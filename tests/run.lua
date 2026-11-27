-- Tests for DMme's text handling (names, links, emoji, /who lines...).
-- Runs outside the game with plain Lua 5.1, from the addon folder:
--     lua tests/run.lua
-- The WoW API is replaced by simple stand-ins (below), and every addon
-- file in DMme.toc is loaded the way the game loads it.

----------------------------------------------------------------------
-- WoW stand-ins
----------------------------------------------------------------------
-- An object that accepts any method call (frames, fonts, textures...).
local function Dummy()
    return setmetatable({}, {
        __index = function() return function() return Dummy() end end,
    })
end

local units = { player = { "Tester" } } -- [unit] = { name, realm }

date, time = os.date, os.time
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert, tremove = table.insert, table.remove
hooksecurefunc = function() end
CreateFrame = function() return Dummy() end
CreateFont = function() return Dummy() end
ChatFontNormal, GameTooltip, DEFAULT_CHAT_FRAME, UIParent = Dummy(), Dummy(), Dummy(), Dummy()
UISpecialFrames, StaticPopupDialogs, SlashCmdList = {}, {}, {}
SOUNDKIT = { TELL_MESSAGE = 1 }
GetLocale = function() return "enUS" end
GetRealmName = function() return "My Realm" end
GetNormalizedRealmName = function() return "MyRealm" end
GetTime = function() return 0 end
UnitName = function(unit) local u = units[unit] if u then return u[1], u[2] end end
UnitIsPlayer = function(unit) return units[unit] ~= nil end
UnitClass = function() return "Warrior", "WARRIOR" end
IsInGroup = function() return units.party1 ~= nil end
IsInRaid = function() return false end
GetNumGroupMembers = function() return units.party1 and 2 or 0 end
GetNumSubgroupMembers = function() return units.party1 and 1 or 0 end
LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Warrior", DEMONHUNTER = "Demon Hunter" }
C_Timer = { After = function() end, NewTimer = function() return Dummy() end, NewTicker = function() return Dummy() end }
GetBindingKey = function() end

----------------------------------------------------------------------
-- Load the addon
----------------------------------------------------------------------
local ns = {}
local toc = assert(io.open("DMme.toc"))
for line in toc:lines() do
    local file = line:match("^([%w_]+%.lua)%s*$")
    if file then
        local chunk = assert(loadfile(file))
        chunk("DMme", ns)
    end
end
toc:close()

----------------------------------------------------------------------
-- Tiny test runner
----------------------------------------------------------------------
local passed, failed = 0, 0
local function eq(got, want, what)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(("FAIL %s\n     got:  %s\n     want: %s"):format(what, tostring(got), tostring(want)))
    end
end

----------------------------------------------------------------------
-- Names
----------------------------------------------------------------------
eq(ns.FullName("  bob "), "Bob", "FullName trims and capitalises")
eq(ns.FullName("Bob-MyRealm"), "Bob", "FullName drops your own realm")
eq(ns.FullName("Bob-Other"), "Bob-Other", "FullName keeps other realms")
eq(ns.FullName("BN:Bob#1234"), "BN:Bob#1234", "FullName keeps Battle.net keys")
eq(ns.FullName(""), nil, "FullName of an empty name")
eq(ns.FullName("дима"), "Дима", "FullName capitalises Cyrillic")
eq(ns.FullName("ярослав"), "Ярослав", "FullName capitalises Cyrillic Р-Я")
eq(ns.FullName("élodie"), "Élodie", "FullName capitalises accented Latin")
eq(ns.FullName("하늘"), "하늘", "FullName leaves Korean untouched")
eq(ns.FullName("龙王-Other"), "龙王-Other", "FullName leaves Chinese untouched")
eq(ns.Lower("ДИМА Élodie ABC 하늘"), "дима élodie abc 하늘", "Lower handles Cyrillic, accents and Korean")
eq(ns.ShortName("BN:Bob#1234"), "Bob", "ShortName of a Battle.net key")
eq(ns.ShortName("Bob-Other"), "Bob", "ShortName drops the realm")

----------------------------------------------------------------------
-- Web addresses
----------------------------------------------------------------------
local function url(word)
    local lead, u, trail = ns.FindURL(word)
    if not u then return nil end
    return lead .. "<" .. u .. ">" .. trail
