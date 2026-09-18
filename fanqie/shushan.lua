-- FanQie Plugin — 书山聚合 source (ShuShan)
-- =============================================================================
-- Protocol (https://v2.vossc.com), 5.48 book source, verified live 2026-09-05.
-- Auth is an email/password account + a REAL 16-hex Android device id:
--   Login:    POST /login   form: email, password
--             → data.user.api_key  (16-char plain string, long-lived)
--   Search:   GET  /search?login=search&key=<kw>&page=<n>&source=<src>
--   Catalog:  POST /catalog  json {source, url(base64 book url), name, tab, bookid}
--             → data: [ { url="book_id=X&item_id=Y", title, cid, tag, isVip,... } ]
--   Content:  POST /content  json {cid, source, book_id, item_id, version:"12"}
--             headers  X-Api-Key: base64(api_key)
--                      X-Device-Type: android|ios
--                      X-Device-Id: <real 16-hex android id>
--             → data.content  (plain text on a successfully-registered device)
-- The 书山 service proxies the target source (番茄/晋江/…) itself, so the same
-- book_id/item_id obtained from a 番茄 catalog can be fetched here through 书山
-- (which can also unlock VIP/pay chapters the official API refuses).
--
-- SAFETY: unlike 知秋, 书山 validates the device id server-side. A bogus /
-- random id triggers a soft block (429 "设备码无效") and historically a forged id
-- caused hard bans. We therefore NEVER auto-generate an android id: the user
-- must supply the REAL 16-hex Android ID of a device that has already logged
-- into 书山 via the 阅读 app. We keep email/password + android id in settings.
-- =============================================================================

local H = require("fanqie.helper")
local FanQie = require("fanqie.fanqie")

-- 模块级日志（懒加载 + 缓存）。WARN/ERROR 在 developer_logs=false 时也会落盘，
-- 因此段评这类"静默降级"的链路必须在这里留痕，否则故障无从排查。
local _logger_cache = nil
local function get_logger()
    if _logger_cache == nil then
        local ok, m = pcall(require, "fanqie.logger")
        _logger_cache = ok and m or false
    end
    if _logger_cache then return _logger_cache end
    return nil
end
local function warn(...)
    local lg = get_logger()
    if lg then lg.warn(...) end
end
local function log_debug(...)
    local lg = get_logger()
    if lg then lg.debug(...) end
end

-- 毫秒级墙钟计时（节点测速用）。
-- socket.gettime() 是"真实流逝时间"，网络等待计入在内；os.clock() 只是 CPU
-- 时间（IO 等待不计入），用它测速会把每个节点都测成 ~0ms，故回退只用
-- os.time()（秒级，粗但不造假）。
local ok_socket_perf, socket_perf = pcall(require, "socket")
local function now_ms()
    if ok_socket_perf and socket_perf and socket_perf.gettime then
        return socket_perf.gettime() * 1000
    end
    return os.time() * 1000
end

local ShuShan = {}

-- 可覆盖的计时器（单测注入确定性延迟序列用）
ShuShan._now_ms = now_ms

ShuShan.DEFAULT_BASE = "http://113.44.163.166:7001"
-- 官方节点池：同一套账号/api_key/设备码在各节点通用（2026-09-14 实测同 key 可跨
-- 节点访问）。Sean 指定 113.44.163.166 作首选，1.94.248.5 作第一备选，其余按延迟兜底。
ShuShan.DEFAULT_NODES = {
    -- 2026-09-18 Sean 实测延迟(ms)：v1 153 / v2 172 / 113.44.163.166:7001 199 /
    --   1.94.248.5:7001 200 / v3 222 / v4 472。Sean 指定 113.44 置首为主，
    --   1.94 排第一备选，其余域名按延迟升序兜底（v1,v2,v3,v4）。
    --   两个 IP 直连节点均为 http 明文 + 7001 端口。
    "http://113.44.163.166:7001",
    "http://1.94.248.5:7001",
    "https://v1.vossc.com",
    "https://v2.vossc.com",
    "https://v3.vossc.com",
    "https://v4.vossc.com",
}
-- 内存态（进程内有效，KOReader 重启后重新探测）：
--   _preferred_base  最近一次成功的节点，后续请求优先走它
--   _node_cooldown   传输层失败的节点 → 冷却截止时间戳
ShuShan._preferred_base = nil
ShuShan._node_cooldown = {}
ShuShan.NODE_COOLDOWN_SECONDS = 120
-- 测速探针：/detection 是服务端轻量存活端点，正常 200-500ms，单节点超时给 6s。
ShuShan.DETECT_PATH = "/detection"
ShuShan.PROBE_TIMEOUT = 6
ShuShan.DEFAULT_SOURCE = "番茄小说"
ShuShan.DEFAULT_TAB = "novel"
ShuShan.CONTENT_VERSION = "12"
ShuShan.X_NOVEL_TOKEN = "SHUSAN_READ_2025"
-- AES keys used by 书山 when it DOES return base64-encrypted content (fallback).
ShuShan.AES_KEY = "G@tY3$jK7#mL2&pW8"
ShuShan.AES_IV  = "C!eH4&sM6@wP9^zX1"

-- Local base64 implementation (pure Lua, no external deps). KOReader does not
-- ship base64 in the sandbox, so we implement encode + decode here.
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64_rev = {}
do
    for i = 1, #B64_CHARS do
        b64_rev[B64_CHARS:sub(i, i)] = i - 1
    end
end

local function base64_encode(s)
    s = tostring(s or "")
    local out = {}
    local i = 1
    while i <= #s do
        local b1 = s:byte(i)
        local b2 = s:byte(i + 1)
        local b3 = s:byte(i + 2)
        local c1 = math.floor(b1 / 4)
        local c2 = math.floor((b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0))
        local c3, c4
        if b2 then
            c3 = math.floor((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0))
            c4 = b3 and (b3 % 64) or nil
        end
        out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
            .. B64_CHARS:sub(c2 + 1, c2 + 1)
            .. (c3 and B64_CHARS:sub(c3 + 1, c3 + 1) or "=")
            .. (c4 and B64_CHARS:sub(c4 + 1, c4 + 1) or "=")
        i = i + 3
    end
    return table.concat(out)
end

local function base64_decode(s)
    s = tostring(s or ""):gsub("%s", "")
    -- strip padding
    s = s:gsub("=+$", "")
    if s == "" then return "" end
    local out = {}
    local buffer = 0
    local bits = 0
    for i = 1, #s do
        local v = b64_rev[s:sub(i, i)]
        if v then
            buffer = buffer * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = math.floor(buffer / (2 ^ bits))
                buffer = buffer % (2 ^ bits)
                out[#out + 1] = string.char(byte)
            end
        end
    end
    return table.concat(out)
end

ShuShan.base64_encode = base64_encode
ShuShan.base64_decode = base64_decode

-- =============================================================================
--  base64(api_key) helper — the actual X-Api-Key header value.
-- =============================================================================
function ShuShan.secret_key_header(cfg)
    local api_key = H.trim(cfg.api_key or "")
    return base64_encode(api_key)
end

-- =============================================================================
--  Settings accessors
-- =============================================================================
-- 归一化节点地址：补 scheme、去掉尾部斜杠。空值返回 ""。
local function normalize_base(u)
    u = H.trim(u or "")
    if u == "" then return "" end
    if not u:match("^http") then u = "https://" .. u end
    if u:sub(-1) == "/" then u = u:sub(1, -2) end
    return u
end

-- 候选节点队列（去重 + 优先级排序）：
--   1) 上次成功的节点（内存记忆，本进程内有效）
--   2) 持久化的"最近可用节点"（跨进程/跨重启有效，见 mark_node_ok）
--   3) 用户自定义 server_url
--   4) 内置节点池
-- 处于冷却期（近期传输层失败）的节点被后移，但不剔除 —— 全挂时仍会尝试。
function ShuShan.candidate_bases(cfg)
    cfg = cfg or {}
    local out, seen = {}, {}
    local function add(u)
        u = normalize_base(u)
        if u ~= "" and not seen[u] then
            seen[u] = true
            out[#out + 1] = u
        end
    end
    add(ShuShan._preferred_base)
    -- 持久化的最近可用节点：仅当用户没改过 server_url 时才沿用
    -- （用户显式改地址 = 有意换节点，旧记忆作废）
    local active = H.trim(cfg.active_base or "")
    if active ~= "" and normalize_base(cfg.active_base_src) == normalize_base(cfg.server_url) then
        add(active)
    end
    add(cfg.server_url)
    for _, u in ipairs(ShuShan.DEFAULT_NODES) do add(u) end

    local now = os.time()
    local hot, cold = {}, {}
    for _, u in ipairs(out) do
        local until_t = ShuShan._node_cooldown[u]
        if until_t and until_t > now then
            cold[#cold + 1] = u
        else
            hot[#hot + 1] = u
        end
    end
    for _, u in ipairs(cold) do hot[#hot + 1] = u end
    return hot
end

-- 首选节点（UI 展示 / 单点请求用）
function ShuShan.resolve_base(cfg)
    local bases = ShuShan.candidate_bases(cfg)
    return bases[1] or ShuShan.DEFAULT_BASE
end

-- 节点健康反馈：成功 → 记忆为首选并解除冷却；传输层失败 → 进入冷却。
-- settings 非空时把"最近可用节点"持久化：章节抓取跑在 fork 子进程里，内存态
-- 不会回传父进程，不持久化的话主节点持续故障时每个新章节都要重撞一次超时。
function ShuShan.mark_node_ok(base, settings)
    if not base or base == "" then return end
    ShuShan._preferred_base = base
    ShuShan._node_cooldown[base] = nil
    if not settings then return end
    pcall(function()
        local cfg = settings:get_source("shushan") or {}
        if H.trim(cfg.active_base or "") == base then return end
        cfg.active_base = base
        cfg.active_base_src = normalize_base(cfg.server_url)  -- 记住当时的用户配置
        cfg.active_base_at = tostring(os.time())
        settings:set_source("shushan", cfg)
    end)
end

function ShuShan.mark_node_bad(base)
    if base and base ~= "" then
        ShuShan._node_cooldown[base] = os.time() + (ShuShan.NODE_COOLDOWN_SECONDS or 120)
        if ShuShan._preferred_base == base then
            ShuShan._preferred_base = nil
        end
    end
end

-- The android id is user-supplied (a REAL device that logged into 书山). We do
-- NOT auto-generate one — that would risk a ban. Return "" if not configured.
function ShuShan.resolve_android_id(cfg)
    return H.trim(cfg.android_id or "")
end

-- Determine device type from the stored id length: android uses 16-hex Android
-- ID; if the user pasted a 32-hex value we still treat as android (Xiaomi SSAID
-- can be 32 hex in some 阅读 app builds). Default "android".
function ShuShan.resolve_device_type(cfg)
    local dt = H.trim(cfg.device_type or "")
    if dt == "ios" then return "ios" end
    return "android"
end

-- Validate the android id shape (16 or 32 hex). Returns (ok, norm).
function ShuShan.validate_android_id(aid)
    aid = H.trim(aid or "")
    if aid == "" then return false, "" end
    if aid:match("^%x+$") then
        local len = #aid
        if len == 16 or len == 32 then return true, aid end
    end
    return false, aid
end

-- =============================================================================
--  HTTP helpers (GET/POST JSON)
-- =============================================================================

-- =============================================================================
--  多节点请求：传输层故障时自动切换下一个节点。
-- =============================================================================
-- opts.path 为相对路径（可含 query），会对候选节点依次尝试。
-- 切换判据（仅当"这次请求本身没成功"才换节点）：
--   * 无响应 / 超时 / 连接错误         → 换
--   * HTTP 5xx（服务端故障）           → 换
--   * HTTP 2xx 但响应不是 JSON         → 换
--   * HTTP 4xx（凭据/设备码/参数问题） → 不换，直接报错（换节点也救不了）
--   * HTTP 2xx 且是合法 JSON           → 返回；业务层 code 由调用方判断
-- 任一节点成功即把它记为后续首选，并解除其冷却。
local function request_json_multi(client, settings, cfg, opts)
    local bases = ShuShan.candidate_bases(cfg)
    local label = opts.label or "书山请求"
    local errors = {}
    local function short(u) return tostring(u):gsub("^https?://", ""):gsub("/+$", "") end

    for i, base in ipairs(bases) do
        local h = {
            ["User-Agent"] = FanQie.MOBILE_UA,
            ["Accept"] = "application/json, text/plain, */*",
        }
        for k, v in pairs(opts.headers or {}) do h[k] = v end

        local ok_req, text, code = pcall(function()
            return client:request({
                url = base .. opts.path,
                method = opts.method or "GET",
                headers = h,
                body = opts.body,
                timeout = opts.timeout or 20,
            })
        end)

        if not ok_req or not text or not code then
            -- 传输层失败（连接/超时/异常） → 换节点
            local why = ok_req and "无响应" or tostring(text)
            why = H.truncate_utf8(why:gsub("%s+", " "), 80)
            ShuShan.mark_node_bad(base)
            errors[#errors + 1] = short(base) .. ": " .. why
            warn("[FanQie] 书山节点不可用[" .. label .. "] 节点=" .. short(base) .. " 原因=" .. why)
        elseif code >= 500 then
            -- 服务端故障 → 换节点
            ShuShan.mark_node_bad(base)
            errors[#errors + 1] = short(base) .. ": HTTP " .. tostring(code)
            warn("[FanQie] 书山节点服务端错误[" .. label .. "] 节点=" .. short(base)
                .. " HTTP=" .. tostring(code))
        elseif code < 200 or code >= 300 then
            -- 4xx：确定性错误，换节点无意义，直接抛给上层（保留原有报错文案）
            error(string.format("%s失败: HTTP %s", label, tostring(code)), 0)
        else
            local ok_json, obj = pcall(function() return client:json_decode(text) end)
            if not ok_json or type(obj) ~= "table" then
                if opts.accept_nonjson then
                    -- 存活探针（/detection）返回的是纯文本 "书山聚合"，不是 JSON。
                    -- 调用方显式声明"可接受非 JSON"时，2xx 即视为该节点成功。
                    ShuShan.mark_node_ok(base, settings)
                    if i > 1 then
                        warn("[FanQie] 书山已切换备用节点[" .. label .. "] 节点=" .. short(base)
                            .. " 失败节点数=" .. tostring(i - 1))
                    end
                    return { __raw = text }, code, base
                end
                ShuShan.mark_node_bad(base)
                errors[#errors + 1] = short(base) .. ": 响应非JSON"
                warn("[FanQie] 书山节点响应异常[" .. label .. "] 节点=" .. short(base)
                    .. " body=" .. H.truncate_utf8(tostring(text):gsub("%s+", " "), 80))
            else
                local switched = (i > 1)
                ShuShan.mark_node_ok(base, settings)
                if switched then
                    warn("[FanQie] 书山已切换备用节点[" .. label .. "] 节点=" .. short(base)
                        .. " 失败节点数=" .. tostring(i - 1))
                end
                return obj, code, base
            end
        end
    end

    local msg = string.format("%s全部节点失败(%d个): %s",
        label, #bases, table.concat(errors, " | "))
    warn("[FanQie] " .. msg)
    error(msg, 0)
end

-- =============================================================================
--  Login — POST /login with email+password, store api_key.
-- =============================================================================
-- Returns (ok, err|api_key). err is nil on success.
function ShuShan.login(client, settings, override_email, override_password)
    local cfg = settings:get_source("shushan")
    local email = H.trim(override_email or cfg.email or "")
    local password = H.trim(override_password or cfg.password or "")
    if email == "" or password == "" then
        error("书山未填写邮箱/密码（请在书源管理→书山中配置）")
    end
    -- Build form-urlencoded body (url-encode values).
    local body = "email=" .. H.url_encode(email) .. "&password=" .. H.url_encode(password)
    local obj = request_json_multi(client, settings, cfg, {
        path = "/login",
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["X-Novel-Token"] = ShuShan.X_NOVEL_TOKEN,
        },
        label = "书山登录",
    })
    if not (obj.success or obj.code == 200) then
        error(string.format("书山登录失败: %s", tostring(obj.message or obj.msg or obj.error or "")))
    end
    local user = (obj.data or {}).user or {}
    local api_key = H.trim(user.api_key or "")
    if api_key == "" then
        error("书山登录成功但未返回 api_key")
    end
    -- persist
    local new_cfg = settings:get_source("shushan")
    new_cfg.email = email
    new_cfg.password = password
    new_cfg.api_key = api_key
    new_cfg.api_key_at = tostring(os.time())
    settings:set_source("shushan", new_cfg)
    return true, api_key
end

-- =============================================================================
--  api_key resolution — login if missing/forced.
-- =============================================================================
-- Returns the api_key string; throws on failure.
function ShuShan.ensure_api_key(client, settings, force)
    local cfg = settings:get_source("shushan") or {}
    local key = H.trim(cfg.api_key or "")
    if not force and key ~= "" then
        return key
    end
    -- No stored key → attempt login with stored email/password (or error if absent).
    local email = H.trim(cfg.email or "")
    local password = H.trim(cfg.password or "")
    if email == "" or password == "" then
        error("书山未登录且无凭据（请配置邮箱/密码或先执行「登录测试」）")
    end
    local ok, result = ShuShan.login(client, settings)
    if not ok then error("书山自动登录失败") end
    return result
end

-- =============================================================================
--  Content — POST /content for one chapter.
-- =============================================================================
-- book_id/item_id come from the catalog. Returns {content=string, ...}.
function ShuShan.get_content(client, settings, book_id, item_id, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan")
    local api_key = ShuShan.ensure_api_key(client, settings, false)
    local aid = ShuShan.resolve_android_id(cfg)
    local ok_aid, aid_norm = ShuShan.validate_android_id(aid)
    if not ok_aid then
        error("书山正文需要真实的 Android ID（16/32位hex）。请在书山设置中填写你已登录书山的那台安卓设备的 Android ID，插件不会自动生成（防封号）。")
    end
    local dev_type = ShuShan.resolve_device_type(cfg)
    local source = H.trim(opts.source or cfg.source or ShuShan.DEFAULT_SOURCE)
    -- 书山段评目前只支持番茄聚合源（/para?source=fq 用番茄 item_id 作 chapter_id）。
    -- 非番茄书（晋江/七猫/…）暂不做段评：避免用番茄通道去错拉其它源的段落评论。
    local is_fq_source = source:find("番茄", 1, true) ~= nil
    local cid = tonumber(opts.cid) or 0
    local version = H.trim(opts.version or cfg.content_version or ShuShan.CONTENT_VERSION)

    local body = client:json_encode({
        cid = cid,
        source = source,
        book_id = tostring(book_id),
        item_id = tostring(item_id),
        version = version,
    })

    local obj = request_json_multi(client, settings, cfg, {
        path = "/content",
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Api-Key"] = ShuShan.secret_key_header(cfg),
            ["X-Novel-Token"] = ShuShan.X_NOVEL_TOKEN,
            ["X-Device-Type"] = dev_type,
            ["X-Device-Id"] = aid_norm,
        },
        label = "书山正文",
    })

    -- 429 soft-block / device invalid: surface a clear message (not a hard ban).
    if obj.status == 429 or obj.code == 429 then
        error(string.format("书山正文被拒(设备码无效): %s 请确认 Android ID 是已登录书山的真实设备。", tostring((obj.data or {}).content or "")))
    end
    if obj.code and obj.code ~= 200 then
        error(string.format("书山正文错误 code=%s: %s",
            tostring(obj.code), tostring(obj.msg or (obj.data and obj.data.content) or "")))
    end
    local data = obj.data or {}
    local content = data.content or ""
    if type(content) ~= "string" or content == "" then
        error(string.format("书山正文为空: cid=%s itemId=%s err=%s",
            tostring(cid), tostring(item_id),
            tostring(data.content or obj.msg or obj.error or "")))
    end

    -- 实测（2026-09-05，已登记设备）服务端直接返回明文 UTF-8 正文，无需解密。
    -- 若未来返回 base64 密文，需在此接入 AES-CBC 解密（key/iv 见顶部常量）；
    -- 当前版本只做明文透传。解码函数 base64_decode 已内置供后续扩展。

    local para_reviews = {}
    -- 段评（段落评论）：仅当 全局段评开关打开(opts.review) 且 当前书为番茄源 时启用。
    -- 书山番茄段评链路：GET {host}/para?source=fq&chapter_id=<番茄item_id> →
    --   { code:0, data:{ list:[{paragraph_id, comment_count, hot,...}] } }
    --   paragraph_id 是 0-based 段落行号，与 /content 明文正文的非空行一一对应。
    -- 这里只做「每段显示评论数气泡」的数据注入（含 para_reviews 表供点击时用
    -- shushan: 前缀识别）；点击查看评论正文走书山自有段评通道
    -- （ShuShan.get_para_review → /idea_comment?api=1），不再依赖知秋。
    if opts.review and is_fq_source then
        local ok_pr, pr_list = pcall(ShuShan._fetch_fq_para_reviews,
            client, settings, tostring(book_id), tostring(item_id))
        if not ok_pr then
            -- 旧版本此处静默吞错，导致"新章节没段评"无法定位。补 WARN 留痕。
            warn("[FanQie] 书山段评链路异常: itemId=" .. tostring(item_id)
                .. " err=" .. H.truncate_utf8(tostring(pr_list):gsub("%s+", " "), 200))
        end
        if ok_pr and type(pr_list) == "table" and #pr_list > 0 then
            -- 转成 pid -> count 映射，供按行号注入（与正文非空段 0-based 对齐）
            local pinfo = {}
            for _, item in ipairs(pr_list) do
                local pid = tonumber(item.paragraph_id)
                local count = tonumber(item.comment_count or 0)
                if pid ~= nil and count and count > 0 then
                    pinfo[pid] = count
                end
            end
            local pids = {}
            for pid in pairs(pinfo) do table.insert(pids, pid) end
            if #pids > 0 then
                -- 拆行：正文以 \n 分段。番茄段评的 paragraph_id 对应「非空段落」的
                -- 0-based 行号（标题/空行不计），故这里按 非空行 计数对齐 pid。
                local lines = {}
                for line in (content .. "\n"):gmatch("(.-)\n") do
                    local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
                    if trimmed ~= "" then
                        lines[#lines + 1] = trimmed  -- 仅保留非空行，下标 1-based
                    end
                end
                local html_lines = {}
                local pid_set = {}
                for _, pid in ipairs(pids) do pid_set[pid] = true end
                local injected = false
                -- 只允许 pid 落在实际段落数内（书山会返回超大的稀疏全局段 id）
                local max_pid = #lines - 1
                for idx, line in ipairs(lines) do
                    local pid = idx - 1  -- 0-based 非空行号
                    if pid <= max_pid and pid_set[pid] and pinfo[pid] and pinfo[pid] > 0 then
                        local count = pinfo[pid]
                        local ident = "shushan:" .. tostring(book_id) .. ":" .. tostring(item_id) .. ":" .. tostring(pid)
                        table.insert(para_reviews, { ident = ident, count = count })
                        html_lines[#html_lines + 1] = "<p>" .. line
                            .. string.format('<comment ident="%s" count="%d" />', ident, count)
                            .. "</p>"
                        injected = true
                    else
                        html_lines[#html_lines + 1] = "<p>" .. line .. "</p>"
                    end
                end
                if injected and #html_lines > 0 then
                    content = table.concat(html_lines, "\n")
                end
            end
        end
        -- /para 无段评或失败：正文照常返回，不影响阅读；失败原因已在
        -- _fetch_fq_para_reviews 内部写 WARN 日志（含 code/msg）。
    end

    return {
        content = content,
        title = data.title or "",
        author = data.author or "",
        cid = cid,
        para_reviews = para_reviews,
    }
end

-- =============================================================================
--  番茄段评列表拉取 — GET {host}/para?source=fq&chapter_id=<番茄item_id>
-- =============================================================================
-- 返回 [{paragraph_id, comment_count, hot, ...}, ...]；任何失败返回 nil。
-- 仅对番茄源的章节有意义（其它上游源的 /para source 取值不同，本函数不处理）。
function ShuShan._fetch_fq_para_reviews(client, settings, book_id, item_id)
    local cfg = settings:get_source("shushan") or {}
    ShuShan.ensure_api_key(client, settings, false)
    local aid = ShuShan.resolve_android_id(cfg)
    local ok_aid, aid_norm = ShuShan.validate_android_id(aid)
    if not ok_aid then
        -- 无设备码则无法拉段评（与正文同源校验）：降级但必须留痕
        warn("[FanQie] 书山段评跳过: 未配置真实 Android ID, itemId=" .. tostring(item_id))
        return nil
    end
    local dev_type = ShuShan.resolve_device_type(cfg)
    local obj = request_json_multi(client, settings, cfg, {
        path = "/para?source=fq&chapter_id=" .. H.url_encode(tostring(item_id)),
        method = "GET",
        headers = {
            ["X-Api-Key"] = ShuShan.secret_key_header(cfg),
            ["X-Novel-Token"] = ShuShan.X_NOVEL_TOKEN,
            ["X-Device-Type"] = dev_type,
            ["X-Device-Id"] = aid_norm,
        },
        label = "书山段评",
    })
    if obj.code and obj.code ~= 0 then
        -- /para 是独立通道：失败时正文照常，只有段评气泡消失。2026-09-14 曾发生
        -- 集群级故障（v1~v4 统一返回 code=-1 "获取番茄段评失败"），正是这条日志定位的。
        warn("[FanQie] 书山段评接口返回错误: itemId=" .. tostring(item_id)
            .. " code=" .. tostring(obj.code)
            .. " msg=" .. H.truncate_utf8(tostring(obj.message or obj.msg or ""):gsub("%s+", " "), 120))
        return nil
    end
    local data = obj.data or {}
    local list = data.list
    if type(list) ~= "table" then
        warn("[FanQie] 书山段评响应结构异常: itemId=" .. tostring(item_id)
            .. " data_type=" .. type(obj.data) .. " list_type=" .. type(list))
        return nil
    end
    -- 只保留落在「正文实际行数」内的 pid（书山可能返回稀疏的超大全局段id，
    -- 需在注入前由调用方过滤；这里也先剔除明显的非行号杂值）
    local out = {}
    for _, item in ipairs(list) do
        if type(item) == "table" then
            table.insert(out, item)
        end
    end
    if #out == 0 then
        log_debug("[FanQie] 书山段评: 本章暂无段评数据 itemId=" .. tostring(item_id))
    end
    return out
end

-- =============================================================================
--  段落级段评正文 —— GET {host}/idea_comment?api=1&book_id&item_id&para&cursor
-- =============================================================================
-- 书山自有的段落级 JSON 段评通道（2026-09-13 逆向 SPA /idea_comment 内部真实调用、
-- 实测可用）。此前误判「书山只有 HTML 页」，实际真正的数据接口是同一页面 URL 上带
-- api=1 的相对请求。返回番茄原生结构（与知秋 paragraph_list 同构）：
--   { code:0, data:{ data_list:[{comment:{common,stat,expand}}],
--                    para_src_content:"段落原文" } }
-- 与 main.lua 的 _displayParaReviewDetail 解析器直接兼容；唯一差异是段落原文放在
-- data.para_src_content（而非 comment.expand.para_src_content），此处已注入补齐。
-- cursor 为偏移量（cursor=0/20/40…），非服务端游标。
function ShuShan.get_para_review(client, settings, book_id, item_id, para_id, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan") or {}
    ShuShan.ensure_api_key(client, settings, false)
    local aid = ShuShan.resolve_android_id(cfg)
    local ok_aid, aid_norm = ShuShan.validate_android_id(aid)
    if not ok_aid then
        error("书山段评需要真实的 Android ID（16/32位hex）。请在书山设置中填写已登录书山的安卓设备 ID。")
    end
    local dev_type = ShuShan.resolve_device_type(cfg)

    local COUNT    = tonumber(opts.count) or 20
    local PAGE_MAX = tonumber(opts.page_max) or 5   -- 最多 5 页(≈100条)，防超时/异常
    local sort     = tostring(opts.sort or "1")     -- 1=默认/最热, 0=最新

    local headers = {
        ["X-Api-Key"]     = ShuShan.secret_key_header(cfg),
        ["X-Novel-Token"] = ShuShan.X_NOVEL_TOKEN,
        ["X-Device-Type"] = dev_type,
        ["X-Device-Id"]   = aid_norm,
    }

    local merged = {}
    local para_src = ""
    local cursor = "0"
    local page = 0
    while page < PAGE_MAX do
        page = page + 1
        local path = "/idea_comment?api=1"
            .. "&book_id=" .. H.url_encode(tostring(book_id))
            .. "&item_id=" .. H.url_encode(tostring(item_id))
            .. "&para="    .. H.url_encode(tostring(para_id))
            .. "&cursor="  .. H.url_encode(tostring(cursor))
            .. "&count="   .. tostring(COUNT)
            .. "&sort="    .. H.url_encode(sort)
        local obj = request_json_multi(client, settings, cfg, {
            path = path,
            method = "GET",
            headers = headers,
            label = "书山段评",
            timeout = opts.timeout or 15,
        })
        if obj.code and obj.code ~= 0 then
            error(string.format("书山段评错误: code=%s %s",
                tostring(obj.code), tostring(obj.message or obj.msg or "")))
        end
        local data = obj.data or {}
        if para_src == "" and type(data.para_src_content) == "string" then
            para_src = data.para_src_content
        end
        local list = data.data_list
        if type(list) ~= "table" or #list == 0 then break end
        for _, item in ipairs(list) do merged[#merged + 1] = item end
        if #list < COUNT then break end        -- 本页不足一页 → 到底
        local clinfo = data.common_list_info
        if type(clinfo) == "table" and clinfo.cursor ~= nil then
            cursor = tostring(clinfo.cursor)   -- 服务端给了游标则优先采用
            if clinfo.has_more == false then break end
        else
            cursor = tostring((tonumber(cursor) or 0) + #list)  -- 否则按偏移量累加
        end
    end

    -- 引文注入：让 main.lua 解析器的 comment.expand.para_src_content 拿到段落原文
    if para_src ~= "" then
        for _, item in ipairs(merged) do
            local c = item.comment or item
            if type(c) == "table" then
                if type(c.expand) ~= "table" then c.expand = {} end
                if c.expand.para_src_content == nil then
                    c.expand.para_src_content = para_src
                end
            end
        end
    end

    local ok_logger, logger_mod = pcall(require, "fanqie.logger")
    if ok_logger and logger_mod then
        logger_mod.info("[FanQie] 书山段评:",
            "bid=" .. tostring(book_id), "item=" .. tostring(item_id),
            "para=" .. tostring(para_id), "条数=" .. tostring(#merged))
    end

    return {
        code = 0,
        data = {
            data_list = merged,
            para_src_content = para_src,
            common_list_info = { total = #merged, has_more = false },
        },
    }
end

-- =============================================================================
--  Catalog — POST /catalog for one book's chapter list.
-- =============================================================================
-- input book_url is the base64-encoded 番茄 detail URL from /search.
-- Returns list of { url=book_id&item_id, title, cid, tag, isVip, isPay }.
function ShuShan.get_catalog(client, settings, book_url, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan")
    ShuShan.ensure_api_key(client, settings, false)
    local source = H.trim(opts.source or cfg.source or ShuShan.DEFAULT_SOURCE)
    local name = H.trim(opts.name or "")
    local tab = H.trim(opts.tab or ShuShan.DEFAULT_TAB)
    local bookid = H.trim(opts.bookid or "")

    local body = client:json_encode({
        source = source,
        url = tostring(book_url),
        name = name,
        tab = tab,
        bookid = bookid,
    })
    local obj = request_json_multi(client, settings, cfg, {
        path = "/catalog",
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = "application/json",
            ["X-Api-Key"] = ShuShan.secret_key_header(cfg),
            ["X-Novel-Token"] = ShuShan.X_NOVEL_TOKEN,
        },
        label = "书山目录",
    })
    local data = obj.data or obj
    if type(data) == "table" and data.url then data = { data } end
    if type(data) ~= "table" then
        error("书山目录响应异常")
    end
    local chapters = {}
    for _, ch in ipairs(data) do
        if type(ch) == "table" then
            table.insert(chapters, ch)
        end
    end
    return chapters
end

-- =============================================================================
--  Search — GET /search (used to locate a book then fetch its catalog).
-- =============================================================================
-- source can be "番茄小说", "番茄小说-VIP" etc. Returns the response data list.
function ShuShan.search(client, settings, keyword, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan")
    ShuShan.ensure_api_key(client, settings, false)
    local source = H.trim(opts.source or cfg.source or ShuShan.DEFAULT_SOURCE)
    local page = tonumber(opts.page) or 1
    local path = "/search?login=search&key=" .. H.url_encode(keyword)
        .. "&page=" .. tostring(page) .. "&source=" .. H.url_encode(source)
    local obj = request_json_multi(client, settings, cfg, {
        path = path,
        method = "GET",
        headers = {
            ["X-Api-Key"] = ShuShan.secret_key_header(cfg),
            ["X-Novel-Token"] = ShuShan.X_NOVEL_TOKEN,
        },
        label = "书山搜索",
    })
    return obj.data or obj
end

-- =============================================================================
--  节点测速（连通性 + 延迟）
-- =============================================================================
-- 背景（2026-09-18 修复）：/detection 是服务端的**轻量存活探针**，返回
--   200 + 纯文本 "书山聚合"（Content-Type: text/html），**不是 JSON**。
-- 旧实现让 query_status 走 request_json_multi 的"严格 JSON"判定，于是每个节点
--   都在 json_decode 那步被判成"响应非JSON" → 逐个把节点标记为坏 → 最终报
--   "全部节点失败"，界面上永远显示"检测失败"。而真实业务接口（/content、
--   /search）返回的是合法 JSON，所以出现"能正常看书却检测失败"。
-- 修复：探针按 **HTTP 2xx** 判定存活（响应体非空作为附加信息），不再要求 JSON。
--
-- 探针**不带任何凭据**（绝不把 base64(api_key) 广播给池里每个节点）：
--   /detection 无需鉴权即返回存活标志；凭据有效性由真实业务请求自然验证。
--
-- 返回数组（保持传入 bases 的顺序）：{ base, ms, ok, code, note, retryable }
--   retryable = 是否属于"该换节点"类故障（无响应/超时/5xx），供冷却决策参考。
function ShuShan.probe_nodes(client, settings, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan") or {}
    local bases = opts.bases or ShuShan.candidate_bases(cfg)
    local timeout = opts.timeout or ShuShan.PROBE_TIMEOUT
    local path = opts.path or ShuShan.DETECT_PATH
    local results = {}

    for _, base in ipairs(bases) do
        local t0 = ShuShan._now_ms()
        local ok_req, text, code = pcall(function()
            return client:request({
                url = base .. path,
                method = "GET",
                headers = {
                    ["User-Agent"] = FanQie.MOBILE_UA,
                    ["Accept"] = "*/*",
                },
                timeout = timeout,
            })
        end)
        local ms = ShuShan._now_ms() - t0
        if ms < 0 then ms = 0 end

        local reachable, note, retryable
        if not ok_req then
            reachable, retryable = false, true
            note = H.truncate_utf8(tostring(text):gsub("%s+", " "), 60)
        elseif not code then
            reachable, retryable = false, true
            note = "无响应"
        elseif code >= 500 then
            reachable, retryable = false, true
            note = "HTTP " .. tostring(code)
        elseif code < 200 or code >= 300 then
            reachable, retryable = false, false   -- 4xx：配置/路径问题，换节点没用
            note = "HTTP " .. tostring(code)
        else
            reachable, retryable = true, false
            note = nil
        end

        results[#results + 1] = {
            base = base,
            ms = math.floor(ms + 0.5),
            ok = reachable,
            code = code,
            note = note,
            retryable = retryable,
        }
    end
    return results
end

-- 测速全部候选节点，并切换到**延迟最低**的那个（持久化 → fork 子进程内也生效）。
-- 返回 (best_base|nil, results, err)。
function ShuShan.select_fastest(client, settings, opts)
    local results = ShuShan.probe_nodes(client, settings, opts)
    local best, best_ms
    for _, r in ipairs(results) do
        if r.ok and (not best_ms or r.ms < best_ms) then
            best, best_ms = r.base, r.ms
        end
    end

    -- 按探针结果修正健康状态：可达 → 解除冷却；该换节点的故障 → 进冷却。
    -- （放在选优之后，避免 mark_node_bad 把刚选出的首选清掉。）
    for _, r in ipairs(results) do
        if r.ok then
            ShuShan._node_cooldown[r.base] = nil
        elseif r.retryable then
            ShuShan.mark_node_bad(r.base)
        end
    end

    if not best then
        warn("[FanQie] 书山测速：全部节点不可达（共 " .. tostring(#results) .. " 个）")
        return nil, results, "全部节点不可达"
    end

    ShuShan.mark_node_ok(best, settings)
    warn(string.format("[FanQie] 书山测速完成：选中 %s（%dms），共测 %d 个节点",
        tostring(best), best_ms, #results))
    return best, results
end

-- =============================================================================
--  Query status — 服务器连通性检查（多节点，任一可达即通过）。
-- =============================================================================
-- 修复（2026-09-18）：/detection 是服务端的轻量存活探针，返回 200 + 纯文本
--   "书山聚合"（Content-Type: text/html），**不是 JSON**。旧实现让它走
--   request_json_multi 的严格 JSON 判定 → 每个节点都在 json_decode 那步被判成
--   "响应非JSON" → 逐个标记节点坏 → 报"全部节点失败" → 界面永远"检测失败"；
--   而真实业务接口（/content、/search）返回合法 JSON，所以"能看书却检测失败"。
-- 现在显式声明 accept_nonjson，2xx 即算该节点连通。
-- 探针**不带 api_key**：避免把凭据广播给池里每个节点，/detection 也无需鉴权。
function ShuShan.query_status(client, settings)
    local cfg = settings:get_source("shushan")
    local obj = request_json_multi(client, settings, cfg, {
        path = ShuShan.DETECT_PATH,
        method = "GET",
        headers = {
            ["X-Novel-Token"] = ShuShan.X_NOVEL_TOKEN,
        },
        label = "书山状态",
        accept_nonjson = true,
    })
    return obj.data or obj
end

-- Report whether the source is usable: needs stored email+password (for login)
-- and a real android id. An existing api_key alone is enough to read.
function ShuShan.is_configured(cfg)
    cfg = cfg or {}
    local key = H.trim(cfg.api_key or "")
    if key ~= "" then return true end
    local email = H.trim(cfg.email or "")
    local password = H.trim(cfg.password or "")
    return email ~= "" and password ~= ""
end

return ShuShan
