local LOG_MODULE = "[FanQie]"

local function safe_require(module_name, required)
    local ok, result = pcall(require, module_name)
    if not ok then
        if required then
            print(LOG_MODULE, "fatal: failed to load required module:", module_name, "-", result)
            return nil, false
        else
            print(LOG_MODULE, "warning: failed to load optional module:", module_name, "-", result)
            return nil, true
        end
    end
    return result, true
end

local WidgetContainer, ok = safe_require("ui/widget/container/widgetcontainer", true)
if not ok then return end

local lfs = safe_require("libs/libkoreader-lfs")

local Dispatcher = safe_require("dispatcher")

local UIManager = safe_require("ui/uimanager")

local InfoMessage = safe_require("ui/widget/infomessage")

local ConfirmBox = safe_require("ui/widget/confirmbox")

local InputDialog = safe_require("ui/widget/inputdialog")

local MultiInputDialog = safe_require("ui/widget/multiinputdialog")

local DataStorage = safe_require("datastorage")

local Menu = safe_require("ui/widget/menu")

local TextViewer = safe_require("ui/widget/textviewer")

local PathChooser = safe_require("ui/widget/pathchooser")

local Event = safe_require("ui/event")

local GestureRange = safe_require("ui/gesturerange")

local logger = safe_require("logger")

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local T_util = safe_require("ffi/util")
local T = T_util and T_util.template or nil

local util = safe_require("util")

-- Local libs
local Settings = safe_require("fanqie.settings")

local Client = safe_require("fanqie.client")

local H = safe_require("fanqie.helper")

local Content = safe_require("fanqie.content")

local DownloadProgress = safe_require("fanqie.download_progress")

local FanQie = safe_require("fanqie.fanqie")

local Log = safe_require("fanqie.logger")

local Patches = safe_require("patches.core")

local Bookshelf = safe_require("fanqie.bookshelf")
local ReaderNavigation = safe_require("fanqie.reader_navigation")

-- 插件元信息（版本号、关于文案）：集中管理，避免多处维护不同步
local Info = safe_require("fanqie.info")

-- 异步子进程模块：把进度上传 / 预下载等阻塞网络操作移出 UI 线程，消除卡顿。
local Async = safe_require("fanqie.async")

local unpack_args = unpack or table.unpack

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function is_auth_error(err)
    return type(err) == "table" and err.auth_expired == true
end

local function display_error(err)
    if is_auth_error(err) then
        return _("登录已过期，请更新 Cookie\n\n请编辑 config.lua 文件，填入最新的 Cookie 值后重新启动插件。")
    end
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

-- Shared state across FileManager and ReaderUI instances
-- (KOReader creates separate WidgetContainer instances for each)
local ok_state, _state = pcall(require, "fanqie.state")
-- fallback_settings_ref 用于在 fallback _state 中也能持久化段评开关
local fallback_settings_ref = nil
if not ok_state then
    _state = {
        current_book = nil,
        current_chapters = nil,
        current_chapter_index = nil,
        current_document_path = nil,
        cached_directory = nil,
        enable_review = false,
        current_para_reviews = {},
        current_para_index = 0,
    }
    function _state.isReviewEnabled() return _state.enable_review == true end
    function _state.setReviewEnabled(v)
        _state.enable_review = v == true
        if fallback_settings_ref then
            pcall(function() fallback_settings_ref:setParaReviewEnabled(_state.enable_review) end)
        end
    end
    function _state.loadReviewState(settings)
        if not settings then return end
        fallback_settings_ref = settings
        local ok_val, val = pcall(function() return settings:getParaReviewEnabled() end)
        if ok_val and val == true then _state.enable_review = true end
    end
    function _state.getCurrentParaReviews() return _state.current_para_reviews or {} end
    function _state.setCurrentParaReviews(r) _state.current_para_reviews = r or {} end
    function _state.setCurrentParaIndex(i) _state.current_para_index = i or 0 end
    function _state.getCurrentParaIndex() return _state.current_para_index or 0 end
    function _state.clearParaReviews() _state.current_para_reviews = {}; _state.current_para_index = 0 end
    _state.chapter_navigating = false
    function _state.setChapterNavigating(v) _state.chapter_navigating = v == true end
    function _state.isChapterNavigating() return _state.chapter_navigating == true end
end

local function getCurrentChapterIndex()
    return _state.current_chapter_index or 0
end

local function getCachedChapters(self, book)
    if not book then
        return {}
    end
    if not book.cached_chapters then
        book.cached_chapters = Content.load_cache_index(self.settings, book.book_id) or {}
    end
    return book.cached_chapters
end

local FanQiePlugin = WidgetContainer:extend{
    name = "fanqie",
    is_doc_only = false,
    fullname = "FanQie",
    version = Info and Info.version or "2.2.0",
}

-- Check if the active ReaderUI document is the fanqie chapter we opened.
-- Prevents event handlers (onEndOfBook, onCloseDocument, etc.) from
-- firing on unrelated documents the user may open afterwards.
function FanQiePlugin:isCurrentDocFanqie()
    if not (self.ui and self.ui.document) then return false end
    local doc_path = self.ui.document.file or self.ui.document.path
    if not doc_path then return false end
    return doc_path:lower():find('/fanqie/', 1, true) ~= nil
end

function FanQiePlugin:init()
    self.settings = Settings:new()
    Log.init(self.settings)
    self.client = Client:new(self.settings)
    self.patches_ok = Patches.verifyPatched()
    -- 尽早安装补丁（含 ReaderLink 段评链接拦截），确保已打开的书也能立即生效
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = Patches.verifyPatched()
    end
    -- 加载持久化的段评开关（必须在加载 config 之前，让 config 不覆盖用户选择）
    if _state.loadReviewState then
        _state.loadReviewState(self.settings)
    end
    self:onDispatcherRegisterActions()
    self:loadConfigFile(true)
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    Log.info("plugin initialized:", "version=", self.version)
end

function FanQiePlugin:displayError(err)
    return display_error(err)
end

if Bookshelf then
    for k, v in pairs(Bookshelf) do
        FanQiePlugin[k] = v
    end
end

if ReaderNavigation then
    for k, v in pairs(ReaderNavigation) do
        FanQiePlugin[k] = v
    end
end

function FanQiePlugin:logInitError(step, err)
    local err_msg = log_error(err)
    if logger and logger.err then
        logger.err(LOG_MODULE, step .. ":", err_msg)
    end
    if Log and Log.error then
        Log.error(step .. ":", err_msg)
    end
    local file = io.open("/mnt/us/koreader/fanqie_init_error.log", "a")
    if file then
        file:write("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. step .. ": " .. err_msg .. "\n")
        file:close()
    end
end

function FanQiePlugin:ensurePatchesInstalled()
    local Patches = require("patches.core")
    if not Patches.verifyPatched("ReaderToc") then
        Patches.install()
    end
end



function FanQiePlugin:onDispatcherRegisterActions()
    -- 参考内置插件模式：用 general=true，让动作在 FileManager 和 Reader
    -- 的手势管理「General」分类下都可绑定、可触发（不局限于某个上下文）。
    Dispatcher:registerAction("show_fanqie_bookshelf", {
        category = "none",
        event = "ShowFanQieBookshelf",
        title = _("番茄书架"),
        general = true,
    })
    Dispatcher:registerAction("return_fanqie_toc", {
        category = "none",
        event = "ShowFanQieToc",
        title = _("返回番茄目录"),
        reader = true,
    })
end

function FanQiePlugin:safeCallback(label, callback)
    local self_ref = self
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return callback(unpack_args(args))
        end, debug.traceback)
        if not ok then
            self_ref:closeBusy()
            if logger and logger.err then logger.err(LOG_MODULE, "action failed:", label, log_error(err)) end
            self_ref:showInfo(T(_("%1 failed:\n%2"), label, display_error(err)))
        end
    end
end

function FanQiePlugin:addToMainMenu(menu_items)
    if self.ui.document and _state.current_book and self:isCurrentDocFanqie() then
        menu_items.fanqie = {
            text = _("番茄小说"),
            sorting_hint = "tools",
            sub_item_table_func = function()
                return {
                    {
                        text = _("书架"),
                        callback = self:safeCallback(_("书架"), function()
                            self:showBookshelf()
                        end),
                    },
                    {
                        text = _("目录"),
                        callback = self:safeCallback(_("目录"), function()
                            self.ui:handleEvent(Event:new("ShowFanQieToc"))
                        end),
                    },
                    {
                        text = _("下载"),
                        callback = self:safeCallback(_("下载"), function()
                            local book = _state.current_book
                            if not book then self:showInfo(_("无书籍信息")); return end
                            local chapters = _state.current_chapters
                            if not chapters or #chapters == 0 then
                                -- 子进程获取目录，UI 线程保持响应
                                self:showBusy(_("正在获取目录..."))
                                local client = self.client
                                local book_id = book.book_id
                                Async.run(function()
                                    local b = { book_id = book_id }
                                    return Content.fetch_catalog(client, b)
                                end, function(ok_cat, result, err)
                                    self:closeBusy()
                                    if not ok_cat or type(result) ~= "table" or #result == 0 then
                                        self:showInfo(_("获取目录失败"))
                                        return
                                    end
                                    _state.current_chapters = result
                                    local Download = require("fanqie.download")
                                    Download.showOptionsDialog(self, book, result,
                                        { current_index = _state.current_chapter_index })
                                end, { poll_interval = 0.3, timeout = 60 })
                                return
                            end
                            local Download = require("fanqie.download")
                            Download.showOptionsDialog(self, book, chapters,
                                { current_index = _state.current_chapter_index })
                        end),
                    },
                    {
                        text = _("设置"),
                        sub_item_table_func = function()
                            return self:getSettingsMenuItems()
                        end,
                    },
                    {
                        text = _("缓存管理"),
                        sub_item_table_func = function()
                            return self:getCacheMenuItems()
                        end,
                    },
                    {
                        text = _("重新获取本章节"),
                        callback = self:safeCallback(_("重新获取本章节"), function()
                            self:reloadCurrentChapter()
                        end),
                    },
                    {
                        text = _("关于"),
                        callback = self:safeCallback(_("关于"), function()
                            self:showInfo(T(Info and Info.about_template or _("番茄小说插件 v%1"), self.version, self.settings:get_download_dir()))
                        end),
                    },
                }
            end,
        }
    else
        menu_items.fanqie = {
            text = _("番茄小说"),
            sorting_hint = "tools",
            sub_item_table_func = function()
                return self:getMainMenuItems()
            end,
        }
    end
end

-- ===========================================================================
-- 段评
-- ===========================================================================
-- 段评开关已移至「设置」页面（getSettingsMenuItems 中的"段评显示"），
-- 阅读时点击「重新获取本章节」会根据开关状态决定是否带段评获取正文。

-- 显示段评列表对话框
function FanQiePlugin:showParaReviewList()
    local reviews = _state.getCurrentParaReviews()
    if #reviews == 0 then
        self:showInfo(_("当前章节暂无段评数据"))
        return
    end
    
    -- 构建段评列表项
    local items = {}
    for i, pr in ipairs(reviews) do
        table.insert(items, {
            text = string.format("%d. %d条评论", i, pr.count or 0),
            callback = function()
                self:showParaReviewDetail(i)
            end,
        })
    end
    
    local menu = Menu:new{
        title = _("段评列表"),
        item_table = items,
        items_per_page = 20,
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            _state.active_menu = nil
        end,
    }
    _state.active_menu = menu
    UIManager:show(menu)
end

-- 显示单段段评详情（从API获取评论数据）
function FanQiePlugin:showParaReviewDetail(index)
    local reviews = _state.getCurrentParaReviews()
    local pr = reviews[index]
    if not pr or not pr.ident then
        self:showInfo(_("段评数据无效"))
        return
    end

    local self_ref = self
    local ident = pr.ident
    local book_id = _state.current_book and _state.current_book.book_id or ""
    local review_index = index
    local total_reviews = #reviews

    -- 将段评获取（阻塞 HTTP）移到子进程，UI 线程仅轮询，不阻塞用户操作。
    -- 子进程不可用时 Async.run 内部自动降级为延后同步。
    self:showBusy(_("正在获取段评..."))
    if Async and Async.run then
        Async.run(function()
            local c = Client:new(self_ref.settings)
            local ident_str = tostring(ident)
            local is_zhiqiu    = ident_str:find("zhiqiu:", 1, true)
            local is_shushan   = ident_str:find("shushan:", 1, true)

            if Log then
                Log.info("[段评] showParaReviewDetail(异步): idx=" .. tostring(review_index)
                    .. " is_zhiqiu=" .. tostring(is_zhiqiu)
                    .. " is_shushan=" .. tostring(is_shushan)
                    .. " ident=" .. ident_str:sub(1, 80))
            end

            local ok, result
            if is_shushan then
                -- 书山自有段落级段评 JSON 通道（GET /idea_comment?api=1，2026-09-13 实测可用），
                -- 不再依赖知秋。ident 格式 shushan:<bid>:<cid>:<pid>，返回番茄原生结构，
                -- 与 _displayParaReviewDetail 解析器兼容。
                ok, result = pcall(function() return c:shushan_get_para_review(ident) end)
                if not ok then
                    error("书山段评获取失败：" .. tostring(result or "")
                        .. "（请确认书山账号已登录、Android ID 为真实设备）")
                end
            elseif is_zhiqiu then
                ok, result = pcall(function() return c:zhiqiu_get_para_review(ident) end)
            else
                -- 无法识别的 ident（多为旧缓存中已移除书源的历史段评）
                error("无法识别段评来源: " .. ident_str:sub(1, 60))
            end
            if not ok then error(result or "段评获取失败") end
            return result
        end, function(ok, result, err)
            self_ref:_displayParaReviewDetail(review_index, total_reviews, ok, result, err)
        end, { poll_interval = 0.125, timeout = 60 })
    else
        -- 降级：Async 模块未加载（极端情况），同步执行
        local c = self_ref.client or Client:new(self_ref.settings)
        local ident_str = tostring(ident)
        local is_zhiqiu    = ident_str:find("zhiqiu:", 1, true)
        local is_shushan   = ident_str:find("shushan:", 1, true)
        local ok, result
        if is_shushan then
            -- 书山自有段评通道（不依赖知秋）
            ok, result = pcall(function() return c:shushan_get_para_review(ident) end)
            if not ok then
                error("书山段评获取失败：" .. tostring(result or "")
                    .. "（请确认书山账号已登录、Android ID 为真实设备）")
            end
        elseif is_zhiqiu then
            ok, result = pcall(function() return c:zhiqiu_get_para_review(ident) end)
        else
            -- 无法识别的 ident（多为旧缓存中已移除书源的历史段评）
            ok, result = false, "无法识别段评来源: " .. ident_str:sub(1, 60)
        end
        self_ref:_displayParaReviewDetail(review_index, total_reviews, ok, result, nil)
    end
