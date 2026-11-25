--[[--
Thought popup pagination and page rendering.

The bottom bar (widget.lua) renders the review content with the document font
and size settings; this module owns the pipeline behind it:

  * one-shot pagination of the review blocks (ContentBuilder + Paginator),
    cached in a koreader Cache keyed by (items, font, margins, height_ratio);
  * per-piece glyph bitmaps (piece cache);
  * lazy page bitmaps (page cache), where a page is a y-slice of the flowing
    content, so a single long thought may span several pages.

Widgets ask for page starts with computePages(viewport_h) and render page
bitmaps on demand with renderPage(page_idx, page_starts). The page -> piece
inverted index is rebuilt whenever the page_starts table changes (i.e. when
the viewport height changes), while layout and piece caches are freed only
when the content or geometry key changes.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Cache = require("cache")
local CacheItem = require("cacheitem")
local ContentBuilder = require("fanqie.review_popup.content_builder")
local Device = require("device")
local FaceFactory = require("fanqie.review_popup.face_factory")
local Paginator = require("fanqie.review_popup.paginator")
local Screen = Device.screen
local logger = require("fanqie.logger")

-- 配图相关依赖全部可选：缺任何一个只丢掉图片能力，文字照常渲染。
-- （测试环境与精简安装里没有这些模块，硬 require 会让整个弹窗起不来。）
local ok_ImgSize, ImgSize = pcall(require, "fanqie.review_popup.img_size")
local ok_ReviewPics, ReviewPics = pcall(require, "fanqie.review_pics")
local ok_RenderImage, RenderImage = pcall(require, "ui/renderimage")
local ok_ImageWidget, ImageWidget = pcall(require, "ui/widget/imagewidget")

-- 墙钟计时（ms）。注意不能用 CPU 时间计时函数：进程空转等待时不增长，
-- 用它测耗时会让性能日志严重失真，这里统一用 luasocket 的 gettime。
local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.time() * 1000
end

local PAGE_BB_CACHE_MAX = 8
local PIECE_CACHE_MAX = 200
local LAYOUT_CACHE_MAX = 6
local IMG_BB_CACHE_MAX = 12

local PieceItem = CacheItem:extend{}
function PieceItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local PageItem = CacheItem:extend{}
function PageItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

-- 已解码 + 已按框 flatten 的图片位图（白底，页面直接 blit）。
-- 尺寸键在 key 里，同一张图在不同框尺寸下各存一份。
local ImgItem = CacheItem:extend{}
function ImgItem:onFree()
    if self.bb and self.bb.free then self.bb:free() end
end

local LayoutItem = CacheItem:extend{}
function LayoutItem:onFree()
    Paginator.freeTextPieces(self.pieces)
end

local function newPieceCache()
    return Cache:new{ slots = PIECE_CACHE_MAX, enable_eviction_cb = true }
end

local function newPageCache()
    return Cache:new{ slots = PAGE_BB_CACHE_MAX, enable_eviction_cb = true }
end

local function newLayoutCache()
    return Cache:new{ slots = LAYOUT_CACHE_MAX, enable_eviction_cb = true }
end

local function newImgCache()
    return Cache:new{ slots = IMG_BB_CACHE_MAX, enable_eviction_cb = true }
end

local function itemsKey(items)
    local parts = {}
    for _, item in ipairs(items or {}) do
        -- 回复展开状态必须进 key：否则「展开」后内容变了、key 没变，
        -- setContent 会认为无需重排，弹窗永远看不到新加载的回复。
        --
        -- 图片指纹（数量 + 各 URL）同理必须进 key：换一页段评时 URL 变了但
        -- 文字可能一模一样（同一段的不同评论），不带上就会命中旧布局。
        -- 注意指纹只含 URL 与数量，**不含下载状态** —— 布局高度只依赖接口给的
        -- 比例，图下没下完不影响排版，所以下载完成不该使布局失效。
        local pic_sig = ""
        if type(item.pics) == "table" and #item.pics > 0 then
            local urls = {}
            for i = 1, #item.pics do
                urls[i] = tostring(item.pics[i].url or "")
            end
            pic_sig = "|p" .. #item.pics .. ":" .. table.concat(urls, ",")
        end
        parts[#parts + 1] = string.format("%s|%s|%s|%d|%s|%s|%d|%s|%s|%s%s",
            tostring(item.abstract or ""),
            tostring(item.author or ""),
            tostring(item.content or ""),
            tonumber(item.likes_count) or 0,
            tostring(tonumber(item.reply_count) or 0),
            tostring(item.replies_expanded and 1 or 0),
            (type(item.replies) == "table") and #item.replies or 0,
            tostring(item.replies_more and 1 or 0),
            tostring(item.replies_loading and 1 or 0),
            -- 「还有 N 条」的文案取自 replies_total，不进 key 会显示旧数字
            tostring(tonumber(item.replies_total) or 0),
            pic_sig)
    end
    return table.concat(parts, "\n")
end

local function geomKey(doc_font_name, doc_font_size, margins, height_ratio, contrast,
                       weight, gamma)
    local m = margins or {}
    return string.format("%s|%d|%d_%d_%d_%d|%.4f|%d|%s|%s",
        doc_font_name or "", doc_font_size or 0,
        m.left or 0, m.right or 0, m.top or 0, m.bottom or 0,
        height_ratio or 0.35,
        tonumber(contrast) or 0,
        tostring(tonumber(weight) or 0),
        tostring(tonumber(gamma) or 0))
end

-- ── 段评配图排版 ─────────────────────────────────────────────────────
-- 硬约束：**分页阶段绝不读图**。布局只用接口给的 width/height（`picInfos` 自带），
-- 拿不到就退化成一个固定比例的框。真实比例只在绘制时用 contain 修正，
-- 因此「图下完了」不需要重排，只刷新那一页 —— 这是首屏能秒出的前提。
-- 单图缩略图的强制约定（Sean 定的，别按「尽量铺满」去调）：
--   竖图（高 ≥ 宽）→ 高度最多半个弹窗；
--   横图（宽 > 高）→ 宽度最多半个弹窗宽。
-- 一半用内容区折算：viewport_h 已扣掉弹窗边框/边距/按钮，text_w 也扣掉了左右边距，
-- 所以算出来的上限只会比「半个弹窗」更小，不会越界。
local IMG_HALF_H_RATIO = 0.5      -- 竖图高度上限 = 内容视口高度的一半
local IMG_HALF_W_RATIO = 0.5      -- 横图宽度上限 = 内容区宽度的一半
local IMG_WIDTH_RATIO = 0.92      -- 内容区宽度的占比，左右留一点呼吸
local IMG_GRID_COLS = 3           -- 多图走 3 列网格（整块，不单张超页）

--- 单图显示框。返回 w, h。
local function singleImageBox(pic, text_w, viewport_h)
    local avail_w = math.floor(text_w * IMG_WIDTH_RATIO)
    if avail_w < 1 then avail_w = 1 end
    local half_h = math.max(1, math.floor((viewport_h or 0) * IMG_HALF_H_RATIO))
    local half_w = math.max(1, math.floor(text_w * IMG_HALF_W_RATIO))
    -- 优先用「裁掉 expand 黑边后的有效尺寸」：否则 800×166 这类极宽图会按 4.8:1
    -- 排成一条矮框，裁完内容又被迫缩回去，等于白裁。_cw/_ch 由 measurePics() 写入。
    local pw = tonumber(pic and pic._cw) or tonumber(pic and pic.w) or 0
    local ph = tonumber(pic and pic._ch) or tonumber(pic and pic.h) or 0
    if pw > 0 and ph > 0 then
        if ph >= pw then
            -- 竖图/方图：先定高（钳半个弹窗），宽按比例跟随
            local h = math.min(half_h, math.floor(avail_w * ph / pw + 0.5))
            h = math.max(1, h)
            local w = math.max(1, math.floor(h * pw / ph + 0.5))
            if w > avail_w then w = avail_w end
            return w, h
        end
        -- 横图：先定宽（钳半个弹窗宽），高按比例跟随
        local w = math.min(avail_w, half_w)
        local h = math.max(1, math.floor(w * ph / pw + 0.5))
        if h > half_h then
            -- 兜底：极端比例下高度也不能越界
            h = half_h
            w = math.max(1, math.floor(h * pw / ph + 0.5))
        end
        return w, h
    end
    -- 缺字段：按横图占位（半宽 + 0.75 半高），不猜具体比例，避免布局抖动
    return math.max(1, math.min(avail_w, half_w)), math.max(1, math.floor(half_h * 0.75))
end

local function gridMetrics(text_w)
    local gap = Screen:scaleBySize(4)
    -- 左对齐后网格铺满正文宽：留 0.92 的呼吸位只会在右边露出一条没人对齐的空槽
    local avail = math.floor(text_w)
    local cell = math.floor((avail - (IMG_GRID_COLS - 1) * gap) / IMG_GRID_COLS)
    if cell < 1 then cell = 1 end
    return cell, gap
end

--- 一个 image block 的几何：{ cells = {{x,y,w,h}}, box_h }。
-- 坐标相对 block 顶部，由 paginate 与 renderPage 共用，保证两边算得一模一样。
-- 缩略图一律左对齐（与正文左边缘齐平）：弹窗里的图是「配图」，不是封面墙，
-- 居中的窄图会让右侧留一块不规则的空白，视觉上比对齐问题更刺眼。
local function imageLayout(pics, text_w, viewport_h)
    local n = #pics
    if n == 1 then
        local w, h = singleImageBox(pics[1], text_w, viewport_h)
        return {
            cells = { { x = 0, y = 0, w = w, h = h } },
            box_h = h,
        }
    end
    local cell, gap = gridMetrics(text_w)
    -- 网格同样守约定：单格不高于半个视口、不宽于半个内容区
    local half_h = math.max(1, math.floor((viewport_h or 0) * IMG_HALF_H_RATIO))
    local half_w = math.max(1, math.floor(text_w * IMG_HALF_W_RATIO))
    if cell > half_h then cell = half_h end
    if cell > half_w then cell = half_w end
    local rows = math.ceil(n / IMG_GRID_COLS)
    local cells = {}
    for i = 1, n do
        local r = math.floor((i - 1) / IMG_GRID_COLS)
        local c = (i - 1) % IMG_GRID_COLS
        cells[i] = {
            x = c * (cell + gap),
            y = r * (cell + gap),
            w = cell,
            h = cell,
        }
    end
    return {
        cells = cells,
        box_h = rows * cell + (rows - 1) * gap,
    }
end

--- 图片块的边界行（坐标相对 block 顶部）。单图一整块原子边界；
--- 网格按行切分，行与行之间不留缝（下一行的 top = 上一行的 bottom）。
-- 分页只认 boundary：图片不进表的话，末页高度会漏算图片那一截 ——
-- 图在最后一条评论里时，末页 = 视口高 + 图高，swipe 翻页只落在页起点上，
-- 图的下沿永远露不出来（表现为「翻不动、缩略图只剩半张」）。
-- 行间不留缝的原因：页起点只落在边界 top/bottom 上，行与行之间若留几像素
-- 的空隙，「上一页装不下下一行」时会催生出只有几像素高的占位页。
local function imageBoundaries(lay)
    local cells = lay.cells or {}
    if #cells == 0 then return {} end
    local rows, order = {}, {}
    for i = 1, #cells do
        local c = cells[i]
        local row = rows[c.y]
        if not row then
            rows[c.y] = { top = c.y, bottom = c.y + c.h }
            order[#order + 1] = c.y
        elseif c.y + c.h > row.bottom then
            row.bottom = c.y + c.h
        end
    end
    table.sort(order)
    local out = {}
    for k = 1, #order do
        local next_top = (k < #order) and rows[order[k + 1]].top or lay.box_h
        out[k] = { top = rows[order[k]].top, bottom = next_top }
    end
    return out
end

local PageRenderer = {}

-- 单测钩子：图片几何是纯函数，但藏在模块内。暴露一份给 _smoke_review_pics.js
-- 直接验证高度钳制（业务代码请勿调用）。
PageRenderer._test = {
    imageLayout = imageLayout,
    singleImageBox = singleImageBox,
    imageBoundaries = imageBoundaries,
}

--- @param opts table { items, doc_font_name, doc_font_size, doc_margins,
---                    height_ratio, pic_dir, estimate_viewport_h }
function PageRenderer:new(opts)
    opts = opts or {}
    local self_obj = setmetatable({}, { __index = PageRenderer })
    self_obj.items = opts.items or {}
    self_obj.doc_font_name = opts.doc_font_name
    self_obj.doc_font_size = opts.doc_font_size or Screen:scaleBySize(18)
    self_obj.doc_margins = opts.doc_margins or {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    }
    self_obj.height_ratio = opts.height_ratio or 0.35
    self_obj.contrast = tonumber(opts.contrast) or 0
    -- 阅读器的「字重」与「对比度」：弹框自建 face，得自己换算成字重档位/字色。
    -- 对比度存的是索引（15 = gamma 1.0），渲染时再经 gammaIndexToValue 换算。
    self_obj.doc_font_weight = tonumber(opts.doc_font_weight) or 0
    self_obj.doc_font_gamma = tonumber(opts.doc_font_gamma) or 15
    self_obj.skip_quote = opts.skip_quote == true
    -- 段评配图目录（<下载目录>/review_pics/<book_id>）。
    -- nil 表示本次弹窗不带图：image piece 只画占位框，不做任何 IO。
    self_obj.pic_dir = opts.pic_dir
    -- 分页时内容区高度还没算准（要先分页才知道总高），这里用估算值定「单图
    -- 高度上限」这一个用途。0.85 的钳制比实际留了余量，估算误差吃得下。
    self_obj.estimate_viewport_h = tonumber(opts.estimate_viewport_h) or 0
    self_obj._layout_cache = newLayoutCache()
    self_obj._page_bbs = newPageCache()
    self_obj._piece_cache = newPieceCache()
    self_obj._img_bbs = newImgCache()
    -- 已确认磁盘上不存在的图片：避免每画一页都 io.open 一次。
    -- 下载成功后由 invalidateImage() 清掉对应项。
    self_obj._img_missing = {}
    self_obj._items_key = itemsKey(self_obj.items)
    self_obj._geom_key = geomKey(self_obj.doc_font_name, self_obj.doc_font_size,
        self_obj.doc_margins, self_obj.height_ratio, self_obj.contrast,
        self_obj.doc_font_weight, self_obj.doc_font_gamma)
    self_obj._bb_key = self_obj._items_key .. "|" .. self_obj._geom_key
    self_obj._page_pieces = {}
    self_obj._page_pieces_key = nil
    -- Public layout results, refreshed by ensureLayout():
    self_obj.layout = nil
    self_obj.content_h = 0
    self_obj.text_w = 0
    self_obj.boundaries = nil
    return self_obj
end

--- Reload content/geometry; re-layout only when the cache key changed.
--- contrast (optional) shifts every block's gray level; a change re-lays out
--- because the colors are baked into the pieces.
function PageRenderer:setContent(items, doc_font_name, doc_font_size, doc_margins, height_ratio, contrast,
                                 doc_font_weight, doc_font_gamma)
    self.items = items or {}
    if doc_font_name ~= nil then self.doc_font_name = doc_font_name end
    if doc_font_size ~= nil then self.doc_font_size = doc_font_size end
    if doc_margins ~= nil then self.doc_margins = doc_margins end
    if height_ratio ~= nil then self.height_ratio = height_ratio end
    if contrast ~= nil then self.contrast = tonumber(contrast) or 0 end
    if doc_font_weight ~= nil then self.doc_font_weight = tonumber(doc_font_weight) or 0 end
    if doc_font_gamma ~= nil then self.doc_font_gamma = tonumber(doc_font_gamma) or 15 end
    local new_items_key = itemsKey(self.items)
    local new_geom_key = geomKey(self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.contrast,
        self.doc_font_weight, self.doc_font_gamma)
    local new_bb_key = new_items_key .. "|" .. new_geom_key
    if new_bb_key ~= self._bb_key then
        self._items_key = new_items_key
        self._geom_key = new_geom_key
        self._bb_key = new_bb_key
        self:ensureLayout()
    end
end

--- 图片有效尺寸变化后强制重排：布局缓存按文本+字体的 key 命中，
--- 尺寸不在 key 里，不清掉会一直复用旧几何（图仍被塞进矮框）。
function PageRenderer:invalidateLayout()
    self._bb_key = nil
    if self._layout_cache and self._layout_cache.clear then
        pcall(self._layout_cache.clear, self._layout_cache)
    end
end

function PageRenderer:paginate()
    local t0 = now_ms()
    -- 分页前先量图片有效尺寸：expand 补边的宽图必须按「内容比例」排版，
    -- 否则框被排成 4.8:1 的矮条，渲染阶段裁了边也放不大。
    self:measurePics(self.items)
    -- 设置里存的是对比度索引（默认 15），渲染要的是 gamma 值（默认 1.0）。
    -- 不换算会恒命中「高对比」→ 全篇多一层仿粗，段评比正文还黑。
    local gamma_value = FaceFactory.gammaIndexToValue(self.doc_font_gamma)
    local blocks = ContentBuilder.build(self.items, {
        contrast = self.contrast,
        gamma = gamma_value,
        skip_quote = self.skip_quote,
    })
    local t1 = now_ms()

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local inner_w = Screen:getWidth()
    local text_w = inner_w - self.doc_margins.left - self.doc_margins.right - item_width
    if text_w < 10 then text_w = 10 end
    local base_size = math.max(8, math.floor(self.doc_font_size or 0))
    local bold_level = FaceFactory.resolveBoldLevel(self.doc_font_weight)

    -- 内容区高度估算：只用于「单图最大高度」这一条（一屏至少一张完整图）。
    -- 真实视口要等分页完才知道（总高决定弹窗是撑满还是收缩），此处的近似
    -- 被 0.85 的钳制系数吸收了，不会让图超出一屏。
    local viewport_h = tonumber(self.estimate_viewport_h) or 0
    if viewport_h <= 0 then
        viewport_h = math.floor(Screen:getHeight() * self.height_ratio)
    end

    local pieces = {}
    local boundaries = {}
    local y = 0

    local function addTextPiece(variant, text, fg, width, x, keep_next)
        local face = FaceFactory:getFace(self.doc_font_name, base_size, variant, bold_level)
        if not face then return false end
        local line_h, extra, baseline = Paginator.textPieceMetrics(face)
        local paginated = Paginator.paginateText(text, face, width)
        local n_lines = paginated.n_lines
        local piece_h = n_lines * line_h + extra
        local piece_y = y
        pieces[#pieces + 1] = {
            kind = "text", variant = variant, text = text, fg = fg,
            face = face, width = width, x = x, y = piece_y,
            bold = face.synth_bold == true,
            n_lines = n_lines, line_h = line_h, piece_h = piece_h,
            baseline = baseline, xtext = paginated.xtext, lines = paginated.lines,
        }
        if keep_next and n_lines >= 1 then
            boundaries[#boundaries + 1] = {
                top = piece_y,
                bottom = piece_y + piece_h,
                keep_next = true,
            }
        else
            for k = 1, n_lines do
                boundaries[#boundaries + 1] = {
                    top = piece_y + (k - 1) * line_h,
                    bottom = piece_y + k * line_h,
                }
            end
        end
        y = y + piece_h
        return true
    end

    for _, block in ipairs(blocks) do
        if block.kind == "separator" then
            -- 分隔线只占位不产生 boundary：分页仍由文字行驱动，页缝落在
            -- 线的留白里视觉无感。piece_h = 线宽，供 renderPage 画矩形。
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            local thickness = math.max(1, Screen:scaleBySize(1))
            pieces[#pieces + 1] = {
                kind = "separator",
                fg = block.fg,
                x = 0,
                y = y,
                width = text_w,
                piece_h = thickness,
            }
            y = y + thickness + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        elseif block.kind == "paragraph" then
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            -- 回复块缩进：层级 * 约 1.15 个字宽，正文宽度同步收窄
            local level = tonumber(block.indent_level) or 0
            local indent = 0
            if level > 0 then
                indent = math.floor(base_size * 1.15 * level)
                if indent > text_w / 2 then indent = math.floor(text_w / 2) end
            end
            local block_w = text_w - indent
            if block_w < 10 then block_w = 10 end
            local before = #pieces
            addTextPiece(block.variant, block.text, block.fg, block_w, indent,
                block.variant == "meta" or block.variant == "reply_meta")
            if #pieces > before then
                local piece = pieces[#pieces]
                -- 弹窗靠这两个字段做点击命中：只有带 action 的行会拦截点击，
                -- 其余区域仍旧翻页。
                piece.action = block.action
                piece.item_index = block.item_index
            end
            y = y + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        elseif block.kind == "image" then
            y = y + math.floor(base_size * (block.spacing_before or 0) + 0.5)
            local pics = block.pics or {}
            -- 二级评论里的图要跟着回复一起缩进：宽度同步收窄，否则图会
            -- 顶到弹窗左边缘、看着不像某条回复的配图。cell.x 仍是块内相对
            -- 坐标，绘制与点击命中都要再加上 piece.x（见 renderPage /
            -- _handleImageAction）。
            local img_level = tonumber(block.indent_level) or 0
            local img_indent = 0
            if img_level > 0 then
                img_indent = math.floor(base_size * 1.15 * img_level)
                if img_indent > text_w / 2 then img_indent = math.floor(text_w / 2) end
            end
            local img_w = text_w - img_indent
            if img_w < 10 then img_w = 10 end
            local lay = imageLayout(pics, img_w, viewport_h)
            pieces[#pieces + 1] = {
                kind = "image",
                pics = pics,
                layout = lay,
                x = img_indent,
                y = y,
                width = img_w,
                piece_h = lay.box_h,
                -- 点击命中：整块图区域都可点，逐张按 cell 判定（见 widget.lua）
                action = "open_image",
                item_index = block.item_index,
            }
            -- 图片行也要进边界表（见 imageBoundaries 注释）：单图原子不跨页，
            -- 网格行间可分页。跨页绘制路径（renderPage 的分段 blit）保留，
            -- 兜 pan 停在页中间的连续滚动。
            for ri, row in ipairs(imageBoundaries(lay)) do
                local top_abs = y + row.top
                if ri == 1 and #boundaries > 0
                    and boundaries[#boundaries].bottom < top_abs then
                    -- 图前的段前距并进上一条边界：否则「上一页装不下图」时
                    -- 分页会在空隙里切出一页只有几像素高的占位页
                    boundaries[#boundaries].bottom = top_abs
                end
                boundaries[#boundaries + 1] = {
                    top = top_abs,
                    bottom = y + row.bottom,
                }
            end
            y = y + lay.box_h + math.floor(base_size * (block.spacing_after or 0) + 0.5)
        end
    end

    local content_h = math.max(1, y)
    local t2 = now_ms()
    logger.info(string.format(
        "thought popup paginated in %.1fms (blocks %.1fms) items=%d content_h=%d",
        (t2 - t0), (t1 - t0), #self.items, content_h))
    return {
        pieces = pieces,
        boundaries = boundaries,
        content_h = content_h,
        item_count = #self.items,
        text_w = text_w,
    }
end

--- (Re)build the layout: free stale page bitmaps, load the cached layout or
--- paginate. Idempotent; call once after construction / setContent.
function PageRenderer:ensureLayout()
    self:_freePageBBs()
    self:_freePieceCache()
    self._layout_cache = self._layout_cache or newLayoutCache()
    local cached = self._layout_cache:get(self._bb_key)
    if cached then
        self.layout = cached
        self.content_h = cached.content_h
        self.boundaries = cached.boundaries
        self.text_w = cached.text_w
        return
    end
    local layout = LayoutItem:new(self:paginate())
    self._layout_cache:insert(self._bb_key, layout)
    self.layout = layout
    self.content_h = layout.content_h
    self.boundaries = layout.boundaries
    self.text_w = layout.text_w
end

--- Page start list for a viewport height (pure logic, see paginator.lua).
--- Always contains at least { 0 }.
function PageRenderer:computePages(viewport_h)
    return Paginator.computePages(self.boundaries, viewport_h, self.content_h)
end

function PageRenderer:_getPieceTextBB(piece)
    self._piece_cache = self._piece_cache or newPieceCache()
    local cached = self._piece_cache:get(piece)
    if cached then return cached.bb end
    local bb = Paginator.renderTextPiece(piece)
    if not bb then return nil end
    self._piece_cache:insert(piece, PieceItem:new{ bb = bb })
    return bb
end

--- 某张配图的本地缓存路径。没有 pic_dir 说明本次弹窗不带图。
function PageRenderer:_imagePath(pic)
    if not self.pic_dir or not ok_ReviewPics then return nil end
    local name = ReviewPics.filename(pic and pic.url)
    if not name then return nil end
    return self.pic_dir .. "/" .. name
end

--- 颜色是否接近纯黑（兼容 8bpp 灰度与 RGB32 两种位图）。
local function is_black_color(c)
    if not c then return false end
    if c.r ~= nil then
        return c.r < 16 and c.g < 16 and c.b < 16
    end
    return (c.a or 0) < 16
end

--- 检测左右整列纯黑的 expand 画布边条。
-- 判据：左右对称（差 ≤2px）、各 ≥4px、内容 ≥20% 宽且中心非纯黑。
-- 扫描上限必须大于常见补边宽（800 宽图可达 280/边），否则会截断在阈值上永不裁剪。
-- get_pixel(x, y) 由调用方提供，便于单测。
local function detect_side_bars_impl(w, h, get_pixel)
    if w < 16 or h < 8 then return 0, 0 end
    local max_cols = math.floor(w * 0.45)
    local step_y = math.max(1, math.floor(h / 32))
    local function column_is_black(x)
        for y = 0, h - 1, step_y do
            if not is_black_color(get_pixel(x, y)) then return false end
        end
        return true
    end
    local function run(from_left)
        local n = 0
        for k = 0, max_cols - 1 do
            local x = from_left and k or (w - 1 - k)
            if not column_is_black(x) then break end
            n = n + 1
        end
        return n
    end
    local l = run(true)
    local r = run(false)
    if l < 4 or r < 4 or math.abs(l - r) > 2 then return 0, 0 end
    local cw = w - l - r
    -- 内容至少保留 20% 宽：再窄说明整图基本是黑底，裁了也没意义
    if cw < 16 or cw < w * 0.2 then return 0, 0 end
    -- 内容区不能整块是黑的：均匀采样 5 列，全黑说明这不是画布补边，放弃
    for i = 1, 5 do
        if not column_is_black(l + math.floor(cw * i / 6)) then
            return l, r
        end
    end
    return 0, 0
end

--- 把一张图解码、等比缩进 box_w × box_h（contain，白底居中），返回整块位图。
-- 返回 nil 表示「文件还没有 / 解不出来」→ 调用方画占位框。
function PageRenderer:_renderImageBB(pic, box_w, box_h)
    if box_w < 1 or box_h < 1 then return nil end
    local path = self:_imagePath(pic)
    if not path then return nil end
    if self._img_missing[path] then return nil end
    if not ReviewPics.file_exists(path) then
        self._img_missing[path] = true
        return nil
    end

    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8

    -- expand 转码模板会在左右补纯黑画布，直接 contain 会把内容缩得只剩中间一条。
    -- 探到对称黑边就裁掉、再按内容比例放大；只动绘制，不改分页尺寸。
    -- 放在比例探测之前：命中这条路时不再白算一遍 contain 参数。
    -- 已判定无黑边的图直接跳过，免得每次渲染都为检测多解码一遍。
    local trim_cached = self._pic_sizes and self._pic_sizes[path]
    if ok_RenderImage and RenderImage and trim_cached ~= false then
        local ok_trim, trimmed = pcall(self._renderTrimmed, self, path, box_w, box_h, bbtype)
        if ok_trim and trimmed then
            self._drawn_images = (self._drawn_images or 0) + 1
            return trimmed
        end
    end

    -- 真实比例优先（读文件头），接口字段次之，都没有就填满框
    local dw, dh = 0, 0
    if ok_ImgSize and ImgSize then
        dw, dh = ImgSize.probe(path)
    end
    if not (dw and dh and dw > 0 and dh > 0) then
        dw, dh = tonumber(pic.w) or 0, tonumber(pic.h) or 0
    end
    if not (dw > 0 and dh > 0) then dw, dh = box_w, box_h end

    local scale = math.min(box_w / dw, box_h / dh)
    local rw = math.max(1, math.floor(dw * scale + 0.5))
    local rh = math.max(1, math.floor(dh * scale + 0.5))
    local ox = math.max(0, math.floor((box_w - rw) / 2))
    local oy = math.max(0, math.floor((box_h - rh) / 2))

    local bb = Blitbuffer.new(box_w, box_h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    -- ImageWidget 在这里只当**绘制工具**（往给定 bb 上画一次就丢），
    -- 不塞进控件树 —— 弹窗这条是自绘位图链，塞控件会被忽略。
    -- 用它而不是裸 blitFrom 的原因：alpha 通道、dither、缩放都由官方代码处理，
    -- 带透明边的表情贴纸不会渲染成黑块，也不用我们自己区分 premultiplied/
    -- straight alpha 两种来源。
    local drawn = false
    if ok_ImageWidget and ImageWidget then
        drawn = pcall(function()
            local iw = ImageWidget:new{
                file = path,
                width = rw,
                height = rh,
                alpha = true,
                -- 不进全局 ImageCache：成品位图我们自己按 (path, 框尺寸) 缓存，
                -- 让官方缓存再存一份原始解码结果只是白占内存。
                file_do_cache = false,
            }
            iw:paintTo(bb, ox, oy)
            if iw.free then iw:free() end
        end)
    end
    if not drawn then
        -- 退路：直接解码到目标尺寸再贴（无 alpha 处理，但至少能看）
        local ok_img, img = false, nil
        if ok_RenderImage and RenderImage then
            ok_img, img = pcall(RenderImage.renderImageFile, RenderImage, path, false, rw, rh)
        end
        if ok_img and img then
            pcall(function()
                bb:blitFrom(img, ox, oy, 0, 0,
                    math.min(rw, img:getWidth()), math.min(rh, img:getHeight()))
            end)
            if img.free then pcall(img.free, img) end
        else
            bb:free()
            return nil
        end
    end
    -- 记录「本弹窗真的往屏幕上画过图」：关窗时要全刷清残影（widget.lua）。
    self._drawn_images = (self._drawn_images or 0) + 1
    return bb
end

--- 裁掉 expand 模板的左右黑边后再 contain。没有黑边就返回 nil，交回 ImageWidget。
function PageRenderer:_renderTrimmed(path, box_w, box_h, bbtype)
    local src = RenderImage:renderImageFile(path, false)
    if not src then return nil end
    local sw, sh = src:getWidth(), src:getHeight()
    -- 布局阶段测过就直接复用（含「无黑边」的否定结果，免得每次渲染都重扫全图）
    local cached = self._pic_sizes and self._pic_sizes[path]
    if cached == false then
        src:free()
        return nil
    end
    local l, r
    if cached and cached.sw == sw and cached.sh == sh then
        l, r = cached.l, cached.r
    else
        l, r = detect_side_bars_impl(sw, sh, function(x, y)
            return src:getPixel(x, y)
        end)
        self._pic_sizes = self._pic_sizes or {}
        self._pic_sizes[path] = (l > 0)
            and { l = l, r = r, sw = sw, sh = sh, cw = sw - l - r, ch = sh }
            or false
    end
    if l == 0 then
        src:free()
        return nil
    end

    local cw = sw - l - r
    local scale = math.min(box_w / cw, box_h / sh)
    local tw = math.max(1, math.floor(cw * scale + 0.5))
    local th = math.max(1, math.floor(sh * scale + 0.5))

    -- blitFrom 带源偏移：只把 [l, 0, cw, sh] 这段拷进新缓冲，再整体缩放。
    local crop = Blitbuffer.new(cw, sh, src:getType())
    crop:blitFrom(src, 0, 0, l, 0, cw, sh)
    src:free()
    local scaled = RenderImage:scaleBlitBuffer(crop, tw, th)   -- 默认会 free crop
    if not scaled then return nil end

    local bb = Blitbuffer.new(box_w, box_h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local ox = math.max(0, math.floor((box_w - tw) / 2))
    local oy = math.max(0, math.floor((box_h - th) / 2))
    bb:blitFrom(scaled, ox, oy, 0, 0,
        math.min(tw, scaled:getWidth()), math.min(th, scaled:getHeight()))
    if scaled.free then scaled:free() end
    return bb
end

--- 量一张「已下载」图片的有效尺寸：解码一次，检测左右 expand 黑边。
-- 结果按 path 缓存（含「无黑边」的否定结果），布局阶段反复调用也不会重复解码。
-- 返回 { l, r, sw, sh, cw, ch }；未下载 / 解码失败 / 无黑边时返回 nil。
function PageRenderer:_measurePic(pic)
    if type(pic) ~= "table" then return nil end
    local path = self:_imagePath(pic)
    if not path or self._img_missing[path] then return nil end
    if not (ok_RenderImage and RenderImage) then return nil end
    self._pic_sizes = self._pic_sizes or {}
    local hit = self._pic_sizes[path]
    if hit ~= nil then return hit or nil end
    local ok, res = pcall(function()
        local src = RenderImage:renderImageFile(path, false)
        if not src then return false end
        local sw, sh = src:getWidth(), src:getHeight()
        local l, r = detect_side_bars_impl(sw, sh, function(x, y)
            return src:getPixel(x, y)
        end)
        src:free()
        if l == 0 and r == 0 then return false end
        return { l = l, r = r, sw = sw, sh = sh, cw = sw - l - r, ch = sh }
    end)
    local val = (ok and res) or false
    self._pic_sizes[path] = val
    return val or nil
end

--- 布局前把裁边后的有效宽高写进 pic（_cw/_ch），返回是否有尺寸变化。
-- 粗筛只测较宽的横图（expand 产物宽 800），普通图跳过，避免打开时整屏解码。
function PageRenderer:measurePics(items)
    if type(items) ~= "table" then return false end
    local changed = false
    local function one(p)
        if type(p) ~= "table" then return end
        local pw, ph = tonumber(p.w) or 0, tonumber(p.h) or 0
        if not (pw >= 600 and pw > ph * 1.2) then return end
        local m = self:_measurePic(p)
        if m and m.cw and m.ch and m.cw > 0 and m.ch > 0 then
            if p._cw ~= m.cw or p._ch ~= m.ch then changed = true end
            p._cw, p._ch = m.cw, m.ch
        elseif p._cw or p._ch then
            p._cw, p._ch = nil, nil
            changed = true
        end
    end
    -- 只测单图：网格格子是固定正方形，按内容比例排版没有意义，
    -- 白白多解码一遍（打开弹窗时一屏十几张图会明显拖慢）。
    for _, it in ipairs(items) do
        if type(it.pics) == "table" and #it.pics == 1 then one(it.pics[1]) end
        if type(it.replies) == "table" then
            for _, rp in ipairs(it.replies) do
                if type(rp.pics) == "table" and #rp.pics == 1 then one(rp.pics[1]) end
            end
        end
    end
    return changed
end

--- 图片位图（按 path + 框尺寸缓存；解码一次，滚动时反复 blit）
function PageRenderer:_getImageBB(pic, box_w, box_h)
    if not self.pic_dir then return nil end
    local path = self:_imagePath(pic)
    if not path then return nil end
    self._img_bbs = self._img_bbs or newImgCache()
    local key = path .. "|" .. box_w .. "x" .. box_h
    local hit = self._img_bbs:get(key)
    if hit then return hit.bb end
    local bb = self:_renderImageBB(pic, box_w, box_h)
    if not bb then return nil end
    self._img_bbs:insert(key, ImgItem:new{ bb = bb })
    return bb
end

--- 下载完成 / 文件被外部删除后调用：让下一帧重新判断文件在不在。
function PageRenderer:invalidateImage(url)
    if not ok_ReviewPics then return end
    local name = ReviewPics.filename(url)
    if not name or not self.pic_dir then return end
    local path = self.pic_dir .. "/" .. name
    self._img_missing[path] = nil
    -- 图片重下后尺寸可能变（之前是坏文件），测量结果一并作废
    if self._pic_sizes then self._pic_sizes[path] = nil end
end

function PageRenderer:_freePieceCache()
    if self._piece_cache and self._piece_cache.clear then
        self._piece_cache:clear()
    else
        self._piece_cache = newPieceCache()
    end
end

--- Render (and cache) the bitmap of page page_idx within page_starts.
--- page_starts is the page list returned by computePages; the page -> piece
--- index is rebuilt whenever a different page_starts table is passed.
function PageRenderer:renderPage(page_idx, page_starts)
    if self._page_pieces_key ~= page_starts then
        self._page_pieces = Paginator.buildPagePieceIndex(
            self.layout and self.layout.pieces, page_starts, self.content_h)
        self._page_pieces_key = page_starts
    end
    self._page_bbs = self._page_bbs or newPageCache()
    local cached = self._page_bbs:get(page_idx)
    if cached then return cached.bb end
    if not page_starts or page_idx < 1 or page_idx > #page_starts then return nil end
    local p0 = page_starts[page_idx]
    local p1 = page_starts[page_idx + 1] or self.content_h
    local h = math.max(1, p1 - p0)
    local bbtype = Screen:isColorEnabled() and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local bb = Blitbuffer.new(self.text_w, h, bbtype)
    bb:fill(Blitbuffer.COLOR_WHITE)

    for _, piece in ipairs(self._page_pieces[page_idx] or {}) do
        -- 分隔线必须在 pieceVisibleRange 之前分流：那个函数对 piece.line_h /
        -- piece.n_lines 做算术，separator 这两个字段为 nil，直接算会崩。
        if piece.kind == "separator" then
            local top = math.max(piece.y, p0)
            local bottom = math.min(piece.y + piece.piece_h, p1)
            if bottom > top then
                bb:paintRect(piece.x, top - p0, piece.width, bottom - top, piece.fg)
            end
        elseif piece.kind == "image" then
            -- 图块跨页：相邻页各绘自己那一段（src_y 对得上），滚动拼起来连续，
            -- 不需要把图顶到下一页开头去「防截断」（那样只会在图前留白）。
            local lay = piece.layout
            local ox = piece.x or 0
            if lay and lay.cells then
                for i = 1, #lay.cells do
                    local cell = lay.cells[i]
                    local pic = piece.pics[i]
                    if pic then
                        local cell_top = piece.y + cell.y
                        local top = math.max(cell_top, p0)
                        local bottom = math.min(cell_top + cell.h, p1)
                        if bottom > top then
                            local img_bb = self:_getImageBB(pic, cell.w, cell.h)
                            if img_bb then
                                bb:blitFrom(img_bb, ox + cell.x, top - p0, 0, top - cell_top,
                                    math.min(cell.w, img_bb:getWidth()), bottom - top)
                            else
                                -- 占位框：还没下完 / 解码失败。浅灰底 + 上下细线，
                                -- 让「这里有一张图」可感知，同时保持可点击。
                                bb:paintRect(ox + cell.x, top - p0, cell.w, bottom - top,
                                    Blitbuffer.COLOR_GRAY_E)
                                bb:paintRect(ox + cell.x, top - p0, cell.w, 1,
                                    Blitbuffer.COLOR_GRAY_9)
                                if cell.h >= 2 then
                                    bb:paintRect(ox + cell.x, top - p0 + (bottom - top) - 1,
                                        cell.w, 1, Blitbuffer.COLOR_GRAY_9)
                                end
                            end
                        end
                    end
                end
            end
        else
            local r = Paginator.pieceVisibleRange(piece, p0, p1)
            if r and piece.kind == "text" then
                local text_bb = self:_getPieceTextBB(piece)
                if text_bb then
                    bb:blitFrom(text_bb, piece.x, r.dest_y, 0, r.src_y, piece.width, r.src_h)
                else
                    logger.warn("thought popup text render failed:",
                        "y=", piece.y, "n_lines=", piece.n_lines,
                        "text=", tostring(piece.text):sub(1, 40))
                end
            end
        end
    end

    self._page_bbs:insert(page_idx, PageItem:new{ bb = bb })
    return bb
end

function PageRenderer:_freePageBBs()
    if self._page_bbs and self._page_bbs.clear then
        self._page_bbs:clear()
    else
        self._page_bbs = newPageCache()
    end
    self._page_pieces = {}
    self._page_pieces_key = nil
end

--- Drop every cached bitmap and layout (called on document close); the next
--- use re-paginates from scratch.
function PageRenderer:freeContentCaches()
    self:_freePageBBs()
    self:_freePieceCache()
    if self._img_bbs and self._img_bbs.clear then
        self._img_bbs:clear()
    else
        self._img_bbs = newImgCache()
    end
    self._img_missing = {}
    if self._layout_cache and self._layout_cache.clear then
        self._layout_cache:clear()
    else
        self._layout_cache = newLayoutCache()
    end
    self.layout = nil
    self.boundaries = nil
end

-- 黑边检测是纯逻辑（像素来源由 getter 注入），暴露给单测直接验证。
PageRenderer._test.detect_side_bars = detect_side_bars_impl

return PageRenderer