end
eq(url("https://wowhead.com/item=1"), "<https://wowhead.com/item=1>", "URL with http")
eq(url("www.example.org"), "<www.example.org>", "URL with www")
eq(url("(discord.gg/abc)."), "(<discord.gg/abc>).", "URL inside punctuation")
eq(url("example.de"), "<example.de>", "country ending .de")
eq(url("10:30"), nil, "a time is not a URL")
eq(url("do.it"), nil, ".it is not taken as a URL")
eq(url("hello"), nil, "a word is not a URL")
eq(url("|Hitem:1|h[a.com]|h"), nil, "never inside a game link")

----------------------------------------------------------------------
-- Community invites and plain text
----------------------------------------------------------------------
local invite = ns.LabelInvites("look |HclubTicket:abc|h[Pristine Circlet]|h")
eq(invite:find("[Community invite: Pristine Circlet]", 1, true) ~= nil, true, "invite is labelled")
eq(ns.PlainText("|cffff0000red|r |Hitem:1|h[Sword]|h"), "red [Sword]", "PlainText removes colours and links")
eq(ns.PlainText("a||b"), "a|b", "PlainText unescapes ||")
eq(ns.SearchText({ m = "|cffff0000HeLLo|r" }), "hello", "SearchText is lower-case plain text")

----------------------------------------------------------------------
-- Emoji
----------------------------------------------------------------------
local E = ns.Emoji
eq(E.Render(":) hi"), E.Tex("smile") .. " hi", "emoji shortcut")
eq(E.Render("nice :D!"), "nice " .. E.Tex("grin") .. "!", "emoji with punctuation after it")
eq(E.Render("at 10:30"), "at 10:30", "a time stays text")
eq(E.Render("\240\159\148\165"), E.Tex("fire"), "real emoji")

----------------------------------------------------------------------
-- /who lines in chat
----------------------------------------------------------------------
local stored
ns.StoreProfile = function(name, data) stored = { name = name, data = data } end
eq(ns.ParseWhoLine("|Hplayer:Bob|h[Bob]|h: Level 60 Night Elf Warrior <The Guild> - Darnassus"), true, "who line parsed")
eq(stored and stored.name, "Bob", "who: name")
eq(stored and stored.data.level, 60, "who: level")
eq(stored and stored.data.race, "Night Elf", "who: two-word race")
eq(stored and stored.data.classFile, "WARRIOR", "who: class")
eq(stored and stored.data.guild, "The Guild", "who: guild")
eq(stored and stored.data.zone, "Darnassus", "who: zone")
ns.ParseWhoLine("|Hplayer:Ann|h[Ann]|h: Level 70 Blood Elf Demon Hunter - Silvermoon")
eq(stored and stored.data.classFile, "DEMONHUNTER", "who: two-word class")
eq(stored and stored.data.race, "Blood Elf", "who: race before a two-word class")
eq(ns.ParseWhoLine("|Hplayer:Bob|h[Bob]|h: hello there"), false, "a normal message is not a who line")

----------------------------------------------------------------------
-- Game message patterns (notices)
----------------------------------------------------------------------
local p = ns.GamePattern("No player named '%s' is currently playing.")
eq(("No player named 'Bob' is currently playing."):match(p), "Bob", "GamePattern captures the name")
eq(("No player named Bob."):match(p), nil, "GamePattern needs the whole message")

----------------------------------------------------------------------
-- Group check: same name on another realm doesn't count
----------------------------------------------------------------------
units.party1 = { "Bob", "Other" }
eq(ns.InMyGroup("Bob-Other"), true, "groupmate from another realm")
eq(ns.InMyGroup("Bob"), false, "same name, your realm, not in group")
units.party1 = nil

----------------------------------------------------------------------
-- Cleaning old saved data
----------------------------------------------------------------------
local now = time()
ns.session = {}
ns.DB = {
    guids = { Old = "g1", Logged = "g2", New = "g3" },
    profiles = { Old = {}, Fresh = {} },
    positions = { Old = {} },
    seen = { Old = now - 40 * 86400, Logged = now - 40 * 86400, New = now },
    log = { Logged = { entries = {} } },
    pinned = {}, mutes = {},
}
eq(ns.PruneStale(), 1, "one stale person removed")
eq(ns.DB.guids.Old, nil, "stale guid removed")
eq(ns.DB.profiles.Old, nil, "stale profile removed")
eq(ns.DB.positions.Old, nil, "stale position removed")
eq(ns.DB.guids.Logged, "g2", "kept: has saved history")
eq(ns.DB.guids.New, "g3", "kept: seen recently")
eq(ns.DB.seen.Fresh ~= nil, true, "unseen entries start their 30 days now")

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
