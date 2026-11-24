-- 书山聚合 source (ShuShan)，https://v2.vossc.com：它自己代理目标站，
-- 同一 book_id/item_id 走它可取到官方接口拒给的 VIP 章。
-- 协议：POST /login → api_key；POST /catalog → 目录；POST /content → 明文正文；
--       头部 X-Api-Key / X-Device-Type / X-Device-Id。
-- ⚠️ 设备号由服务端校验，假 id 会被软封（429「设备码无效」），绝不自动生成，
--    只能由用户填真实 16 位十六进制 Android ID。

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
local function log_info(...)
    local lg = get_logger()
    if lg then lg.info(...) end
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

ShuShan.DEFAULT_BASE = "https://v4.vossc.com"
-- 官方节点池：同一套账号/api_key/设备码在各节点通用（2026-09-14 实测同 key 可跨
-- 节点访问）。
-- 2026-11-20 设备端实测（Kindle，分阶段）：TCP 40-60ms / TLS 70-330ms，
--   服务端处理才是大头，且同一节点 0.4s~5s 横跳。
--   实测排序：v1 388-509 / v4 571-785 / v2 584-989 / v5 505-1047 / v3 623-3536，
--   113.44.163.166 虽免 TLS，但服务端已稳定 5s，故排到最后（仍保留，恢复后可用）。
--   1.94.248.5 持续 6s 超时 / 502，已摘除；要恢复可在「书山服务器地址」手填。
-- ⚠️ 单次「成功但慢」还会被 mark_node_ok 降权 1 小时，顺序不是唯一判据。
ShuShan.DEFAULT_NODES = {
    "https://v4.vossc.com",
    "https://v1.vossc.com",
    "https://v2.vossc.com",
    "https://v5.vossc.com",
    "https://v3.vossc.com",
    "http://113.44.163.166:7001",
}
-- 内存态（进程内有效，KOReader 重启后重新探测）：
--   _preferred_base  最近一次成功的节点，后续请求优先走它
--   _node_cooldown   传输层失败的节点 → 冷却截止时间戳
ShuShan._preferred_base = nil
ShuShan._node_cooldown = {}
ShuShan.NODE_COOLDOWN_SECONDS = 120
-- 「成功但慢」的节点降权窗口：超过 SLOW_MS 视为慢，降权 SLOW_TTL 秒。
-- 只影响排序，不影响可用性（全慢时照样能用）。
ShuShan.SLOW_MS = 4000
ShuShan.SLOW_TTL = 3600
-- 「持久化首选」的准入线：active_base 自己上次的耗时超过这个值就不再优先，
-- 否则 113.44 那种「成功但 1.9s」的节点会一直霸占第一位。
ShuShan.ACTIVE_MS_OK = 1500
-- 测速探针：旧 /detection 已 404，改用 /api/site/public（200 + JSON，无需鉴权）。
-- 正常节点设备端 470-820ms，但服务端负载波动大（实测同一节点 0.7~3.7s 都出现过），
-- 超时压到 3s 会误杀「慢但活着」的节点，故仍给 5s。
ShuShan.DETECT_PATH = "/api/site/public"
ShuShan.PROBE_TIMEOUT = 5
ShuShan.DEFAULT_SOURCE = "番茄小说"
ShuShan.DEFAULT_TAB = "novel"
ShuShan.CONTENT_VERSION = "12"

