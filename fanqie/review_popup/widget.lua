--[[--
Thought popup widget (bottom position).

Renders review items by shaping each text block with the document font (or a
fallback chain) and paginating once; pages are blitted into a bitmap viewport
that scrolls. Long content scrolls directly, with no button navigation.

Pagination, layout, page and piece caches live in fanqie/review_popup/
pages.lua (PageRenderer). This module composes the renderer into the bottom
bar: a solid top border, a scrollable page viewport (scroll_container.lua),
and bottom/tap/Back gestures.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local PageRenderer = require("fanqie.review_popup.pages")
local ScrollContainer = require("fanqie.review_popup.scroll_container")
-- 配图缓存模块可选：缺了就只画占位框，不影响文字弹窗
local ok_ReviewPics, ReviewPics = pcall(require, "fanqie.review_pics")
local Size = require("ui/size")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
-- 日志模块缺失时静默降级（测试环境 / 精简安装）
local ok_log, Log = pcall(require, "fanqie.logger")
if not ok_log then Log = nil end

local TOP_BORDER_SIZE = Size.line.thick
local PADDING = Size.padding.large

--- 回复条目补一层可渲染的 pics。
--- 接口给的回复图是原始 image_data 结构（web_uri / web_url / dynamic_url，
--- HEIC 还要转码），必须过 normalize_images 才能得到 {url, fetch, w, h}。
--- 三个源的回复最终都汇到 _fetchReplies 的合并循环里（书山内联也走 on_replies），
--- 所以在这里统一处理，不散落到各客户端。
local function _attachReplyPics(reply)
    if type(reply) ~= "table" then return reply end
    if type(reply.pics) == "table" and #reply.pics > 0 then return reply end
    local pics = {}
    if ok_ReviewPics and type(ReviewPics) == "table" and ReviewPics.from_comment then
        local ok, got = pcall(ReviewPics.from_comment, { images = reply.images })
        if ok and type(got) == "table" then pics = got end
    end
    reply.pics = pics
    return reply
end

local ThoughtPopupWidget = InputContainer:extend{
    items = nil,
    doc_font_name = nil,
    doc_font_size = Screen:scaleBySize(18),
    doc_margins = {
        left = Screen:scaleBySize(20),
        right = Screen:scaleBySize(20),
        top = Screen:scaleBySize(10),
        bottom = Screen:scaleBySize(10),
    },
    height_ratio = 0.70,
    contrast = 9,
    doc_font_weight = 0,
    doc_font_gamma = 15,  -- 对比度索引，15 = gamma 1.0（阅读器默认值）
    close_callback = nil,
    dialog = nil,
    -- Optional fanqie navigation: when set, a horizontal swipe calls
    -- para_nav("next") / para_nav("prev") instead of closing. Swiping to
    -- close stays available through tap-outside and the Back key.
    para_nav = nil,

    -- 底部「继续加载（还剩 N 条）」按钮：more_text 为文案（nil 则不显示），
    -- on_more 为点击回调。加载中回调内部用 _more_busy 挡连点。
    more_text = nil,
    on_more = nil,
    _more_busy = false,
    -- 二级评论回调：on_replies(item, cursor, done)，
    -- done(ok, result, err)，result = { replies, total, has_more, cursor }
    on_replies = nil,
    -- 段评配图：pic_dir 是本书的图片缓存目录；fetch_pic(url, path, done)
    -- 由 main.lua 注入（走 Async 子进程下载）。两者都缺时只画占位框，不做 IO。
    pic_dir = nil,
    fetch_pic = nil,
    _img_gen = 0,
    -- 续拉重开后恢复的滚动位置（内容坐标）；_buildLayout 消费后清零
    _restore_offset = nil,

    _pages = nil,
    _scroll_container = nil,

    covers_footer = true,
}

--- 高度比例钳制 + 尺寸换算（init 与 _reopen 共用）。
function ThoughtPopupWidget:_clampHeight()
    self.height_ratio = math.max(0.1, math.min(0.9, self.height_ratio or 0.70))
    self.width = Screen:getWidth()
    self.height = math.floor(Screen:getHeight() * self.height_ratio)
end

--- 内容区高度估算。
-- 分页阶段要定「单图最多多高」（缩略图上限 = 弹窗可视高度的一半），但真实视口
-- 要等分页完才知道（总高决定弹窗撑满还是收缩）。这里用估算值，因为已经扣掉
-- 边框/边距/按钮，算出来只有比半个弹窗更小，不会越界。
function ThoughtPopupWidget:_estimateViewportH()
    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local chrome = TOP_BORDER_SIZE + 2 * PADDING
    if self.more_text and self.on_more then
        chrome = chrome + Screen:scaleBySize(36) + Screen:scaleBySize(14)
    end
    return math.max(1, ratio_h - chrome)
end

function ThoughtPopupWidget:init()
    self:_clampHeight()

    if Device:isTouchDevice() then
        local range = Geom:new{
            x = 0, y = 0,
            w = Screen:getWidth(),
            h = Screen:getHeight(),
        }
        self.ges_events = {
            TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = range,
                }
            },
            SwipeClose = {
                GestureRange:new{
                    ges = "swipe",
                    range = range,
                }
            },
        }
    end

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end

    self._pages = PageRenderer:new{
        items = self.items,
        doc_font_name = self.doc_font_name,
        doc_font_size = self.doc_font_size,
        doc_margins = self.doc_margins,
        height_ratio = self.height_ratio,
        contrast = self.contrast,
        doc_font_weight = self.doc_font_weight,
        doc_font_gamma = self.doc_font_gamma,
        pic_dir = self.pic_dir,
        estimate_viewport_h = self:_estimateViewportH(),
    }
    self._pages:ensureLayout()
    self:_buildLayout()
