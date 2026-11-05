-- DMme: whispers in popup windows + guild invite helpers
local ADDON = ...

local defaults = {
    hideFromChat = false, -- hide whispers from the normal chat frames
    sound = true,         -- play a sound on incoming whispers
    autoOpen = true,      -- open a window automatically on incoming whispers
    logEnabled = false,   -- OPT-IN: save whispers to disk (SavedVariables)
    logMax = 2000,        -- max saved messages per contact
    hintShown = false,
    scale = 1,
    width = 380,
    height = 260,
    tabbed = true,        -- all conversations in one window with tabs
    buttons = {           -- which action buttons show in the whisper window
        guild = false,    -- Guild Invite is OFF by default
        party = true,
        who = true,
        history = true,
    },
    menu = {              -- extra entries in the right-click menu on names
        guild = false,
        open = true,
    },
    minimap = {           -- minimap button
        hide = false,
        angle = 200,      -- position around the minimap, in degrees
        detached = false, -- true = free-floating, drag it anywhere on screen
        -- pos = { point, relPoint, x, y }  (screen position when detached)
    },
    log = {},             -- [fullName] = { last = time, entries = { { t, i, m, me } } }
    positions = {},       -- [fullName] = { point, x, y, w, h, minimized }
    guids = {},           -- [fullName] = guid (for class colour / icon)
    classColors = true,   -- colour whispers/unread markers by class instead of pink
    profiles = {},        -- [fullName] = last /who result { level, race, class, classFile, guild, zone, t }
}

local DB
local windows = {}      -- [fullName] = frame
local windowCount = 0
local playerName = UnitName("player")
-- forward declarations (defined further down)
local ShowHistory, ShowSettings, ActivateTab, CloseTab, RefreshTabs, UpdateSessionUI
local CreateMinimapButton, OpenWindow

-- Conversations from this session: [key] = { t, text, incoming, lines = { entries }, unread }
-- Saved in DMmeDB.session so it survives /reload; wiped on a fresh login.
local session = {}
local SESSION_LINES = 200 -- messages kept per conversation for the session

-- Unread count for a conversation (window if it exists, else saved session value)
local function KeyUnread(key)
    local f = windows[key]
    if f then return f.unread or 0 end
    local s = session[key]
    return s and s.unread or 0
end
-- Players we sent a /who for from a DMme button: [key] = time
local whoPending = {}

----------------------------------------------------------------------
-- Style
----------------------------------------------------------------------
local WHITE = "Interface\\Buttons\\WHITE8X8"
local MEDIA_GEAR = "Interface\\AddOns\\DMme\\Media\\gear"   -- white gear, tinted in code
local MEDIA_ICON = "Interface\\AddOns\\DMme\\Media\\icon"   -- logo (minimap + addon list)
local FLAT = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil

local C = {
    bg       = { 0.055, 0.055, 0.07, 0.94 },
    header   = { 0.11, 0.11, 0.14, 1 },
    header2  = { 0.075, 0.075, 0.095, 1 },
    border   = { 0.20, 0.20, 0.25, 1 },
    inset    = { 0.035, 0.035, 0.045, 0.9 },
    button   = { 0.14, 0.14, 0.17, 1 },
    buttonHi = { 0.22, 0.22, 0.27, 1 },
    muted    = { 0.55, 0.55, 0.62 },
    accent   = { 1.0, 0.50, 1.0 },      -- default (whisper pink) until class is known
    inText   = { 1.0, 0.62, 1.0 },      -- incoming message text
    outText  = { 0.78, 0.76, 0.88 },    -- outgoing message text
    bn       = { 0.51, 0.77, 1.0 },     -- Battle.net blue
    bnText   = { 0.55, 0.85, 1.0 },     -- incoming Battle.net message text
}

local HEADER_H = 34

----------------------------------------------------------------------
-- API compatibility helpers
----------------------------------------------------------------------
local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
local AddFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff80ffDMme|r: " .. tostring(msg))
end

-- Modern clients (Midnight-era API) can hand addons "secret" values, e.g.
-- chat text during combat in instances. Those can't be inspected, stored or
-- changed by addons, so DMme leaves such messages to the normal chat frame.
local function IsSecret(v)
    return issecretvalue ~= nil and v ~= nil and issecretvalue(v) == true
end

local function AnySecret(...)
    for i = 1, select("#", ...) do
        if IsSecret((select(i, ...))) then return true end
    end
    return false
end

-- Battle.net conversations use the key "BN:<BattleTag>" (e.g. "BN:Bob#1234"),
-- which stays the same across sessions so saved history keeps working.
local function IsBN(key)
    return type(key) == "string" and key:sub(1, 3) == "BN:"
end

local function ShortName(name)
    if IsBN(name) then return (name:sub(4):gsub("#%d+$", "")) end
    if Ambiguate then return Ambiguate(name, "none") end
    return (name:gsub("%-.*$", ""))
end

local function IsOwnRealm(realm)
    if not realm or realm == "" then return false end
    local norm = GetNormalizedRealmName and GetNormalizedRealmName()
    local plain = GetRealmName and (GetRealmName() or ""):gsub("[%s%-]", "")
    return realm == norm or realm == plain
end

-- Conversation key. Same-realm players are stored by their plain name
-- ("Bob"), other realms keep exactly the "Name-Realm" the server sent us.
-- We never invent a realm suffix: some servers reject the client's
-- internal realm name ("No player named ... is currently playing").
local function FullName(name)
    if not name or name == "" then return nil end
    if IsBN(name) then return name end
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
    local base, realm = name:match("^(.-)%-(.+)$")
    if base and base ~= "" and IsOwnRealm(realm) then name = base end
    return name:sub(1, 1):upper() .. name:sub(2)
end

-- Name to use for whisper / invite API calls (keys are already in that form).
local function TargetName(name)
    return FullName(name) or name
end

----------------------------------------------------------------------
-- Battle.net helpers
----------------------------------------------------------------------
local bnIDs = {} -- [key] = bnetAccountID (only valid for this session)

local function BNInfo(id)
    if id and C_BattleNet and C_BattleNet.GetAccountInfoByID then
        return C_BattleNet.GetAccountInfoByID(id)
    end
end

-- Key for a Battle.net account ID; also remembers the ID and, if they are
-- playing WoW, their character GUID (gives class colours/icons).
local guidStore -- set once DB is loaded: function(key, guid)
local function BNKeyFromID(id)
    if not id then return nil end
    local info = BNInfo(id)
    local key = "BN:" .. ((info and info.battleTag) or tostring(id))
    bnIDs[key] = id
    local g = info and info.gameAccountInfo
    if g and g.playerGuid and guidStore then guidStore(key, g.playerGuid) end
    return key, info
end

-- Current bnetAccountID for a key (searches the friends list if needed).
local function BNResolve(key)
    if bnIDs[key] and BNInfo(bnIDs[key]) then return bnIDs[key] end
    if not (C_BattleNet and C_BattleNet.GetFriendAccountInfo and BNGetNumFriends) then return nil end
    for i = 1, (BNGetNumFriends()) do
        local a = C_BattleNet.GetFriendAccountInfo(i)
        if a and a.battleTag and ("BN:" .. a.battleTag) == key then
            bnIDs[key] = a.bnetAccountID
            return a.bnetAccountID
        end
    end
end

-- "Name-Realm" of the WoW character a Battle.net friend is playing
-- (same game version as you), or nil.
local function GetBNCharacter(key)
    local info = BNInfo(BNResolve(key))
    local g = info and info.gameAccountInfo
    if not g or not g.characterName or g.characterName == "" then return nil end
    if g.clientProgram and BNET_CLIENT_WOW and g.clientProgram ~= BNET_CLIENT_WOW then return nil end
    if g.wowProjectID and WOW_PROJECT_ID and g.wowProjectID ~= WOW_PROJECT_ID then return nil end
    local name = g.characterName
    if g.realmName and g.realmName ~= "" then name = name .. "-" .. g.realmName:gsub("[%s%-]", "") end
    return FullName(name)
end

-- Character to use for invite/who: the name itself, or the character a
-- Battle.net friend is currently playing.
local function ResolveTarget(key)
    if not IsBN(key) then return key end
    local c = GetBNCharacter(key)
    if not c then Print(ShortName(key) .. " isn't playing a character you can reach right now.") end
    return c
end

-- Send a whisper to a key (character or Battle.net).
local function SendWhisperTo(key, text)
    if IsBN(key) then
        local id = BNResolve(key)
        if id and BNSendWhisper then
            BNSendWhisper(id, text)
        else
            Print(ShortName(key) .. " is not online on Battle.net.")
        end
    else
        SendChat(text, "WHISPER", nil, key)
    end
end

local function CanInvite(silent)
    if not IsInGuild() then
        if not silent then Print("You are not in a guild.") end
        return false
    end
    if CanGuildInvite and not CanGuildInvite() then
        if not silent then Print("You do not have permission to invite to your guild.") end
        return false
    end
    return true
end

-- Guild invites are restricted to the Blizzard UI on this client:
--  * calling C_GuildInfo.Invite from an addon -> ADDON_ACTION_FORBIDDEN
--  * a secure button/macro running "/ginvite"  -> "A macro script has been blocked"
--  * pre-filling "/ginvite" in the chat box    -> the chat box gets tainted and
--    the invite is still forbidden when you press Enter
-- So we never touch the chat box. Instead we show the command, selected, in
-- our own little box: Ctrl+C, then Enter / Ctrl+V / Enter in normal chat.
-- Pasted text counts as your own typing, so the game accepts it.
local copyBox

local function ShowCopyBox(text, hint)
    if not copyBox then
        local b = CreateFrame("Frame", "DMmeCopyBox", UIParent, BACKDROP_TEMPLATE)
        b:SetSize(340, 84)
        b:SetPoint("TOP", UIParent, "TOP", 0, -160)
        b:SetBackdrop(FLAT)
        b:SetBackdropColor(0.055, 0.055, 0.07, 0.96)
        b:SetBackdropBorderColor(1, 0.5, 1, 1)
        b:SetFrameStrata("FULLSCREEN_DIALOG")
        b:EnableMouse(true)
        tinsert(UISpecialFrames, "DMmeCopyBox")

        b.hint = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.hint:SetPoint("TOPLEFT", 10, -10)
        b.hint:SetPoint("TOPRIGHT", -28, -10)
        b.hint:SetJustifyH("LEFT")

        local x = CreateFrame("Button", nil, b)
        x:SetSize(18, 18)
        x:SetPoint("TOPRIGHT", -5, -5)
        local xl = x:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        xl:SetPoint("CENTER")
        xl:SetText("x")
        x:SetScript("OnClick", function() b:Hide() end)

        local box = CreateFrame("Frame", nil, b, BACKDROP_TEMPLATE)
        box:SetPoint("BOTTOMLEFT", 10, 10)
        box:SetPoint("BOTTOMRIGHT", -10, 10)
        box:SetHeight(26)
        box:SetBackdrop(FLAT)
        box:SetBackdropColor(0.09, 0.09, 0.11, 1)
        box:SetBackdropBorderColor(0.3, 0.3, 0.36, 1)

        local eb = CreateFrame("EditBox", nil, box)
        eb:SetPoint("TOPLEFT", 8, 0)
        eb:SetPoint("BOTTOMRIGHT", -8, 0)
        eb:SetFontObject(ChatFontNormal)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function() b:Hide() end)
        eb:SetScript("OnEnterPressed", function() b:Hide() end)
        -- read-only: undo any typing, keep the text selected
        eb:SetScript("OnTextChanged", function(self, userInput)
            if userInput then self:SetText(b.text or ""); self:HighlightText() end
        end)
        eb:SetScript("OnMouseUp", function(self) self:HighlightText() end)
        eb:SetScript("OnKeyDown", function(_, key)
            if key == "C" and IsControlKeyDown() then
                C_Timer.After(0.05, function()
                    b:Hide()
                    Print("Copied. Now press |cffffd100Enter|r, |cffffd100Ctrl+V|r, |cffffd100Enter|r.")
                end)
            end
        end)
        b.eb = eb
        copyBox = b
    end
    copyBox.text = text
    copyBox.hint:SetText(hint)
    copyBox:Show()
    copyBox:Raise()
    copyBox.eb:SetText(text)
    copyBox.eb:SetFocus()
    copyBox.eb:HighlightText()
end

local function GuildInviteName(name)
    if not name or name == "" then return end
    if not CanInvite() then return end
    name = ResolveTarget(name)
    if not name then return end
    local cmd = "/ginvite " .. TargetName(name)
    ShowCopyBox(cmd, "Press |cffffd100Ctrl+C|r, then in chat: |cffffd100Enter|r, |cffffd100Ctrl+V|r, |cffffd100Enter|r.\n|cff9a9aa8The game only allows guild invites you type yourself.|r")
end

