-- 封面缓存治理：文件名规则、存在性查找、新鲜度、统计、清理。
--
-- 历史问题：
--   ① 文件名用书名（两本同名书共用一个 .jpg，后下的覆盖前一本）；
--   ② 只写不清：移出书架的书、换过的封面永远留在 covers 目录；
--   ③ 没有任何统计，用户无法知道占了多少空间。
--
-- 命名改为 book_id.jpg 后，旧缓存（书名.jpg）仍能被 find() 找到并使用，
-- 不强制迁移——首次重新下载某本书时自然落到新名字，老的慢慢变成孤儿，
-- 由 prune/maybe_auto_prune 收走。
--
-- 2026-11 再改一次：文件名加上 App 封面 hash 短码 `<book_id>_<宽>_<hash8>.jpg`。
-- 原因：番茄「改名=换封面」，同一本书的封面会变；只靠 book_id+宽度做键，
-- 换了封面还是命中同一个文件，书架会永远显示旧图。
-- 没有 App 封面（知秋/书山都不可用）时不带 hash，退回旧的 `<book_id>_<宽>`。

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_Log, Log = pcall(require, "fanqie.logger")
local ok_FanQie, FanQie = pcall(require, "fanqie.fanqie")

local M = {}

M.SUFFIX = ".jpg"
-- 文件名里带请求宽度，换尺寸时旧图自然不被命中、自动重下，不必手工清缓存。
-- 必须与 fanqie.COVER_WIDTH 保持一致：那边改了这边没改，书架会一直用旧尺寸。
M.COVER_WIDTH = (ok_FanQie and FanQie and FanQie.COVER_WIDTH) or 480
-- 取图规则换代标记（2026-11-10 v3：分桶选模板，去掉 CDN 补的黑边）。
-- URL 变了但 cover_hash 仍是同一个图片 hash，不加这一位就会命中旧的带黑边
-- 文件、永远不重下。改取图模板时把这里 +1 即可让整架封面自然失效。
M.LAYOUT_TAG = "v3"
M.PRUNE_DAYS = 30                       -- 自动清理只删「超过这么久没被写过」的
M.AUTO_PRUNE_BYTES = 200 * 1024 * 1024  -- 目录超过 200MB 才考虑自动清理

local function fs()
    if ok_lfs and lfs then return lfs end
    return nil
end

local function sanitize(name)
    return (tostring(name or ""):gsub("[/\\:%*%?\"<>|]", "_"))
end

-- 父目录不存在时按需创建（main.lua 里原来调 H.make_dir，这里自带一份，
-- 免得调用方每次都要先 require helper）。
local function ensure_dir(path)
    if type(path) ~= "string" or path == "" then return end
    local L = fs()
    if L and L.attributes then
        if not L.attributes(path, "mode") then
            pcall(L.mkdir, path)
        end
        return
    end
    -- 没有 lfs：交给第一次写入的 io.open 去失败
end

--- 封面目录：<下载目录>/covers
function M.dir(settings)
    local base = ""
    if settings then
        local ok, d = pcall(function() return settings:get_download_dir() end)
        if ok and type(d) == "string" then
            base = d
        elseif type(settings) == "table" then
            local ok2, d2 = pcall(function() return settings:get("cache_dir") end)
            if ok2 and type(d2) == "string" then base = d2 end
        end
    end
    if base == "" then base = "./fanqie_cache" end
    return base .. "/covers"
end

function M.file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

--- 新命名：<book_id>_<宽>[_<封面hash8>]_<取图规则>.jpg；没有 book_id 时退回书名
function M.filename(book)
    if type(book) ~= "table" then return nil end
    local bid = book.book_id or book.bookId
    if bid ~= nil and tostring(bid) ~= "" then
        local name = sanitize(bid) .. "_" .. M.COVER_WIDTH
        if type(book.cover_hash) == "string" and book.cover_hash ~= "" then
            name = name .. "_" .. sanitize(book.cover_hash)
        end
        return name .. "_" .. M.LAYOUT_TAG .. M.SUFFIX
    end
    if type(book.title) == "string" and book.title ~= "" then
        return sanitize(book.title) .. M.SUFFIX
    end
    return nil