end

-- 显示段评详情弹窗（纯 UI 渲染，不做网络请求）
function FanQiePlugin:_displayParaReviewDetail(index, total_reviews, ok, result, err)
    local self = self
    -- 懒加载富排版段评弹框（含 freetype/xtext 渲染管线），仅在本弹框真正要展示时拉取
    local ok_reviewpopup, ReviewPopup = pcall(require, "fanqie.review_popup")
    if not ok_reviewpopup or not ReviewPopup then
        if Log then Log.error("[段评] review_popup 加载失败:", tostring(ReviewPopup)) end
        self:closeBusy()
        self:showInfo(_("段评富排版组件加载失败，请检查 fanqie/review_popup 模块"))
        return
    end
    -- 章节切换中：异步段评获取完成时可能已进入新章节，丢弃过期的段评弹窗
    if _state.isChapterNavigating() then
        if Log then Log.debug("[段评] _displayParaReviewDetail: 章节切换中，丢弃段评弹窗") end
        self:closeBusy()
        return
    end
    if not ok then
        if Log then Log.error("[段评] 获取失败:", tostring(err or result)) end
        self:closeBusy()
        self:showInfo(_("段评获取失败: ") .. tostring(err or result))
        return
    end

    -- 日志：记录 API 返回的原始结构，便于诊断
    if Log then
        local result_type = type(result)
        local comments_count = 0
        local total_val = 0
        if result_type == "table" then
            -- 新格式: result.data.data_list[]
            local dl = result.data and result.data.data_list
            if type(dl) == "table" then
                comments_count = #dl
                total_val = (result.data.common_list_info and result.data.common_list_info.total) or 0
            else
                -- 旧格式兼容: result.data.comments[]
                local c = result.comments
                if not c and type(result.data) == "table" then
                    c = result.data.comments or result.data
                end
                if type(c) == "table" then comments_count = #c end
                total_val = result.total
                    or (result.data and result.data.total) or 0
            end
        end
        Log.info("[段评] API返回: type=" .. result_type
            .. " comments=" .. comments_count
            .. " total=" .. tostring(total_val))
    end

    -- 解析评论列表（支持新格式 data_list 和旧格式 comments）
    local comments = nil
    local total = 0

    if type(result) == "table" and type(result.data) == "table" then
        -- 新格式: /api/fanqie/comment/paragraph/list
        -- data.data_list[].comment.{common,stat}
        -- data.common_list_info.{total,has_more,cursor}
        local data_list = result.data.data_list
        if type(data_list) == "table" and #data_list > 0 then
            comments = {}
            total = (result.data.common_list_info and result.data.common_list_info.total) or #data_list
            for _, item in ipairs(data_list) do
                local c = item.comment or item
                local common = c.common or {}
                local content = common.content or {}
                local user_info = common.user_info or {}
                local base_info = user_info.base_info or user_info
                local stat = c.stat or {}

                table.insert(comments, {
                    username = base_info.user_name or common.user_name or "匿名",
                    text = content.text or common.text or "",
                    like_count = stat.digg_count or 0,
                    reply_count = stat.reply_count or 0,
                    create_time = common.create_timestamp or common.create_time,
                    para_src = (c.expand and c.expand.para_src_content) or "",
                })
            end
        else
            -- 旧格式兼容: data.comments[]
            local c = result.data.comments
            if type(c) == "table" then
                comments = c
                total = result.data.total or #c
            end
        end
    elseif type(result) == "table" then
        -- 旧格式兼容: result.comments[]
        comments = result.comments
        total = result.total or 0
    end

    if type(comments) ~= "table" then comments = {} end
    if total == 0 then total = #comments end

    self:closeBusy()

    if #comments > 0 then
        -- ================================================================
        -- B 档：把段评弹框从纯 TextViewer 换成微信读书「想法」式富排版弹框
        -- （移植自 weread.koplugin 的 thought_popup 渲染管线，见 fanqie/review_popup/）
        -- ================================================================
        -- 归一再展示: 取第一条非空 para_src 作为整段引文(abstract)，没有则不显示引文
        local abstract = ""
        for _, c0 in ipairs(comments) do
            local src = tostring(c0.para_src or c0.abstract or "")
            if src ~= "" then abstract = src break end
        end

        -- 归一化 items: { abstract, author, content, likes_count }
        local rich_items = {}
        for _, comment in ipairs(comments) do
            local username = tostring(comment.username or comment.user_name
                or (comment.user and comment.user.user_name)
                or (comment.user and comment.user.nick_name)
                or comment.nick_name or comment.nickname or "匿名")
            local content_text = tostring(comment.text or comment.content or "")
            local like_count = tonumber(comment.like_count or comment.likeCount
                or comment.digg_count) or 0
            if content_text ~= "" then
                table.insert(rich_items, {
                    abstract = abstract,
                    author = username,
                    content = content_text,
                    likes_count = like_count,
                })
            end
        end

        if #rich_items == 0 then
            self:showInfo(T(_("本条段评共 %1 条评论，暂无显示数据"), tostring(total)))
            return
        end

        -- 段落 上一段/下一段：横向滑动切换（在弹框内仍可上下滚动/翻页查看全部评论）
        local function navigate_para(delta)
            local target = index + delta
            if target < 1 or target > total_reviews then return end
            ReviewPopup.closeVisible()
            -- 延迟一帧，等旧弹框从 UIManager 出栈后再打开下一段
            UIManager:nextTick(function()
                self:showParaReviewDetail(target)
            end)
        end

        local opts = {
            pages = rich_items,
            position = "bottom",
            height_ratio = 0.7,
            contrast = 7,
            tap_to_page = true,
            para_nav = function(dir)
                if dir == "prev" then navigate_para(-1)
                else navigate_para(1) end
            end,
            doc_font_name = nil,
            doc_font_size = nil,
            doc_margins = nil,
        }

        -- 从当前阅读器 ui 读取正文字体/字号/边距（带降级，读不到就交给弹框默认）
        if self.ui then
            local ok_dev, Device = pcall(require, "device")
            local Screen = ok_dev and Device and Device.screen
            local font_face
            if self.ui.font and self.ui.font.font_face then
                font_face = self.ui.font.font_face
            elseif G_reader_settings then
                font_face = G_reader_settings:readSetting("cre_font")
            end
            opts.doc_font_name = font_face
            local doc = self.ui.document
            local doc_font_size = (doc and doc.configurable and doc.configurable.font_size) or 18
            if Screen and Screen.scaleBySize then
                -- 弹框字号比正文小一号（KOReader 每档 = 整数值 ±1，见 readerfont）
                opts.doc_font_size = Screen:scaleBySize(math.max(doc_font_size - 1, 10))
            end
            if doc and doc.getPageMargins then
                local okm, margins = pcall(function() return doc:getPageMargins() end)
                if okm and margins then opts.doc_margins = margins end
            end
        end

        ReviewPopup.show(opts)
    else
        self:showInfo(T(_("本条段评共 %1 条评论，暂无显示数据"), tostring(total)))
    end
end

-- 段评异步获取已迁移至 showParaReviewDetail / _displayParaReviewDetail


-- ============================================================================
-- 段评链接拦截
-- ============================================================================
-- KOReader 的 ReaderLink:showLinkBox() 在检测到 <a> 链接点击时，直接调用
-- self:onGotoLink()（方法调用，非事件广播），因此插件自身的 onGotoLink 永远
-- 收不到。ReaderLink:onGotoLink 不认识 fanqie-para: 协议，会报"无效或外部链接"。
--
-- 解决方案：通过 patches/core.lua 猴补丁 ReaderLink.onGotoLink，在原函数之前
-- 检查 fanqie-para: 前缀，匹配则派发 FanQieParaReview 事件给本插件。
function FanQiePlugin:onFanQieParaReview(idx)
    if not self:isCurrentDocFanqie() then return end
    if not idx then return end
    -- 章节切换中（onEndOfBook→navigateToChapter）：忽略段评请求，防止弹窗闪现
    if _state.isChapterNavigating() then
        if Log then Log.debug("[段评] onFanQieParaReview: 章节切换中，跳过 idx=" .. tostring(idx)) end
        return true
    end
    if Log then Log.info("[段评] onFanQieParaReview: idx=" .. tostring(idx)) end
    self:showParaReviewDetail(idx)
    return true
end

function FanQiePlugin:getMainMenuItems()
    local items = {
        {
            text = _("书架"),
            callback = self:safeCallback(_("书架"), function()
                self:showBookshelf()
            end),
        },
        {
            text = _("下载管理"),
            callback = self:safeCallback(_("下载管理"), function()
                self:showDownloadManager()
            end),
        },
        {
            text = _("设置"),
            sub_item_table_func = function()
                return self:getSettingsMenuItems()
            end,
        },
        {
            text = _("缓存管理"),
            sub_item_table_func = function()
                return self:getCacheMenuItems()
            end,
        },
    }
    
    -- Add "Reload current chapter" option only when reading a fanqie chapter
    if self:isCurrentDocFanqie() and _state.current_chapter_index and _state.current_chapter_index > 0 then
        table.insert(items, {
            text = _("重新获取本章节"),
            separator = true,
            callback = self:safeCallback(_("重新获取本章节"), function()
                self:reloadCurrentChapter()
            end),
        })
    end
    
    table.insert(items, {
        text = _("关于"),
        callback = self:safeCallback(_("关于"), function()
            UIManager:show(InfoMessage:new{
                text = T(Info and Info.about_template or _("番茄小说插件 v%1"), self.version, self.settings:get_download_dir()),
            })
        end),
    })
    
    return items
end

-- ===========================================================================
-- Settings menu
-- ===========================================================================

function FanQiePlugin:getSettingsMenuItems()
    return {
        {
            text = _("缓存目录"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showDownloadDirPicker(touchmenu_instance)
            end,
        },
        {
            text_func = function()
                local cache = self.settings:get("cache", {})
                local count = cache.pre_download_chapters or 3
                return T(_("预下载章节数: %1"), tostring(count))
            end,
            keep_menu_open = true,
            sub_item_table = {
                { text = "1",  keep_menu_open = true, callback = function() self:setPreDownloadCount(1) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 1 end },
                { text = "3",  keep_menu_open = true, callback = function() self:setPreDownloadCount(3) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 3 end },
                { text = "5",  keep_menu_open = true, callback = function() self:setPreDownloadCount(5) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 5 end },
                { text = "10", keep_menu_open = true, callback = function() self:setPreDownloadCount(10) end,
                    checked_func = function() local c = self.settings:get("cache", {}); return (c and c.pre_download_chapters or 3) == 10 end },
            },
        },
        
        {
            text = _("下载图片"),
            checked_func = function()
                local cache = self.settings:get("cache", {})
                return cache.download_book_images ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local cache = self.settings:get("cache", {})
                cache.download_book_images = not (cache.download_book_images ~= false)
                self.settings:set("cache", cache)
                self.settings:flush()
            end,
        },
        {
            text = _("段评显示"),
            checked_func = function()
                return _state.isReviewEnabled()
            end,
            keep_menu_open = true,
            callback = function()
                _state.setReviewEnabled(not _state.isReviewEnabled())
            end,
        },
        {
            text = _("读取进度同步"),
            checked_func = function()
                local sync = self.settings:get("sync", {})
                return sync.pull_on_open ~= false
            end,
            keep_menu_open = true,
            callback = function()
                local sync = self.settings:get("sync", {})
                sync.pull_on_open = not (sync.pull_on_open ~= false)
                self.settings:set("sync", sync)
                self.settings:flush()
            end,
        },
        {
            text = _("重新加载配置文件"),
            keep_menu_open = true,
            callback = function()
                self:loadConfigFile(false, true)
            end,
        },
        {
            text = _("扫码登录"),
            keep_menu_open = false,
            callback = function()
                local QRLogin = require("fanqie.qrlogin")
                local qr = QRLogin:new(self.client, self.settings, self)
                qr:start()
            end,
        },
        {
            text = _("退出登录"),
            enabled_func = function()
                return self.settings:is_cookie_configured()
            end,
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("确定退出登录？将清除已保存的 Cookie。"),
                    ok_text = _("退出登录"),
                    ok_callback = function()
                        self.settings:set("cookies", {})
                        self.settings:flush()
                        self:showInfo(_("已退出登录"))
                    end,
                })
            end,
        },
        {
            text = _("书源管理"),
            sub_item_table_func = function()
                return self:getSourceMenuItems()
            end,
        },
        {
            text = _("调试日志"),
            sub_item_table_func = function()
                return self:getLogMenuItems()
            end,
        },
    }
