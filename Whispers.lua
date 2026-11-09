-- DMme: Spam filter, whisper and /who handling, events, chat filters and right-click menus.
-- Part of DMme; loads after the files before it in DMme.toc and shares
-- names with them through the addon namespace (ns).
local ADDON, ns = ...

-- from earlier files (these never change after loading)
local AddFilter = ns.AddFilter
local AddTab = ns.AddTab
local AnySecret = ns.AnySecret
local ApplyFontSize = ns.ApplyFontSize
local BACKDROP_TEMPLATE = ns.BACKDROP_TEMPLATE
local BNKeyFromID = ns.BNKeyFromID
local ClassFileFromName = ns.ClassFileFromName
local DEFAULT_REPLIES = ns.DEFAULT_REPLIES
local FillMessages = ns.FillMessages
local FlatButton = ns.FlatButton
local FormatEntry = ns.FormatEntry
local FullName = ns.FullName
local GetWindow = ns.GetWindow
local GuildInviteName = ns.GuildInviteName
local IndexOf = ns.IndexOf
local IsBN = ns.IsBN
local IsSecret = ns.IsSecret
local KeyInfo = ns.KeyInfo
local LoadPalette = ns.LoadPalette
local LogEntry = ns.LogEntry
local PlayWhisperSound = ns.PlayWhisperSound
local Print = ns.Print
local PruneHistory = ns.PruneHistory
local RunThemeHooks = ns.RunThemeHooks
local SESSION_LINES = ns.SESSION_LINES
local ShortName = ns.ShortName
local Skin = ns.Skin
local SkinHeader = ns.SkinHeader
local StartFlash = ns.StartFlash
local Trim = ns.Trim
local UpdateTitle = ns.UpdateTitle
local defaults = ns.defaults
local playerName = ns.playerName
local tabOrder = ns.tabOrder
local whoAlias = ns.whoAlias
local whoPending = ns.whoPending
local windows = ns.windows

----------------------------------------------------------------------
-- Spam filter: whispers containing one of DB.spamWords are dropped (not
-- shown in DMme or the main chat). Never applied to friends, guild, your
-- group, Battle.net, GMs, or anyone you already have a conversation with.
----------------------------------------------------------------------
local DEFAULT_SPAM_WORDS = {
    "cheap gold", "gold for sale", "selling gold", "sell gold", "buy gold",
    "wts gold", "gold delivery", "fast delivery", "instant delivery",
    "power leveling", "powerleveling", "boosting service", "boost service",
    "discount code", "coupon code", "best price",
}
local spamLog = {}   -- this session's blocked whispers: { t, key, text, word }
local SPAM_LOG_MAX = 100

local function IsSpam(key, text, guid, flags)
    if not (ns.DB and ns.DB.spamFilter) or type(text) ~= "string" or not key then return false end
    if IsBN(key) or ns.session[key] then return false end
    if flags == "GM" or flags == "DEV" then return false end
    if guid then
        if C_FriendList and C_FriendList.IsFriend then
            local ok, friend = pcall(C_FriendList.IsFriend, guid)
            if ok and friend then return false end
        end
        if IsGuildMember then
            local ok, member = pcall(IsGuildMember, guid)
            if ok and member then return false end
        end
    end
    local short = ShortName(key)
    if (UnitInParty and UnitInParty(short)) or (UnitInRaid and UnitInRaid(short)) then return false end
    local t = text:lower()
    for _, w in ipairs(ns.DB.spamWords or {}) do
        if w ~= "" and t:find(w, 1, true) then return true, w end
    end
    return false
end

