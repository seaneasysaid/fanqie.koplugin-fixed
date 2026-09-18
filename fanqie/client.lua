local ltn12 = require("ltn12")
local Cookie = require("fanqie.cookie")
local FanQie = require("fanqie.fanqie")
local H = require("fanqie.helper")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

-- High-resolution wall-clock timer for perf logging (millisecond precision).
-- Falls back to os.clock() (CPU time) if socket is unavailable.
local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.clock() * 1000
end

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local SHELF_CACHE_TTL = 5 * 60 -- 5 minutes for shelf cache
local unpack_args = unpack or table.unpack

-- Rate limiting is now handled per-source by fanqie.sources.SourceManager,
-- invoked from get_chapter_content_with_fallback (not inside each fetcher).

local Client = {}
Client.__index = Client

-- SHELF_CACHE：fetch_shelf_detail 内部短缓存，按 cookie_hash 做 key，10 分钟 TTL。
-- 仅用于避免短时间内重复网络请求，不是显示层数据源。
-- 显示层数据源由 bookshelf.lua 的 SHELF_MEM_CACHE（内存主源 + 文件后备）承担。
local SHELF_CACHE = {}

local function header_value(headers, name)
    if not headers then
        return nil
    end
    local target = name:lower()
    for key, value in pairs(headers) do
        if tostring(key):lower() == target then
            return value
        end
    end
    return nil
end

local AUTH_ERROR_CODES = {
    [-2012] = true,
    [-2041] = true,
}

local function is_auth_error(client, code, text, headers)
    if code == 401 or code == 403 then
        return true
    end
    text = tostring(text or "")
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            if AUTH_ERROR_CODES[err_code] then
                return true
            end
            local err_message = data.errMsg or data.errmsg or data.message or data.msg or ""
            if tostring(err_message):find("登录", 1, true) or tostring(err_message):find("登录", 1, true) then
                return true
            end
        end
    end
    return false
end

local function http_error(client, code, text, headers)
    text = tostring(text or "")
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    if is_auth_error(client, code, text, headers) then
        table.insert(parts, "auth_expired=true")
    end
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function transport_request(transport, request, timeout)
    timeout = timeout or DEFAULT_TIMEOUT_SECONDS
    local previous_timeout = transport.TIMEOUT
    transport.TIMEOUT = timeout
    local t0 = now_ms()
    local ok, result1, result2, result3, result4 = pcall(transport.request, request)
    local elapsed = now_ms() - t0
    transport.TIMEOUT = previous_timeout

    -- Perf log: how long the raw HTTP request took (network + TLS + server).
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        local method = (request and request.method) or "GET"
        local url = (request and request.url) or "?"
        -- socket.http returns 1 on success (not the body); the body is
        -- collected by the ltn12 sink, so we can't get its length here.
        -- Only strings/tables support the # operator — numbers don't.
        local body_len = 0
        if type(result1) == "string" or type(result1) == "table" then
            body_len = #result1
        end
        logger_mod.debug("[FanQie][perf] transport_request:",
            "method=" .. method,
            "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
            "code=" .. tostring(result2),
            "result_type=" .. type(result1),
            "url=" .. url)
    end

    if not ok then
        error("transport_request抛异常: " .. tostring(result1))
    end
    -- LuaSocket returns: body, code, headers, status 或 nil, error_message
    -- 检查是否为nil错误（连接失败、超时等）
    if result1 == nil and type(result2) == "string" then
        error("transport_request连接失败: " .. result2)
    end
    return result1, result2, result3, result4
end

function Client:new(settings)
    local obj = setmetatable({
        settings = settings,
    }, self)
    -- Source fetcher dispatch table: source_id -> function(book_id, item_id, opts).
    obj._source_fetchers = {
        official = function(bid, iid) return obj:official_get_content(bid, iid) end,
        zhiqiu = function(bid, iid, opts) return obj:zhiqiu_get_content(bid, iid, opts) end,
        shushan = function(bid, iid, opts) return obj:shushan_get_content(bid, iid, opts) end,
    }
    return obj
