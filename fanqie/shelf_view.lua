local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")

local Screen = Device.screen

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local function status_text(book)
    local progress = tonumber(book.progress or 0) or 0
    if progress >= 1 then return _("已读完") end
    local read_chapters = tonumber(book.read_chapters or 0) or 0
    local total_chapters = tonumber(book.total_chapters or 0) or 0
    if total_chapters > 0 and read_chapters > 0 then
        return string.format(_("%d/%d章"), read_chapters, total_chapters)
    elseif progress > 0 then
        return string.format(_("%.1f%%"), progress * 100)
    end
    return _("未开始")
end

-- ---- 封面网格布局：比例 0.68 / gutter 6 / 阴影 3 / 圆角 5 / 标题行 22 / 副行 16 ----

local GRID_COLS = 4
local GRID_ROWS = 3

-- 弱化色（第二行进度文字 / 阴影）。Blitbuffer.gray 是核心 API，但个别构建可能缺失，
-- 安全兜底避免首屏崩溃。
local function dim_color()
    local ok, v = pcall(function() return Blitbuffer.gray(0.5) end)
    if ok and v then return v end
    return Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_BLACK
end

local function shelfSizeScale()
    return Screen:scaleBySize(1000) / 1000
end

local function cellCardMetrics(cell_w, cell_h)
    local size_scale = shelfSizeScale()
    local gutter = math.max(1, math.floor(6 * size_scale))
    local shadow = math.max(1, math.floor(3 * size_scale))
    local title_gap = math.max(1, math.floor(4 * size_scale))
    local title_h = math.max(1, math.floor(22 * size_scale))
    local sub_gap = math.max(1, math.floor(2 * size_scale))
    local sub_h = math.max(1, math.floor(16 * size_scale))
    local border = Size.border.thin
    local max_cw = math.max(1, cell_w - 2 * gutter)
    local max_ch = math.max(1, cell_h - 2 * gutter - title_gap - title_h - sub_gap - sub_h)
    -- 封面约为 2:3 竖版，卡片锁定同一比例避免四周留白
    local aspect = 0.68
    local card_w, card_h
    if max_cw / max_ch > aspect then
        card_h = max_ch
        card_w = math.max(1, math.floor(card_h * aspect))
    else
        card_w = max_cw
        card_h = math.max(1, math.floor(card_w / aspect))
    end
    local radius = math.min(math.max(2, math.floor(5 * size_scale)),
        math.floor(math.min(card_w, card_h) / 2))
    return {
        gutter = gutter,
        shadow = shadow,
        title_gap = title_gap,
        title_h = title_h,
        sub_gap = sub_gap,
        sub_h = sub_h,
        border = border,
        card_w = card_w,
        card_h = card_h,
        cover_w = card_w + shadow,
        cover_h = card_h + shadow,
        radius = radius,
    }
end

-- ---- 圆角封面卡与阴影 ----

local function inside_rounded_rect(px, py, width, height, radius)
    if px < 0 or py < 0 or px >= width or py >= height then return false end
    if radius <= 0 then return true end
    local center_x, center_y
    if px < radius and py < radius then
        center_x, center_y = radius, radius
    elseif px >= width - radius and py < radius then
        center_x, center_y = width - radius - 1, radius
    elseif px < radius and py >= height - radius then
        center_x, center_y = radius, height - radius - 1
    elseif px >= width - radius and py >= height - radius then
        center_x, center_y = width - radius - 1, height - radius - 1
    else
        return true
    end
    local delta_x, delta_y = px - center_x, py - center_y
    return delta_x * delta_x + delta_y * delta_y <= radius * radius
end

local CoverShadow = Widget:extend{
    width = 1,
    height = 1,
    radius = 1,
}

