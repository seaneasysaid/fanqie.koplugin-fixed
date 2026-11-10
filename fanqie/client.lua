local ltn12 = require("ltn12")
local Cookie = require("fanqie.cookie")
local FanQie = require("fanqie.fanqie")
local H = require("fanqie.helper")

local ok_https, https = pcall(require, "ssl.https")
local ok_http, http = pcall(require, "socket.http")

-- High-resolution wall-clock timer for perf logging (millisecond precision).
-- Falls back to os.time() (second precision) if socket is unavailable.
local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.time() * 1000
end

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local DEFAULT_TIMEOUT_SECONDS = 15
local SHELF_CACHE_TTL = 5 * 60 -- 5 minutes for shelf cache
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
        official = function(bid, iid, opts) return obj:official_get_content(bid, iid, opts) end,
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

-- 统一报错：鉴权失效走带标记的错误表，其余直接抛消息
local function raise_http_error(client, code, text, resp_headers, err_msg)
    if is_auth_error(client, code, text, resp_headers) then
        error({ auth_expired = true, message = err_msg })
    end
    error(err_msg)
end

-- 公共请求封装：拼装 Cookie/Referer/自定义头 → 发请求 → 回写 Set-Cookie。
-- referer 三态：nil=默认首页；false=一个都不发（部分 CDN 防盗链）；字符串=原样。
-- 返回 text, code, resp_headers（与底层 request/request_follow 一致）
function Client:_request_common(method, url, opts, follow)
    opts = opts or {}
    local cookies = self.settings:get("cookies", {})
    local headers = {}
    if opts.base_headers then
        for key, value in pairs(opts.base_headers) do
            headers[key] = value
        end
    end
    if opts.referer == false then
        -- 显式要求不带 Referer
    elseif opts.referer then
        headers["Referer"] = opts.referer
    else
        headers["Referer"] = FanQie.BASE_URL .. "/"
    end
    local cookie_header = Cookie.to_header(cookies)
    if cookie_header ~= "" then
        headers["Cookie"] = cookie_header
    end
    if opts.headers then
        for key, value in pairs(opts.headers) do
            headers[key] = value
        end
    end

    local req = { url = url, method = method, headers = headers, body = opts.body }
    local text, code, resp_headers
    if follow then
        text, code, resp_headers = self:request_follow(req)
    else
        text, code, resp_headers = self:request(req)
    end

    local set_cookie = header_value(resp_headers, "set-cookie")
    if set_cookie then
        self.settings:set("cookies", Cookie.merge_set_cookie(cookies, set_cookie))
        self.settings:flush()
    end
    return text, code, resp_headers
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local text, code, resp_headers = self:_request_common("POST", url, {
        base_headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = FanQie.BASE_URL,
        },
        referer = opts.referer,
        headers = opts.headers,
        body = self:json_encode(data),
    })
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_msg = string.format("POST %s => %s", url, http_error(self, code, text, resp_headers))
    raise_http_error(self, code, text, resp_headers, err_msg)
end

function Client:get_json(url, opts)
    opts = opts or {}
    local text, code, resp_headers = self:_request_common("GET", url, {
        base_headers = { ["Accept"] = "application/json, text/plain, */*" },
        referer = opts.referer,
        headers = opts.headers,
    })
    if code and code >= 200 and code < 300 then
        return self:json_decode(text), code, resp_headers
    end
    local err_msg = string.format("GET %s => %s", url, http_error(self, code, text, resp_headers))
    raise_http_error(self, code, text, resp_headers, err_msg)
end

