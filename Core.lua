-- DMme: every whisper (and Battle.net whisper) in its own window or tab,
-- with class colours, /who profiles, a minimap session list, optional
-- history and a settings panel. Works on Retail and Forever.
local ADDON, ns = ...

local defaults = {
    hideFromChat = false, -- hide whispers from the normal chat frames
    sound = true,         -- play a sound on incoming whispers
    soundKit = "TELL_MESSAGE", -- which sound (a SOUNDKIT name, see SOUND_OPTIONS)
    soundKitBN = "SAME",  -- Battle.net whisper sound ("SAME" = same as soundKit)
    autoOpen = true,      -- open a window automatically on incoming whispers
    combatHold = true,    -- in combat: don't pop windows open, open them when combat ends
    spamFilter = true,    -- drop whispers that contain a spam word (see DB.spamWords)
    fontSize = nil,       -- message text size (nil = the game's chat font size)
    emoji = true,         -- show emoji pictures for :) <3 :fire: ... and real emoji
    listMode = "recent",  -- whisper list tab: "recent" (this session) or "friends" (online friends)
    logEnabled = false,   -- OPT-IN: save whispers to disk (SavedVariables)
    logMax = 2000,        -- max saved messages per contact
    logKeep = "forever",  -- how long history is kept: day / week / month / year / forever
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
        replies = true,   -- quick replies
    },
    replyShiftSend = true, -- quick replies: Shift-click sends, a plain click only fills the box
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
    floatButton = {       -- a separate DMme button on the screen (minimap-button bag addons leave it alone)
        show = false,
        size = 36,        -- pixels (the minimap button is 31)
        locked = false,   -- true = can't be dragged or resized by accident
        -- pos = { x, y }  (centre, in screen units)
    },
    log = {},             -- [fullName] = { last = time, entries = { { t, i, m, me } } }
    positions = {},       -- [fullName] = { point, x, y, w, h, minimized }
    guids = {},           -- [fullName] = guid (for class colour / icon)
    classColors = true,   -- colour whispers/unread markers by class instead of pink
    profiles = {},        -- [fullName] = last /who result { level, race, class, classFile, guild, zone, t }
    theme = "modern",     -- "modern" (flat dark) or "classic" (game-style, like the guild chat window)
}

-- shared between files: ns.DB
local windows = {}      -- [fullName] = frame
ns.windowCount = 0
-- Your character's name as whispers use it. On Forever characters have
-- two-part names ("Magic Mageen") and UnitName gives the two parts as two
-- values; on Retail the second value is a realm, which is never returned for
-- yourself. So a second value for "player" means this client uses two-part names.
local function TwoPartNames()
    local _, second = UnitName("player")
    return second ~= nil and second ~= ""
end
local playerName = UnitName("player")
if TwoPartNames() then playerName = playerName .. " " .. select(2, UnitName("player")) end
-- forward declarations (defined further down)
-- shared between files: ns.ShowHistory, ns.ShowSettings, ns.ActivateTab, ns.CloseTab, ns.RefreshTabs, ns.UpdateSessionUI
-- shared between files: ns.CreateMinimapButton, ns.OpenWindow, ns.StoreProfile
-- shared between files: ns.settings -- the Settings frame (created on first open)

-- Conversations from this session: [key] = { t, text, incoming, lines = { entries }, unread }
-- Saved in DMmeDB.session so it survives /reload; wiped on a fresh login.
ns.session = {}
local SESSION_LINES = 200 -- messages kept per conversation for the session

-- Unread count for a conversation (window if it exists, else saved session value)
local function KeyUnread(key)
    local f = windows[key]
    if f then return f.unread or 0 end
    local s = ns.session[key]
    return s and s.unread or 0
end
-- Players we sent a /who for from a DMme button: [key] = time
local whoPending = {}
-- /who sent for a Battle.net friend's character: [characterKey] = "BN:..." key
local whoAlias = {}

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
    frameBorder = { 0.20, 0.20, 0.25, 1 },  -- outer window border
    insetBorder = { 0.13, 0.13, 0.16, 1 },  -- message area / list border
    inputBg  = { 0.09, 0.09, 0.11, 1 },     -- edit boxes, check boxes
    listBg   = { 0.07, 0.07, 0.09, 0.98 },  -- dropdown list
    btnText  = { 0.85, 0.85, 0.9 },         -- button label
    sep      = { 0.2, 0.2, 0.25, 1 },       -- separator lines
    tabOn    = { 0.055, 0.055, 0.07, 0.94 },
    tabOff   = { 0.07, 0.07, 0.09, 0.95 },
    tabHover = { 0.12, 0.12, 0.15, 0.95 },
}