end

function ThoughtPopupWidget:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.container.dimen
    end)
end

function ThoughtPopupWidget:_reopen(opts)
    -- 续拉重开（opts.restore_scroll=true）才恢复滚动位置；
    -- 点新段落重开时不带该标记，避免弹窗一打开就停在旧滚动位置
    if opts.restore_scroll and self._scroll_container then
        self._restore_offset = self._scroll_container.scroll_offset or 0
    else
        self._restore_offset = nil
    end
    self._more_busy = false
    self.items = opts.items or {}
    if opts.doc_font_name then self.doc_font_name = opts.doc_font_name end
    if opts.doc_font_size then self.doc_font_size = opts.doc_font_size end
    if opts.doc_margins then self.doc_margins = opts.doc_margins end
    if opts.height_ratio then self.height_ratio = opts.height_ratio end
    if opts.contrast ~= nil then self.contrast = opts.contrast end
    if opts.doc_font_weight ~= nil then self.doc_font_weight = opts.doc_font_weight end
    if opts.doc_font_gamma ~= nil then self.doc_font_gamma = opts.doc_font_gamma end
    if opts.dialog then self.dialog = opts.dialog end
    self.close_callback = opts.close_callback
    self.para_nav = opts.para_nav
    self.more_text = opts.more_text
    self.on_more = opts.on_more
    self.on_replies = opts.on_replies
    self:_clampHeight()

    -- 配图：目录可能随书变化（切段落不变，切书会重开）。fetch_pic 一直沿用。
    -- 换了书就得作废在跑的队列：旧任务会把图写进旧书的目录，白耗流量，
    -- 而且新书目录的 _pendingImageUrls 会因 inflight 标记把同名任务挡掉。
    if opts.pic_dir and self.pic_dir and opts.pic_dir ~= self.pic_dir then
        self._img_gen = (self._img_gen or 0) + 1
        self._img_queue = {}
        self._img_inflight = {}
        self._img_running = false
    end
    if opts.pic_dir then self.pic_dir = opts.pic_dir end
    if opts.fetch_pic then self.fetch_pic = opts.fetch_pic end
    self._pages.pic_dir = self.pic_dir
    self._pages.estimate_viewport_h = self:_estimateViewportH()

    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.contrast,
        self.doc_font_weight, self.doc_font_gamma)
    self:_buildLayout()
end