end

-- ===========================================================================
-- Book source management
-- ===========================================================================

function FanQiePlugin:getSourceMenuItems()
    local SourceManager = require("fanqie.sources")
    local ordered = SourceManager.get_all_sources(self.settings)
    local items = {}
    for _i, src in ipairs(ordered) do
        local cfg = src.config
        local meta = src.meta
        local is_dev = meta.in_development == true
        local is_enabled = cfg.enabled ~= false
        local is_configured = SourceManager.is_configured(src.id, cfg, self.settings)
        local name = meta.name
        if is_dev then name = name .. _(" (开发中)") end
        if not is_configured and not is_dev then name = name .. _(" (未配置)") end
        local display_name = name
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(src.id)
                local prefix = (c.enabled ~= false) and "●" or "○"
                return string.format("%s %s", prefix, display_name)
            end,
            enabled_func = function() return not is_dev end,
            keep_menu_open = true,
            sub_item_table_func = function()
                return self:getSourceDetailMenuItems(src.id)
            end,
        })
    end
    return items
end

function FanQiePlugin:getSourceDetailMenuItems(source_id)
    local SourceManager = require("fanqie.sources")
    local meta = SourceManager.REGISTRY[source_id]
    local items = {}

    -- Enable / disable toggle (dev sources lock this)
    if not meta.in_development then
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source(source_id)
                return c.enabled ~= false and _("禁用此源") or _("启用此源")
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local c = self.settings:get_source(source_id)
                self.settings:set_source_field(source_id, "enabled", c.enabled == false)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
    end

    -- ZhiQiu (知秋) branch: configure the three credentials (源作者/官方反馈群/
    -- 临时Token口令) that mint the shared token, or paste a token directly.
    if source_id == "zhiqiu" then
        table.insert(items, {
            text = _("服务器/Token设置"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showZhiQiuConfigDialog(touchmenu_instance)
            end,
        })
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source("zhiqiu")
                local tok = H.trim(c.token or "")
                if tok ~= "" then return _("共享Token: 已配置") end
                -- No token stored yet → can self-mint from the three credentials.
                local a = H.trim(c.source_author or "")
                local g = H.trim(c.group_id or "")
                local p = H.trim(c.temp_token_pass or "")
                if a ~= "" and g ~= "" and p ~= "" then
                    return _("共享Token: 自动获取(三件套已填)")
                end
                return _("共享Token: 未配置")
            end,
            keep_menu_open = true,
        })
        table.insert(items, {
            text = _("获取共享Token（无/已过期时自动铸造）"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showBusy(_("正在检查/获取共享Token..."))
                local settings = self.settings
                Async.run(function()
                    local c = Client:new(settings)
                    local ZhiQiu = require("fanqie.zhiqiu")
                    -- 知秋服务限制：同一设备仅在无token或token过期后可重新申请
                    --（有效期内重复申请会返回"用户已存在"）。故此处不强制刷新。
                    local tok = ZhiQiu.ensure_token(c, settings, false)
                    return tok
                end, function(ok, tok, err)
                    self:closeBusy()
                    if ok and tok and tok ~= "" then
                        UIManager:show(InfoMessage:new{
                            text = _("✅ 共享Token已就绪（3天有效，自动续期）"), timeout = 3,
                        })
                    elseif ok then
                        UIManager:show(InfoMessage:new{
                            text = _("✅ Token有效期内，无需重新获取"), timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("获取失败: ") .. tostring(err), timeout = 4,
                        })
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        })
        table.insert(items, {
            text = _("查询Token剩余额度"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showBusy(_("正在查询..."))
                local settings = self.settings
                Async.run(function()
                    local c = Client:new(settings)
                    local ZhiQiu = require("fanqie.zhiqiu")
                    return ZhiQiu.query_token(c, settings)
                end, function(ok, info, err)
                    self:closeBusy()
                    if ok and info then
                        UIManager:show(InfoMessage:new{
                            text = _("日剩余: ") .. tostring(info.left)
                                .. _("  到期: ") .. tostring(info.ddlTime or ""), timeout = 4,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("查询失败: ") .. tostring(err or "无Token"), timeout = 4,
                        })
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        })
        table.insert(items, {
            text = _("清除共享Token"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self.settings:set_source_field("zhiqiu", "token", "")
                self.settings:set_source_field("zhiqiu", "token_minted_at", "")
                if touchmenu_instance then touchmenu_instance:updateItems() end
                UIManager:show(InfoMessage:new{
                    text = _("已清除共享Token，下次获取时自动重新铸造"), timeout = 3,
                })
            end,
        })
    end

    -- ShuShan (书山) branch: email/password + REAL Android id → api_key.
    -- 书山聚合：一个账号聚合非番茄源，并可用番茄源付费解锁。读正文必须提供
    -- 已用阅读 app 登录书山的那台安卓设备的真实 Android ID（16hex）。插件
    -- 不自动生成 id（伪造曾致封号），仅在正文请求时校验。
    if source_id == "shushan" then
        table.insert(items, {
            text = _("账号/设备设置"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showShuShanConfigDialog(touchmenu_instance)
            end,
        })
        table.insert(items, {
            text_func = function()
                local c = self.settings:get_source("shushan")
                local key = H.trim(c.api_key or "")
                local aid = H.trim(c.android_id or "")
                if key ~= "" then
                    return _("登录: 已获取api_key")
                end
                local e = H.trim(c.email or "")
                local p = H.trim(c.password or "")
                if e ~= "" and p ~= "" then
                    return _("登录: 已配置凭据(待登录)")
                end
                return _("登录: 未配置")
            end,
            keep_menu_open = true,
        })
        table.insert(items, {
            text = _("登录测试（邮箱+密码 → 获取/刷新api_key）"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showBusy(_("正在登录书山..."))
                local settings = self.settings
                Async.run(function()
                    local c = Client:new(settings)
                    return c:shushan_login()
                end, function(ok, api_key, err)
                    self:closeBusy()
                    if ok and api_key and api_key ~= "" then
                        UIManager:show(InfoMessage:new{
                            text = _("✅ 书山登录成功！api_key 已保存"), timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("登录失败: ") .. tostring(err), timeout = 4,
                        })
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        })
        table.insert(items, {
            text = _("服务器测速（自动切换到最快线路）"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:showBusy(_("正在测速所有线路..."))
                local settings = self.settings
                Async.run(function()
                    local c = Client:new(settings)
                    return c:shushan_select_fastest()
                end, function(ok, data, err)
                    self:closeBusy()
                    if ok and data and data.best then
                        -- 可达节点排前并按延迟升序，不可达的列在后面
                        local sorted = {}
                        for _, r in ipairs(data.results or {}) do
                            sorted[#sorted + 1] = r
                        end
                        table.sort(sorted, function(a, b)
                            if a.ok ~= b.ok then return a.ok end
                            return (a.ms or 0) < (b.ms or 0)
                        end)
                        local lines = {}
                        for _, r in ipairs(sorted) do
                            local host = tostring(r.base):gsub("^https?://", "")
                            if r.ok then
                                lines[#lines + 1] = string.format("%s  %dms%s",
                                    host, r.ms,
                                    (r.base == data.best) and "  <- 已选用" or "")
                            else
                                lines[#lines + 1] = string.format("%s  不可达（%s）",
                                    host, tostring(r.note or "无响应"))
                            end
                        end
                        local best_host = tostring(data.best):gsub("^https?://", "")
                        local detail = table.concat(lines, "\n")
                        local msg = "已切换到最快线路: " .. best_host .. "\n----------\n" .. detail
                        if T then
                            msg = T(_("已切换到最快线路: %1\n----------\n%2"), best_host, detail)
                        end
                        UIManager:show(InfoMessage:new{
                            text = "✅ " .. msg, timeout = 8,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("测速失败: ") .. tostring((data and data.err) or err),
                            timeout = 4,
                        })
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end)
            end,
        })
        table.insert(items, {
            text = _("退出登录（清除api_key）"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(ConfirmBox:new{
                    text = _("确定退出书山登录？\n将清除已保存的 api_key（保留邮箱/密码/设备ID）。"),
                    ok_text = _("退出"),
                    cancel_text = _("取消"),
                    ok_callback = function()
                        self.settings:set_source_field("shushan", "api_key", "")
                        self.settings:set_source_field("shushan", "api_key_at", "")
                        local SM = require("fanqie.sources")
                        SM.rate_limit_reset("shushan")
                        UIManager:show(InfoMessage:new{
                            text = _("已退出书山登录"), timeout = 2,
                        })
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        })
    end

    -- Rate limit setting (all sources)
    -- separator=true：在该项下方画横线，把"上移/下移"整组与上方配置项视觉分隔
    table.insert(items, {
        text_func = function()
            local c = self.settings:get_source(source_id)
            local rl = c.rate_limit or {}
            local mr = rl.max_requests or 0
            local ws = (rl.window_seconds or 0) > 0 and rl.window_seconds or 30
            if mr == 0 then
                return _("限流: 无限制")
            end
            return string.format(_("限流: %d次 / %ds"), mr, ws)
        end,
        separator = true,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            self:showSourceRateLimitDialog(source_id, touchmenu_instance)
        end,
    })

    -- Move up / down
    -- 修复返回书源列表顺序不刷新的 bug：KOReader TouchMenu 返回父页时默认用栈中缓存的
    -- 旧 item_table，不会重新调用 sub_item_table_func。这里给父页（书源列表）挂
    -- needs_refresh + refresh_func，再 backToUpperMenu 返回时即触发重建，立即看到新顺序。
    local function move_and_refresh(direction)
        return function(touchmenu_instance)
            self.settings:move_source(source_id, direction)
            if touchmenu_instance and touchmenu_instance.item_table_stack then
                local parent = touchmenu_instance.item_table_stack[#touchmenu_instance.item_table_stack]
                if parent then
                    parent.needs_refresh = true
                    parent.refresh_func = function()
                        return self:getSourceMenuItems()
                    end
                end
            end
            -- 返回书源列表，触发 needs_refresh → refresh_func 重建列表（新顺序立即生效）
            if touchmenu_instance and touchmenu_instance.backToUpperMenu then
                touchmenu_instance:backToUpperMenu()
            end
        end
    end

    table.insert(items, {
        text = _("上移"),
        separator = true,
        keep_menu_open = true,
        callback = move_and_refresh(-1),
    })
    table.insert(items, {
        text = _("下移"),
        keep_menu_open = true,
        callback = move_and_refresh(1),
    })

    return items
end

function FanQiePlugin:showZhiQiuConfigDialog(touchmenu_instance)
    if not MultiInputDialog then
        self:showInfo(_("系统不支持多输入对话框"))
        return
    end
    local cfg = self.settings:get_source("zhiqiu")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("知秋四合一设置"),
        fields = {
            {
                description = _("服务器地址"),
                text = cfg.server_url or "",
                hint = "https://fq.vv9v.cn",
            },
            {
                description = _("共享Token(可选，填了三件套可自动获取)"),
                text = cfg.token or "",
                hint = _("留空自动获取"),
            },
            {
                description = _("源作者 (pw1)"),
                text = cfg.source_author or "",
                hint = _("知秋"),
            },
            {
                description = _("官方反馈群 (pw2)"),
                text = cfg.group_id or "",
                hint = "755947375",
            },
            {
                description = _("临时Token口令 (pw3)"),
                text = cfg.temp_token_pass or "",
                hint = _("天一团队是倒狗(...)整串"),
            },
        },
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        local server = H.trim(fields[1] or "")
                        local token  = H.trim(fields[2] or "")
                        local pw1 = H.trim(fields[3] or "")
                        local pw2 = H.trim(fields[4] or "")
                        local pw3 = (fields[5] or "")
                        if server == "" then
                            self:showInfo(_("服务器地址不能为空"))
                            return
                        end
                        if token == "" and (pw1 == "" or pw2 == "" or pw3 == "") then
                            self:showInfo(_("请填共享Token，或填齐 源作者/官方反馈群/临时Token口令 以便自动获取"))
                            return
                        end
                        local new_cfg = self.settings:get_source("zhiqiu")
                        new_cfg.server_url = server
                        new_cfg.source_author = pw1
                        new_cfg.group_id = pw2
                        new_cfg.temp_token_pass = pw3
                        -- 仅当用户手动填了 token 才覆盖；留空则沿用（由 ensure_token 按3天有效期自动续期）
                        if token ~= "" then
                            new_cfg.token = token
                            new_cfg.token_minted_at = tostring(os.time())
                        end
                        self.settings:set_source("zhiqiu", new_cfg)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("已保存。若未填Token，请在书源菜单点『立即获取/续期共享Token』"),
                            timeout = 3,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:showShuShanConfigDialog(touchmenu_instance)
    if not MultiInputDialog then
        self:showInfo(_("系统不支持多输入对话框"))
        return
    end
    local cfg = self.settings:get_source("shushan")
    local dialog
    dialog = MultiInputDialog:new{
        title = _("书山账号设置"),
        fields = {
            {
                description = _("服务器地址"),
                text = cfg.server_url or "",
                hint = "https://v2.vossc.com",
            },
            {
                description = _("书山账号邮箱"),
                text = cfg.email or "",
                hint = "xxx@qq.com",
            },
            {
                description = _("书山账号密码"),
                text = cfg.password or "",
                hint = _("用于登录获取 api_key"),
            },
            {
                description = _("真实 Android ID (16/32位hex，读正文必填)"),
                text = cfg.android_id or "",
                hint = _("你已用阅读app登录书山的那台安卓设备"),
            },
            {
                description = _("正文版本号 (默认12)"),
                text = cfg.content_version or "",
                hint = "12",
            },
        },
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        local server = H.trim(fields[1] or "")
                        local email = H.trim(fields[2] or "")
                        local password = H.trim(fields[3] or "")
                        local android_id = H.trim(fields[4] or "")
                        local ver = H.trim(fields[5] or "")
                        if server == "" then
                            self:showInfo(_("服务器地址不能为空"))
                            return
                        end
                        if email == "" or password == "" then
                            self:showInfo(_("请填写书山账号邮箱和密码"))
                            return
                        end
                        -- Android ID 合法性提示（非强制，正文时才需要；但给出明显警告）
                        if android_id ~= "" and not android_id:match("^%x+$") then
                            self:showInfo(_("Android ID 应为十六进制字符(0-9a-f)。请确认填写的是设备Android ID而非其他编号。"))
                            return
                        end
                        if android_id ~= "" and #android_id ~= 16 and #android_id ~= 32 then
                            self:showInfo(_("Android ID 长度应为16或32位。你填的是 ") .. tostring(#android_id) .. " 位")
                            return
                        end
                        local new_cfg = self.settings:get_source("shushan")
                        new_cfg.server_url = server
                        new_cfg.email = email
                        new_cfg.password = password
                        if android_id ~= "" then new_cfg.android_id = android_id end
                        if ver ~= "" then new_cfg.content_version = ver end
                        -- 若换了邮箱/密码，旧 api_key 可能失效，清除以触发重新登录
                        new_cfg.api_key = ""
                        new_cfg.api_key_at = ""
                        self.settings:set_source("shushan", new_cfg)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("已保存。请点『登录测试』获取 api_key 后即可使用。读正文还需有效 Android ID。"),
                            timeout = 4,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:showSourceRateLimitDialog(source_id, touchmenu_instance)
    if not InputDialog then
        self:showInfo(_("系统不支持输入对话框"))
        return
    end
    local cfg = self.settings:get_source(source_id)
    local rl = cfg.rate_limit or { max_requests = 0, window_seconds = 0 }
    local dialog
    dialog = InputDialog:new{
        title = _("限流设置"),
        input = tostring(rl.max_requests or 0),
        input_type = "number",
        description = _("格式: 最大请求数 / 时间窗口(秒)，0=无限制\n示例: 5/30 表示 30秒内最多5次"),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText() or ""
                        UIManager:close(dialog)
                        local mr_str, win_str = input:match("^(%d+)%s*/%s*(%d+)$")
                        if not mr_str then
                            mr_str = input:match("^(%d+)$")
                            win_str = tostring(rl.window_seconds or 30)
                        end
                        if not mr_str then
                            self:showInfo(_("格式错误"))
                            return
                        end
                        local mr = tonumber(mr_str) or 0
                        local win = (tonumber(win_str) or 30)
                        if win <= 0 then win = 30 end
                        if mr < 0 then
                            self:showInfo(_("数值不能为负"))
                            return
                        end
                        local new_cfg = self.settings:get_source(source_id)
                        new_cfg.rate_limit = { max_requests = mr, window_seconds = win }
                        self.settings:set_source(source_id, new_cfg)
                        -- Reset this source's rate-limit state so the new config
                        -- takes effect immediately (old timestamps cleared).
                        local SM = require("fanqie.sources")
                        SM.rate_limit_reset(source_id)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(InfoMessage:new{
                            text = _("限流设置已保存"), timeout = 2,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:getLogMenuItems()
    return {
        {
            text_func = function()
                local advanced = self.settings:get("advanced", {})
                return advanced.developer_logs and _("调试日志: 开") or _("调试日志: 关")
            end,
            checked_func = function()
                local advanced = self.settings:get("advanced", {})
                return advanced.developer_logs == true
            end,
            keep_menu_open = true,
            callback = function()
                local advanced = self.settings:get("advanced", {})
                advanced.developer_logs = not (advanced.developer_logs == true)
                self.settings:set("advanced", advanced)
                self.settings:flush()
                if advanced.developer_logs then
                    Log.info("debug logging enabled")
                end
            end,
        },
        {
            text = _("查看日志文件"),
            keep_menu_open = true,
            callback = function()
                local log_path = Log.get_log_file_path()
                if not log_path then
                    self:showInfo(_("日志文件路径未初始化"))
                    return
                end
                if not lfs or not lfs.attributes(log_path, "mode") then
                    self:showInfo(_("日志文件不存在，开启调试日志后操作插件即可生成"))
                    return
                end
                -- Copy log to a temp location for safe viewing
                local tmp_dir = DataStorage:getDataDir() .. "/tmp"
                H.make_dir(tmp_dir)
                local tmp_path = tmp_dir .. "/fanqie_log_viewer.txt"
                local src = io.open(log_path, "r")
                if not src then
                    self:showInfo(_("无法读取日志文件"))
                    return
                end
                local content = src:read("*a")
                src:close()
                if #content > 20000 then
                    content = content:sub(-20000)
                end
                local dst = io.open(tmp_path, "w")
                if not dst then
                    self:showInfo(_("无法写入临时文件"))
                    return
                end
                dst:write(content)
                dst:close()
                -- Open with file manager / text viewer
                local FileManager = safe_require("ui/filemanager")
                if FileManager then
                    local fm = FileManager:new{
                        dimen = Screen:getDeviceScreenSize(),
                        covers_fullscreen = true,
                    }
                    -- Navigate to temp dir and open the file
                    -- Simpler approach: show in text viewer
                    local TextViewer = safe_require("ui/widget/textviewer")
                    if TextViewer then
                        UIManager:show(TextViewer:new{
                            title = _("FanQie 插件日志"),
                            text = content,
                        })
                    else
                        self:showInfo(_("日志已复制到: %1", tmp_path))
                    end
                else
                    self:showInfo(_("日志已复制到: %1", tmp_path))
                end
            end,
        },
        {
            text = _("清除日志"),
            keep_menu_open = true,
            callback = function()
                Log.clear_log()
                self:showInfo(_("日志已清除"))
            end,
        },
        {
            text = _("在文件管理器中查看"),
            keep_menu_open = true,
            callback = function()
                local log_path = Log.get_log_file_path()
                if not log_path then return end
                local dir = log_path:match("^(.*)/[^/]+$") or self.settings:get_download_dir()
                local FileManager = require("apps/filemanager/filemanager")
                local RUI = require("apps/reader/readerui")
                if RUI and RUI.instance then
                    RUI.instance:onClose()
                    UIManager:scheduleIn(0.1, function()
                        FileManager:showFiles(dir)
                    end)
                else
                    FileManager:showFiles(dir)
                end
            end,
        },
    }
end

function FanQiePlugin:setPreDownloadCount(n)
    local cache = self.settings:get("cache", {})
    cache.pre_download_chapters = n
    self.settings:set("cache", cache)
    self.settings:flush()
end

function FanQiePlugin:showDownloadDirPicker(touchmenu_instance)
    local path_chooser = PathChooser:new{
        select_file = false,
        path = self.settings:get_download_dir(),
        onConfirm = function(path)
            self.settings:set_download_dir(path)
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            UIManager:show(InfoMessage:new{
                text = T(_("缓存目录已设置为:\n%1"), path),
                timeout = 2,
            })
        end,
    }
    UIManager:show(path_chooser)
end

-- ===========================================================================
-- Config file loading
-- ===========================================================================

function FanQiePlugin:loadConfigFile(silent, force)
    local plugin_path = self:getPluginPath()
    local config_path = plugin_path .. "/config.lua"
    
    local file = io.open(config_path, "r")
    if not file then return end
    file:close()
    
    local ok, config = pcall(dofile, config_path)
    if not ok or type(config) ~= "table" then return end
    
    pcall(function()
        self.settings:apply_config(config, { apply_preferences = true, force = force })
    end)
    
    if not silent then
        UIManager:show(InfoMessage:new{
            text = _("config.lua loaded."), timeout = 2,
        })
    end
end

function FanQiePlugin:getPluginPath()
    local source = debug.getinfo(1, "S").source or ""
    local path = source:match("^@(.+)$") or source
    return path:match("^(.*)/[^/]+$") or "."
end

-- ===========================================================================
-- Network check
-- ===========================================================================

function FanQiePlugin:checkNetwork()
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr and NetworkMgr.isOnline and not NetworkMgr:isOnline() then
        self:showInfo(_("未连接网络，请先开启 WiFi"))
        return false
    end
    return true
end



function FanQiePlugin:showBookList(books)
    -- 先关闭旧的书架菜单，避免后台刷新后两个书架 UI 叠在一起
    if self.book_list_menu then
        self:_cancelCoverLoading()
        UIManager:close(self.book_list_menu)
        self.book_list_menu = nil
    end

    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end

    for _, book in ipairs(books) do
        if book.cover then
            local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
            local cover_path = cover_cache_dir .. "/" .. cover_filename
            if H.file_exists(cover_path) then
                book.cover_path = cover_path
            end
        end
    end

    local ShelfView = require("fanqie.shelf_view")
    self.book_list_menu = ShelfView.show{
        title = _("番茄书架"),
        books = books,
        show_covers = true,
        on_select = function(book)
            self:_cancelCoverLoading()  -- 进入书籍时停止封面预下载，释放带宽给章节预下载
            self:showBookDetail(book)
        end,
        on_close = function()
            self:_cancelCoverLoading()
            self.book_list_menu = nil
            _state.active_menu = nil
        end,
        on_refresh = function()
            self:showBookshelf({ force_refresh = true })
        end,
        on_page_changed = function(page, first, last, current)
            self:_onShelfPage(books, current, page, first, last)
        end,
    }
    _state.active_menu = self.book_list_menu

    -- 后台批量预下载所有未缓存的封面（串行，避免阻塞 UI）
    self:_preloadAllCovers(books)
end

function FanQiePlugin:_cancelCoverLoading()
    self._cover_generation = (tonumber(self._cover_generation) or 0) + 1
    self._cover_preload_generation = (tonumber(self._cover_preload_generation) or 0) + 1
end

function FanQiePlugin:_onShelfPage(books, view, page, first, last)
    -- 只取消翻页级的封面下载，不影响 _preloadAllCovers 的全量预下载
    self._cover_generation = (tonumber(self._cover_generation) or 0) + 1
    local generation = self._cover_generation
    self:_cacheShelfPageCovers(books, view, page, first, last, generation, first)
end

function FanQiePlugin:_cacheShelfPageCovers(books, view, page, first, last, generation, index)
    index = index or first
    if generation ~= self._cover_generation or not view or view._miu_closed or tonumber(view.page or 1) ~= tonumber(page) then
        return
    end
    if index > last then return end

    local book = books[index]
    if not book or not book.cover or book.cover == "" then
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
        end)
        return
    end

    if book.cover_path then
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
        end)
        return
    end

    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end
    local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
    local cover_path = cover_cache_dir .. "/" .. cover_filename

    if H.file_exists(cover_path) then
        book.cover_path = cover_path
        local changed = false
        for _, entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id) == tostring(book.book_id or book.bookId) then
                if entry.cover_path ~= cover_path then
                    entry.cover_path = cover_path
                    changed = true
                end
                break
            end
        end
        if changed then
            view._suppress_page_callback = true
            pcall(view.updateItems, view, nil, true)
            view._suppress_page_callback = false
        end
        UIManager:scheduleIn(0.1, function()
            self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
        end)
        return
    end

    local ok, _ = pcall(function()
        local data = self.client:get_binary(book.cover)
        local file = io.open(cover_path, "wb")
        if file then
            file:write(data)
            file:close()
            book.cover_path = cover_path
            local changed = false
            for _, entry in ipairs(view.item_table or {}) do
                if tostring(entry.book_id) == tostring(book.book_id or book.bookId) then
                    if entry.cover_path ~= cover_path then
                        entry.cover_path = cover_path
                        changed = true
                    end
                    break
                end
            end
            if changed then
                view._suppress_page_callback = true
                pcall(view.updateItems, view, nil, true)
                view._suppress_page_callback = false
            end
        end
    end)

    UIManager:scheduleIn(0.1, function()
        self:_cacheShelfPageCovers(books, view, page, first, last, generation, index + 1)
    end)
end

-- 后台批量预下载所有未缓存的封面（子进程执行，不阻塞 UI）
-- 使用独立的 _cover_preload_generation，不受翻页取消影响
function FanQiePlugin:_preloadAllCovers(books)
    self._cover_preload_generation = (tonumber(self._cover_preload_generation) or 0) + 1
    local generation = self._cover_preload_generation
    local cover_cache_dir = self.settings:get_download_dir() .. "/covers"
    if H then H.make_dir(cover_cache_dir) end
    local view = self.book_list_menu
    local client = self.client

    -- 更新 UI 中指定 book_id 的封面路径
    local function update_ui_cover(book_id, cover_path)
        if not view or view._miu_closed then return end
        local changed = false
        for _, entry in ipairs(view.item_table or {}) do
            if tostring(entry.book_id) == tostring(book_id) then
                if entry.cover_path ~= cover_path then
                    entry.cover_path = cover_path
                    changed = true
                end
                break
            end
        end
        if changed then
            view._suppress_page_callback = true
            pcall(view.updateItems, view, nil, true)
            view._suppress_page_callback = false
        end
    end

    local function preload_one(idx)
        if generation ~= self._cover_preload_generation then return end
        if not view or view._miu_closed then return end
        if idx > #books then return end

        local book = books[idx]
        if not book or not book.cover or book.cover == "" then
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        -- 已有缓存路径，跳过
        if book.cover_path then
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        local cover_filename = string.gsub(book.title, "[/\\:%*%?\"<>|]", "_") .. ".jpg"
        local cover_path = cover_cache_dir .. "/" .. cover_filename
        local book_id = book.book_id or book.bookId

        -- 文件已存在，设置路径并更新 UI
        if H.file_exists(cover_path) then
            book.cover_path = cover_path
            update_ui_cover(book_id, cover_path)
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
            return
        end

        -- 子进程下载封面并写入文件，UI 线程零阻塞
        local url = book.cover
        Async.run(function()
            -- fork 继承 client/settings，子进程内同步下载并写文件
            local data = client:get_binary(url)
            local file = io.open(cover_path, "wb")
            if file then
                file:write(data)
                file:close()
                return { path = cover_path, book_id = tostring(book_id) }
            end
            return nil
        end, function(ok, result, err)
            if generation ~= self._cover_preload_generation then return end
            if ok and result and result.path then
                book.cover_path = result.path
                update_ui_cover(result.book_id, result.path)
            end
            -- 继续下一本（子进程已退出，无残留资源）
            UIManager:scheduleIn(0.05, function() preload_one(idx + 1) end)
        end, { poll_interval = 0.125, timeout = 30 })
    end

    -- 延迟启动，给书架 UI 渲染让出时间
    UIManager:scheduleIn(0.5, function() preload_one(1) end)
end

function FanQiePlugin:showBookDetail(book)
    local cached = Content.load_cache_index(self.settings, book.book_id)
    local cache_count = 0
    for _ in pairs(cached) do cache_count = cache_count + 1 end

    local buttons = {
        {
            {
                text = _("开始阅读"),
                callback = function()
                    UIManager:close(_state.detail_dialog)
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
                    self:openBook(book)
                end,
            },
            {
                text = _("章节目录"),
                callback = function()
                    UIManager:close(_state.detail_dialog)
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
                    self:showChapterListing(book)
                end,
            },
        },
        {
            {
            text = _("下载"),
            callback = function()
                UIManager:close(_state.detail_dialog)
                -- 保留 active_menu（书架），后台运行关闭下载进度对话框后可回到书架
                -- 避免 UIManager 无 widget 导致 KOReader 退出
                self:_startBookDownload(book)
            end,
        },
        },
        {
            {
                text = _("清空本书缓存"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("确定清空《%1》的缓存?\n%2 章节将被删除。"), book.title or "未知", cache_count),
                        ok_text = _("清空"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            self.settings:clear_book_cache(book.book_id)
                            UIManager:close(_state.detail_dialog)
                            UIManager:show(InfoMessage:new{
                                text = _("缓存已清空"),
                            })
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("关闭"),
                callback = function()
                    UIManager:close(_state.detail_dialog)
                end,
            },
        },
    }

    local ButtonDialog = require("ui/widget/buttondialog")
    local info_text = string.format("%s\n进度: %d/%d", book.title or "未知", book.read_chapters or 0, book.total_chapters or 0)
    if cache_count > 0 then
        info_text = info_text .. string.format(" [缓存%d章]", cache_count)
    end
    if book.desc and #book.desc > 0 then
        local short_desc = book.desc:sub(1, 200)
        if #book.desc > 200 then short_desc = short_desc .. "..." end
        info_text = info_text .. "\n\n" .. short_desc
    end

    _state.detail_dialog = ButtonDialog:new{
        title = _("书籍详情"),
        title_align = "center",
        info_text = info_text,
        buttons = buttons,
    }
    UIManager:show(_state.detail_dialog)
end

-- 异步获取目录后打开下载对话框
function FanQiePlugin:_startBookDownload(book)
    local self_ref = self
    local book_id = book.book_id
    local Async_mod = Async

    self:showBusy(_("正在获取目录..."))

    local function fetch_and_show()
        if Async_mod and Async_mod.run then
            Async_mod.run(function()
                return self_ref:get_chapters(book_id)
            end, function(ok, chapters, err)
                self_ref:closeBusy()
                if not ok or type(chapters) ~= "table" then
                    if Log then Log.error("fetch chapters failed:", log_error(err or chapters)) end
                    self_ref:showError(T(_("获取目录失败:\n%1"), display_error(err or chapters)))
                    return
                end
                -- 检查已缓存章节数量
                local cached_map = Content.load_cache_index(self_ref.settings, book_id) or {}
                local cached_count = 0
                for _ in pairs(cached_map) do cached_count = cached_count + 1 end
                require("fanqie.download").showOptionsDialog(self_ref, book, chapters, {
                    cached_count = cached_count,
                })
            end, { poll_interval = 0.3, timeout = 60 })
        else
            local ok, chapters = pcall(function()
                return self_ref:get_chapters(book_id)
            end)
            self:closeBusy()
            if not ok or type(chapters) ~= "table" then
                if Log then Log.error("fetch chapters failed:", log_error(chapters)) end
                self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
                return
            end
            local cached_map = Content.load_cache_index(self.settings, book_id) or {}
            local cached_count = 0
            for _ in pairs(cached_map) do cached_count = cached_count + 1 end
            require("fanqie.download").showOptionsDialog(self, book, chapters, {
                cached_count = cached_count,
            })
        end
    end

    -- 有缓存目录时先显示，后台刷新
    local cached_catalog = Content.load_catalog_cache(self.settings, book_id)
    if cached_catalog and #cached_catalog > 0 then
        fetch_and_show()
    else
        fetch_and_show()
    end
end

-- ===========================================================================
-- Chapter listing
-- ===========================================================================

function FanQiePlugin:showChapterListing(book, opts)
    opts = opts or {}
    local force_refresh = opts.force_refresh == true
    -- remember_page: keep the user on the same page after a refresh
    local remember_page = opts.remember_page

    -- 构建并显示目录菜单（缓存命中与异步获取共用）
    local function display_chapters(chapters)
        if not chapters or #chapters == 0 then
            self:showInfo(_("未获取到章节"))
            return
        end

        _state.current_book = book
        _state.current_chapters = chapters

        -- 刷新内存缓存：预下载可能已更新文件但内存缓存未同步，
        -- 强制重新从文件加载确保目录对号准确
        _state.invalidateChapterIndexCache(book.book_id)
        local cached = Content.load_cache_index(self.settings, book.book_id)
        local current_idx = getCurrentChapterIndex()

        -- current_chapter_index 已在切章时正确更新，优先使用。
        -- 仅当 current_chapter_index 无效（首次打开/未设置）时，
        -- 才用 book.item_id（书架记录的上次阅读章节）回退定位。
        if (not current_idx or current_idx <= 0) and book.item_id then
            for i, chapter in ipairs(chapters) do
                if tostring(chapter.itemId) == tostring(book.item_id) then
                    current_idx = i
                    break
                end
            end
        end

        local items = {}
        local cached_map = {}
        if cached then
            for item_id, _ in pairs(cached) do
                cached_map[item_id] = true
            end
        end

        for i, chapter in ipairs(chapters) do
            local title = chapter.title or ("Chapter " .. tostring(i))
            local prefix = ""
            if i == current_idx then
                prefix = "▶ "
            elseif cached_map[tostring(chapter.itemId)] then
                prefix = "✓ "
            end
            table.insert(items, {
                text = prefix .. title,
                callback = function()
                    -- 先关闭目录菜单，避免切章时菜单闪现
                    if _state.active_menu then
                        UIManager:close(_state.active_menu)
                        _state.active_menu = nil
                    end
                    self:openChapter(book, chapters, i)
                end,
            })
        end

        local items_per_page = 12
        local initial_page = remember_page or 1

        if not remember_page and current_idx > 0 then
            items.current = current_idx
            initial_page = math.ceil(current_idx / items_per_page)
        end

        local plugin = self
        local chapter_menu = Menu:new{
            title = string.format("%s - 目录", book.title or book.book_id),
            item_table = items,
            items_per_page = items_per_page,
            is_borderless = true,
            is_popout = false,
            title_bar_left_icon = "appbar.menu",
            close_callback = function()
                if _state.active_menu == chapter_menu then
                    _state.active_menu = nil
                end
            end,
        }

        -- Wire up the title-bar left icon to open a small action menu.
        -- This icon is visible on every page of the chapter list, so the user
        -- can refresh from wherever they currently are.
        chapter_menu.onLeftButtonTap = function()
            local current_page = chapter_menu.page or 1
            local ButtonDialog = require("ui/widget/buttondialog")
            local action_dialog
            action_dialog = ButtonDialog:new{
                title = _("目录操作"),
                title_align = "center",
                buttons = {
                    {{
                        text = _("刷新目录"),
                        callback = function()
                            UIManager:close(action_dialog)
                            UIManager:close(chapter_menu)
                            _state.active_menu = nil
                            -- Re-open and stay on the same page after refresh
                            plugin:showChapterListing(book, {
                                force_refresh = true,
                                remember_page = current_page,
                            })
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

        if initial_page > 1 then
            chapter_menu:onGotoPage(initial_page)
        end

        _state.active_menu = chapter_menu
        UIManager:show(chapter_menu)

        if force_refresh and not opts.silent then
            self:showInfo(_("目录已刷新"))
        end
    end

    -- Try persistent catalog cache first (so we don't hit the network every time)
    local chapters = nil
    if not force_refresh then
        chapters = Content.load_catalog_cache(self.settings, book.book_id)
        if chapters and #chapters > 0 then
            Log.debug("showChapterListing: using cached catalog, count =", #chapters)
        else
            chapters = nil
        end
    end

    -- 缓存命中：直接显示，不走网络
    if chapters and #chapters > 0 then
        display_chapters(chapters)
        return
    end

    -- 无缓存或强制刷新：子进程获取目录，UI 线程保持响应（不再卡顿）
    if not self:checkNetwork() then
        -- force_refresh 无网时回退到旧缓存
        if force_refresh then
            local cached = Content.load_catalog_cache(self.settings, book.book_id)
            if cached and #cached > 0 then
                display_chapters(cached)
                self:showInfo(_("无网络，显示缓存目录"))
                return
            end
        end
        return
    end
    self:showBusy(_("正在获取目录..."))
    local client = self.client
    local settings = self.settings
    local book_id = book.book_id
    Async.run(function()
        -- 子进程内执行 HTTP 目录获取
        local b = { book_id = book_id }
        return Content.fetch_catalog(client, b)
    end, function(ok, result, err)
        self:closeBusy()
        if not ok or type(result) ~= "table" then
            -- 获取失败：回退到旧缓存，不删除任何数据
            if force_refresh then
                local cached = Content.load_catalog_cache(settings, book.book_id)
                if cached and #cached > 0 then
                    display_chapters(cached)
                    self:showInfo(_("刷新失败，显示缓存目录"))
                    return
                end
            end
            self:showError(T(_("获取目录失败:\n%1"), display_error(err or result)))
            return
        end
        local fetched = result
        if #fetched == 0 then
            -- 空结果可能是 cookie 过期，回退到旧缓存
            if force_refresh then
                local cached = Content.load_catalog_cache(settings, book.book_id)
                if cached and #cached > 0 then
                    display_chapters(cached)
                    self:showInfo(_("获取数据为空，显示缓存目录"))
                    return
                end
            end
            self:showInfo(_("未获取到章节"))
            return
        end

        -- 获取成功：覆盖旧缓存
        Content.save_catalog_cache(settings, book_id, fetched)
        -- 同时更新内存缓存
        _state.setDirectoryCache(book_id, fetched)

        display_chapters(fetched)
    end, { poll_interval = 0.3, timeout = 60 })
end

function FanQiePlugin:showJumpToChapter(book, chapters)
    local InputDialog = require("ui/widget/inputdialog")
    local total = #chapters

    local dialog
    dialog = InputDialog:new{
        title = _("跳转到章节"),
        input = tostring(getCurrentChapterIndex() > 0 and getCurrentChapterIndex() or 1),
        input_hint = string.format("(1-%d)", total),
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("跳转"),
                    is_enter_default = true,
                    callback = function()
                        local input = dialog:getInputText()
                        local idx = tonumber(input)
                        if idx and idx >= 1 and idx <= total then
                            UIManager:close(dialog)
                            self:openChapter(book, chapters, math.floor(idx))
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("请输入 1 到 %1 之间的数字"), total),
                                timeout = 2,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function FanQiePlugin:get_chapters(book_id)
    local book = { book_id = book_id }
    return Content.fetch_catalog(self.client, book)
end

-- ===========================================================================
-- Chapter reading & auto-jump next chapter
-- ===========================================================================

function FanQiePlugin:navigateToChapter(book, chapters, chapter_index, opts)
    opts = opts or {}
    local chapter = chapters[chapter_index]
    if not chapter then
        self:showInfo(_("章节不存在"))
        return false
    end

    -- 标记章节切换中：防止段评异步回调在切章后弹窗闪现
    _state.setChapterNavigating(true)

    if _state.is_downloading then
        -- 正在下载其它章节：给用户明确提示，而不是静默失败
        _state.setChapterNavigating(false)
        self:showInfo(_("正在下载中，请稍候再试"))
        return false
    end

    _state.current_book = book
    _state.current_chapters = chapters

    -- 从全局状态获取段评开关，传递 review=true 给内容获取
    -- skip_cache_index=true：子进程不写共享索引，由父进程统一持久化
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = { skip_cache_index = true }
    if review_enabled then fetch_opts.review = true end

    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]

    -- 已缓存正文直接使用：段评数据缺失不触发重下（有些章节本就无段评）。
    -- 想要段评的用户可通过「重新获取本章节」手动重下（按当前段评开关决定是否带段评）。

    -- If not found in cache index, try to find file directly from filesystem
    if not existing_path or not H.file_exists(existing_path) then
        local found_path = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            -- Update cache index with found file
            cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, cached_chapters)
            existing_path = found_path
            if Log then Log.info("found cached chapter in filesystem:", item_id) end
        end
    end

    if existing_path and H.file_exists(existing_path) then
        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        -- 加载段评数据到全局状态
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        self:showReaderUI(existing_path, chapter)
        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
        return true
    end

    _state.is_downloading = true
    self:showBusy(T(_("正在下载: %1"), chapter.title or ""))

    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local client = self.client
    local settings = self.settings
    -- 段评获取与章节正文下载一起在子进程执行，UI 线程仅轮询，不再卡顿
    Async.run(function()
        local path, ch, para_reviews, rate_info = Content.fetch_chapter_html(client, settings, b, chapter, fetch_opts)
        return { path = path, para_reviews = para_reviews, rate_info = rate_info }
    end, function(ok, result, err)
        self:closeBusy()

        if not ok or type(result) ~= "table" or not result.path then
            Log.error("navigateToChapter download failed:", tostring(err or result))
            _state.is_downloading = false
            _state.setChapterNavigating(false)
            self:showError(T(_(opts.error_message or "下载章节失败:\n%1"), display_error(err or result)))
            return
        end

        -- 合并子进程记录的限流时间戳到父进程状态（子进程记录会随退出丢失）
        local SourceManager = require("fanqie.sources")
        SourceManager.merge_rate_limit_timestamps(result.rate_info)

        local path = result.path
        local para_reviews = result.para_reviews

        local cc = getCachedChapters(self, book)
        cc[item_id] = path
        -- 父进程统一持久化完整索引
        Content.save_cache_index(settings, book.book_id, cc)

        -- 存储段评数据到全局状态
        if review_enabled and para_reviews then
            _state.setCurrentParaReviews(para_reviews)
        end

        _state.current_chapter_index = chapter_index
        _state.pre_download_triggered = false
        _state.is_downloading = false
        self:showReaderUI(path, chapter)

        if opts.after_navigate then
            UIManager:scheduleIn(1.0, opts.after_navigate)
        end
    end, { delay = 0.1, poll_interval = 0.2, timeout = 60 })

    return true
end

function FanQiePlugin:openChapter(book, chapters, chapter_index)
    return self:navigateToChapter(book, chapters, chapter_index, {
        error_message = "下载章节失败:\n%1",
    })
end

function FanQiePlugin:showReaderUI(path, chapter)
    local ReaderUI = require("apps/reader/readerui")

    -- 章节切换已完成（新文档即将加载），清除导航标志
    _state.setChapterNavigating(false)

    local ok, err = pcall(function()
        -- 不用 switchDocument（其内部先 onClose 再 showReader，中间 forceRePaint 会闪现书架）
        -- 直接用 showReader：doShowReader 在 nextTick 中关闭旧实例并打开新实例，无闪现
        if not ReaderUI.instance then
            UIManager:broadcastEvent(Event:new("SetupShowReader"))
        end
        ReaderUI:showReader(path, nil, true)  -- seamless=true 隐藏"打开文件"提示
    end)
    if not ok then
        Log.error("showReaderUI failed:", log_error(err))
        self:showError(T(_("打开文档失败:\n%1"), display_error(err)))
        return
    end
    _state.current_document_path = path
    _state.document_opened = true
    
    if _state.current_book then
        UIManager:scheduleIn(1.0, function()
            if _state.current_book then
                getCachedChapters(self, _state.current_book)
            end
        end)
    end
end

-- Reload current chapter: delete cached file and re-download
function FanQiePlugin:reloadCurrentChapter()
    local book = _state.current_book
    local chapters = _state.current_chapters
    local current_idx = _state.current_chapter_index
    
    if not book or not chapters or not current_idx then
        self:showInfo(_("没有可重新获取的章节"))
        return
    end
    
    local chapter = chapters[current_idx]
    if not chapter then return end
    
    local item_id = tostring(chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]
    
    -- Delete cached file if exists
    if existing_path and H.file_exists(existing_path) then
        os.remove(existing_path)
        if Log then Log.info("deleted cached chapter:", item_id) end
    end
    
    -- Also try to delete from expected location
    local expected_path = Content.book_cache_dir(self.settings, book.book_id) .. "/chapter_" .. item_id .. ".html"
    if H.file_exists(expected_path) then
        os.remove(expected_path)
        if Log then Log.info("deleted expected chapter file:", item_id) end
    end

    -- 删除段评数据索引文件，确保重新获取
    local para_reviews_path = Content.book_cache_dir(self.settings, book.book_id) .. "/para_reviews_" .. item_id .. ".lua"
    if H.file_exists(para_reviews_path) then
        os.remove(para_reviews_path)
        if Log then Log.info("deleted para_reviews index:", item_id) end
    end
    _state.clearParaReviews()

    -- Clear cache index entry
    cached_chapters[item_id] = nil
    Content.save_cache_index(self.settings, book.book_id, cached_chapters)
    
    -- Re-download
    self:navigateToChapter(book, chapters, current_idx, {
        error_message = "重新获取章节失败:\n%1",
    })
end

function FanQiePlugin:preDownloadChapters(book, chapters, current_index)
    local cache = self.settings:get("cache", {})
    local pre_download_count = cache.pre_download_chapters or 3
    local total = #chapters

    if current_index >= total then return end

    -- 段评模式：预下载也传递 review=true；skip_cache_index 由父进程统一持久化索引
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = { skip_cache_index = true }
    if review_enabled then fetch_opts.review = true end

    local cached_chapters = getCachedChapters(self, book)
    local client = self.client
    local settings = self.settings

    -- 顺序下载：每章在子进程执行（HTTP + 图片下载 + 落盘均在子进程），
    -- 父进程 UI 线程只做轻量轮询，不再因预下载卡顿阅读。
    local function download_one(offset)
        if _state.is_downloading then
            -- 用户正在主动下载章节，稍后重试
            UIManager:scheduleIn(1.0, function()
                download_one(offset)
            end)
            return
        end

        if offset > pre_download_count or current_index + offset > total then
            _state.pre_download_triggered = false
            Log.debug("pre-download: batch completed")
            return
        end

        local target_idx = current_index + offset
        local chapter = chapters[target_idx]
        local item_id = tostring(chapter.itemId)

        local already_cached = cached_chapters[item_id] and H.file_exists(cached_chapters[item_id])
        -- 已缓存正文直接跳过：段评数据缺失不触发重下

        if already_cached then
            Log.debug("pre-download: chapter", target_idx, "already cached")
            UIManager:scheduleIn(0, function() download_one(offset + 1) end)
            return
        end

        Log.info("pre-download: starting download for chapter", target_idx)
        local b = { book_id = book.book_id, title = book.title, author = book.author }
        -- 置 is_downloading：让 onEndOfBook/navigateToChapter 感知预下载进行中，
        -- 避免与它们重复下载同一章；on_done 中先清零再调度下一章。
        _state.is_downloading = true
        Async.run(function()
            -- 子进程内执行：抓取正文 + 段评 + 图片下载 + 保存 HTML
            -- skip_cache_index=true，不写共享 cache_index.lua（由父进程统一持久化）
            local path, _ch, _rev, rate_info = Content.fetch_chapter_html(client, settings, b, chapter, fetch_opts)
            return { path = path, rate_info = rate_info }
        end, function(ok, result, err)
            -- 先清零，确保调度下一章时 download_one 不会被自己卡住
            _state.is_downloading = false
            local path = type(result) == "table" and result.path or nil
            if ok and path then
                -- 合并子进程记录的限流时间戳，保证后续预下载限流准确
                local SourceManager = require("fanqie.sources")
                SourceManager.merge_rate_limit_timestamps(result.rate_info)
                cached_chapters[item_id] = path
                -- 父进程统一持久化完整索引，避免与子进程争写
                Content.save_cache_index(settings, book.book_id, cached_chapters)
                Log.info("pre-download: completed chapter", target_idx)
            else
                Log.warn("pre-download: failed chapter", target_idx, ":", err)
            end
            -- 继续下一章
            UIManager:scheduleIn(0, function() download_one(offset + 1) end)
        end, { poll_interval = 0.2, timeout = 60 })
    end

    -- Delay start so user sees the current chapter first
    UIManager:scheduleIn(2.0, function()
        download_one(1)
    end)
end

-- Get current page progress within the chapter (0.0 - 1.0)
function FanQiePlugin:getCurrentPageProgress()
    if self.ui and self.ui.document then
        local doc = self.ui.document
        if doc.info and doc.info.number_of_pages and doc.info.number_of_pages > 0 then
            local current_page = self.ui.state and self.ui.state.page or 1
            return math.min(current_page / doc.info.number_of_pages, 1.0)
        end
    end
    return 0
end

-- Sync reading progress to server (called on chapter end and document close)
-- 通过 Async 子进程上传，HTTP 请求在子进程执行，UI 线程仅做轻量轮询，
-- 不再阻塞界面（消除章节开始 / 每 10 页时的几秒卡顿）。
function FanQiePlugin:syncCurrentProgress()
    if not _state.current_book or not _state.current_chapters then return end
    local idx = _state.current_chapter_index
    if not idx or idx < 1 then return end
    local chapter = _state.current_chapters[idx]
    if not chapter or not chapter.itemId or not _state.current_book.book_id then
        return
    end
    local progress = self:getCurrentPageProgress()
    local last_report = _state.getLastProgressReport(chapter.itemId)
    if last_report and last_report.progress >= progress then
        return
    end

    -- 提前拷贝，避免子进程闭包依赖可变的全局状态
    local book_id = _state.current_book.book_id
    local item_id = chapter.itemId
    local chapter_idx = idx - 1
    local client = self.client
    local start_time = os.clock()

    Async.run(function()
        -- 在子进程中执行阻塞 HTTP POST
        client:update_read_progress(book_id, item_id, chapter_idx, progress)
        return true
    end, function(ok, _result, err)
        Log.info("syncCurrentProgress completed in",
            string.format("%.3f", os.clock() - start_time), "seconds")
        if ok then
            _state.setLastProgressReport(item_id, progress)
            _state.removePendingProgress(book_id, item_id)
        else
            if Log then Log.warn("syncCurrentProgress failed:", err) end
            _state.addPendingProgress(book_id, item_id, chapter_idx, progress)
        end
    end, { delay = 0.1, poll_interval = 0.2, timeout = 30 })
end

-- Retry pending progress reports when network is available
-- 每条待上传进度在子进程执行，顺序处理，UI 线程不阻塞。
function FanQiePlugin:retryPendingProgress()
    local book_id = _state.current_book and _state.current_book.book_id
    if not book_id then return end

    local start_time = os.clock()
    UIManager:scheduleIn(0.5, function()
        local pending = _state.getPendingProgress()
        -- 收集本书的待上传条目为顺序列表
        local queue = {}
        for key, item in pairs(pending) do
            if item.book_id == book_id then
                table.insert(queue, item)
            end
        end
        local total = #queue
        if total == 0 then return end

        local client = self.client
        local function process_next(i)
            if i > total then
                Log.info("retryPendingProgress completed", total,
                    "items in", string.format("%.3f", os.clock() - start_time), "seconds")
                return
            end
            local item = queue[i]
            Async.run(function()
                client:update_read_progress(item.book_id, item.item_id, item.chapter_idx, item.progress)
                return true
            end, function(ok, _r, err)
                if ok then
                    _state.setLastProgressReport(item.item_id, item.progress)
                    _state.removePendingProgress(item.book_id, item.item_id)
                else
                    if Log then Log.warn("retryPendingProgress item failed:", item.item_id, err) end
                end
                -- 处理下一条
                UIManager:scheduleIn(0, function() process_next(i + 1) end)
            end, { poll_interval = 0.2, timeout = 30 })
        end
        process_next(1)
    end)
end

function FanQiePlugin:onPageUpdate(pageno)
    if not _state.current_book or not _state.current_chapters then
        return
    end
    if not self:isCurrentDocFanqie() then
        return
    end

    if not self.ui or not self.ui.document then return end

    local doc = self.ui.document
    local total_pages = doc:getPageCount()
    if not total_pages or total_pages <= 0 then return end

    _state.last_page_number = pageno

    -- Only trigger pre-download after user has read past 50% of the chapter
    -- This avoids triggering immediately on chapter open for short chapters
    local progress = pageno / total_pages
    if progress > 0.5 and not _state.pre_download_triggered then
        _state.pre_download_triggered = true
        UIManager:scheduleIn(1.0, function()
            self:preDownloadChapters(_state.current_book, _state.current_chapters, _state.current_chapter_index)
        end)
    end

    if pageno % 10 == 0 then
        self:syncCurrentProgress()
    end
end

-- Handle "previous chapter" signal from patched ReaderPaging.
-- Triggered only when user presses "previous page" while on page 1.
function FanQiePlugin:onFanQiePrevChapter()
    if not _state.current_book or not _state.current_chapters then
        return false
    end
    if not self:isCurrentDocFanqie() then
        return false
    end

    if _state.start_of_chapter_triggered then
        return false
    end

    local current_idx = getCurrentChapterIndex()
    if current_idx <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("已经是第一章了"),
            timeout = 3,
        })
        return true
    end

    _state.start_of_chapter_triggered = true
    _state.setChapterNavigating(true)

    local prev_idx = current_idx - 1
    local chapters = _state.current_chapters
    local book = _state.current_book
    local prev_chapter = chapters[prev_idx]
    if not prev_chapter then
        _state.start_of_chapter_triggered = false
        return true
    end

    local item_id = tostring(prev_chapter.itemId)
    local cached_chapters = getCachedChapters(self, book)
    local existing_path = cached_chapters[item_id]
    local path = existing_path

    -- 段评模式：段评开关决定首次下载是否带段评；已缓存正文直接用，缺段评不重下
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = { skip_cache_index = true }
    if review_enabled then fetch_opts.review = true end

    -- 下载完成后的跳章逻辑（缓存命中与异步下载共用）
    local function finish_prev(p)
        -- 加载段评数据
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        _state.current_chapter_index = prev_idx
        _state.pre_download_triggered = false
        _state.last_page_number = nil
        self:showReaderUI(p, prev_chapter)
        UIManager:scheduleIn(1.0, function()
            _state.start_of_chapter_triggered = false
            self:syncCurrentProgress()
            self:preDownloadChapters(book, chapters, prev_idx)
            self:retryPendingProgress()
        end)
    end

    if not existing_path or not H.file_exists(existing_path) then
        -- Try to find file directly from filesystem
        local found_path = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found_path then
            cached_chapters[item_id] = found_path
            Content.save_cache_index(self.settings, book.book_id, cached_chapters)
            path = found_path
        else
            self:showBusy(T(_("正在下载: %1"), prev_chapter.title or ""))
            local b = { book_id = book.book_id, title = book.title, author = book.author }
            local client = self.client
            local settings = self.settings
            Async.run(function()
                local path, _ch, _rev, rate_info = Content.fetch_chapter_html(client, settings, b, prev_chapter, fetch_opts)
                return { path = path, rate_info = rate_info }
            end, function(ok, result, err)
                self:closeBusy()
                if not ok or type(result) ~= "table" or not result.path then
                    Log.error("onFanQiePrevChapter download failed:", tostring(err or result))
                    _state.start_of_chapter_triggered = false
                    _state.setChapterNavigating(false)
                    self:showError(T(_("加载上一章失败:\n%1"), display_error(err or result)))
                    return
                end
                local SourceManager = require("fanqie.sources")
                SourceManager.merge_rate_limit_timestamps(result.rate_info)
                local cc = getCachedChapters(self, book)
                cc[item_id] = result.path
                Content.save_cache_index(settings, book.book_id, cc)
                finish_prev(result.path)
            end, { delay = 0.1, poll_interval = 0.2, timeout = 60 })
            return true  -- 异步下载，完成后跳章
        end
    end

    finish_prev(path)
    return true
end

function FanQiePlugin:onEndOfBook()
    if not _state.current_book or not _state.current_chapters then
        return false
    end
    
    local is_fanqie = self:isCurrentDocFanqie()
    if not is_fanqie then
        return false
    end

    -- 重入保护：异步跳章期间，忽略末页重复触发的事件，避免重复下载下一章
    if _state.end_of_book_jumping then
        return true
    end

    local current_idx = getCurrentChapterIndex()
    local chapters = _state.current_chapters
    local book = _state.current_book

    if book.book_id and current_idx > 0 then
        local chapter = chapters[current_idx]
        if chapter and chapter.itemId then
            local last_report = _state.getLastProgressReport(chapter.itemId)
            if not last_report or last_report.progress < 1.0 then
                local book_id = book.book_id
                local item_id = chapter.itemId
                local idx = current_idx
                local client = self.client
                -- 子进程上传进度=1.0，避免阻塞末页翻章体验
                Async.run(function()
                    client:update_read_progress(book_id, item_id, idx - 1, 1.0)
                    return true
                end, function(ok, _r, err)
                    if ok then
                        _state.setLastProgressReport(item_id, 1.0)
                        _state.removePendingProgress(book_id, item_id)
                    else
                        if Log then Log.warn("onEndOfBook progress upload failed:", err) end
                        _state.addPendingProgress(book_id, item_id, idx - 1, 1.0)
                    end
                end, { delay = 0.1, poll_interval = 0.2, timeout = 30 })
            end
        end
    end

    local next_idx = current_idx + 1

    if next_idx > #chapters then
        UIManager:show(InfoMessage:new{
            text = _("已经是最后一章了"),
            timeout = 3,
        })
        return true
    end

    local next_chapter = chapters[next_idx]
    if not next_chapter then
        return true
    end

    -- 下一章切换：段评获取与正文下载在子进程执行，UI 线程保持响应。
    -- busy 对话框期间界面不冻结；事件返回 true 使文档保持打开，
    -- 异步完成后由 finish_next 跳转下一章。
    _state.setChapterNavigating(true)
    local item_id = tostring(next_chapter.itemId)
    local review_enabled = _state.isReviewEnabled()
    local fetch_opts = { skip_cache_index = true }
    if review_enabled then fetch_opts.review = true end

    -- 下载完成后的跳章逻辑（缓存命中与异步下载共用）
    local function finish_next(p)
        -- 加载段评数据
        if review_enabled then
            local reviews = Content.load_para_reviews_index(self.settings, book.book_id, item_id)
            _state.setCurrentParaReviews(reviews)
        end
        _state.current_chapter_index = next_idx
        _state.pre_download_triggered = false
        self:showReaderUI(p, next_chapter)
        UIManager:scheduleIn(1.0, function()
            self:preDownloadChapters(book, chapters, next_idx)
            self:retryPendingProgress()
        end)
    end

    -- 解析下一章缓存路径（已缓存正文直接用，缺段评不重下；文件系统回退查找）
    local function resolve_cached_path()
        local cached_chapters = getCachedChapters(self, book)
        local p = cached_chapters[item_id]
        if p and H.file_exists(p) then
            return p
        end
        local found = Content.find_chapter_file(self.settings, book.book_id, item_id)
        if found then
            local cc = getCachedChapters(self, book)
            cc[item_id] = found
            Content.save_cache_index(self.settings, book.book_id, cc)
            return found
        end
        return nil
    end

    -- 1) 快速路径：缓存命中直接跳章（同步完成，无需重入保护）
    local cached_path = resolve_cached_path()
    if cached_path then
        finish_next(cached_path)
        return true
    end

    -- 2) 异步下载路径：标记重入，避免末页重复触发下载同一章
    _state.end_of_book_jumping = true

    local b = { book_id = book.book_id, title = book.title, author = book.author }
    local client = self.client
    local settings = self.settings

    -- showBusy 幂等包装：等待路径可能已显示 busy，避免重复 show 泄漏对话框
    local function ensure_busy(text)
        if not self._busy_msg then
            self:showBusy(text)
        end
    end

    -- 启动下载：同时置 is_downloading，让预下载 download_one 检测后延后重试，
    -- 避免与预下载争用同一书源限流配额 / 争写缓存索引。
    local function start_download()
        _state.is_downloading = true
        ensure_busy(T(_("正在下载: %1"), next_chapter.title or ""))
        Async.run(function()
            local path, _ch, _rev, rate_info = Content.fetch_chapter_html(client, settings, b, next_chapter, fetch_opts)
            return { path = path, rate_info = rate_info }
        end, function(ok, result, err)
            self:closeBusy()
            if not ok or type(result) ~= "table" or not result.path then
                Log.error("onEndOfBook download failed:", tostring(err or result))
                _state.is_downloading = false
                _state.end_of_book_jumping = false
                _state.setChapterNavigating(false)
                self:showError(T(_("加载下一章失败:\n%1"), display_error(err or result)))
                return
            end
            local SourceManager = require("fanqie.sources")
            SourceManager.merge_rate_limit_timestamps(result.rate_info)
            local cc = getCachedChapters(self, book)
            cc[item_id] = result.path
            Content.save_cache_index(settings, book.book_id, cc)
            _state.is_downloading = false
            _state.end_of_book_jumping = false
            finish_next(result.path)
        end, { delay = 0.1, poll_interval = 0.2, timeout = 60 })
    end

    -- 若预下载正在进行（is_downloading=true），先等待其完成再决定是否需要自己下载：
    -- 预下载可能正在下载本章，完成后即可走缓存命中路径，避免重复下载。
    -- 每轮先查缓存，命中即跳；未命中且仍有下载在进行则继续等（最多 ~60s）。
    if _state.is_downloading then
        ensure_busy(T(_("正在准备: %1"), next_chapter.title or ""))
        local waits = 0
        local function wait_then_download()
            -- 优先查缓存：预下载可能已缓存本章
            local p = resolve_cached_path()
            if p then
                self:closeBusy()
                _state.end_of_book_jumping = false
                finish_next(p)
                return
            end
            if _state.is_downloading then
                waits = waits + 1
                if waits > 120 then
                    -- 等待超时（is_downloading 异常卡死），强制自己下载
                    Log.warn("onEndOfBook: wait for is_downloading timeout, force download")
                    start_download()
                    return
                end
                UIManager:scheduleIn(0.5, wait_then_download)
                return
            end
            -- 无下载在进行且未缓存，自己下载
            start_download()
        end
        UIManager:scheduleIn(0.5, wait_then_download)
    else
        start_download()
    end
    return true  -- 事件已处理，文档保持打开，异步完成后跳章
end

function FanQiePlugin:onCloseDocument()
    if not self:isCurrentDocFanqie() then
        return
    end
    self:syncCurrentProgress()
    _state.current_document_path = nil
    _state.setTocMenuOpen(false)
    _state.pre_download_triggered = false
    _state.last_page_number = nil
    _state.document_opened = false
    _state.setChapterNavigating(false)
end

function FanQiePlugin:onClose()
    if _state.active_menu then
        UIManager:close(_state.active_menu)
        _state.active_menu = nil
    end
    if _state.detail_dialog then
        UIManager:close(_state.detail_dialog)
        _state.detail_dialog = nil
    end
    if _state.toc_menu then
        UIManager:close(_state.toc_menu)
        _state.toc_menu = nil
    end
    _state.setTocMenuOpen(false)
end

function FanQiePlugin:onCloseWidget()
    self:onClose()
end

function FanQiePlugin:onShowFanQieToc()
    if not (_state.current_book and _state.current_chapters) then
        return false
    end
    if not self:isCurrentDocFanqie() then
        return false
    end
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = true
    end

    self:syncCurrentProgress()
    -- Reuse showChapterListing so the reader-side TOC also gets the
    -- persistent catalog cache and the refresh button.
    self:showChapterListing(_state.current_book)
    return true
end

function FanQiePlugin:onShowFanQieBookshelf()
    -- 手势「番茄书架」：任何上下文（FileManager / Reader）都直接打开书架。
    -- 书架 widget 压栈显示，底层阅读器仍在，选择书目后自行导航，不会破坏进度。
    self:showBookshelf()
    return true
end

-- ===========================================================================
-- Cache management
-- ===========================================================================

function FanQiePlugin:getCacheMenuItems()
    local items = {}
    local stats = self.settings:get_cache_stats()
    local size_mb = stats.total_size / (1024 * 1024)

    table.insert(items, {
        text = string.format(_("缓存统计: %d 本书, %d 章节, %.1f MB"), stats.book_count, stats.chapter_count, size_mb),
        enabled_func = function() return false end,
    })
    table.insert(items, {
        text = _("查看缓存目录"),
        keep_menu_open = true,
        callback = function()
            local dir = self.settings:get_download_dir()
            local FileManager = require("apps/filemanager/filemanager")
            local RUI = require("apps/reader/readerui")
            if RUI and RUI.instance then
                RUI.instance:onClose()
                UIManager:scheduleIn(0.1, function()
                    FileManager:showFiles(dir)
                end)
            else
                FileManager:showFiles(dir)
            end
        end,
    })
    table.insert(items, {
        text = _("刷新章节缓存"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("确定刷新章节缓存?\n下次打开书籍时将重新获取最新章节列表。"),
                ok_text = _("刷新"),
                cancel_text = _("取消"),
                ok_callback = function()
                    _state.invalidateAllCache()
                    self:clearShelfCache()
                    UIManager:show(InfoMessage:new{
                        text = _("章节缓存已刷新"),
                    })
                end,
            })
        end,
    })
    table.insert(items, {
        text = _("清除全部缓存"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = string.format(_("确定清除所有番茄小说缓存?\n%d 本书, %d 章节将被删除。"), stats.book_count, stats.chapter_count),
                ok_text = _("清除"),
                cancel_text = _("取消"),
                ok_callback = function()
                    self.settings:clear_all_cache()
                    self:clearShelfCache()
                    _state.invalidateAllCache()
                    UIManager:show(InfoMessage:new{
                        text = _("缓存已清除"),
                    })
                end,
            })
        end,
    })
    return items
end

-- ===========================================================================
-- Download management
-- ===========================================================================

function FanQiePlugin:showDownloadManager()
    local self_ref = self
    local dialog
    -- 定时刷新控制标志（Menu 关闭后停止刷新）
    local refresh_active = true

    -- 调试日志
    local task = _state.getDownloadTask()
    local history = _state.getDownloadHistory()
    if Log and Log.info then
        Log.info("[DownloadMgr] open: task=" .. tostring(task and task.book_title or "nil")
            .. " task_status=" .. tostring(task and task.status or "nil")
            .. " history_count=" .. tostring(#history))
    end

    -- 构建进度条文本（墨水屏友好的纯文本进度条）
    local function buildProgressText(current, total)
        if not total or total <= 0 then return "0%" end
        local pct = math.floor((current or 0) / total * 100)
        -- 10 格进度条，每格代表 10%
        local filled = math.floor(pct / 10)
        local bar = string.rep("█", filled) .. string.rep("░", 10 - filled)
        return string.format("%s %d%% (%d/%d)", bar, pct, current or 0, total)
    end

    -- 构建 Menu items
    local function buildItems()
        local items = {}
        local task = _state.getDownloadTask()
        if Log and Log.info then
            Log.info("[DownloadMgr] buildItems: task=" .. tostring(task and task.book_title or "nil")
                .. " status=" .. tostring(task and task.status or "nil"))
        end

        -- 当前下载任务
        if task and task.status == "downloading" then
            table.insert(items, {
                text = T(_("正在下载: 《%1》"), task.book_title or task.book_id or "未知"),
                enabled_func = function() return false end,
            })
            table.insert(items, {
                text = buildProgressText(task.current, task.total),
                enabled_func = function() return false end,
            })
            if task.chapter and task.chapter ~= "" then
                table.insert(items, {
                    text = T(_("当前: %1"), task.chapter),
                    enabled_func = function() return false end,
                    separator = true,
                })
            else
                table.insert(items, { text = "", separator = true })
            end
            table.insert(items, {
                text = _("取消下载"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("确定取消《%1》的下载?"), task.book_title or "未知"),
                        ok_text = _("确定"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            _state.clearDownloadTask()
                            self_ref:showInfo(_("已取消下载"))
                            -- 刷新列表
                            if dialog and dialog.updateItems then
                                dialog.item_table = buildItems()
                                dialog:updateItems()
                            end
                        end,
                    })
                end,
            })
            table.insert(items, { text = "", separator = true })
        else
            table.insert(items, {
                text = _("当前无下载任务"),
                enabled_func = function() return false end,
            })
            table.insert(items, { text = "", separator = true })
        end

        -- 历史下载记录
        local history = _state.getDownloadHistory()
        if #history > 0 then
            table.insert(items, {
                text = _("最近下载记录:"),
                enabled_func = function() return false end,
            })
            for i, h in ipairs(history) do
                local status_text = h.status == "completed" and _("完成")
                    or (h.status == "interrupted" and _("中断") or _("取消"))
                local time_str = h.end_time and os.date("%m-%d %H:%M", h.end_time) or ""
                table.insert(items, {
                    text = T(_("《%1》 - %2 %3"), h.book_title or h.book_id or "未知", status_text, time_str),
                    enabled_func = function() return false end,
                })
            end
            table.insert(items, { text = "", separator = true })
            table.insert(items, {
                text = _("清空历史记录"),
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("确定清空所有下载历史记录?"),
                        ok_text = _("确定"),
                        cancel_text = _("取消"),
                        ok_callback = function()
                            _state.clearDownloadHistory()
                            self_ref:showInfo(_("已清空历史记录"))
                            if dialog and dialog.updateItems then
                                dialog.item_table = buildItems()
                                dialog:updateItems()
                            end
                        end,
                    })
                end,
            })
        end

        if Log and Log.info then
            Log.info("[DownloadMgr] buildItems: items_count=" .. tostring(#items))
        end
        return items
    end

    dialog = Menu:new{
        title = _("下载管理"),
        item_table = buildItems(),
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            refresh_active = false
            _state.active_menu = nil
        end,
    }
    _state.active_menu = dialog
    UIManager:show(dialog)

    -- 定时刷新当前下载进度（2秒间隔，墨水屏友好）
    local function refreshProgress()
        if not refresh_active then return end
        if not dialog then return end

        local task = _state.getDownloadTask()
        if task and task.status == "downloading" then
            -- 有下载任务，刷新列表
            dialog.item_table = buildItems()
            if dialog.updateItems then
                dialog:updateItems()
            end
            -- 继续定时刷新
            UIManager:scheduleIn(2, refreshProgress)
        else
            -- 下载完成或取消，最后刷新一次
            dialog.item_table = buildItems()
            if dialog.updateItems then
                dialog:updateItems()
            end
        end
    end

    -- 如果有下载任务，启动定时刷新
    local task = _state.getDownloadTask()
    if task and task.status == "downloading" then
        UIManager:scheduleIn(2, refreshProgress)
    end
end

function FanQiePlugin:getCacheSizeMB()
    local total = 0
    local dir = self.settings:get_download_dir()
    local ok = pcall(function()
        local function walk(path)
            for entry in lfs.dir(path) do
                if entry ~= "." and entry ~= ".." then
                    local full = path .. "/" .. entry
                    local attr = lfs.attributes(full)
                    if attr then
                        if attr.mode == "directory" then
                            walk(full)
                        else
                            total = total + attr.size
                        end
                    end
                end
            end
        end
        walk(dir)
    end)
    return total / (1024 * 1024)
end

function FanQiePlugin:clearAllCache()
    local dir = self.settings:get_download_dir()
    if not dir then
        self:showInfo(_("下载目录未设置"))
        return
    end

    local ProgressWidget = require("ui/widget/progresswidget")
    local progress = ProgressWidget:new{
        width = Screen:getWidth() - 100,
        height = 8,
    }
    local progress_dialog = InfoMessage:new{
        text = _("正在清除缓存..."),
        timeout = 0,
        dismissable = false,
        icon = "info",
        additional_widgets = { progress },
    }
    UIManager:show(progress_dialog)

    local total_files = 0
    local function count_files(path)
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local full = path .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        count_files(full)
                    end
                    total_files = total_files + 1
                end
            end
        end
    end
    count_files(dir)

    local removed_count = 0
    local function remove_tree(path)
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local full = path .. "/" .. entry
                local attr = lfs.attributes(full)
                if attr then
                    if attr.mode == "directory" then
                        remove_tree(full)
                        lfs.rmdir(full)
                    else
                        os.remove(full)
                    end
                    removed_count = removed_count + 1
                    if total_files > 0 then
                        progress:setProgress(removed_count / total_files)
                    end
                    UIManager:forceRePaint()
                end
            end
        end
    end

    pcall(remove_tree, dir)
    UIManager:close(progress_dialog)
    self:showInfo(string.format(_("缓存已清除\n共删除 %d 个文件"), removed_count))
end

-- ===========================================================================
-- Book opening (from bookshelf or direct)
-- ===========================================================================

-- 用缓存目录进入阅读（离线模式或网络获取失败时的回退路径）
function FanQiePlugin:_openBookWithCache(book, cached_chapters)
    if not cached_chapters or #cached_chapters == 0 then return end
    UIManager:scheduleIn(0.1, function()
        getCachedChapters(self, book)
    end)
    -- 从 book.item_id（书架中的上次阅读章节）找起始索引
    local start_index = 1
    if book.item_id then
        local target_item_id = tostring(book.item_id)
        for idx, ch in ipairs(cached_chapters) do
            if tostring(ch.itemId or ch.item_id) == target_item_id then
                start_index = idx
                break
            end
        end
    end
    -- 如果上次阅读的章节没有缓存，向后找第一个有缓存的章节
    local chapter_cache = Content.load_cache_index(self.settings, book.book_id)
    if chapter_cache then
        local start_item_id = tostring(cached_chapters[start_index].itemId or cached_chapters[start_index].item_id or "")
        if not chapter_cache[start_item_id] then
            if Log then Log.info("openBook: last read chapter not cached, finding next cached") end
            for idx = start_index, #cached_chapters do
                local item_id = tostring(cached_chapters[idx].itemId or cached_chapters[idx].item_id or "")
                if chapter_cache[item_id] then
                    start_index = idx
                    break
                end
            end
        end
    end
    if Log then Log.info("openBookWithCache: start_index=" .. start_index) end
    self:openChapter(book, cached_chapters, start_index)
end

function FanQiePlugin:openBook(book)
    if not self.patches_ok then
        Patches.install()
        self.patches_ok = true
    end
    _state.current_book = book

    -- 先尝试目录缓存（本地 IO，不阻塞）
    local cached_chapters = Content.load_catalog_cache(self.settings, book.book_id)
    local has_cache = cached_chapters and #cached_chapters > 0

    -- 无缓存 + 无网络：提示用户联网
    if not has_cache and not self:checkNetwork() then
        return
    end

    -- 有缓存 + 无网络：离线模式，直接用缓存打开，跳过云端进度同步
    if has_cache and not self:checkNetwork() then
        if Log then Log.info("openBook: offline mode, using cached chapters") end
        self:_openBookWithCache(book, cached_chapters)
        return
    end

    -- 有网络（无论是否有缓存）：子进程获取目录（缓存未命中时）+ 阅读进度
    self:showBusy(_("正在获取目录..."))
    local client = self.client
    local settings = self.settings
    local book_id = book.book_id
    local pull_progress = settings:get("sync", {}).pull_on_open ~= false

    Async.run(function()
        -- 子进程：始终拉取最新目录（有缓存也刷新，获取新章节）；按设置拉取阅读进度
        local b = { book_id = book_id }
        local fetched = Content.fetch_catalog(client, b)
        local progress = nil
        if pull_progress then
            local ok_p, p = pcall(function() return client:fetch_read_progress() end)
            if ok_p then progress = p end
        end
        -- 多值打包成 table（Async.run work_func 只能返回单值）
        return { chapters = fetched, progress = progress }
    end, function(ok, result, err)
        self:closeBusy()
        if not ok or type(result) ~= "table" then
            -- 获取失败：有缓存则回退到缓存进入阅读
            if has_cache then
                if Log then Log.warn("openBook: fetch failed, fallback to cached chapters") end
                self:_openBookWithCache(book, cached_chapters)
                return
            end
            self:showError(T(_("获取目录失败:\n%1"), display_error(err or result)))
            return
        end

        -- 优先用子进程新拉取的目录，回退到缓存
        local chapters = result.chapters or (has_cache and cached_chapters or nil)
        if not chapters or #chapters == 0 then
            -- 新目录为空（可能 cookie 过期）：有缓存则回退
            if has_cache then
                if Log then Log.warn("openBook: fetched empty chapters, fallback to cache") end
                self:_openBookWithCache(book, cached_chapters)
                return
            end
            self:showInfo(_("未获取到章节"))
            return
        end

        -- 持久化新拉取的目录（缓存命中时不重复写）
        if result.chapters and #result.chapters > 0 then
            Content.save_catalog_cache(settings, book_id, result.chapters)
            _state.setDirectoryCache(book_id, result.chapters)
        end

        UIManager:scheduleIn(0.1, function()
            getCachedChapters(self, book)
        end)

        -- 从云端进度中找到起始章节
        local start_index = 1
        if result.progress and result.progress.data then
            for _, item in ipairs(result.progress.data) do
                if tostring(item.book_id or item.bookId) == tostring(book_id) then
                    local target_item_id = tostring(item.item_id or item.itemId)
                    if target_item_id and target_item_id ~= "" then
                        for idx, ch in ipairs(chapters) do
                            if tostring(ch.itemId or ch.item_id) == target_item_id then
                                start_index = idx
                                break
                            end
                        end
                    end
                    break
                end
            end
        end

        -- 云端进度未命中当前书籍时，回退到 book.item_id（书架中的上次阅读章节）
        if start_index == 1 and book.item_id then
            local target_item_id = tostring(book.item_id)
            for idx, ch in ipairs(chapters) do
                if tostring(ch.itemId or ch.item_id) == target_item_id then
                    start_index = idx
                    break
                end
            end
            if start_index > 1 and Log then
                Log.info("openBook: cloud progress miss, fallback to book.item_id, start_index=" .. start_index)
            end
        end

        if start_index > #chapters then
            start_index = 1
        end

        self:openChapter(book, chapters, start_index)
    end, { poll_interval = 0.3, timeout = 60 })
end

-- ===========================================================================
-- UI helpers
-- ===========================================================================

function FanQiePlugin:showBusy(text)
    self._busy_msg = InfoMessage:new{ text = text, norefresh = true }
    UIManager:show(self._busy_msg)
    UIManager:forceRePaint()
end

function FanQiePlugin:closeBusy()
    if self._busy_msg then
        UIManager:close(self._busy_msg)
        self._busy_msg = nil
    end
end

function FanQiePlugin:showInfo(text)
    UIManager:show(InfoMessage:new{ text = text })
end

function FanQiePlugin:showError(text)
    UIManager:show(InfoMessage:new{ text = text, norefresh = false })
end

return FanQiePlugin