----------------------------------------------------------------------
-- Themes (Settings > Look > Theme):
--   "modern"   = Dark: DMme's flat dark look (the palette above)
--   "classic"  = Forever: like the game's classic windows (gold dialog
--                border, tooltip-style insets, red buttons with gold text)
--   "midnight" = Midnight: like the current game's dark-metal windows
-- "classic" and "midnight" are both "game style": they also use the game's
-- check boxes and chat-style lines ("[Name] whispers: ...").
-- The C tables are changed in place, so code that reads C at draw time picks
-- the theme up automatically; things set once at creation register with
-- OnTheme() and are re-run when the theme changes.
----------------------------------------------------------------------
local THEME_OPTIONS = {
    { id = "modern",   label = "Dark" },
    { id = "classic",  label = "Forever" },
    { id = "midnight", label = "Midnight" },
}
local PALETTE = { modern = {} }
for k, v in pairs(C) do PALETTE.modern[k] = { unpack(v) } end
PALETTE.classic = {
    bg       = { 0.07, 0.07, 0.08, 0.97 },    -- dark, nearly opaque, like the guild window
    header   = { 0.16, 0.13, 0.09, 0.85 },
    header2  = { 0.05, 0.04, 0.03, 0.85 },
    border   = { 0.55, 0.55, 0.55, 1 },       -- tint on the tooltip border
    frameBorder = { 1, 1, 1, 1 },             -- gold dialog border, untinted
    inset    = { 0, 0, 0, 0.6 },
    insetBorder = { 0.6, 0.6, 0.6, 1 },
    inputBg  = { 0, 0, 0, 0.75 },
    listBg   = { 0.02, 0.02, 0.02, 0.97 },
    button   = { 0.40, 0.05, 0.02, 1 },
    buttonHi = { 0.62, 0.09, 0.04, 1 },
    btnText  = { 1, 0.82, 0 },
    muted    = { 0.62, 0.6, 0.52 },
    accent   = { 1, 0.82, 0 },                -- gold instead of pink
    sep      = { 0.55, 0.45, 0.2, 0.7 },
    tabOn    = { 0.12, 0.1, 0.07, 0.97 },
    tabOff   = { 0.03, 0.03, 0.03, 0.92 },
    tabHover = { 0.14, 0.11, 0.07, 0.95 },
}
-- Midnight: the Forever look with a dark steel border and cooler, bluer darks
PALETTE.midnight = {}
for k, v in pairs(PALETTE.classic) do PALETTE.midnight[k] = v end
for k, v in pairs({
    bg          = { 0.045, 0.05, 0.065, 0.97 },
    header      = { 0.11, 0.12, 0.15, 0.9 },
    header2     = { 0.04, 0.045, 0.06, 0.9 },
    frameBorder = { 0.66, 0.68, 0.74, 1 },    -- tint on the desaturated dialog border
    border      = { 0.42, 0.44, 0.5, 1 },
    insetBorder = { 0.38, 0.4, 0.46, 1 },
    inset       = { 0, 0, 0, 0.5 },
    inputBg     = { 0.02, 0.025, 0.035, 0.85 },
    listBg      = { 0.04, 0.045, 0.06, 0.98 },
    muted       = { 0.58, 0.6, 0.66 },
    sep         = { 0.45, 0.47, 0.55, 0.6 },
    tabOn       = { 0.08, 0.09, 0.12, 0.97 },
    tabOff      = { 0.02, 0.025, 0.035, 0.92 },
    tabHover    = { 0.1, 0.11, 0.15, 0.95 },
}) do PALETTE.midnight[k] = v end

local function LoadPalette(name)
    local over = PALETTE[name] or {}
    for k, base in pairs(PALETTE.modern) do
        local src, dst = over[k] or base, C[k]
        for i = 1, 4 do dst[i] = src[i] end
    end
end