end

function Client:json_encode(data)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.encode then
        return json.encode(data)
    end
    return json:encode(data)
end

function Client:json_decode(text)
    if not ok_json then
        error("JSON module is not available")
    end
    if json.decode then
        return json.decode(text)
    end
    return json:decode(text)
end

function Client:request(opts)
    local body = opts.body
    local response = {}
    local headers = opts.headers or {}
    headers["User-Agent"] = headers["User-Agent"] or FanQie.USER_AGENT
    headers["Accept"] = headers["Accept"] or "application/json, text/plain, */*"
    headers["Accept-Encoding"] = "identity"
    headers["Connection"] = "keep-alive"

    if body then
        headers["Content-Length"] = tostring(#body)
    end

    local transport = opts.url:match("^https:") and https or http
    if opts.url:match("^https:") and not ok_https then
        error("ssl.https is not available")
    elseif not transport and not ok_http then
        error("socket.http is not available")
    end

    local request_tbl = {
        url = opts.url,
        method = opts.method or (body and "POST" or "GET"),
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response),
    }
    -- 透传 redirect 选项（socket.http 默认 true 自动跟随，设 false 可手动处理重定向以保留中间 Set-Cookie）
    if opts.redirect ~= nil then
        request_tbl.redirect = opts.redirect
    end

    local _, code, resp_headers, status = transport_request(transport, request_tbl, opts.timeout)

    return table.concat(response), tonumber(code), resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    max_redirects = max_redirects or 5
    local url = opts.url
    for redirect_index = 1, max_redirects + 1 do
        opts.url = url
        local text, code, resp_headers, status = self:request(opts)
        if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
            local location = header_value(resp_headers, "location")
            if not location then
                return text, code, resp_headers, status
            end
            if location:match("^https?://") then
                url = location
            else
                local scheme, host = url:match("^(https?)://([^/]+)")
                if scheme then
                    if location:sub(1, 1) == "/" then
                        url = scheme .. "://" .. host .. location
                    else
                        local prefix = url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
                        url = prefix .. location
                    end
                else
                    url = location
                end
            end
            opts.method = "GET"
            opts.body = nil
            opts.headers = opts.headers or {}
            opts.headers["Content-Length"] = nil
        else
            return text, code, resp_headers, status
        end
    end
    error("Too many redirects")
end