local function RecordSpam(key, text, word)
    spamLog[#spamLog + 1] = { t = time(), key = key, text = text, word = word }
    if #spamLog > SPAM_LOG_MAX then table.remove(spamLog, 1) end
    if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
end

-- Blocked whispers as plain text (Settings > Chat > Show blocked).
local function SpamLogText()
    if #spamLog == 0 then return "Nothing blocked this session." end
    local out = {}
    for _, e in ipairs(spamLog) do
        out[#out + 1] = "[" .. date("%H:%M", e.t) .. "] " .. ShortName(e.key) .. ": " .. e.text
            .. (e.muted and "   (muted)" or ("   (matched \"" .. e.word .. "\")"))
    end
    return table.concat(out, "\n")
end

----------------------------------------------------------------------
-- Mute: silence one person's whispers (and Battle.net whispers) for a
-- while. Muted whispers open no window, play no sound and are hidden from
-- the main chat too. They are listed under Settings > Chat > Show blocked.
-- DB.mutes[key] = time the mute ends, or 0 for forever.
----------------------------------------------------------------------
local MUTE_OPTIONS = {
    { id = "1h",      label = "1 hour",   secs = 3600 },
    { id = "24h",     label = "24 hours", secs = 86400 },
    { id = "week",    label = "1 week",   secs = 7 * 86400 },
    { id = "month",   label = "1 month",  secs = 30 * 86400 },
    { id = "forever", label = "Forever",  secs = 0 },
}
local MUTE_ALIASES = {
    ["1h"] = "1h", hour = "1h", ["1hour"] = "1h",
    ["24h"] = "24h", day = "24h", ["1d"] = "24h", ["24hours"] = "24h",
    week = "week", ["1w"] = "week", ["7d"] = "week",
    month = "month", ["1m"] = "month", ["30d"] = "month",
    forever = "forever", perm = "forever", always = "forever",
}
local function MuteOption(id)
    id = MUTE_ALIASES[(id or ""):lower():gsub("%s", "")]
    for _, o in ipairs(MUTE_OPTIONS) do if o.id == id then return o end end
end

-- Mute end time for a key, or nil. Expired mutes are removed here.
local function MutedUntil(key)
    local until_ = key and ns.DB and ns.DB.mutes[key]
    if not until_ then return nil end
    if until_ ~= 0 and until_ <= time() then
        ns.DB.mutes[key] = nil
        return nil
    end
    return until_
end
local function IsMuted(key) return MutedUntil(key) ~= nil end

-- "forever" / "3d 4h" / "2h 10m" / "5m"
local function MuteLeftText(key)
    local until_ = MutedUntil(key)
    if not until_ then return nil end
    if until_ == 0 then return "forever" end
    local left = until_ - time()
    local d, h, m = math.floor(left / 86400), math.floor(left % 86400 / 3600), math.ceil(left % 3600 / 60)
    if m == 60 then h, m = h + 1, 0 end
    if d > 0 then return d .. "d " .. h .. "h" end
    if h > 0 then return h .. "h " .. m .. "m" end
    return math.max(m, 1) .. "m"
end

local function AfterMutesChanged()
    if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
    if ns.mutedList and ns.mutedList:IsShown() then ns.mutedList:Refresh() end
end

local function MuteName(name, optId)
    local key, o = FullName(name), MuteOption(optId)
    if not key or not o or not ns.DB then return end
    ns.DB.mutes[key] = o.secs == 0 and 0 or time() + o.secs
    Print("Muted " .. ShortName(key) .. (o.secs == 0 and " forever" or (" for " .. o.label)) ..
        ". Undo with |cffffd100/dm unmute " .. ShortName(key) .. "|r.")
    AfterMutesChanged()
end

local function UnmuteName(name)
    local key = FullName(name)
    if not key or not ns.DB then return end
    if not ns.DB.mutes[key] then
        -- typed without a realm: match a muted "Name-Realm" by its first part
        for k in pairs(ns.DB.mutes) do
            if ShortName(k):lower() == ShortName(key):lower() then key = k; break end
        end
    end
    if ns.DB.mutes[key] then
        ns.DB.mutes[key] = nil
        Print("Unmuted " .. ShortName(key) .. ".")
    else
        Print(ShortName(key) .. " is not muted.")
    end
    AfterMutesChanged()
end

-- Drop expired mutes (at login); returns the number still muted.
local function PruneMutes()
    local n = 0
    for key in pairs(ns.DB.mutes) do
        if IsMuted(key) then n = n + 1 end
    end
    return n
end

-- Window listing muted people, with an Unmute button each.
local function ShowMutedList()
    local m = ns.mutedList
    if not m then
        local ROWS, ROW_H = 10, 22
        m = CreateFrame("Frame", "DMmeMutedList", UIParent, BACKDROP_TEMPLATE)
        m:SetSize(320, 74 + ROWS * ROW_H)
        m:SetPoint("CENTER", 60, 0)
        Skin(m, "window")
        m:SetFrameStrata("FULLSCREEN_DIALOG")
        m:SetToplevel(true)
        m:SetClampedToScreen(true)
        m:EnableMouse(true)
        m:SetMovable(true)
        m:RegisterForDrag("LeftButton")
        m:SetScript("OnDragStart", m.StartMoving)
        m:SetScript("OnDragStop", m.StopMovingOrSizing)
        tinsert(UISpecialFrames, "DMmeMutedList")

        local header = m:CreateTexture(nil, "BORDER")
        SkinHeader(header, 29)
        local title = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("LEFT", m, "TOPLEFT", 12, -15)
        title:SetText("Muted players")
        local close = FlatButton(m, "x", { bare = true, width = 20, height = 20,
            font = "GameFontHighlight", hoverColor = { 0.9, 0.25, 0.25 } })
        close:SetPoint("TOPRIGHT", -6, -5)
        close:SetScript("OnClick", function() m:Hide() end)

        local empty = m:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        empty:SetPoint("TOP", 0, -60)
        empty:SetText("Nobody is muted.")
        local hint = m:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", 12, 12)
        hint:SetPoint("RIGHT", -12, 0)
        hint:SetJustifyH("LEFT")
        hint:SetText("Mute someone: right-click their name > Mute whispers,\nor /dm mute <name> [1h|24h|week|month|forever].")

        m.offset = 0
        m.rows = {}
        for i = 1, ROWS do
            local r = CreateFrame("Frame", nil, m)
            r:SetHeight(ROW_H)
            r:SetPoint("TOPLEFT", 12, -36 - (i - 1) * ROW_H)
            r:SetPoint("RIGHT", -12, 0)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            r.name:SetPoint("LEFT", 0, 0)
            r.name:SetWidth(150)
            r.name:SetJustifyH("LEFT")
            r.left = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            r.left:SetPoint("LEFT", r.name, "RIGHT", 4, 0)
            r.btn = FlatButton(r, "Unmute", { width = 64, height = 18 })
            r.btn:SetPoint("RIGHT", 0, 0)
            r.btn:SetScript("OnClick", function(self) UnmuteName(self.key) end)
            m.rows[i] = r
        end
        m:EnableMouseWheel(true)
        m:SetScript("OnMouseWheel", function(self, delta)
            self.offset = self.offset - delta
            self:Refresh()
        end)

        function m:Refresh()
            local keys = {}
            for key in pairs(ns.DB.mutes) do
                if IsMuted(key) then keys[#keys + 1] = key end
            end
            table.sort(keys, function(a, b) return ShortName(a):lower() < ShortName(b):lower() end)
            self.offset = math.max(0, math.min(self.offset, #keys - ROWS))
            for i, r in ipairs(self.rows) do
                local key = keys[i + self.offset]
                if key then
                    r.name:SetText(ShortName(key))
                    r.left:SetText(MuteLeftText(key) == "forever" and "forever" or (MuteLeftText(key) .. " left"))
                    r.btn.key = key
                    r:Show()
                else
                    r:Hide()
                end
            end
            empty:SetShown(#keys == 0)
        end
        m:SetScript("OnShow", m.Refresh)
        ns.mutedList = m
    end
    m:SetScale(ns.DB.scale or 1)
    m:Show()
    m:Raise()
    m:Refresh()
end

-- Editor for the spam word list: one word or phrase per line.
local spamEditor
local function ShowSpamEditor()
    if not spamEditor then
        local e = CreateFrame("Frame", "DMmeSpamWords", UIParent, BACKDROP_TEMPLATE)
        e:SetSize(340, 360)
        e:SetPoint("CENTER", 60, 0)
        Skin(e, "window")
        e:SetFrameStrata("FULLSCREEN_DIALOG")
        e:SetToplevel(true)
        e:SetClampedToScreen(true)
        e:EnableMouse(true)
        e:SetMovable(true)
        e:RegisterForDrag("LeftButton")
        e:SetScript("OnDragStart", e.StartMoving)
        e:SetScript("OnDragStop", e.StopMovingOrSizing)
        tinsert(UISpecialFrames, "DMmeSpamWords")

        local header = e:CreateTexture(nil, "BORDER")
        SkinHeader(header, 29)
        local title = e:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("LEFT", e, "TOPLEFT", 12, -15)
        title:SetText("Spam filter words")
        local close = FlatButton(e, "x", { bare = true, width = 20, height = 20,
            font = "GameFontHighlight", hoverColor = { 0.9, 0.25, 0.25 } })
        close:SetPoint("TOPRIGHT", -6, -5)
        close:SetScript("OnClick", function() e:Hide() end)

        local hint = e:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("TOPLEFT", 12, -38)
        hint:SetPoint("RIGHT", -12, 0)
        hint:SetJustifyH("LEFT")
        hint:SetText("One word or phrase per line (not case sensitive). A whisper that contains any of them is blocked - never from friends, guild, your group, Battle.net, or people you already talk to.")

        local box = CreateFrame("Frame", nil, e, BACKDROP_TEMPLATE)
        box:SetPoint("TOPLEFT", 10, -80)
        box:SetPoint("BOTTOMRIGHT", -10, 40)
        Skin(box, "inset")
        local sf = CreateFrame("ScrollFrame", nil, box)
        sf:SetPoint("TOPLEFT", 8, -6)
        sf:SetPoint("BOTTOMRIGHT", -8, 6)
        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(300)
        eb:SetMaxLetters(0)
        sf:SetScrollChild(eb)
        sf:SetScript("OnSizeChanged", function(_, w) eb:SetWidth(w) end)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnCursorChanged", function(_, _, y, _, h)
            y = -y
            local top, height = sf:GetVerticalScroll(), sf:GetHeight()
            if y < top then
                sf:SetVerticalScroll(y)
            elseif y + h > top + height then
                sf:SetVerticalScroll(math.min(y + h - height, sf:GetVerticalScrollRange()))
            end
        end)
        sf:EnableMouseWheel(true)
        sf:SetScript("OnMouseWheel", function(self, delta)
            local v = self:GetVerticalScroll() - delta * 40
            self:SetVerticalScroll(math.max(0, math.min(v, self:GetVerticalScrollRange())))
        end)
        box:EnableMouse(true)
        box:SetScript("OnMouseDown", function() eb:SetFocus() end)

        local save = FlatButton(e, "Save", { width = 80 })
        save:SetPoint("BOTTOMRIGHT", -10, 10)
        save:SetScript("OnClick", function()
            local list, seen = {}, {}
            for line in (eb:GetText() .. "\n"):gmatch("(.-)\n") do
                local w = Trim(line):lower()
                if w ~= "" and not seen[w] then
                    seen[w] = true
                    list[#list + 1] = w
                end
            end
            ns.DB.spamWords = list
            Print("Spam filter: " .. #list .. " words saved.")
            e:Hide()
            if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
        end)
        local defaultsBtn = FlatButton(e, "Defaults", { width = 80, tooltip = "Default words",
            tooltipText = "Put back the default word list.\n(Not saved until you click Save.)" })
        defaultsBtn:SetPoint("RIGHT", save, "LEFT", -6, 0)
        defaultsBtn:SetScript("OnClick", function() eb:SetText(table.concat(DEFAULT_SPAM_WORDS, "\n")) end)
        e.eb = eb
        spamEditor = e
    end
    spamEditor:SetScale(ns.DB.scale or 1)
    spamEditor.eb:SetText(table.concat(ns.DB.spamWords or {}, "\n"))
    spamEditor:Show()
    spamEditor:Raise()
    spamEditor.eb:SetFocus()
end

----------------------------------------------------------------------
-- Whisper handling
----------------------------------------------------------------------
-- Conversations whose window was held back during combat: [key] = true
local heldOpen = {}

local function AddLine(key, text, incoming, guid)
    if incoming and guid then ns.DB.guids[key] = guid end
    local entry = { t = time(), i = incoming or nil, m = text, me = (not incoming) and playerName or nil }
    local s = ns.session[key] or {}
    s.t, s.text, s.incoming = entry.t, text, incoming
    s.lines = s.lines or {}
    ns.session[key] = s

    -- Create/show the window BEFORE logging so the new line isn't replayed twice
    local f = windows[key]
    local wantOpen = not incoming or ns.DB.autoOpen
    -- in combat: don't pop anything open, open it when combat ends
    local hold = incoming and ns.DB.autoOpen and ns.DB.combatHold and InCombatLockdown and InCombatLockdown()
    if hold then
        heldOpen[key] = true
    elseif ns.DB.tabbed then
        if wantOpen or (f and IndexOf(tabOrder, key)) then
            if incoming then
                f = AddTab(key) -- new tab in the background (shows it if nothing is open)
            elseif key ~= ns.activeKey or not f or not f:IsShown() then
                f = ns.ActivateTab(key) -- you whispered someone: switch to them
            end
        end
    else
        if not f and wantOpen then
            f = GetWindow(key, true)
        elseif f and incoming and not f:IsShown() and ns.DB.autoOpen then
            f:Show()
        end
    end
    -- remember the line for this session (after the window replayed old ones)
    local lines = s.lines
    lines[#lines + 1] = entry
    for _ = 1, #lines - SESSION_LINES do table.remove(lines, 1) end
    LogEntry(key, entry)
    if ns.DB.logEnabled and ns.hist and ns.hist:IsShown() then ns.hist:Refresh() end
    if not f then
        -- no window (auto-open is off): still count it as unread so the
        -- minimap badge/list show it; the window picks this up when opened
        if incoming then s.unread = (s.unread or 0) + 1 end
        ns.UpdateSessionUI()
        return
    end

    local wasAtBottom = f.msg:AtBottom()
    ns.DayBreak(f, entry.t) -- divider if this is the first message of a new day
    f.msg:AddMessage(FormatEntry(key, entry))

    if incoming then
        if not wasAtBottom then f.jump:Show() end
        local visible = f:IsVisible()
        if not visible or (not f.edit:HasFocus() and not (MouseIsOver and MouseIsOver(f))) then
            f.unread = f.unread + 1
            if visible then StartFlash(f) end
        end
        UpdateTitle(f)
    else
        f.msg:ScrollToBottom()
        f.jump:Hide()
    end
    if ns.DB.tabbed then ns.RefreshTabs() end
    ns.UpdateSessionUI()
end

----------------------------------------------------------------------
-- /who results -> player profile (level, race, class, guild, zone)
----------------------------------------------------------------------
ns.StoreProfile = function(name, data)
    if IsSecret(name) or AnySecret(data.level, data.race, data.class, data.guild, data.zone) then return end
    local key = FullName(name)
    if not key or not ns.DB then return end
    -- a /who for a Battle.net friend's character: fill in their Battle.net
    -- conversation too (guild, and level/race if Battle.net left them out)
    local alias = whoAlias[key]
    if alias then
        whoAlias[key] = nil
        local merged = {}
        for k, v in pairs(ns.DB.profiles[alias] or {}) do merged[k] = v end
        for k, v in pairs(data) do merged[k] = v end
        merged.character = merged.character or ShortName(key)
        merged.classFile = nil -- recomputed from the class name
        ns.StoreProfile(alias, merged)
    end
    -- only keep profiles for people we talk to (or just /who'd from a window)
    if not (windows[key] or ns.session[key] or ns.DB.log[key] or ns.DB.profiles[key] or whoPending[key]) then return end
    whoPending[key] = nil
    data.t = time()
    data.classFile = data.classFile or ClassFileFromName(data.class)
    local hadClass = (KeyInfo(key)) ~= nil
    ns.DB.profiles[key] = data
    local f = windows[key]
    if f then
        -- class just learned: redraw so their messages get the class colour
        if not hadClass and data.classFile then FillMessages(f) end
        UpdateTitle(f)
    end
    if ns.DB.tabbed then ns.RefreshTabs() end
    ns.UpdateSessionUI()
    if ns.hist and ns.hist:IsShown() then ns.hist:Refresh() end
end

-- Read the who list the game keeps (filled for every /who).
local function ReadWhoResults()
    local n = 0
    if C_FriendList and C_FriendList.GetNumWhoResults then
        n = C_FriendList.GetNumWhoResults() or 0
    elseif GetNumWhoResults then
        n = GetNumWhoResults() or 0
    end
    for i = 1, n do
        if C_FriendList and C_FriendList.GetWhoInfo then
            local w = C_FriendList.GetWhoInfo(i)
            if w and w.fullName then
                ns.StoreProfile(w.fullName, { level = w.level, race = w.raceStr, class = w.classStr,
                    classFile = w.filename, guild = w.fullGuildName, zone = w.area })
            end
        elseif GetWhoInfo then
            local name, guild, level, race, class, zone, classFile = GetWhoInfo(i)
            if name then
                ns.StoreProfile(name, { level = level, race = race, class = class,
                    classFile = classFile, guild = guild, zone = zone })
            end
        end
    end
end

-- Small /who results are printed in chat instead, e.g.
-- "[Bob]: Level 60 Night Elf Warrior <Guild> - Darnassus"
local whoPrefix = (WHO_LIST_FORMAT and WHO_LIST_FORMAT:match("|h:%s*(.-)%%d")) or "Level "
local function ParseWhoLine(msg)
    local name, rest = msg:match("|Hplayer:([^|:]+)[^|]*|h.-|h:%s*(.+)$")
    if not name or rest:sub(1, #whoPrefix) ~= whoPrefix then return false end
    rest = rest:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local level = tonumber(rest:match("(%d+)"))
    if not level then return false end
    local guild = rest:match("<(.-)>")
    local zone = rest:match("%s%-%s(.-)$")
    local mid = rest:match("%d+%s+(.-)%s*<") or rest:match("%d+%s+(.-)%s+%-%s") or ""
    -- split "Night Elf Warrior" into race + class using the localized class names
    local words = {}
    for w in mid:gmatch("%S+") do words[#words + 1] = w end
    local race, class, classFile
    for k = 1, #words do
        local cand = table.concat(words, " ", k)
        local file = ClassFileFromName(cand)
        if file then
            class, classFile = cand, file
            race = k > 1 and table.concat(words, " ", 1, k - 1) or nil
            break
        end
    end
    ns.StoreProfile(name, { level = level, race = race, class = class or mid,
        classFile = classFile, guild = guild, zone = zone })
    return true
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("WHO_LIST_UPDATE")
events:RegisterEvent("ADDON_ACTION_FORBIDDEN")
events:RegisterEvent("ADDON_ACTION_BLOCKED")
events:RegisterEvent("CHAT_MSG_SYSTEM")
events:RegisterEvent("CHAT_MSG_WHISPER")
events:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
events:RegisterEvent("PLAYER_REGEN_ENABLED") -- combat ended: open held-back windows
pcall(events.RegisterEvent, events, "CHAT_MSG_BN_WHISPER")
pcall(events.RegisterEvent, events, "CHAT_MSG_BN_WHISPER_INFORM")

events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        DMmeDB = DMmeDB or {}
        for k, v in pairs(defaults) do
            if type(v) == "table" then
                if type(DMmeDB[k]) ~= "table" then DMmeDB[k] = {} end
                -- fill in missing sub-options (buttons, menu)
                for sk, sv in pairs(v) do
                    if DMmeDB[k][sk] == nil then DMmeDB[k][sk] = sv end
                end
            elseif DMmeDB[k] == nil then
                DMmeDB[k] = v
            end
        end
        ns.DB = DMmeDB
        if ns.DB.theme ~= "classic" and ns.DB.theme ~= "midnight" then ns.DB.theme = "modern" end
        LoadPalette(ns.DB.theme)
        RunThemeHooks() -- anything built before the saved settings were loaded
        ApplyFontSize()
        ns.DB.history = nil -- old always-on history from v1.0 (replaced by opt-in log)
        ns.guidStore = function(key, guid) ns.DB.guids[key] = guid end
        -- session list survives /reload (wiped on a fresh login, see PLAYER_ENTERING_WORLD)
        if type(ns.DB.session) ~= "table" then ns.DB.session = {} end
        ns.session = ns.DB.session
        -- quick replies: a plain list, so it is not merged with defaults
        -- (that would bring back replies the player deleted)
        if type(ns.DB.replies) ~= "table" then
            ns.DB.replies = {}
            for i, r in ipairs(DEFAULT_REPLIES) do ns.DB.replies[i] = r end
        end
        -- spam words: same reason (deleted words must stay deleted)
        if type(ns.DB.spamWords) ~= "table" then
            ns.DB.spamWords = {}
            for i, w in ipairs(DEFAULT_SPAM_WORDS) do ns.DB.spamWords[i] = w end
        end
        self:UnregisterEvent("ADDON_LOADED")
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin = ...
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if ns.DB and isInitialLogin then
            -- fresh login (not a /reload): start a new session, but keep any
            -- whispers that already arrived while the game was loading
            local now = time()
            for key, s in pairs(ns.session) do
                if not s.t or now - s.t > 60 then ns.session[key] = nil end
            end
        end
        ns.UpdateSessionUI()
        return
    elseif event == "PLAYER_LOGOUT" then
        -- remember unread counts for the next /reload
        if ns.DB then
            for key, f in pairs(windows) do
                if ns.session[key] then ns.session[key].unread = (f.unread or 0) > 0 and f.unread or nil end
            end
        end
        return
    elseif event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
        -- the game blocked something DMme (or code it touched) tried to do:
        -- say exactly what, so it can be reported and fixed
        local addon, func = ...
        if addon == ADDON then
            Print("|cffff5555The game blocked|r " .. tostring(func) ..
                " |cff9a9aa8(" .. event .. ")|r - please report this line.")
        end
        return
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- combat over: open the windows that were held back
        if ns.DB and next(heldOpen) then
            for key in pairs(heldOpen) do
                if ns.DB.autoOpen and ns.session[key] then
                    if ns.DB.tabbed then
                        AddTab(key)
                    else
                        local f = GetWindow(key, true)
                        if f.unread > 0 and not f.minimized then StartFlash(f) end
                    end
                end
            end
            wipe(heldOpen)
            if ns.DB.tabbed then ns.RefreshTabs() end
            ns.UpdateSessionUI()
        end
        return
    elseif event == "WHO_LIST_UPDATE" then
        ReadWhoResults()
        return
    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if ns.DB and not IsSecret(msg) and type(msg) == "string" and msg:find("|Hplayer:", 1, true) then
            if ParseWhoLine(msg) then
                -- the who list usually has the exact class too; read it next frame
                C_Timer.After(0, ReadWhoResults)
            end
        end
        return
    elseif event == "PLAYER_LOGIN" then
        if ns.DB and not ns.DB.minimap.hide then ns.CreateMinimapButton() end
        if ns.DB and ns.DB.floatButton.show then ns.CreateFloatButton() end
        if ns.DB then PruneHistory() end -- drop history older than "Keep history for"
        if ns.DB then PruneMutes() end   -- drop mutes that ran out
        -- Re-key data saved by older versions as "Name-<own realm>"
        if ns.DB then
            for _, tbl in ipairs({ ns.DB.log, ns.DB.guids, ns.DB.positions }) do
                local moves = {}
                for k in pairs(tbl) do
                    local nk = FullName(k)
                    if nk and nk ~= k then moves[k] = nk end
                end
                for old, new in pairs(moves) do
                    if tbl[new] == nil then tbl[new] = tbl[old] end
                    tbl[old] = nil
                end
            end
        end
        return
    end
    if not ns.DB then return end

    local text, sender = ...
    local guid = select(12, ...)
    -- hidden from addons (e.g. in combat in an instance): the normal chat
    -- frame still shows it; DMme can't read it, so it skips this one
    if AnySecret(text, sender, guid, (select(13, ...))) then return end
    local key
    local isBN = event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM"
    if isBN then
        -- arg13 = Battle.net account ID of the other person
        key = BNKeyFromID(select(13, ...))
        guid = nil -- BNKeyFromID stores their character GUID if they are in WoW
    else
        key = FullName(sender)
    end
    if not key then return end

    if (event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER") and IsMuted(key) then
        spamLog[#spamLog + 1] = { t = time(), key = key, text = text, muted = true }
        if #spamLog > SPAM_LOG_MAX then table.remove(spamLog, 1) end
        if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
        return -- muted: no window, no sound
    end

    if event == "CHAT_MSG_WHISPER" then
        local spam, word = IsSpam(key, text, guid, (select(6, ...)))
        if spam then RecordSpam(key, text, word); return end -- no window, no sound
    end

    if event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER" then
        AddLine(key, text, true, guid)
        PlayWhisperSound(false, isBN)
        if not ns.DB.logEnabled and not ns.DB.hintShown then
            ns.DB.hintShown = true
            Print("Tip: type |cffffd100/dm log|r to save whisper history, and |cffffd100/dm history|r to browse it.")
        end
    else -- *_WHISPER_INFORM (you whispered someone)
        AddLine(key, text, false, guid)
    end
end)

-- Optionally hide whispers from the regular chat frames
if AddFilter then
    -- never hide a whisper DMme couldn't read (secret value): it would be lost
    local function filter(_, event, msg, sender, ...)
        if AnySecret(msg, sender) then return false end
        if not ns.DB then return false end
        -- muted people: hidden from the main chat too
        if event == "CHAT_MSG_WHISPER" and IsMuted(FullName(sender)) then return true end
        if event == "CHAT_MSG_BN_WHISPER" and next(ns.DB.mutes) then
            local id = select(11, ...) -- arg13 = Battle.net account ID
            if not AnySecret(id) and IsMuted((BNKeyFromID(id))) then return true end
        end
        if event == "CHAT_MSG_WHISPER" and ns.DB.spamFilter then
            -- ... starts at arg3: flags = arg6, guid = arg12
            local flags, guid = select(4, ...), select(10, ...)
            if not AnySecret(guid) and IsSpam(FullName(sender), msg, guid, flags) then return true end
        end
        return ns.DB.hideFromChat
    end
    AddFilter("CHAT_MSG_WHISPER", filter)
    AddFilter("CHAT_MSG_WHISPER_INFORM", filter)
    AddFilter("CHAT_MSG_BN_WHISPER", filter)
    AddFilter("CHAT_MSG_BN_WHISPER_INFORM", filter)
end

----------------------------------------------------------------------
-- Right-click "Guild Invite" on player names in chat
----------------------------------------------------------------------
if Menu and Menu.ModifyMenu then
    -- Modern menu system

    -- A menu DMme opened runs as "DMme", so the game's "Copy Character Name"
    -- would fail (CopyToClipboard() is protected). Point that entry at our own
    -- copy box instead: the name shows selected, ready for Ctrl+C.
    local COPY_LABEL = COPY_CHARACTER_NAME or "Copy Character Name"
    local function FixCopyName(desc, name)
        if not desc.EnumerateElementDescriptions then return end
        for _, child in desc:EnumerateElementDescriptions() do
            local ok, text = pcall(MenuUtil.GetElementText, child)
            if ok and text == COPY_LABEL and child.SetResponder then
                child:SetResponder(function()
                    ns.ShowCopyBox(name, "Press |cffffd100Ctrl+C|r to copy the name.",
                        "Name copied - paste it with |cffffd100Ctrl+V|r.")
                    return MenuResponse and MenuResponse.Close
                end)
            else
                FixCopyName(child, name) -- also look inside submenus
            end
        end
    end

    local function addEntries(_owner, root, contextData)
        if ns.menuCopyName and MenuUtil and MenuUtil.GetElementText then
            FixCopyName(root, ns.menuCopyName)
        end
        if not contextData then return end
        -- Never in menus opened from the Friends list. Menu items an addon adds
        -- carry its taint, and Blizzard closes menus without protection: the close
        -- re-enables scrolling on the Friends list under the menu as "DMme", which
        -- leaves tainted entries in the list's row-size cache. Its next refresh
        -- (any friend update) then fails: "DMme tried to call SearchFriends()".
        -- (Found with /console taintLog 2: wipe() of that cache, then the block.)
        if contextData.friendsList then return end
        local name
        if contextData.bnetIDAccount then
            name = BNKeyFromID(contextData.bnetIDAccount) -- Battle.net friend
        elseif contextData.unit then
            -- portraits / unit frames: the menu only gives the first part of the
            -- name, so ask the game for the whole thing ("Mrs Karma" on Forever,
            -- "Name-Realm" on Retail). NPCs give nil: nothing to add.
            name = ns.UnitWhisperName(contextData.unit)
            if not name then return end
        elseif contextData.name then
            name = contextData.name
            local server = contextData.server and contextData.server:gsub("[%s%-]", "")
            if server and server ~= "" then
                name = name .. "-" .. server
            end
        end
        if not name then return end
        if not ns.DB or not (ns.DB.menu.guild or ns.DB.menu.open or ns.DB.menu.mute) then return end
        root:CreateDivider()
        root:CreateTitle("DMme")
        if ns.DB.menu.guild then
            root:CreateButton("Guild Invite", function() GuildInviteName(FullName(name)) end)
        end
        if ns.DB.menu.open then
            root:CreateButton("Open Whisper Window", function() ns.OpenWindow(name) end)
        end
        if ns.DB.menu.mute and FullName(name) ~= FullName(playerName) then
            local left = MuteLeftText(FullName(name))
            if left then
                root:CreateButton("Unmute (" .. (left == "forever" and "muted forever" or (left .. " left")) .. ")",
                    function() UnmuteName(name) end)
            else
                local sub = root:CreateButton("Mute whispers")
                for _, o in ipairs(MUTE_OPTIONS) do
                    sub:CreateButton(o.label, function() MuteName(name, o.id) end)
                end
            end
        end
    end
    for _, tag in ipairs({ "MENU_UNIT_FRIEND", "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY",
                           "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_BN_FRIEND" }) do
        Menu.ModifyMenu(tag, addEntries)
    end
elseif UnitPopup_ShowMenu then
    -- Legacy UIDropDownMenu fallback
    local allowed = { FRIEND = true, PLAYER = true, PARTY = true, RAID_PLAYER = true, TARGET = true }
    hooksecurefunc("UnitPopup_ShowMenu", function(dropdown, which, unit, name, _userData)
        if not allowed[which] or UIDROPDOWNMENU_MENU_LEVEL ~= 1 then return end
        -- a unit (portrait) knows the whole name; the bare `name` may not
        local fromUnit = unit and ns.UnitWhisperName(unit)
        local target = fromUnit or name
        if not target or target == playerName then return end
        local server = dropdown and dropdown.server
        server = server and server:gsub("[%s%-]", "")
        if not fromUnit and server and server ~= "" and not target:find("-", 1, true) then
            target = target .. "-" .. server
        end

        if not ns.DB then return end
        if ns.DB.menu.guild then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Guild Invite"
            info.notCheckable = true
            info.func = function() GuildInviteName(FullName(target)) end
            UIDropDownMenu_AddButton(info, 1)
        end
        if ns.DB.menu.open then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Open Whisper Window"
            info.notCheckable = true
            info.func = function() ns.OpenWindow(target) end
            UIDropDownMenu_AddButton(info, 1)
        end
        if ns.DB.menu.mute then
            -- no submenu here: 24 hours (other lengths: /dm mute <name> <time>)
            local info = UIDropDownMenu_CreateInfo()
            info.notCheckable = true
            if IsMuted(FullName(target)) then
                info.text = "Unmute Whispers"
                info.func = function() UnmuteName(target) end
            else
                info.text = "Mute Whispers (24 hours)"
                info.func = function() MuteName(target, "24h") end
            end
            UIDropDownMenu_AddButton(info, 1)
        end
    end)
end

----------------------------------------------------------------------
-- Shift-click item links into a focused DMme edit box
----------------------------------------------------------------------
do
    -- Retail moved ChatEdit_InsertLink to ChatFrameUtil.InsertLink; hook
    -- whichever exist, and ignore the same link twice in one frame in case
    -- one calls the other.
    local lastLink, lastTime
    local function InsertIntoDMme(link)
        if type(link) ~= "string" then return end
        local now = GetTime()
        if link == lastLink and now == lastTime then return end
        for _, f in pairs(windows) do
            if f:IsShown() and f.edit:HasFocus() then
                lastLink, lastTime = link, now
                f.edit:Insert(link)
                return
            end
        end
    end
    if ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", InsertIntoDMme)
    end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", InsertIntoDMme)
    end
end

-- shared with the files after this one (see their 'from earlier files')
ns.spamLog = spamLog
ns.SpamLogText = SpamLogText
ns.ShowSpamEditor = ShowSpamEditor
ns.MUTE_OPTIONS = MUTE_OPTIONS
ns.MuteOption = MuteOption
ns.IsMuted = IsMuted
ns.MuteLeftText = MuteLeftText
ns.MuteName = MuteName
ns.UnmuteName = UnmuteName
ns.PruneMutes = PruneMutes
ns.ShowMutedList = ShowMutedList
