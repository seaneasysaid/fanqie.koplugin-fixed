-- 异步子进程：阻塞的网络/IO 放子进程，UI 线程轮询管道，界面不冻结。
-- 参考 frontend/ui/trapper.lua 的 runInSubProcess + pipe，但纯回调驱动（on_done）。
-- 管道协议：成功 {"ok":true,"result":…}；失败 {"ok":false,"err":"…"}。
-- ⚠️ 子进程只回传**第一个**返回值：失败原因必须在子进程内 error(msg, 0) 抛出。
-- 无 fork 时（Windows 测试 / 旧环境）降级为延后同步执行，仍会短暂阻塞。

local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
local ok_UIManager, UIManager = pcall(require, "ui/uimanager")
local ok_Log, Log = pcall(require, "fanqie.logger")

-- ffi/util.lua 没有声明 close（Kindle 实测 `missing declaration for symbol
-- 'close'`）。超时清理需要直接关掉管道读端，这里补一次声明；重复声明由
-- pcall 兜住，不影响其它模块。
local ok_ffi, ffi = pcall(require, "ffi")
if ok_ffi and ffi then
    pcall(ffi.cdef, "int close(int fd);")
end

local ok_json, json = pcall(require, "json")
if not ok_json then
    ok_json, json = pcall(require, "rapidjson")
end

local Async = {}

--- 当前运行环境是否支持子进程（POSIX fork）。
function Async.is_available()
    return ok_ffiutil
        and ffiutil
        and type(ffiutil.runInSubProcess) == "function"
        and type(ffiutil.writeToFD) == "function"
        and type(ffiutil.readAllFromFD) == "function"
        and type(ffiutil.getNonBlockingReadSize) == "function"
        and type(ffiutil.isSubProcessDone) == "function"
end

