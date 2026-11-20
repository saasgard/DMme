-- DMme: translations.
-- Button labels, tooltips and Settings rows are looked up in ns.L by their
-- English text (FlatButton, ShowTooltip and the Settings builders do this).
-- A text with no translation shows in English, so a language can be filled
-- in a bit at a time. Chat messages (Print) are still English only.
--
-- To add a language: add a table for its locale code below, e.g.
--   deDE = {
--       ["Search"] = "Suchen",
--       ["Whisper sound"] = "Flüstern-Ton",
--   },
local _, ns = ...

local L = setmetatable({}, { __index = function(_, k) return k end })
ns.L = L

local TRANSLATIONS = {
    -- deDE = { },
    -- frFR = { },
}

local locale = GetLocale and GetLocale() or "enUS"
for k, v in pairs(TRANSLATIONS[locale] or {}) do rawset(L, k, v) end
