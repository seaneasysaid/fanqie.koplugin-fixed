-- 阅读统计合并：把番茄"同一本书的所有章节"在 KOReader 阅读统计里算成一本。
--
-- 背景：插件把每一章存成一个独立的 .html 文件，KOReader 的 statistics 插件
--   用 (title, authors, md5) 三元组标识"一本书"（md5 取自文档 sidecar 的
--   partial_md5_checksum），于是每一章都成了统计里独立的一条记录。
-- 方案：在当前文档的 statistics 实例上猴补丁 initData()，让它在本插件的章节
--   文件上临时用「书名 + 作者 + 按 book_id 生成的固定标识」去读/建同一条记录；
--   initData 结束后还原 doc_props，界面上仍然显示章节标题。
-- 影响范围只有统计数据库，不改动其它模块的行为。

local M = {
    _mark = "_fanqie_stats_patch_v1",
}

local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

local function is_fanqie_path(file_path)
    if not H or not H.is_str then return false end
    return H.is_str(file_path) and file_path:lower():find('/fanqie/', 1, true) ~= nil
end

-- 章节文件路径：<cache_dir>/<book_id>/chapter_<item_id>.html
-- 取倒数第二段作为 book_id（与 Content.book_cache_dir 的构造方式一致）
local function book_id_from_path(file_path)
    if not H or not H.is_str or not H.is_str(file_path) then return nil end
    local book_id = file_path:match("/([^/]+)/[^/]+$")
    if not book_id or book_id == "" then return nil end
    return book_id
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

-- 返回 { title, authors, md5 }；确认不了书名时返回 nil（保持 KOReader 原行为）
function M.resolve(file_path, settings)
    if not is_fanqie_path(file_path) then return nil end
    local book_id = book_id_from_path(file_path)
    if not book_id then return nil end
    local book = current_session_book(book_id) or shelf_book(book_id, settings)
    if not book then return nil end
    return {
        book_id = book_id,
        title = book.title,
        authors = (book.author and book.author ~= "") and book.author or "N/A",
        md5 = "fanqie-" .. book_id,
    }
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

-- 给当前文档（一个 ReaderUI 实例）的 statistics 实例安装身份补丁。
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