-- ─────────────────────────────────────────────────────────────────────────
-- v6 协议（2026-11-19）：书山服务端下线了旧 /login /search /catalog /content
-- （全部 404），换成 /api/* + x-novel-* 签名头。旧 api_key 仍是同一把钥匙：
-- x-novel-token = base64(api_key)，x-novel-public = md5(api_key + 设备码 + 秒级时间)。
-- 实测签名用 api_key **原文**（不是 token 原文），否则 40105。正文/目录返回明文，
-- 无需 AES 解密（decryptIfEncrypted 只是书源兜底，插件侧不触发）。
ShuShan.API_VERSION = "11"  -- x-novel-version；服务端对其宽松，保留可配置
-- 内存缓存：书级 sing（按书名查一次）与 item_id→chapter_index 映射（拉一次目录）。
-- 进程内有效，落盘见 _cache_path。
ShuShan._v6_sing = {}       -- [book_id] = { sing, tab, source }
ShuShan._v6_chindex = {}    -- [book_id] = { [item_id] = chapter_index }

local ok_sha2_v6, sha2_v6 = pcall(require, "ffi/sha2")
local md5_v6 = (ok_sha2_v6 and type(sha2_v6) == "table" and sha2_v6.md5) or nil
local sha256_v6 = (ok_sha2_v6 and type(sha2_v6) == "table" and sha2_v6.sha256) or nil
-- 前向声明：v6_resolve_params 在 request_json_multi 定义之前就需要引用它。
local request_json_multi

-- ── v6 段评 JWT（2026-11-19）─────────────────────────────────────────────
-- 书山 v6 的段评 API（/api/comment*）不走 api_key，走网页 SPA 的 JWT。
-- 拿 JWT 需要：GET /api/captcha/challenge → 算 altcha PoW（sha256，约几千次）→
-- POST /api/auth/login {email,password,altcha} → data.jwt（有效期约 7 天）。
-- 邮箱密码与书山登录相同；PoW 在 LuaJIT 里实测 <1s。JWT 缓存到 settings，
-- 过期才重算。失败返回 nil（段评降级到知秋，不影响正文）。
ShuShan.JWT_TTL = 6 * 24 * 3600  -- 提前一天刷新（服务端有效期 ~7 天）
local function hex_to_bytes(s)
    local out = {}
    for h in tostring(s or ""):gmatch("%x%x") do out[#out + 1] = string.char(tonumber(h, 16)) end
    return table.concat(out)
end

local function bytes_to_hex(s)
    return (tostring(s or ""):gsub(".", function(c)
        return string.format("%02x", c:byte())
    end))
end

-- ── libcrypto 加速的 SHA-256（2026-11-20）───────────────────────────────
-- ffi/sha2 的 sha256 实测 ~80µs/次（Sean 双机基准：20 万次 Kindle 8.3s /
-- Kobo 16.5s），altcha PoW 迭代数方差很大（期望 ~65k，尾部可到 40 万），
-- Kobo 上整个求解 20~40s，撞死段评 60s 子进程超时（fanqie.log 里那串
-- 「[async] 子进程超时 60 s」就是这么来的）。KOReader 自带 libcrypto
-- （LibreSSL/OpenSSL），ffi 直调单次 ≈1µs，PoW 压回 1 秒级。
-- 加载时用 SHA256("abc") 标准摘要自检；任何一步不成就整体禁用，
-- 走回下面的 ffi/sha2 十六进制循环 —— 行为一致，只差速度。
local _crypto_SHA256, _sha256_md, _sha256_string, _ffi
do
    local ok_ffi, ffi = pcall(require, "ffi")
    if ok_ffi and type(ffi) == "table" then
        _ffi = ffi
        local ok_cdef = pcall(ffi.cdef,
            -- 用 const char * 声明：LuaJIT 只对 char 指针做 Lua string 自动转换；
            -- 与 lib 里真正的 unsigned char * 形参在 ABI 上完全等价。
            "unsigned char *SHA256(const char *d, size_t n, unsigned char *md);")
        if ok_cdef then
            for _, name in ipairs({ "libcrypto.so.57", "libcrypto.so.1.1", "libcrypto.so.3", "libcrypto" }) do
                local ok_load, lib = pcall(ffi.load, name)
                if ok_load and (type(lib) == "cdata" or type(lib) == "userdata") and pcall(function() return lib.SHA256 end) then
                    _crypto_SHA256 = lib.SHA256
                    break
                end
            end
        end
    end
    if _crypto_SHA256 then
        local known = "\xba\x78\x16\xbf\x8f\x01\xcf\xea\x41\x41\x40\xde\x5d\xae\x22\x23"
            .. "\xb0\x03\x61\xa3\x96\x17\x7a\x9c\xb4\x10\xff\x61\xf2\x00\x15\xad" -- SHA256("abc")
        local ok_test, md = pcall(ffi.new, "unsigned char[32]")
        if ok_test and type(md) == "cdata" then
            local ok_call = pcall(_crypto_SHA256, "abc", 3, md)
            if not ok_call or ffi.string(md, 32) ~= known then
                _crypto_SHA256 = nil
            else
                _sha256_md = md
                _sha256_string = ffi.string
            end
        else
            _crypto_SHA256 = nil
        end
    end
end


local function altcha_solve(parameters)
    if not sha256_v6 or type(parameters) ~= "table" then return nil end
    local salt = hex_to_bytes(parameters.salt or "")
    local nonce = hex_to_bytes(parameters.nonce or "")
    local prefix = tostring(parameters.keyPrefix or "")
    local cost = math.max(1, tonumber(parameters.cost) or 1)
    if salt == "" or nonce == "" or prefix == "" then return nil end
    local prefix_len = #prefix
    if prefix_len == 0 or prefix_len > 64 then return nil end
    -- 快路径：libcrypto 直调。要点（2026-11-20 双机真机实测踩坑）：
    -- ① Kobo/Kindle 的 luajit 里 ffi.load 返回 userdata 不是 cdata，守卫别断言类型；
    -- ② 这套老 luajit 的自动 GC 在「每迭代都分配 Lua 字符串」的 ffi 热循环里会段错误
    --    （双机实测），所以循环体零分配：输入写进预填的 ffi 缓冲、前缀用 md 下标比较；
    -- ③ 只在 cost==1 时启用：cost>1 的哈希链（慢路径按 hex 链）语义未验证，交回慢路径。
    -- 服务端要完整 64-hex derivedKey（截到 keyLength 会 401），命中才 hex 一次。
    if _crypto_SHA256 and _ffi and cost == 1 then
        local prefix_bytes = hex_to_bytes(prefix)
        if #prefix_bytes * 2 == prefix_len then
            local base_len = #salt + #nonce
            local total = base_len + 4
            local inbuf = _ffi.new("unsigned char[?]", total)
            _ffi.copy(inbuf, salt, #salt)
            _ffi.copy(inbuf + #salt, nonce, #nonce)
            local in_ptr = _ffi.cast("const char *", inbuf)
            local pb = {}
            for i = 1, #prefix_bytes do pb[i - 1] = prefix_bytes:byte(i) end
            local plen = #prefix_bytes
            for counter = 0, 2000000 do
                inbuf[base_len] = math.floor(counter / 16777216) % 256
                inbuf[base_len + 1] = math.floor(counter / 65536) % 256
                inbuf[base_len + 2] = math.floor(counter / 256) % 256
                inbuf[base_len + 3] = counter % 256
                _crypto_SHA256(in_ptr, total, _sha256_md)
                local match = true
                for i = 0, plen - 1 do
                    if _sha256_md[i] ~= pb[i] then match = false break end
                end
                if match then
                    return { counter = counter, derivedKey = bytes_to_hex(_sha256_string(_sha256_md, 32)), time = 0 }
                end
            end
            return nil
        end
    end
    for counter = 0, 2000000 do
        local c3 = string.char(
            math.floor(counter / 16777216) % 256,
            math.floor(counter / 65536) % 256,
            math.floor(counter / 256) % 256,
            counter % 256)
        local key = sha256_v6(salt .. nonce .. c3)
        for _ = 1, cost - 1 do key = sha256_v6(key) end
        -- 服务端验证要完整 64-hex derivedKey（altcha-insecure.js 虽截断到
        -- keyLength，本站实测传完整值才过签；截到 32 会 401）。
        if key:sub(1, prefix_len):lower() == prefix:lower() then
            return { counter = counter, derivedKey = key:lower(), time = 0 }
        end
    end
    return nil
end

function ShuShan.ensure_jwt(client, settings, cfg, force)
    local now = os.time()
    if not force then
        local cached = H.trim(cfg.jwt or "")
        local at = tonumber(cfg.jwt_at or 0) or 0
        if cached ~= "" and (now - at) < ShuShan.JWT_TTL then return cached end
    end
    local email = H.trim(cfg.email or "")
    local password = H.trim(cfg.password or "")
    if email == "" or password == "" then return nil end
    local base = nil
    local bases = ShuShan.candidate_bases(cfg)
    base = bases[1]
    if not base then return nil end
    local headers = { ["User-Agent"] = FanQie.MOBILE_UA, ["Accept"] = "application/json" }
    -- ① challenge
    local ok_ch, ch = pcall(function()
        local t, code = client:request({ url = base .. "/api/captcha/challenge",
            method = "GET", headers = headers, timeout = 15 })
        if not code or code < 200 or code >= 300 then return nil end
        return client:json_decode(t)
    end)
    if not ok_ch or type(ch) ~= "table" or type(ch.parameters) ~= "table" then return nil end
    -- ② PoW
    local solution = altcha_solve(ch.parameters)
    if not solution then return nil end
    -- ③ payload = base64({challenge:{parameters,signature},solution})
    local challenge = { parameters = ch.parameters, signature = ch.signature }
    local ok_enc, payload = pcall(function()
        return ShuShan.base64_encode(client:json_encode({ challenge = challenge, solution = solution }))
    end)
    if not ok_enc or not payload then return nil end
    -- ④ SPA login
    local body = client:json_encode({ email = email, password = password, altcha = payload })
    local lg = { ["User-Agent"] = FanQie.MOBILE_UA, ["Accept"] = "application/json",
                 ["Content-Type"] = "application/json" }
    local ok_lg, jwt = pcall(function()
        local t, code = client:request({ url = base .. "/api/auth/login", method = "POST",
            headers = lg, body = body, timeout = 20 })
        if not code or code < 200 or code >= 300 then return nil end
        local o = client:json_decode(t)
        if type(o) ~= "table" or o.code ~= 0 then return nil end
        local d = o.data or {}
        local j = d.jwt or d.access_token or ""
        if type(j) ~= "string" or j == "" then return nil end
        return j
    end)
    if not ok_lg or not jwt then return nil end
    -- ⑤ persist
    pcall(function()
        local nc = settings:get_source("shushan") or {}
        nc.jwt = jwt
        nc.jwt_at = tostring(now)
        settings:set_source("shushan", nc)
    end)
    cfg.jwt, cfg.jwt_at = jwt, tostring(now)
    return jwt
end
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

-- ── v6 鉴权头 ────────────────────────────────────────────────────────────
-- 返回 2 个值：(headers, err)。api_key 与真实 android_id 必填。
-- x-novel-token = base64(api_key)；x-novel-public = md5(api_key 原文 .. deviceid .. ts)。
function ShuShan.v6_headers(cfg)
    local api_key = H.trim(cfg.api_key or "")
    local aid = H.trim(cfg.android_id or "")
    if api_key == "" then return nil, "书山未登录（无 api_key）" end
    if aid == "" then return nil, "书山需要真实 Android ID（v6 签名）" end
    if not md5_v6 then return nil, "缺少 ffi/sha2（无法计算书山签名）" end
    local ts = tostring(os.time())
    local token = base64_encode(api_key)
    local public = md5_v6(api_key .. aid .. ts)
    if type(public) ~= "string" then public = "" end
    return {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Accept"] = "application/json, text/plain, */*",
        ["Content-Type"] = "application/json",
        ["x-novel-token"] = token,
        ["x-novel-deviceid"] = aid,
        ["x-novel-timestamap"] = ts,
        ["x-novel-public"] = public:lower(),
        ["x-novel-version"] = ShuShan.API_VERSION,
    }