end

--- 旧命名：<书名>.jpg（只用于兼容已下载的旧缓存）
function M.legacy_filename(book)
    if type(book) ~= "table" or type(book.title) ~= "string" or book.title == "" then
        return nil
    end
    return sanitize(book.title) .. M.SUFFIX
end

--- 写新封面时的目标路径
function M.path(settings, book)
    local name = M.filename(book)
    if not name then return nil end
    local dir = M.dir(settings)
    ensure_dir(dir)
    return dir .. "/" .. name
end

--- 找已存在的封面文件：先新名，再旧名。
-- 返回 nil 表示没有缓存（调用方去下载）。
--
-- ⚠️ 带 cover_hash 时**不做旧名回退**：`<book_id>_<宽>.jpg` / `<book_id>.jpg`
-- 存的是 Web 那张旧封面，回退过去就等于「换了封面也永远不换」——正是这个
-- 函数最容易踩的坑。宁可重下一次，下载失败也别拿旧图顶替。
function M.find(settings, book)
    local dir = M.dir(settings)
    local name = M.filename(book)
    if not name then return nil end
    local path = dir .. "/" .. name
    if M.file_exists(path) then return path end
    if type(book.cover_hash) == "string" and book.cover_hash ~= "" then
        return nil
    end
    local legacy = M.legacy_filename(book)
    if legacy and legacy ~= name then
        local old_path = dir .. "/" .. legacy
        if M.file_exists(old_path) then return old_path end
    end
    return nil
end

--- 目录占用：{ count = 图片数, bytes = 总字节 }
function M.stats(dir)
    local out = { count = 0, bytes = 0 }
    local L = fs()
    if not L or type(L.dir) ~= "function" then return out end
    local ok, iter, dir_obj = pcall(L.dir, dir)
    if not ok or type(iter) ~= "function" then return out end
    for name in iter, dir_obj do
        if type(name) == "string" and name:lower():match("%.jpg$") then
            local path = dir .. "/" .. name
            local ok_a, size = pcall(L.attributes, path, "size")
            if ok_a and type(size) == "number" then
                out.count = out.count + 1
                out.bytes = out.bytes + size
            end
        end
    end
    return out
end

--- 删除超过 days 天没被写过的封面。
-- ⚠️ **已废弃：生产路径不再调用，不要接回**。
-- 原因：mtime 只在**写入**时更新，一本 40 天前下过封面、天天在读的书
-- mtime 同样很旧，按时间删会误伤（删后能自愈重下，但会闪白 + 白耗流量）。
-- 清理请用 prune_orphans（按书架集合判断）。
-- @return deleted, freed_bytes
function M.prune(dir, days)
    local deleted, freed = 0, 0
    local L = fs()
    if not L or type(L.dir) ~= "function" then return deleted, freed end
    local cutoff = os.time() - (tonumber(days) or M.PRUNE_DAYS) * 86400
    local ok, iter, dir_obj = pcall(L.dir, dir)
    if not ok or type(iter) ~= "function" then return deleted, freed end
    for name in iter, dir_obj do
        if type(name) == "string" and name:lower():match("%.jpg$") then
            local path = dir .. "/" .. name
            local ok_m, mtime = pcall(L.attributes, path, "modification")
            if ok_m and type(mtime) == "number" and mtime < cutoff then
                local ok_s, size = pcall(L.attributes, path, "size")
                if os.remove(path) then
                    deleted = deleted + 1
                    if ok_s and type(size) == "number" then freed = freed + size end
                end
            end
        end
    end
    if deleted > 0 and ok_Log and Log then
        Log.info("[cover_cache] 清理 %d 张过期封面，释放 %d 字节", deleted, freed)
    end
    return deleted, freed
end

