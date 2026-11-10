-- DMme: game notices in conversations, Reply key and /w from the main chat,
-- idle fade, taskbar flash, pinned conversations and the busy auto-reply.
-- Part of DMme; loads after the files before it in DMme.toc and shares
-- names with them through the addon namespace (ns).
local _, ns = ...

-- from earlier files (these never change after loading)
local AddFilter = ns.AddFilter
local AnySecret = ns.AnySecret
local BNKeyFromID = ns.BNKeyFromID
local FullName = ns.FullName
local IndexOf = ns.IndexOf
local Print = ns.Print
local SendWhisperTo = ns.SendWhisperTo
local ShortName = ns.ShortName
local tabOrder = ns.tabOrder
local windows = ns.windows

local function HasConversation(key)
    return key and (ns.session[key] or windows[key]) and true or false
end

----------------------------------------------------------------------
-- Notices: grey lines in the conversation for "not delivered", away/busy
-- replies, and came online / went offline.
----------------------------------------------------------------------
-- A game message like "No player named '%s' is currently playing." as a
-- Lua pattern that captures the %s parts.
local function GamePattern(fmt)
    if type(fmt) ~= "string" then return nil end
    local p = fmt:gsub("([%(%)%.%[%]%*%+%-%?%^%$])", "%%%1")
    p = p:gsub("%%%%%d%%%$s", "(.-)") -- "%1$s" style
    p = p:gsub("%%s", "(.-)")
    return "^" .. p .. "$"
end

local NOT_FOUND = GamePattern(ERR_CHAT_PLAYER_NOT_FOUND_S)
local CAME_ONLINE = GamePattern(ERR_FRIEND_ONLINE_SS)
local WENT_OFFLINE = GamePattern(ERR_FRIEND_OFFLINE_S)

