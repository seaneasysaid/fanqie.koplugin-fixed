local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local T = _

local ok_device, device = pcall(require, "device")
local Screen = ok_device and device.screen or nil
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Menu, Menu = pcall(require, "ui/widget/menu")
local ok_InputDialog, InputDialog = pcall(require, "ui/widget/inputdialog")

local ok_H, H = pcall(require, "fanqie.helper")
local ok_Log, Log = pcall(require, "fanqie.logger")
local ok_Content, Content = pcall(require, "fanqie.content")
local ok_state, _state = pcall(require, "fanqie.state")
local ok_Async, Async = pcall(require, "fanqie.async")
local ok_FanQie, FanQie = pcall(require, "fanqie.fanqie")
local ok_CoverCache, CoverCache = pcall(require, "fanqie.cover_cache")
local ok_ReviewPics, ReviewPics = pcall(require, "fanqie.review_pics")
local ok_BookNames, BookNames = pcall(require, "fanqie.book_names")

-- 书架内存缓存：内存主源 + 文件后备
-- 存精简后的 books 数组（与 shelf_cache.lua 同构）。
-- 与 client.lua 的 SHELF_CACHE 职责区分：
--   - SHELF_MEM_CACHE（本变量）：显示层数据源，进程生命周期内有效，无 TTL
--   - SHELF_CACHE（client.lua）：fetch_shelf_detail 内部短缓存，按 cookie_hash 做 key，
--     10 分钟 TTL，避免短时间内重复网络请求
local SHELF_MEM_CACHE = nil

local function log_error(err)
    local text = tostring(err):gsub("[%c]+", " ")
    if #text > 500 then
        return text:sub(1, 500) .. "..."
    end
    return text
end

local function display_error(err)
    if type(err) == "table" and err.auth_expired == true then
        return _("Cookie 已过期，请重新配置")
    end
    local text = tostring(err)
    text = text:match("^[^\r\n]+") or text
    if #text > 300 then
        return text:sub(1, 300) .. "..."
    end
    return text
end

-- 书架持久化缓存：存为 Lua table 文件，离线时直接读
local function get_shelf_cache_path(settings)
    local cache_dir = settings and settings.get_download_dir and settings:get_download_dir() or ""
    if cache_dir == "" then cache_dir = "./fanqie_cache" end
    H.make_dir(cache_dir)
    return cache_dir .. "/shelf_cache.lua"
end

-- 浅拷贝 books 数组（仅数组层）：调用方（main.lua 的 showBookList）可能原地
-- table.sort，浅拷贝保证内存缓存的原始顺序（= 服务端顺序）不被污染。
-- 内部 book 对象仍共享引用，封面下载回填的 cover_path 会写进缓存对象——
-- 该污染无害（有益：下次跳过重复下载）。
local function shallow_copy_books(books)
    local copy = {}
    for i, b in ipairs(books) do
        copy[i] = b
    end
    return copy
end