--- 把书架集合摊平成「允许保留的文件名」，新旧两套命名都收。
-- 旧名不能丢：老缓存仍在被 find() 回退使用，删了等于白下一遍。
-- @return keep 精确文件名集合, ids 在架 book_id 集合（用于放行任意 hash 后缀）
local function keep_names(books)
    local keep, ids = {}, {}
    for i = 1, #books do
        local book = books[i]
        local name = M.filename(book)
        if name then keep[name] = true end
        local old = M.legacy_filename(book)
        if old then keep[old] = true end
        -- 改名前的接口原名：书名被 book_names 校正成 App 正式名后，照旧名存的
        -- 封面 / 段评目录仍要算在架，不能因为改了个名字就把图删了
        if type(book.web_title) == "string" and book.web_title ~= "" then
            keep[sanitize(book.web_title) .. M.SUFFIX] = true
        end
        local bid = book.book_id or book.bookId
        if bid ~= nil and tostring(bid) ~= "" then
            ids[sanitize(bid)] = true
        end
    end
    return keep, ids
end

--- 按书架集合删除孤儿封面：已移出书架的书、被同名书顶掉的旧文件。
-- 判据是**集合成员**而不是 mtime —— 「这本书还在不在书架上」才是封面该不该
-- 留的依据，和它上次被下载/被读的时间无关。用 mtime 会把「40 天前下过封面
-- 但天天在读」的书当过期删掉（能自愈重下，但闪白 + 白耗流量）。
--
-- 不做「待删多于待留就放弃」这类护栏：孤儿比在架书多是常态（长期换书后
-- 旧文件堆积），那种护栏会把最该清理的场景整个拦死。真正的防线在上游：
-- 书架结果为空时 bookshelf.lua 直接 return，不会进到这里。
-- @return deleted, freed_bytes
function M.prune_orphans(dir, books)
    local deleted, freed = 0, 0
    local L = fs()
    if not L or type(L.dir) ~= "function" then return deleted, freed end
    if type(books) ~= "table" or #books == 0 then return deleted, freed end
    local keep, ids = keep_names(books)
    if next(keep) == nil then return deleted, freed end
    local ok, iter, dir_obj = pcall(L.dir, dir)
    if not ok or type(iter) ~= "function" then return deleted, freed end

    -- 先列清单再动手：删一半才发现集合不对就来不及了
    local dead, kept = {}, 0
    for name in iter, dir_obj do
        if type(name) == "string" and name:lower():match("%.jpg$") then
            -- 带封面 hash 的文件名形如 `<book_id>_<宽>_<hash8>.jpg`。
            -- 只要这个 book_id 还在书架上就放行 —— 否则 prune 发生在
            -- decorate 之前（books 还没带 cover_hash）时，会把刚下好的
            -- 新封面当孤儿删掉，表现是「封面下完又消失、下次打开还得再下」。
            local id_part = name:match("^(%d+)_%d+_")
            if keep[name] or (id_part and ids[sanitize(id_part)]) then
                kept = kept + 1
            else
                local path = dir .. "/" .. name
                local ok_s, size = pcall(L.attributes, path, "size")
                dead[#dead + 1] = {
                    path = path,
                    bytes = (ok_s and type(size) == "number") and size or 0,
                }
            end
        end
    end

    for i = 1, #dead do
        local item = dead[i]
        if os.remove(item.path) then
            deleted = deleted + 1
            freed = freed + item.bytes
        end
    end
    if deleted > 0 and ok_Log and Log then
        Log.info("[cover_cache] 清理 %d 张孤儿封面，释放 %d 字节（保留 %d 张）",
            deleted, freed, kept)
    end
    return deleted, freed
end

--- 保守的自动清理：只有目录超过阈值才动手。
-- 只走集合判据。**不要**在拿不到 books 时退回按 mtime 删 —— 那是已知会
-- 误伤在读书籍的判据（见 M.prune 注释），拿不到集合就这次不清。
-- 返回 deleted, freed；没触发时返回 0, 0。
function M.maybe_auto_prune(settings, books)
    local dir = M.dir(settings)
    local st = M.stats(dir)
    if st.bytes < M.AUTO_PRUNE_BYTES then
        return 0, 0
    end
    if type(books) ~= "table" or #books == 0 then
        return 0, 0
    end
    if ok_Log and Log then
        Log.info("[cover_cache] 目录 %d 字节 / %d 张，开始清理孤儿", st.bytes, st.count)
    end
    return M.prune_orphans(dir, books)
end

return M