-- the player name in a system message (may be a |Hplayer link)
local function NameFrom(s)
    if not s then return nil end
    return FullName(s:match("|Hplayer:([^:|]+)") or s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- "No player named ..." for someone you have a conversation with: the key
local function NotFoundKey(msg)
    local name = NOT_FOUND and msg:match(NOT_FOUND)
    local key = NameFrom(name)
    return HasConversation(key) and key or nil
end

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_SYSTEM")
events:RegisterEvent("CHAT_MSG_AFK")
events:RegisterEvent("CHAT_MSG_DND")
pcall(events.RegisterEvent, events, "BN_FRIEND_ACCOUNT_ONLINE")
pcall(events.RegisterEvent, events, "BN_FRIEND_ACCOUNT_OFFLINE")

----------------------------------------------------------------------
-- Busy auto-reply: answers each person once while it's on. Turned off at
-- every login, so it is never left on by accident.
----------------------------------------------------------------------
local busyReplied = {} -- [key] = true: already got the auto-reply

local function SetBusy(on, text)
    if text and text:match("%S") then ns.DB.busyText = text end
    ns.DB.busy = on and true or false
    wipe(busyReplied)
    if ns.DB.busy then
        Print("Busy auto-reply |cff55ff55ON|r: \"" .. ns.DB.busyText .. "\"  (|cffffd100/dm busy off|r to stop)")
    else
        Print("Busy auto-reply OFF.")
    end
    if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
    if ns.UpdateSessionUI then ns.UpdateSessionUI() end
end
ns.SetBusy = SetBusy

-- Called by Whispers.lua for every incoming whisper that wasn't muted or spam.
ns.OnIncoming = function(key)
    if ns.DB.flashTaskbar and FlashClientIcon then FlashClientIcon() end
    if ns.DB.busy and not busyReplied[key] then
        busyReplied[key] = true
        local text = ns.DB.busyText
        if text and text:match("%S") then
            -- next frame: after the incoming line is in the window
            C_Timer.After(0.2, function() pcall(SendWhisperTo, key, "[Auto-reply] " .. text) end)
        end
    end
end

----------------------------------------------------------------------
-- Reply key: while "Reply key opens DMme" is on, the keys bound to the
-- game's Reply get an override binding to DMme's "Reply to last whisper".
-- Override bindings can't change in combat: those wait for it to end.
----------------------------------------------------------------------
local bindOwner = CreateFrame("Frame")
local bindPending, lastBindState = false, nil

local function ApplyReplyKey()
    if not ns.DB then return end
    local keys = { GetBindingKey("REPLY") }
    -- setting override bindings fires UPDATE_BINDINGS again: only redo
    -- them when the setting or the Reply keys really changed
    local state = tostring(ns.DB.replyKey) .. ":" .. table.concat(keys, ",")
    if state == lastBindState then return end
    if InCombatLockdown() then bindPending = true; return end
    bindPending = false
    lastBindState = state
    ClearOverrideBindings(bindOwner)
    if ns.DB.replyKey then
        for _, k in ipairs(keys) do
            SetOverrideBinding(bindOwner, false, k, "DMME_REPLY")
        end
    end
end
ns.ApplyReplyKey = ApplyReplyKey

----------------------------------------------------------------------
-- /w name in the main chat box: open the DMme window instead. Watches the
-- chat boxes for a new whisper target, then closes the main box and moves
-- what you typed over to DMme.
----------------------------------------------------------------------
local function DeactivateChat(eb)
    if ChatEdit_DeactivateChat then
        ChatEdit_DeactivateChat(eb)
    elseif ChatFrameUtil and ChatFrameUtil.DeactivateChat then
        ChatFrameUtil.DeactivateChat(eb)
    else
        eb:ClearFocus()
    end
end

local function Redirect(eb)
    if not (ns.DB and ns.DB.redirectWhisper) or not eb:HasFocus() then return end
    local chatType, target, text = eb:GetAttribute("chatType"), eb:GetAttribute("tellTarget"), eb:GetText()
    if AnySecret(chatType, target, text) or type(target) ~= "string" or target == "" then return end
    local key
    if chatType == "WHISPER" then
        key = FullName(target)
    elseif chatType == "BN_WHISPER" and BNet_GetBNetIDAccount then
        key = BNKeyFromID(BNet_GetBNetIDAccount(target))
    end
    if not key then return end
    -- Only a new target (/w name, Reply). Opening the main box when it was
    -- left on "whisper Bob" (Enter) is not a /w, so it stays in the main chat.
    local newTarget = GetTime() - (eb.dmmeTargetAt or 0) < 0.5
    if not newTarget and eb.dmmeLastTarget == key then return end
    eb.dmmeTargetAt, eb.dmmeLastTarget = nil, key
    DeactivateChat(eb)
    ns.OpenWindow(key)
    local f = windows[key]
    if f and type(text) == "string" and text ~= "" then f.edit:SetText(text) end
end

-- Look a moment later, when the game has set both the target and the chat
-- type (clients set them in different orders). Twice, in case one frame
-- is too early; Redirect does nothing once the main box is closed.
local function CheckSoon(eb)
    if not (ns.DB and ns.DB.redirectWhisper and eb) then return end
    C_Timer.After(0, function() pcall(Redirect, eb) end)
    C_Timer.After(0.05, function() pcall(Redirect, eb) end)
end

local function HookChatBox(eb)
    if not eb or eb.dmmeHooked or not eb.SetAttribute then return end
    eb.dmmeHooked = true
    hooksecurefunc(eb, "SetAttribute", function(self, attr)
        if attr == "tellTarget" then self.dmmeTargetAt = GetTime() end
        if attr == "tellTarget" or attr == "chatType" then CheckSoon(self) end
    end)
    -- newer clients: the header is redrawn whenever the chat type changes
    if eb.UpdateHeader then hooksecurefunc(eb, "UpdateHeader", CheckSoon) end
end

local function HookChatBoxes()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        HookChatBox(_G["ChatFrame" .. i .. "EditBox"])
    end
    -- older clients: one global function redraws the header
    if ChatEdit_UpdateHeader then hooksecurefunc("ChatEdit_UpdateHeader", CheckSoon) end
end

----------------------------------------------------------------------
-- Idle fade: windows go see-through when nothing is happening, and come
-- back when the mouse is over them, you type, or a whisper arrives.
----------------------------------------------------------------------
local FADE_AFTER = 6 -- seconds
local fadeTicker

local function WindowBusy(f, now)
    if f:IsMouseOver(26, 0, 0, 0) then return true end -- 26 = tab strip above the window
    if f.edit:HasFocus() or (f.glow and f.glow:IsShown()) then return true end
    local r, p = ns.replyMenu, ns.Emoji and ns.Emoji.picker
    if (r and r:IsShown() and r.owner == f) or (p and p:IsShown() and p.owner == f) then return true end
    return now - (f.lastActivity or 0) < FADE_AFTER
end

local function FadeTick()
    local now = GetTime()
    for _, f in pairs(windows) do
        if f:IsShown() then
            if not f.fadeSeen then f.fadeSeen = true; f.lastActivity = now end
            local want = WindowBusy(f, now) and 1 or ns.DB.fadeAlpha
            local a = f:GetAlpha()
            if math.abs(a - want) > 0.01 then
                f:SetAlpha(a + (want - a) * 0.35)
            elseif a ~= want then
                f:SetAlpha(want)
            end
        else
            f.fadeSeen = nil
        end
    end
end

local function ApplyFade()
    if fadeTicker then fadeTicker:Cancel(); fadeTicker = nil end
    if ns.DB.fadeIdle and C_Timer and C_Timer.NewTicker then
        fadeTicker = C_Timer.NewTicker(0.05, FadeTick)
    else
        for _, f in pairs(windows) do f:SetAlpha(1) end
    end
end
ns.ApplyFade = ApplyFade

----------------------------------------------------------------------
-- Pinned conversations: at the top of the whisper list, and their tabs
-- open before the others.
----------------------------------------------------------------------
ns.TogglePin = function(name)
    local key = FullName(name)
    if not key then return end
    if ns.DB.pinned[key] then
        ns.DB.pinned[key] = nil
        Print(ShortName(key) .. " unpinned.")
    else
        ns.DB.pinned[key] = true
        Print(ShortName(key) .. " pinned to the top of the whisper list.")
    end
    local i = IndexOf(tabOrder, key)
    if i then
        table.remove(tabOrder, i)
        ns.InsertTab(key)
    end
    if ns.DB.tabbed then ns.RefreshTabs() end
    ns.UpdateSessionUI()
end

----------------------------------------------------------------------
-- Events
----------------------------------------------------------------------
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("UPDATE_BINDINGS")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:SetScript("OnEvent", function(_, event, ...)
    if not ns.DB then return end
    if event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if AnySecret(msg) or type(msg) ~= "string" then return end
        local key = NotFoundKey(msg)
        if key then
            ns.AddNotice(key, "Not delivered: " .. ShortName(key) .. " is offline or the name is wrong.")
            return
        end
        local on = CAME_ONLINE and msg:match(CAME_ONLINE)
        if on then
            key = NameFrom(on)
            if HasConversation(key) then ns.AddNotice(key, ShortName(key) .. " came online.") end
            return
        end
        local off = WENT_OFFLINE and msg:match(WENT_OFFLINE)
        if off then
            key = NameFrom(off)
            if HasConversation(key) then ns.AddNotice(key, ShortName(key) .. " went offline.") end
        end
    elseif event == "CHAT_MSG_AFK" or event == "CHAT_MSG_DND" then
        local text, sender = ...
        if AnySecret(text, sender) then return end
        local key = FullName(sender)
        if not HasConversation(key) then return end
        local what = event == "CHAT_MSG_AFK" and " is away" or " doesn't want to be disturbed"
        local reply = (type(text) == "string" and text ~= "") and (": " .. text) or "."
        ns.AddNotice(key, ShortName(key) .. what .. reply)
    elseif event == "BN_FRIEND_ACCOUNT_ONLINE" or event == "BN_FRIEND_ACCOUNT_OFFLINE" then
        local id = ...
        if AnySecret(id) then return end
        local key = BNKeyFromID(id)
        if not HasConversation(key) then return end
        ns.AddNotice(key, ShortName(key) .. (event == "BN_FRIEND_ACCOUNT_ONLINE" and " came online." or " went offline."))
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin = ...
        if isInitialLogin and ns.DB.busy then ns.DB.busy = false end
    elseif event == "PLAYER_LOGIN" then
        HookChatBoxes()
        ApplyReplyKey()
        ApplyFade()
    elseif event == "UPDATE_BINDINGS" then
        -- you changed the Reply key: move the override to the new key
        C_Timer.After(0, ApplyReplyKey)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if bindPending then ApplyReplyKey() end
    end
end)

-- With "Hide whispers from the main chat" on, the away/busy replies and
-- "No player named..." for your DMme conversations are shown only in DMme.
if AddFilter then
    local function hideAwayReply(_, _, msg, sender)
        if not (ns.DB and ns.DB.hideFromChat and ns.DB.notices) or AnySecret(msg, sender) then return false end
        return HasConversation(FullName(sender))
    end
    AddFilter("CHAT_MSG_AFK", hideAwayReply)
    AddFilter("CHAT_MSG_DND", hideAwayReply)
    AddFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
        if not (ns.DB and ns.DB.hideFromChat and ns.DB.notices) or AnySecret(msg) or type(msg) ~= "string" then return false end
        return NotFoundKey(msg) ~= nil
    end)
end

-- Key binding (Bindings.xml)
BINDING_NAME_DMME_BUSY = "Busy auto-reply on / off"
function DMme_ToggleBusy() if ns.DB then SetBusy(not ns.DB.busy) end end