-- Binary-safe download with redirect following (for images, etc.)
function Client:download_binary(url)
    local headers = {
        ["User-Agent"] = FanQie.USER_AGENT,
        ["Accept"] = "*/*",
        ["Accept-Encoding"] = "identity",
        ["Connection"] = "keep-alive",
    }
    local text, code = self:request_follow({
        url = url,
        method = "GET",
        headers = headers,
    })
    if code and code >= 200 and code < 300 then
        return text, code
    end
    return nil, code
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Content-Type"] = "application/json;charset=UTF-8",
        ["Origin"] = FanQie.BASE_URL,
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "POST",
        headers = headers,
        body = self:json_encode(data),
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_detail = http_error(self, code, text, resp_headers)
    local err_msg = string.format("POST %s => %s", url, err_detail)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_json(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
    }
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_detail = http_error(self, code, text, resp_headers)
    local err_msg = string.format("GET %s => %s", url, err_detail)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_text(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        ["Referer"] = opts.referer or (FanQie.BASE_URL .. "/"),
        ["Cookie"] = Cookie.to_header(cookies),
    }
    local text, code, resp_headers = self:request({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text
    end
    local err_msg = http_error(self, code, text, resp_headers)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:get_binary(url, opts)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {
        ["Accept"] = opts.accept or "*/*",
        ["Cookie"] = Cookie.to_header(cookies),
    }
    -- Referer: explicit string → use it; false → send none; nil → default base URL.
    -- Some CDNs (e.g. fqnovelpic.com) reject any Referer as anti-leech.
    if opts.referer == false then
        -- intentionally no Referer header
    elseif opts.referer then
        headers["Referer"] = opts.referer
    else
        headers["Referer"] = FanQie.BASE_URL .. "/"
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end
    local text, code, resp_headers = self:request_follow({
        url = url,
        method = "GET",
        headers = headers,
    })
    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    local err_msg = http_error(self, code, text, resp_headers)
    if is_auth_error(self, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    else
        error(err_msg)
    end
end

function Client:fetch_shelf_info()
    local params = FanQie.make_shelf_params()
    local url = FanQie.shelf_url() .. "?"
    local parts = {}
    for key, value in pairs(params) do
        table.insert(parts, key .. "=" .. H.url_encode(value))
    end
    return self:get_json(url .. table.concat(parts, "&"))
end

function Client:clear_shelf_cache()
    SHELF_CACHE = {}
end

local function get_cookie_hash(cookies)
    local parts = {}
    for k, v in pairs(cookies) do
        table.insert(parts, k .. "=" .. v)
    end
    table.sort(parts)
    return table.concat(parts, ";")
end

function Client:fetch_shelf_detail(force_refresh)
    local now = os.time()
    local cookies = self.settings:get("cookies", {})
    local cache_key = next(cookies) and get_cookie_hash(cookies) or "default"
    local cached = SHELF_CACHE[cache_key]
    if not force_refresh and cached and (now - cached.timestamp) < SHELF_CACHE_TTL then
        return cached.data
    end
    
    -- 书架直接使用官方 API
    local shelf_info = self:fetch_shelf_info()
    if type(shelf_info) ~= "table" or type(shelf_info.data) ~= "table" then
        return { code = 0, data = { detail_list = {} } }
    end
    
    local book_shelf_info = shelf_info.data.book_shelf_info or shelf_info.data.bookShelfInfo or shelf_info.data
    if type(book_shelf_info) ~= "table" or #book_shelf_info == 0 then
        return { code = 0, data = { detail_list = {} } }
    end
    
    local shelf_book_ids = {}
    for _, item in ipairs(book_shelf_info) do
        if item.book_id then
            table.insert(shelf_book_ids, item.book_id)
        end
    end
    
    local progress_result = self:fetch_read_progress()
    local progress_map = {}
    if progress_result and progress_result.data then
        for _, item in ipairs(progress_result.data) do
            progress_map[tostring(item.book_id)] = {
                read_progress = item.read_progress,
                index = item.index,
                item_id = item.item_id,
            }
        end
    end
    
    local books = {}
    for _, book_id in ipairs(shelf_book_ids) do
        local progress = progress_map[tostring(book_id)]
        table.insert(books, {
            book_id = book_id,
            item_id = progress and progress.item_id or "0",
        })
    end
    
    local detail_result = self:post_json(FanQie.bookshelf_multidetail_url(), { books = books })
    if detail_result and detail_result.data and detail_result.data.detail_list then
        for _, book in ipairs(detail_result.data.detail_list) do
            local progress = progress_map[tostring(book.book_id)]
            if progress then
                book.read_progress = progress.read_progress
                book.index = progress.index
                book.latest_read_item_id = progress.item_id
            end
        end
    end
    
    SHELF_CACHE[cache_key] = {
        timestamp = now,
        data = detail_result,
    }
    
    return detail_result
end

function Client:fetch_read_progress()
    return self:get_json(FanQie.progress_url())
end

function Client:update_read_progress(book_id, item_id, index, progress)
    return self:post_json(FanQie.update_progress_url(), {
        book_id = book_id,
        item_id = item_id,
        read_progress = progress or 0,
        index = index,
        read_timestamp = tostring(math.floor(os.time())),
        genre_type = 0,
    })
end

function Client:fetch_chapter_directory(book_id)
    -- 目录直接使用官方 API
    local ok, result = pcall(function()
        return self:get_json(FanQie.directory_url(book_id))
    end)
    
    if ok and result and result.code == 0 and result.data then
        return result
    end
    
    local err_msg = "官方 API 获取目录失败"
    if result then
        err_msg = err_msg .. ": code=" .. tostring(result.code) .. " message=" .. tostring(result.message or "")
    end
    error(err_msg)
end

-- Fetch chapter content via the official FanQie API (public, no login needed).
-- Returns {content, title, author} on success; errors on failure.
function Client:official_get_content(book_id, item_id)
    local url = FanQie.chapter_content_url(book_id, item_id)
    local result = self:get_json(url)
    if type(result) == "table" and result.data then
        local content = result.data.content or ""
        if content and #content > 50 then
            return {
                content = content,
                title = result.data.title or "",
                author = result.data.author or "",
            }
        end
        error(string.format("官方API返回内容过短: itemId=%s, 长度=%s",
            tostring(item_id), tostring(#content)))
    elseif type(result) == "table" then
        local keys = {}
        for k, _ in pairs(result) do table.insert(keys, tostring(k)) end
        error(string.format("官方API响应格式异常: itemId=%s, 缺少data字段, keys=%s",
            tostring(item_id), table.concat(keys, ",")))
    end
    error(string.format("官方API响应无效: itemId=%s, type=%s", tostring(item_id), type(result)))
end

-- ============================================================================
-- 知秋「番茄四合一」Source (ZhiQiu) — delegate to fanqie/zhiqiu.lua
-- Base: https://fq.vv9v.cn  Auth headers: x-sec-token + x-android-id
-- Content: GET /novel/chap?novelId=<book_id>&chapId=<item_id>
-- Catalog: GET /novel/catalog?novelId=<book_id>
-- ============================================================================

function Client:zhiqiu_get_content(book_id, item_id, opts)
    opts = opts or {}
    local ZhiQiu = require("fanqie.zhiqiu")
    return ZhiQiu.get_content(self, self.settings, book_id, item_id, opts)
end

function Client:zhiqiu_get_catalog(book_id, opts)
    opts = opts or {}
    local ZhiQiu = require("fanqie.zhiqiu")
    return ZhiQiu.get_catalog(self, self.settings, book_id, opts)
end

-- ============================================================================
-- 书山聚合 Source (ShuShan) — delegate to fanqie/shushan.lua
-- Base: https://v2.vossc.com  Auth: X-Api-Key(base64 api_key) + X-Device-Id
-- Content: POST /content (番茄官方 book_id/item_id; 可解锁VIP章)
-- Catalog: POST /catalog (输入 base64 详情URL → 章节目录)
-- Search:  GET  /search
-- ============================================================================

function Client:shushan_get_content(book_id, item_id, opts)
    opts = opts or {}
    local ShuShan = require("fanqie.shushan")
    return ShuShan.get_content(self, self.settings, book_id, item_id, opts)
end

function Client:shushan_get_catalog(book_url, opts)
    opts = opts or {}
    local ShuShan = require("fanqie.shushan")
    return ShuShan.get_catalog(self, self.settings, book_url, opts)
end

function Client:shushan_search(keyword, opts)
    opts = opts or {}
    local ShuShan = require("fanqie.shushan")
    return ShuShan.search(self, self.settings, keyword, opts)
end

function Client:shushan_login()
    local ShuShan = require("fanqie.shushan")
    return ShuShan.login(self, self.settings)
end

-- 书山服务器连通性检测（多节点，任一可达即通过）。
-- /detection 返回纯文本而非 JSON，探针按 2xx 判定；不带 api_key。
function Client:shushan_query_status()
    local ShuShan = require("fanqie.shushan")
    return ShuShan.query_status(self, self.settings)
end

-- 书山全节点测速 + 自动切换到延迟最低的节点。
-- 返回 { best = <节点地址|nil>, results = { {base,ms,ok,code,note}, ... }, err = <nil|字符串> }
-- 包成单 table 是因为 Async.run 只透传一个返回值。
function Client:shushan_select_fastest()
    local ShuShan = require("fanqie.shushan")
    local best, results, err = ShuShan.select_fastest(self, self.settings)
    return { best = best, results = results, err = err }
end

-- 书山段落级段评（书山自有 JSON 通道，不依赖知秋）。
-- ident 格式: "shushan:<book_id>:<item_id>:<pid>"
-- GET {base}/idea_comment?api=1&book_id=&item_id=&para=&cursor=&count=&sort=
--   → { code:0, data:{ data_list:[{comment:{common,stat}}], para_src_content } }
-- 与番茄原生/知秋同构，main.lua 的 _displayParaReviewDetail 可直接解析。
function Client:shushan_get_para_review(ident)
    local bid, cid, pid = tostring(ident):match("^shushan:([^:]+):([^:]+):([^:]+)$")
    if not bid then
        error("书山段评 ident 无效: " .. tostring(ident):sub(1, 80))
    end
    local ShuShan = require("fanqie.shushan")
    return ShuShan.get_para_review(self, self.settings, bid, cid, pid)
end

-- 知秋段评内容拉取。ident 格式: "zhiqiu:<book_id>:<item_id>:<pid>"
-- 由段评气泡 ident（见 fanqie/zhiqiu.lua 注入的 <comment ident="zhiqiu:..."/>）
-- 解析出 bid/cid/pid，调用 GET /novel/comment/paragraph_list 取该段评论。
-- 返回结构为番茄原生 { code, data:{ common_list_info:{total,..}, data_list:[{comment:{common,stat}}] } }，
-- 与书山段评返回格式一致，main.lua 的 _displayParaReviewDetail 可直接解析。
function Client:zhiqiu_get_para_review(ident)
    local cfg = self.settings:get_source("zhiqiu")
    local ZhiQiu = require("fanqie.zhiqiu")
    local base = H.trim(cfg.server_url or ZhiQiu.DEFAULT_BASE)
    if base:sub(-1) == "/" then base = base:sub(1, -2) end

    -- token（可能过期，ensure_token 自动续期/铸造）
    local token = H.trim(cfg.token or "")
    if token == "" then
        token = ZhiQiu.ensure_token(self, self.settings, false)
    end
    if token == "" then
        error("知秋书源未配置共享 Token，无法加载段评")
    end
    local android_id = ""
    -- 复用 zhiqiu 模块的 android id（持久化到 settings，与正文请求一致）
    local ok_aid, aid_val = pcall(function()
        return ZhiQiu.resolve_android_id(self.settings)
    end)
    if ok_aid and aid_val and aid_val ~= "" then
        android_id = aid_val
    else
        android_id = H.trim(cfg.android_id or "")
    end

    -- 解析 ident: zhiqiu:BID:CID:PID
    local bid, cid, pid = tostring(ident):match("^zhiqiu:([^:]+):([^:]+):([^:]+)$")
    if not bid then
        error("知秋段评 ident 无效: " .. tostring(ident):sub(1, 80))
    end

    local url = base .. "/novel/comment/paragraph_list?bid=" .. H.url_encode(bid)
        .. "&cid=" .. H.url_encode(cid)
        .. "&pid=" .. H.url_encode(pid)
        .. "&page=1&size=30"

    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        logger_mod.info("[FanQie] 知秋段评请求:", "pid=" .. tostring(pid), "url=" .. url:sub(1, 150))
    end

    local headers = {
        ["User-Agent"]       = FanQie.MOBILE_UA,
        ["x-sec-token"]      = token,
        ["x-android-id"]     = android_id,
        ["Accept"]           = "application/json, text/plain, */*",
        ["Accept-Encoding"]  = "identity",
        ["Content-Type"]     = "application/json",
    }
    local ok_req, text, code = pcall(function()
        return self:request({ url = url, method = "GET", headers = headers, timeout = 15 })
    end)
    if not ok_req or not code or code < 200 or code >= 300 then
        error("知秋段评请求失败: HTTP " .. tostring(code or "nil") .. " " .. tostring(ok_req and "" or text))
    end

    local ok_decode, result = pcall(function()
        return self:json_decode(text)
    end)
    if not ok_decode or type(result) ~= "table" then
        error("知秋段评响应解析失败: " .. tostring(text or ""):sub(1, 200))
    end
    if result.code and result.code ~= 0 then
        error(string.format("知秋段评错误: code=%s %s",
            tostring(result.code), tostring(result.error or result.msg or "")))
    end
    return result
end

-- Generic source scheduler: iterate enabled+configured sources in priority
-- order, applying per-source rate limiting, and fall back to the next on
-- failure.
-- opts: { review = bool }  -- 是否启用段评模式
function Client:get_chapter_content_with_fallback(book_id, item_id, opts)
    opts = opts or {}
    local t_start = now_ms()
    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    local function log_info(...) if ok_logger and logger_mod then logger_mod.info(...) end end
    local function log_debug(...) if ok_logger and logger_mod then logger_mod.debug(...) end end
    local function log_error(...) if ok_logger and logger_mod then logger_mod.error(...) end end

    local SourceManager = require("fanqie.sources")
    local sources = SourceManager.get_active_sources(self.settings)
    if #sources == 0 then
        error("无可用书源（请在「设置 → 书源管理」中启用并配置至少一个源）")
    end

    -- 本轮放行请求记录的时间戳，供子进程→父进程合并限流状态。
    -- 子进程 fork 出 RATE_LIMIT_TIMESTAMPS 副本，记录的时间戳会随子进程退出丢失，
    -- 需经此返回值带回父进程由 SourceManager.merge_rate_limit_timestamps 合并。
    local recorded = {}
    local errors = {}
    for _, src in ipairs(sources) do
        local fetcher = self._source_fetchers[src.id]
        if fetcher then
            local rl = src.config.rate_limit or {}
            local ok_rl, wait, ts = SourceManager.rate_limit_check(src.id, rl.max_requests, rl.window_seconds)
            if not ok_rl then
                log_debug("[FanQie] 源被限流，跳过:",
                    "source=" .. src.id, "wait=" .. tostring(wait) .. "s")
                table.insert(errors, src.id .. ": 限流中(需等" .. tostring(wait) .. "s)")
            else
                if ts then
                    table.insert(recorded, { source_id = src.id, ts = ts })
                end
                log_info("[FanQie] 尝试源:",
                    "source=" .. src.id, "itemId=" .. tostring(item_id))
                local t_src = now_ms()
                local ok, result = pcall(fetcher, book_id, item_id, opts)
                local elapsed = now_ms() - t_src
                if ok and result and result.content then
                    log_debug("[FanQie][perf] 源成功:",
                        "source=" .. src.id,
                        "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
                        "itemId=" .. tostring(item_id),
                        "长度=" .. tostring(#result.content))
                    -- 第3返回值 recorded：本轮记录的限流时间戳，供父进程合并
                    return result, src.id, recorded
                end
                local err_msg = "未知错误"
                if type(result) == "string" then
                    err_msg = result
                elseif type(result) == "table" and result.message then
                    err_msg = result.message
                end
                err_msg = err_msg:gsub("[%c]+", " ")
                log_debug("[FanQie][perf] 源失败，切换下一源:",
                    "source=" .. src.id,
                    "elapsed=" .. string.format("%.0f", elapsed) .. "ms",
                    "err=" .. err_msg)
                table.insert(errors, src.id .. ": " .. err_msg)
            end
        end
    end

    local total_elapsed = now_ms() - t_start
    log_error("[FanQie] 所有书源均失败:",
        "itemId=" .. tostring(item_id),
        "total=" .. string.format("%.0f", total_elapsed) .. "ms",
        "errors=" .. table.concat(errors, " | "))
    error("所有书源均失败: " .. table.concat(errors, " | "))
end

return Client