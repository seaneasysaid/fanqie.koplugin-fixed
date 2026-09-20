-- 阅读统计合并：把番茄"同一本书的所有章节"在 KOReader 阅读统计里算成一本，
-- 并让"页数"仍然是真实页数（跨章累加），而不是退化成章数。
--
-- 背景：插件把每一章存成一个独立的 .html 文件，KOReader 的 statistics 插件
--   用 (title, authors, md5) 三元组标识"一本书"（md5 取自文档 sidecar 的
--   partial_md5_checksum），于是每一章都成了统计里独立的一条记录。
--
-- 两个必须一起解决的问题：
--   1) 身份：在 statistics 实例上猴补丁 initData()，让它在本插件的章节文件上
--      临时用「书名 + 作者 + 按 book_id 生成的固定标识」去读/建同一条记录；
--      initData 结束后还原 doc_props，界面上仍然显示章节标题。
--   2) 页数：合并身份后各章页码都从 1 开始，而 page_stat_data 按
--      (id_book, page) 存，不同章的"第 3 页"会互相覆盖。
--      这里采用「跨章连续虚拟页号」：第 N 章的第 P 页 = (N-1)*SPAN + P。
--      这样每章占一段互不重叠的页号，真实翻过的页数可以跨章累加，
--      已读页数 = count(DISTINCT page) 就是真实页数，阅读时长也逐页保留。
--
-- 为什么必须让 book.pages 与 page_stat_data.total_pages 相等：
--   page_stat 是个视图，会按 pages/total_pages 把页号重新缩放：
--       first_page = ((page - 1) * pages) / total_pages + 1
--   只有两者相等时它才是恒等映射（first_page == page），
--   已读页数才不会被缩放放大或缩小。所以每次落库前都会把该书历史行的
--   total_pages 对齐成当前的 book.pages（幂等，失败不影响阅读）。
--
-- 注意：不能通过"把内存里的页码直接改成虚拟页号"来实现——onPageUpdate()
--   靠 curr_page ~= pageno 判定真实翻页，页码被改乱后章内翻页判定会失效，
--   阅读时长会丢失。因此映射只做在落库层，内存里仍按真实页累计时长。

local M = {
    _mark = "_fanqie_stats_patch_v2",
}

-- 每章预留的虚拟页槽位。只影响页号空间，不影响计数：
-- 已读页数是 distinct page 的个数，与页号本身多大无关。
-- 取 100 是为了保证再大的字号也不会把一章撑到溢出下一章的段（溢出会被截断）。
local CHAPTER_SPAN = 100
-- 还没观测到任何章页数时的兜底估计（一章约这么多页）
local DEFAULT_CHAPTER_PAGES = 12

local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

local function is_str(s)
    return H and H.is_str and H.is_str(s) or type(s) == "string"
end

local function is_fanqie_path(file_path)
    return is_str(file_path) and file_path:lower():find('/fanqie/', 1, true) ~= nil
end

-- 章节文件路径：<cache_dir>/<book_id>/chapter_<item_id>.html
-- 取倒数第二段作为 book_id（与 Content.book_cache_dir 的构造方式一致）
local function book_id_from_path(file_path)
    if not is_str(file_path) then return nil end
    local book_id = file_path:match("/([^/]+)/[^/]+$")
    if not book_id or book_id == "" then return nil end
    return book_id
end

-- chapter_<item_id>.html → item_id
local function item_id_from_path(file_path)
    if not is_str(file_path) then return nil end
    local item_id = file_path:match("/chapter_([^/]+)%.html$")
    if not item_id or item_id == "" then
        item_id = file_path:match("^chapter_([^/]+)%.html$")
    end
    if not item_id or item_id == "" then return nil end
    return item_id
end

-- 目录信息进程内缓存：目录文件可能几十 KB，别每次翻页都读
local _cat_cache = {}