end

-- v6 元数据缓存（sing / item_id→chapter_index）落盘路径：
-- <cache_dir>/<book_id>/_shushan_v6.lua。放书缓存目录，随书一起管理。
local function v6_cache_path(settings, book_id)
    local ok_content, Content = pcall(require, "fanqie.content")
    if not ok_content or not Content or not Content.book_cache_dir then return nil end
    local dir = Content.book_cache_dir(settings, book_id)
    return dir .. "/_shushan_v6.lua"
end

local function v6_cache_load(settings, book_id)
    local p = v6_cache_path(settings, book_id)
    if not p or not H.file_exists(p) then return nil end
    local ok, obj = pcall(dofile, p)
    if ok and type(obj) == "table" then return obj end
    return nil
end

local function v6_cache_save(settings, book_id, obj)
    local p = v6_cache_path(settings, book_id)
    if not p then return end
    pcall(function()
        local dir = p:match("^(.*)/[^/]+$")
        if dir and H.make_dir then H.make_dir(dir) end
        local f = io.open(p, "w")
        if not f then return end
        local function ser(v)
            if type(v) == "table" then
                local parts = {}
                for k, val in pairs(v) do
                    parts[#parts + 1] = "[" .. string.format("%q", tostring(k)) .. "]=" .. ser(val)
                end
                return "{" .. table.concat(parts, ",") .. "}"
            elseif type(v) == "number" then
                return tostring(v)
            else
                return string.format("%q", tostring(v))
            end
        end
        f:write("return " .. ser(obj) .. "\n")
        f:close()
    end)
end

-- v6 取正文需要 sing（书级，书名查一次）+ chapter_index（书山目录里的序号）。
-- 插件调用链只有 book_id/item_id，这里内部闭环补齐并缓存：
--   sing    —— 用 book_names 缓存的书名查 /api/search，取该书的 sing/tab/source；
--   chindex —— 拉一次 /api/catalog（按 sing），建 item_id→chapter_index 映射。
-- 两者落盘缓存（<book_cache>/_shushan_v6.lua），一本书只查一次。
-- 返回 (sing, chapter_index, err)。
function ShuShan.v6_resolve_params(client, settings, cfg, book_id, item_id)
    local bid = tostring(book_id)
    local iid = tostring(item_id)
    local meta = v6_cache_load(settings, bid) or {}

    -- ① 书籍 sing
    local sing = H.trim(meta.sing or "")
    local tab = H.trim(meta.tab or cfg.tab or ShuShan.DEFAULT_TAB)
    local source = H.trim(meta.source or cfg.source or ShuShan.DEFAULT_SOURCE)
    if sing == "" then
        local name = ""
        local ok_bn, BookNames = pcall(require, "fanqie.book_names")
        if ok_bn and BookNames and BookNames.get then
            name = H.trim(BookNames.get(settings, bid) or "")
        end
        if name == "" then
            return nil, nil, "书山v6缺少书名（无法查 sing）：请先刷新书架校正书名"
        end
        local ok_s, rows = pcall(ShuShan.search, client, settings, name, { source = source, tab = tab })
        if not ok_s or type(rows) ~= "table" then
            return nil, nil, "书山v6按书名查 sing 失败"
        end
        for _, row in ipairs(rows) do
            if type(row) == "table" and tostring(row.book_id or "") == bid then
                sing = H.trim(row.sing or "")
                tab = H.trim(row.tab or tab)
                source = H.trim(row.source or source)
                break
            end
        end
        if sing == "" then
            return nil, nil, "书山v6搜索结果里没有这本书的 sing"
        end
        meta.sing, meta.tab, meta.source = sing, tab, source
        meta.index = meta.index or {}
        v6_cache_save(settings, bid, meta)
    end

    -- ② chapter_index：从缓存的 item_id→index 映射取
    local index_map = meta.index or {}
    local chindex = tonumber(index_map[iid])
    if not chindex then
        local v6h, herr = ShuShan.v6_headers(cfg)
        if not v6h then return nil, nil, herr end
        local body = client:json_encode({
            sing = sing, book_id = bid, source = source, tab = tab,
            title = H.trim(meta.title or ""),
        })
        local ok_c, obj = pcall(request_json_multi, client, settings, cfg, {
            path = "/api/catalog", method = "POST", body = body,
            headers = v6h, label = "书山v6目录",
        })
        if not ok_c or type(obj) ~= "table" or obj.code ~= 0 then
            local msg = ok_c and obj and obj.message or tostring(obj)
            return nil, nil, "书山v6目录失败: " .. H.truncate_utf8(tostring(msg), 80)
        end
        index_map = {}
        for _, ch in ipairs(obj.data or {}) do
            if type(ch) == "table" then
                local ci = tonumber(ch.chapter_index)
                local cid = tostring(ch.item_id or "")
                if ci and cid ~= "" then index_map[cid] = ci end
                -- 顺手记书名，供下次 search 用（虽然已有 sing 缓存）
                if ch.title and meta.title == nil then meta.title = tostring(ch.title) end
            end
        end
        chindex = tonumber(index_map[iid])
        if not chindex then
            return nil, nil, "书山v6目录里找不到该章节 item_id=" .. iid
        end
        meta.index = index_map
        v6_cache_save(settings, bid, meta)
    end
    return sing, chindex, nil
end

--  Settings accessors
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
    local active_ms = tonumber(cfg.active_ms or 0) or 0
    local active_fast = (active_ms <= 0) or (active_ms <= (ShuShan.ACTIVE_MS_OK or 1500))
    if active ~= "" and active_fast
        and normalize_base(cfg.active_base_src) == normalize_base(cfg.server_url) then
        add(active)
    end
    -- server_url 若就是内置节点，别提前插队：否则一旦首选失败，会先撞上
    -- 池子里排最后的慢节点（113.44），而不是次快的 v1。
    local url_in_pool = false
    local norm_url = normalize_base(cfg.server_url)
    if norm_url ~= "" then
        for _, u in ipairs(ShuShan.DEFAULT_NODES) do
            if normalize_base(u) == norm_url then url_in_pool = true break end
        end
    end
    if not url_in_pool then add(cfg.server_url) end
    for _, u in ipairs(ShuShan.DEFAULT_NODES) do add(u) end

    local now = os.time()
    -- 「慢节点」：最近一次成功但耗时超过 SLOW_MS 的节点，排到所有正常节点之后。
    -- 实测同一节点会在 0.4s~5s 之间横跳（113.44 那台尤其明显），光靠「失败才切」
    -- 永远切不走它 —— 它每次都成功，只是慢。
    local slow_base = normalize_base(cfg.slow_base or "")
    local slow_until = tonumber(cfg.slow_until or 0) or 0
    if slow_base == "" or slow_until < now then slow_base = nil end

    local hot, slow, cold = {}, {}, {}
    for _, u in ipairs(out) do
        local until_t = ShuShan._node_cooldown[u]
        if until_t and until_t > now then
            cold[#cold + 1] = u
        elseif slow_base and u == slow_base then
            slow[#slow + 1] = u
        else
            hot[#hot + 1] = u
        end
    end
    for _, u in ipairs(slow) do hot[#hot + 1] = u end
    for _, u in ipairs(cold) do hot[#hot + 1] = u end
    return hot
end

-- 节点健康反馈：成功 → 记忆为首选并解除冷却；传输层失败 → 进入冷却。
-- settings 非空时把"最近可用节点"持久化：章节抓取跑在 fork 子进程里，内存态
-- 不会回传父进程，不持久化的话主节点持续故障时每个新章节都要重撞一次超时。
function ShuShan.mark_node_ok(base, settings, elapsed_ms)
    if not base or base == "" then return end
    ShuShan._preferred_base = base
    ShuShan._node_cooldown[base] = nil
    if not settings then return end
    pcall(function()
        local cfg = settings:get_source("shushan") or {}
        local now = os.time()
        local is_slow = elapsed_ms and elapsed_ms > (ShuShan.SLOW_MS or 1500)
        local slow_base = H.trim(cfg.slow_base or "")
        local changed = false

        local new_ms = elapsed_ms and math.floor(elapsed_ms) or nil
        if H.trim(cfg.active_base or "") ~= base then
            cfg.active_base = base
            cfg.active_base_src = normalize_base(cfg.server_url)  -- 记住当时的用户配置
            cfg.active_base_at = tostring(now)
            changed = true
        end
        -- 记录该节点本次耗时：下次候选排序时用它判断「还配不配当首选」
        if new_ms and tonumber(cfg.active_ms or 0) ~= new_ms then
            cfg.active_ms = tostring(new_ms)
            changed = true
        end
        if is_slow then
            -- 成功但慢：降权 10 分钟，让候选顺序把别的节点排到前面
            if slow_base ~= base or (tonumber(cfg.slow_until or 0) or 0) < now then
                cfg.slow_base = base
                cfg.slow_until = tostring(now + (ShuShan.SLOW_TTL or 600))
                changed = true
            end
        elseif slow_base == base then
            -- 同一节点这次快了：立刻解除降权
            cfg.slow_base = nil
            cfg.slow_until = nil
            changed = true
        end
        if changed then settings:set_source("shushan", cfg) end
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

--  HTTP helpers (GET/POST JSON)

-- 多节点请求：只对传输层故障换节点 —— 无响应/超时/连接错误、5xx、2xx 但非 JSON；
-- 4xx（凭据/设备码/参数问题）不换，直接报错。成功节点记为后续首选并解除冷却。
request_json_multi = function(client, settings, cfg, opts)
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

        local t_req0 = now_ms()
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
                    ShuShan.mark_node_ok(base, settings, now_ms() - t_req0)
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
                ShuShan.mark_node_ok(base, settings, now_ms() - t_req0)
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

--  Login — POST /login with email+password, store api_key.
-- Returns (ok, err|api_key). err is nil on success.
function ShuShan.login(client, settings, override_email, override_password)
    local cfg = settings:get_source("shushan")
    local email = H.trim(override_email or cfg.email or "")
    local password = H.trim(override_password or cfg.password or "")
    if email == "" or password == "" then
        error("书山未填写邮箱/密码（请在书源管理→书山中配置）")
    end
    -- v6: POST /api/login {email,password} → data.token (= base64 api_key).
    -- token 解码回 api_key 原文落盘（v6 签名要用原文；旧路径仍存 base64 兼容）。
    local body = client:json_encode({ email = email, password = password })
    local obj = request_json_multi(client, settings, cfg, {
        path = "/api/login",
        method = "POST",
        body = body,
        headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = FanQie.MOBILE_UA,
        },
        label = "书山登录",
    })
    if not (obj.success or obj.code == 0 or obj.code == 200) then
        error(string.format("书山登录失败: %s", tostring(obj.message or obj.msg or obj.error or "")))
    end
    local token = H.trim((obj.data or {}).token or "")
    local api_key = ""
    if token ~= "" then
        api_key = H.trim(base64_decode(token))  -- v6: token = base64(api_key)
        if api_key == "" then api_key = token end
    end
    if api_key == "" then
        error("书山登录成功但未返回 token")
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

--  api_key resolution — login if missing/forced.
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

--  Content — POST /content for one chapter.
-- book_id/item_id come from the catalog. Returns {content=string, ...}.
function ShuShan.get_content(client, settings, book_id, item_id, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan")
    -- 只为「没登录时自动登录」的副作用；v6 的密钥从 cfg 现取（v6_headers）
    ShuShan.ensure_api_key(client, settings, false)
    local aid = ShuShan.resolve_android_id(cfg)
    local ok_aid, aid_norm = ShuShan.validate_android_id(aid)
    if not ok_aid then
        error("书山正文需要真实的 Android ID（16/32位hex）。请在书山设置中填写你已登录书山的那台安卓设备的 Android ID，插件不会自动生成（防封号）。")
    end
    local dev_type = ShuShan.resolve_device_type(cfg)
    local source = H.trim(opts.source or cfg.source or ShuShan.DEFAULT_SOURCE)
    -- 段评开关打开时，仅对番茄聚合源注入气泡（段落序号与番茄段评同源）。
    local is_fq_source = source:find("番茄", 1, true) ~= nil
    local cid = tonumber(opts.cid) or 0
    local version = H.trim(opts.version or cfg.content_version or ShuShan.CONTENT_VERSION)

    -- ── v6 正文（2026-11-19）：/api/content + x-novel-* + sing + chapter_index ──
    local v6h, v6err = ShuShan.v6_headers(cfg)
    if not v6h then error("书山正文: " .. tostring(v6err)) end
    local sing, chindex, perr = ShuShan.v6_resolve_params(client, settings, cfg, book_id, item_id)
    if not sing then error("书山正文: " .. tostring(perr)) end
    local body = client:json_encode({
        sing = sing,
        book_id = tostring(book_id),
        item_id = tostring(item_id),
        chapter_index = chindex,
        source = source,
        tab = H.trim(opts.tab or cfg.tab or ShuShan.DEFAULT_TAB),
        content_md5 = H.trim(opts.content_md5 or ""),
        version = version,
        devicetype = dev_type,
    })
    local obj = request_json_multi(client, settings, cfg, {
        path = "/api/content",
        method = "POST",
        body = body,
        headers = v6h,
        label = "书山正文",
    })

    -- 429 soft-block / device invalid: surface a clear message (not a hard ban).
    if obj.status == 429 or obj.code == 429 then
        error(string.format("书山正文被拒(设备码无效): %s 请确认 Android ID 是已登录书山的真实设备。", tostring((obj.data or {}).content or "")))
    end
    if obj.code and obj.code ~= 0 and obj.code ~= 200 then
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

    -- 实测服务端直接返回明文 UTF-8 正文，无需解密。
    -- 若未来返回 base64 密文，需在此接入 AES-CBC 解密（key/iv 见顶部常量）；
    -- 当前版本只做明文透传。解码函数 base64_decode 已内置供后续扩展。

    local para_reviews = {}
    -- 段评气泡：仅当段评开关打开且当前为番茄源时启用。
    -- 计数由 _fetch_fq_para_reviews 提供（知秋 paragraph_info / 官方 idea-list），
    -- 返回 [{paragraph_id, comment_count}]；paragraph_id 是 0-based 段落行号，
    -- 与 /api/content 明文正文的非空行一一对应。
    -- 点击查看正文走 ShuShan.get_para_review（书山 v6 /api/comment + JWT）。
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

--  番茄段评气泡计数（按章）—— 返回 [{paragraph_id, comment_count}, ...] 或 nil。
--  v6（2026-11-19）书山已没有「按章列段落计数」的接口（旧 /para 直接 404），
--  计数改走番茄自己的 App 段评统计：
--    ① 官方 idea/list（Comments.stats，按 blk p_idx 计数）—— 主通道；
--    ② 官方设备身份不可用时，退知秋 paragraph_info 兜底。
--  段评详情仍由 ShuShan.get_para_review（书山 v6 /api/comment + JWT）提供，
--  两边共用同一个 pid（para=pid 已实测能取回该段原文与评论）。
--
--  ⚡ 计数结果按章落盘缓存（`<book_cache>/<bid>/_pc_<item_id>.lua`）：
--  这一路请求约 370ms，而翻回老章、重开同一章都会重新进这里，缓存后为 0 请求。
--  有评论的章缓存 7 天；「本章无评论」只缓存 12 小时（新评论可能随时冒出来）。
ShuShan.PARA_COUNT_TTL = 7 * 24 * 3600
ShuShan.PARA_COUNT_TTL_EMPTY = 12 * 3600

local function para_count_path(settings, book_id, item_id)
    local ok_content, Content = pcall(require, "fanqie.content")
    if not ok_content or not Content or not Content.book_cache_dir then return nil end
    local dir = Content.book_cache_dir(settings, book_id)
    if not dir then return nil end
    return dir .. "/_pc_" .. tostring(item_id) .. ".lua", dir
end

-- 返回 (list, hit)：hit=true 表示命中缓存（list 可能是空表 =「本章确认无评论」）
local function para_count_load(settings, book_id, item_id)
    local p = para_count_path(settings, book_id, item_id)
    if not p or not H.file_exists(p) then return nil, false end
    local ok, obj = pcall(dofile, p)
    if not ok or type(obj) ~= "table" then return nil, false end
    local list = {}
    for _, item in ipairs(obj.list or {}) do
        local pid = tonumber(item[1])
        local n = tonumber(item[2])
        if pid and n and n > 0 then
            list[#list + 1] = { paragraph_id = pid, comment_count = n }
        end
    end
    local ttl = (#list == 0) and (ShuShan.PARA_COUNT_TTL_EMPTY or 43200)
        or (ShuShan.PARA_COUNT_TTL or 604800)
    local age = os.time() - (tonumber(obj.t) or 0)
    if age < 0 or age > ttl then return nil, false end
    return list, true
end

local function para_count_save(settings, book_id, item_id, list)
    local p, dir = para_count_path(settings, book_id, item_id)
    if not p then return end
    local parts = {}
    for _, it in ipairs(list or {}) do
        parts[#parts + 1] = string.format("{%d,%d}", it.paragraph_id, it.comment_count)
    end
    pcall(function()
        if dir and H.make_dir then H.make_dir(dir) end
        local f = io.open(p, "w")
        if not f then return end
        f:write("return {t=", tostring(os.time()), ",list={",
            table.concat(parts, ","), "}}\n")
        f:close()
    end)
end

function ShuShan._fetch_fq_para_reviews(client, settings, book_id, item_id)
    local bid, cid = tostring(book_id), tostring(item_id)

    local cached, hit = para_count_load(settings, bid, cid)
    if hit then
        log_debug("[FanQie] 书山段评气泡: 命中本地缓存 paras=" .. #cached
            .. " itemId=" .. cid)
        if #cached == 0 then return nil end
        return cached
    end

    -- ① 官方 App 段评统计（idea/list，番茄原生计数）
    local ok_c, Comments = pcall(require, "fanqie.reading.comments")
    if ok_c and type(Comments) == "table" and Comments.stats then
        local ok_s, stats = pcall(Comments.stats, client, settings, cid)
        if ok_s and type(stats) == "table" then
            local out = {}
            for pid, info in pairs(stats) do
                local n = tonumber(type(info) == "table" and info.count or 0) or 0
                local ipid = tonumber(pid)
                if ipid and n > 0 then
                    out[#out + 1] = { paragraph_id = ipid, comment_count = n }
                end
            end
            -- 官方答复是权威的：空结果也缓存，免得下次再白跑一次知秋。
            para_count_save(settings, bid, cid, out)
            if #out == 0 then
                log_debug("[FanQie] 书山段评气泡: 官方统计确认本章无评论 itemId=" .. cid)
                return nil
            end
            log_debug("[FanQie] 书山段评气泡: 计数走官方 idea/list, 有评论段落=" .. #out
                .. " itemId=" .. cid)
            return out
        end
    end

    -- ② 兜底：知秋 paragraph_info（0-based 非空行号，与书山正文逐行对齐）
    local ok_z, ZhiQiu = pcall(require, "fanqie.zhiqiu")
    if ok_z and type(ZhiQiu) == "table" then
        local ok, data = pcall(function()
            local zcfg = settings:get_source("zhiqiu") or {}
            local base = H.trim(zcfg.server_url or ZhiQiu.DEFAULT_BASE)
            local token = ZhiQiu.ensure_token(client, settings, false)
            local aid = ZhiQiu.resolve_android_id(settings)
            local d = ZhiQiu._fetch_paragraph_info(client, settings, bid, cid, token, aid, base)
            if type(d) ~= "table" then
                -- 本地 token 还在 3 天窗口内但服务端已失效时，_fetch 只回 nil；
                -- 这里强刷一次再试，避免整本书都没气泡。
                token = ZhiQiu.ensure_token(client, settings, true)
                aid = ZhiQiu.resolve_android_id(settings)
                d = ZhiQiu._fetch_paragraph_info(client, settings, bid, cid, token, aid, base)
            end
            return d
        end)
        if ok and type(data) == "table" then
            local out = {}
            for pid, info in pairs(data) do
                local n = tonumber(type(info) == "table" and info.count or 0) or 0
                local ipid = tonumber(pid)
                if ipid and n > 0 then
                    out[#out + 1] = { paragraph_id = ipid, comment_count = n }
                end
            end
            para_count_save(settings, bid, cid, out)
            if #out > 0 then
                warn("[FanQie] 书山段评气泡: 官方计数不可用，已退知秋 paragraph_info, itemId=" .. cid)
                return out
            end
        end
    end

    -- 两条通道都失败：不缓存（下次仍应重试）
    warn("[FanQie] 书山段评气泡: 计数通道全部失败（官方/知秋），本章不带气泡 itemId=" .. cid)
    return nil
end

-- 段落级段评 —— GET {host}/idea_comment?api=1&book_id&item_id&para&cursor
-- 返回番茄原生结构（与知秋 paragraph_list 同构），main.lua 的解析器可直接吃；
-- 唯一差异是段落原文在 data.para_src_content，这里注入补齐。
-- cursor 是偏移量（0/20/40…），不是服务端游标。
-- 段评详情内存缓存（进程内，30 分钟 / 最多 40 条）
ShuShan.PR_CACHE_TTL = 30 * 60
ShuShan.PR_CACHE_MAX = 40

function ShuShan.get_para_review(client, settings, book_id, item_id, para_id, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan") or {}
    ShuShan.ensure_api_key(client, settings, false)

    local COUNT    = tonumber(opts.count) or 20
    local PAGE_MAX = tonumber(opts.page_max) or 1
    local sort     = tostring(opts.sort or "1")

    -- 段评详情内存缓存：同一段反复点开（关掉再点）不必再打网络。
    -- 只存活在当前进程，上限 40 条、30 分钟过期，评论增删由过期兜底。
    -- key 必须带上 count / page_max：同一段「首屏 20 条」与「一次拉两页 40 条」
    -- 结果不同，只按 cursor 做键会互相串用。
    local cache_key = table.concat({ tostring(book_id), tostring(item_id),
        tostring(para_id), tostring(tonumber(opts.cursor) or 0),
        tostring(COUNT), tostring(PAGE_MAX), sort }, ":")
    local cache = ShuShan._pr_cache
    if not cache then
        cache = {}
        ShuShan._pr_cache = cache
    end
    local ce = cache[cache_key]
    if ce and (os.time() - (ce.t or 0)) < (ShuShan.PR_CACHE_TTL or 1800) then
        log_debug("[FanQie] 书山段评: 命中内存缓存 para=" .. tostring(para_id)
            .. " cursor=" .. tostring(opts.cursor or 0))
        return ce.res
    end

    -- v6 段评走 SPA JWT（不是 api_key）。JWT 缓存 6 天，过期才重算 PoW。
    local jwt = ShuShan.ensure_jwt(client, settings, cfg, false)
    if not jwt then error("书山段评无法获取 JWT（请检查邮箱密码；失败将降级到知秋）") end
    local h = {
        ["User-Agent"] = FanQie.MOBILE_UA,
        ["Accept"] = "application/json",
        ["Authorization"] = "Bearer " .. jwt,
    }
    local source = H.trim(opts.source or cfg.source or ShuShan.DEFAULT_SOURCE)

    -- 图片提取：一级评论与二级回复同源（segments[type=image] 优先，images 兜底）。
    -- 单独抽出来是为了两处共用且只创建一次闭包（原先二级那份嵌在 map_item 里，
    -- 每条段评解析都会重建一次）。旧代码二级只映射 text/user/time/likes，
    -- 图片字段整个丢弃 → 服务端有图却只剩正文里的 `[图片]` 字样（实测 2026-11-23）。
    local function extract_images(src)
        local out = {}
        for _, seg in ipairs(src.segments or {}) do
            if type(seg) == "table" and seg.type == "image"
                and type(seg.url) == "string" and seg.url ~= "" then
                out[#out + 1] = { url = seg.url }
            end
        end
        if #out == 0 then
            for _, im in ipairs(src.images or {}) do
                if type(im) == "table" and type(im.url) == "string" and im.url ~= "" then
                    out[#out + 1] = { url = im.url }
                end
            end
        end
        return out
    end

    -- v6 items[] → 插件 data_list[]（main.lua 的 _parseParaReviewResult 可直接吃）
    local function map_item(it)
        if type(it) ~= "table" then return nil end
        local images = extract_images(it)
        local replies = {}
        for _, r in ipairs(it.reply_list or {}) do
            if type(r) == "table" then
                replies[#replies + 1] = {
                    Common = {
                        content = {
                            text = tostring(r.content or ""),
                            image_data_list = extract_images(r),
                        },
                        user_info = { user_name = tostring(r.user_name or "匿名") },
                        create_timestamp = r.time,
                    },
                    stat = { digg_count = tonumber(r.likes) or 0 },
                }
            end
        end
        return {
            comment = {
                comment_id = tostring(it.id or ""),
                common = {
                    content = {
                        text = tostring(it.content or ""),
                        image_data_list = images,
                    },
                    user_info = { user_name = tostring(it.user_name or "匿名") },
                    create_timestamp = it.time,
                },
                stat = {
                    digg_count = tonumber(it.likes) or 0,
                    reply_count = tonumber(it.replies) or 0,
                },
                expand = { para_src_content = tostring(it.para_text or it.quote or "") },
            },
            replies = replies,
        }
    end

    local merged = {}
    local para_src = ""
    local offset = tonumber(opts.cursor) or 0
    local next_offset = offset
    local last_total, last_has_more, last_page_full = nil, nil, false
    local page = 0
    while page < PAGE_MAX do
        page = page + 1
        local query = "source=" .. H.url_encode(source)
            .. "&tab=paras&book_id=" .. H.url_encode(tostring(book_id))
            .. "&item_id=" .. H.url_encode(tostring(item_id))
            .. "&para=" .. H.url_encode(tostring(para_id))
            .. "&offset=" .. tostring(offset) .. "&count=" .. tostring(COUNT)
            .. "&sort=" .. H.url_encode(sort)
        local obj = request_json_multi(client, settings, cfg, {
            path = "/api/comment?" .. query, method = "GET", headers = h,
            label = "书山段评", timeout = opts.timeout or 15,
        })
        if obj.code and obj.code ~= 0 then
            error(string.format("书山段评错误: code=%s %s",
                tostring(obj.code), tostring(obj.message or obj.msg or "")))
        end
        local data = obj.data or {}
        if para_src == "" then
            para_src = tostring(data.quote or "")
            if para_src == "" and type(data.book) == "table" then para_src = "" end
        end
        local items = data.items
        if type(items) ~= "table" or #items == 0 then
            last_page_full = false
            break
        end
        for _, it in ipairs(items) do
            local mapped = map_item(it)
            if mapped then merged[#merged + 1] = mapped end
        end
        last_total = tonumber(data.total) or last_total
        last_has_more = (data.has_more == true)
        last_page_full = (#items >= COUNT)
        -- 下一页 offset：服务端 next 优先（实测是数字；万一是 URL 就按本页条数累加）
        next_offset = offset + #items
        local next_off = tonumber(data.next)
        if next_off then next_offset = next_off end
        if last_has_more == false or not last_page_full then break end
        offset = next_offset
        next_offset = offset
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

    -- has_more 判定：服务端明确给值优先；否则看「本页是否拉满 / 已拉条数是否小于 total」。
    -- ⚠️ 旧代码这里引用了从未赋值的 last_page_full + 未定义的 cursor，导致
    -- cursor 恒为 0、has_more 恒为 nil ——「继续加载」点了永远拿到第一页（全重复）。
    local has_more_out = false
    if last_has_more ~= nil then
        has_more_out = (last_has_more == true)
    end
    if not has_more_out and last_total then
        -- 注意用「已拉到的绝对位置」比 total，别用本页条数：
        -- 续拉时 merged 只有这一页，拿 #merged < total 会永远为真。
        has_more_out = (next_offset < last_total)
    end
    if not has_more_out and not last_total and last_page_full then
        has_more_out = true
    end

    local result = {
        code = 0,
        data = {
            data_list = merged,
            para_src_content = para_src,
            common_list_info = {
                total = last_total or #merged,
                has_more = has_more_out,
                cursor = next_offset,
            },
        },
    }

    -- 写缓存（超过上限先淘汰最旧的一条，LRU 简化版：按写入时间）
    cache[cache_key] = { t = os.time(), res = result }
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    if n > (ShuShan.PR_CACHE_MAX or 40) then
        local oldest_key, oldest_t = nil, nil
        for k, v in pairs(cache) do
            local t = (type(v) == "table" and v.t) or 0
            if not oldest_t or t < oldest_t then oldest_key, oldest_t = k, t end
        end
        if oldest_key then cache[oldest_key] = nil end
    end

    return result
end

--  Catalog — POST /catalog for one book's chapter list.
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

    -- v6 目录需要 sing：优先从 opts 传，否则按书名查并缓存。
    local v6h, herr = ShuShan.v6_headers(cfg)
    if not v6h then error("书山目录: " .. tostring(herr)) end
    local bookid_str = tostring(bookid)
    local meta = v6_cache_load(settings, bookid_str) or {}
    local sing = H.trim(opts.sing or meta.sing or "")
    if sing == "" then
        local name2 = H.trim(opts.name or name or "")
        if name2 == "" then error("书山v6目录缺少 sing 且无书名") end
        local ok_s, rows = pcall(ShuShan.search, client, settings, name2, { source = source, tab = tab })
        if ok_s and type(rows) == "table" then
            for _, row in ipairs(rows) do
                if type(row) == "table" and (tostring(row.book_id or "") == bookid_str or name2 == H.trim(row.title or "")) then
                    sing = H.trim(row.sing or "")
                    if sing ~= "" then
                        meta.sing, meta.tab, meta.source = sing, H.trim(row.tab or tab), H.trim(row.source or source)
                        v6_cache_save(settings, bookid_str, meta)
                        break
                    end
                end
            end
        end
        if sing == "" then error("书山v6目录查 sing 失败") end
    end
    local body = client:json_encode({
        sing = sing,
        book_id = bookid_str,
        source = source,
        tab = tab,
        title = name,
    })
    local obj = request_json_multi(client, settings, cfg, {
        path = "/api/catalog",
        method = "POST",
        body = body,
        headers = v6h,
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

--  Search — GET /search (used to locate a book then fetch its catalog).
-- source can be "番茄小说", "番茄小说-VIP" etc. Returns the response data list.
function ShuShan.search(client, settings, keyword, opts)
    opts = opts or {}
    local cfg = settings:get_source("shushan")
    ShuShan.ensure_api_key(client, settings, false)
    local source = H.trim(opts.source or cfg.source or ShuShan.DEFAULT_SOURCE)
    local page = tonumber(opts.page) or 1
    local tab = H.trim(opts.tab or cfg.tab or ShuShan.DEFAULT_TAB)
    local v6h, herr = ShuShan.v6_headers(cfg)
    if not v6h then error("书山搜索: " .. tostring(herr)) end
    -- v6: GET /api/search?keyword=&page=&tab=[&source=]
    local path = "/api/search?keyword=" .. H.url_encode(keyword)
        .. "&page=" .. tostring(page) .. "&tab=" .. H.url_encode(tab)
        .. "&source=" .. H.url_encode(source)
    local obj = request_json_multi(client, settings, cfg, {
        path = path,
        method = "GET",
        headers = v6h,
        label = "书山搜索",
    })
    local data = obj.data or obj
    return (type(data) == "table" and data.list) or data
end

-- 按 book_id 精确认领一条搜索结果。
--
-- 为什么要「认领」而不是直接取第一条：搜索是**按书名**做的，而书名本身
-- 可能已经过时（番茄改名后 Web 名还是旧的）。`book_url` 是 base64 编码的
-- 番茄详情地址，解码后里面带 `book_id=<id>`，用它做精确匹配就不会认错书。
--
-- ⚠️ 书山搜索索引里的封面会滞后：2026-11-07 实测 28 本，25 本与知秋一致，
--    2 本仍是改名前的旧图、1 本是第三版。所以它只做知秋之后的兜底。
--
-- @return table|nil { name, cover } — cover 是 origin 原图地址
function ShuShan.find_book(client, settings, book_id, keyword, opts)
    if book_id == nil or tostring(book_id) == "" then return nil end
    local kw = H.trim(keyword or "")
    if kw == "" then return nil end

    local ok, rows = pcall(ShuShan.search, client, settings, kw, opts)
    if not ok or type(rows) ~= "table" then return nil end

    local target = tostring(book_id)
    for _, row in ipairs(rows) do
        if type(row) == "table" then
            -- v6 搜索结果直接带 book_id；旧版需 base64 解 book_url 取 book_id=。
            local bid = tostring(row.book_id or "")
            local matched = (bid == target)
            if not matched then
                local raw = ShuShan.base64_decode(tostring(row.book_url or ""))
                matched = (type(raw) == "string" and raw:find("book_id=" .. target, 1, true) ~= nil)
            end
            if matched then
                return {
                    name = H.trim(row.title or ""),
                    cover = H.trim(row.cover or ""),
                }
            end
        end
    end
    return nil
end

-- 节点测速（连通性 + 延迟）
-- ⚠️ /detection 返回 200 + 纯文本「书山聚合」，不是 JSON：必须按 HTTP 2xx 判存活，
--    走严格 JSON 判定会把每个节点都判坏，出现「能看书却检测失败」。
-- 探针不带任何凭据（不把 api_key 广播给池里每个节点）。
-- 返回 { base, ms, ok, code, note, retryable }，retryable 表示属于该换节点类故障。
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
    log_info(string.format("[FanQie] 书山测速完成：选中 %s（%dms），共测 %d 个节点",
        tostring(best), best_ms, #results))
    return best, results
end

-- 服务器连通性检查（多节点，任一可达即通过）。
-- v6 的 /api/site/public 返回 JSON（200），无需鉴权；2xx 即算连通。
function ShuShan.query_status(client, settings)
    local cfg = settings:get_source("shushan")
    local obj = request_json_multi(client, settings, cfg, {
        path = ShuShan.DETECT_PATH,
        method = "GET",
        label = "书山状态",
        accept_nonjson = true,   -- 老节点仍可能回纯文本，2xx 即视为可达
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