function Client:get_text(url, opts)
    opts = opts or {}
    local text, code, resp_headers = self:_request_common("GET", url, {
        base_headers = {
            ["Accept"] = opts.accept
                or "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
        referer = opts.referer,
        headers = opts.headers,
    })
    if code and code >= 200 and code < 300 then
        return text
    end
    raise_http_error(self, code, text, resp_headers, http_error(self, code, text, resp_headers))
end

function Client:get_binary(url, opts)
    opts = opts or {}
    -- Referer: explicit string → use it; false → send none; nil → default base URL.
    -- Some CDNs (e.g. fqnovelpic.com) reject any Referer as anti-leech.
    local text, code, resp_headers = self:_request_common("GET", url, {
        base_headers = { ["Accept"] = opts.accept or "*/*" },
        referer = opts.referer,
        headers = opts.headers,
    }, true) -- true = 跟随重定向
    if code and code >= 200 and code < 300 then
        return text, code, resp_headers
    end
    raise_http_error(self, code, text, resp_headers, http_error(self, code, text, resp_headers))
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

-- 清除本机注册的番茄 App 设备身份与章节密钥缓存，下次取正文时重新注册。
-- 设备身份被风控（连续空响应/403）时用这个重置。
function Client:official_app_reset_identity()
    local ok_set = pcall(function() self.settings:set("reading_device", nil) end)
    local ok_key = pcall(function() self.settings:set("reading_v1_key", nil) end)
    pcall(function() self.settings:flush() end)
    return ok_set and ok_key
end

-- 段评气泡注入（官方 App 协议）：把
-- <comment ident="official:<book>/<item>/<pid>" count="N" /> 插到段落 </p> 前
-- （blk 的 p_idx 正是段评统计用的段落序号），交给 content.lua 既有气泡管线。
--- 把段评统计注入正文气泡，并回报「命中率异常」。
-- 返回 content, para_reviews, anomaly
--   anomaly = { expected=, injected=, blk_seen=, kind="none"|"partial" }
-- 为什么要回报：泡泡依赖正文里的 `<blk p_idx="N">` 段落标记。番茄前端一改版
-- （去掉 blk 或改属性名），气泡会全部消失且**零报错**——用户以为这本书本来
-- 没段评，插件以为一切正常。这里把静默失效变成一条可查的 WARN。
local function inject_comment_tags(content, book_id, item_id, stats)
    local para_reviews = {}
    if type(content) ~= "string" or type(stats) ~= "table" then
        return content, para_reviews
    end
    -- 期望命中段数：stats 里 count > 0 的段
    local expected = 0
    for _, info in pairs(stats) do
        if type(info) == "table" and (tonumber(info.count) or 0) > 0 then
            expected = expected + 1
        end
    end
    local blk_seen = 0
    local out = content:gsub("(<p%s[^>]*>[%s%S]-</p>)", function(seg)
        local pid = tonumber(seg:match('<blk[^>]*p_idx="(%d+)"'))
        if pid then blk_seen = blk_seen + 1 end
        local info = pid and stats[pid]
        local n = info and (tonumber(info.count) or 0) or 0
        if n > 0 and not seg:find("<comment", 1, true) then
            local ident = string.format("official:%s:%s:%d", book_id, item_id, pid)
            table.insert(para_reviews, { ident = ident, count = n })
            local tag = string.format('<comment ident="%s" count="%d" />', ident, n)
            return seg:sub(1, -5) .. tag .. "</p>"
        end
        return seg
    end)

    local anomaly = nil
    local injected = #para_reviews
    if expected > 0 and injected == 0 then
        anomaly = { expected = expected, injected = 0, blk_seen = blk_seen, kind = "none" }
    elseif expected >= 10 and injected * 2 < expected then
        anomaly = { expected = expected, injected = injected, blk_seen = blk_seen, kind = "partial" }
    end
    return out, para_reviews, anomaly
end

-- 通过番茄 App reading 协议取正文：设备注册 → registerkey → batch_full → 本地解密。
-- opts.review = true 时顺带拉段评统计并注入气泡（失败不阻塞正文）。
-- 返回 {content, title, author, source="official_reading", para_reviews} 或 (nil, err)。
function Client:official_app_get_content(book_id, item_id, opts)
    opts = opts or {}
    local Reading = require("fanqie.reading")
    local row, err = Reading.fetch(self, self.settings, book_id, item_id)
    if type(row) ~= "table" or type(row.content) ~= "string" or row.content == "" then
        return nil, err or "App 协议未返回正文"
    end

    local para_reviews = {}
    if opts.review then
        local ok_log, logger_mod = pcall(require, "fanqie.logger")
        local log_info = function(...) if ok_log and logger_mod then pcall(logger_mod.info, ...) end end
        local log_warn = function(...) if ok_log and logger_mod then pcall(logger_mod.warn, ...) end end

        -- Comments.stats 失败时返回 (nil, err)：必须留痕，否则「没气泡」会被
        -- 误判成「本章本来就没有段评」。
        local ok_stats, stats, stats_err = pcall(function()
            local Comments = require("fanqie.reading.comments")
            return Comments.stats(self, self.settings, item_id)
        end)
        if not ok_stats then
            stats, stats_err = nil, stats
        end
        if type(stats) == "table" then
            local ok_inject, content2, reviews, inject_anomaly = pcall(inject_comment_tags,
                row.content or "", tostring(book_id), tostring(item_id), stats)
            if ok_inject then
                row.content = content2
                para_reviews = reviews or {}
                if inject_anomaly then
                    -- 命中率异常：大概率是番茄正文结构改版（blk 标记没了/改名了）。
                    -- 这条 WARN 是「气泡为什么全没了」的唯一线索。
                    log_warn(string.format(
                        "[FanQie][official] 段评气泡注入异常(%s)：stats 命中 %d 段，实际注入 %d 个，正文 blk 标记 %d 处 —— 番茄正文结构可能已改版",
                        tostring(inject_anomaly.kind), inject_anomaly.expected,
                        inject_anomaly.injected, inject_anomaly.blk_seen))
                end
            else
                log_warn("[FanQie][official] 段评气泡注入失败:",
                    tostring(content2))
            end
            local para_n = 0
            for _ in pairs(stats) do para_n = para_n + 1 end
            log_info("[FanQie][official] 段评统计注入:",
                "itemId=" .. tostring(item_id),
                "paras=" .. tostring(para_n),
                "bubbles=" .. tostring(#para_reviews))
        else
            log_warn("[FanQie][official] 段评统计获取失败（正文不带气泡）:",
                tostring(stats_err or stats))
        end
    end

    row.para_reviews = para_reviews
    return row
end

-- Fetch chapter content via the official FanQie API.
-- 正文只走 App reading 协议（设备注册 + 四神签名 + 本地解密）。
-- 旧网页接口 /api/reader/chapter/content 长期 404，已彻底移除，
-- 失败时立刻抛错让上层切下一个书源，不再白等一轮超时。
-- Returns {content, title, author, para_reviews} on success; errors on failure.
function Client:official_get_content(book_id, item_id, opts)
    local ok, row, err = pcall(function()
        return self:official_app_get_content(book_id, item_id, opts)
    end)
    if ok and type(row) == "table" and type(row.content) == "string" and #row.content > 0 then
        return row
    end
    local reason = ok and tostring(err) or ("App协议异常: " .. tostring(row))
    self._official_app_error = reason
    local ok_log, logger_mod = pcall(require, "fanqie.logger")
    if ok_log and logger_mod and logger_mod.warn then
        pcall(logger_mod.warn, "[FanQie][official] 取正文失败:", reason)
    end
    error("官方源取正文失败: " .. reason)
end

-- 官方 App 段评列表（/novel/commentapi/comment/list），ident = official:<bid>:<cid>:<pid>。
-- 返回结构刻意与书山/知秋的「新格式」一致，main.lua 的解析器/气泡兜底/续拉游标原样复用。
-- ⚠️ 失败返回 (nil, err)，绝不返回空页 —— 否则上层会显示成「共 0 条评论」。
--- 官方源二级评论（回复列表）：{ replies, total, has_more, cursor } 或 (nil, err)。
--- 接口返回是平铺的，层级靠 reply_to_reply_id；展示按时间平铺 +「回复 @某人」，不会丢条。
function Client:official_get_para_replies(comment_id, opts)
    opts = opts or {}
    comment_id = tostring(comment_id or "")
    if comment_id == "" then
        return nil, "缺少段评 ID"
    end
    local Comments = require("fanqie.reading.comments")
    local list, info, err = Comments.replies(self, self.settings, comment_id, {
        count = tonumber(opts.count) or 20,
        cursor = tostring(opts.cursor or ""),
    })
    if not list then
        return nil, err or "官方段评回复获取失败"
    end
    local flat = {}
    for _, item in ipairs(list) do
        flat[#flat + 1] = Comments.flatten_reply(item)
    end
    info = type(info) == "table" and info or {}
    local total = tonumber(info.total) or #flat
    local has_more = info.has_more
    if has_more == nil then
        local cursor = tostring(info.cursor or "")
        has_more = (cursor ~= "" and cursor ~= "0" and #flat > 0)
    end
    return {
        replies = flat,
        total = total,
        has_more = has_more,
        cursor = info.cursor,
    }
end

function Client:official_get_para_review(ident, opts)
    opts = opts or {}
    local book_id, item_id, pid = tostring(ident):match("^official:(%d+):(%d+):(%d+)$")
    if not book_id then
        return nil, "段评标识无效（官方源）: " .. tostring(ident):sub(1, 60)
    end
    local Comments = require("fanqie.reading.comments")
    local data_list, info, err = Comments.list(self, self.settings, item_id, book_id,
        tonumber(pid), {
            count = tonumber(opts.count) or 20,
            cursor = tostring(opts.cursor or ""),
            sort = tonumber(opts.sort) or 0,
            item_version = opts.item_version,
        })
    if not data_list then
        return nil, err or "官方段评列表获取失败"
    end
    info = type(info) == "table" and info or {}
    local total = tonumber(info.total) or #data_list
    -- has_more 缺失时用游标兜底：接口给了下一页游标就说明还有内容，
    -- 否则「继续加载」按钮永远不出现（总数已知却只能看第一页）。
    local has_more = info.has_more
    if has_more == nil then
        local cursor = tostring(info.cursor or "")
        has_more = (cursor ~= "" and cursor ~= "0")
    end
    return {
        data = {
            data_list = data_list,
            common_list_info = {
                total = total,
                has_more = has_more,
                cursor = info.cursor,
            },
        },
    }
end

-- 知秋「番茄四合一」Source (ZhiQiu) — delegate to fanqie/zhiqiu.lua
-- Base: https://fq.vv9v.cn  Auth headers: x-sec-token + x-android-id
-- Content: GET /novel/chap?novelId=<book_id>&chapId=<item_id>
-- Catalog: GET /novel/catalog?novelId=<book_id>

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

-- 书籍详情（App 端书名/封面）：按 book_id 精确取，不走搜索。
-- Web 端的书名与封面都停在「改名之前」，这是唯一能拿到 App 当前值的通道。
function Client:zhiqiu_book_info(book_id, opts)
    local ZhiQiu = require("fanqie.zhiqiu")
    return ZhiQiu.get_novel_info(self, self.settings, book_id, opts)
end

-- 书山聚合 Source (ShuShan) — delegate to fanqie/shushan.lua
-- Base: https://v2.vossc.com  Auth: X-Api-Key(base64 api_key) + X-Device-Id
-- Content: POST /content (番茄官方 book_id/item_id; 可解锁VIP章)
-- Catalog: POST /catalog (输入 base64 详情URL → 章节目录)
-- Search:  GET  /search

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

-- 书山按 book_id 认领（解码 book_url 精确匹配）。知秋不可用时的封面兜底。
function Client:shushan_find_book(book_id, keyword, opts)
    local ShuShan = require("fanqie.shushan")
    return ShuShan.find_book(self, self.settings, book_id, keyword, opts)
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
function Client:shushan_get_para_review(ident, opts)
    local bid, cid, pid = tostring(ident):match("^shushan:([^:]+):([^:]+):([^:]+)$")
    if not bid then
        error("书山段评 ident 无效: " .. tostring(ident):sub(1, 80))
    end
    local ShuShan = require("fanqie.shushan")
    return ShuShan.get_para_review(self, self.settings, bid, cid, pid, opts)
end

-- 知秋段评内容拉取。ident 格式: "zhiqiu:<book_id>:<item_id>:<pid>"
-- 由段评气泡 ident（见 fanqie/zhiqiu.lua 注入的 <comment ident="zhiqiu:..."/>）
-- 解析出 bid/cid/pid，调用 GET /novel/comment/paragraph_list 取该段评论。
-- 返回结构为番茄原生 { code, data:{ common_list_info:{total,..}, data_list:[{comment:{common,stat}}] } }，
-- 与书山段评返回格式一致，main.lua 的 _displayParaReviewDetail 可直接解析。
function Client:zhiqiu_get_para_review(ident, opts)
    opts = opts or {}
    -- 知秋的 paragraph_list 只能用 page/size（cursor/offset 参数被服务端忽略，
    -- 与 reply 接口同源）。服务端返回的 common_list_info.cursor 是**条数偏移**
    -- （"30" 表示下一屏从第 30 条开始），这里换算成页码。
    local size = tonumber(opts.size) or 30
    if size < 1 then size = 30 end
    local offset = tonumber(tostring(opts.cursor or "0"))
    if not offset or offset < 0 then offset = 0 end
    local page = math.floor(offset / size) + 1
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
        .. "&page=" .. tostring(page)
        .. "&size=" .. tostring(size)

    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        logger_mod.info("[FanQie] 知秋段评请求:", "pid=" .. tostring(pid),
            "page=" .. tostring(page), "url=" .. url:sub(1, 150))
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

-- 知秋二级评论（回复列表）：GET {base}/novel/comment/reply?bid=&rid=&page=&size=
--   → { code:0, data:{ reply_list:[{Common,stat,reply_id,reply_to_comment_id,
--        reply_to_reply_id,reply_to_user_info,sub_reply}], comment_list_info:{total,has_more,cursor} } }
--
-- 分页用 page/size：2026-10-26 实测 cursor / offset 参数被服务端忽略
-- （page=1&size=20&cursor=2 仍然返回全部 3 条），所以cursor 在这里是**条数偏移**，
-- 由调用方传进来的 cursor 换算成页码。
-- 返回 { replies, total, has_more, cursor }，与 official_get_para_replies 同构，
-- replies 是 Comments.flatten_reply 的扁平结构（Common 大写也认）。
function Client:zhiqiu_get_para_replies(book_id, comment_id, opts)
    opts = opts or {}
    local bid = tostring(book_id or "")
    local rid = tostring(comment_id or "")
    if bid == "" or rid == "" then
        return nil, "缺少书籍或段评 ID"
    end
    local cfg = self.settings:get_source("zhiqiu") or {}
    local ZhiQiu = require("fanqie.zhiqiu")
    local base = H.trim(cfg.server_url or ZhiQiu.DEFAULT_BASE)
    if base:sub(-1) == "/" then base = base:sub(1, -2) end

    local token = H.trim(cfg.token or "")
    if token == "" then
        token = ZhiQiu.ensure_token(self, self.settings, false)
    end
    if token == "" then
        return nil, "知秋书源未配置共享 Token，无法加载回复"
    end
    local android_id = H.trim(cfg.android_id or "")
    local ok_aid, aid_val = pcall(function() return ZhiQiu.resolve_android_id(self.settings) end)
    if ok_aid and type(aid_val) == "string" and aid_val ~= "" then android_id = aid_val end

    local size = math.max(1, math.min(tonumber(opts.count) or 20, 50))
    local offset = math.max(0, math.floor(tonumber(opts.cursor) or 0))
    local page = math.floor(offset / size) + 1

    local url = base .. "/novel/comment/reply?bid=" .. H.url_encode(bid)
        .. "&rid=" .. H.url_encode(rid)
        .. "&page=" .. tostring(page)
        .. "&size=" .. tostring(size)

    local headers = {
        ["User-Agent"]      = FanQie.MOBILE_UA,
        ["x-sec-token"]     = token,
        ["x-android-id"]    = android_id,
        ["Accept"]          = "application/json, text/plain, */*",
        ["Accept-Encoding"] = "identity",
        ["Content-Type"]    = "application/json",
    }
    local ok_req, text, code = pcall(function()
        return self:request({ url = url, method = "GET", headers = headers, timeout = 15 })
    end)
    if not ok_req or not code or code < 200 or code >= 300 then
        return nil, "知秋回复请求失败: HTTP " .. tostring(code or "nil")
            .. " " .. tostring(ok_req and "" or text)
    end
    local ok_decode, result = pcall(function() return self:json_decode(text) end)
    if not ok_decode or type(result) ~= "table" then
        return nil, "知秋回复响应解析失败: " .. tostring(text or ""):sub(1, 160)
    end
    if result.code and result.code ~= 0 then
        return nil, string.format("知秋回复错误: code=%s %s",
            tostring(result.code), tostring(result.error or result.msg or ""))
    end

    local data = type(result.data) == "table" and result.data or {}
    local list = type(data.reply_list) == "table" and data.reply_list or {}
    local Comments = require("fanqie.reading.comments")
    local flat = {}
    for _, item in ipairs(list) do
        local r = Comments.flatten_reply(item)
        -- sub_reply 是「回复的回复」内联数组；渲染端是平铺列表，
        -- 直接按顺序接在后面，避免「点开只有一级」看着缺条。
        if type(r) == "table" then
            flat[#flat + 1] = r
        end
        local subs = type(item.sub_reply) == "table" and item.sub_reply or {}
        for _, sub in ipairs(subs) do
            local sr = Comments.flatten_reply(sub)
            if type(sr) == "table" then
                sr.reply_to_user_name = sr.reply_to_user_name
                    or (type(r) == "table" and r.user_name or nil)
                flat[#flat + 1] = sr
            end
        end
    end
    local info = type(data.comment_list_info) == "table" and data.comment_list_info or {}
    local total = tonumber(info.total) or (#flat + offset)
    local has_more = info.has_more
    if has_more == nil then has_more = (offset + #flat) < total end
    return {
        replies = flat,
        total = total,
        has_more = has_more == true,
        cursor = offset + #flat,
    }
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