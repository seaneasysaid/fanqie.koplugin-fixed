--[[--
Compat translation shim for the fanqie review_popup port of weread's
thought_popup.

weread's modules called PluginUtil.tr(text) (== weread.lib.i18n.tr). The fanqie
plugin translates through gettext; reuse it when available, else identity.
--]]
local ok, gettext = pcall(require, "gettext")
local T = ok and gettext or function(text) return text end

local I18n = {
    tr = function(text)
        return T(text)
    end,
}

return I18n
