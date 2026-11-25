-- 段评图片缓存：目录、命名、路径、统计、清理。
--
-- 目录结构：<下载目录>/review_pics/<book_id>/<md5(url)>.<ext>
--
-- 为什么按 book_id 分子目录，而不是像封面那样平铺：
--   * 段评图不属于任何一本书之外的实体，书移出书架时整目录删除最干净；
--   * 平铺的话文件名只能靠 url hash，无法回答「这张图是哪本书的」，
--     清理时又只能退回 mtime —— 那正是封面清理踩过的坑（写入时间不是使用时间）；
--   * 判据是**集合成员**：书架还在的书整目录保留，不在的直接删目录。
--
-- 与 covers/ 完全独立：混目录会让两边的孤儿清理互相误删。

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
local ok_Log, Log = pcall(require, "fanqie.logger")
local ok_md5, md5 = pcall(require, "md5")

local M = {}

M.DIR_NAME = "review_pics"
M.AUTO_PRUNE_BYTES = 100 * 1024 * 1024   -- 段评图比封面小而多，阈值取 100MB

local function fs()
    if ok_lfs and lfs then return lfs end
    return nil
end

local function is_dir(path)
    local L = fs()
    if not L or type(L.attributes) ~= "function" then return false end
    local ok, mode = pcall(L.attributes, path, "mode")
    return ok and mode == "directory"
end

