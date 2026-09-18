-- FanQie Plugin Configuration
-- Copy this file to config.lua and modify the values below

return {
    -- Cookie 保底配置（可选）：扫码登录优先，以下字段仅在未扫码时作为 fallback。
    -- 正常使用无需填写，菜单 → 番茄小说 → 扫码登录即可自动获取并持久化 Cookie。
    -- 如需手动填写：从浏览器复制 Cookie 字符串填入 cookie_string，
    -- 或在 cookies 表里填入 ttwid / sessionid 等键值。
    cookie_string = "",

    cookies = {
        ["ttwid"] = "",
        ["sessionid"] = "",
    },

    sync = {
        pull_on_open = true,
        upload_on_close = true,
    },

    cache = {
        download_book_images = true,
        pre_download_chapters = 3,
        pre_download_groups = 2,
    },

    reading = {
        max_level = 1000,
        min_level = 1,
        auto_navigate = true,
        auto_navigate_delay = 0,
        disable_double_tap_navigation = false,
        enable_reflow = false,
        sync_bookmark = true,
        sync_annotation = true,
        sync_reading_progress = true,
        sync_calendar = true,
        sync_notebook = true,
    },

    debug = {
        dump_network = false,
        log_request = false,
        log_response = false,
        log_session = false,
        log_error = false,
        log_level = "warn",
    },

    layout = {
        reading_font_size = 0,
        reading_line_height = 0,
        reading_text_alignment = 0,
        reading_margin_top = 0,
        reading_margin_bottom = 0,
        reading_margin_left = 0,
        reading_margin_right = 0,
    },

    notification = {
        enabled = true,
        duration = 3,
    },

    experimental = {
        enable_new_sync = false,
        enable_new_api = false,
    },
}