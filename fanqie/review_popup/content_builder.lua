--[[--
Thought popup content builder.

Normalized review items (weread.lib.annotations records: abstract, author,
content, likes_count) become a widget-independent block tree consumed by
widget.lua:

    { kind="paragraph", variant=<quote|meta|content>, text=..., fg=gray level }

Size variants for each block live in face_factory.lua (VARIANTS); the gray
levels below match the WeRead reader's footnote styling.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local util = require("util")

-- 段评正文里的表情是占位码（[奸笑]/[吃瓜]…），渲染前先换成 emoji。
-- 模块缺失/报错时静默降级为原样文本，绝不能拖垮弹窗。
local ok_emoticon, Emoticon = pcall(require, "fanqie.emoticon")
if not ok_emoticon or type(Emoticon) ~= "table" or not Emoticon.decode then
    Emoticon = nil
end
local function decode(s)
    if type(s) ~= "string" then return s end
    -- 番茄服务端在评论正文里塞 `[图片]` 字面量标记图片位置，但图片本体是走
    -- segments/image_data_list 单独渲染成图片块的。表情解码表没有这一项，
    -- 不过滤就会在文字里露出难看的 `[图片]`（一级、二级都中招）。
    -- 图片块照常显示，这里只清文字里的占位符（连同紧邻的空白）。
    if s:find("[图片]", 1, true) then
        s = s:gsub("%s*%[图片%]%s*", " ")
        s = s:gsub("^%s+", ""):gsub("%s+$", "")
    end
    if not Emoticon then return s end
    local ok, out = pcall(Emoticon.decode, s)
    return (ok and out) or s
end

local ContentBuilder = {}

-- Gray levels used by the popup blocks, indexed 0 (pure black) to 15
-- (lightest). The eInk palette is COLOR_GRAY_1..7 and COLOR_GRAY_9 plus the
-- COLOR_DARK_GRAY / COLOR_GRAY / COLOR_GRAY_B / COLOR_LIGHT_GRAY /
-- COLOR_GRAY_D / COLOR_GRAY_E / COLOR_WHITE aliases; keep the Color8 values
-- (isColor8 only accepts Color8 cdata).
local GRAY_LEVELS = {
    [0] = Blitbuffer.COLOR_BLACK,   --  0 (0x00)
    Blitbuffer.COLOR_GRAY_1,        --  1 (0x11)
    Blitbuffer.COLOR_GRAY_2,        --  2 (0x22)
    Blitbuffer.COLOR_GRAY_3,        --  3 (0x33)
    Blitbuffer.COLOR_GRAY_4,        --  4 (0x44)
    Blitbuffer.COLOR_GRAY_5,        --  5 (0x55)
    Blitbuffer.COLOR_GRAY_6,        --  6 (0x66)
    Blitbuffer.COLOR_GRAY_7,        --  7 (0x77)
    Blitbuffer.COLOR_DARK_GRAY,     --  8 (0x88)
    Blitbuffer.COLOR_GRAY_9,        --  9 (0x99)
    Blitbuffer.COLOR_GRAY,          -- 10 (0xAA)
    Blitbuffer.COLOR_GRAY_B,        -- 11 (0xBB)
    Blitbuffer.COLOR_LIGHT_GRAY,    -- 12 (0xCC)
    Blitbuffer.COLOR_GRAY_D,        -- 13 (0xDD)
    Blitbuffer.COLOR_GRAY_E,        -- 14 (0xEE)
    Blitbuffer.COLOR_WHITE,         -- 15 (0xFF)
}

--- Gray level -> Color8 value, clamped to the palette.
local function grayForLevel(level)
    level = math.max(0, math.min(15, level))
    return GRAY_LEVELS[level] or Blitbuffer.COLOR_GRAY_5
end

--- 阅读器的「对比度」低于标准（gamma < 1.0）时正文不再是纯黑。cre 的 gamma
--- 只作用于 crengine 自己的字形栅格，弹框这套自绘字体读不到，只能在字色上近似；
--- 高于标准则表现为笔画变粗，由 face_factory 的仿粗档位负责。
--- 传入的是**换算后的 gamma 值**（1.0 = 标准），不是设置里的索引。
--- 基准用 1 档(#11)而不是纯黑：同样的字重下，纯黑在墨水屏上比正文更「实」，
--- 略淡一档的观感才和正文齐平。
local BODY_BASE_LEVEL = 1
local function textColorForGamma(gamma)
    local g = tonumber(gamma) or 1
    -- 标准对比度：纯黑，与正文一致（weread 的想法弹窗也是纯黑）。
    if g >= 0.95 then return Blitbuffer.COLOR_BLACK end
    -- 对比度调低时正文笔画变细。弹框这条自建渲染链只能改字色，
    -- 改多了就整片发虚（0.8 就灰成 #33 是明显过头），所以最多淡一档。
    return grayForLevel(BODY_BASE_LEVEL)
end

--- UTF-8-safe truncation with an ellipsis suffix.
--- Character splitting uses koreader util.splitToChars (merges WTF-8 surrogate pairs).
local function truncateRunes(str, max_runes)
    if type(str) ~= "string" or type(max_runes) ~= "number" or max_runes <= 0 then
        return ""
    end
    local chars = util.splitToChars(str)
    if #chars <= max_runes then
        return str
    end
    local parts = {}
    for i = 1, max_runes do
        parts[i] = chars[i]
    end
    return table.concat(parts) .. "…"
end

--- Strip leading/trailing whitespace (including newlines and common Unicode
--- blanks). A trailing newline would add an extra empty line at the end of
--- the paragraph. WeRead data occasionally has \n+ZWNJ / ZWSP+\n / full-width
--- spaces; Lua %s only covers ASCII whitespace. Inner \n\n breaks are kept.
local function isEdgeBlankAt(s, i, len)
    local b = s:byte(i)
    if not b then return false, 0 end
    if b == 0x09 or b == 0x0A or b == 0x0B or b == 0x0C or b == 0x0D or b == 0x20 then
        return true, 1
    end
    if b == 0xC2 and i + 1 <= len and s:byte(i + 1) == 0xA0 then
        return true, 2
    end
    if b == 0xE2 and i + 2 <= len and s:byte(i + 1) == 0x80 then
        local b3 = s:byte(i + 2)
        if b3 == 0x8B or b3 == 0x8C then
            return true, 3
        end
    end
    if b == 0xE3 and i + 2 <= len and s:byte(i + 1) == 0x80 and s:byte(i + 2) == 0x80 then
        return true, 3
    end
    if b == 0xEF and i + 2 <= len and s:byte(i + 1) == 0xBB and s:byte(i + 2) == 0xBF then
        return true, 3
    end
    return false, 0
end

local function trimText(s)
    if type(s) ~= "string" then return s end
    local len = #s
    if len == 0 then return s end
    local start = 1
    while start <= len do
        local blank, n = isEdgeBlankAt(s, start, len)
        if not blank then break end
        start = start + n
    end
    local finish = len
    while finish >= start do
        local i = finish
        while i > start do
            local b = s:byte(i)
            if not b or b < 0x80 or b >= 0xC0 then break end
            i = i - 1
        end
        local blank, n = isEdgeBlankAt(s, i, len)
        if not blank or i + n - 1 ~= finish then break end
        finish = i - 1
    end
    if start == 1 and finish == len then return s end
    if start > finish then return "" end
    return s:sub(start, finish)
end

--- Quote rendering: first paragraph only (with an ellipsis when more
--- paragraphs follow), truncated to 50 runes, wrapped in 「」.
local function buildQuoteText(quote)
    if type(quote) ~= "string" or quote == "" then return nil end
    quote = trimText(quote)
    if quote == "" then return nil end
    local nl = quote:find("[\r\n]")
    if nl then
        local first = quote:sub(1, nl - 1)
        if quote:sub(nl + 1):match("%S") then
            quote = first .. "…"
        else
            quote = first
        end
    end
    local q = truncateRunes(decode(quote), 50)
    return "「" .. q .. "」"
end

--- Build the block list for a thought popup.
--- @param items table[] review items { abstract, author, content, likes_count }
--- @param opts table|nil options table:
---   contrast  number  contrast delta (positive darkens)
---   skip_quote  boolean  omit the quote block (shown in title bar)
--- @return table[] blocks
function ContentBuilder.build(items, opts)
    if type(opts) == "number" then
        opts = { contrast = opts }
    end
    opts = opts or {}
    local blocks = {}
    if type(items) ~= "table" or #items == 0 then
        return blocks
    end
    local text_fg = textColorForGamma(opts.gamma)

    local quote = not opts.skip_quote and buildQuoteText(items[1] and items[1].abstract)
    if quote then
        blocks[#blocks + 1] = {
            kind = "paragraph",
            variant = "quote",
            text = quote,
            fg = text_fg,
        }
    end

    for item_index, item in ipairs(items) do
        -- 一级评论之间加分隔线（与自己的回复树之间、回复彼此之间不加）：
        -- 只有新的一条一级评论开始前才插。间距全交给 separator，
        -- 所以下面 meta 不再设 spacing_before（否则双重叠加显得过松）。
        if item_index > 1 then
            blocks[#blocks + 1] = {
                kind = "separator",
                fg = grayForLevel(10),   -- 灰阶约 #AAA
                spacing_before = 0.54,
                spacing_after = 0.54,
            }
        end
        -- 一级评论的作者行用中点（与点赞数前的分隔点同一个字符），名字前后
        -- 各一个点：`· 张三 · ♥ 2`。下面「▸ 展开 N 条回复」仍用三角：
        -- 两者符号相同会让读者分不清哪行是作者、哪行是可点的开关。
        local meta = "· " .. tostring(item.author or "匿名")
        local likes = tonumber(item.likes_count) or 0
        if likes > 0 then
            meta = meta .. " · ♥ " .. tostring(likes)
        end
        -- meta（作者·赞）是辅助信息：比正文/引文浅一个灰阶，形成层级
        blocks[#blocks + 1] = {
            kind = "paragraph",
            variant = "meta",
            text = meta,
            fg = grayForLevel(5),
            spacing_after = 0.18,
        }

        local content = decode(trimText(item.content or ""))
        if content ~= "" then
            blocks[#blocks + 1] = {
                kind = "paragraph",
                variant = "content",
                text = content,
                fg = text_fg,
            }
        end

        -- 段评配图：纯图评论（无文字）也会走到这里 —— 归一层已放开「必须有文字」
        -- 的判据，否则这类图整个被丢弃。
        if type(item.pics) == "table" and #item.pics > 0 then
            blocks[#blocks + 1] = {
                kind = "image",
                pics = item.pics,
                item_index = item_index,
                spacing_before = 0.2,
                spacing_after = 0.2,
            }
        end

        -- ── 二级评论（官方源）──────────────────────────────────────────
        -- 入口单独占一行且可点。展开后回复按接口顺序平铺，用「回复 @某人」
        -- 表达层级：接口里 sub_reply 恒空，层级只靠 reply_to_reply_id，
        -- 平铺展示不会丢条，也不会无限缩进。
        if item.can_replies and (tonumber(item.reply_count) or 0) > 0 then
            local reply_count = tonumber(item.reply_count) or 0
            local toggle_text
            if item.replies_loading then
                toggle_text = "↳ 正在加载回复…"
            elseif item.replies_expanded then
                toggle_text = "▾ 收起 " .. tostring(reply_count) .. " 条回复"
            else
                toggle_text = "▸ 展开 " .. tostring(reply_count) .. " 条回复"
            end
            -- 加载中不挂 action：piece.action 为空即不可点，避免重复发请求
            local toggle_action = not item.replies_loading and "toggle_replies" or nil
            blocks[#blocks + 1] = {
                kind = "paragraph",
                variant = "reply_toggle",
                text = toggle_text,
                fg = grayForLevel(4),
                spacing_before = 0.18,
                action = toggle_action,
                item_index = item_index,
            }

            if item.replies_expanded and type(item.replies) == "table" then
                for _, reply in ipairs(item.replies) do
                    local name = tostring(reply.user_name or "匿名")
                    local meta = "↳ " .. name
                    local to_name = tostring(reply.reply_to_user_name or "")
                    if to_name ~= "" and to_name ~= name then
                        meta = meta .. " 回复 @" .. to_name
                    end
                    local digg = tonumber(reply.digg_count) or 0
                    if digg > 0 then
                        meta = meta .. " · ♥ " .. tostring(digg)
                    end
                    blocks[#blocks + 1] = {
                        kind = "paragraph",
                        variant = "reply_meta",
                        text = meta,
                        fg = grayForLevel(6),
                        indent_level = 1,
                        spacing_before = 0.12,
                        item_index = item_index,
                    }
                    local rtext = decode(trimText(reply.text or ""))
                    if rtext ~= "" then
                        blocks[#blocks + 1] = {
                            kind = "paragraph",
                            variant = "reply",
                            text = rtext,
                            fg = text_fg,
                            indent_level = 1,
                            item_index = item_index,
                        }
                    end
                    -- 二级回复也可能带图（实测书山内联回复里就有，纯表情+图很常见）。
                    -- 纯图回复 rtext 为空，只有这段能把它显示出来；缩进 1 级与
                    -- 回复正文对齐，宽度同步收窄（见 pages.lua 的 image 分支）。
                    if type(reply.pics) == "table" and #reply.pics > 0 then
                        blocks[#blocks + 1] = {
                            kind = "image",
                            pics = reply.pics,
                            item_index = item_index,
                            indent_level = 1,
                            spacing_before = 0.12,
                            spacing_after = 0.06,
                        }
                    end
                end

                if item.replies_more then
                    local loaded = #item.replies
                    local total = tonumber(item.replies_total) or (tonumber(item.reply_count) or loaded)
                    local left = total - loaded
                    local more_text
                    if left > 0 then
                        more_text = string.format("… 还有 %d 条回复", left)
                    else
                        more_text = "… 继续加载更多回复"
                    end
                    if item.replies_loading then
                        more_text = "… 正在加载更多回复…"
                    end
                    local more_action = not item.replies_loading and "more_replies" or nil
                    blocks[#blocks + 1] = {
                        kind = "paragraph",
                        variant = "reply_toggle",
                        text = more_text,
                        fg = grayForLevel(5),
                        indent_level = 1,
                        spacing_before = 0.12,
                        action = more_action,
                        item_index = item_index,
                    }
                end
            end
        end
    end

    return blocks
end

return ContentBuilder