-- Lua 原生序列化：把子进程结果序列化为可 loadstring 的 Lua 表达式。
-- 之前用 JSON，但 rapidjson/dkjson 对纯字符串 key 的 hash table 编码时会
-- 丢成空 {}，导致 result.jar 跨子进程后变空（登录成功但 cookie 全丢）。
-- Lua 序列化能完整保留 table 结构，且 string.format("%q") 正确转义所有特殊字符。
local function lua_serialize(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "nil" then
        return "nil"
    elseif t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            local ks
            if type(k) == "string" then
                ks = string.format("[%q]", k)
            elseif type(k) == "number" then
                ks = "[" .. tostring(k) .. "]"
            else
                ks = nil  -- 跳过非 string/number key（function/userdata 等不支持）
            end
            if ks then
                table.insert(parts, ks .. "=" .. lua_serialize(val))
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    else
        return "nil"
    end
end

local function lua_deserialize(s)
    if not s or s == "" then return nil end
    local load_func = loadstring or load
    if not load_func then return nil end
    local fn = load_func("return " .. s)
    if not fn then return nil end
    local ok, v = pcall(fn)
    if not ok then return nil end
    return v
end

-- 把任意错误信息清理成单行字符串，避免 JSON/协议被换行污染。
local function sanitize_err(err)
    local s = tostring(err or "unknown error")
    s = s:gsub("[%c]", " ")
    if #s > 1000 then s = s:sub(1, 1000) .. "..." end
    return s
end

--- 延后同步执行（降级路径）：在 UI 线程跑 work_func，立即回调。
local function run_sync(work_func, on_done, delay)
    if not ok_UIManager or not UIManager then
        -- 连 UIManager 都没有，直接同步执行
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
        return nil
    end
    UIManager:scheduleIn(delay or 0, function()
        local ok, result = pcall(work_func)
        if on_done then
            if ok then on_done(true, result, nil)
            else on_done(false, nil, sanitize_err(result)) end
        end
    end)
    return nil
end

--- 在子进程中执行 work_func（无参闭包，返回可 JSON 序列化值或抛错），
--- 完成后在 UI 线程回调 on_done(ok, result, err)。
--- @param work_func function  子进程内执行的工作函数（闭包捕获的状态在 fork 时被继承）
--- @param on_done    function|nil  回调 function(ok, result, err)，在 UI 线程运行
--- @param opts       table|nil  { delay=0, poll_interval=0.125, timeout=60 }
--- @return handle|nil  返回句柄 { cancel=fn, pid=... }；降级同步时返回 nil
function Async.run(work_func, on_done, opts)
    opts = opts or {}
    local poll_interval = opts.poll_interval or 0.125
    local timeout = opts.timeout or 60
    local delay = opts.delay or 0

    if not Async.is_available() then
        if ok_Log then Log.debug("[async] 子进程不可用，降级同步执行") end
        return run_sync(work_func, on_done, delay)
    end

    -- 子进程入口：执行 work_func，把结果以 JSON 写回管道并关闭 fd。
    local function child_entry(pid, child_write_fd)
        -- fork 后的子进程会继承父进程的 fd（含 HTTP Inspector 的监听 socket，
        -- 如 8082）。若不关闭，子进程存活期间会占住该端口，导致父进程在
        -- standby/resume、章节切换时无法重新 bind，报 "address already in use"。
        -- 番茄 async 子进程只需 stdio + child_write_fd 通信，其余继承 fd 一律关闭。
        pcall(function()
            local ffi_c, C_c
            local ok_ffi_c, ffi_c_mod = pcall(require, "ffi")
            if ok_ffi_c and ffi_c_mod then
                ffi_c = ffi_c_mod
                C_c = ffi_c.C
            end
            if C_c and C_c.close then
                local keep = { [0] = true, [1] = true, [2] = true }
                if child_write_fd then keep[child_write_fd] = true end
                -- 遍历 3..最大可能 fd；对未打开 fd 的 close 是安全的 no-op (EBADF)。
                local MAX_FD = 1024
                for fd = 3, MAX_FD do
                    if not keep[fd] then
                        pcall(C_c.close, fd)
                    end
                end
            end
        end)
        local ok, result = pcall(work_func)
        local payload
        if ok then
            local enc = lua_serialize({ ok = true, result = result })
            -- 序列化失败时退化为纯成功标记
            payload = enc or '{ok=true,result=nil}'
        else
            local enc = lua_serialize({ ok = false, err = sanitize_err(result) })
            payload = enc or '{ok=false,err="encode failed"}'
        end
        if ok_Log then
            Log.debug("[async] child payload len=" .. tostring(#payload) .. " 前120=" .. payload:sub(1, 120))
        end
        -- writeToFD 第三参 true 表示写完关闭 fd，父进程 readAllFromFD 据此收到 EOF
        pcall(ffiutil.writeToFD, child_write_fd, payload, true)
    end

    local pid, parent_read_fd = ffiutil.runInSubProcess(child_entry, true) -- with_pipe = true
    if not pid then
        if ok_Log then Log.warn("[async] runInSubProcess 启动失败，降级同步") end
        return run_sync(work_func, on_done, delay)
    end

    local handle = { pid = pid, fd = parent_read_fd, _cancelled = false }
    local start_clock = os.time()

    -- on_done 只允许到达一次：poll 异常收口与正常收口可能同时命中
    -- （例如 on_done 自己抛错，异常又被外层 pcall 捕获）。
    local done_called = false
    local function call_done(ok, val, err)
        if done_called then return end
        done_called = true
        if on_done then on_done(ok, val, err) end
    end

    -- 终止并清理子进程（避免僵尸），fd 也一并关闭。
    -- ⚠️ 绝不能在 UI 线程调用 ffiutil.readAllFromFD：它是**阻塞读**，会一直
    -- 等到「所有」持有管道写端的进程关闭。子进程卡在网络超时时写端不会关；
    -- 即便先 SIGKILL，它 fork 出的孙进程仍可能继承写端 —— 2026-11-10 在
    -- Kindle 真机实测：先 KILL 再 read 依旧挂死 20s+。旧实现更糟：先 read
    -- 后 KILL，terminateSubProcess 永远执行不到，整个 KOReader 冻结。
    --
    -- 超时 / 取消 / poll 异常时结果一律丢弃，没必要读管道内容：直接 close
    -- 读端 fd 即可（真机实测 0 秒返回），孙进程写管道会收到 EPIPE 自行退出。
    local function cleanup(pid_ref, fd_ref)
        -- 判断本身也要兜住：异常时按「进程还活着」处理，宁可多 kill 一次。
        local ok_done, done = pcall(ffiutil.isSubProcessDone, pid_ref)
        local killed = false
        if pid_ref and (not ok_done or not done) then
            pcall(ffiutil.terminateSubProcess, pid_ref)  -- SIGKILL 整个进程组
            killed = true
        end
        if fd_ref then
            -- 连符号访问都要 pcall：未声明时 `ffi.C.close` 求值就会抛错
            local closed = false
            local ok_sym, close_fn = pcall(function()
                return ok_ffi and ffi and ffi.C and ffi.C.close or nil
            end)
            if ok_sym and close_fn ~= nil then
                closed = pcall(function() close_fn(fd_ref) end) and true or false
            end
            if not closed then
                -- 拿不到 close（极端环境）：也绝不阻塞 UI，只把 fd 交给后台
                -- 在确认进程退出后再收；收不掉也只是泄漏一个 fd，好过冻死。
                local tries = 0
                local function collect()
                    local ok_call, is_done = pcall(ffiutil.isSubProcessDone, pid_ref)
                    tries = tries + 1
                    if (not ok_call) or is_done or tries >= 40 then
                        pcall(ffiutil.readAllFromFD, fd_ref)
                        return
                    end
                    if ok_UIManager and UIManager then
                        UIManager:scheduleIn(0.1, collect)
                    end
                end
                if ok_UIManager and UIManager then
                    UIManager:scheduleIn(0.1, collect)
                end
            end
        end
        -- SIGKILL 到 waitpid 回收之间有延迟，后台补一次 reap 收僵尸，
        -- 全程不占用 UI 线程。
        if killed and pid_ref and ok_UIManager and UIManager then
            local tries = 0
            local function reap()
                local ok_call, is_done = pcall(ffiutil.isSubProcessDone, pid_ref)
                if (not ok_call) or is_done then return end
                tries = tries + 1
                if tries < 20 then UIManager:scheduleIn(0.2, reap) end
            end
            UIManager:scheduleIn(0.1, reap)
        end
    end

    handle.cancel = function()
        handle._cancelled = true
        cleanup(handle.pid, handle.fd)
        handle.fd = nil
        -- 取消后 poll 直接 return，on_done 不会到达；忙碌框 / 门控位由调用方
        -- 通过 on_cancel 收口（关 busy、清 shelf_refreshing）。没提供就不调。
        if done_called then return end
        done_called = true
        if opts.on_cancel then pcall(opts.on_cancel) end
    end

    -- 轮询函数：每次由 UIManager:scheduleIn 在 UI 线程唤醒。
    -- 🔴 整体 pcall：poll 由 scheduleIn 驱动，函数体内一次未捕获异常就会
    -- 断掉调度链 ⇒ on_done 永不到达 ⇒ busy 永久卡。这是唯一还活着的
    -- 「卡 loading」路径，必须在这里兜住。
    local function poll()
        if handle._cancelled then return end
        local ok_poll, err_poll = pcall(function()

            -- 超时检测
            if os.difftime(os.time(), start_clock) > timeout then
                if ok_Log then Log.warn("[async] 子进程超时", timeout, "s，终止") end
                cleanup(handle.pid, handle.fd)
                handle.fd = nil
                call_done(false, nil, "async timeout")
                return
            end

            local subprocess_done = ffiutil.isSubProcessDone(pid)
            local stuff_to_read = parent_read_fd
                and ffiutil.getNonBlockingReadSize(parent_read_fd) ~= 0

            if subprocess_done or stuff_to_read then
                local result_ok, result_val, result_err
                if stuff_to_read then
                    local ret_str = ffiutil.readAllFromFD(parent_read_fd)
                    handle.fd = nil
                    if ok_Log then
                        Log.debug("[async] parent ret_str len=" .. tostring(ret_str and #ret_str or -1) .. " 前120=" .. tostring(ret_str):sub(1, 120))
                    end
                    local decoded = ret_str and lua_deserialize(ret_str)
                    if type(decoded) == "table" then
                        if decoded.ok then
                            result_ok, result_val = true, decoded.result
                        else
                            result_ok, result_err = false, decoded.err or "unknown error"
                        end
                    else
                        -- Lua 反序列化失败：若子进程已正常退出，视作成功无返回值
                        if subprocess_done then
                            result_ok, result_val = true, nil
                        else
                            result_ok, result_err = false, "malformed subprocess output"
                        end
                    end
                else
                    -- 子进程退出但无任何输出（崩溃 / os.exit）
                    if parent_read_fd then
                        pcall(ffiutil.readAllFromFD, parent_read_fd)
                        handle.fd = nil
                    end
                    result_ok, result_err = false, "subprocess exited without output"
                end

                -- 若读取时子进程尚未退出（数据先于退出到达），安排稍后回收
                if not subprocess_done then
                    local collect_pid = pid
                    local collect
                    collect = function()
                        if ffiutil.isSubProcessDone(collect_pid) then
                            -- 已回收
                        else
                            UIManager:scheduleIn(1, collect)
                        end
                    end
                    UIManager:scheduleIn(1, collect)
                end

                if not handle._cancelled then
                    if result_ok then
                        call_done(true, result_val, nil)
                    else
                        call_done(false, nil, result_err)
                    end
                end
            else
                -- 未完成，继续轮询
                UIManager:scheduleIn(poll_interval, poll)
            end
        end)
        if not ok_poll then
            -- poll 链断裂：按失败收口，保证调用方能 closeBusy / 清门控位
            if ok_Log then Log.warn("[async] poll 异常，按失败收口:", sanitize_err(err_poll)) end
            cleanup(handle.pid, handle.fd)
            handle.fd = nil
            call_done(false, nil, "async poll error: " .. sanitize_err(err_poll))
        end
    end

    UIManager:scheduleIn(delay, poll)
    return handle
end

return Async
