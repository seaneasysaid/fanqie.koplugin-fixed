local lfs = require("libs/libkoreader-lfs")
local util = require("util")
local DataStorage = require("datastorage")

local M = {}

M.is_str = function(s)
    return type(s) == "string"
end

M.is_num = function(n)
    return type(n) == "number"
end

M.is_tbl = function(t)
    return type(t) == "table"
end

M.is_func = function(f)
    return type(f) == "function"
end

M.is_boolean = function(b)
    return type(b) == "boolean"
end

M.if_nil = function(a, b)
    if a == nil then
        return b
    end
    return a
end

M.trim = function(s)
    if not s then return "" end
    return s:match("^%s*(.-)%s*$") or ""
end

-- Unicode 感知的「行首空白剥离」。
-- Lua 的 %s 只认 ASCII 空白（空格/TAB/CR/LF/VT/FF），**不匹配**全角空格
-- U+3000、不换行空格 U+00A0 等。中文小说源常在每段行首插 2 个 U+3000 做
-- 「首行缩进」，而正文渲染本身已有 CSS `text-indent: 2em`，两者叠加会变成
-- 4 字符缩进（知秋源即如此；书山源正文无此前置空白，故显示 2 字符）。
-- 本函数逐行剥离行首的各类 Unicode 空白，不改动行尾、不改动换行结构
-- （行数严格不变，段评 pid 对齐不受影响）。
M.BLANK_PREFIXES = {
    "\9", "\11", "\12", "\13", "\32",                                     -- \t \v \f \r 空格
    "\194\160",                                                            -- U+00A0 不换行空格
    "\226\128\128", "\226\128\129", "\226\128\130", "\226\128\131",        -- U+2000-2003
    "\226\128\132", "\226\128\133", "\226\128\134", "\226\128\135",        -- U+2004-2007
    "\226\128\136", "\226\128\137", "\226\128\138",                        -- U+2008-200A
    "\226\128\175",                                                        -- U+202F 窄不换行空格
    "\226\129\159",                                                        -- U+205F 中等数学空格
    "\227\128\128",                                                        -- U+3000 全角空格
}

M.strip_leading_blank = function(s)
    if type(s) ~= "string" or s == "" then return s end
    -- 快速路径：正文里一个可疑字符都没有时直接返回，不做逐行扫描
    local prefixes = M.BLANK_PREFIXES
    local has = false
    for _, p in ipairs(prefixes) do
        if s:find(p, 1, true) then has = true break end
    end
    if not has then return s end
    -- [^\n]* 逐行匹配（不吞换行符），保证行数与换行分布逐字节不变
    return (s:gsub("[^\n]*", function(line)
        if line == "" then return line end
        local i = 1
        while true do
            local matched = false
            for _, p in ipairs(prefixes) do
                if line:sub(i, i + #p - 1) == p then
                    i = i + #p
                    matched = true
                    break
                end
            end
            if not matched then break end
        end
        if i == 1 then return line end
        return line:sub(i)
    end))
end

-- UTF-8 安全的字节截断：用于日志/错误信息，避免把多字节汉字切成半个
-- （残缺字节写进日志会显示乱码，也让后续按 UTF-8 解析的工具报错）。
M.truncate_utf8 = function(s, n)
    s = tostring(s or "")
    if n <= 0 then return "" end
    if #s <= n then return s end
    local t = s:sub(1, n)
    -- 1) 回退掉结尾的 UTF-8 续字节（0x80~0xBF）
    while #t > 0 do
        local b = t:byte(#t)
        if b >= 0x80 and b < 0xC0 then
            t = t:sub(1, #t - 1)
        else
            break
        end
    end
    -- 2) 若结尾停在多字节字符的首字节上，说明该字符不完整，一并去掉
    if #t > 0 then
        local b = t:byte(#t)
        if b >= 0xC0 then
            t = t:sub(1, #t - 1)
        end
    end
    return t
end

M.join_path = function(...)
    local args = {...}
    local path = ""
    for _, p in ipairs(args) do
        if p then
            path = path .. "/" .. p
        end
    end
    return path:gsub("/+", "/")
end

M.get_cache_path = function(book_id)
    local base_dir = DataStorage:getFullDataDir() .. "/fanqie"
    return M.join_path(base_dir, book_id)
end

M.make_dir = function(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    util.makePath(path)
    return lfs.attributes(path, "mode") == "directory"
end

M.file_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "file"
end

M.dir_exists = function(path)
    if not M.is_str(path) then return false end
    return lfs.attributes(path, "mode") == "directory"
end

M.delete_file = function(path)
    if M.file_exists(path) then
        return os.remove(path)
    end
    return true
end

M.write_file = function(path, data)
    local dir = path:match("^(.*)/[^/]+$")
    if dir then
        M.make_dir(dir)
    end
    local file, err = io.open(path, "wb")
    if not file then
        error(err)
    end
    file:write(data)
    file:close()
end

M.delete_dir = function(path)
    if not M.dir_exists(path) then return true end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = M.join_path(path, entry)
            local mode = lfs.attributes(full_path, "mode")
            if mode == "directory" then
                M.delete_dir(full_path)
            else
                os.remove(full_path)
            end
        end
    end
    return lfs.rmdir(path)
end

M.table_size = function(t)
    if not M.is_tbl(t) then return 0 end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

M.split = function(str, sep)
    local result = {}
    local pattern = string.format("([^%s]+)", sep)
    for part in string.gmatch(str, pattern) do
        table.insert(result, part)
    end
    return result
end

M.url_encode = function(str)
    if not str then return "" end
    str = tostring(str)
    return str:gsub("[^a-zA-Z0-9%-_.~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

return M