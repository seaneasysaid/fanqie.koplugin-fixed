local H = require("fanqie.helper")

local FanQie = {}

FanQie.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
FanQie.MOBILE_UA = "Mozilla/5.0 (Linux; Android 10; Pixel 3) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
FanQie.BASE_URL = "https://fanqienovel.com"

-- 无签名的手机端封面 CDN。接口返回的 thumb_url 走的是带签名的 CDN
-- （p9-novel-sign.*，x-expires 只签到次日），过期后回源必然 403。
-- 收敛到这个域名后地址幂等、长期有效。
FanQie.MOBILE_COVER_CDN = "https://p6-novel.byteimg.com"

-- 封面请求宽度。书架两列时卡片约 470px（Kindle Voyage / Kobo Clara 同级屏），
-- 取 480 正好 1:1 贴进卡片，不再靠放大糊图；原图 600 宽，未超采样。
-- ⚠️ 改这个值必须同步 cover_cache.COVER_WIDTH，否则旧尺寸缓存不会失效。
FanQie.COVER_WIDTH = 480

--- 把番茄封面地址收敛为**无签名**的手机端 CDN 地址。
-- 输入可以是带签名的 thumb_url、thumb_uri（相对路径）或已经是目标形态的地址；
-- 幂等：已是无签名地址时原样返回（只换尺寸后缀）。
-- 返回 nil 表示没有可用地址（调用方应跳过封面，而不是写空串）。
function FanQie.mobile_cover(thumb)
    if type(thumb) ~= "string" or thumb == "" then
        return nil
    end
    -- 取出路径部分：novel-pic/... 或 novel-static/...
    local path = thumb:match("(novel%-pic/[^~%?#]+)")
        or thumb:match("(novel%-static/[^~%?#]+)")
    if not path then
        -- 另一种真实形态：主机下直接是裸哈希，例如
        --   https://p9-novel-sign.byteimg.com/a0500010…~tplv-resize:225:300.image?x-expires=…
        -- 这类没有 novel-pic/ 前缀。实测原签名主机去掉查询仍是 403，
        -- 但换成 p6-novel + ~tplv-shrink:<w>:0.image 可取（200 / JPEG），
        -- 所以这里统一按「主机之后的路径 + 固定尺寸后缀」重拼。
        -- 只有番茄自己的图片 CDN 才能挪到 p6-novel，别把外部域名的图改坏
        local host, host_path = thumb:match("^https?://([^/]+)/([^?#]+)")
        if not (host and host:match("byteimg%.com$")) then
            if thumb:match("^https?://") then
                return thumb
            end
            return FanQie.MOBILE_COVER_CDN .. "/"
                .. thumb:gsub("^/", ""):gsub("~tplv[^/]*$", "")
                .. "~tplv-shrink:" .. FanQie.COVER_WIDTH .. ":0.image"
        end
        path = host_path:gsub("~tplv[^/]*$", "")
    end
    return FanQie.MOBILE_COVER_CDN .. "/" .. path .. "~tplv-shrink:" .. FanQie.COVER_WIDTH .. ":0.image"
end

function FanQie.make_shelf_params()
    return {
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
    }
end

function FanQie.shelf_url()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/info/v:version/"
end

function FanQie.bookshelf_multidetail_url()
    return FanQie.BASE_URL .. "/api/bookshelf/multidetail"
end

function FanQie.progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/progress"
end

function FanQie.update_progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/update_progress"
end

function FanQie.directory_url(book_id)
    return FanQie.BASE_URL .. "/api/reader/directory/detail?bookId=" .. H.url_encode(book_id)
end

function FanQie.reader_url(item_id)
    return "https://fanqienovel.com/reader/" .. item_id
end

return FanQie