local function PartyInviteName(name)
    name = ResolveTarget(name)
    if not name then return end
    local target = TargetName(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(target)
    elseif InviteUnit then
        InviteUnit(target)
    end
end

local function WhoName(name)
    name = ResolveTarget(name)
    if not name then return end
    whoPending[FullName(name)] = time()
    local q = 'n-"' .. ShortName(name) .. '"'
    if C_FriendList and C_FriendList.SendWho then
        C_FriendList.SendWho(q)
    elseif SendWho then
        SendWho(q)
    end
end

-- Returns classFile, localizedClass, localizedRace for a GUID
local function GuidInfo(guid)
    if guid and GetPlayerInfoByGUID then
        local locClass, classFile, locRace = GetPlayerInfoByGUID(guid)
        return classFile, locClass, locRace
    end
end

local function ClassRGB(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
end

-- Accent colour for DMme's own windows (Settings, History, whisper list):
-- the class colour of the character you are playing, or pink if class
-- colours are turned off. Elements register with OnUIAccent so they can be
-- recoloured live when the setting changes.
local uiAccentHooks = {}
local function UIAccent()
    if DB and DB.classColors then
        local r, g, b = ClassRGB(select(2, UnitClass("player")))
        if r then return r, g, b end
    end
    return C.accent[1], C.accent[2], C.accent[3]
end
local function OnUIAccent(fn)
    uiAccentHooks[#uiAccentHooks + 1] = fn
    fn(UIAccent())
end
local function ApplyUIAccent()
    local r, g, b = UIAccent()
    for _, fn in ipairs(uiAccentHooks) do fn(r, g, b) end
end

-- classFile, localizedClass, localizedRace for a conversation, from the
-- whisper GUID or, failing that, the last /who result we saw for them.
local function KeyInfo(key)
    local classFile, locClass, locRace = GuidInfo(DB.guids[key])
    local p = DB.profiles and DB.profiles[key]
    if p then
        classFile = classFile or p.classFile
        locClass = locClass or p.class
        locRace = locRace or p.race
    end
    return classFile, locClass, locRace
end

-- Name colour for a conversation: Battle.net blue, else class colour.
local function KeyRGB(key)
    if IsBN(key) then return C.bn[1], C.bn[2], C.bn[3] end
    return ClassRGB((KeyInfo(key)))
end

-- localized class name -> classFile ("Warrior" -> "WARRIOR")
local classByName
local function ClassFileFromName(name)
    if not name then return nil end
    if not classByName then
        classByName = {}
        for _, t in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
            for file, loc in pairs(t) do classByName[loc:lower()] = file end
        end
    end
    return classByName[name:lower()]
end

local function Hex(r, g, b)
    return string.format("ff%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

local function Colorize(text, r, g, b)
    if not r then return text end
    return "|c" .. Hex(r, g, b) .. text .. "|r"
end

local function Lighten(r, g, b, t)
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

-- Highlight colour for a conversation (unread markers, tabs, previews):
-- their class colour (Battle.net blue), or whisper pink if unknown/disabled.
local function KeyHighlight(key)
    if DB.classColors then
        local r, g, b = KeyRGB(key)
        if r then return r, g, b end
    end
    return 1, 0.5, 1
end

-- Colour for their message text: class colour lightened a bit for readability.
local function KeyTextRGB(key)
    if DB.classColors then
        local r, g, b = KeyRGB(key)
        if r then return Lighten(r, g, b, 0.3) end
    end
    local t = IsBN(key) and C.bnText or C.inText
    return t[1], t[2], t[3]
end

local function KeyColorize(key, text)
    return Colorize(text, KeyHighlight(key))
end

local function SetGradientV(tex, top, bottom)
    tex:SetTexture(WHITE)
    if CreateColor and pcall(tex.SetGradient, tex, "VERTICAL",
            CreateColor(bottom[1], bottom[2], bottom[3], bottom[4] or 1),
            CreateColor(top[1], top[2], top[3], top[4] or 1)) then
        return
    end
    if tex.SetGradientAlpha then
        tex:SetGradientAlpha("VERTICAL", bottom[1], bottom[2], bottom[3], bottom[4] or 1,
            top[1], top[2], top[3], top[4] or 1)
    else
        tex:SetVertexColor(top[1], top[2], top[3], top[4] or 1)
    end
end

----------------------------------------------------------------------
-- Log (opt-in, saved to SavedVariables)
----------------------------------------------------------------------
local function LogEntry(key, entry)
    if not DB.logEnabled then return end
    local log = DB.log[key]
    if not log then log = { entries = {} }; DB.log[key] = log end
    local e = log.entries
    e[#e + 1] = entry
    log.last = entry.t
    local over = #e - (DB.logMax or 2000)
    for _ = 1, over do table.remove(e, 1) end
end

-- entry = { t = time(), i = incoming (true/nil), m = text, me = your character }
local function FormatEntry(key, e, dim)
    local stamp = "|cff5f5f6b" .. date("%H:%M", e.t) .. "|r"
    local name, r, g, b
    local bn = IsBN(key)
    if e.i then
        name = ShortName(key)
        r, g, b = ClassRGB((KeyInfo(key)))
        if bn and not r then r, g, b = C.bn[1], C.bn[2], C.bn[3] end
    else
        name = e.me or playerName
        if name == playerName then r, g, b = ClassRGB(select(2, UnitClass("player"))) end
    end
    local tc = C.outText
    if e.i then tc = { KeyTextRGB(key) } end
    if dim then
        r, g, b = 0.6, 0.6, 0.66
        tc = e.i and { 0.62, 0.52, 0.62 } or { 0.5, 0.5, 0.56 }
    end
    -- the name is a real player link, like in the normal chat frame
    local colored = Colorize(name, r or 0.85, g or 0.85, b or 0.9)
    local nameText
    if e.i and bn then
        local id = BNResolve(key)
        local info = BNInfo(id)
        if info and info.accountName then
            nameText = "|HBNplayer:" .. info.accountName .. ":" .. id .. ":0:BN_WHISPER:" .. info.accountName .. "|h" .. colored .. "|h"
        else
            nameText = colored
        end
    else
        nameText = "|Hplayer:" .. (e.i and key or name) .. "|h" .. colored .. "|h"
    end
    return string.format("%s  %s  %s", stamp, nameText, Colorize(e.m, tc[1], tc[2], tc[3]))
end

-- Open the game's own player right-click menu (same as in normal chat).
local function ShowPlayerMenu(name)
    if not name or not SetItemRef then return end
    if IsBN(name) then
        local id = BNResolve(name)
        local info = BNInfo(id)
        if info and info.accountName then
            SetItemRef("BNplayer:" .. info.accountName .. ":" .. id .. ":0:BN_WHISPER:" .. info.accountName,
                "[" .. info.accountName .. "]", "RightButton", DEFAULT_CHAT_FRAME)
        end
        return
    end
    SetItemRef("player:" .. name, "[" .. ShortName(name) .. "]", "RightButton", DEFAULT_CHAT_FRAME)
end

-- Hyperlink clicks in our message frames:
--  right-click / modified click on a name -> the game's normal handling (player menu, /who, ...)
--  plain left-click on a name             -> open that conversation in DMme
--  any other link (items, quests...)      -> the game's normal handling
local function HandleLink(_, link, text, button)
    local plain = button == "LeftButton" and not IsModifierKeyDown()
    local name = link:match("^player:([^:]+)")
    if name and plain then
        if FullName(name) ~= FullName(playerName) then OpenWindow(name) end
        return
    end
    local bnID = tonumber(link:match("^BNplayer:[^:]*:(%d+)") or "")
    if bnID and plain then
        OpenWindow((BNKeyFromID(bnID)))
        return
    end
    SetItemRef(link, text, button, DEFAULT_CHAT_FRAME)
end

local function DayHeader(t)
    return "|cff6a6a78----------  " .. date("%A, %d %B %Y", t) .. "  ----------|r"
end

local function SetLogging(on)
    DB.logEnabled = on and true or false
    if DB.logEnabled then
        Print("Whisper logging |cff55ff55ON|r - whispers are saved and shown in /dm history.")
    else
        Print("Whisper logging |cffff5555OFF|r - new whispers are not saved. Existing logs are kept (delete them in /dm history).")
    end
    if DMmeHistory and DMmeHistory.UpdateToggle then DMmeHistory:UpdateToggle() end
end

----------------------------------------------------------------------
-- Widgets
----------------------------------------------------------------------
local function ShowTooltip(owner, title, text)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:SetText(title, 1, 1, 1)
    if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
    GameTooltip:Show()
end

-- Flat button with hover highlight and optional tooltip.
-- opts: { width, tooltip, tooltipText, bare (no background), hoverColor }
local function FlatButton(parent, text, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent, BACKDROP_TEMPLATE)
    b:SetBackdrop(FLAT)
    local function normal()
        if opts.bare then
            b:SetBackdropColor(0, 0, 0, 0)
            b:SetBackdropBorderColor(0, 0, 0, 0)
        else
            b:SetBackdropColor(unpack(C.button))
            b:SetBackdropBorderColor(unpack(C.border))
        end
        b.label:SetTextColor(0.85, 0.85, 0.9)
    end
    b.cwFlat = true
    b.label = b:CreateFontString(nil, "OVERLAY", opts.font or "GameFontHighlightSmall")
    b.label:SetPoint("CENTER")
    b.label:SetText(text)
    b:SetSize(opts.width or (b.label:GetStringWidth() + 18), opts.height or 20)
    normal()

    b:SetScript("OnEnter", function(self)
        local hc = opts.hoverColor or self.accent or { UIAccent() }
        self:SetBackdropColor(unpack(C.buttonHi))
        self:SetBackdropBorderColor(hc[1], hc[2], hc[3], 1)
        self.label:SetTextColor(1, 1, 1)
        if opts.tooltip then ShowTooltip(self, opts.tooltip, opts.tooltipText) end
    end)
    b:SetScript("OnLeave", function()
        normal()
        GameTooltip:Hide()
    end)
    b:SetScript("OnMouseDown", function(self) self.label:SetPoint("CENTER", 1, -1) end)
    b:SetScript("OnMouseUp", function(self) self.label:SetPoint("CENTER", 0, 0) end)
    return b
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local function SavePosition(f)
    local point, _, _, x, y = f:GetPoint(1)
    if not point then return end
    local w, h = f:GetWidth(), f.minimized and f.restoreHeight or f:GetHeight()
    if DB.tabbed then
        DB.tabPos = { point, x, y, w, h }          -- one shared spot for the tabbed window
    else
        DB.positions[f.key] = { point, x, y, w, h, f.minimized }
    end
end

-- Place a window: the shared tabbed spot, or its own saved spot.
local function ApplyPosition(f)
    local p = DB.tabbed and DB.tabPos or (not DB.tabbed and DB.positions[f.key])
    local w, h = DB.width, DB.height
    f:ClearAllPoints()
    if p then
        f:SetPoint(p[1], UIParent, p[1], p[2], p[3])
        w, h = p[4] or w, p[5] or h
    elseif DB.tabbed then
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    else
        local offset = ((windowCount - 1) % 8) * 24
        f:SetPoint("CENTER", UIParent, "CENTER", offset, -offset)
    end
    f:SetWidth(w)
    if f.minimized then
        f.restoreHeight = h
        f:SetHeight(HEADER_H)
    else
        f:SetHeight(h)
    end
end

-- Show/hide action buttons according to the settings and re-flow them.
local function LayoutButtons(f)
    local prev
    for _, btn in ipairs(f.actionButtons) do
        if DB.buttons[btn.id] then
            btn:ClearAllPoints()
            if prev then
                btn:SetPoint("LEFT", prev, "RIGHT", 4, 0)
            else
                btn:SetPoint("TOPLEFT", f.body, "TOPLEFT", 8, -7)
            end
            btn:Show()
            prev = btn
        else
            btn:Hide()
        end
    end
    f.inset:ClearAllPoints()
    f.inset:SetPoint("TOPLEFT", f.body, "TOPLEFT", 8, prev and -33 or -8)
    f.inset:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", -8, 38)
end

local function UpdateTitle(f)
    local name = ShortName(f.key)
    local classFile, locClass, locRace = KeyInfo(f.key)
    local r, g, b = ClassRGB(classFile)
    f.title:SetText(Colorize(name, r, g, b))

    local sub = (locRace and locClass) and (locRace .. " " .. locClass) or "Whisper"
    local p = DB.profiles[f.key]
    if p then
        -- profile from the last /who: "Level 60 Human Warrior  <Guild>"
        local parts = {}
        if p.level then parts[#parts + 1] = "Level " .. p.level end
        if locRace then parts[#parts + 1] = locRace end
        if locClass then parts[#parts + 1] = Colorize(locClass, r, g, b) end
        sub = #parts > 0 and table.concat(parts, " ") or sub
        if p.guild and p.guild ~= "" then sub = sub .. "  |cff40ff40<" .. p.guild .. ">|r" end
        -- (zone is shown in the name tooltip; it made the line too long)
    end
    local bn = IsBN(f.key)
    if bn then
        -- Battle.net: blue name, Battle.net icon, and the character they play (if any)
        f.title:SetText(Colorize(name, C.bn[1], C.bn[2], C.bn[3]))
        local info = BNInfo(BNResolve(f.key))
        local ga = info and info.gameAccountInfo
        sub = "|cff82c4ffBattle.net|r"
        if not info or (ga and ga.isOnline == false) then
            sub = sub .. "  (offline)"
        elseif ga and ga.characterName and ga.characterName ~= "" then
            sub = sub .. "  -  " .. Colorize(ga.characterName, r, g, b) .. (locClass and (" " .. locClass) or "")
        end
    end
    if f.unread > 0 and f.minimized then
        sub = sub .. "  " .. KeyColorize(f.key, "(" .. f.unread .. " new)")
    end
    f.subtitle:SetText(sub)

    if bn then
        f.icon:SetTexture("Interface\\FriendsFrame\\Battlenet-Battleneticon")
        f.icon:SetTexCoord(0, 1, 0, 1)
    elseif classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
        f.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        f.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[classFile]))
    else
        f.icon:SetTexture("Interface\\Icons\\INV_Letter_15")
        f.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end

    -- accent colour follows the class colour (Battle.net: always blue)
    local acc = bn and C.bn or (r and { r, g, b } or C.accent)
    f.accent = acc
    f.accentLine:SetVertexColor(acc[1], acc[2], acc[3], 0.9)
    f.iconRing:SetBackdropBorderColor(acc[1], acc[2], acc[3], 1)
    f.glow:SetBackdropBorderColor(acc[1], acc[2], acc[3], 1)
    for _, btn in ipairs(f.actionButtons) do btn.accent = acc end
    if f.edit:HasFocus() then
        f.inputBox:SetBackdropBorderColor(acc[1], acc[2], acc[3], 1)
    end
end

local function StopFlash(f)
    local had = f.unread > 0
    f.unread = 0
    if f.flashAnim:IsPlaying() then f.flashAnim:Stop() end
    f.glow:Hide()
    UpdateTitle(f)
    if had and UpdateSessionUI then UpdateSessionUI() end
end

local function StartFlash(f)
    f.glow:Show()
    if not f.flashAnim:IsPlaying() then f.flashAnim:Play() end
end

local function SetMinimized(f, minimized)
    f.minimized = minimized
    if minimized then
        f.restoreHeight = f:GetHeight()
        f.body:Hide()
        f:SetHeight(HEADER_H)
        f.minBtn.label:SetText("+")
    else
        f.body:Show()
        f:SetHeight(f.restoreHeight or DB.height)
        f.minBtn.label:SetText("-")
        StopFlash(f)
    end
    SavePosition(f)
    UpdateTitle(f)
end

-- (Re)draw a window's messages: this session's messages (kept across /reload)
-- and, before them, the last few saved history messages (dimmed) when logging is on.
-- Called on creation and whenever colours change (setting toggled, class learned).
local function FillMessages(f)
    local key, msg = f.key, f.msg
    msg:Clear()
    local s = session[key]
    local lines = s and s.lines
    local sessionStart = lines and lines[1] and lines[1].t or math.huge
    local log = DB.logEnabled and DB.log[key]
    if log and #log.entries > 0 then
        local older = {}
        for _, e in ipairs(log.entries) do
            if e.t < sessionStart then older[#older + 1] = e end
        end
        if #older > 0 then
            for j = math.max(1, #older - 29), #older do
                msg:AddMessage(FormatEntry(key, older[j], true))
            end
            msg:AddMessage("|cff4a4a55-------------  earlier  -------------|r")
        end
    end
    if lines then
        for _, e in ipairs(lines) do msg:AddMessage(FormatEntry(key, e)) end
    end
    msg:ScrollToBottom()
    -- after Clear() + refill the frame can keep stale line positions until it
    -- is resized; force a relayout now and once more on the next frame
    local function relayout()
        if msg.MarkLayoutDirty then msg:MarkLayoutDirty() end
        if msg.MarkDisplayDirty then msg:MarkDisplayDirty() end
        if msg.RefreshLayout then msg:RefreshLayout() end
        msg:ScrollToBottom()
    end
    relayout()
    if C_Timer then C_Timer.After(0, relayout) end
end

-- Re-colour everything after a colour-related change.
local function RecolorAll()
    ApplyUIAccent() -- Settings / History / whisper list accents
    for _, f in pairs(windows) do
        FillMessages(f)
        UpdateTitle(f)
    end
    if RefreshTabs then RefreshTabs() end
    if UpdateSessionUI then UpdateSessionUI() end
end

local function CreateWindow(key)
    windowCount = windowCount + 1
    local f = CreateFrame("Frame", "DMmeConv" .. windowCount, UIParent, BACKDROP_TEMPLATE)
    f.key = key
    f.unread = 0
    f.actionButtons = {}
    f.accent = C.accent
    f:SetBackdrop(FLAT)
    f:SetBackdropColor(unpack(C.bg))
    f:SetBackdropBorderColor(unpack(C.border))
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetScale(DB.scale or 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(380, 170, 900, 700)
    elseif f.SetMinResize then
        f:SetMinResize(380, 170)
        f:SetMaxResize(900, 700)
    end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePosition(self) end)
    f:SetScript("OnMouseDown", function(self) self:Raise(); StopFlash(self) end)
    f:SetScript("OnEnter", function(self) if not self.minimized then StopFlash(self) end end)

    ApplyPosition(f)

    -- Soft drop shadow
    local shadow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetTexture(WHITE)
    shadow:SetVertexColor(0, 0, 0, 0.35)
    shadow:SetPoint("TOPLEFT", -3, 3)
    shadow:SetPoint("BOTTOMRIGHT", 4, -4)

    -- Unread glow (pulsing accent border)
    local glow = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    glow:SetPoint("TOPLEFT", -2, 2)
    glow:SetPoint("BOTTOMRIGHT", 2, -2)
    glow:SetBackdrop({ edgeFile = WHITE, edgeSize = 2 })
    glow:SetFrameLevel(f:GetFrameLevel() + 20)
    glow:EnableMouse(false)
    glow:Hide()
    f.glow = glow
    local flash = glow:CreateAnimationGroup()
    flash:SetLooping("BOUNCE")
    local fa = flash:CreateAnimation("Alpha")
    fa:SetFromAlpha(0.15)
    fa:SetToAlpha(1)
    fa:SetDuration(0.7)
    f.flashAnim = flash

    -- Fade in when shown
    local fadeIn = f:CreateAnimationGroup()
    local fi = fadeIn:CreateAnimation("Alpha")
    fi:SetFromAlpha(0)
    fi:SetToAlpha(1)
    fi:SetDuration(0.18)
    f:SetScript("OnShow", function() fadeIn:Play() end)

    ------------------------------------------------------------------
    -- Header
    ------------------------------------------------------------------
    local header = f:CreateTexture(nil, "BORDER")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H - 2)
    SetGradientV(header, C.header, C.header2)

    local accentLine = f:CreateTexture(nil, "ARTWORK")
    accentLine:SetTexture(WHITE)
    accentLine:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    accentLine:SetHeight(1)
    f.accentLine = accentLine

    local iconRing = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    iconRing:SetSize(24, 24)
    iconRing:SetPoint("LEFT", f, "TOPLEFT", 6, -(HEADER_H / 2))
    iconRing:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    iconRing:SetBackdropColor(0, 0, 0, 1)
    f.iconRing = iconRing
    local icon = iconRing:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    f.icon = icon

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", iconRing, "TOPRIGHT", 7, 0)
    f.title:SetPoint("RIGHT", f, "RIGHT", -76, 0)
    f.title:SetJustifyH("LEFT")
    -- single line, cut off with "..." instead of wrapping over the other line
    f.title:SetHeight(14)
    f.title:SetWordWrap(false)
    if f.title.SetMaxLines then f.title:SetMaxLines(1) end

    f.subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.subtitle:SetPoint("BOTTOMLEFT", iconRing, "BOTTOMRIGHT", 7, 0)
    f.subtitle:SetPoint("RIGHT", f, "RIGHT", -76, 0)
    f.subtitle:SetJustifyH("LEFT")
    f.subtitle:SetTextColor(unpack(C.muted))
    f.subtitle:SetHeight(11)
    f.subtitle:SetWordWrap(false)
    if f.subtitle.SetMaxLines then f.subtitle:SetMaxLines(1) end

    -- Right-click the icon/name in the title bar -> the game's player menu.
    -- Left-drag still moves the window.
    local nameBtn = CreateFrame("Button", nil, f)
    nameBtn:SetPoint("TOPLEFT", iconRing, "TOPLEFT", 0, 0)
    nameBtn:SetPoint("BOTTOMRIGHT", f.subtitle, "BOTTOMRIGHT", 0, 0)
    nameBtn:RegisterForClicks("RightButtonUp")
    nameBtn:RegisterForDrag("LeftButton")
    nameBtn:SetScript("OnClick", function() ShowPlayerMenu(f.key) end)
    nameBtn:SetScript("OnMouseDown", function() f:Raise(); StopFlash(f) end)
    nameBtn:SetScript("OnDragStart", function() f:StartMoving() end)
    nameBtn:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        SavePosition(f)
        if DB.tabbed then RefreshTabs() end
    end)
    nameBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        local r, g, b = KeyRGB(f.key)
        GameTooltip:SetText(ShortName(f.key), r or 1, g or 1, b or 1)
        local p = DB.profiles[f.key]
        local _, locClass, locRace = KeyInfo(f.key)
        if p then
            local line = ((p.level and ("Level " .. p.level .. " ")) or "") .. (locRace or "") .. " " .. (locClass or "")
            GameTooltip:AddLine(line, 1, 1, 1)
            if p.guild and p.guild ~= "" then GameTooltip:AddLine("<" .. p.guild .. ">", 0.25, 1, 0.25) end
            if p.zone and p.zone ~= "" then GameTooltip:AddLine(p.zone, 0.8, 0.8, 0.8) end
            local ago = math.floor((time() - (p.t or time())) / 60)
            GameTooltip:AddLine("From /who " .. (ago < 1 and "just now" or (ago .. " min ago")), 0.5, 0.5, 0.55)
        elseif locClass then
            GameTooltip:AddLine((locRace or "") .. " " .. locClass, 1, 1, 1)
            GameTooltip:AddLine("Click Who for level, guild and zone.", 0.5, 0.5, 0.55)
        end
        GameTooltip:AddLine("Right-click for player options.", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    nameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local close = FlatButton(f, "x", { bare = true, width = 20, height = 20,
        font = "GameFontHighlight", hoverColor = { 0.9, 0.25, 0.25 } })
    close:SetPoint("TOPRIGHT", -6, -7)
    close:SetScript("OnClick", function()
        if DB.tabbed then CloseTab(f.key) else f:Hide() end
    end)

    local minBtn = FlatButton(f, "-", { bare = true, width = 20, height = 20, font = "GameFontHighlight" })
    minBtn:SetPoint("RIGHT", close, "LEFT", -2, 0)
    minBtn:SetScript("OnClick", function() SetMinimized(f, not f.minimized) end)
    f.minBtn = minBtn

    -- Settings (gear)
    local gear = CreateFrame("Button", nil, f)
    gear:SetSize(14, 14)
    gear:SetPoint("RIGHT", minBtn, "LEFT", -6, 0)
    local gtex = gear:CreateTexture(nil, "ARTWORK")
    gtex:SetAllPoints()
    gtex:SetTexture(MEDIA_GEAR)
    gtex:SetVertexColor(0.6, 0.6, 0.68)
    gear:SetScript("OnEnter", function(self)
        local a = f.accent
        gtex:SetVertexColor(a[1], a[2], a[3])
        ShowTooltip(self, "Settings", "Buttons, tabs, sound, logging...")
    end)
    gear:SetScript("OnLeave", function() gtex:SetVertexColor(0.6, 0.6, 0.68); GameTooltip:Hide() end)
    gear:SetScript("OnMouseDown", function() gtex:SetPoint("TOPLEFT", 1, -1); gtex:SetPoint("BOTTOMRIGHT", 1, -1) end)
    gear:SetScript("OnMouseUp", function() gtex:SetPoint("TOPLEFT", 0, 0); gtex:SetPoint("BOTTOMRIGHT", 0, 0) end)
    gear:SetScript("OnClick", function() ShowSettings() end)

    ------------------------------------------------------------------
    -- Body (hidden when minimised)
    ------------------------------------------------------------------
    local body = CreateFrame("Frame", nil, f)
    body:SetPoint("TOPLEFT", 0, -HEADER_H)
    body:SetPoint("BOTTOMRIGHT", 0, 0)
    f.body = body

    -- Action bar
    local actions = {
        { "guild", "Guild Invite", "Guild Invite", "Shows the /ginvite command ready to copy and paste in chat.\n(The game only allows guild invites you send yourself.)", function() GuildInviteName(f.key) end },
        { "party", "Invite", "Party Invite", "Invite this player to your group.", function() PartyInviteName(f.key) end },
        { "who", "Who", "Who", "Look up level, class and zone.", function() WhoName(f.key) end },
        { "history", "History", "Whisper History", "Browse saved whispers with this player.", function() ShowHistory(f.key) end },
    }
    for _, a in ipairs(actions) do
        local btn = FlatButton(body, a[2], { tooltip = a[3], tooltipText = a[4] })
        btn.id = a[1]
        btn:SetScript("OnClick", a[5])
        f.actionButtons[#f.actionButtons + 1] = btn
    end

    -- Message area inset (anchored by LayoutButtons)
    local inset = CreateFrame("Frame", nil, body, BACKDROP_TEMPLATE)
    f.inset = inset
    LayoutButtons(f)
    inset:SetBackdrop(FLAT)
    inset:SetBackdropColor(unpack(C.inset))
    inset:SetBackdropBorderColor(0.13, 0.13, 0.16, 1)

    local msg = CreateFrame("ScrollingMessageFrame", nil, inset)
    msg:SetPoint("TOPLEFT", 7, -6)
    msg:SetPoint("BOTTOMRIGHT", -7, 6)
    msg:SetFontObject(ChatFontNormal)
    msg:SetJustifyH("LEFT")
    msg:SetFading(false)
    msg:SetMaxLines(500)
    msg:SetSpacing(2)
    msg:EnableMouse(true)
    if msg.SetIndentedWordWrap then msg:SetIndentedWordWrap(true) end
    if msg.SetHyperlinksEnabled then msg:SetHyperlinksEnabled(true) end
    msg:SetScript("OnHyperlinkClick", HandleLink)
    f.msg = msg

    -- "Jump to new messages" pill
    local jump = FlatButton(inset, "New messages  v", { tooltip = "Jump to latest" })
    jump:SetPoint("BOTTOM", 0, 6)
    jump:SetFrameLevel(msg:GetFrameLevel() + 5)
    jump:Hide()
    jump:SetScript("OnClick", function(self) msg:ScrollToBottom(); self:Hide() end)
    f.jump = jump

    msg:EnableMouseWheel(true)
    msg:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        elseif delta > 0 then
            self:ScrollUp(); self:ScrollUp()
        else
            self:ScrollDown(); self:ScrollDown()
        end
        if self:AtBottom() then jump:Hide() end
    end)

    -- Input box
    local inputBox = CreateFrame("Frame", nil, body, BACKDROP_TEMPLATE)
    inputBox:SetPoint("BOTTOMLEFT", 8, 8)
    inputBox:SetPoint("BOTTOMRIGHT", -24, 8)
    inputBox:SetHeight(24)
    inputBox:SetBackdrop(FLAT)
    inputBox:SetBackdropColor(0.09, 0.09, 0.11, 1)
    inputBox:SetBackdropBorderColor(unpack(C.border))
    f.inputBox = inputBox

    local edit = CreateFrame("EditBox", nil, inputBox)
    edit:SetPoint("TOPLEFT", 8, 0)
    edit:SetPoint("BOTTOMRIGHT", -8, 0)
    edit:SetFontObject(ChatFontNormal)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(255)
    edit:SetTextInsets(0, 0, 0, 0)
    f.edit = edit

    local placeholder = inputBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    placeholder:SetPoint("LEFT", 9, 0)
    placeholder:SetText("Whisper " .. ShortName(key) .. "...")
    placeholder:SetTextColor(0.4, 0.4, 0.46)

    inputBox:EnableMouse(true)
    inputBox:SetScript("OnMouseDown", function() edit:SetFocus() end)
    msg:SetScript("OnMouseDown", function() f:Raise(); StopFlash(f); edit:SetFocus() end)

    edit:SetScript("OnTextChanged", function(self)
        placeholder:SetShown(self:GetText() == "" and not self:HasFocus())
    end)
    edit:SetScript("OnEditFocusGained", function()
        placeholder:Hide()
        local a = f.accent
        inputBox:SetBackdropBorderColor(a[1], a[2], a[3], 1)
        StopFlash(f)
    end)
    edit:SetScript("OnEditFocusLost", function(self)
        placeholder:SetShown(self:GetText() == "")
        inputBox:SetBackdropBorderColor(unpack(C.border))
    end)
    edit:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        if text and text:match("%S") then
            SendWhisperTo(f.key, text)
        end
        self:SetText("")
    end)
    edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    -- Resize grip
    local grip = CreateFrame("Button", nil, body)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function() f:StopMovingOrSizing(); SavePosition(f) end)

    -- Escape closes the window
    tinsert(UISpecialFrames, f:GetName())

    FillMessages(f)
    -- restore the unread count saved before a /reload
    local s = session[key]
    if s and s.unread then
        f.unread = s.unread
        s.unread = nil
    end

    windows[key] = f
    UpdateTitle(f)
    local pos = DB.positions[key]
    if not DB.tabbed and pos and pos[6] then SetMinimized(f, true) end
    f:Hide() -- callers decide when to show it
    f:HookScript("OnHide", function() if UpdateSessionUI then UpdateSessionUI() end end)
    return f
end

local function GetWindow(key, show)
    local f = windows[key] or CreateWindow(key)
    if show and not f:IsShown() then f:Show() end
    return f
end

----------------------------------------------------------------------
-- Tabbed mode: every conversation window is docked in the same spot,
-- only the active one is shown, and a tab strip sits on top of it.
----------------------------------------------------------------------
local tabOrder, activeKey = {}, nil
local tabStrip, tabButtons = nil, {}

local function ActiveFrame() return activeKey and windows[activeKey] end

local function IndexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
end

ActivateTab = function(key)
    local f = windows[key] or CreateWindow(key)
    if not IndexOf(tabOrder, key) then tinsert(tabOrder, key) end
    local cur = ActiveFrame()
    if cur and cur ~= f then cur:Hide() end
    activeKey = key
    ApplyPosition(f)
    f:Show()
    f:Raise()
    StopFlash(f)
    RefreshTabs()
    return f
end

-- Add a tab without switching to it (unless nothing is showing).
local function AddTab(key)
    local f = windows[key] or CreateWindow(key)
    if not IndexOf(tabOrder, key) then tinsert(tabOrder, key) end
    local cur = ActiveFrame()
    if not cur or not cur:IsShown() then return ActivateTab(key) end
    RefreshTabs()
    return f
end

CloseTab = function(key)
    local idx = IndexOf(tabOrder, key)
    if idx then tremove(tabOrder, idx) end
    local f = windows[key]
    if f then f:Hide() end
    if key == activeKey then
        activeKey = nil
        local nextKey = idx and (tabOrder[idx] or tabOrder[idx - 1])
        if nextKey then ActivateTab(nextKey); return end
    end
    RefreshTabs()
end

local function CloseAllWindows()
    for _, f in pairs(windows) do f:Hide() end
    wipe(tabOrder)
    activeKey = nil
    if RefreshTabs then RefreshTabs() end
end

local function StyleTab(b, hover)
    local f = windows[b.key]
    local active = b.key == activeKey
    local r, g, bl = KeyRGB(b.key)
    local unread = f and f.unread or 0
    local name = ShortName(b.key)
    if active then
        b:SetBackdropColor(unpack(C.bg))
        b:SetBackdropBorderColor(unpack(C.border))
        b.line:SetVertexColor(r or C.accent[1], g or C.accent[2], bl or C.accent[3], 1)
        b.line:Show()
        b.label:SetText(Colorize(name, r or 1, g or 1, bl or 1))
    else
        b:SetBackdropColor(hover and 0.12 or 0.07, hover and 0.12 or 0.07, hover and 0.15 or 0.09, 0.95)
        b.line:Hide()
        if unread > 0 then
            b:SetBackdropBorderColor(KeyHighlight(b.key))
            b.label:SetText(KeyColorize(b.key, name .. " (" .. unread .. ")"))
        else
            b:SetBackdropBorderColor(unpack(C.border))
            b.label:SetText("|cff9a9aa8" .. name .. "|r")
        end
    end
end

local function GetTabButton(i)
    local b = tabButtons[i]
    if b then return b end
    b = CreateFrame("Button", nil, tabStrip, BACKDROP_TEMPLATE)
    b:SetHeight(22)
    b:SetBackdrop(FLAT)
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetTexture(WHITE)
    b.line:SetPoint("TOPLEFT", 1, -1)
    b.line:SetPoint("TOPRIGHT", -1, -1)
    b.line:SetHeight(2)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", 8, 0)
    b.label:SetPoint("RIGHT", -8, 0)
    b.label:SetWordWrap(false)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            ActivateTab(self.key)
        else
            CloseTab(self.key)
        end
    end)
    b:SetScript("OnEnter", function(self)
        StyleTab(self, true)
        ShowTooltip(self, ShortName(self.key), "Left-click: switch\nRight-click: close tab\nDrag: move window")
    end)
    b:SetScript("OnLeave", function(self) StyleTab(self); GameTooltip:Hide() end)
    -- dragging a tab moves the whole tabbed window
    b:SetScript("OnDragStart", function() local f = ActiveFrame(); if f then f:StartMoving() end end)
    b:SetScript("OnDragStop", function()
        local f = ActiveFrame()
        if f then f:StopMovingOrSizing(); SavePosition(f) end
    end)
    tabButtons[i] = b
    return b
end

RefreshTabs = function()
    if not tabStrip then
        tabStrip = CreateFrame("Frame", nil, UIParent)
        tabStrip:SetHeight(22)
    end
    local host = ActiveFrame()
    if not DB.tabbed or not host or #tabOrder == 0 then
        tabStrip:Hide()
        return
    end
    tabStrip:SetParent(host)
    tabStrip:ClearAllPoints()
    tabStrip:SetPoint("BOTTOMLEFT", host, "TOPLEFT", 0, -1)
    tabStrip:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", 0, -1)
    tabStrip:SetFrameLevel(host:GetFrameLevel() + 2)
    tabStrip:Show()

    local n, gap = #tabOrder, 2
    local avail = host:GetWidth()
    local widths, total = {}, 0
    for i, key in ipairs(tabOrder) do
        local b = GetTabButton(i)
        b.key = key
        StyleTab(b)
        local w = math.max(60, math.min(140, b.label:GetStringWidth() + 18))
        widths[i] = w
        total = total + w
    end
    local squeeze = (total + gap * (n - 1)) > avail
    local even = math.floor((avail - gap * (n - 1)) / n)
    local x = 0
    for i = 1, n do
        local b = tabButtons[i]
        local w = squeeze and even or widths[i]
        b:SetWidth(w)
        b:ClearAllPoints()
        b:SetPoint("BOTTOMLEFT", tabStrip, "BOTTOMLEFT", x, 0)
        b:Show()
        x = x + w + gap
    end
    for i = n + 1, #tabButtons do tabButtons[i]:Hide() end
    if UpdateSessionUI then UpdateSessionUI() end
end

local function SetTabbed(on)
    CloseAllWindows()
    DB.tabbed = on and true or false
    for _, f in pairs(windows) do ApplyPosition(f) end
    Print("Tabbed window: " .. (DB.tabbed and "ON" or "OFF"))
end

OpenWindow = function(name)
    local key = FullName(name)
    if not key then return end
    local f
    if DB.tabbed then f = ActivateTab(key) else f = GetWindow(key, true) end
    if f.minimized then SetMinimized(f, false) end
    f:Raise()
    f.edit:SetFocus()
end

----------------------------------------------------------------------
-- History browser
----------------------------------------------------------------------
local ROWS, ROW_H = 13, 26
local hist -- the frame (global name DMmeHistory)

StaticPopupDialogs["DMME_DELETE_LOG"] = {
    text = "Delete the saved whisper log with %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, data)
        DB.log[data] = nil
        if hist then
            if hist.selected == data then hist.selected = nil end
            hist:Refresh()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

----------------------------------------------------------------------
-- Copy window: a conversation as plain, selectable text (Ctrl+C)
----------------------------------------------------------------------
-- Remove colour codes, textures and link wrappers ("|Hitem:..|h[Sword]|h" -> "[Sword]").
local function PlainText(s)
    s = s or ""
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("|H.-|h(.-)|h", "%1")
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", "")
    s = s:gsub("|K.-|k", "?")
    s = s:gsub("||", "|")
    return s
end

-- The whole saved conversation with `key` as plain text, grouped by day.
local function ConversationText(key)
    local log = DB.log[key]
    if not log then return "" end
    local out, lastDay = {}, nil
    local them = ShortName(key)
    for _, e in ipairs(log.entries) do
        local day = date("%Y%m%d", e.t)
        if day ~= lastDay then
            if lastDay then out[#out + 1] = "" end
            out[#out + 1] = "--- " .. date("%A, %d %B %Y", e.t) .. " ---"
            lastDay = day
        end
        local who = e.i and them or (e.me or playerName)
        out[#out + 1] = "[" .. date("%H:%M", e.t) .. "] " .. who .. ": " .. PlainText(e.m)
    end
    return table.concat(out, "\n")
end

local copyLog

local function ShowCopyLog(title, text)
    if not copyLog then
        local c = CreateFrame("Frame", "DMmeCopyLog", UIParent, BACKDROP_TEMPLATE)
        c:SetSize(540, 380)
        c:SetPoint("CENTER", 40, -20)
        c:SetBackdrop(FLAT)
        c:SetBackdropColor(unpack(C.bg))
        c:SetBackdropBorderColor(unpack(C.border))
        c:SetFrameStrata("FULLSCREEN_DIALOG")
        c:SetToplevel(true)
        c:SetClampedToScreen(true)
        c:EnableMouse(true)
        c:SetMovable(true)
        c:RegisterForDrag("LeftButton")
        c:SetScript("OnDragStart", c.StartMoving)
        c:SetScript("OnDragStop", c.StopMovingOrSizing)
        tinsert(UISpecialFrames, "DMmeCopyLog")

        local shadow = c:CreateTexture(nil, "BACKGROUND", nil, -8)
        shadow:SetTexture(WHITE)
        shadow:SetVertexColor(0, 0, 0, 0.35)
        shadow:SetPoint("TOPLEFT", -3, 3)
        shadow:SetPoint("BOTTOMRIGHT", 4, -4)

        local header = c:CreateTexture(nil, "BORDER")
        header:SetPoint("TOPLEFT", 1, -1)
        header:SetPoint("TOPRIGHT", -1, -1)
        header:SetHeight(28)
        SetGradientV(header, C.header, C.header2)
        local line = c:CreateTexture(nil, "ARTWORK")
        line:SetTexture(WHITE)
        line:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
        line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
        line:SetHeight(1)
        OnUIAccent(function(r, g, b) line:SetVertexColor(r, g, b, 0.9) end)

        c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        c.title:SetPoint("LEFT", c, "TOPLEFT", 10, -15)

        local close = FlatButton(c, "x", { bare = true, width = 20, height = 20,
            font = "GameFontHighlight", hoverColor = { 0.9, 0.25, 0.25 } })
        close:SetPoint("TOPRIGHT", -4, -5)
        close:SetScript("OnClick", function() c:Hide() end)

        local hint = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        hint:SetPoint("BOTTOMLEFT", 12, 12)
        hint:SetText("Press |cffffd100Ctrl+C|r to copy, then paste it anywhere with |cffffd100Ctrl+V|r.")

        local selectAll = FlatButton(c, "Select all", { width = 80 })
        selectAll:SetPoint("BOTTOMRIGHT", -10, 8)

        -- text area
        local box = CreateFrame("Frame", nil, c, BACKDROP_TEMPLATE)
        box:SetPoint("TOPLEFT", 10, -38)
        box:SetPoint("BOTTOMRIGHT", -10, 36)
        box:SetBackdrop(FLAT)
        box:SetBackdropColor(unpack(C.inset))
        box:SetBackdropBorderColor(0.13, 0.13, 0.16, 1)

        local sf = CreateFrame("ScrollFrame", nil, box)
        sf:SetPoint("TOPLEFT", 8, -6)
        sf:SetPoint("BOTTOMRIGHT", -8, 6)

        local eb = CreateFrame("EditBox", nil, sf)
        eb:SetMultiLine(true)
        eb:SetAutoFocus(false)
        eb:SetFontObject(ChatFontNormal)
        eb:SetWidth(500)
        eb:SetMaxLetters(0)
        sf:SetScrollChild(eb)
        sf:SetScript("OnSizeChanged", function(self, w) eb:SetWidth(w) end)

        -- read-only: undo any typing
        eb:SetScript("OnTextChanged", function(self, userInput)
            if userInput then self:SetText(c.text or ""); self:HighlightText() end
        end)
        eb:SetScript("OnEscapePressed", function() c:Hide() end)
        -- keep the cursor visible while moving through the text
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

        selectAll:SetScript("OnClick", function() eb:SetFocus(); eb:HighlightText() end)

        c.eb, c.sf = eb, sf
        copyLog = c
    end
    copyLog.text = text
    copyLog.title:SetText(title)
    copyLog:SetScale(DB.scale or 1)
    copyLog:Show()
    copyLog:Raise()
    copyLog.eb:SetText(text)
    copyLog.eb:SetCursorPosition(0)
    copyLog.sf:SetVerticalScroll(0)
    copyLog.eb:SetFocus()
    copyLog.eb:HighlightText()
end

local function CreateHistory()
    local h = CreateFrame("Frame", "DMmeHistory", UIParent, BACKDROP_TEMPLATE)
    h:SetSize(680, 430)
    h:SetPoint("CENTER")
    h:SetBackdrop(FLAT)
    h:SetBackdropColor(unpack(C.bg))
    h:SetBackdropBorderColor(unpack(C.border))
    h:SetFrameStrata("DIALOG")
    h:SetToplevel(true)
    h:SetClampedToScreen(true)
    h:SetScale(DB.scale or 1)
    h:EnableMouse(true)
    h:SetMovable(true)
    h:RegisterForDrag("LeftButton")
    h:SetScript("OnDragStart", h.StartMoving)
    h:SetScript("OnDragStop", h.StopMovingOrSizing)
    h:SetScript("OnMouseDown", h.Raise)
    tinsert(UISpecialFrames, "DMmeHistory")
    h.filter = ""
    h.offset = 0
    h.list = {}

    local shadow = h:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetTexture(WHITE)
    shadow:SetVertexColor(0, 0, 0, 0.35)
    shadow:SetPoint("TOPLEFT", -3, 3)
    shadow:SetPoint("BOTTOMRIGHT", 4, -4)

    -- Header
    local header = h:CreateTexture(nil, "BORDER")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H - 2)
    SetGradientV(header, C.header, C.header2)
    local line = h:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    OnUIAccent(function(r, g, b) line:SetVertexColor(r, g, b, 0.9) end)
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    line:SetHeight(1)

    local icon = h:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", h, "TOPLEFT", 8, -(HEADER_H / 2))
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = h:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText("Whisper History")

    local close = FlatButton(h, "x", { bare = true, width = 20, height = 20,
        font = "GameFontHighlight", hoverColor = { 0.9, 0.25, 0.25 } })
    close:SetPoint("TOPRIGHT", -6, -7)
    close:SetScript("OnClick", function() h:Hide() end)

    local toggle = FlatButton(h, "Logging: OFF", { width = 110,
        tooltip = "Whisper logging", tooltipText = "When ON, whispers are saved to your SavedVariables so you can read them here later. Off by default." })
    toggle:SetPoint("RIGHT", close, "LEFT", -8, 0)
    toggle:SetScript("OnClick", function() SetLogging(not DB.logEnabled) end)
    function h:UpdateToggle()
        if DB.logEnabled then
            toggle.label:SetText("Logging: |cff55ff55ON|r")
        else
            toggle.label:SetText("Logging: |cffff5555OFF|r")
        end
        self:Refresh()
    end

    -- Left: search + contact list
    local left = CreateFrame("Frame", nil, h, BACKDROP_TEMPLATE)
    left:SetPoint("TOPLEFT", 8, -(HEADER_H + 8))
    left:SetPoint("BOTTOMLEFT", 8, 8)
    left:SetWidth(200)
    left:SetBackdrop(FLAT)
    left:SetBackdropColor(unpack(C.inset))
    left:SetBackdropBorderColor(0.13, 0.13, 0.16, 1)

    local searchBox = CreateFrame("Frame", nil, left, BACKDROP_TEMPLATE)
    searchBox:SetPoint("TOPLEFT", 6, -6)
    searchBox:SetPoint("TOPRIGHT", -6, -6)
    searchBox:SetHeight(22)
    searchBox:SetBackdrop(FLAT)
    searchBox:SetBackdropColor(0.09, 0.09, 0.11, 1)
    searchBox:SetBackdropBorderColor(unpack(C.border))
    local search = CreateFrame("EditBox", nil, searchBox)
    search:SetPoint("TOPLEFT", 7, 0)
    search:SetPoint("BOTTOMRIGHT", -7, 0)
    search:SetFontObject(ChatFontNormal)
    search:SetAutoFocus(false)
    local ph = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ph:SetPoint("LEFT", 8, 0)
    ph:SetText("Search names or messages...")
    ph:SetTextColor(0.4, 0.4, 0.46)
    searchBox:EnableMouse(true)
    searchBox:SetScript("OnMouseDown", function() search:SetFocus() end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEditFocusGained", function()
        ph:Hide()
        searchBox:SetBackdropBorderColor(UIAccent())
    end)
    search:SetScript("OnEditFocusLost", function(self)
        ph:SetShown(self:GetText() == "")
        searchBox:SetBackdropBorderColor(unpack(C.border))
    end)
    search:SetScript("OnTextChanged", function(self)
        ph:SetShown(self:GetText() == "" and not self:HasFocus())
        h.filter = self:GetText():lower()
        h.offset = 0
        h:Refresh()
    end)

    h.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, left, BACKDROP_TEMPLATE)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", 4, -(32 + (i - 1) * ROW_H))
        row:SetPoint("TOPRIGHT", -4, -(32 + (i - 1) * ROW_H))
        row:SetBackdrop({ bgFile = WHITE })
        row:SetBackdropColor(0, 0, 0, 0)
        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetTexture(WHITE)
        row.bar:SetPoint("TOPLEFT")
        row.bar:SetPoint("BOTTOMLEFT")
        row.bar:SetWidth(2)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("LEFT", 8, 0)
        row.name:SetPoint("RIGHT", -62, 0)
        row.name:SetJustifyH("LEFT")
        row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.info:SetPoint("RIGHT", -6, 0)
        row.info:SetJustifyH("RIGHT")
        row.info:SetTextColor(unpack(C.muted))
        row:SetScript("OnEnter", function(self)
            if h.selected ~= self.key then self:SetBackdropColor(1, 1, 1, 0.05) end
        end)
        row:SetScript("OnLeave", function(self)
            if h.selected ~= self.key then self:SetBackdropColor(0, 0, 0, 0) end
        end)
        row:SetScript("OnClick", function(self)
            h.selected = self.key
            h:Refresh()
        end)
        h.rows[i] = row
    end
    left:EnableMouseWheel(true)
    left:SetScript("OnMouseWheel", function(_, delta)
        local maxOff = math.max(0, #h.list - ROWS)
        h.offset = math.min(maxOff, math.max(0, h.offset - delta * 2))
        h:RefreshRows()
    end)

    -- Right: toolbar + log view
    local right = CreateFrame("Frame", nil, h, BACKDROP_TEMPLATE)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 8, 0)
    right:SetPoint("BOTTOMRIGHT", -8, 8)
    right:SetBackdrop(FLAT)
    right:SetBackdropColor(unpack(C.inset))
    right:SetBackdropBorderColor(0.13, 0.13, 0.16, 1)

    h.who = right:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h.who:SetPoint("TOPLEFT", 10, -10)
    h.who:SetPoint("RIGHT", right, "RIGHT", -290, 0)
    h.who:SetJustifyH("LEFT")

    local del = FlatButton(right, "Delete", { hoverColor = { 0.9, 0.25, 0.25 },
        tooltip = "Delete log", tooltipText = "Permanently delete the saved log with this player." })
    del:SetPoint("TOPRIGHT", -6, -6)
    del:SetScript("OnClick", function()
        if h.selected then
            StaticPopup_Show("DMME_DELETE_LOG", ShortName(h.selected), nil, h.selected)
        end
    end)
    local gi = FlatButton(right, "Guild Invite", { tooltip = "Guild Invite",
        tooltipText = "Shows the /ginvite command ready to copy and paste in chat." })
    gi:SetPoint("RIGHT", del, "LEFT", -4, 0)
    gi:SetScript("OnClick", function() if h.selected then GuildInviteName(h.selected) end end)
    local chat = FlatButton(right, "Open Chat", { tooltip = "Open whisper window" })
    chat:SetPoint("RIGHT", gi, "LEFT", -4, 0)
    chat:SetScript("OnClick", function() if h.selected then OpenWindow(h.selected) end end)
    local copy = FlatButton(right, "Copy", { tooltip = "Copy conversation",
        tooltipText = "Opens the whole conversation as plain text, ready to copy with Ctrl+C." })
    copy:SetPoint("RIGHT", chat, "LEFT", -4, 0)
    copy:SetScript("OnClick", function()
        if h.selected then
            ShowCopyLog("Conversation with " .. ShortName(h.selected), ConversationText(h.selected))
        end
    end)
    h.toolButtons = { del, gi, chat, copy }

    local sep = right:CreateTexture(nil, "ARTWORK")
    sep:SetTexture(WHITE)
    sep:SetVertexColor(0.16, 0.16, 0.2, 1)
    sep:SetPoint("TOPLEFT", 1, -32)
    sep:SetPoint("TOPRIGHT", -1, -32)
    sep:SetHeight(1)

    local view = CreateFrame("ScrollingMessageFrame", nil, right)
    view:SetPoint("TOPLEFT", 10, -40)
    view:SetPoint("BOTTOMRIGHT", -10, 8)
    view:SetFontObject(ChatFontNormal)
    view:SetJustifyH("LEFT")
    view:SetFading(false)
    view:SetMaxLines(5000)
    view:SetSpacing(2)
    view:EnableMouse(true)
    if view.SetIndentedWordWrap then view:SetIndentedWordWrap(true) end
    if view.SetHyperlinksEnabled then view:SetHyperlinksEnabled(true) end
    view:SetScript("OnHyperlinkClick", HandleLink)
    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", function(self, delta)
        if IsShiftKeyDown() then
            if delta > 0 then self:ScrollToTop() else self:ScrollToBottom() end
        else
            for _ = 1, 3 do if delta > 0 then self:ScrollUp() else self:ScrollDown() end end
        end
    end)
    h.view = view

    local empty = right:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER", 0, 0)
    empty:SetWidth(360)
    empty:SetTextColor(unpack(C.muted))
    h.empty = empty

    function h:BuildList()
        wipe(self.list)
        local q = self.filter
        for key, log in pairs(DB.log) do
            local match = q == "" or ShortName(key):lower():find(q, 1, true)
            if not match then
                for _, e in ipairs(log.entries) do
                    if e.m:lower():find(q, 1, true) then match = true; break end
                end
            end
            if match then self.list[#self.list + 1] = key end
        end
        table.sort(self.list, function(a, b) return (DB.log[a].last or 0) > (DB.log[b].last or 0) end)
    end

    function h:RefreshRows()
        for i, row in ipairs(self.rows) do
            local key = self.list[self.offset + i]
            row.key = key
            if key then
                local log = DB.log[key]
                local r, g, b = KeyRGB(key)
                row.name:SetText(Colorize(ShortName(key), r, g, b))
                local last = log.last or 0
                local when = (date("%Y%m%d", last) == date("%Y%m%d")) and date("%H:%M", last) or date("%d %b", last)
                row.info:SetText(when .. "  |cff8888aa" .. #log.entries .. "|r")
                local sel = key == self.selected
                row:SetBackdropColor(1, 1, 1, sel and 0.09 or 0)
                if sel then
                    row.bar:SetVertexColor(r or C.accent[1], g or C.accent[2], b or C.accent[3], 1)
                    row.bar:Show()
                else
                    row.bar:Hide()
                end
                row:Show()
            else
                row:Hide()
            end
        end
    end

    function h:ShowLog()
        self.view:Clear()
        local key = self.selected
        local log = key and DB.log[key]
        for _, b in ipairs(self.toolButtons) do b:SetShown(log ~= nil) end
        if not log then
            self.who:SetText("")
            if next(DB.log) == nil then
                self.empty:SetText(DB.logEnabled
                    and "No saved whispers yet.\nThey will appear here as you chat."
                    or "Whisper logging is OFF.\n\nClick |cffffd100Logging|r in the top bar (or type |cffffd100/dm log|r)\nto start saving whispers so you can read them here.")
            else
                self.empty:SetText("Select a conversation on the left.")
            end
            self.empty:Show()
            return
        end
        self.empty:Hide()
        local r, g, b = KeyRGB(key)
        self.who:SetText(Colorize(ShortName(key), r, g, b) .. "  |cff8888aa" .. #log.entries .. " messages|r")
        local lastDay
        local q = self.filter
        for _, e in ipairs(log.entries) do
            local day = date("%Y%m%d", e.t)
            if day ~= lastDay then
                self.view:AddMessage(" ")
                self.view:AddMessage(DayHeader(e.t))
                lastDay = day
            end
            local line = FormatEntry(key, e)
            if q ~= "" and e.m:lower():find(q, 1, true) then
                line = "|cffffd100>|r " .. line   -- mark search hits
            end
            self.view:AddMessage(line)
        end
        self.view:ScrollToBottom()
    end

    function h:Refresh()
        self:BuildList()
        if self.selected and not DB.log[self.selected] then self.selected = nil end
        if not self.selected and self.list[1] then self.selected = self.list[1] end
        self.offset = math.min(self.offset, math.max(0, #self.list - ROWS))
        self:RefreshRows()
        self:ShowLog()
    end

    h:SetScript("OnShow", function(self) self:UpdateToggle() end)
    hist = h
    return h
end

ShowHistory = function(name)
    local h = hist or CreateHistory()
    if name then
        h.selected = FullName(name)
        if h.selected and DB.log[h.selected] then
            -- make sure the selected contact is visible in the list
            h.offset = 0
        end
    end
    if h:IsShown() then h:UpdateToggle() else h:Show() end
    h:Raise()
end

----------------------------------------------------------------------
-- Whisper handling
----------------------------------------------------------------------
local function AddLine(key, text, incoming, guid)
    if incoming and guid then DB.guids[key] = guid end
    local entry = { t = time(), i = incoming or nil, m = text, me = (not incoming) and playerName or nil }
    local s = session[key] or {}
    s.t, s.text, s.incoming = entry.t, text, incoming
    s.lines = s.lines or {}
    session[key] = s

    -- Create/show the window BEFORE logging so the new line isn't replayed twice
    local f = windows[key]
    local wantOpen = not incoming or DB.autoOpen
    if DB.tabbed then
        if wantOpen or (f and IndexOf(tabOrder, key)) then
            if incoming then
                f = AddTab(key) -- new tab in the background (shows it if nothing is open)
            elseif key ~= activeKey or not f or not f:IsShown() then
                f = ActivateTab(key) -- you whispered someone: switch to them
            end
        end
    else
        if not f and wantOpen then
            f = GetWindow(key, true)
        elseif f and incoming and not f:IsShown() and DB.autoOpen then
            f:Show()
        end
    end
    -- remember the line for this session (after the window replayed old ones)
    local lines = s.lines
    lines[#lines + 1] = entry
    for _ = 1, #lines - SESSION_LINES do table.remove(lines, 1) end
    LogEntry(key, entry)
    if DB.logEnabled and hist and hist:IsShown() then hist:Refresh() end
    if not f then UpdateSessionUI(); return end

    local wasAtBottom = f.msg:AtBottom()
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
    if DB.tabbed then RefreshTabs() end
    UpdateSessionUI()
end

----------------------------------------------------------------------
-- /who results -> player profile (level, race, class, guild, zone)
----------------------------------------------------------------------
local function StoreProfile(name, data)
    if IsSecret(name) or AnySecret(data.level, data.race, data.class, data.guild, data.zone) then return end
    local key = FullName(name)
    if not key or not DB then return end
    -- only keep profiles for people we talk to (or just /who'd from a window)
    if not (windows[key] or session[key] or DB.log[key] or DB.profiles[key] or whoPending[key]) then return end
    whoPending[key] = nil
    data.t = time()
    data.classFile = data.classFile or ClassFileFromName(data.class)
    local hadClass = (KeyInfo(key)) ~= nil
    DB.profiles[key] = data
    local f = windows[key]
    if f then
        -- class just learned: redraw so their messages get the class colour
        if not hadClass and data.classFile then FillMessages(f) end
        UpdateTitle(f)
    end
    if DB.tabbed then RefreshTabs() end
    UpdateSessionUI()
    if hist and hist:IsShown() then hist:Refresh() end
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
                StoreProfile(w.fullName, { level = w.level, race = w.raceStr, class = w.classStr,
                    classFile = w.filename, guild = w.fullGuildName, zone = w.area })
            end
        elseif GetWhoInfo then
            local name, guild, level, race, class, zone, classFile = GetWhoInfo(i)
            if name then
                StoreProfile(name, { level = level, race = race, class = class,
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
    StoreProfile(name, { level = level, race = race, class = class or mid,
        classFile = classFile, guild = guild, zone = zone })
    return true
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LOGOUT")
events:RegisterEvent("WHO_LIST_UPDATE")
events:RegisterEvent("CHAT_MSG_SYSTEM")
events:RegisterEvent("CHAT_MSG_WHISPER")
events:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
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
        DB = DMmeDB
        DB.history = nil -- old always-on history from v1.0 (replaced by opt-in log)
        guidStore = function(key, guid) DB.guids[key] = guid end
        -- session list survives /reload (wiped on a fresh login, see PLAYER_ENTERING_WORLD)
        if type(DB.session) ~= "table" then DB.session = {} end
        session = DB.session
        self:UnregisterEvent("ADDON_LOADED")
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin = ...
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if DB and isInitialLogin then
            -- fresh login (not a /reload): start a new session, but keep any
            -- whispers that already arrived while the game was loading
            local now = time()
            for key, s in pairs(session) do
                if not s.t or now - s.t > 60 then session[key] = nil end
            end
        end
        UpdateSessionUI()
        return
    elseif event == "PLAYER_LOGOUT" then
        -- remember unread counts for the next /reload
        if DB then
            for key, f in pairs(windows) do
                if session[key] then session[key].unread = (f.unread or 0) > 0 and f.unread or nil end
            end
        end
        return
    elseif event == "WHO_LIST_UPDATE" then
        ReadWhoResults()
        return
    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if DB and not IsSecret(msg) and type(msg) == "string" and msg:find("|Hplayer:", 1, true) then
            if ParseWhoLine(msg) then
                -- the who list usually has the exact class too; read it next frame
                C_Timer.After(0, ReadWhoResults)
            end
        end
        return
    elseif event == "PLAYER_LOGIN" then
        if DB and not DB.minimap.hide then CreateMinimapButton() end
        -- Re-key data saved by older versions as "Name-<own realm>"
        if DB then
            for _, tbl in ipairs({ DB.log, DB.guids, DB.positions }) do
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
    if not DB then return end

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

    if event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER" then
        AddLine(key, text, true, guid)
        if DB.sound and SOUNDKIT and SOUNDKIT.TELL_MESSAGE then
            PlaySound(SOUNDKIT.TELL_MESSAGE)
        end
        if not DB.logEnabled and not DB.hintShown then
            DB.hintShown = true
            Print("Tip: type |cffffd100/dm log|r to save whisper history, and |cffffd100/dm history|r to browse it.")
        end
    else -- *_WHISPER_INFORM (you whispered someone)
        AddLine(key, text, false, guid)
    end
end)

-- Optionally hide whispers from the regular chat frames
if AddFilter then
    -- never hide a whisper DMme couldn't read (secret value): it would be lost
    local function filter(_, _, msg, sender)
        if AnySecret(msg, sender) then return false end
        return DB and DB.hideFromChat
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
    local function addEntries(owner, root, contextData)
        if not contextData then return end
        local name
        if contextData.bnetIDAccount then
            name = BNKeyFromID(contextData.bnetIDAccount) -- Battle.net friend
        elseif contextData.name then
            name = contextData.name
            if contextData.server and contextData.server ~= "" then
                name = name .. "-" .. contextData.server
            end
        end
        if not name then return end
        if not DB or not (DB.menu.guild or DB.menu.open) then return end
        root:CreateDivider()
        root:CreateTitle("DMme")
        if DB.menu.guild then
            root:CreateButton("Guild Invite", function() GuildInviteName(FullName(name)) end)
        end
        if DB.menu.open then
            root:CreateButton("Open Whisper Window", function() OpenWindow(name) end)
        end
    end
    for _, tag in ipairs({ "MENU_UNIT_FRIEND", "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY",
                           "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_TARGET", "MENU_UNIT_BN_FRIEND" }) do
        Menu.ModifyMenu(tag, addEntries)
    end
elseif UnitPopup_ShowMenu then
    -- Legacy UIDropDownMenu fallback
    local allowed = { FRIEND = true, PLAYER = true, PARTY = true, RAID_PLAYER = true, TARGET = true }
    hooksecurefunc("UnitPopup_ShowMenu", function(dropdown, which, unit, name, userData)
        if not allowed[which] or UIDROPDOWNMENU_MENU_LEVEL ~= 1 then return end
        local target = name or (unit and GetUnitName(unit, true))
        if not target or target == playerName then return end
        local server = dropdown and dropdown.server
        if server and server ~= "" and not target:find("-", 1, true) then
            target = target .. "-" .. server
        end

        if not DB then return end
        if DB.menu.guild then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Guild Invite"
            info.notCheckable = true
            info.func = function() GuildInviteName(FullName(target)) end
            UIDropDownMenu_AddButton(info, 1)
        end
        if DB.menu.open then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "Open Whisper Window"
            info.notCheckable = true
            info.func = function() OpenWindow(target) end
            UIDropDownMenu_AddButton(info, 1)
        end
    end)
end

----------------------------------------------------------------------
-- Shift-click item links into a focused DMme edit box
----------------------------------------------------------------------
if ChatEdit_InsertLink then
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        for _, f in pairs(windows) do
            if f:IsShown() and f.edit:HasFocus() then
                f.edit:Insert(link)
                return
            end
        end
    end)
end

----------------------------------------------------------------------
-- Session list + minimap button
----------------------------------------------------------------------
local mmButton, sessionPanel
local LIST_ROWS, LIST_ROW_H = 10, 36

local function IsActiveConversation(key)
    if DB.tabbed then return IndexOf(tabOrder, key) ~= nil end
    local f = windows[key]
    return f and f:IsShown() or false
end

local function SessionKeys()
    local list = {}
    for key in pairs(session) do list[#list + 1] = key end
    table.sort(list, function(a, b) return session[a].t > session[b].t end)
    return list
end

-- Number of conversations (windows/tabs) that have unread whispers.
local function UnreadConversations()
    local n = 0
    for key in pairs(windows) do
        if KeyUnread(key) > 0 then n = n + 1 end
    end
    for key in pairs(session) do -- conversations without a window yet (after /reload)
        if not windows[key] and KeyUnread(key) > 0 then n = n + 1 end
    end
    return n
end

local function Ago(t)
    local d = time() - t
    if d < 60 then return "now" end
    if d < 3600 then return math.floor(d / 60) .. "m" end
    return date("%H:%M", t)
end

-- Remove a conversation from the session: close its tab/window and clear it.
local function RemoveSession(key)
    session[key] = nil
    local f = windows[key]
    if DB.tabbed and IndexOf(tabOrder, key) then
        CloseTab(key)
    elseif f then
        f:Hide()
    end
    if f then
        f.msg:Clear()
        f.unread = 0
        f.jump:Hide()
        if f.flashAnim:IsPlaying() then f.flashAnim:Stop() end
        f.glow:Hide()
    end
    UpdateSessionUI()
end

local function ClearSession()
    for _, key in ipairs(SessionKeys()) do RemoveSession(key) end
end

local function CreateSessionPanel()
    local p = CreateFrame("Frame", "DMmeSessionList", UIParent, BACKDROP_TEMPLATE)
    p:SetWidth(290)
    p:SetBackdrop(FLAT)
    p:SetBackdropColor(unpack(C.bg))
    p:SetBackdropBorderColor(unpack(C.border))
    p:SetFrameStrata("DIALOG")
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:Hide()
    tinsert(UISpecialFrames, "DMmeSessionList")
    p.offset = 0

    local shadow = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetTexture(WHITE)
    shadow:SetVertexColor(0, 0, 0, 0.35)
    shadow:SetPoint("TOPLEFT", -3, 3)
    shadow:SetPoint("BOTTOMRIGHT", 4, -4)

    local header = p:CreateTexture(nil, "BORDER")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(28)
    SetGradientV(header, C.header, C.header2)
    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    OnUIAccent(function(r, g, b) line:SetVertexColor(r, g, b, 0.9) end)
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    line:SetHeight(1)

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", p, "TOPLEFT", 10, -15)
    title:SetText("Whispers this session")

    local close = FlatButton(p, "x", { bare = true, width = 20, height = 20,
        font = "GameFontHighlight", hoverColor = { 0.9, 0.25, 0.25 } })
    close:SetPoint("TOPRIGHT", -4, -5)
    close:SetScript("OnClick", function() p:Hide() end)

    local clear = FlatButton(p, "Clear all", { hoverColor = { 0.9, 0.25, 0.25 },
        tooltip = "Clear all", tooltipText = "Remove every conversation from this list and close their windows.\n(Saved history is not deleted.)" })
    clear:SetPoint("RIGHT", close, "LEFT", -4, 0)
    clear:SetScript("OnClick", ClearSession)

    p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    p.empty:SetPoint("TOP", 0, -48)
    p.empty:SetText("No whispers yet this session.")

    p.rows = {}
    for i = 1, LIST_ROWS do
        local r = CreateFrame("Button", nil, p, BACKDROP_TEMPLATE)
        r:SetHeight(LIST_ROW_H)
        r:SetPoint("TOPLEFT", 4, -(34 + (i - 1) * LIST_ROW_H))
        r:SetPoint("TOPRIGHT", -4, -(34 + (i - 1) * LIST_ROW_H))
        r:SetBackdrop({ bgFile = WHITE })
        r:SetBackdropColor(0, 0, 0, 0)

        r.bar = r:CreateTexture(nil, "ARTWORK") -- green bar = open conversation
        r.bar:SetTexture(WHITE)
        r.bar:SetVertexColor(0.3, 0.9, 0.4, 1)
        r.bar:SetPoint("TOPLEFT", 0, -4)
        r.bar:SetPoint("BOTTOMLEFT", 0, 4)
        r.bar:SetWidth(2)

        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(22, 22)
        r.icon:SetPoint("LEFT", 8, 0)

        r.del = FlatButton(r, "x", { bare = true, width = 18, height = 18, hoverColor = { 0.9, 0.25, 0.25 },
            tooltip = "Remove", tooltipText = "Remove from this list and close the conversation." })
        r.del:SetPoint("RIGHT", -2, 0)
        r.del:SetScript("OnClick", function() if r.key then RemoveSession(r.key) end end)

        r.when = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.when:SetPoint("TOPRIGHT", r.del, "TOPLEFT", -4, -1)
        r.when:SetTextColor(unpack(C.muted))

        r.badge = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.badge:SetPoint("BOTTOMRIGHT", r.del, "BOTTOMLEFT", -4, 0)

        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, 1)
        r.name:SetPoint("RIGHT", r.when, "LEFT", -6, 0)
        r.name:SetJustifyH("LEFT")
        r.name:SetWordWrap(false)

        r.preview = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.preview:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 8, -1)
        r.preview:SetPoint("RIGHT", r.badge, "LEFT", -6, 0)
        r.preview:SetJustifyH("LEFT")
        r.preview:SetWordWrap(false)

        r:SetScript("OnEnter", function(self) self:SetBackdropColor(1, 1, 1, 0.06) end)
        r:SetScript("OnLeave", function(self) self:SetBackdropColor(0, 0, 0, 0) end)
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetScript("OnClick", function(self, button)
            if not self.key then return end
            if button == "RightButton" then
                ShowPlayerMenu(self.key)
            else
                OpenWindow(self.key); p:Hide()
            end
        end)
        p.rows[i] = r
    end

    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(self, delta)
        local n = 0
        for _ in pairs(session) do n = n + 1 end
        self.offset = math.min(math.max(0, n - LIST_ROWS), math.max(0, self.offset - delta))
        self:Refresh()
    end)

    function p:Refresh()
        local keys = SessionKeys()
        self.offset = math.min(self.offset, math.max(0, #keys - LIST_ROWS))
        local shown = math.min(#keys, LIST_ROWS)
        self.empty:SetShown(#keys == 0)
        for i, r in ipairs(self.rows) do
            local key = keys[self.offset + i]
            r.key = key
            if key then
                local s = session[key]
                local f = windows[key]
                local classFile = KeyInfo(key)
                local cr, cg, cb = KeyRGB(key)
                r.name:SetText(Colorize(ShortName(key), cr, cg, cb))
                r.when:SetText(Ago(s.t))
                local text = s.text or ""
                if s.incoming then
                    local tr, tg, tb = KeyTextRGB(key)
                    r.preview:SetText(Colorize(text, tr * 0.8, tg * 0.8, tb * 0.8)) -- a bit dimmer than the name
                else
                    r.preview:SetText("|cff8a8a98You: " .. text .. "|r")
                end
                local unread = KeyUnread(key)
                r.badge:SetText(unread > 0 and KeyColorize(key, unread .. " new") or "")
                r.bar:SetShown(IsActiveConversation(key))
                if IsBN(key) then
                    r.icon:SetTexture("Interface\\FriendsFrame\\Battlenet-Battleneticon")
                    r.icon:SetTexCoord(0, 1, 0, 1)
                elseif classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
                    r.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
                    r.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[classFile]))
                else
                    r.icon:SetTexture("Interface\\Icons\\INV_Letter_15")
                    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                end
                r:Show()
            else
                r:Hide()
            end
        end
        self:SetHeight(34 + math.max(shown, 1) * LIST_ROW_H + (shown == 0 and 20 or 6))
    end

    sessionPanel = p
    return p
end

-- Tooltip with the latest conversations (minimap button + addon compartment).
local function ShowSessionTooltip(owner, anchorPoint, isMinimapButton)
    GameTooltip:SetOwner(owner, anchorPoint or "ANCHOR_LEFT")
    GameTooltip:SetText("DMme", UIAccent())
    local keys = SessionKeys()
    if #keys == 0 then
        GameTooltip:AddLine("No whispers yet this session.", 0.6, 0.6, 0.65)
    else
        for i = 1, math.min(5, #keys) do
            local key = keys[i]
            local unread = KeyUnread(key)
            local cr, cg, cb = KeyRGB(key)
            GameTooltip:AddDoubleLine(ShortName(key) .. (unread > 0 and ("  " .. KeyColorize(key, "(" .. unread .. ")")) or ""),
                Ago(session[key].t), cr or 1, cg or 1, cb or 1, 0.6, 0.6, 0.65)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd100Left-click|r  whisper list", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffd100Right-click|r  settings", 0.8, 0.8, 0.8)
    if isMinimapButton then
        GameTooltip:AddLine("|cffffd100Drag|r  move button" .. (DB.minimap.detached and " (anywhere)" or ""), 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

-- anchor: frame to open next to (default: the minimap button)
local function ToggleSessionPanel(anchor)
    local p = sessionPanel or CreateSessionPanel()
    if p:IsShown() then p:Hide(); return end
    p:SetScale(DB.scale or 1)
    p:ClearAllPoints()
    if not (anchor and anchor.GetCenter) then
        anchor = (mmButton and mmButton:IsShown()) and mmButton or nil
    end
    -- open towards the middle of the screen
    local x = anchor and anchor:GetCenter()
    if not x then
        p:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -200)
    elseif x > UIParent:GetWidth() / 2 then
        p:SetPoint("TOPRIGHT", anchor, "BOTTOMLEFT", 0, 0)
    else
        p:SetPoint("TOPLEFT", anchor, "BOTTOMRIGHT", 0, 0)
    end
    p.offset = 0
    p:Refresh()
    p:Show()
    p:Raise()
end

local function PositionMinimapButton()
    local b = mmButton
    b:ClearAllPoints()
    if DB.minimap.detached then
        if b:GetParent() ~= UIParent then b:SetParent(UIParent) end
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        local p = DB.minimap.pos
        if p then
            b:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        else
            b:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -40)
        end
    else
        if b:GetParent() ~= Minimap then b:SetParent(Minimap) end
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        local angle = math.rad(DB.minimap.angle or 200)
        local r = (Minimap:GetWidth() / 2) + 5
        b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
    end
end

-- Detach the button from the minimap (free-floating) or snap it back.
local function SetMinimapDetached(detached)
    DB.minimap.detached = detached and true or false
    if mmButton and detached and not DB.minimap.pos then
        -- start floating exactly where it is now
        local x, y = mmButton:GetCenter()
        if x then
            local s = mmButton:GetEffectiveScale() / UIParent:GetEffectiveScale()
            DB.minimap.pos = { "CENTER", "BOTTOMLEFT", x * s, y * s }
        end
    end
    if mmButton then PositionMinimapButton() end
end

CreateMinimapButton = function()
    if mmButton or not Minimap then return end
    local b = CreateFrame("Button", "DMmeMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture(MEDIA_ICON)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    -- unread badge
    local badge = CreateFrame("Frame", nil, b, BACKDROP_TEMPLATE)
    badge:SetSize(16, 14)
    badge:SetPoint("TOPRIGHT", 2, 2)
    badge:SetFrameLevel(b:GetFrameLevel() + 2)
    badge:SetBackdrop(FLAT)
    badge:SetBackdropColor(0.85, 0.25, 0.85, 1)
    badge:SetBackdropBorderColor(0, 0, 0, 1)
    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    badge.text:SetPoint("CENTER", 0, 0)
    badge:Hide()
    b.badge = badge

    -- pulsing pink glow while there are unread whispers
    local glow = b:CreateTexture(nil, "OVERLAY", nil, 7)
    glow:SetSize(31, 31)
    glow:SetPoint("TOPLEFT", 0, 0)
    glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    glow:SetBlendMode("ADD")
    glow:SetVertexColor(1, 0.35, 1, 1)
    glow:SetAlpha(0)
    local pulse = glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local pa = pulse:CreateAnimation("Alpha")
    pa:SetFromAlpha(0)
    pa:SetToAlpha(1)
    pa:SetDuration(0.6)
    pa:SetSmoothing("IN_OUT")
    pulse:SetScript("OnStop", function() glow:SetAlpha(0) end)
    b.glow, b.pulse = glow, pulse

    -- the badge pops a little each time a new whisper arrives
    local pop = badge:CreateAnimationGroup()
    local ps = pop:CreateAnimation("Scale")
    if ps.SetScaleFrom then
        ps:SetScaleFrom(1.6, 1.6)
        ps:SetScaleTo(1, 1)
    else
        ps:SetFromScale(1.6, 1.6)
        ps:SetToScale(1, 1)
    end
    ps:SetDuration(0.25)
    ps:SetSmoothing("OUT")
    b.pop = pop

    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ShowSettings() else ToggleSessionPanel() end
    end)
    b:SetMovable(true)
    b:SetClampedToScreen(true)
    -- we save the position ourselves; don't let the game's layout cache fight us
    if b.SetDontSavePosition then b:SetDontSavePosition(true) end
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        if DB.minimap.detached then
            self:StartMoving() -- free-floating: drag anywhere
            return
        end
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            DB.minimap.angle = math.deg(math.atan2(py / s - my, px / s - mx))
            PositionMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if DB.minimap.detached then
            self:StopMovingOrSizing()
            local point, _, relPoint, x, y = self:GetPoint(1)
            DB.minimap.pos = { point, relPoint, x, y }
        end
    end)
    b:SetScript("OnEnter", function(self) ShowSessionTooltip(self, "ANCHOR_LEFT", true) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    mmButton = b
    PositionMinimapButton()
end

local function SetMinimapShown(show)
    DB.minimap.hide = not show
    if show then
        CreateMinimapButton()
        if mmButton then mmButton:Show() end
    elseif mmButton then
        mmButton:Hide()
    end
end

UpdateSessionUI = function()
    if not DB then return end
    if mmButton then
        local b = mmButton
        local n = UnreadConversations()
        if n > 0 then
            b.badge.text:SetText(n > 9 and "9+" or n)
            b.badge:Show()
            if n > (b.lastUnread or 0) then b.pop:Play() end -- a new window has unread
            if not b.pulse:IsPlaying() then b.pulse:Play() end
        else
            b.badge:Hide()
            if b.pulse:IsPlaying() then b.pulse:Stop() end
        end
        b.lastUnread = n
    end
    if sessionPanel and sessionPanel:IsShown() then sessionPanel:Refresh() end
end

----------------------------------------------------------------------
-- Settings panel
----------------------------------------------------------------------
local settings

local function ApplyScale(s)
    s = math.floor(s * 100 + 0.5) / 100
    DB.scale = s
    for _, f in pairs(windows) do f:SetScale(s) end
    if hist then hist:SetScale(s) end
    if settings then settings:SetScale(s) end
    if DB.tabbed then RefreshTabs() end
end

local function RelayoutAllButtons()
    for _, f in pairs(windows) do LayoutButtons(f) end
end

local function CreateSettings()
    local s = CreateFrame("Frame", "DMmeSettings", UIParent, BACKDROP_TEMPLATE)
    s:SetWidth(340)
    s:SetPoint("CENTER")
    s:SetBackdrop(FLAT)
    s:SetBackdropColor(unpack(C.bg))
    s:SetBackdropBorderColor(unpack(C.border))
    s:SetFrameStrata("DIALOG")
    s:SetToplevel(true)
    s:SetClampedToScreen(true)
    s:SetScale(DB.scale or 1)
    s:EnableMouse(true)
    s:SetMovable(true)
    s:RegisterForDrag("LeftButton")
    s:SetScript("OnDragStart", s.StartMoving)
    s:SetScript("OnDragStop", s.StopMovingOrSizing)
    tinsert(UISpecialFrames, "DMmeSettings")

    local shadow = s:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetTexture(WHITE)
    shadow:SetVertexColor(0, 0, 0, 0.35)
    shadow:SetPoint("TOPLEFT", -3, 3)
    shadow:SetPoint("BOTTOMRIGHT", 4, -4)

    local header = s:CreateTexture(nil, "BORDER")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H - 2)
    SetGradientV(header, C.header, C.header2)
    local line = s:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    OnUIAccent(function(r, g, b) line:SetVertexColor(r, g, b, 0.9) end)
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    line:SetHeight(1)

    local icon = s:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22)
    icon:SetPoint("LEFT", s, "TOPLEFT", 8, -(HEADER_H / 2))
    icon:SetTexture(MEDIA_GEAR)
    OnUIAccent(function(r, g, b) icon:SetVertexColor(r, g, b) end)
    local title = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText("DMme Settings")

    local close = FlatButton(s, "x", { bare = true, width = 20, height = 20,
        font = "GameFontHighlight", hoverColor = { 0.9, 0.25, 0.25 } })
    close:SetPoint("TOPRIGHT", -6, -7)
    close:SetScript("OnClick", function() s:Hide() end)

    local y = -(HEADER_H + 10)
    local checks = {}

    local function Section(text)
        y = y - 6
        local fs = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", 14, y)
        fs:SetText(text:upper())
        OnUIAccent(function(r, g, b) fs:SetTextColor(r, g, b) end)
        local l = s:CreateTexture(nil, "ARTWORK")
        l:SetTexture(WHITE)
        l:SetVertexColor(0.2, 0.2, 0.25, 1)
        l:SetPoint("LEFT", fs, "RIGHT", 8, 0)
        l:SetPoint("RIGHT", s, "RIGHT", -14, 0)
        l:SetHeight(1)
        y = y - 20
    end

    local function Check(label, tip, get, set)
        local b = CreateFrame("Button", nil, s)
        b:SetPoint("TOPLEFT", 16, y)
        b:SetPoint("RIGHT", s, "RIGHT", -16, 0)
        b:SetHeight(20)
        local box = CreateFrame("Frame", nil, b, BACKDROP_TEMPLATE)
        box:SetSize(14, 14)
        box:SetPoint("LEFT", 0, 0)
        box:SetBackdrop(FLAT)
        box:SetBackdropColor(0.09, 0.09, 0.11, 1)
        box:SetBackdropBorderColor(unpack(C.border))
        local fill = box:CreateTexture(nil, "ARTWORK")
        fill:SetTexture(WHITE)
        fill:SetPoint("TOPLEFT", 3, -3)
        fill:SetPoint("BOTTOMRIGHT", -3, 3)
        OnUIAccent(function(r, g, b) fill:SetVertexColor(r, g, b, 1) end)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", box, "RIGHT", 8, 0)
        fs:SetPoint("RIGHT", 0, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText(label)
        b.Refresh = function()
            local on = get()
            fill:SetShown(on)
            fs:SetTextColor(on and 1 or 0.7, on and 1 or 0.7, on and 1 or 0.75)
        end
        b:SetScript("OnClick", function()
            set(not get())
            for _, c in ipairs(checks) do c.Refresh() end
        end)
        b:SetScript("OnEnter", function(self)
            box:SetBackdropBorderColor(UIAccent())
            if tip then ShowTooltip(self, label, tip) end
        end)
        b:SetScript("OnLeave", function()
            box:SetBackdropBorderColor(unpack(C.border))
            GameTooltip:Hide()
        end)
        checks[#checks + 1] = b
        y = y - 22
        return b
    end

    -- Window
    Section("Window")
    Check("Tabbed window", "Put all whisper conversations in one window with a tab per player.\nRight-click a tab to close it.",
        function() return DB.tabbed end, SetTabbed)
    Check("Open automatically on new whisper", nil,
        function() return DB.autoOpen end, function(v) DB.autoOpen = v end)
    Check("Play sound on new whisper", nil,
        function() return DB.sound end, function(v) DB.sound = v end)
    Check("Hide whispers from the main chat", "Whispers only show in DMme, not in your normal chat tabs.",
        function() return DB.hideFromChat end, function(v) DB.hideFromChat = v end)
    Check("Class colors instead of pink", "Whisper text, unread markers, tabs and list previews use the player's class color.\n(Pink is used until their class is known. Battle.net friends are blue.)",
        function() return DB.classColors end, function(v) DB.classColors = v; RecolorAll() end)
    Check("Show minimap button", "Left-click: list of this session's whispers.\nRight-click: settings. Drag to move it.",
        function() return not DB.minimap.hide end, SetMinimapShown)
    Check("Detach button from minimap", "Lets you drag the button anywhere on your screen.\nTurn off to snap it back to the minimap edge.",
        function() return DB.minimap.detached end, SetMinimapDetached)

    -- Scale row
    local scaleLabel = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    scaleLabel:SetPoint("TOPLEFT", 16, y - 3)
    scaleLabel:SetText("Window scale")
    local plus = FlatButton(s, "+", { width = 22 })
    plus:SetPoint("TOPRIGHT", -16, y)
    local value = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    value:SetPoint("RIGHT", plus, "LEFT", -8, 0)
    value:SetWidth(40)
    local minus = FlatButton(s, "-", { width = 22 })
    minus:SetPoint("RIGHT", value, "LEFT", -8, 0)
    local function showScale() value:SetText(string.format("%.2f", DB.scale or 1)) end
    plus:SetScript("OnClick", function() ApplyScale(math.min(1.5, (DB.scale or 1) + 0.05)); showScale() end)
    minus:SetScript("OnClick", function() ApplyScale(math.max(0.6, (DB.scale or 1) - 0.05)); showScale() end)
    y = y - 28

    -- Buttons
    Section("Window buttons")
    local function ButtonCheck(id, label, tip)
        Check(label, tip, function() return DB.buttons[id] end,
            function(v) DB.buttons[id] = v; RelayoutAllButtons() end)
    end
    ButtonCheck("guild", "Guild Invite", "Shows the /ginvite command ready to copy and paste.\n(The game blocks addons from sending guild invites.)")
    ButtonCheck("party", "Party Invite")
    ButtonCheck("who", "Who")
    ButtonCheck("history", "History")

    -- Right-click menu
    Section("Right-click menu on names")
    Check("Guild Invite", "Adds Guild Invite to the right-click menu on player names.",
        function() return DB.menu.guild end, function(v) DB.menu.guild = v end)
    Check("Open Whisper Window", nil,
        function() return DB.menu.open end, function(v) DB.menu.open = v end)

    -- History
    Section("History")
    Check("Save whisper history", "Saves whispers to disk so you can read them later in the History window. Off by default.",
        function() return DB.logEnabled end, SetLogging)
    local open = FlatButton(s, "Open History", { width = 110 })
    open:SetPoint("TOPLEFT", 16, y - 4)
    open:SetScript("OnClick", function() ShowHistory() end)
    y = y - 34

    s:SetHeight(-y + 6)

    function s:Refresh()
        for _, c in ipairs(checks) do c.Refresh() end
        showScale()
    end
    s:SetScript("OnShow", function(self) self:Refresh() end)
    settings = s
    return s
end

ShowSettings = function()
    local s = settings or CreateSettings()
    s:Refresh()
    s:Show()
    s:Raise()
end

-- Entry in the game's AddOns options (Esc > Options > AddOns)
do
    local panel = CreateFrame("Frame")
    panel.name = "DMme"
    local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 16, -16)
    t:SetText("DMme")
    local d = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -8)
    d:SetText("Whisper windows, tabs, buttons and history.")
    local b = FlatButton(panel, "Open DMme Settings", { width = 200, height = 24 })
    b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -14)
    b:SetScript("OnClick", function() ShowSettings() end)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        local cat = Settings.RegisterCanvasLayoutCategory(panel, "DMme")
        Settings.RegisterAddOnCategory(cat)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

----------------------------------------------------------------------
-- Slash commands
----------------------------------------------------------------------
SLASH_DMME1 = "/dm"
SLASH_DMME2 = "/dmme"
SlashCmdList.DMME = function(input)
    local cmd, rest = (input or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" or cmd == "config" or cmd == "settings" or cmd == "options" then
        ShowSettings()
    elseif cmd == "minimap" then
        SetMinimapShown(DB.minimap.hide)
        Print("Minimap button: " .. (DB.minimap.hide and "hidden" or "shown"))
        if settings and settings:IsShown() then settings:Refresh() end
    elseif cmd == "detach" then
        SetMinimapDetached(not DB.minimap.detached)
        Print("Minimap button: " .. (DB.minimap.detached and "detached - drag it anywhere" or "attached to the minimap"))
        if settings and settings:IsShown() then settings:Refresh() end
    elseif cmd == "list" or cmd == "session" then
        ToggleSessionPanel()
    elseif cmd == "tabs" then
        SetTabbed(not DB.tabbed)
        if settings and settings:IsShown() then settings:Refresh() end
    elseif cmd == "open" or cmd == "w" then
        if rest ~= "" then OpenWindow(rest) else Print("Usage: /dm open <name>") end
    elseif cmd == "ginvite" or cmd == "gi" then
        if rest ~= "" then GuildInviteName(FullName(rest)) else Print("Usage: /dm ginvite <name>") end
    elseif cmd == "hide" then
        DB.hideFromChat = not DB.hideFromChat
        Print("Hide whispers from main chat: " .. (DB.hideFromChat and "ON" or "OFF"))
    elseif cmd == "sound" then
        DB.sound = not DB.sound
        Print("Whisper sound: " .. (DB.sound and "ON" or "OFF"))
    elseif cmd == "auto" then
        DB.autoOpen = not DB.autoOpen
        Print("Auto-open windows on whisper: " .. (DB.autoOpen and "ON" or "OFF"))
    elseif cmd == "scale" then
        local s = tonumber(rest)
        if s and s >= 0.5 and s <= 2 then
            ApplyScale(s)
            Print("Window scale set to " .. DB.scale .. ".")
        else
            Print("Usage: /dm scale <0.5 - 2>  (now " .. (DB.scale or 1) .. ")")
        end
    elseif cmd == "log" then
        local r = rest:lower()
        if r == "on" then SetLogging(true)
        elseif r == "off" then SetLogging(false)
        else SetLogging(not DB.logEnabled) end
    elseif cmd == "history" or cmd == "h" then
        ShowHistory(rest ~= "" and rest or nil)
    elseif cmd == "clear" then
        if rest ~= "" then
            local key = FullName(rest)
            DB.log[key] = nil
            Print("Deleted saved log for " .. rest .. ".")
        else
            wipe(DB.log)
            Print("Deleted all saved whisper logs.")
        end
        if hist and hist:IsShown() then hist:Refresh() end
    elseif cmd == "reset" then
        wipe(DB.positions)
        DB.tabPos = nil
        for _, f in pairs(windows) do ApplyPosition(f) end
        if DB.tabbed then RefreshTabs() end
        Print("Window positions reset.")
    elseif cmd == "closeall" then
        CloseAllWindows()
    else
        Print("Commands:")
        Print("  /dm - open settings")
        Print("  /dm tabs - toggle tabbed window (now " .. (DB.tabbed and "ON" or "OFF") .. ")")
        Print("  /dm list - this session's whispers")
        Print("  /dm minimap - show/hide the minimap button")
        Print("  /dm detach - detach/attach the minimap button")
        Print("  /dm open <name> - open a whisper window")
        Print("  /dm ginvite <name> - show the /ginvite command to copy")
        Print("  /dm hide - toggle hiding whispers from main chat (now " .. (DB.hideFromChat and "ON" or "OFF") .. ")")
        Print("  /dm sound - toggle whisper sound (now " .. (DB.sound and "ON" or "OFF") .. ")")
        Print("  /dm auto - toggle auto-open on whisper (now " .. (DB.autoOpen and "ON" or "OFF") .. ")")
        Print("  /dm scale <n> - window scale (now " .. (DB.scale or 1) .. ")")
        Print("  /dm log [on|off] - save whispers to disk (now " .. (DB.logEnabled and "ON" or "OFF") .. ")")
        Print("  /dm history [name] - browse saved whispers")
        Print("  /dm clear [name] - delete saved logs")
        Print("  /dm reset | closeall")
    end
end

----------------------------------------------------------------------
-- Retail addon compartment (the addon menu next to the minimap).
-- Wired up in DMme.toc; clients without the compartment ignore it.
----------------------------------------------------------------------
function DMme_OnAddonCompartmentClick(_, mouseButton, menuButtonFrame)
    if not DB then return end
    if mouseButton == "RightButton" then
        ShowSettings()
    else
        ToggleSessionPanel(menuButtonFrame)
    end
end

function DMme_OnAddonCompartmentEnter(_, menuButtonFrame)
    if DB and menuButtonFrame then ShowSessionTooltip(menuButtonFrame, "ANCHOR_LEFT") end
end

function DMme_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