function ThoughtPopupWidget:_buildLayout()
    self:clear()

    -- 「真的画过图」计数归零：它挂在 PageRenderer 上、而弹窗是池化复用的。
    -- 但归零前要把「本次弹窗会话画过图」记下来：点另一段的段评走的是 _reopen
    -- （同一个 widget、不关窗），新段落可能没有图，计数一归零，关窗时就判不出
    -- 「刚才那屏图需要全刷」，残影会留在阅读区。会话标记只在关窗时清。
    if (tonumber(self._pages._drawn_images) or 0) > 0 then
        self._had_images_session = true
    end
    self._pages._drawn_images = 0

    local item_width = math.min(math.ceil(self.doc_margins.right * 2 / 5), Screen:scaleBySize(10))
    local text_w = self._pages.text_w
    local content_h = self._pages.content_h

    local ratio_h = math.floor(Screen:getHeight() * self.height_ratio)
    local chrome = TOP_BORDER_SIZE + 2 * PADDING

    -- 「继续加载」按钮：先建好并量高度，把占的纵向空间一起计进 chrome，
    -- 否则视口会把按钮挤出屏幕
    local more_btn
    if self.more_text and self.on_more then
        local Button = require("ui/widget/button")
        more_btn = Button:new{
            text = self.more_text,
            width = self.width - Screen:scaleBySize(24),  -- 铺满（左右各留 12px 边距）
            text_font_bold = false,
            callback = function()
                if self._more_busy then return end
                self._more_busy = true
                self.on_more()
            end,
        }
        local ok_size, btn_size = pcall(function() return more_btn:getSize() end)
        local btn_h = (ok_size and btn_size and btn_size.h) or Screen:scaleBySize(36)
        chrome = chrome + btn_h + Screen:scaleBySize(14)
    end
    -- 布局诊断（仅 DEBUG 级，需开启 developer_logs）
    if Log and Log.debug then
        Log.debug(string.format("[段评] 布局 btn=%s ratio_h=%d content_h=%d chrome=%d",
            tostring(more_btn ~= nil), ratio_h, content_h, chrome))
    end
    local blank_tolerance = math.ceil((self.doc_font_size or Screen:scaleBySize(18)) * 1.2)

    local viewport_h
    if content_h + chrome <= ratio_h - blank_tolerance then
        viewport_h = content_h
        self.height = content_h + chrome
    else
        viewport_h = ratio_h - chrome
        self.height = ratio_h
    end
    if viewport_h < 1 then viewport_h = 1 end

    local scroll = ScrollContainer:new{
        content_h = content_h,
        viewport_h = viewport_h,
        scrollbar_w = item_width,
        margin_left = self.doc_margins.left,
        text_w = text_w,
        dialog = self,
        -- 续拉重开时恢复滚动位置（init 内会按新的 max_offset 自动钳制）
        scroll_offset = self._restore_offset or 0,
        boundaries = self._pages.boundaries,
        page_bb_getter = function(page_idx)
            local pages = self._scroll_container and self._scroll_container.pages
            return self._pages:renderPage(page_idx, pages)
        end,
    }
    self._scroll_container = scroll
    self._restore_offset = nil

    local vgroup_children = {
        LineWidget:new{
            dimen = Geom:new{ w = self.width, h = TOP_BORDER_SIZE },
        },
        VerticalSpan:new{ width = PADDING },
        scroll,
        VerticalSpan:new{ width = PADDING },
    }

    if more_btn then
        table.insert(vgroup_children, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        table.insert(vgroup_children, more_btn)
        table.insert(vgroup_children, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    end

    local vgroup = VerticalGroup:new(vgroup_children)

    self.container = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        margin = 0,
        padding = 0,
        vgroup,
    }

    self[1] = BottomContainer:new{
        dimen = Screen:getSize(),
        self.container
    }

    -- 布局就绪后再拉图：首屏文字已经能画了，图片是「陆续填充」。
    self:_startImageDownloads()
end

--- 本段评里所有配图（去重）。只返回还没落盘的。
--- ⚠️ 二级回复里的图也算：回复展开时它们才进入 items，而预下载队列
--- 以前只扫一级评论的 item.pics，导致回复配图**根本不会自动下载**，
--- 必须点一下才触发（点击走 _handleImageAction 的 refetch）。表现就是
--- 「回复里的图一直占位、点了才出来」。
function ThoughtPopupWidget:_pendingImageUrls()
    if not self.pic_dir or not ok_ReviewPics then return {} end
    local seen, out = {}, {}
    local function take(pics)
        if type(pics) ~= "table" then return end
        for _, p in ipairs(pics) do
            local url = p and p.url
            if type(url) == "string" and url ~= "" and not seen[url] then
                seen[url] = true
                local name = ReviewPics.filename(url)
                -- filename 拿不到（异常 url）就整条跳过：拼出的 path 会退化成
                -- 目录本身，file_exists(目录) 若为真就永远不进队列，
                -- 若为假则每次重建都重试一次必然失败的下载
                local path = name and (self.pic_dir .. "/" .. name)
                if path and not ReviewPics.file_exists(path) then
                    -- url 作去重与缓存名，fetch 才是真正下载地址
                    out[#out + 1] = { url = url, fetch = p.fetch or url, path = path }
                end
            end
        end
    end
    for _, item in ipairs(self.items or {}) do
        take(item.pics)
        -- 回复只有展开后才有数据；展开会重建布局并再次调用本函数，
        -- 所以这里按「已拿到的回复」扫一遍即可（未展开时是空表）。
        if type(item.replies) == "table" then
            for _, r in ipairs(item.replies) do
                take(r and r.pics)
            end
        end
    end
    return out
end

--- 串行下载未缓存的配图（并发几十张会把弱网和内存都拖死）。
-- 每张下完清一次页面位图缓存 + 局部刷新，滚动位置不变。
--
-- ⚠️ 队列是**常驻**的，跨布局重建（展开回复 / 继续加载 / 切段落）延续，
-- 不再每次 `_buildLayout` 就 ++gen 从头重扫。原因不是省事：
--   旧队列的 Async 子进程不会因为 gen 变了就被取消，而 fetch_pic 是直接
--   `io.open(path,"wb")` 写目标文件（非原子）。若重建后新队列对同一张
--   「还没落盘」的图再发一次，两个子进程就同写一个文件，可能留下半截
--   位图 —— 而半截图 file_exists 为真，模型层会当成「已缓存」永远不再重下，
--   表现是这张图永久停在占位框。
-- 现在只把「新出现且不在下载中」的任务追加进队列，同一 url 永不同时两份。
function ThoughtPopupWidget:_startImageDownloads()
    if not self.pic_dir or type(self.fetch_pic) ~= "function" then return end
    self._img_queue = self._img_queue or {}
    self._img_inflight = self._img_inflight or {}

    local added = 0
    for _, job in ipairs(self:_pendingImageUrls()) do
        if not self._img_inflight[job.url] then
            self._img_inflight[job.url] = true
            self._img_queue[#self._img_queue + 1] = job
            added = added + 1
        end
    end
    -- 只有真加了任务才出声：用来在设备日志里区分「增量补队」和「重复重下」
    if added > 0 and Log and Log.info then
        Log.info("[段评] 配图排队 +%d，待下 %d", added, #self._img_queue)
    end
    if self._img_running or #self._img_queue == 0 then return end

    self._img_running = true
    local widget = self
    -- gen 只在关窗时变（见 onCloseWidget），代表「这个弹窗会话还活着」
    local gen = self._img_gen

    local function step()
        if gen ~= widget._img_gen then
            -- 弹窗已关闭：丢掉剩余任务，下次打开会重新扫（已落盘的不会再下）
            widget._img_queue = {}
            widget._img_inflight = {}
            widget._img_running = false
            return
        end
        local job = table.remove(widget._img_queue, 1)
        if not job then
            widget._img_running = false
            return
        end
        local finished = false
        local function done(ok)
            if finished then return end
            finished = true
            -- 先清在飞标记：这张（无论成败）已经不再是「下载中」，
            -- 下一轮重建可以重新排它重试，不会被 inflight 永久挡住
            widget._img_inflight[job.url] = nil
            if gen ~= widget._img_gen then return end
            if ok then
                widget._pages:invalidateImage(job.url)
                widget:_queueImageRefresh()
            end
            -- 无论成败都继续下一张：一张坏图不该挡住后面的
            step()
        end
        local ok_call = pcall(self.fetch_pic, job.fetch or job.url, job.path, done)
        if not ok_call then
            self._pages:invalidateImage(job.url)
            done(false)
        end
    end
    step()
end

--- 图片落盘后重画：页面位图里烤的是旧占位框，必须清掉再让它重绘。
--- 用 "ui" 而非 "partial"：弹窗是盖在 ReaderUI 上的 UI 元素，partial 会计入
--- flashing promotion（每 N 次提升为 flashui 闪白），在 REAGL 设备上还会被
--- 强制成全屏 FULL 更新 —— 表现就是上方正文像蒙了一层白纱。
function ThoughtPopupWidget:_refreshImageArea()
    if not self._scroll_container then return end
    self._pages:_freePageBBs()
    UIManager:setDirty(self, function()
        return "ui", self._scroll_container.dimen
    end)
end

--- 批量下载时的合并刷新：串行队列里每下一张都整页清缓存重绘，十几张就是
--- 十几次全量重排（电纸书上很贵）。这里把同一窗口内的完成事件攒一次，
--- 最多每 0.35s 重绘一回；点图单独下载时仍走 _refreshImageArea 立即生效。
function ThoughtPopupWidget:_queueImageRefresh()
    if self._img_refresh_pending then return end
    self._img_refresh_pending = true
    local widget = self
    -- 定时器不会随弹窗关闭取消：0.35s 后弹窗可能已经不在窗口栈上，
    -- 再 setDirty 它只是白发一次刷新（严重时容器已被 clear）。
    -- 用 gen 判断这次 flush 是否还属于同一个弹窗会话。
    local gen = self._img_gen
    local function flush()
        widget._img_refresh_pending = false
        if gen ~= widget._img_gen then return end
        if widget._scroll_container then widget:_refreshImageArea() end
    end
    local ok = pcall(function() UIManager:scheduleIn(0.35, flush) end)
    if not ok then flush() end
end

function ThoughtPopupWidget:onCloseWidget()
    -- 关窗即停下载：队列是常驻的（跨布局重建延续），不在这里作废的话，
    -- 关掉弹窗后还会把这一段的几十张图全部在后台下完，每张还 setDirty 一次
    -- 已经不在窗口栈上的 widget。切段落走的是 _reopen，不需要靠关窗保活。
    self._img_gen = (self._img_gen or 0) + 1
    self._img_queue = {}
    self._img_inflight = {}
    self._img_running = false
    self._img_refresh_pending = false

    -- 有图：整屏全刷。图片是大面积深色块，连「区域内 full」都擦不干净，
    --       关窗后上方正文会留残影 / 发灰。
    -- 纯文字：仍给一条「弹窗矩形的 ui 刷新」。这不是多余的一次 ——
    --       UIManager:close() 自己不排刷新（setDirty 不带模式会直接丢弃），
    --       _repaint 里 dirty 却无刷新入队时，会兜底执行一次
    --       `_refresh("partial")`，那是**整屏** partial：在 Kindle 的 REAGL
    --       波形上正是「正文像蒙了层白纱」的来源。给它一条 ui 区域刷新，
    --       既把弹窗那块重画掉，又不会让整屏正文被洗一遍。
    local had_images = self._had_images_session
        or (self._pages and (tonumber(self._pages._drawn_images) or 0) > 0)
    -- 会话结束：标记归零，池化复用时下一次开窗从「纯文字」算起
    self._had_images_session = nil
    if had_images then
        UIManager:setDirty(nil, "full")
    else
        UIManager:setDirty(self, function()
            return "ui", self.container.dimen
        end)
    end
    if self.close_callback then
        local callback = self.close_callback
        self.close_callback = nil
        callback(self.height)
    end
end

function ThoughtPopupWidget:onClose()
    UIManager:close(self)
    return true
end

function ThoughtPopupWidget:onTapClose(_, ges)
    -- Tap outside the bottom bar closes the popup.
    if ges.pos:notIntersectWith(self.container.dimen) then
        UIManager:close(self)
        return true
    end
    -- 只有「展开/收起/继续加载」这几行和图片块会拦截点击；未命中就什么都不做
    local scroll = self._scroll_container
    if scroll and scroll.dimen and ges.pos:intersectWith(scroll.dimen) then
        local content_x = (ges.pos.x - scroll.dimen.x) - (scroll.margin_left or 0)
        local content_y = (ges.pos.y - scroll.dimen.y) + (scroll.scroll_offset or 0)
        local piece = self:_findActionPieceAtContentY(content_y)
        if piece then
            if piece.action == "open_image" then
                self:_handleImageAction(piece, content_x, content_y)
                return true
            end
            if self:_handleReplyAction(piece) then
                return true
            end
        end
    end
    return true
end

function ThoughtPopupWidget:onSwipeClose(_, ges)
    local BD = require("ui/bidi")
    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
    if direction == "west" or direction == "east" then
        if self.para_nav then
            -- fanqie: horizontal swipe navigates to an adjacent paragraph.
            self.para_nav(direction == "east" and "prev" or "next")
        else
            UIManager:close(self)
        end
        return true
    end
    if ges.pos:intersectWith(self.container.dimen) then
        return true
    end
    return false
end

--- 命中测试：只找带 action 的行（展开/收起/继续加载回复）。
--- 返回 piece（含 action / item_index）。
function ThoughtPopupWidget:_findActionPieceAtContentY(y)
    local pieces = self._pages and self._pages.layout and self._pages.layout.pieces
    if not pieces then return nil end
    for _, piece in ipairs(pieces) do
        if piece.action and piece.y and piece.piece_h
            and piece.y <= y and y < piece.y + piece.piece_h then
            return piece
        end
    end
    return nil
end

--- 重新分页并重建布局，保留当前滚动位置。
--- 展开/收起回复会改变内容高度，必须整体重排（缓存 key 里带了回复状态）。
function ThoughtPopupWidget:_refreshAfterReplyChange()
    local offset = (self._scroll_container and self._scroll_container.scroll_offset) or 0
    self._restore_offset = offset
    self._pages:setContent(self.items, self.doc_font_name, self.doc_font_size,
        self.doc_margins, self.height_ratio, self.contrast,
        self.doc_font_weight, self.doc_font_gamma)
    self:_buildLayout()
    UIManager:setDirty(self, function()
        return "ui", self.container.dimen
    end)
end

--- 点击配图：已缓存 → 交给 KOReader 的 ImageViewer 全屏看原图（它会全刷，
--- 残影留在查看器层面解决）；未缓存 → 就地触发一次下载，不弹错误框打断阅读。
function ThoughtPopupWidget:_handleImageAction(piece, content_x, content_y)
    local lay = piece.layout
    if not lay or not lay.cells then return end
    local pics = piece.pics or {}
    local rel_y = (content_y or 0) - (piece.y or 0)
    -- cell.x 是块内相对坐标；回复里的图块整体缩进 piece.x，命中要减掉
    local rel_x = (content_x or 0) - (piece.x or 0)
    local idx
    for i = 1, #lay.cells do
        local cell = lay.cells[i]
        if pics[i] and rel_x >= cell.x and rel_x < cell.x + cell.w
            and rel_y >= cell.y and rel_y < cell.y + cell.h then
            idx = i
            break
        end
    end
    if not idx then idx = 1 end
    local pic = pics[idx]
    if not pic then return end
    if not ok_ReviewPics then return end
    local name = ReviewPics.filename(pic.url)
    local path = (self.pic_dir and name) and (self.pic_dir .. "/" .. name) or nil

    local function refetch()
        if not (path and type(self.fetch_pic) == "function") then return end
        -- 队列已在下载同一张：等它跑完自己会刷新，别再起一份并发写同一文件
        if self._img_inflight and self._img_inflight[pic.url] then return end
        -- 下载用 fetch（HEIC 已换成转码后的 WebP 地址），缓存名仍用稳定 url
        pcall(self.fetch_pic, pic.fetch or pic.url, path, function(ok)
            if ok then
                self._pages:invalidateImage(pic.url)
                self:_refreshImageArea()
            end
        end)
    end

    -- 0 字节是下载被中断留下的残骸：留着也解不出图，删掉重下一次
    if path and ReviewPics.file_exists(path) then
        local f = io.open(path, "rb")
        local size = 0
        if f then
            size = f:seek("end") or 0
            f:close()
        end
        if size <= 0 then
            pcall(os.remove, path)
            refetch()
            if Log and Log.info then Log.info("[段评] 配图是 0 字节残骸，已删除重下") end
            return
        end
    end

    if not (path and ReviewPics.file_exists(path)) then
        refetch()
        if Log and Log.info then Log.info("[段评] 图片尚未缓存，已触发下载") end
        return
    end

    -- 注意：ImageViewer 的 image 形参要的是 BlitBuffer，文件路径必须给 file。
    -- 传 image = path 会让 ImageWidget 把字符串当位图（_bb = image），
    -- 随后 _render/getSize 里 _bb:getWidth() 抛"attempt to call method
    -- 'getWidth' (a nil value)"，崩在 UIManager 重绘阶段 —— 是整个 KOReader
    -- 挂掉，插件侧连 pcall 都接不住。
    local ok, viewer = pcall(function()
        return require("ui/widget/imageviewer"):new{ file = path, fullscreen = true }
    end)
    if ok and viewer then
        UIManager:show(viewer)
    elseif Log and Log.warn then
        Log.warn("[段评] ImageViewer 打开失败")
    end
end

function ThoughtPopupWidget:_handleReplyAction(piece)
    local item = self.items and self.items[tonumber(piece.item_index) or 0]
    if not item or not self.on_replies then return false end

    if piece.action == "toggle_replies" then
        if item.replies_loading then return true end
        if item.replies_expanded then
            item.replies_expanded = false
            self:_refreshAfterReplyChange()
            return true
        end
        if type(item.replies) == "table" and #item.replies > 0 then
            item.replies_expanded = true
            self:_refreshAfterReplyChange()
            return true
        end
        -- 首次展开：先把「正在加载」显示出来，再去拉数据，避免点了没反应
        item.replies_expanded = true
        item.replies_loading = true
        self:_refreshAfterReplyChange()
        self:_fetchReplies(item, nil)
        return true
    end

    if piece.action == "more_replies" then
        if item.replies_loading then return true end
        item.replies_loading = true
        self:_refreshAfterReplyChange()
        self:_fetchReplies(item, item.replies_cursor)
        return true
    end

    return false
end

function ThoughtPopupWidget:_fetchReplies(item, cursor)
    local widget = self
    local function done(ok, result, err)
        item.replies_loading = false
        if ok and type(result) == "table" and type(result.replies) == "table" then
            item.replies = item.replies or {}
            for _, r in ipairs(result.replies) do
                item.replies[#item.replies + 1] = _attachReplyPics(r)
            end
            item.replies_total = tonumber(result.total) or #item.replies
            item.replies_more = result.has_more == true
            item.replies_cursor = result.cursor
            item.replies_expanded = true
            if (tonumber(item.reply_count) or 0) < (tonumber(item.replies_total) or 0) then
                item.reply_count = item.replies_total
            end
        else
            -- 拉失败就收起，不留一个"展开中"的空壳；下次点会重新请求
            item.replies_expanded = false
            local reason = tostring(err or result or "未知原因")
            item.replies_error = reason
            -- 具体原因一并显示：「可能被风控」「HTTP 4xx」「返回为空」这类
            -- 信息直接决定用户该重试还是该换节点，藏在日志里等于没给。
            local brief = reason:gsub("%s+", " ")
            if #brief > 60 then brief = brief:sub(1, 60) .. "…" end
            pcall(function()
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = "回复加载失败：" .. brief,
                })
            end)
            if Log and Log.warn then
                pcall(Log.warn, "[段评] 回复加载失败: " .. reason)
            end
        end
        widget:_refreshAfterReplyChange()
    end

    local ok_call = pcall(self.on_replies, item, cursor, done)
    if not ok_call then
        item.replies_loading = false
        item.replies_expanded = false
        self:_refreshAfterReplyChange()
    end
end

function ThoughtPopupWidget:free(full)
    WidgetContainer.free(self, full)
end

function ThoughtPopupWidget:_freeContentCaches()
    self._pages:freeContentCaches()
end

return ThoughtPopupWidget
