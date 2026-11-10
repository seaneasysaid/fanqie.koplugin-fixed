-- 书架书名 / 封面校正：把 Web 接口的「SEO 推广名 + 旧封面」换成 App 当前值。
--
-- 背景（2026-11-07 全量复核 28 本，结果推翻了 10-26 的判断）：
--   * 番茄**改名时会同时换封面**。Web 端两条路径都停在改名之前：
--       - 书架 `/api/bookshelf/multidetail`     → book_name / thumb_url 是旧的
--       - App 搜索 `novel.snssdk.com/.../search` → 书名和封面也是旧的
--     实测 28 本：22 本被改过名，21 本封面不同；两条 Web 路径一本都没跟上。
--     → 所以 10-26 那版「用 App 搜索拿正式名」的逻辑**现在是空转**：搜出来的
--       title 永远等于传入的 Web 名，永远判定「没改名」。
--   * 真正有效的是**按 book_id 精确查详情**：
--       知秋 `/novel/info?novelId=<id>` → book_name + thumb_uri（App 当前值）
--       书山 `/search?key=<书名>` 解码 book_url 认领 → title + cover（兜底）
--     知秋要 Token（3 天，自动续）；书山要 api_key，且索引会滞后（28 本里
--     25 本同知秋、2 本仍旧图、1 本第三版），所以只做兜底。
--
-- 缓存：`<cache_dir>/<book_id>/app_name.lua`
--   { name, cover, cover_hash, at, tried, v = 2 }
--   * TTL 只决定「要不要再核对一次」，**不影响已拿到的值**：
--     过期的名字/封面继续用，绝不退回 SEO 名与旧封面（否则会周期性跳变）。
--   * 书名与封面同一条请求拿回来，一次网络换两个字段。
--   * v < 2 的旧缓存（只有 name）会强制补查一次，补齐封面。
--
-- 统计身份：统计库靠 md5 = "fanqie-<book_id>" 定位行，改名**不会**把历史拆成两行；
--   title 只是簿记的显示列，改名后同步 UPDATE 过去（M.backfill_stats_title）。

local M = {}

local ok_H, H = pcall(require, "fanqie.helper")
if not ok_H then H = nil end

local ok_Content, Content = pcall(require, "fanqie.content")
if not ok_Content then Content = nil end