function CoverShadow:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(1, math.floor(tonumber(self.radius) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function CoverShadow:paintTo(bb, x, y)
    bb:paintRoundedRect(x, y, self.width, self.height, dim_color(), self.radius)
end

-- FrameContainer 不会把子控件裁剪进圆角，这里手动把四角遮回背景色
local RoundedCoverCard = Widget:extend{
    inner = nil,
    width = 1,
    height = 1,
    radius = 0,
    border_size = 0,
    shadow_offset = 0,
    shadow_color = nil,
}

function RoundedCoverCard:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.radius = math.max(0, math.floor(tonumber(self.radius) or 0))
    self.border_size = math.max(0, math.floor(tonumber(self.border_size) or 0))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function RoundedCoverCard:free(...)
    if self.inner and self.inner.free then self.inner:free(...) end
end

RoundedCoverCard.onCloseWidget = RoundedCoverCard.free

function RoundedCoverCard:_masked_corner_color(px, py)
    if self.shadow_color
        and inside_rounded_rect(px - self.shadow_offset, py - self.shadow_offset,
            self.width, self.height, self.radius) then
        return self.shadow_color
    end
    return Blitbuffer.COLOR_WHITE
end

function RoundedCoverCard:paintTo(bb, x, y)
    if self.inner then self.inner:paintTo(bb, x + self.border_size, y + self.border_size) end
    local radius = self.radius
    if radius > 0 then
        for dy = 0, radius - 1 do
            for dx = 0, radius - 1 do
                local corners = {
                    { dx, dy },
                    { self.width - 1 - dx, dy },
                    { dx, self.height - 1 - dy },
                    { self.width - 1 - dx, self.height - 1 - dy },
                }
                for _, point in ipairs(corners) do
                    if not inside_rounded_rect(point[1], point[2], self.width, self.height, radius) then
                        bb:paintRect(x + point[1], y + point[2], 1, 1,
                            self:_masked_corner_color(point[1], point[2]))
                    end
                end
            end
        end
    end
    if self.border_size > 0 then
        bb:paintBorder(x, y, self.width, self.height, self.border_size,
            Blitbuffer.COLOR_BLACK, radius, true)
    end
end

-- 固定测量宽度的左对齐文字行
local LeftAlignedText = Widget:extend{
    width = 1,
    height = 1,
    content = nil,
}

function LeftAlignedText:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function LeftAlignedText:paintTo(bb, x, y)
    local content_size = self.content:getSize()
    self.content:paintTo(bb, x, y + math.floor((self.height - content_size.h) / 2))
end

function LeftAlignedText:free(...)
    if self.content and self.content.free then self.content:free(...) end
end

LeftAlignedText.onCloseWidget = LeftAlignedText.free

-- 网格空位格。HorizontalGroup 要求子项实现 getSize()；不能用"空 FrameContainer"占位
-- （其 getSize 会索引 nil 子项直接崩，crash.log: framecontainer.lua:55）。
local BlankCell = Widget:extend{
    width = 1,
    height = 1,
}

function BlankCell:init()
    self.width = math.max(1, math.floor(tonumber(self.width) or 1))
    self.height = math.max(1, math.floor(tonumber(self.height) or 1))
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
end

function BlankCell:getSize()
    return self.dimen
end

function BlankCell:paintTo(bb, x, y)
    bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
end

-- ---- 封面网格条目（竖排：圆角封面卡+阴影在上，标题 + 进度在下） ----

local ShelfItem = InputContainer:extend{
    entry = nil,
    menu = nil,
    dimen = nil,
}

function ShelfItem:init()
    self.ges_events = {
        TapSelect = {GestureRange:new{ges="tap", range=self.dimen}},
        HoldSelect = {GestureRange:new{ges="hold", range=self.dimen}},
    }

    local w, h = self.dimen.w, self.dimen.h
    local m = cellCardMetrics(w, h)

    -- 封面卡：OverlapGroup 叠加「右下偏移的圆角阴影 + 圆角封面卡」
    local inner_w = math.max(1, m.card_w - 2 * m.border)
    local inner_h = math.max(1, m.card_h - 2 * m.border)
    local inner
    if self.entry.show_cover ~= false and self.entry.cover_path then
        inner = ImageWidget:new{
            file = self.entry.cover_path,
            width = inner_w,
            height = inner_h,
            -- 不设 scale_factor：直接拉伸到目标尺寸（填满，无留白；轻微变形可接受）
            file_do_cache = false,
        }
    else
        inner = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            TextBoxWidget:new{
                text = _("无封面"),
                width = math.max(1, inner_w - 12),
                alignment = "center",
                face = Font:getFace("smallinfofont", 16),
            },
        }
    end
    local cover = OverlapGroup:new{
        dimen = Geom:new{ w = m.cover_w, h = m.cover_h },
    }
    if m.shadow > 0 then
        local shadow = CoverShadow:new{
            width = m.card_w,
            height = m.card_h,
            radius = m.radius,
        }
        shadow.overlap_offset = { m.shadow, m.shadow }
        table.insert(cover, shadow)
    end
    table.insert(cover, RoundedCoverCard:new{
        inner = inner,
        width = m.card_w,
        height = m.card_h,
        radius = m.radius,
        border_size = m.border,
        shadow_offset = m.shadow,
        shadow_color = (m.shadow > 0) and dim_color() or nil,
    })

    -- 第一行：书名，单行展示（超宽截断），左对齐
    local title_widget = TextWidget:new{
        text = tostring(self.entry.title or _("未命名")),
        face = Font:getFace("cfont", 15),
        max_width = m.cover_w,
    }
    -- 第二行：进度「x/y章」弱化色
    local sub_widget = TextWidget:new{
        text = tostring(self.entry.status or ""),
        face = Font:getFace("smallinfofont", 13),
        fgcolor = dim_color(),
        max_width = m.cover_w,
    }

    local column = VerticalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = m.cover_w, h = m.cover_h },
            cover,
        },
        VerticalSpan:new{ width = m.title_gap },
        LeftAlignedText:new{ width = m.cover_w, height = m.title_h, content = title_widget },
        VerticalSpan:new{ width = m.sub_gap },
        LeftAlignedText:new{ width = m.cover_w, height = m.sub_h, content = sub_widget },
    }
    self[1] = FrameContainer:new{
        width = w,
        height = h,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{w = w, h = h},
            column,
        },
    }
