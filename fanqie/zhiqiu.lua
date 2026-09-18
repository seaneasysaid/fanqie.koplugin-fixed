-- FanQie Plugin — 知秋「番茄四合一」source (ZhiQiu)
-- =============================================================================
-- Protocol (fq.vv9v.cn), plain JSON, no encryption, no anti-crawl session:
--   Base:   https://fq.vv9v.cn
--   Auth:   headers  x-sec-token: <共享token>   and   x-android-id: <androidId>
--   Search: GET  /novel/search?keyword=<kw>&page=<n>
--   Catalog:GET  /novel/catalog?novelId=<book_id>
--   Content:GET  /novel/chap?novelId=<book_id>&chapId=<item_id>&tone=<tone>
--   Info:   GET  /novel/info?novelId=<book_id>
-- Response fields mirror the 番茄 app (book_name/author/item_id/...).
--
-- The 知秋 service uses the SAME book_id / item_id as 番茄官方 API, so books
-- added to the plugin via 官方 catalog can be read here by passing the same ids.
-- =============================================================================

local H = require("fanqie.helper")
local FanQie = require("fanqie.fanqie")

local ZhiQiu = {}

ZhiQiu.DEFAULT_BASE = "https://fq.vv9v.cn"

-- Generate a stable pseudo device id (kept across runs via settings).
-- 知秋服务端要求的 android id 是合法 16 位 hex（32 位虽也接受，但统一为
-- 16 位以严格匹配官方协议，避免风控歧义）。
local function generate_device_id()
    math.randomseed(os.time() + os.clock())
    local chars = "0123456789abcdef"
    local out = {}
    for i = 1, 16 do
        local pos = math.random(1, #chars)
        out[i] = chars:sub(pos, pos)
    end
    return table.concat(out)
end

-- Resolve android id, caching in settings so it is stable per device.
local function resolve_android_id(settings)
    local cfg = settings:get_source("zhiqiu")
    local aid = H.trim(cfg.android_id or "")
    if aid == "" then
        aid = generate_device_id()
        settings:set_source_field("zhiqiu", "android_id", aid)
    end
    return aid
end
-- Exported for fanqie/client.lua (zhiqiu_get_para_review needs the same android id).
ZhiQiu.resolve_android_id = resolve_android_id

-- Build the GET request wrapper the same way plugin requests are issued.
local function http_get(client, url, headers, timeout)
    local h = {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
    }
    if headers then
        for k, v in pairs(headers) do h[k] = v end
    end
    return client:request({
        url = url,
        method = "GET",
        headers = h,
        timeout = timeout or 15,
    })
end

-- Public entry: fetch one chapter's plain-text content.
-- book_id == 知秋/番茄 novelId ; item_id == chapter id (chapId).
-- opts.token   optional override token (config token is default).
-- opts.base    optional override base url.
-- Returns {content=string, title=string} on success; errors on failure.
function ZhiQiu.get_content(client, settings, book_id, item_id, opts)
    opts = opts or {}
    local cfg = settings:get_source("zhiqiu")
    local base = H.trim(cfg.server_url or ZhiQiu.DEFAULT_BASE)
    if opts.base and opts.base ~= "" then base = opts.base end
    if base:sub(-1) == "/" then base = base:sub(1, -2) end

    local token = H.trim(opts.token or cfg.token or "")
    if token == "" then
        -- No stored token: try to auto-mint from 源作者/官方反馈群/临时Token口令.
        token = ZhiQiu.ensure_token(client, settings, false)
    end
    if token == "" then
        error("知秋书源未配置共享 Token（请在设置→书源管理→知秋四合一中填写 x-sec-token，或填三件套自动获取）")
    end
    local android_id = resolve_android_id(settings)
    local tone = H.trim(opts.tone or cfg.tone_id or "")

    local params = {
        novelId = tostring(book_id),
        chapId  = tostring(item_id),
    }
    if tone ~= "" then params.tone = tone end
    local q = {}
    for k, v in pairs(params) do
        table.insert(q, k .. "=" .. H.url_encode(v))
    end

    local url = base .. "/novel/chap?" .. table.concat(q, "&")
    local text, code = http_get(client, url, {
        ["x-sec-token"]  = token,
        ["x-android-id"] = android_id,
    })
    if not text or not code then
        error("知秋正文请求失败（网络错误）")
    end
    if code < 200 or code >= 300 then
        error(string.format("知秋正文请求失败: HTTP %s", tostring(code)))
    end

    local ok, obj = pcall(function() return client:json_decode(text) end)
    if not ok or type(obj) ~= "table" then
        error("知秋正文响应非 JSON: " .. tostring(text):sub(1, 120))
    end
    -- server replies {code, error?, data:{content,...}} ; data.content is the text
    if obj.code and obj.code ~= 0 and obj.error then
        error("知秋正文错误: " .. tostring(obj.error))
    end
    local data = obj.data or obj
    local content = data.content or ""
    -- 统一段首缩进：知秋上游正文每段行首带 2 个全角空格（U+3000，实测
    -- 2026-09-14 逐字节确认），正文渲染本身又有 CSS `text-indent: 2em`，
    -- 叠加后显示为 4 字符缩进，比书山源多 2 字符。这里剥掉行首的 Unicode
    -- 空白（Lua 的 %s 不认全角空格，故用 helper 的字节级实现），使知秋与
    -- 书山/官方源表现一致——段落缩进统一交由 CSS 负责。
    -- 注意：只改行首内容、不动换行结构，段评 pid 按行号对齐不受影响。
    content = H.strip_leading_blank(content)
    if #content < 20 then
        error(string.format("知秋正文过短: itemId=%s len=%s err=%s",
            tostring(item_id), tostring(#content),
            tostring(obj.error or obj.msg or "")))
    end

    -- 段评（段落评论）注入。知秋正文是纯文本，段落由 \n 分隔，行索引(0-based)
    -- 与 /novel/comment/paragraph_info 返回的 pid 一一对应。段评开关打开时：
    --   1) 调 paragraph_info 拿到 有段评的 pid → count 映射
    --   2) 在每个有段评的段落末尾注入 <comment ident="zhiqiu:BID:CID:PID" count="N"/>
    --   3) 同时生成 para_reviews 表（按段落先后顺序，与 content.lua 渲染气泡的序号一致）
    --   ident 里的 zhiqiu: 前缀用于 main.lua 分发到 zhiqiu_get_para_review 拉取评论内容。
    local para_reviews = {}
    if opts.review then
        local ok_p, pinfo = pcall(ZhiQiu._fetch_paragraph_info, client, settings, book_id, item_id, token, android_id, base)
        if ok_p and pinfo and type(pinfo) == "table" then
            -- 收集有段评的 pid（count>0），按 pid 升序注入（保证顺序与段落一致）
            local pids = {}
            for k, v in pairs(pinfo) do
                local pid = tonumber(k)
                if pid ~= nil and type(v) == "table" and (tonumber(v.count) or 0) > 0 then
                    table.insert(pids, pid)
                end
            end
            table.sort(pids)
            if #pids > 0 then
                -- 拆行（保序）；正文以 \n 分隔段落，行号(0-based) 即 pid
                local lines = {}
                for line in (content .. "\n"):gmatch("(.-)\n") do
                    table.insert(lines, line)
                end
                local injected = false
                -- 注意：知秋正文是纯文本(无 <p>)。content.lua 的段评渲染在
                -- content 无 <p> 时会走"fallback 逐行分段"，该路径会把同段内所有
                -- <comment> 占位符错误地堆到末尾。因此段评模式下必须先把正文转成
                -- 每段一个 <p> 的 HTML，让 clean 走 <p> 分支，每段气泡才能就地保留。
                local html_lines = {}
                local reviews_inserted = {} -- pid -> 已插入，用于段内 <comment>
                for idx, line in ipairs(lines) do
                    local pid = idx - 1
                    -- 该段是否有段评？
                    local has = false
                    for _, p in ipairs(pids) do if p == pid then has = true break end end
                    -- （此处原有两行「计算 trimmed 却从未引用」的死代码，已于
                    --   2026-09-14 删除；行首缩进改由上游 H.strip_leading_blank 统一处理。）
                    if has and line ~= "" then
                        local count = tonumber((pinfo[tostring(pid)] or pinfo[pid] or {}).count) or 0
                        if count > 0 then
                            local ident = "zhiqiu:" .. tostring(book_id) .. ":" .. tostring(item_id) .. ":" .. tostring(pid)
                            table.insert(para_reviews, { ident = ident, count = count })
                            html_lines[#html_lines + 1] = "<p>" .. line
                                .. string.format('<comment ident="%s" count="%d" />', ident, count)
                                .. "</p>"
                            injected = true
                        else
                            html_lines[#html_lines + 1] = "<p>" .. line .. "</p>"
                        end
                    elseif line ~= "" then
                        html_lines[#html_lines + 1] = "<p>" .. line .. "</p>"
                    end
                    -- 空行：保留为换行分隔（不产生空 <p>）
                end
                if injected then
                    content = table.concat(html_lines, "\n")
                end
            end
        end
        -- paragraph_info 请求失败或本段无段评时静默降级：正文照常返回，不报错
    end

    return {
        content      = content,
        title        = data.title or "",
        author       = data.author or "",
        para_reviews = para_reviews,
    }
end

-- Fetch which paragraphs carry comments (pid -> {count,...}) for one chapter.
-- GET /novel/comment/paragraph_info?bid=<book_id>&cid=<chapId>
-- Returns data table { [pid] = {count=.., ...} } ; nil on any failure.
function ZhiQiu._fetch_paragraph_info(client, settings, book_id, item_id, token, android_id, base)
    if base:sub(-1) == "/" then base = base:sub(1, -2) end
    local url = base .. "/novel/comment/paragraph_info?bid=" .. H.url_encode(tostring(book_id))
        .. "&cid=" .. H.url_encode(tostring(item_id))
    local text, code = http_get(client, url, {
        ["x-sec-token"]  = token,
        ["x-android-id"] = android_id,
    })
    if not text or not code or code < 200 or code >= 300 then
        return nil
    end
    local ok, obj = pcall(function() return client:json_decode(text) end)
    if not ok or type(obj) ~= "table" then
        return nil
    end
    if obj.code and obj.code ~= 0 then
        return nil
    end
    local d = obj.data or obj
    if type(d) ~= "table" then return nil end
    return d
end

-- =============================================================================
--  Token acquisition — matches the 知秋 登录页 "获取Token" button (getTempToken).
--  GET {base}/user/temp?id=<androidId>&pw1=<源作者>&pw2=<官方反馈群>&pw3=<临时Token口令>
--  → data = { token, id, left, createTime, ddlTime }   (token valid ~3 days, 6000/day)
-- =============================================================================

-- 用指定 android_id 执行一次铸币请求，返回 (token, err)。err 为 nil 表示成功。
-- err 可能是字符串（网络/解析错）或 { http_code = <数字> }（HTTP 状态异常，含400）。
local function try_mint(client, base, android_id, pw1, pw2, pw3)
    local params = { id = android_id, pw1 = pw1, pw2 = pw2, pw3 = pw3 }
    local q = {}
    for k, v in pairs(params) do
        table.insert(q, k .. "=" .. H.url_encode(tostring(v)))
    end
    local url = base .. "/user/temp?" .. table.concat(q, "&")
    -- x-sec-token empty is fine at mint time; x-android-id must match android_id.
    local text, code = http_get(client, url, {
        ["x-sec-token"]  = "",
        ["x-android-id"] = android_id,
    })
    if not text or not code then
        return nil, "网络错误（无响应）"
    end
    if code < 200 or code >= 300 then
        return nil, { http_code = tonumber(code) }
    end
    local ok, obj = pcall(function() return client:json_decode(text) end)
    if not ok or type(obj) ~= "table" or not obj.data then
        return nil, "响应异常: " .. tostring(text):sub(1, 120)
    end
    if obj.code and obj.code ~= 0 then
        return nil, string.format("code=%s %s",
            tostring(obj.code), tostring(obj.msg or obj.error or ""))
    end
    local token = H.trim(obj.data.token or "")
    if token == "" then
        return nil, "服务端未返回 token"
    end
    return token, nil
end

-- 把 android_id 换成一个全新的随机 id，并持久化到 settings，返回新 id。
local function rotate_android_id(settings)
    local aid = generate_device_id()
    settings:set_source_field("zhiqiu", "android_id", aid)
    return aid
end

-- Auto-mint (or refresh) the shared token from the three 知秋 credentials.
-- The android id used to mint MUST be the SAME hex id sent on content calls.
-- On success it persists { token, minted_at } back into the source config so it
-- survives restarts. Returns the token string; throws on failure.
--
-- 自愈：知秋服务对"同一设备 id"在 token 有效期内重复铸币返回 HTTP 400
-- "用户已存在"。旧 id 一旦卡死（token 曾铸造成功但本地丢失）只能等过期才能重用。
-- 因此遇到 400 / "用户已存在" 时自动更换一个全新 id 重新铸币，并把新 id 持久化，
-- 避免插件一直卡在同一个 id 上反复报 400。
function ZhiQiu.ensure_token(client, settings, force)
    local cfg = settings:get_source("zhiqiu") or {}
    local android_id = resolve_android_id(settings)

    -- If we already hold a token and it is still within its ~3-day window, reuse it.
    if not force then
        local tok = H.trim(cfg.token or "")
        local minted = tonumber(cfg.token_minted_at or 0) or 0
        if tok ~= "" and (os.time() - minted) < (3 * 24 * 3600) then
            return tok
        end
    end

    local pw1 = H.trim(cfg.source_author or "")   -- 源作者   = 知秋
    local pw2 = H.trim(cfg.group_id or "")         -- 官方反馈群 = 755947375
    local pw3 = H.trim(cfg.temp_token_pass or "")  -- 临时Token口令
    if pw1 == "" or pw2 == "" or pw3 == "" then
        error("知秋书源未填写 源作者/官方反馈群/临时Token口令（书源管理→知秋四合一）")
    end

    local base = H.trim(cfg.server_url or ZhiQiu.DEFAULT_BASE)
    if base:sub(-1) == "/" then base = base:sub(1, -2) end

    -- 第 1 次尝试：用当前 android_id。
    local token, err = try_mint(client, base, android_id, pw1, pw2, pw3)
    if token then
        settings:set_source_field("zhiqiu", "token", token)
        settings:set_source_field("zhiqiu", "token_minted_at", tostring(os.time()))
        return token
    end

    -- 判断是否"用户已存在"(HTTP 400 卡死 id)。此时旧 id 绑定了仍在有效期内的
    -- token，本地却拿不到——唯一解法是换一个从未注册过的全新 id 重铸。
    local is_registered_conflict = false
    if type(err) == "table" and err.http_code == 400 then
        is_registered_conflict = true
    elseif type(err) == "string" and err:find("用户已存在", 1, true) then
        is_registered_conflict = true
    end

    if is_registered_conflict then
        -- 换全新 id 重铸一次（旧 id 3 天后可再用，但本地 token 已丢，不等待）。
        local new_id = rotate_android_id(settings)
        local token2, err2 = try_mint(client, base, new_id, pw1, pw2, pw3)
        if token2 then
            settings:set_source_field("zhiqiu", "token", token2)
            settings:set_source_field("zhiqiu", "token_minted_at", tostring(os.time()))
            return token2
        end
        error(string.format(
            "知秋获取Token失败（原设备id %s 已注册但本地Token丢失，已自动更换为 %s 重试仍失败）: %s",
            android_id, new_id,
            type(err2) == "table" and ("HTTP " .. tostring(err2.http_code)) or tostring(err2)))
    end

    -- 非"用户已存在"错误：原样抛出。
    error("知秋获取Token失败: "
        .. (type(err) == "table" and ("HTTP " .. tostring(err.http_code)) or tostring(err)))
end

-- Query remaining quota / expiry of the current token (GET /user/test).
-- Returns the data table { id, left, ddlTime, ... }; throws if unusable.
function ZhiQiu.query_token(client, settings)
    local cfg = settings:get_source("zhiqiu") or {}
    local android_id = resolve_android_id(settings)
    local token = H.trim(cfg.token or "")
    if token == "" then
        error("当前无共享Token，请先获取")
    end
    local base = H.trim(cfg.server_url or ZhiQiu.DEFAULT_BASE)
    if base:sub(-1) == "/" then base = base:sub(1, -2) end

    local url = base .. "/user/test?token=" .. H.url_encode(token)
    local text, code = http_get(client, url, {
        ["x-sec-token"]  = token,
        ["x-android-id"] = android_id,
    })
    if not text or not code or code < 200 or code >= 300 then
        error("查询Token失败: HTTP " .. tostring(code or "nil"))
    end
    local ok, obj = pcall(function() return client:json_decode(text) end)
    if not ok or type(obj) ~= "table" or not obj.data then
        error("查询Token失败（响应异常）")
    end
    if obj.code and obj.code ~= 0 then
        error(string.format("查询Token失败: code=%s %s",
            tostring(obj.code), tostring(obj.msg or obj.error or "")))
    end
    return obj.data
end

-- Optional: fetch the chapter directory (for preview / completeness).
-- Returns list of { item_id, title, first_pass_time } if needed later.
function ZhiQiu.get_catalog(client, settings, book_id, opts)
    opts = opts or {}
    local cfg = settings:get_source("zhiqiu")
    local base = H.trim(cfg.server_url or ZhiQiu.DEFAULT_BASE)
    if base:sub(-1) == "/" then base = base:sub(1, -2) end
    local token = H.trim(opts.token or cfg.token or "")
    local android_id = resolve_android_id(settings)
    if token == "" then error("知秋 Token 未配置") end

    local url = base .. "/novel/catalog?novelId=" .. H.url_encode(tostring(book_id))
    local text, code = http_get(client, url, {
        ["x-sec-token"]  = token,
        ["x-android-id"] = android_id,
    })
    if not text or not code or code < 200 or code >= 300 then
        error("知秋目录请求失败: HTTP " .. tostring(code or "nil"))
    end
    local ok, obj = pcall(function() return client:json_decode(text) end)
    if not ok or type(obj) ~= "table" then error("知秋目录响应非 JSON") end
    return obj.data or obj
end

-- Report whether the source is usable: needs a stored token OR the three
-- 知秋 credential fields (源作者/官方反馈群/临时Token口令) to self-mint one.
function ZhiQiu.is_configured(cfg)
    cfg = cfg or {}
    local token = H.trim(cfg.token or "")
    if token ~= "" then return true end
    local pw1 = H.trim(cfg.source_author or "")
    local pw2 = H.trim(cfg.group_id or "")
    local pw3 = H.trim(cfg.temp_token_pass or "")
    return pw1 ~= "" and pw2 ~= "" and pw3 ~= ""
end

return ZhiQiu