-- 官方 App 详情协议（四神签名）。2026-11-11 起作为书名/封面的**主来源**：
-- multi-detail 支持 book_id 逗号批量，一次请求就能把整架 book_name + thumb_uri
-- 拿回来，比逐本查知秋/书山快一个数量级，也不再依赖三方节点的可用性。
local function try_require(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    return nil
end
local Crypto = try_require("fanqie.reading.crypto")
local Sign = try_require("fanqie.reading.sign")
local Device = try_require("fanqie.reading.device")
local Reading = try_require("fanqie.reading")
local CoverCache = try_require("fanqie.cover_cache")
local Socket = try_require("socket")

M.OFFICIAL_HOST = "api5-normal-sinfonlinec.fqnovel.com"
M.OFFICIAL_PATH = "/reading/bookapi/multi-detail/v/"
M.OFFICIAL_TIMEOUT = 12          -- 单次批量请求
M.OFFICIAL_BATCH = 40            -- 一次最多查多少本（31 本实测 0.5s 全返回）
-- 渲染前预取的总预算与封面下载上限：绝不因为补封面把「正在获取书架」拖太久，
-- 没轮到的封面仍由 UI 线程的 _preloadAllCovers 异步补。
M.PREFLIGHT_BUDGET = 20
M.PREFLIGHT_MAX_COVERS = 6
M.PREFLIGHT_COVER_TIMEOUT = 6

local function is_str(s)
    return H and H.is_str and H.is_str(s) or type(s) == "string"
end

local function log_debug(...)
    local ok, L = pcall(require, "fanqie.logger")
    if ok and type(L) == "table" and L.debug then pcall(L.debug, ...) end
end

-- App 端 UA：搜索接口不带它会被挡（Web UA 返回空 body）
M.APP_UA = "com.dragon.read/6.5.3.32 (Linux; U; Android 13; zh_CN; "
    .. "VDE-AL10; Build/TP1A.220624.014;tt-ok/3.10.0.2)"
M.SEARCH_BASE = "https://novel.snssdk.com/api/novel/channel/homepage/search/"
    .. "search/v1/?aid=1967&offset=0&q="

M.TTL = 7 * 24 * 60 * 60   -- 7 天：过一周才重新核对，稳态下书架刷新 0 请求
M.REQUEST_GAP = 0.2        -- 串行节流，28 本约 6 秒
M.MAX_PER_RUN = 30         -- 单次最多查 30 本：除以节流后落在 Async 超时之内

-- 缓存结构版本：v < 2 的旧缓存只有 name，没有封面 → 强制补查一次。
-- v3（2026-11-10）：取图模板改成分桶选择，缓存里存的旧 expand URL 会带黑边，
-- 必须强制补查一次重新生成；否则 TTL 内书架会一直用旧地址。
M.CACHE_VERSION = 3

-- 封面尺寸与取图规则（2026-11-10 修正）。
-- 两类模板不能混用：
--   ~tplv-shrink:W:0.jpeg            等比缩放到 W 宽，**不补边**；
--                                   但 novel-pic-r / tos-cn-i-* 桶一律 403
--   ~tplv-1yzifmftcy-expand:W:0:0.jpeg  公共模板，四类路径都能取；
--                                   ⚠️ 它是「扩展画布」语义：原图窄于 W 时
--                                   会在左右补纯黑条（地煞七十二变、篡改射雕
--                                   就是这么来的），放进书架看着像没铺满
-- 所以：受限桶（本来就是 3:4 的原图，expand 不补边）用公共模板，其余一律
-- shrink。后缀用 .jpeg 不用 .webp：不依赖设备端 webp 解码，书架第一眼要稳。
M.COVER_HOST = "https://p6-novel.byteimg.com"
M.COVER_STYLE = "1yzifmftcy-expand"   -- 仅 novel-pic-r / tos-* 桶使用
M.COVER_EXT = "jpeg"
M.COVER_WIDTH = 480

local BUSY = false         -- 同一时刻只允许一个校正任务（书架会被反复打开）

-- 缓存路径：<cache_dir>/<book_id>/app_name.lua（与 book_meta.lua 同目录）
function M.cache_path(settings, book_id)
    if not settings or not is_str(book_id) or book_id == "" then return nil end
    if Content and Content.book_cache_dir then
        local ok, dir = pcall(Content.book_cache_dir, settings, book_id)
        if ok and is_str(dir) then return H.join_path(dir, "app_name.lua") end
    end
    return nil
end

-- 返回 (name, at, tried, cover, cover_hash, version)。name 为空串表示「缓存里就是没名字」。
function M.read(settings, book_id)
    local path = M.cache_path(settings, book_id)
    if not path or not H or not H.file_exists(path) then return nil, 0, false, nil, nil, 0 end
    local ok, meta = pcall(dofile, path)
    if not ok or type(meta) ~= "table" then return nil, 0, false, nil, nil, 0 end
    local name = is_str(meta.name) and meta.name or ""
    local cover = is_str(meta.cover) and meta.cover or nil
    local chash = is_str(meta.cover_hash) and meta.cover_hash or nil
    return name, tonumber(meta.at) or 0, meta.tried == true, cover, chash,
        tonumber(meta.v) or 1
end

-- 已缓存的正式名。**不看 TTL**：过期也继续用，绝不退回 SEO 名。
function M.get(settings, book_id)
    local name = M.read(settings, book_id)
    if is_str(name) and name ~= "" then return name end
    return nil
end

-- 已缓存的 App 封面。**同样不看 TTL**：换封面时宁可用旧的也别退回 Web 旧图。
-- @return cover_url|nil, cover_hash|nil
function M.get_cover(settings, book_id)
    local _, _, _, cover, chash = M.read(settings, book_id)
    return cover, chash
end

-- 是否需要再发一次网络请求
function M.needs_fetch(settings, book_id, now)
    local name, at, tried, _cover, _chash, ver = M.read(settings, book_id)
    now = now or os.time()
    if (ver or 1) < M.CACHE_VERSION then
        return true                      -- 旧结构：缺封面字段，补查一次
    end
    if is_str(name) and name ~= "" then
        return (now - at) >= M.TTL      -- 有名字：只按 TTL 复核
    end
    if tried then
        return (now - at) >= M.TTL      -- 确认过没有：同样按 TTL
    end
    return true                          -- 从没查过
end

function M.save(settings, book_id, name, cover, cover_hash, tried)
    local path = M.cache_path(settings, book_id)
    if not path or not H or not H.write_file then return false end
    -- 父目录可能还没建（未下载过的书）
    if Content and Content.book_cache_dir then
        local ok, dir = pcall(Content.book_cache_dir, settings, book_id)
        if ok and is_str(dir) and H.make_dir then pcall(H.make_dir, dir) end
    end
    local body = string.format(
        "return { name = %q, cover = %q, cover_hash = %q, at = %d, tried = %s, v = %d }\n",
        is_str(name) and name or "",
        is_str(cover) and cover or "",
        is_str(cover_hash) and cover_hash or "",
        os.time(), tried and "true" or "false", M.CACHE_VERSION)
    local ok = pcall(H.write_file, path, body)
    return ok and true or false
end

-- 封面路径归一化：把 thumb_uri / 签名 URL 统一成「桶内路径」。
-- 例：`novel-pic/<hash>`、`novel-pic-r/<hash>`、`tos-cn-i-…/<hash>`、裸 `<hash>`
local function cover_path_of(thumb_uri, thumb_url)
    if is_str(thumb_uri) then
        local p = H.trim(thumb_uri)
        if p ~= "" then return p end
    end
    if is_str(thumb_url) and thumb_url ~= "" then
        local path = thumb_url:match("^https?://[^/]+(/.*)$")
        if path then
            path = path:gsub("^/", "")
            local head = path:match("^(.*)~tplv")
            if head then path = head end
            path = path:match("^([^?]*)") or path
            return H.trim(path)
        end
    end
    return ""
end

-- shrink/resize 在这两个桶上实测 403（换 p3/p6/p9/p1 host 都一样），
-- 只有公共 expand 模板能取；而它们的原图本身就是 3:4，expand 不会补边。
local function needs_public_template(path)
    return path:match("^novel%-pic%-r/") ~= nil
        or path:match("^tos%-cn%-i%-[%w]+/") ~= nil
end

--- 由 thumb_uri / thumb_url 生成可下载的封面地址。
--- @return url|nil, hash|nil  hash 是路径末段前 8 位，用于缓存文件名去重
function M.build_cover(thumb_uri, thumb_url, width)
    local path = cover_path_of(thumb_uri, thumb_url)
    if path == "" then return nil, nil end
    local w = tonumber(width) or M.COVER_WIDTH
    local url
    if needs_public_template(path) then
        url = string.format("%s/%s~tplv-%s:%d:0:0.%s",
            M.COVER_HOST, path, M.COVER_STYLE, w, M.COVER_EXT)
    else
        url = string.format("%s/%s~tplv-shrink:%d:0.%s",
            M.COVER_HOST, path, w, M.COVER_EXT)
    end
    local tail = path:match("([%w]+)$")
    return url, tail and tail:sub(1, 8) or nil
end

--- 书山给的是完整 origin 地址（`…/origin/novel-pic/<hash>`），单独归一化。
--- 只接受确认能取到的桶；认不出就返回 nil（调用方保留 Web 封面，不写坏地址）。
function M.cover_from_url(url)
    if not is_str(url) or url == "" then return nil, nil end
    local path = url:match("^https?://[^/]+(/.*)$")
    if not path then return nil, nil end
    path = path:gsub("^/", ""):gsub("^origin/", "")
    path = path:match("^(.*)~tplv") or path
    path = path:match("^([^?]*)") or path
    local bucket = path:match("^([%w%-]+)/") or ""
    -- novel-images / 未知桶实测取不到（404），一律跳过，别拿坏地址覆盖好封面。
    -- 裸 hash（无斜杠）是有效形态，书山的 `origin/<hash>` 就是这种。
    local bare = path:match("^%w+$") ~= nil
    if not bare and bucket ~= "novel-pic" and bucket ~= "novel-pic-r"
        and not path:match("^tos%-cn%-i%-[%w]+/") then
        return nil, nil
    end
    return M.build_cover(path, nil)
end

-- 从搜索响应里按 book_id 取正式书名。
-- 优先走 JSON 解码 + 深度查找（结构与字段位置都不可信，别用正则猜）；
-- 解码不可用时退回「以 book_id 为锚点切段再找 title」的兜底。
function M.parse_title(text, book_id, decoder)
    if not is_str(text) or text == "" or not is_str(book_id) or book_id == "" then
        return nil
    end
    local target = tostring(book_id)

    if decoder then
        local ok, data = pcall(decoder, text)
        if ok and type(data) == "table" then
            local found = nil
            local function walk(t, depth)
                if found or type(t) ~= "table" or depth > 6 then return end
                local bid = t.book_id or t.bookId or t.id
                if bid ~= nil and tostring(bid) == target then
                    local title = t.title or t.book_name or t.bookName
                    if is_str(title) and title ~= "" then
                        found = title
                        return
                    end
                end
                for _, v in pairs(t) do
                    if type(v) == "table" then walk(v, depth + 1) end
                    if found then return end
                end
            end
            walk(data, 0)
            if found then return found end
        end
    end

    -- 兜底：以 "book_id":"<id>" 为锚，取其后 4000 字里第一个 "title":"…"。
    -- 只用于解码失败（极少），命中错的可能性由外层 book_id 精确匹配挡住主要风险。
    for _, key in ipairs({ "book_id", "bookId" }) do
        local pos = text:find('"' .. key .. '":"' .. target .. '"', 1, true)
        if pos then
            local seg = text:sub(pos, pos + 4000)
            local title = seg:match('"title":"([^"]*)"')
            if title and title ~= "" then return title end
        end
    end
    return nil
end

-- 用本地缓存的名字/封面覆盖 books[i]（纯内存，不发网络）。
-- 同时把接口原名记到 web_title，作为下次搜索的 query。
-- 封面换了就把 cover_path 清掉：旧文件是上一张图，留着会让书架一直显示旧封面
-- （CoverCache.find 会按新文件名找不到，重新下载）。
-- 返回被改动的本数。
function M.decorate(settings, books)
    if not settings or type(books) ~= "table" then return 0 end
    local changed = 0
    for _, b in ipairs(books) do
        if type(b) == "table" then
            local bid = b.book_id and tostring(b.book_id) or ""
            if bid ~= "" then
                -- web_title 一旦记下就不再变：title 会被改，原始名只此一份
                if not is_str(b.web_title) or b.web_title == "" then
                    b.web_title = is_str(b.title) and b.title or ""
                end
                local name = M.get(settings, bid)
                if name and name ~= b.title then
                    b.title = name
                    changed = changed + 1
                end
                local cover, chash = M.get_cover(settings, bid)
                if cover and cover ~= "" then
                    if b.cover ~= cover then
                        b.cover = cover
                        b.cover_path = nil
                        changed = changed + 1
                    end
                    b.cover_hash = chash
                end
            end
        end
    end
    return changed
end

-- 回填统计库书名：统计行靠 md5 定位，这里只改显示列，历史页数/时长不受影响。
-- 批量版：一次开库改多本（回调跑在 UI 线程，别为每本书开关一次 sqlite）。
-- items = { { id = "<book_id>", title = "书名" }, ... }
function M.backfill_stats_titles(items)
    if type(items) ~= "table" or #items == 0 then return 0 end
    local ok_sq3, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq3 or not SQ3 then return 0 end
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds or type(DataStorage) ~= "table" then return 0 end
    local ok_path, dir = pcall(DataStorage.getSettingsDir, DataStorage)
    if not ok_path or not is_str(dir) then return 0 end
    local ok_db, db = pcall(SQ3.open, dir .. "/statistics.sqlite3")
    if not ok_db or not db then return 0 end
    local n = 0
    for _, it in ipairs(items) do
        if type(it) == "table" and is_str(it.id) and it.id ~= ""
            and is_str(it.title) and it.title ~= "" then
            local md5 = "fanqie-" .. tostring(it.id)
            local esc = it.title:gsub("'", "''")
            local ok = pcall(function()
                db:exec(string.format("UPDATE book SET title = '%s' WHERE md5 = '%s';", esc, md5))
            end)
            if ok then n = n + 1 end
        end
    end
    pcall(db.close, db)
    return n
end

function M.backfill_stats_title(book_id, title)
    if not is_str(book_id) or book_id == "" then return false end
    if not is_str(title) or title == "" then return false end
    return M.backfill_stats_titles({ { id = book_id, title = title } }) > 0
end

-- 子进程内休眠。无 fork（降级同步）时绝不休眠，否则卡 UI。
local function sleep_seconds(sec)
    if not sec or sec <= 0 then return end
    local ok_a, Async = pcall(require, "fanqie.async")
    if ok_a and type(Async) == "table" and Async.is_available then
        local ok_av, avail = pcall(Async.is_available)
        if ok_av and not avail then return end
    end
    local ok_s, socket = pcall(require, "socket")
    if ok_s and type(socket) == "table" and type(socket.sleep) == "function" then
        pcall(socket.sleep, sec)
    end
end

-- 查一本书的正式名（在子进程里跑）——只走 App 搜索，作最后兜底。
-- 返回 (name, status)：status = "ok" / "empty"（搜到了但没这本）/ "error"
function M.fetch_name_search(client, book_id, query)
    if not client or not is_str(book_id) or book_id == "" then return nil, "error" end
    if not is_str(query) or query == "" then return nil, "empty" end
    local ok_enc = H and H.url_encode
    local url = M.SEARCH_BASE .. (ok_enc and H.url_encode(query) or query)
    local ok_get, text = pcall(function()
        return client:get_text(url, {
            headers = { ["User-Agent"] = M.APP_UA },
            referer = false,   -- 这是 App 接口，带 Web Referer 反而不像客户端
        })
    end)
    if not ok_get or not is_str(text) or text == "" then
        return nil, "error"
    end
    local decoder = nil
    if type(client.json_decode) == "function" then
        decoder = function(s) return client:json_decode(s) end
    end
    local name = M.parse_title(text, book_id, decoder)
    if name and name ~= "" then return name, "ok" end
    return nil, "empty"
end

-- 高精度毫秒时间戳：同秒请求的 X-Ss-Req-Ticket 不能撞。
local function now_ms()
    if Socket and type(Socket.gettime) == "function" then
        return math.floor(Socket.gettime() * 1000)
    end
    return os.time() * 1000 + math.random(0, 999)
end

--- 官方 App multi-detail 批量查询（四神签名）。
--- book_id 用逗号分隔可一次查多本；实测整架 31 本 0.5 秒全返回。
--- 只用已落盘的设备身份，绝不在这里同步注册（会阻塞调用方）。
---@param ids string[] 书号数组
---@return table|nil map  { [book_id] = { name, cover, cover_hash } }, boolean answered
---        answered=true 表示「服务端确实答复了」：map 为空也是有效答复，
---        请求没成功时为 nil（调用方据此区分「查无此书」和「没查成」）。
function M.fetch_official_batch(client, settings, ids)
    if not client or not Crypto or not Sign or not Device or not Reading then return nil end
    if type(ids) ~= "table" or #ids == 0 then return nil end
    local ok_dev, device = pcall(Device.get, settings)
    if not ok_dev or type(device) ~= "table" then return nil end

    local ts = now_ms()
    local params = Crypto.build_common_query(device, ts)
    params.book_id = table.concat(ids, ",")
    local qs = Crypto.encode_query(params)
    local headers = Crypto.build_unsigned_headers(device, ts)
    local ok_sign, signed = pcall(Sign.sign_headers, qs, device.device_id, {
        khronos = math.floor(ts / 1000),
        version_name = device.version_name,
        device_type = device.device_type,
        os_version = device.os_version,
    })
    if not ok_sign or type(signed) ~= "table" then return nil end
    for k, v in pairs(signed) do headers[k] = v end
    headers["X-Ss-Req-Ticket"] = tostring(ts)

    local url = "https://" .. M.OFFICIAL_HOST .. M.OFFICIAL_PATH .. "?" .. qs
    local ok_req, text, code = pcall(function()
        return client:request({
            url = url, method = "GET", headers = headers,
            timeout = M.OFFICIAL_TIMEOUT,
        })
    end)
    if not ok_req or not is_str(text) or text == "" then return nil end
    if not code or code < 200 or code >= 300 then return nil end
    -- 19 位 book_id 若以裸数字出现，rapidjson 解码会丢精度，先补引号
    local safe = Reading.quote_bigints(text)
    local ok_json, data = pcall(function() return client:json_decode(safe) end)
    if not ok_json or type(data) ~= "table" or tonumber(data.code) ~= 0
        or type(data.data) ~= "table" then
        return nil
    end

    local out = {}
    for _, row in ipairs(data.data) do
        if type(row) == "table" then
            local bid = row.book_id ~= nil and tostring(row.book_id) or ""
            local nm = ""
            if is_str(row.book_name) then
                nm = (H and H.trim) and H.trim(row.book_name) or row.book_name
            end
            local cover, chash = M.build_cover(row.thumb_uri, row.thumb_url)
            if bid ~= "" and (nm ~= "" or cover) then
                out[bid] = { name = nm, cover = cover, cover_hash = chash }
            end
        end
    end
    if next(out) == nil then return out, true end
    return out, true
end

--- 书架缓存里是否还有「名字或封面没拿到」的书（新书必然命中）。
--- 供 showBookshelf 决定能不能安全地立刻显示缓存。
--- ⚠️ 判据是「有没有写过校正缓存」，不是缓存内容、也不是 needs_fetch：
---    * 新书没有 app_name.lua → 先显示必然闪 Web 旧名旧图，要等刷新；
---    * TTL 到期只是复核、已确认拿不到 App 值的书（tried）也只是没有值，
---      两者都已有缓存条目，等一次刷新也变不出新数据，白等还拖慢开书架。
function M.has_pending(settings, books)
    if not settings or type(books) ~= "table" then return false end
    for _, b in ipairs(books) do
        if type(b) == "table" then
            local bid = b.book_id and tostring(b.book_id) or ""
            if bid ~= "" then
                local path = M.cache_path(settings, bid)
                if not path or not H or not H.file_exists
                    or not H.file_exists(path) then
                    return true
                end
            end
        end
    end
    return false
end

--- 渲染前批量校正（**必须在后台子进程里调用**）。
--- 官方源一次拿齐名字/封面 → 写缓存 → decorate → 预下载新封面，
--- 于是界面第一次渲染就是 App 值，不会再闪一次 Web 旧名旧图。
--- 官方拿不到的书不写缓存，留给 ensure() 走知秋/书山兜底。
---@return number 本次校正的本数
function M.preflight(client, settings, books)
    if not settings or not client or type(books) ~= "table" or #books == 0 then return 0 end
    local ids = {}
    local now = os.time()
    for _, b in ipairs(books) do
        local bid = type(b) == "table" and b.book_id and tostring(b.book_id) or ""
        if bid ~= "" and M.needs_fetch(settings, bid, now) then
            ids[#ids + 1] = bid
        end
    end
    if #ids == 0 then return 0 end

    local deadline = os.time() + M.PREFLIGHT_BUDGET
    local got = {}
    local absent = {}   -- 服务端明确答复「没有这几本」
    for start = 1, #ids, M.OFFICIAL_BATCH do
        local batch = {}
        for i = start, math.min(start + M.OFFICIAL_BATCH - 1, #ids) do
            batch[#batch + 1] = ids[i]
        end
        local ok_b, res, answered = pcall(M.fetch_official_batch, client, settings, batch)
        if ok_b and type(res) == "table" then
            for k, v in pairs(res) do got[k] = v end
            -- 只有「服务端答复了、这本却不在返回里」才算查无此书；
            -- 请求失败（answered=nil）什么都不写，下次开书架还会重试。
            if answered then
                for _, bid in ipairs(batch) do
                    if not res[bid] then absent[#absent + 1] = bid end
                end
            end
        end
        if os.time() >= deadline then break end
    end
    local n = 0
    for bid, item in pairs(got) do
        M.save(settings, bid, item.name, item.cover, item.cover_hash, true)
        n = n + 1
    end
    -- 查无此书的要落一条「查过」的标记，否则 has_pending 永远为真：
    -- 每次打开书架都会白等一次刷新，而刷新也变不出数据来。
    -- 只在「这本连缓存文件都没有」时写，绝不覆盖已有的好名字。
    for _, bid in ipairs(absent) do
        local path = M.cache_path(settings, bid)
        if path and not (H and H.file_exists and H.file_exists(path)) then
            M.save(settings, bid, nil, nil, nil, true)
        end
    end
    if n == 0 then return 0 end
    M.decorate(settings, books)

    -- 把新封面拉到本地：showBookList 的 CoverCache.find 立刻命中，
    -- 首屏直接显示 App 封面，而不是等 UI 线程异步下载。
    local downloaded = 0
    for _, b in ipairs(books) do
        if downloaded >= M.PREFLIGHT_MAX_COVERS or os.time() >= deadline then break end
        if type(b) == "table" then
            local bid = b.book_id and tostring(b.book_id) or ""
            if bid ~= "" and got[bid] and is_str(b.cover) and b.cover ~= ""
                and CoverCache then
                if not CoverCache.find(settings, b) then
                    local path = CoverCache.path(settings, b)
                    if path then
                        local ok_dl, data, code = pcall(function()
                            return client:request({
                                url = b.cover, method = "GET",
                                headers = { ["Accept"] = "image/*" },
                                timeout = M.PREFLIGHT_COVER_TIMEOUT,
                            })
                        end)
                        if ok_dl and is_str(data) and data ~= "" and code
                            and code >= 200 and code < 300 then
                            local f = io.open(path, "wb")
                            if f then
                                f:write(data)
                                f:close()
                                downloaded = downloaded + 1
                                b.cover_path = path
                            end
                        end
                    end
                end
            end
        end
    end
    log_debug("[book_names] 官方批量预校正:", tostring(n), "本")
    return n
end

-- 查一本书的「App 当前书名 + 封面」（官方批量没命中时的兜底链）。
--
-- 优先级：知秋（按 id 精确）→ 书山（按名搜再认领 id）→ App 搜索（只给名字）。
-- 前两级任一能给齐「名字 + 封面」就直接返回；给不齐就继续往下补。
--
-- @return name|nil, cover|nil, cover_hash|nil, status   status: ok/empty/error
function M.fetch_book(client, settings, book_id, query)
    if not client or not is_str(book_id) or book_id == "" then return nil, nil, nil, "error" end
    local name, cover, chash
    local last_err = "error"

    -- 1) 知秋：/novel/info 按 book_id 直取，改名/换封面同步得最及时
    if type(client.zhiqiu_book_info) == "function" then
        local ok, data, err = pcall(function() return client:zhiqiu_book_info(book_id) end)
        if ok and type(data) == "table" then
            local nm = is_str(data.book_name) and H.trim(data.book_name) or ""
            if nm ~= "" then name = nm end
            cover, chash = M.build_cover(data.thumb_uri, data.thumb_url)
            last_err = (name or cover) and "ok" or "empty"
            if name and cover then return name, cover, chash, "ok" end
        else
            last_err = (ok and tostring(err or "empty")) or "error"
        end
    end

    -- 2) 书山：只能按书名搜，再用解码出的 book_url 认领 book_id
    if type(client.shushan_find_book) == "function" and is_str(query) and query ~= "" then
        local ok, row = pcall(function() return client:shushan_find_book(book_id, query) end)
        if ok and type(row) == "table" then
            local nm = is_str(row.name) and H.trim(row.name) or ""
            local cv, h = M.cover_from_url(row.cover)
            if nm ~= "" and not name then name = nm end
            if cv and not cover then cover, chash = cv, h end
            if name or cover then last_err = "ok" end
            if name and cover then return name, cover, chash, "ok" end
        end
    end

    -- 3) App 搜索：实测书名与 Web 一致（番茄把搜索索引和 Web 对齐了），
    --    留着只为「知秋/书山都没配」时至少能拿到一个名字。
    local s_name, s_status = M.fetch_name_search(client, book_id, query)
    if s_name and not name then name = s_name end
    if not name and not cover then
        last_err = (s_status == "empty") and "empty" or "error"
    end

    if name or cover then return name, cover, chash, "ok" end
    -- 只有明确「查过但没有这本」才允许落盘 tried；其余（网络/鉴权/未配置）
    -- 一律按 error 处理，下次书架刷新还会重试。
    return nil, nil, nil, (last_err == "empty") and "empty" or "error"
end

-- 后台校正入口。同步部分只做「用已有缓存改名」，网络全在子进程。
-- on_updated(books) 在拿到新名字/新封面并写回 books 后调用一次（可能一次都不调）。
function M.ensure(settings, books, on_updated)
    if not settings or type(books) ~= "table" or #books == 0 then return false end
    M.decorate(settings, books)   -- 先用缓存名，保证界面立刻正确
    if BUSY then return false end

    local todo = {}
    for _, b in ipairs(books) do
        if type(b) == "table" and #todo < M.MAX_PER_RUN then
            local bid = b.book_id and tostring(b.book_id) or ""
            local query = b.web_title or ""
            -- 知秋按 book_id 取，不依赖书名，所以 web_title 缺失时仍然值得查
            if bid ~= "" and M.needs_fetch(settings, bid) then
                todo[#todo + 1] = { book_id = bid, query = query }
            end
        end
    end
    if #todo == 0 then return false end

    local ok_Async, Async = pcall(require, "fanqie.async")
    if not ok_Async or type(Async) ~= "table" or not Async.run then
        return false
    end

    BUSY = true
    -- pcall 包住：Async.run 自身抛错（无 fork / 管道失败）时 BUSY 必须复位，
    -- 否则本次会话再也不会有第二次校正的机会
    local ok_run = pcall(Async.run, function()
        local ok_client, Client = pcall(require, "fanqie.client")
        if not ok_client or type(Client) ~= "table" or not Client.new then
            error("client unavailable", 0)
        end
        local ok_new, client = pcall(function() return Client:new(settings) end)
        if not ok_new or not client then error("client init failed", 0) end

        local out = {}
        -- 官方源为主：一次批量把待校正的书拿齐，命中的不再走三方链。
        local ids = {}
        for _, it in ipairs(todo) do ids[#ids + 1] = it.book_id end
        local hit = {}
        for start = 1, #ids, M.OFFICIAL_BATCH do
            local batch = {}
            for i = start, math.min(start + M.OFFICIAL_BATCH - 1, #ids) do
                batch[#batch + 1] = ids[i]
            end
            local ok_b, res = pcall(M.fetch_official_batch, client, settings, batch)
            if ok_b and type(res) == "table" then
                for bid, item in pairs(res) do
                    hit[bid] = true
                    out[bid] = {
                        name = item.name,
                        cover = item.cover,
                        cover_hash = item.cover_hash,
                        tried = true,
                    }
                end
            end
        end
        -- 官方没返回的那几本才退回知秋/书山逐本补
        local remaining = {}
        for _, it in ipairs(todo) do
            if not hit[it.book_id] then remaining[#remaining + 1] = it end
        end
        for i, it in ipairs(remaining) do
            local ok_one, name, cover, chash, status =
                pcall(M.fetch_book, client, settings, it.book_id, it.query)
            if ok_one then
                out[it.book_id] = {
                    name = name,
                    cover = cover,
                    cover_hash = chash,
                    -- 解析到书 / 明确了「搜到但没有这本」才落盘；
                    -- 传输层故障不落盘，下次书架刷新重试
                    tried = (status == "ok" or status == "empty"),
                }
            end
            if i < #remaining then sleep_seconds(M.REQUEST_GAP) end
        end
        -- 知秋 Token 可能是在这个子进程里刚铸出来的（首次/过期后）。
        -- settings 写在子进程里带不回父进程，必须随返回值带上去，否则下次
        -- 又会用新随机 android_id 再铸一个，白耗额度还可能被风控。
        local ok_cfg, cfg = pcall(function() return settings:get_source("zhiqiu") end)
        if ok_cfg and type(cfg) == "table" then
            out._meta = {
                zhiqiu = {
                    token = cfg.token,
                    android_id = cfg.android_id,
                    token_minted_at = cfg.token_minted_at,
                },
            }
        end
        return out
    end, function(ok, result)
        BUSY = false
        if not ok or type(result) ~= "table" then
            log_debug("[book_names] 校正子进程异常，本次不落盘")
            return
        end
        -- 先把子进程里铸的 Token 合并回父进程（settings 会落盘）
        local meta = result._meta
        result._meta = nil
        if type(meta) == "table" and type(meta.zhiqiu) == "table" then
            local zq = meta.zhiqiu
            pcall(function()
                if is_str(zq.token) and zq.token ~= "" then
                    settings:set_source_field("zhiqiu", "token", zq.token)
                end
                if is_str(zq.android_id) and zq.android_id ~= "" then
                    settings:set_source_field("zhiqiu", "android_id", zq.android_id)
                end
                if is_str(zq.token_minted_at) and zq.token_minted_at ~= "" then
                    settings:set_source_field("zhiqiu", "token_minted_at", zq.token_minted_at)
                end
            end)
        end
        local changed = 0
        local sql_items = {}
        for bid, item in pairs(result) do
            if type(item) == "table" and (item.name or item.cover) then
                M.save(settings, bid, item.name, item.cover, item.cover_hash, item.tried)
                if is_str(item.name) and item.name ~= "" then
                    sql_items[#sql_items + 1] = { id = bid, title = item.name }
                end
                changed = changed + 1
            elseif type(item) == "table" and item.tried then
                -- 确认过没有（搜到了但没这本）：标记 tried，TTL 内不再查
                M.save(settings, bid, nil, nil, nil, true)
            end
        end
        -- 一次开库改完，避免 UI 线程上开关 20 次 sqlite
        if #sql_items > 0 then M.backfill_stats_titles(sql_items) end
        if changed > 0 then
            M.decorate(settings, books)
            log_debug("[book_names] 已校正书名/封面:", tostring(changed), "本")
            if on_updated then pcall(on_updated, books) end
        end
    end, {
        poll_interval = 0.3,
        -- 25 本 × (请求 + 0.2s 节流) 可能超过默认 60s；给足余量，
        -- 超时则整批不落盘（下次书架刷新重试），不会写半截错误数据
        timeout = 150,
        on_cancel = function() BUSY = false end,
    })
    if not ok_run then
        BUSY = false
        log_debug("[book_names] Async.run 启动失败，本次跳过")
        return false
    end
    return true
end

return M