local function save_shelf_cache(settings, books)
    if not settings or not books or type(books) ~= "table" then return end
    -- 写内存缓存（浅拷贝：调用方可能原地排序 books，
    -- 存浅拷贝保持内存缓存的原始顺序不被污染）
    SHELF_MEM_CACHE = shallow_copy_books(books)
    local path = get_shelf_cache_path(settings)
    local lines = { "return {" }
    for i, b in ipairs(books) do
        local parts = {}
        for k, v in pairs(b) do
            if type(v) == "string" then
                -- 完整转义：\ " \n \r \t，避免书名含特殊字符导致缓存文件语法错误
                local escaped = v:gsub("\\", "\\\\")
                    :gsub('"', '\\"')
                    :gsub("\n", "\\n")
                    :gsub("\r", "\\r")
                    :gsub("\t", "\\t")
                table.insert(parts, string.format('%s="%s"', k, escaped))
            elseif type(v) == "number" then
                table.insert(parts, string.format('%s=%s', k, tostring(v)))
            elseif type(v) == "boolean" then
                table.insert(parts, string.format('%s=%s', k, tostring(v)))
            end
        end
        table.insert(lines, "  {" .. table.concat(parts, ",") .. "},")
    end
    table.insert(lines, "}")
    local f = io.open(path, "w")
    if f then
        f:write(table.concat(lines, "\n"))
        f:close()
        if Log then Log.info("shelf cache saved: " .. tostring(#books) .. " books to " .. path) end
    else
        if Log then Log.warn("shelf cache save failed: cannot open " .. path) end
    end
end

-- 书架缓存读取：内存主源 + 文件后备 + 回填
-- 优先查内存缓存，命中直接返回，避免文件 IO；
-- 未命中时读文件缓存，并回填内存，后续读取全部走内存。
-- 返回浅拷贝：避免调用方原地排序污染内存缓存。
local function load_shelf_cache(settings)
    if SHELF_MEM_CACHE and #SHELF_MEM_CACHE > 0 then
        return shallow_copy_books(SHELF_MEM_CACHE)
    end
    local path = get_shelf_cache_path(settings)
    if not H or not H.file_exists or not H.file_exists(path) then
        if Log then Log.info("shelf cache: file not found at " .. path) end
        return nil
    end
    local ok, data = pcall(function()
        local chunk, err = loadfile(path)
        if not chunk then
            if Log then Log.warn("shelf cache loadfile failed: " .. tostring(err)) end
            return nil
        end
        return chunk()
    end)
    if ok and type(data) == "table" and #data > 0 then
        if Log then Log.info("shelf cache loaded: " .. tostring(#data) .. " books") end
        -- 用本地缓存的 App 正式名覆盖 SEO 推广名（纯内存，无网络）
        if ok_BookNames and BookNames then
            pcall(BookNames.decorate, settings, data)
        end
        -- 3. 回填内存缓存（存原始引用，调用方拿到的是浅拷贝不会污染 data）
        SHELF_MEM_CACHE = data
        return shallow_copy_books(data)
    end
    if not ok then
        if Log then Log.warn("shelf cache pcall failed: " .. tostring(data)) end
    end
    return nil
end

local Bookshelf = {}

-- 清除书架缓存：三层同步清理
--   1. SHELF_MEM_CACHE（显示层内存缓存）
--   2. client.SHELF_CACHE（API 短缓存）
--   3. shelf_cache.lua（文件缓存）
function Bookshelf:clearShelfCache()
    SHELF_MEM_CACHE = nil
    -- 2. 清 client 的 API 短缓存
    if self.client and self.client.clear_shelf_cache then
        self.client:clear_shelf_cache()
    end
    local path = get_shelf_cache_path(self.settings)
    if H and H.file_exists and H.file_exists(path) then
        os.remove(path)
        if Log then Log.info("shelf cache file deleted: " .. path) end
    end
end

--- 刷新门控位：自动刷新与手动刷新共用，防止两个子进程同时拉 get_shelf。
-- 位放在 _state（模块级，跨实例共享）。🔴 **每个出口都必须清位**，
-- 漏一个的后果是「书架再也不自动刷新」，比并发本身更难排查。
local function refreshing_now()
    return ok_state and _state and _state.shelf_refreshing == true
end

local function set_refreshing(v)
    if ok_state and _state then
        _state.shelf_refreshing = v and true or nil
    end
end

--- 书架刷新成功后的顺带维护：covers 目录只增不减，超阈值时清孤儿封面。
-- 必须把这次拿到的全量 books 传进去：清理按「是不是还在书架上」判断，
-- 按 mtime 判断会误删长期在读的老封面（自愈重下，但闪白 + 白耗流量）。
-- 阈值仍是 200MB（见 cover_cache.lua），普通设备不会触发。
local function maybe_prune_covers(settings, books)
    if ok_CoverCache and CoverCache and CoverCache.maybe_auto_prune then
        pcall(CoverCache.maybe_auto_prune, settings, books)
    end
    -- 段评配图（review_pics/<book_id>/）独立目录、独立阈值，同样按书架集合清理。
    -- 分开做：混目录会让两边的孤儿清理互相误删。
    if ok_ReviewPics and ReviewPics and ReviewPics.maybe_auto_prune then
        pcall(ReviewPics.maybe_auto_prune, settings, books)
    end
end

-- 后台校正书名（App 正式名）。拿到后写回缓存、同步刷新书架当前页。
-- 不阻塞界面：本地缓存名在 decorate 阶段已经生效，这里只补「还没查过的书」。
function Bookshelf:_ensureBookNames(books)
    if not (ok_BookNames and BookNames) then return false end
    if type(books) ~= "table" or #books == 0 then return false end
    local plugin = self
    local ok, started = pcall(BookNames.ensure, self.settings, books, function(updated)
        save_shelf_cache(plugin.settings, updated)
        -- 只刷标题，保持当前页；书架没开着（或已换菜单）时静默跳过
        if plugin.refreshShelfTitles then
            pcall(plugin.refreshShelfTitles, plugin, updated)
        end
    end)
    return ok and started or false
end

function Bookshelf:showBookshelf(opts)
    opts = opts or {}
    local force_refresh = opts.force_refresh == true

    if not self.patches_ok then
        local Patches = require("patches.core")
        Patches.install()
        self.patches_ok = true
    end

    -- 回退到文件缓存（force_refresh 获取失败时使用）
    local function fallback_to_cache()
        local cached = load_shelf_cache(self.settings)
        if cached and #cached > 0 then
            self:showBookList(cached)
            return true
        end
        return false
    end

    -- 非强制刷新：优先显示本地缓存，有网后台刷新。
    -- ⚠️ 缓存里若有「没校正过」的书（刚加进书架的新书），不能立刻显示：
    --    那会先闪一次 Web 推广名 + 旧封面。改为等后台刷新（其中已在子进程里
    --    用官方源批量校正完）再渲染，首屏直接是 App 当前名字和封面。
    if not force_refresh then
        local cached_shelf = load_shelf_cache(self.settings)
        if cached_shelf and #cached_shelf > 0 then
            local plugin = self
            local pending = false
            if ok_BookNames and BookNames and BookNames.has_pending then
                local ok_p, p = pcall(BookNames.has_pending, self.settings, cached_shelf)
                pending = ok_p and p == true
            end
            if not pending then
                self:showBookList(cached_shelf)
                -- 稳态下没有待校正的书，这里 0 请求
                self:_ensureBookNames(cached_shelf)
            end
            -- 后台异步刷新：门控——已有刷新在跑就跳过（不重入、不排队）
            if self:checkNetwork() and not refreshing_now() and ok_Async and Async then
                set_refreshing(true)
                self:showBusy(pending and _("正在获取书籍信息...") or _("正在刷新书架..."))
                local settled = false
                local function finish(ok, result)
                    if settled then return end
                    settled = true
                    plugin:closeBusy()
                    set_refreshing(false)
                    if ok and type(result) == "table" and #result > 0 then
                        save_shelf_cache(plugin.settings, result)
                        maybe_prune_covers(plugin.settings, result)
                        plugin:showBookList(result)
                        plugin:_ensureBookNames(result)
                    elseif pending then
                        -- 刷新失败 / 超时 / 取消：回退缓存，别把界面留在空白
                        plugin:showBookList(cached_shelf)
                        plugin:_ensureBookNames(cached_shelf)
                    end
                end
                Async.run(function()
                    -- 只有 pending 时才强制走网络：内存里的 5 分钟书架缓存
                    -- 可能还是「没有这本新书」的旧快照；稳态保持原有缓存语义
                    return plugin:get_shelf(pending, true)
                end, function(ok, result, err)
                    finish(ok, result)
                end, {
                    poll_interval = 0.3, timeout = 60,
                    on_cancel = function()
                        finish(false, nil)
                    end,
                })
            elseif pending then
                -- 无网 / Async 不可用 / 已有刷新在跑：拿不到 App 值，
                -- 只能显示缓存（仍会看到 Web 值），但至少不会空白或卡住
                self:showBookList(cached_shelf)
                self:_ensureBookNames(cached_shelf)
            end
            return
        end
    end

    -- force_refresh 或无缓存：直接从网络获取
    -- 获取成功后 save_shelf_cache 覆盖旧缓存；失败时回退到旧缓存
    if not self:checkNetwork() then
        if force_refresh and fallback_to_cache() then
            self:showInfo(_("无网络，显示缓存数据"))
            return
        end
        self:showError(_("无网络且无书架缓存，请先联网获取书架"))
        return
    end

    self:showBusy(force_refresh and _("正在刷新书架...") or _("正在获取书架..."))
    local plugin = self
    -- 手动刷新不被门控拒绝（行为不变），但必须参与置位/清位，
    -- 否则位永不清、自动刷新会永久被挡。
    set_refreshing(true)
    if ok_Async and Async then
        Async.run(function()
            -- force_refresh=true 跳过 client 内存缓存，从网络获取
            return plugin:get_shelf(force_refresh, true)
        end, function(ok, result, err)
            plugin:closeBusy()
            set_refreshing(false)  -- 统一清位：下面所有 return 都被覆盖
            if not ok or type(result) ~= "table" then
                if Log then Log.error("fetch shelf failed:", log_error(err or result)) end
                -- 获取失败：回退到旧缓存，不删除任何数据
                if force_refresh and fallback_to_cache() then
                    plugin:showInfo(_("刷新失败，显示缓存数据"))
                    return
                end
                plugin:showError(T(_("获取书架失败:\n%1"), display_error(err or result)))
                return
            end
            if Log then Log.debug("shelf fetched:", #result, "books") end
            if not result or #result == 0 then
                -- 空结果可能是 cookie 过期，回退到旧缓存
                if force_refresh and fallback_to_cache() then
                    plugin:showInfo(_("获取数据为空，显示缓存数据"))
                    return
                end
                plugin:showInfo(_("书架为空，请先在番茄小说App中添加书籍"))
                return
            end

            save_shelf_cache(plugin.settings, result)
            maybe_prune_covers(plugin.settings, result)
            plugin:showBookList(result)
            plugin:_ensureBookNames(result)
        end, {
            poll_interval = 0.3, timeout = 60,
            on_cancel = function()
                plugin:closeBusy()
                set_refreshing(false)
            end,
        })
    else
        -- Async 模块不可用时降级为同步
        local ok, result = pcall(function()
            return self:get_shelf()
        end)
        self:closeBusy()
        set_refreshing(false)
        if not ok then
            if Log then Log.error("fetch shelf failed:", log_error(result)) end
            self:showError(T(_("获取书架失败:\n%1"), display_error(result)))
            return
        end
        if Log then Log.debug("shelf fetched:", #result, "books") end
        if not result or #result == 0 then
            self:showInfo(_("书架为空，请先在番茄小说App中添加书籍"))
            return
        end

        save_shelf_cache(self.settings, result)
        maybe_prune_covers(self.settings, result)
        self:showBookList(result)
        self:_ensureBookNames(result)
    end
end

--- @param allow_preflight boolean|nil 只在 Async 子进程里传 true：
---        渲染前用官方源批量校正并预下载封面，界面第一次显示就是 App 值。
function Bookshelf:get_shelf(force_refresh, allow_preflight)
    if Log then Log.debug("fetching shelf from API" .. (force_refresh and " (force refresh)" or "")) end
    local result = self.client:fetch_shelf_detail(force_refresh)

    local books = {}
    local shelf = nil
    if result and type(result.data) == "table" then
        shelf = result.data.detail_list or result.data.book_shelf_info or result.data.bookShelfInfo
        if not shelf then
            local count = 0
            for _ in pairs(result.data) do count = count + 1 end
            if count > 0 and result.data[1] then
                shelf = result.data
            end
        end
    end
    if type(shelf) == "table" then
        for _, item in ipairs(shelf) do
            local total_chapters = tonumber(item.serial_count or item.total_chapters or 0)
            local read_chapters = tonumber(item.real_chapter_order or item.index or 0)
            local progress = 0
            if total_chapters and total_chapters > 0 then
                progress = read_chapters / total_chapters
            elseif item.read_progress then
                progress = tonumber(item.read_progress) / 10000
            end
            -- 封面地址必须收敛成无签名 CDN：接口给的 thumb_url 带签名，
            -- x-expires 只签到次日，缓存未命中时用旧地址回源会 403（封面变空白）。
            -- 另外不能只靠 or 兜底——空串 "" 在 Lua 里是 truthy，会把后面
            -- 所有候选字段整个吃掉，所以逐个挑「非空字符串」。
            local raw_cover = item.thumb_url
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.thumb_uri end
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.coverUrl end
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.cover end
            if type(raw_cover) ~= "string" or raw_cover == "" then raw_cover = item.cover_url end
            local cover = raw_cover
            if ok_FanQie and FanQie and FanQie.mobile_cover then
                cover = FanQie.mobile_cover(raw_cover) or raw_cover
            end
            local book = {
                book_id = item.book_id or item.bookId or item.id,
                -- ⚠️ book_name 必须是第一优先，**不能**改成 title 优先。
                -- multidetail 的 detail_list 每项是「书 + 最近阅读位置」的混合结构
                -- （同项还带 latest_read_item_id / index / read_progress），其中的
                -- title 指向的是**章节标题**而非书名：2026-10-26 按一份诊断文档改成
                -- title 优先后，真机书架上整片书名变成「第 N 章 xxx」，随即回退。
                -- 书名字段是 book_name。
                title = item.book_name or item.title or item.name or "未知",
                author = item.author_name or item.author or "",
                cover = cover,
                desc = item.description or item.desc or item.abstract or "",
                progress = progress,
                item_id = item.item_id or item.itemId,
                total_chapters = total_chapters,
                read_chapters = read_chapters,
            }
            if book.book_id then
                table.insert(books, book)
            end
        end
    end
    -- 渲染前先把未校正的书用官方源一次拿齐（名字 + 封面 + 封面图片落盘）。
    -- 只在后台子进程里跑：这里发网络请求不阻塞 UI，失败静默回退。
    -- ⚠️ 先确认子进程可用：Async 在 fork 失败时会降级成「同步执行」，
    --    那样这段预取就会跑在 UI 线程上，把开书架卡住十几秒。
    if allow_preflight and ok_BookNames and BookNames and BookNames.preflight then
        local sub = ok_Async and Async and Async.is_available and Async.is_available()
        if sub then
            pcall(BookNames.preflight, self.client, self.settings, books)
        end
    end
    -- 已有缓存的书名替换成 App 正式名；官方没拿到的仍保持 SEO 名，
    -- 由 _ensureBookNames 在后台用三方源补齐。
    if ok_BookNames and BookNames then
        pcall(BookNames.decorate, self and self.settings or nil, books)
    end
    return books
end

-- ⚠️ 这里原本有 download_covers / showBookList / showBookDetail 三个方法，
-- 已整体移除：main.lua 在末尾用同名方法（FanQiePlugin:showBookList /
-- FanQiePlugin:showBookDetail）覆盖了 Bookshelf 的混入实现，三者永不执行。
-- 其中 download_covers 是**同步串行**HTTP 下载版，是个随时会被误启用的地雷；
-- 真正在跑的是 main.lua 的 _preloadAllCovers / _cacheShelfPageCovers
-- （子进程 + generation 取消）。删掉可避免「改了半天没生效」和「误启用阻塞版」。
function Bookshelf:showChapterListing(book)
    local self_ref = self
    local book_id = book.book_id
    local Async_mod = Async

    local function fetch_and_display()
        self:showBusy(_("正在获取目录..."))
        if ok_Async and Async_mod then
            Async_mod.run(function()
                return self_ref:get_chapters(book_id)
            end, function(ok, chapters, err)
                self_ref:closeBusy()
                if not ok or type(chapters) ~= "table" then
                    if Log then Log.error("fetch chapters failed:", log_error(err or chapters)) end
                    self_ref:showError(T(_("获取目录失败:\n%1"), display_error(err or chapters)))
                    return
                end
                self_ref:_displayChapterListing(book, chapters)
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
            self:_displayChapterListing(book, chapters)
        end
    end

    local cached = Content.load_catalog_cache and Content.load_catalog_cache(self.settings, book_id) or nil
    if cached and #cached > 0 then
        self:_displayChapterListing(book, cached)
        fetch_and_display()
    else
        fetch_and_display()
    end
end

function Bookshelf:_displayChapterListing(book, chapters)
    -- 缓存索引存储在文件（cache_index.lua），不在 settings 里。
    -- 之前用 settings:get("cached_chapter_index."..book_id) 读取，永远为空，
    -- 导致目录里已下载章节不显示 ✓ 对号。
    -- 刷新内存缓存：从阅读器返回书架后，内存缓存可能因旧 bug 不完整，
    -- 强制重新从文件加载确保目录对号准确
    local cached = {}
    if ok_state and _state and _state.invalidateChapterIndexCache then
        _state.invalidateChapterIndexCache(book.book_id)
    end
    if ok_Content and Content and Content.load_cache_index then
        cached = Content.load_cache_index(self.settings, book.book_id) or {}
        -- 同步到 book.cached_chapters，供后续 navigateToChapter 直接使用
        book.cached_chapters = cached
    end

    local items = {}
    for i, chapter in ipairs(chapters) do
        local is_cached = cached[tostring(chapter.itemId)] and true or false
        local text = string.format("%d. %s", i, chapter.title or "")
        table.insert(items, {
            text = text,
            mandatory = is_cached and "✓" or "",
            chapter_index = i,
            callback = function()
                UIManager:close(self.chapter_list_menu)
                self:openChapter(book, chapters, i)
            end,
        })
    end

    self.chapter_list_menu = Menu:new{
        title = book.title,
        item_table = items,
        is_borderless = true,
        width = Screen:getWidth() - 40,
        height = Screen:getHeight() - 100,
        close_callback = function()
            self.chapter_list_menu = nil
        end,
        on_top = function()
            if self.chapter_list_menu then
                self.chapter_list_menu.page = 1
                UIManager:setDirty(self.chapter_list_menu)
            end
        end,
        on_bottom = function()
            if self.chapter_list_menu then
                local total_pages = math.ceil(#items / (self.chapter_list_menu.per_page or 10))
                self.chapter_list_menu.page = total_pages
                UIManager:setDirty(self.chapter_list_menu)
            end
        end,
    }
    UIManager:show(self.chapter_list_menu)
end

function Bookshelf:showJumpToChapter(book, chapters)
    local dialog = InputDialog:new{
        title = _("跳转到章节"),
        input = tostring(_state.current_chapter_index or 1),
        input_type = "number",
        buttons = {
            {
                text = _("取消"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("确定"),
                callback = function()
                    local idx = tonumber(dialog:getInputText())
                    UIManager:close(dialog)
                    if idx and idx >= 1 and idx <= #chapters then
                        self:openChapter(book, chapters, idx)
                    else
                        self:showError(_("章节号无效"))
                    end
                end,
            },
        },
    }
    UIManager:show(dialog)
end

function Bookshelf:downloadBook(book)
    local ok, chapters = pcall(function()
        return self:get_chapters(book.book_id)
    end)
    if not ok then
        if Log then Log.error("fetch chapters failed:", log_error(chapters)) end
        self:showError(T(_("获取目录失败:\n%1"), display_error(chapters)))
        return
    end
    -- 书架下载：不传 current_index（无"当前阅读后N章"/"剩余全部"选项）
    require("fanqie.download").showOptionsDialog(self, book, chapters)
end

-- 按 book_id 查一本书的标题/作者（仅供阅读统计合并使用）
-- 只读：书架内存缓存 → shelf_cache.lua 文件缓存，不触发任何网络请求。
function Bookshelf.find_book_meta(book_id, settings)
    if not book_id then return nil end
    book_id = tostring(book_id)

    local function pick(books)
        if type(books) ~= "table" then return nil end
        for _, b in ipairs(books) do
            if type(b) == "table" and tostring(b.book_id or b.bookId or "") == book_id then
                return {
                    book_id = book_id,
                    title = b.title or b.book_name or b.name or "",
                    author = b.author or b.author_name or "",
                }
            end
        end
        return nil
    end

    local found = pick(SHELF_MEM_CACHE)
    if found then return found end

    if ok_H and H and H.file_exists and settings then
        local cache_path = get_shelf_cache_path(settings)
        if H.file_exists(cache_path) then
            local ok, data = pcall(function()
                local chunk = loadfile(cache_path)
                return chunk and chunk() or nil
            end)
            if ok and type(data) == "table" then
                if Log and Log.info then
                    Log.info("stats: book meta from shelf cache " .. cache_path)
                end
                return pick(data)
            end
        end
    end
    return nil
end

return Bookshelf