local function ensure_path(target)
    if type(target) ~= "string" or target == "" then return end
    local L = fs()
    if not L then return end
    if is_dir(target) then return end
    -- 自左向右逐级尝试，已存在的级直接跳过
    local acc = target:match("^%a:[/\\]") or target:match("^/") or ""
    local rest = target:sub(#acc + 1)
    for seg in rest:gmatch("[^/\\]+") do
        acc = acc .. seg
        if not is_dir(acc) then
            if type(L.mkdir) == "function" then pcall(L.mkdir, acc) end
        end
        acc = acc .. "/"
    end
end

--- 下载目录（与 covers/ 同一个父目录）
function M.download_dir(settings)
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
    return base
end

--- 根目录：<下载目录>/review_pics
function M.base(settings)
    return M.download_dir(settings) .. "/" .. M.DIR_NAME
end

local function sanitize(seg)
    return (tostring(seg or ""):gsub("[/\\:%*%?\"<>|]", "_"))
end

--- 单本书的图片目录：<base>/<book_id>
function M.dir(settings, book_id)
    if book_id == nil or tostring(book_id) == "" then return nil end
    return M.base(settings) .. "/" .. sanitize(book_id)
end

--- 确保某本书的图片目录存在（写图前调一次，之后直接用 dir() 拼路径）。
function M.ensure(settings, book_id)
    local dir = M.dir(settings, book_id)
    if dir then ensure_path(dir) end
    return dir
end

--- URL -> 文件名。md5 不可用时退回一个稳定的 32 位混合哈希，
--- 只要同一 URL 每次得到同一个名字即可（碰撞概率远低于实际图片量）。
local function url_key(url)
    if ok_md5 and md5 and md5.sumhexa then
        local ok, hex = pcall(md5.sumhexa, url)
        if ok and type(hex) == "string" then return hex end
    end
    local h1, h2 = 5381, 52711
    for i = 1, #url do
        local b = url:byte(i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
    end
    -- %.0f 而不是 %08x：Lua 5.3/5.1 混用与部分实现的 math.floor 会把整数
    -- 留成 float，%x 会直接报 "number has no integer representation"。
    return string.format("%.0f-%.0f", h1, h2)
end

-- 番茄图片实际全是 jpg/webp；扩展名只用于本地识别，解码不看后缀。
local function url_ext(url)
    local ext = tostring(url or ""):match("%.([%a%d]+)$")
    if not ext then return "jpg" end
    ext = ext:lower()
    if ext == "jpeg" then return "jpg" end
    if ext == "png" or ext == "webp" or ext == "gif" or ext == "jpg" then
        return ext
    end
    return "jpg"
end

--- URL -> 缓存文件名
function M.filename(url)
    if type(url) ~= "string" or url == "" then return nil end
    return url_key(url) .. "." .. url_ext(url)
end

function M.file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

--- 判断一段字节是不是能渲染的位图（只看文件头，不解码）。
-- 只挡 0 字节不够：CDN/WAF 会回 200 + HTML 错误页，断流会留半截 body，
-- 写盘后 file_exists 为真就会被当成「已缓存」永不重下 → 永久灰框。
function M.is_image_bytes(data)
    if type(data) ~= "string" or #data < 12 then return false end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return true end          -- PNG
    if data:sub(1, 3) == "\255\216\255" then return true end               -- JPEG
    if data:sub(1, 6) == "GIF87a" or data:sub(1, 6) == "GIF89a" then
        return true                                                       -- GIF
    end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
        return true                                                       -- WebP
    end
    if data:sub(1, 2) == "BM" then return true end                         -- BMP
    return false
end

--- 文件存在且内容确实是位图。缓存命中判断应该用它，而不是 file_exists。
-- 返回 valid, exists：exists=false 表示文件不存在（调用方直接去下载）；
-- exists=true 而 valid=false 表示历史坏缓存（错误页/半截图），应删除重下。
function M.valid_image(path)
    if type(path) ~= "string" or path == "" then return false, false end
    local f = io.open(path, "rb")
    if not f then return false, false end
    local head = f:read(12)
    f:close()
    if M.is_image_bytes(head) then return true, true end
    return false, true
end

--- 一条段评 → 配图数组，统一结构 { url, fetch, w, h, displayable }。
--
-- 两条来源：
--   官方源   comment.images（= content.image_data_list 的原始结构）
--            交给 reading/comments.lua 的 normalize_images —— 它负责拆掉
--            `{ image_data = {…} }` 这层包装，并把 HEIC/HEIF 换成公共模板
--            转码后的 WebP（设备端没有 HEVC 解码器，不转就白下载）。
--   其他源   picInfos[{ picUrl, width, height }] → norm_infos
--
-- url 与 fetch 的区别：url 是原地址（带签名，做缓存名与去重键，稳定）；
-- fetch 才是真正下载用的地址（HEIC 时是转码后的）。不给 fetch 就用 url。
--
-- ⚠️ 放在这里而不是 main.lua 里，是为了能单测 —— 上一版埋在 main.lua 的
-- 局部函数里，字段名写错（picInfos 而非 images）没有任何测试能发现。
function M.from_comment(comment)
    local out = {}
    if type(comment) ~= "table" then return out end

    local raw = comment.images or comment.image_list
    -- 不能用 #raw > 0：真实结构是 { image_data = {…} } 这种 map，长度恒为 0
    if type(raw) == "table" and next(raw) ~= nil then
        -- normalize_images 的外层是 ipairs，喂 map 会一条都取不到，
        -- 所以「不是数组」的形态先包一层再给（包成 { raw } 它自己会再拆）。
        local wrapped = (#raw > 0) and raw or { raw }
        local ok_c, Comments = pcall(require, "fanqie.reading.comments")
        local normalized
        if ok_c and Comments and Comments.normalize_images then
            local ok, r = pcall(Comments.normalize_images, wrapped)
            if ok and type(r) == "table" then normalized = r end
        end
        for _, im in ipairs(normalized or {}) do
            if type(im.url) == "string" and im.url ~= "" then
                out[#out + 1] = {
                    url = im.url,
                    fetch = im.fetch_url or im.url,
                    w = tonumber(im.width) or 0,
                    h = tonumber(im.height) or 0,
                    displayable = im.displayable ~= false,
                }
            end
        end
        if #out > 0 then return out end
    end

    for _, p in ipairs(M.norm_infos(comment.picInfos or comment.pic_infos
        or comment.pic_list or comment.imgInfos)) do
        out[#out + 1] = {
            url = p.url,
            fetch = p.url,
            w = p.w,
            h = p.h,
            displayable = true,
        }
    end
    return out
end

--- 接口字段归一化为 { url, w, h }。
-- 官方段评给的是 `picInfos[{ picUrl, width, height, md5 }]`；字段名在别的
-- 书源/接口版本里可能是 pic_url / url / image_url，一并认。
-- 元素直接是 URL 字符串也接受（旧接口形态）。
-- width/height 只用来在分页阶段定占位比例（不读图）；缺了也不影响显示，
-- 渲染端会退回固定比例的框，再用文件头探到的真实比例做 contain。
function M.norm_infos(pic_infos)
    local pics = {}
    if type(pic_infos) ~= "table" then return pics end
    for _, p in ipairs(pic_infos) do
        local url, w, h
        if type(p) == "string" then
            url = p
        elseif type(p) == "table" then
            -- web_url / dynamic_url 是番茄官方 image_data 的字段名。
            -- 官方源正常走 Comments.normalize_images，这里只是它在极端情况下
            -- 加载失败时的兜底，保证图不至于全丢。
            url = p.picUrl or p.pic_url or p.web_url or p.dynamic_url
                or p.url or p.image_url or p.src
            -- 书山聚合的段评图只给 web_uri（值同样是完整 https 地址）。
            -- 只在它是绝对地址时采用，相对 uri 拼不出可用链接。
            if (not url or url == "") and type(p.web_uri) == "string"
                and p.web_uri:match("^https?://") then
                url = p.web_uri
            end
            w = p.width or p.picWidth or p.w
            h = p.height or p.picHeight or p.h
        end
        if type(url) == "string" and url ~= "" then
            pics[#pics + 1] = {
                url = url,
                w = tonumber(w) or 0,
                h = tonumber(h) or 0,
            }
        end
    end
    return pics
end

--- 写入目标路径（会建好目录）
function M.path(settings, book_id, url)
    local name = M.filename(url)
    if not name then return nil end
    local dir = M.dir(settings, book_id)
    if not dir then return nil end
    ensure_path(dir)
    return dir .. "/" .. name
end

--- 已缓存则返回路径，否则 nil（调用方去下载）
function M.find(settings, book_id, url)
    local p = M.path(settings, book_id, url)
    if p and M.file_exists(p) then return p end
    return nil
end

--- 目录占用：{ count = 图片数, bytes = 总字节 }
function M.stats(dir)
    local out = { count = 0, bytes = 0 }
    local L = fs()
    if not L or type(L.dir) ~= "function" or type(dir) ~= "string" then return out end
    local ok, iter, dir_obj = pcall(L.dir, dir)
    if not ok or type(iter) ~= "function" then return out end
    for name in iter, dir_obj do
        if type(name) == "string" and not name:match("^%.") then
            local path = dir .. "/" .. name
            local ok_a, size = pcall(L.attributes, path, "size")
            if ok_a and type(size) == "number" and size > 0 then
                out.count = out.count + 1
                out.bytes = out.bytes + size
            end
        end
    end
    return out
end

--- 根目录下所有书目录的占用合计
function M.total_stats(settings)
    local out = { count = 0, bytes = 0 }
    local L = fs()
    local base = M.base(settings)
    if not L or type(L.dir) ~= "function" then return out end
    local ok, iter, dir_obj = pcall(L.dir, base)
    if not ok or type(iter) ~= "function" then return out end
    for name in iter, dir_obj do
        if type(name) == "string" and not name:match("^%.") then
            local st = M.stats(base .. "/" .. name)
            out.count = out.count + st.count
            out.bytes = out.bytes + st.bytes
        end
    end
    return out
end

local function rmdir_tree(path)
    local L = fs()
    if not L or type(L.dir) ~= "function" then return 0 end
    local ok, iter, dir_obj = pcall(L.dir, path)
    if not ok or type(iter) ~= "function" then return 0 end
    local removed = 0
    for name in iter, dir_obj do
        if type(name) == "string" then
            local child = path .. "/" .. name
            if is_dir(child) then
                removed = removed + rmdir_tree(child)
            elseif os.remove(child) then
                removed = removed + 1
            end
        end
    end
    pcall(L.rmdir, path)
    return removed
end

--- 按书架集合清理：删除不在集合内的 <book_id>/ 整个子目录。
-- 判据是集合成员而不是 mtime —— 理由同 cover_cache.prune_orphans：
-- mtime 只在写入时更新，常读的书同样「很旧」。
-- @param book_ids table  书架 book_id 数组（或 set）
-- @return deleted_files, freed_bytes
function M.prune_orphans(settings, book_ids)
    local L = fs()
    local deleted, freed = 0, 0
    if not L or type(L.dir) ~= "function" then return deleted, freed end
    if type(book_ids) ~= "table" then return deleted, freed end

    local keep = {}
    -- 同时接受两种形状：book_id 数组/set，或者书架书目数组（元素是 book 表）。
    local function id_of(v)
        if type(v) == "table" then
            return v.book_id or v.bookId or v.id
        end
        return v
    end
    for k, v in pairs(book_ids) do
        local id
        if type(k) == "number" then id = id_of(v) else id = id_of(k) end
        if id ~= nil and tostring(id) ~= "" then
            keep[sanitize(id)] = true
        end
    end
    if next(keep) == nil then return deleted, freed end   -- 空集合不动手

    local base = M.base(settings)
    local ok, iter, dir_obj = pcall(L.dir, base)
    if not ok or type(iter) ~= "function" then return deleted, freed end

    local dead = {}
    for name in iter, dir_obj do
        if type(name) == "string" and not name:match("^%.") and not keep[name] then
            local path = base .. "/" .. name
            if is_dir(path) then
                local st = M.stats(path)
                dead[#dead + 1] = { path = path, bytes = st.bytes }
            end
        end
    end

    for i = 1, #dead do
        local n = rmdir_tree(dead[i].path)
        if n > 0 then
            deleted = deleted + n
            freed = freed + dead[i].bytes
        end
    end
    if deleted > 0 and ok_Log and Log then
        Log.info("[review_pics] 清理 %d 张段评图，释放 %d 字节", deleted, freed)
    end
    return deleted, freed
end

--- 阈值触发的自动清理：超过 AUTO_PRUNE_BYTES 才按书架集合删整目录。
-- 拿不到书单就这次不清（不要退回按 mtime 猜）。
function M.maybe_auto_prune(settings, book_ids)
    if type(book_ids) ~= "table" then return 0, 0 end
    local st = M.total_stats(settings)
    if st.bytes < M.AUTO_PRUNE_BYTES then return 0, 0 end
    if ok_Log and Log then
        Log.info("[review_pics] 目录 %d 字节 / %d 张，开始清理", st.bytes, st.count)
    end
    return M.prune_orphans(settings, book_ids)
end

return M