local DIALOG_BD = {
    -- solid fill: the game's UI-DialogBox-Background-Dark texture is partly
    -- see-through, so the world (nameplates etc.) showed through the windows
    bgFile = WHITE,
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}
local TOOLTIP_BD = {
    bgFile = WHITE,
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

local themeHooks = {}
-- true for the game-style themes (Forever, Midnight)
local function IsGameStyle() return ns.DB ~= nil and (ns.DB.theme == "classic" or ns.DB.theme == "midnight") end

-- The pieces BackdropTemplate builds the border from; Midnight greys out the
-- gold dialog border so it reads as dark metal.
local BD_PIECES = { "TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
    "TopEdge", "BottomEdge", "LeftEdge", "RightEdge" }
local function SetBorderDesaturated(f, on)
    for _, k in ipairs(BD_PIECES) do
        local t = f[k]
        if t and t.SetDesaturated then t:SetDesaturated(on) end
    end
end

-- Register fn(gameStyle) to (re)apply theme-dependent looks; runs once now.
local function OnTheme(fn)
    themeHooks[#themeHooks + 1] = fn
    fn(IsGameStyle())
end

local function RunThemeHooks()
    local classic = IsGameStyle()
    for _, fn in ipairs(themeHooks) do fn(classic) end
end

-- Backdrop + colours for a frame by role:
--  "window" outer frame, "inset" message area / panel, "input" edit/check box,
--  "list" dropdown. bg/border (optional) override the modern colours only.
local ROLE_COLORS = {
    window = { "bg", "frameBorder" },
    inset  = { "inset", "insetBorder" },
    input  = { "inputBg", "border" },
    list   = { "listBg", "border" },
}
local function Skin(f, role, bg, border)
    OnTheme(function(classic)
        if classic then
            f:SetBackdrop(role == "window" and DIALOG_BD or TOOLTIP_BD)
        else
            f:SetBackdrop(FLAT)
        end
        SetBorderDesaturated(f, role == "window" and ns.DB ~= nil and ns.DB.theme == "midnight")
        local rc = ROLE_COLORS[role]
        f:SetBackdropColor(unpack((not classic and bg) or C[rc[1]]))
        f:SetBackdropBorderColor(unpack((not classic and border) or C[rc[2]]))
    end)
end

local HEADER_H = 34

-- Font for message text (whisper windows, input box, History). Its size is
-- a setting; everything using it follows when it changes.
local msgFont = CreateFont("DMmeMessageFont")
msgFont:SetFontObject(ChatFontNormal)
local FONT_MIN, FONT_MAX = 9, 24
local function DefaultFontSize()
    local _, size = ChatFontNormal:GetFont()
    return math.floor((size or 14) + 0.5)
end
local function ApplyFontSize()
    local file, size, flags = ChatFontNormal:GetFont()
    if not file then return end
    msgFont:SetFont(file, (ns.DB and ns.DB.fontSize) or size, flags or "")
end

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

-- Name to whisper a player unit by (portraits, party/raid frames), or nil
-- for NPCs and names the game hides from addons.
--   Forever:  "Mrs Karma"         first name + surname, with a space
--   Retail:   "Name-ArgentDawn"   other realms (realm without spaces/dashes)
--             "Name"              your own realm
function ns.UnitWhisperName(unit)
    if not (unit and UnitIsPlayer and UnitIsPlayer(unit)) then return nil end
    local n, second = UnitName(unit)
    if AnySecret(n, second) or not n or n == "" then return nil end
    if not second or second == "" then return n end
    if TwoPartNames() then return n .. " " .. second end
    return n .. "-" .. (second:gsub("[%s%-]", ""))
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
-- shared between files: ns.guidStore -- set once DB is loaded: function(key, guid)
local function BNKeyFromID(id)
    if not id then return nil end
    local info = BNInfo(id)
    local key = "BN:" .. ((info and info.battleTag) or tostring(id))
    bnIDs[key] = id
    local g = info and info.gameAccountInfo
    if g and g.playerGuid and ns.guidStore then ns.guidStore(key, g.playerGuid) end
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
-- Game account info of a Battle.net friend who is playing a WoW character
-- in the same game version as you, or nil.
local function GetBNGame(key)
    local info = BNInfo(BNResolve(key))
    local g = info and info.gameAccountInfo
    if not g or not g.characterName or g.characterName == "" then return nil end
    if g.clientProgram and BNET_CLIENT_WOW and g.clientProgram ~= BNET_CLIENT_WOW then return nil end
    if g.wowProjectID and WOW_PROJECT_ID and g.wowProjectID ~= WOW_PROJECT_ID then return nil end
    return g
end

-- "Name" or "Name-Realm" of the character a Battle.net friend is playing.
local function GetBNCharacter(key)
    local g = GetBNGame(key)
    if not g then return nil end
    local name = g.characterName
    local realm = g.realmName
    local sameRealm = g.realmID and GetRealmID and g.realmID == GetRealmID()
    -- Some servers (e.g. Forever) report internal realm names like
    -- "CAMWOWEU5Realm5PvE" that the server itself rejects in names: players
    -- there are reached by plain name, so never append those.
    local internal = realm and realm:find("Realm%d") ~= nil
    if realm and realm ~= "" and not sameRealm and not internal then
        name = name .. "-" .. realm:gsub("[%s%-]", "")
    end
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

local function ShowCopyBox(text, hint, doneMsg)
    if not copyBox then
        local b = CreateFrame("Frame", "DMmeCopyBox", UIParent, BACKDROP_TEMPLATE)
        b:SetSize(340, 84)
        b:SetPoint("TOP", UIParent, "TOP", 0, -160)
        Skin(b, "window", { 0.055, 0.055, 0.07, 0.96 }, { 1, 0.5, 1, 1 })
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
        Skin(box, "input", nil, { 0.3, 0.3, 0.36, 1 })

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
                    Print(b.doneMsg or "Copied. Now press |cffffd100Enter|r, |cffffd100Ctrl+V|r, |cffffd100Enter|r.")
                end)
            end
        end)
        b.eb = eb
        copyBox = b
    end
    copyBox.text = text
    copyBox.doneMsg = doneMsg -- chat message after Ctrl+C (nil = the /ginvite steps)
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
    -- Battle.net friends: invite through their game account, like the
    -- Friends list does (works no matter how their realm is named)
    if IsBN(name) then
        local g = GetBNGame(name)
        if not g then
            Print(ShortName(name) .. " isn't playing a character you can invite right now.")
            return
        end
        if g.gameAccountID then
            if FriendsFrame_InviteOrRequestToJoin and g.playerGuid then
                FriendsFrame_InviteOrRequestToJoin(g.playerGuid, g.gameAccountID)
                return
            elseif BNInviteFriend then
                BNInviteFriend(g.gameAccountID)
                return
            end
        end
        -- no Battle.net invite on this client: fall back to the character name
    end
    name = ResolveTarget(name)
    if not name then return end
    local target = TargetName(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(target)
    elseif InviteUnit then
        InviteUnit(target)
    end
end

-- Battle.net friends: the friends list already knows their character's
-- level, race, class and zone (works across realms and factions, unlike /who).
-- Run a /who for a character name (results are picked up by StoreProfile).
local function SendWhoFor(charName)
    whoPending[FullName(charName)] = time()
    local q = 'n-"' .. ShortName(charName) .. '"'
    if C_FriendList and C_FriendList.SendWho then
        C_FriendList.SendWho(q)
    elseif SendWho then
        SendWho(q)
    end
end

local function NonEmpty(v)
    if v == nil or v == "" or v == 0 then return nil end
    return v
end

local function BNWho(key)
    local info = BNInfo(BNResolve(key))
    local g = info and info.gameAccountInfo
    if not (g and NonEmpty(g.characterName)) then
        Print(ShortName(key) .. " isn't playing a WoW character right now.")
        return
    end
    local data = {
        level = NonEmpty(g.characterLevel),
        race = NonEmpty(g.raceName),
        class = NonEmpty(g.className),
        zone = NonEmpty(g.areaName),
        character = g.characterName,
    }
    ns.StoreProfile(key, data)

    -- Reachable character: a real /who adds what Battle.net doesn't give
    -- (guild, up-to-date level/zone). The game prints its own result line and
    -- it's copied into this Battle.net conversation (see StoreProfile).
    local c = GetBNCharacter(key)
    if c then
        whoAlias[FullName(c)] = key
        SendWhoFor(c)
        return
    end

    -- No /who possible (e.g. another game version): answer in chat ourselves
    -- so the click still visibly does something.
    local parts = {}
    if data.level then parts[#parts + 1] = "Level " .. data.level end
    if data.race then parts[#parts + 1] = data.race end
    if data.class then parts[#parts + 1] = data.class end
    local line = ShortName(key) .. " is playing |cffffffff" .. g.characterName .. "|r"
    if #parts > 0 then line = line .. " - " .. table.concat(parts, " ") end
    if data.zone then line = line .. " - " .. data.zone end
    Print(line)
end

local function WhoName(name)
    if IsBN(name) then BNWho(name); return end
    name = ResolveTarget(name)
    if not name then return end
    SendWhoFor(name)
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
    -- game-style theme: gold headings like the game's own windows
    if ns.DB and ns.DB.classColors and not IsGameStyle() then
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
    local classFile, locClass, locRace = GuidInfo(ns.DB.guids[key])
    local p = ns.DB.profiles and ns.DB.profiles[key]
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
    if ns.DB.classColors then
        local r, g, b = KeyRGB(key)
        if r then return r, g, b end
    end
    return 1, 0.5, 1
end

-- Colour for their message text: class colour lightened a bit for readability.
local function KeyTextRGB(key)
    if ns.DB.classColors then
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

-- Header band of a window. `bottom` = distance from the top of the frame to
-- the header's bottom edge; in the classic theme it sits inside the dialog
-- border instead of touching the frame edge.
local function SkinHeader(header, bottom)
    OnTheme(function(classic)
        local pad = classic and 5 or 1
        header:ClearAllPoints()
        header:SetPoint("TOPLEFT", pad, -pad)
        header:SetPoint("TOPRIGHT", -pad, -pad)
        header:SetHeight(bottom - pad)
        SetGradientV(header, C.header, C.header2)
    end)
end

-- Colour of a chat type from the game's chat settings (so it matches the
-- player's own whisper colours), with a fallback.
local function ChatRGB(kind, r, g, b)
    local t = ChatTypeInfo and ChatTypeInfo[kind]
    if t and t.r then return t.r, t.g, t.b end
    return r, g, b
end

----------------------------------------------------------------------
-- Log (opt-in, saved to SavedVariables)
----------------------------------------------------------------------
local function LogEntry(key, entry)
    if not ns.DB.logEnabled then return end
    local log = ns.DB.log[key]
    if not log then log = { entries = {} }; ns.DB.log[key] = log end
    local e = log.entries
    e[#e + 1] = entry
    log.last = entry.t
    local over = #e - (ns.DB.logMax or 2000)
    for _ = 1, over do table.remove(e, 1) end
end

-- Sounds you can pick for new whispers (Settings > Window > "Whisper sound").
-- Only the ones this game client has are offered.
local SOUND_OPTIONS = {}
for _, o in ipairs({
    { id = "TELL_MESSAGE",            label = "Whisper (default)" },
    { id = "IG_PLAYER_INVITE",        label = "Group invite" },
    { id = "READY_CHECK",             label = "Ready check" },
    { id = "RAID_WARNING",            label = "Raid warning" },
    { id = "MAP_PING",                label = "Map ping" },
    { id = "IG_QUEST_LIST_COMPLETE",  label = "Quest complete" },
    { id = "LOOT_WINDOW_COIN_SOUND",  label = "Coins" },
    { id = "AUCTION_WINDOW_OPEN",     label = "Auction house" },
    { id = "ALARM_CLOCK_WARNING_3",   label = "Alarm clock" },
    { id = "IG_MAINMENU_OPEN",        label = "Soft click" },
}) do
    if SOUNDKIT and SOUNDKIT[o.id] then SOUND_OPTIONS[#SOUND_OPTIONS + 1] = o end
end

-- Play the chosen whisper sound (force = play even if sound is turned off, for previews).
-- isBN = Battle.net whisper (uses its own sound unless set to "Same as whispers").
local function PlayWhisperSound(force, isBN)
    if not (force or ns.DB.sound) or not SOUNDKIT then return end
    local name = ns.DB.soundKit
    if isBN and ns.DB.soundKitBN and ns.DB.soundKitBN ~= "SAME" then name = ns.DB.soundKitBN end
    local id = SOUNDKIT[name or ""] or SOUNDKIT.TELL_MESSAGE
    if id then PlaySound(id) end
end

-- Battle.net sound choices: "Same as whispers" plus the same list.
local BN_SOUND_OPTIONS = { { id = "SAME", label = "Same as whispers" } }
for _, o in ipairs(SOUND_OPTIONS) do BN_SOUND_OPTIONS[#BN_SOUND_OPTIONS + 1] = o end

-- How long saved history is kept (Settings > History > "Keep history for")
local KEEP_OPTIONS = {
    { id = "day",     label = "1 day",   secs = 86400 },
    { id = "week",    label = "1 week",  secs = 7 * 86400 },
    { id = "month",   label = "1 month", secs = 30 * 86400 },
    { id = "year",    label = "1 year",  secs = 365 * 86400 },
    { id = "forever", label = "Forever", secs = nil },
}

local function KeepOption(id)
    for _, o in ipairs(KEEP_OPTIONS) do if o.id == id then return o end end
    return KEEP_OPTIONS[#KEEP_OPTIONS]
end

-- Number of saved messages older than the given keep option.
local function CountExpired(id)
    local secs = KeepOption(id).secs
    if not secs then return 0 end
    local cutoff, n = time() - secs, 0
    for _, log in pairs(ns.DB.log) do
        for _, e in ipairs(log.entries) do
            if e.t < cutoff then n = n + 1 else break end -- entries are oldest first
        end
    end
    return n
end

-- Delete saved messages older than the current keep setting.
local function PruneHistory()
    local secs = KeepOption(ns.DB.logKeep).secs
    if not secs then return 0 end
    local cutoff, removed = time() - secs, 0
    for key, log in pairs(ns.DB.log) do
        local kept = {}
        for _, e in ipairs(log.entries) do
            if e.t >= cutoff then kept[#kept + 1] = e else removed = removed + 1 end
        end
        if #kept == 0 then
            ns.DB.log[key] = nil
        else
            log.entries = kept
        end
    end
    return removed
end

----------------------------------------------------------------------
-- Clickable web links: URLs in messages become "|Hdmmeurl:...|h" links;
-- clicking one opens a box with the address selected, ready for Ctrl+C.
----------------------------------------------------------------------
-- endings accepted for addresses without http:// or www. ("discord.gg/abc", "wowhead.com")
local URL_TLDS = {
    com = true, net = true, org = true, gg = true, tv = true, io = true,
    eu = true, uk = true, info = true, app = true, dev = true, ly = true,
    gl = true, be = true, me = true, co = true, us = true, xyz = true,
}
local URL_COLOR = "|cff4fb4ff"

-- If `word` is (or contains, inside punctuation) a web address, returns
-- leading punctuation, the address, trailing punctuation.
local function FindURL(word)
    if word:find("|", 1, true) then return end -- part of an item/player link
    local lead, core = word:match("^([%(%[\"']*)(.*)$")
    local url, trail = core:match("^(.-)([%.,;:!%?%)%]\"']*)$")
    if not url or #url < 4 then return end
    local lower = url:lower()
    if lower:match("^%a[%w+.-]*://[%w]") or lower:match("^www%.[%w-]+%.%a") then
        return lead, url, trail
    end
    local host = lower:match("^([%w-]+%.[%w.-]*%a)")
    local tld = host and host:match("%.(%a+)$")
    if tld and URL_TLDS[tld] and #host > #tld + 2 then
        local rest = lower:sub(#host + 1)
        if rest == "" or rest:match("^[/:?#]") then return lead, url, trail end
    end
end

-- Turn web addresses in a message into clickable links. r, g, b = the
-- message colour, restored after each link.
local function Linkify(text, r, g, b)
    if not text or text == "" then return text end
    local reopen = "|c" .. Hex(r, g, b)
    return (text:gsub("%S+", function(word)
        local lead, url, trail = FindURL(word)
        if not url then return nil end
        return lead .. URL_COLOR .. "|Hdmmeurl:" .. url .. "|h[" .. url .. "]|h|r" .. reopen .. trail
    end))
end

----------------------------------------------------------------------
-- Emoji. WoW's fonts can't draw emoji, so DMme ships them as pictures
-- (Media/Emoji, from Twemoji - CC-BY 4.0, see Media/Emoji/LICENSE.txt) and
-- swaps them in when showing a message:
--  * shortcuts typed as a separate word: :) :D <3 :fire: ...
--  * real emoji, e.g. from someone on the Battle.net phone app
-- Only what you see changes; the message itself is sent as typed.
-- (One table instead of many locals: Lua allows 200 locals per file.)
----------------------------------------------------------------------
local Emoji = {
    PATH = "Interface\\AddOns\\DMme\\Media\\Emoji\\",
    -- name (file), the real emoji as UTF-8 bytes, shortcuts (first = what the picker types)
    LIST = {
        { "smile", "\240\159\153\130", { ":)", ":-)" } },
        { "grin", "\240\159\152\128", { ":D", ":-D" } },
        { "laugh", "\240\159\152\130", { ":joy:", "xD", "XD" } },
        { "rofl", "\240\159\164\163", { ":rofl:" } },
        { "sweat", "\240\159\152\133", { ":sweat:" } },
        { "wink", "\240\159\152\137", { ";)", ";-)" } },
        { "blush", "\240\159\152\138", { "^^", ":blush:" } },
        { "love", "\240\159\152\141", { ":love:" } },
        { "kiss", "\240\159\152\152", { ":*", ":kiss:" } },
        { "tongue", "\240\159\152\155", { ":P", ":p", ":-P", ":-p" } },
        { "cool", "\240\159\152\142", { ":cool:" } },
        { "smirk", "\240\159\152\143", { ":smirk:" } },
        { "think", "\240\159\164\148", { ":think:" } },
        { "neutral", "\240\159\152\144", { ":neutral:" } },
        { "upside", "\240\159\153\131", { ":upside:" } },
        { "surprised", "\240\159\152\174", { ":O", ":o", ":-O" } },
        { "sad", "\240\159\153\129", { ":(", ":-(" } },
        { "cry", "\240\159\152\162", { ":'(", ":cry:" } },
        { "sob", "\240\159\152\173", { ":sob:" } },
        { "please", "\240\159\165\186", { ":please:" } },
        { "angry", "\240\159\152\160", { ">:(", ":angry:" } },
        { "sleep", "\240\159\152\180", { ":zzz:" } },
        { "party", "\240\159\165\179", { ":party:" } },
        { "facepalm", "\240\159\164\166", { ":facepalm:" } },
        { "shrug", "\240\159\164\183", { ":shrug:" } },
        { "skull", "\240\159\146\128", { ":skull:" } },
        { "eyes", "\240\159\145\128", { ":eyes:" } },
        { "heart", "\226\157\164", { "<3", ":heart:" } },
        { "broken", "\240\159\146\148", { "</3" } },
        { "thumbsup", "\240\159\145\141", { "(y)", ":+1:" } },
        { "thumbsdown", "\240\159\145\142", { "(n)", ":-1:" } },
        { "ok", "\240\159\145\140", { ":ok:" } },
        { "clap", "\240\159\145\143", { ":clap:" } },
        { "wave", "\240\159\145\139", { ":wave:" } },
        { "pray", "\240\159\153\143", { ":pray:" } },
        { "muscle", "\240\159\146\170", { ":strong:" } },
        { "fire", "\240\159\148\165", { ":fire:" } },
        { "hundred", "\240\159\146\175", { ":100:" } },
        { "star", "\226\173\144", { ":star:" } },
        { "sparkles", "\226\156\168", { ":sparkles:" } },
        { "check", "\226\156\133", { ":check:" } },
        { "gold", "\240\159\146\176", { ":gold:" } },
        { "swords", "\226\154\148", { ":swords:" } },
        { "beer", "\240\159\141\186", { ":beer:" } },
        { "gift", "\240\159\142\129", { ":gift:" } },
        { "ghost", "\240\159\145\187", { ":ghost:" } },
    },
    byCode = {}, byUTF8 = {},
}
for _, e in ipairs(Emoji.LIST) do
    Emoji.byUTF8[e[2]] = e[1]
    for _, c in ipairs(e[3]) do Emoji.byCode[c] = e[1] end
end

function Emoji.Tex(name, size)
    return "|T" .. Emoji.PATH .. name .. ":" .. (size or 0) .. "|t"
end

function Emoji.On() return not ns.DB or ns.DB.emoji ~= false end

-- Swap emoji shortcuts and real emoji in `text` for pictures.
function Emoji.Render(text)
    if not text or text == "" or not Emoji.On() then return text end
    -- real emoji: drop the invisible "show as emoji" marker and skin tones, then swap
    text = text:gsub("\239\184\143", "")
    text = text:gsub("\240\159\143[\187-\191]", "")
    local function swap(s)
        local name = Emoji.byUTF8[s]
        return name and Emoji.Tex(name) or nil
    end
    text = text:gsub("\240[\144-\191][\128-\191][\128-\191]", swap)
    text = text:gsub("\226[\128-\191][\128-\191]", swap)
    -- shortcuts: only as a whole word, never inside links ("|") or times like 10:30
    text = text:gsub("%S+", function(word)
        if word:find("|", 1, true) then return nil end
        local name = Emoji.byCode[word]
        if name then return Emoji.Tex(name) end
        -- allow punctuation right after it: "nice :D!"
        local core, trail = word:match("^(.-)([,%.!%?]+)$")
        name = core and Emoji.byCode[core]
        if name then return Emoji.Tex(name) .. trail end
    end)
    return text
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
    local function Link(linkName, colored, toThem)
        if toThem and bn then
            local id = BNResolve(key)
            local info = BNInfo(id)
            if info and info.accountName then
                return "|HBNplayer:" .. info.accountName .. ":" .. id .. ":0:BN_WHISPER:" .. info.accountName .. "|h" .. colored .. "|h"
            end
            return colored
        end
        return "|Hplayer:" .. linkName .. "|h" .. colored .. "|h"
    end

    if IsGameStyle() then
        -- game style, like the normal chat frame:
        --   [Name] whispers: hello      To [Name]: hello
        -- the whole line in the whisper colour, the name in their class colour
        local inKind, outKind, fr, fg, fb
        if bn then
            inKind, outKind, fr, fg, fb = "BN_WHISPER", "BN_WHISPER_INFORM", 0, 1, 0.96
        else
            inKind, outKind, fr, fg, fb = "WHISPER", "WHISPER_INFORM", 1, 0.5, 1
        end
        local lr, lg, lb = ChatRGB(e.i and inKind or outKind, fr, fg, fb)
        if not e.i then
            -- the game uses the same colour for sent and received by default,
            -- which makes a conversation hard to follow: shade your own lines
            -- darker (unless you picked a different colour in chat settings)
            local ir, ig, ib = ChatRGB(inKind, fr, fg, fb)
            if math.abs(ir - lr) + math.abs(ig - lg) + math.abs(ib - lb) < 0.15 then
                lr, lg, lb = lr * 0.72, lg * 0.72, lb * 0.72
            end
        end
        if dim then lr, lg, lb = lr * 0.6, lg * 0.6, lb * 0.6 end
        local them = ShortName(key)
        local tr, tg, tb = ClassRGB((KeyInfo(key)))
        if bn and not tr then tr, tg, tb = C.bn[1], C.bn[2], C.bn[3] end
        if dim or not ns.DB.classColors then tr = nil end
        local themText = tr and Colorize(them, tr, tg, tb) or Colorize(them, lr, lg, lb)
        local bracketed = Colorize("[", lr, lg, lb) .. themText .. Colorize("]", lr, lg, lb)
        local link = Link(key, bracketed, true)
        if e.i then
            return string.format("%s %s%s", stamp, link, Colorize(" whispers: " .. Emoji.Render(Linkify(e.m, lr, lg, lb)), lr, lg, lb))
        end
        return string.format("%s %s%s%s", stamp, Colorize("To ", lr, lg, lb), link, Colorize(": " .. Emoji.Render(Linkify(e.m, lr, lg, lb)), lr, lg, lb))
    end

    local colored = Colorize(name, r or 0.85, g or 0.85, b or 0.9)
    local nameText = Link(e.i and key or name, colored, e.i)
    return string.format("%s  %s  %s", stamp, nameText, Colorize(Emoji.Render(Linkify(e.m, tc[1], tc[2], tc[3])), tc[1], tc[2], tc[3]))
end

-- Any menu DMme opens runs as "DMme" (tainted), so Blizzard's own
-- "Copy Character Name" in it is blocked: CopyToClipboard() is protected.
-- While the menu is built we remember the name; Whispers.lua then points that
-- one entry at our copy box instead (see FixCopyName there).
local function OpenItemRef(link, text, button, copyName)
    ns.menuCopyName = copyName
    local ok, err = pcall(SetItemRef, link, text, button, DEFAULT_CHAT_FRAME)
    ns.menuCopyName = nil
    if not ok then geterrorhandler()(err) end
end

-- Open the game's own player right-click menu (same as in normal chat).
local function ShowPlayerMenu(name)
    if not name or not SetItemRef then return end
    if IsBN(name) then
        local id = BNResolve(name)
        local info = BNInfo(id)
        if info and info.accountName then
            OpenItemRef("BNplayer:" .. info.accountName .. ":" .. id .. ":0:BN_WHISPER:" .. info.accountName,
                "[" .. info.accountName .. "]", "RightButton", info.accountName)
        end
        return
    end
    OpenItemRef("player:" .. name, "[" .. ShortName(name) .. "]", "RightButton", name)
end

-- Hyperlink clicks in our message frames:
--  right-click / modified click on a name -> the game's normal handling (player menu, /who, ...)
--  plain left-click on a name             -> open that conversation in DMme
--  any other link (items, quests...)      -> the game's normal handling
local function HandleLink(_, link, text, button)
    -- web address -> show it ready to copy (addons can't open a browser)
    local url = link:match("^dmmeurl:(.+)$")
    if url then
        ShowCopyBox(url, "Press |cffffd100Ctrl+C|r to copy the link, then paste it in your browser.",
            "Link copied - paste it in your browser with |cffffd100Ctrl+V|r.")
        return
    end
    local plain = button == "LeftButton" and not IsModifierKeyDown()
    local name = link:match("^player:([^:]+)")
    if name and plain then
        if FullName(name) ~= FullName(playerName) then ns.OpenWindow(name) end
        return
    end
    local bnID = tonumber(link:match("^BNplayer:[^:]*:(%d+)") or "")
    if bnID and plain then
        ns.OpenWindow((BNKeyFromID(bnID)))
        return
    end
    OpenItemRef(link, text, button, name)
end

local function DayHeader(t)
    return "|cff6a6a78----------  " .. date("%A, %d %B %Y", t) .. "  ----------|r"
end

local function SetLogging(on)
    ns.DB.logEnabled = on and true or false
    if ns.DB.logEnabled then
        Print("Whisper logging |cff55ff55ON|r - whispers are saved and shown in /dm history.")
    else
        Print("Whisper logging |cffff5555OFF|r - new whispers are not saved. Existing logs are kept (delete them in /dm history).")
    end
    if DMmeHistory and DMmeHistory.UpdateToggle then DMmeHistory:UpdateToggle() end
end

-- shared with the files after this one (see their 'from earlier files')
ns.defaults = defaults
ns.windows = windows
ns.playerName = playerName
ns.SESSION_LINES = SESSION_LINES
ns.KeyUnread = KeyUnread
ns.whoPending = whoPending
ns.whoAlias = whoAlias
ns.WHITE = WHITE
ns.MEDIA_GEAR = MEDIA_GEAR
ns.MEDIA_ICON = MEDIA_ICON
ns.FLAT = FLAT
ns.BACKDROP_TEMPLATE = BACKDROP_TEMPLATE
ns.C = C
ns.THEME_OPTIONS = THEME_OPTIONS
ns.PALETTE = PALETTE
ns.LoadPalette = LoadPalette
ns.TOOLTIP_BD = TOOLTIP_BD
ns.IsGameStyle = IsGameStyle
ns.OnTheme = OnTheme
ns.RunThemeHooks = RunThemeHooks
ns.Skin = Skin
ns.HEADER_H = HEADER_H
ns.msgFont = msgFont
ns.FONT_MIN = FONT_MIN
ns.FONT_MAX = FONT_MAX
ns.DefaultFontSize = DefaultFontSize
ns.ApplyFontSize = ApplyFontSize
ns.AddFilter = AddFilter
ns.Print = Print
ns.IsSecret = IsSecret
ns.AnySecret = AnySecret
ns.IsBN = IsBN
ns.ShortName = ShortName
ns.FullName = FullName
ns.BNInfo = BNInfo
ns.BNKeyFromID = BNKeyFromID
ns.BNResolve = BNResolve
ns.SendWhisperTo = SendWhisperTo
ns.GuildInviteName = GuildInviteName
ns.PartyInviteName = PartyInviteName
ns.WhoName = WhoName
ns.ClassRGB = ClassRGB
ns.UIAccent = UIAccent
ns.OnUIAccent = OnUIAccent
ns.ApplyUIAccent = ApplyUIAccent
ns.KeyInfo = KeyInfo
ns.KeyRGB = KeyRGB
ns.ClassFileFromName = ClassFileFromName
ns.Colorize = Colorize
ns.KeyHighlight = KeyHighlight
ns.KeyTextRGB = KeyTextRGB
ns.KeyColorize = KeyColorize
ns.SkinHeader = SkinHeader
ns.LogEntry = LogEntry
ns.SOUND_OPTIONS = SOUND_OPTIONS
ns.PlayWhisperSound = PlayWhisperSound
ns.BN_SOUND_OPTIONS = BN_SOUND_OPTIONS
ns.KEEP_OPTIONS = KEEP_OPTIONS
ns.KeepOption = KeepOption
ns.CountExpired = CountExpired
ns.PruneHistory = PruneHistory
ns.Emoji = Emoji
ns.FormatEntry = FormatEntry
ns.ShowPlayerMenu = ShowPlayerMenu
ns.ShowCopyBox = ShowCopyBox
ns.HandleLink = HandleLink
ns.DayHeader = DayHeader
ns.SetLogging = SetLogging