-- 返回 { idx = { [item_id] = 章序号 }, total = 全书章数 }；拿不到返回 nil
local function catalog_info(settings, book_id)
    if not book_id then return nil end
    book_id = tostring(book_id)
    local hit = _cat_cache[book_id]
    if hit ~= nil then return hit end

    local ok_content, Content = pcall(require, "fanqie.content")
    if not ok_content or type(Content) ~= "table" or not Content.load_catalog_cache then
        return nil
    end
    local ok, catalog = pcall(Content.load_catalog_cache, settings, book_id)
    if not ok or type(catalog) ~= "table" or #catalog == 0 then
        return nil
    end

    local idx = {}
    for i, ch in ipairs(catalog) do
        if type(ch) == "table" then
            local iid = tostring(ch.itemId or ch.item_id or "")
            if iid ~= "" and idx[iid] == nil then idx[iid] = i end
        end
    end
    local info = { idx = idx, total = #catalog }
    _cat_cache[book_id] = info
    return info
end

-- 当前会话正在读的书（最可靠，含未落缓存的书）
local function current_session_book(book_id)
    local ok_state, _state = pcall(require, "fanqie.state")
    if not ok_state or type(_state) ~= "table" then return nil end
    local b = _state.current_book
    if type(b) ~= "table" then return nil end
    if tostring(b.book_id or b.bookId or "") ~= book_id then return nil end
    local title = b.title or b.book_name or b.name
    if not title or title == "" then return nil end
    return { title = title, author = b.author or b.author_name or "" }
end

-- 书架缓存里的书（冷启动直接打开章节文件时靠它）
local function shelf_book(book_id, settings)
    local ok_bs, Bookshelf = pcall(require, "fanqie.bookshelf")
    if not ok_bs or type(Bookshelf) ~= "table" or not Bookshelf.find_book_meta then return nil end
    local ok, meta = pcall(Bookshelf.find_book_meta, book_id, settings)
    if not ok or type(meta) ~= "table" then return nil end
    if not meta.title or meta.title == "" then return nil end
    return { title = meta.title, author = meta.author or "" }
end

-- 返回 { title, authors, md5, chapter_index, total_chapters }；
-- 确认不了书名时返回 nil（保持 KOReader 原行为）。
-- chapter_index / total_chapters 拿不到时为 nil，此时只合并身份、不动页数。
function M.resolve(file_path, settings)
    if not is_fanqie_path(file_path) then return nil end
    local book_id = book_id_from_path(file_path)
    if not book_id then return nil end
    local book = current_session_book(book_id) or shelf_book(book_id, settings)
    if not book then return nil end

    local identity = {
        book_id = book_id,
        title = book.title,
        authors = (book.author and book.author ~= "") and book.author or "N/A",
        md5 = "fanqie-" .. book_id,
    }

    local cat = catalog_info(settings, book_id)
    if cat then
        identity.total_chapters = cat.total
        local item_id = item_id_from_path(file_path)
        identity.chapter_index = item_id and cat.idx[item_id] or nil
    end
    return identity
end

-- statistics 实例：正常按插件名取；名字对不上时按特征在模块列表里兜底找
local function find_statistics(ui)
    local st = ui.statistics
    if type(st) == "table" and type(st.initData) == "function" then return st end
    for _, mod in ipairs(ui) do
        if type(mod) == "table" and type(mod.initData) == "function"
            and type(mod.getIdBookDB) == "function" then
            return mod
        end
    end
    return nil
end

----------------------------------------------------------------------
-- 虚拟页号
----------------------------------------------------------------------

-- 第 N 章第 P 页 → 全局唯一页号
function M.virtual_page(chapter_index, local_page)
    local n = math.floor(tonumber(chapter_index) or 1)
    local p = math.floor(tonumber(local_page) or 1)
    if n < 1 then n = 1 end
    if p < 1 then p = 1 end
    if p > CHAPTER_SPAN then p = CHAPTER_SPAN end -- 溢出保护：截断到本章段尾
    return (n - 1) * CHAPTER_SPAN + p
end

-- 把本会话的「章内页 → 时长列表」重映射到「虚拟页 → 时长列表」。
-- 时长原样保留，只是换页号，因此各章之间不再互相覆盖。
-- 返回 nil 表示没有可落库的数据。
function M.remap_page_stat(page_stat, chapter_index)
    if type(page_stat) ~= "table" or not chapter_index then return nil end
    local out, moved = {}, 0
    for local_page, data_list in pairs(page_stat) do
        if type(data_list) == "table" then
            local vp = M.virtual_page(chapter_index, local_page)
            local dst = out[vp]
            if not dst then dst = {}; out[vp] = dst end
            for _, tuple in ipairs(data_list) do
                if type(tuple) == "table" then
                    dst[#dst + 1] = tuple
                    moved = moved + 1
                end
            end
        end
    end
    if moved == 0 then return nil end
    return out
end

----------------------------------------------------------------------
-- 全书虚拟总页数：book.pages 必须与 page_stat_data.total_pages 相等，
-- 否则 page_stat 视图会缩放页号，已读页数就不准了。
----------------------------------------------------------------------

local function with_db(fn)
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return nil end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table" then return nil end
    local ok_path, path = pcall(DataStorage.getSettingsDir, DataStorage)
    if not ok_path or not is_str(path) then return nil end
    local ok, db = pcall(SQ3.open, path .. "/statistics.sqlite3")
    if not ok or not db then return nil end
    local r1, r2 = pcall(fn, db)
    pcall(db.close, db)
    if r1 then return r2 end
    return nil
end

-- 库里已有记录按虚拟页段推算"平均每章记录了多少页"，用于校准全书页数估计
local function avg_pages_from_db(id_book)
    if not id_book then return nil end
    return with_db(function(db)
        local ok, row = pcall(function()
            return db:rowexec(string.format(
                "SELECT count(DISTINCT ((page - 1) / %d)), count(*) FROM page_stat_data WHERE id_book = %d;",
                CHAPTER_SPAN, tonumber(id_book)))
        end)
        if not ok or type(row) ~= "table" then return nil end
        local segs = tonumber(row[1]) or 0
        local rows = tonumber(row[2]) or 0
        if segs <= 0 then return nil end
        return rows / segs
    end)
end

-- 让全书的历史记录与当前 book.pages 对齐，保证 page_stat 视图恒等映射
local function align_total_pages(id_book, v)
    if not id_book or not v then return end
    with_db(function(db)
        pcall(function()
            db:exec(string.format(
                "UPDATE page_stat_data SET total_pages = %d WHERE id_book = %d AND total_pages <> %d;",
                tonumber(v), tonumber(id_book), tonumber(v)))
        end)
    end)
end

local function chapter_page_count(s)
    local doc = s and s.ui and s.ui.document
    if type(doc) == "table" and type(doc.getPageCount) == "function" then
        local ok, n = pcall(doc.getPageCount, doc)
        local num = tonumber(n)
        if ok and num and num > 0 then return num end
    end
    return nil
end

-- 全书页数估计 = 平均每章页数 × 章数。
-- 因为已读页数统计的是 distinct 页号的个数（与页号大小无关），
-- 所以这里的估计只影响"进度"分母，不影响已读页数和阅读时长。
function M.estimate_total_pages(id_book, total_chapters, chapter_pages)
    local n = tonumber(total_chapters)
    if not n or n <= 0 then return nil end
    local avg = tonumber(chapter_pages)
    if not avg or avg <= 0 then avg = DEFAULT_CHAPTER_PAGES end
    local db_avg = avg_pages_from_db(id_book)
    if db_avg and db_avg > 0 then avg = (avg + db_avg) * 0.5 end
    local v = math.floor(avg * n + 0.5)
    if v < n then v = n end -- 至少每章 1 页
    return v
end

----------------------------------------------------------------------
-- 安装补丁
----------------------------------------------------------------------

-- 给当前文档（一个 ReaderUI 实例）的 statistics 实例安装身份/页数补丁。
-- 返回解析出的身份（table）表示"本文档是番茄章节且已知书名"；否则返回 nil。
function M.sync(ui, settings)
    if type(ui) ~= "table" then return nil end
    local file = ui.document and (ui.document.file or ui.document.path)
    local identity = M.resolve(file, settings)
    if not identity then return nil end

    -- statistics 插件可能未启用/不存在：此时不动，只返回身份供日志用
    local st = find_statistics(ui)
    if type(st) ~= "table" then return identity end
    if st[M._mark] then return identity end

    -- 计算并把身份/页数应用到一个 statistics 实例上（initData 与 insertDB 共用）
    local function apply(s, idn)
        if not idn or not idn.chapter_index or not idn.total_chapters then return nil end
        local v = M.estimate_total_pages(s.id_curr_book, idn.total_chapters, chapter_page_count(s))
        if not v then return nil end
        if type(s.data) == "table" then s.data.pages = v end
        if s.id_curr_book then align_total_pages(s.id_curr_book, v) end
        return v
    end

    local orig_initData = st.initData
    st.initData = function(s)
        local props = type(s) == "table" and s.ui and s.ui.doc_props or nil
        local idn = nil
        if type(props) == "table" then
            local f = s.ui and s.ui.document and (s.ui.document.file or s.ui.document.path)
            idn = M.resolve(f, settings)
        end
        if not idn then return orig_initData(s) end
        -- 临时顶替：initData 内部从 doc_props 取书名/作者，从 self.doc_md5 取标识
        local saved_title, saved_authors = props.display_title, props.authors
        props.display_title = idn.title
        props.authors = idn.authors
        s.doc_md5 = idn.md5
        local ok, err = pcall(orig_initData, s)
        -- 还原：界面上的标题/作者仍是章节文件自己的
        props.display_title = saved_title
        props.authors = saved_authors
        if not ok then error(tostring(err), 0) end
        -- orig 内部把 pages 写成了本章页数，这里改成全书页数（id_curr_book 已有值）
        apply(s, idn)
    end

    -- 落库时把章内页号重映射成跨章唯一的虚拟页号。
    -- 必须在这一层做：内存里若把页码改掉，onPageUpdate 的翻页判定会失效，
    -- 阅读时长将全部丢失。
    local orig_insertDB = st.insertDB
    if type(orig_insertDB) == "function" then
        st.insertDB = function(s, updated_pagecount)
            local f = s.ui and s.ui.document and (s.ui.document.file or s.ui.document.path)
            local idn = M.resolve(f, settings)
            if not idn or not idn.chapter_index then
                return orig_insertDB(s, updated_pagecount)
            end

            local v = apply(s, idn)
            local real_curr = s.curr_page
            local remapped = M.remap_page_stat(s.page_stat, idn.chapter_index)
            if remapped then
                s.page_stat = remapped
                s.curr_page = M.virtual_page(idn.chapter_index, real_curr)
            end
            -- 把全书页数作为 updated_pagecount 传进去，避免上游把
            -- book.pages 覆盖回"本章页数"（那样会破坏视图的恒等映射）
            local ok, err = pcall(orig_insertDB, s, v or updated_pagecount)

            -- 注意：orig 内部末尾会 resetVolatileStats() 清空 page_stat，
            -- 这里绝不能把落库前的旧 page_stat 还原回去（会重复入库）。
            -- 只把当前页重新播种（真实页码），保证后续翻页计时连续。
            s.curr_page = real_curr
            s.page_stat = {}
            if real_curr ~= nil then
                s.page_stat[real_curr] = { { os.time(), 0 } }
            end
            if not ok then error(tostring(err), 0) end
        end
    end

    st[M._mark] = true

    -- 插件注册顺序不保证：若 statistics 的 onReaderReady 已经先跑过，
    -- 用新身份重跑一次 initData，让 id_curr_book 指向合并后的那条记录。
    if st.id_curr_book ~= nil then
        pcall(function() st:initData() end)
    end
    return identity
end

return M