end

function ShelfItem:onTapSelect(arg, ges)
    self.menu:onMenuSelect(self.entry)
    return true
end

function ShelfItem:onHoldSelect()
    if self.entry and self.entry.hold_callback then self.entry.hold_callback() end
    return true
end

local ShelfMenu = Menu:extend{
    on_page_changed = nil,
    on_close_callback = nil,
    _miu_closed = false,
    _suppress_page_callback = false,
}

-- 左上角按钮：弹出操作菜单（与目录界面一致，图标为 appbar.menu 三横杠）
function ShelfMenu:onLeftButtonTap()
    if not self._on_refresh then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local action_dialog
    action_dialog = ButtonDialog:new{
        title = _("书架操作"),
        title_align = "center",
        buttons = {
            {{
                text = _("刷新书架"),
                callback = function()
                    UIManager:close(action_dialog)
                    self._on_refresh()
                end,
            }},
            {{
                text = _("关闭"),
                callback = function()
                    UIManager:close(action_dialog)
                end,
            }},
        },
    }
    UIManager:show(action_dialog)
end

function ShelfMenu:onMenuSelect(entry, pos)
    return Menu.onMenuSelect(self, entry)
end

-- 网格布局：每页 GRID_COLS x GRID_ROWS 个封面卡。
-- 可用总高 = item_dimen.h * perpage（Menu 以此反推每页条数），cell_h = 可用总高 / 行数
function ShelfMenu:updateItems(select_number, no_recalculate_dimen)
    local old_dimen = self.dimen and self.dimen:copy()
    self.layout = {}
    self.item_group:clear()
    self.page_info:resetLayout()
    self.return_button:resetLayout()
    self.content_group:resetLayout()
    Menu._recalculateDimen(self, no_recalculate_dimen)
    local cell_w = math.max(1, math.floor(self.item_dimen.w / GRID_COLS))
    local cell_h = math.max(1, math.floor(self.item_dimen.h * self.perpage / GRID_ROWS))
    local offset = (self.page - 1) * self.perpage
    local index_on_page = 0
    for row = 1, GRID_ROWS do
        local line = HorizontalGroup:new{ align = "center" }
        local line_cells = {}
        for col = 1, GRID_COLS do
            index_on_page = index_on_page + 1
            local index = offset + index_on_page
            local entry = self.item_table[index]
            if entry then
                entry.idx = index
                if index == self.itemnumber then select_number = index_on_page end
                local item = ShelfItem:new{
                    entry = entry,
                    menu = self,
                    dimen = Geom:new{x=0, y=0, w=cell_w, h=cell_h},
                }
                table.insert(line, item)
                table.insert(line_cells, item)
            else
                table.insert(line, BlankCell:new{ width = cell_w, height = cell_h })
            end
        end
        table.insert(self.item_group, line)
        table.insert(self.layout, line_cells)
    end
    self:updatePageInfo(select_number)
    self:mergeTitleBarIntoLayout()
    UIManager:setDirty(self.show_parent, function()
        return "ui", old_dimen and old_dimen:combine(self.dimen) or self.dimen
    end)
    if not self._suppress_page_callback and not self._miu_closed and self.on_page_changed then
        local page = tonumber(self.page) or 1
        local first = (page - 1) * self.perpage + 1
        local last = math.min(#self.item_table, first + self.perpage - 1)
        UIManager:scheduleIn(0, function()
            if not self._miu_closed and self.on_page_changed then
                pcall(self.on_page_changed, page, first, last, self)
            end
        end)
    end
end

function ShelfMenu:onCloseWidget()
    self._miu_closed = true
    if self.on_close_callback then
        local callback = self.on_close_callback
        self.on_close_callback = nil
        pcall(callback, self)
    end
    if Menu.onCloseWidget then return Menu.onCloseWidget(self) end
end

local ShelfView = {}

-- 构造 ShelfItem 的 items 列表（show 和 update 复用）
local function build_items(books, opts)
    local items = {}
    for _, book in ipairs(books or {}) do
        items[#items + 1] = {
            book_id = book.book_id or book.bookId,
            title = book.title,
            author = book.author,
            status = status_text(book),
            cover_path = book.cover_path,
            show_cover = opts.show_covers ~= false,
            callback = function() if opts.on_select then opts.on_select(book) end end,
            hold_callback = function() if opts.on_hold then opts.on_hold(book) end end,
        }
    end
    return items
end

function ShelfView.show(opts)
    opts = opts or {}
    local items = build_items(opts.books or {}, opts)
    local page_callback
    if opts.on_page_changed then
        page_callback = function(page, first, last, current)
            if last >= first then
                opts.on_page_changed(page, first, last, current)
            end
        end
    end
    local menu = ShelfMenu:new{
        title = opts.title or _("书架"),
        item_table = items,
        items_per_page = GRID_COLS * GRID_ROWS,
        is_borderless = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        on_close_callback = opts.on_close,
        on_page_changed = page_callback,
    }
    menu._on_refresh = opts.on_refresh
    UIManager:show(menu)
    return menu
end

-- 动态更新书架菜单内容（不关闭重开，避免闪烁）
-- 刷新数据回来后直接 switchItemTable 更新，保持当前页
function ShelfView.update(menu, books, opts)
    if not menu then return end
    opts = opts or {}
    local items = build_items(books or {}, opts)
    -- 保持当前页：switchItemTable 第二参数是 item_number（全局索引），不是 page
    local current_page = menu.page or 1
    local perpage = menu.perpage or (GRID_COLS * GRID_ROWS)
    local item_number = (current_page - 1) * perpage + 1
    if item_number > #items then item_number = 1 end
    menu:switchItemTable(items, item_number, true)
end

return ShelfView
