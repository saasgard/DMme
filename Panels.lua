-- DMme: Whisper list (Recent / Friends) and the minimap button.
-- Part of DMme; loads after the files before it in DMme.toc and shares
-- names with them through the addon namespace (ns).
local ADDON, ns = ...

-- from earlier files (these never change after loading)
local BACKDROP_TEMPLATE = ns.BACKDROP_TEMPLATE
local BNKeyFromID = ns.BNKeyFromID
local C = ns.C
local ClassFileFromName = ns.ClassFileFromName
local ClassRGB = ns.ClassRGB
local Colorize = ns.Colorize
local Emoji = ns.Emoji
local FLAT = ns.FLAT
local FlatButton = ns.FlatButton
local FullName = ns.FullName
local IndexOf = ns.IndexOf
local IsBN = ns.IsBN
local KeyColorize = ns.KeyColorize
local KeyInfo = ns.KeyInfo
local KeyRGB = ns.KeyRGB
local KeyTextRGB = ns.KeyTextRGB
local KeyUnread = ns.KeyUnread
local MEDIA_ICON = ns.MEDIA_ICON
local OnTheme = ns.OnTheme
local OnUIAccent = ns.OnUIAccent
local ShortName = ns.ShortName
local ShowPlayerMenu = ns.ShowPlayerMenu
local Skin = ns.Skin
local SkinHeader = ns.SkinHeader
local UIAccent = ns.UIAccent
local WHITE = ns.WHITE
local tabOrder = ns.tabOrder
local windows = ns.windows

----------------------------------------------------------------------
-- Session list + minimap button
----------------------------------------------------------------------
local mmButton
local LIST_ROWS, LIST_ROW_H = 10, 36

local function IsActiveConversation(key)
    if ns.DB.tabbed then return IndexOf(tabOrder, key) ~= nil end
    local f = windows[key]
    return f and f:IsShown() or false
end

local function SessionKeys()
    local list = {}
    for key in pairs(ns.session) do list[#list + 1] = key end
    table.sort(list, function(a, b) return ns.session[a].t > ns.session[b].t end)
    return list
end

-- Number of conversations (windows/tabs) that have unread whispers.
local function UnreadConversations()
    local n = 0
    for key in pairs(windows) do
        if KeyUnread(key) > 0 then n = n + 1 end
    end
    for key in pairs(ns.session) do -- conversations without a window yet (after /reload)
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
    ns.session[key] = nil
    local f = windows[key]
    if ns.DB.tabbed and IndexOf(tabOrder, key) then
        ns.CloseTab(key)
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
    ns.UpdateSessionUI()
end

local function ClearSession()
    for _, key in ipairs(SessionKeys()) do RemoveSession(key) end
end

-- Mark every conversation as read (clears badges, glows and tab markers)
-- without closing anything or removing it from the list.
local function ClearAllUnread()
    for _, f in pairs(windows) do
        if (f.unread or 0) > 0 then ns.StopFlash(f) end
    end
    for _, s in pairs(ns.session) do s.unread = nil end
    if ns.DB.tabbed and ns.RefreshTabs then ns.RefreshTabs() end
    ns.UpdateSessionUI()
end

local function CreateSessionPanel()
    local p = CreateFrame("Frame", "DMmeSessionList", UIParent, BACKDROP_TEMPLATE)
    p:SetWidth(290)
    Skin(p, "window")
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
    OnTheme(function(classic) shadow:SetShown(not classic) end) -- game windows have no drop shadow

    local header = p:CreateTexture(nil, "BORDER")
    SkinHeader(header, 29)
    local line = p:CreateTexture(nil, "ARTWORK")
    line:SetTexture(WHITE)
    OnUIAccent(function(r, g, b) line:SetVertexColor(r, g, b, 0.9) end)
    line:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    line:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    line:SetHeight(1)

    -- Two tabs: Recent (this session's whispers) and Friends (who is online).
    -- The Friends tab lets you start a chat without going through Blizzard's
    -- Friends list menu (DMme can't add to that menu without tainting it).
    local tabs = {}
    local function StyleTabs()
        for _, t in ipairs(tabs) do
            if t.mode == p.mode then
                t:SetBackdropColor(unpack(C.buttonHi))
                t:SetBackdropBorderColor(UIAccent())
                t.label:SetTextColor(1, 1, 1)
            else
                t:SetBackdropColor(unpack(C.button))
                t:SetBackdropBorderColor(unpack(C.border))
                t.label:SetTextColor(unpack(C.btnText))
            end
        end
    end
    local function Tab(mode, text, tip)
        local t = FlatButton(p, text, { width = 74, tooltip = text, tooltipText = tip })
        t.mode = mode
        t:SetScript("OnClick", function()
            p.mode = mode
            ns.DB.listMode = mode
            p.offset = 0
            p:Refresh()
        end)
        t:HookScript("OnLeave", StyleTabs)
        tabs[#tabs + 1] = t
        return t
    end
    local recentTab = Tab("recent", "Recent", "Whispers this session.")
    recentTab:SetPoint("LEFT", p, "TOPLEFT", 8, -15)
    local friendsTab = Tab("friends", "Friends", "Friends who are online.\nClick one to start a chat in DMme.")
    friendsTab:SetPoint("LEFT", recentTab, "RIGHT", 4, 0)
    p.mode = (ns.DB.listMode == "friends") and "friends" or "recent"

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

    -- Online friends: Battle.net first (WoW players on top), then character
    -- friends. Each entry: { key, name, sub, status, classFile, isBN, order }.
    -- Only reads friend info; never touches Blizzard's Friends frame.
    local CLIENT_NAMES = { App = "Battle.net app", BSAp = "Battle.net mobile", WoW = "World of Warcraft" }
    local function OnlineFriends()
        local list, seenChars = {}, {}
        if C_BattleNet and C_BattleNet.GetFriendAccountInfo and BNGetNumFriends then
            for i = 1, (BNGetNumFriends() or 0) do
                local a = C_BattleNet.GetFriendAccountInfo(i)
                local g = a and a.gameAccountInfo
                if a and g and g.isOnline and a.bnetAccountID then
                    local key = BNKeyFromID(a.bnetAccountID)
                    local name = a.accountName or (a.battleTag and a.battleTag:match("^[^#]+")) or "?"
                    local e = { key = key, name = name, isBN = true, order = 3,
                        sortName = (a.battleTag or name):lower() }
                    if g.clientProgram == "WoW" and g.characterName and g.characterName ~= "" then
                        local classFile = ClassFileFromName(g.className)
                        local cr, cg, cb = ClassRGB(classFile)
                        e.classFile = classFile
                        e.sub = Colorize(g.characterName, cr or 0.85, cg or 0.85, cb or 0.9)
                            .. ((g.areaName and g.areaName ~= "") and ("  |cff8a8a98" .. g.areaName .. "|r") or "")
                        e.order = (g.wowProjectID == WOW_PROJECT_ID) and 1 or 2
                        if g.realmName and g.realmName ~= "" then
                            seenChars[FullName(g.characterName .. "-" .. g.realmName) or ""] = true
                        end
                    else
                        e.sub = "|cff8a8a98" .. (CLIENT_NAMES[g.clientProgram] or g.richPresence or "Online") .. "|r"
                    end
                    if a.isAFK or g.isGameAFK then e.status = "|cffffd100AFK|r"
                    elseif a.isDND or g.isGameBusy then e.status = "|cffff5555Busy|r" end
                    list[#list + 1] = e
                end
            end
        end
        if C_FriendList and C_FriendList.GetNumFriends and C_FriendList.GetFriendInfoByIndex then
            for i = 1, (C_FriendList.GetNumFriends() or 0) do
                local info = C_FriendList.GetFriendInfoByIndex(i)
                local key = info and info.connected and FullName(info.name)
                if key and not seenChars[key] then
                    if info.guid and ns.DB.guids then ns.DB.guids[key] = ns.DB.guids[key] or info.guid end
                    local classFile = ClassFileFromName(info.className)
                    local e = { key = key, name = ShortName(key), classFile = classFile, order = 1,
                        sortName = ShortName(key):lower() }
                    local bits = {}
                    if info.level and info.level > 0 then bits[#bits + 1] = "Level " .. info.level end
                    if info.area and info.area ~= "" then bits[#bits + 1] = info.area end
                    e.sub = "|cff8a8a98" .. table.concat(bits, "  ") .. "|r"
                    if info.afk then e.status = "|cffffd100AFK|r"
                    elseif info.dnd then e.status = "|cffff5555Busy|r" end
                    list[#list + 1] = e
                end
            end
        end
        table.sort(list, function(x, y)
            if x.order ~= y.order then return x.order < y.order end
            return x.sortName < y.sortName
        end)
        return list
    end

    -- keep the Friends tab current while it is open (our own frame, our own events)
    for _, ev in ipairs({ "BN_FRIEND_INFO_CHANGED", "BN_FRIEND_LIST_SIZE_CHANGED", "FRIENDLIST_UPDATE",
                          "BN_CONNECTED", "BN_DISCONNECTED" }) do
        pcall(p.RegisterEvent, p, ev)
    end
    p:SetScript("OnEvent", function(self)
        if not (self:IsShown() and self.mode == "friends") or self.pending then return end
        self.pending = true -- friend updates come in bursts: refresh once
        C_Timer.After(0.3, function() self.pending = nil; if self:IsShown() then self:Refresh() end end)
    end)

    p.rows = {}
    for i = 1, LIST_ROWS do
        local r = CreateFrame("Button", nil, p, BACKDROP_TEMPLATE)
        r:SetHeight(LIST_ROW_H)
        r:SetPoint("TOPLEFT", 6, -(34 + (i - 1) * LIST_ROW_H))
        r:SetPoint("TOPRIGHT", -6, -(34 + (i - 1) * LIST_ROW_H))
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
                ns.OpenWindow(self.key); p:Hide()
            end
        end)
        p.rows[i] = r
    end

    p:EnableMouseWheel(true)
    p:SetScript("OnMouseWheel", function(self, delta)
        local n = self.count or 0
        self.offset = math.min(math.max(0, n - LIST_ROWS), math.max(0, self.offset - delta))
        self:Refresh()
    end)

    local function SetIcon(r, isBN, classFile)
        if classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
            r.icon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
            r.icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[classFile]))
        elseif isBN then
            r.icon:SetTexture("Interface\\FriendsFrame\\Battlenet-Battleneticon")
            r.icon:SetTexCoord(0, 1, 0, 1)
        else
            r.icon:SetTexture("Interface\\Icons\\INV_Letter_15")
            r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end

    -- Friends tab
    local function RefreshFriends(self)
        local list = OnlineFriends()
        self.count = #list
        friendsTab.label:SetText("Friends (" .. #list .. ")")
        self.offset = math.min(self.offset, math.max(0, #list - LIST_ROWS))
        local shown = math.min(#list, LIST_ROWS)
        self.empty:SetText("No friends online.")
        self.empty:SetShown(#list == 0)
        for i, r in ipairs(self.rows) do
            local e = list[self.offset + i]
            r.key = e and e.key
            r.del:Hide()
            if e then
                if e.isBN then
                    r.name:SetText(Colorize(e.name, C.bn[1], C.bn[2], C.bn[3]))
                else
                    local cr, cg, cb = ClassRGB(e.classFile)
                    r.name:SetText(Colorize(e.name, cr or 1, cg or 1, cb or 1))
                end
                r.preview:SetText(e.sub or "")
                r.when:SetText(e.status or "")
                local unread = KeyUnread(e.key)
                r.badge:SetText(unread > 0 and KeyColorize(e.key, unread .. " new") or "")
                r.bar:SetShown(ns.session[e.key] ~= nil and IsActiveConversation(e.key))
                SetIcon(r, e.isBN, e.classFile)
                r:Show()
            else
                r:Hide()
            end
        end
        return shown
    end

    function p:Refresh()
        clear:SetShown(self.mode == "recent")
        StyleTabs()
        local shown
        if self.mode == "friends" then
            shown = RefreshFriends(self)
            self:SetHeight(34 + math.max(shown, 1) * LIST_ROW_H + (shown == 0 and 20 or 6))
            return
        end
        friendsTab.label:SetText("Friends")
        self.empty:SetText("No whispers yet this session.")
        local keys = SessionKeys()
        self.count = #keys
        self.offset = math.min(self.offset, math.max(0, #keys - LIST_ROWS))
        shown = math.min(#keys, LIST_ROWS)
        self.empty:SetShown(#keys == 0)
        for i, r in ipairs(self.rows) do
            local key = keys[self.offset + i]
            r.key = key
            r.del:Show()
            if key then
                local s = ns.session[key]
                local classFile = KeyInfo(key)
                local cr, cg, cb = KeyRGB(key)
                r.name:SetText(Colorize(ShortName(key), cr, cg, cb))
                r.when:SetText(Ago(s.t))
                local text = s.text or ""
                if s.incoming then
                    local tr, tg, tb = KeyTextRGB(key)
                    r.preview:SetText(Colorize(Emoji.Render(text), tr * 0.8, tg * 0.8, tb * 0.8)) -- a bit dimmer than the name
                else
                    r.preview:SetText("|cff8a8a98You: " .. Emoji.Render(text) .. "|r")
                end
                local unread = KeyUnread(key)
                r.badge:SetText(unread > 0 and KeyColorize(key, unread .. " new") or "")
                r.bar:SetShown(IsActiveConversation(key))
                if IsBN(key) then
                    SetIcon(r, true, nil) -- Battle.net icon (as before)
                else
                    SetIcon(r, false, classFile)
                end
                r:Show()
            else
                r:Hide()
            end
        end
        self:SetHeight(34 + math.max(shown, 1) * LIST_ROW_H + (shown == 0 and 20 or 6))
    end

    ns.sessionPanel = p
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
                Ago(ns.session[key].t), cr or 1, cg or 1, cb or 1, 0.6, 0.6, 0.65)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("|cffffd100Left-click|r  whispers and online friends", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffd100Right-click|r  settings", 0.8, 0.8, 0.8)
    -- the addon menu (compartment) may not pass middle clicks, so only promise Shift-click there
    GameTooltip:AddLine("|cffffd100" .. (isMinimapButton and "Middle- or Shift-click" or "Shift-click")
        .. "|r  mark all as read", 0.8, 0.8, 0.8)
    if isMinimapButton == "float" then
        if ns.DB.floatButton.locked then
            GameTooltip:AddLine("Locked (unlock in Settings > General)", 0.6, 0.6, 0.65)
        else
            GameTooltip:AddLine("|cffffd100Drag|r  move button", 0.8, 0.8, 0.8)
            GameTooltip:AddLine("|cffffd100Ctrl + scroll|r  resize", 0.8, 0.8, 0.8)
        end
    elseif isMinimapButton then
        GameTooltip:AddLine("|cffffd100Drag|r  move button" .. (ns.DB.minimap.detached and " (anywhere)" or ""), 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

-- anchor: frame to open next to (default: the minimap button)
local function ToggleSessionPanel(anchor)
    local p = ns.sessionPanel or CreateSessionPanel()
    if p:IsShown() then p:Hide(); return end
    p:SetScale(ns.DB.scale or 1)
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
    if ns.DB.minimap.detached then
        if b:GetParent() ~= UIParent then b:SetParent(UIParent) end
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        local p = ns.DB.minimap.pos
        if p then
            b:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        else
            b:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -220, -40)
        end
    else
        if b:GetParent() ~= Minimap then b:SetParent(Minimap) end
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        local angle = math.rad(ns.DB.minimap.angle or 200)
        local r = (Minimap:GetWidth() / 2) + 5
        b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
    end
end

-- Detach the button from the minimap (free-floating) or snap it back.
local function SetMinimapDetached(detached)
    ns.DB.minimap.detached = detached and true or false
    if mmButton and detached and not ns.DB.minimap.pos then
        -- start floating exactly where it is now
        local x, y = mmButton:GetCenter()
        if x then
            local s = mmButton:GetEffectiveScale() / UIParent:GetEffectiveScale()
            ns.DB.minimap.pos = { "CENTER", "BOTTOMLEFT", x * s, y * s }
        end
    end
    if mmButton then PositionMinimapButton() end
end

-- The round DMme button: icon, unread badge, pulsing glow. Used by both the
-- minimap button and the floating button (31x31; the floating one is scaled).
local function BuildDMmeButton(name, parent)
    local b = CreateFrame("Button", name, parent)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
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
    glow:SetAlpha(0)
    OnTheme(function(classic)
        -- pink in Dark; the game's red notification badge and a gold glow in game styles
        if classic then
            badge:SetBackdropColor(0.72, 0.07, 0.04, 1)
            glow:SetVertexColor(1, 0.82, 0.25, 1)
        else
            badge:SetBackdropColor(0.85, 0.25, 0.85, 1)
            glow:SetVertexColor(1, 0.35, 1, 1)
        end
    end)
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

    b:SetScript("OnClick", function(self, button)
        if button == "MiddleButton" or (button == "LeftButton" and IsShiftKeyDown()) then
            ClearAllUnread()
        elseif button == "RightButton" then
            ns.ShowSettings()
        else
            ToggleSessionPanel(self)
        end
    end)
    b:SetMovable(true)
    b:SetClampedToScreen(true)
    -- we save the position ourselves; don't let the game's layout cache fight us
    if b.SetDontSavePosition then b:SetDontSavePosition(true) end
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

ns.CreateMinimapButton = function()
    if mmButton or not Minimap then return end
    local b = BuildDMmeButton("DMmeMinimapButton", Minimap)
    b:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        if ns.DB.minimap.detached then
            self:StartMoving() -- free-floating: drag anywhere
            return
        end
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            ns.DB.minimap.angle = math.deg(math.atan2(py / s - my, px / s - mx))
            PositionMinimapButton()
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if ns.DB.minimap.detached then
            self:StopMovingOrSizing()
            local point, _, relPoint, x, y = self:GetPoint(1)
            ns.DB.minimap.pos = { point, relPoint, x, y }
        end
    end)
    b:SetScript("OnEnter", function(self) ShowSessionTooltip(self, "ANCHOR_LEFT", true) end)

    mmButton = b
    PositionMinimapButton()
end

----------------------------------------------------------------------
-- Floating button: the same button, but its own frame on the screen (not
-- on the minimap), so minimap-button collector addons leave it alone.
-- Drag to move, Ctrl + mouse wheel to resize (or Settings > General).
-- DB.floatButton = { show, size (pixels), locked, pos = { x, y } }
----------------------------------------------------------------------
local floatButton
local FLOAT_MIN, FLOAT_MAX, FLOAT_BASE = 20, 80, 31

local function PositionFloatButton()
    local b, o = floatButton, ns.DB.floatButton
    local s = b:GetScale()
    b:ClearAllPoints()
    if o.pos then
        -- saved in screen (UIParent) units; SetPoint offsets are in the button's scale
        b:SetPoint("CENTER", UIParent, "BOTTOMLEFT", o.pos[1] / s, o.pos[2] / s)
    else
        b:SetPoint("CENTER", UIParent, "CENTER", 0, 200 / s)
    end
end

local function SaveFloatPosition(b)
    local x, y = b:GetCenter()
    if not x then return end
    local s = b:GetEffectiveScale() / UIParent:GetEffectiveScale()
    ns.DB.floatButton.pos = { x * s, y * s }
end

-- Size in pixels (the minimap button is 31). Keeps the button centred where it is.
local function SetFloatSize(size)
    size = math.max(FLOAT_MIN, math.min(FLOAT_MAX, math.floor(size + 0.5)))
    ns.DB.floatButton.size = size
    if floatButton then
        if floatButton:GetCenter() then SaveFloatPosition(floatButton) end
        floatButton:SetScale(size / FLOAT_BASE)
        PositionFloatButton()
    end
    if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
end

ns.CreateFloatButton = function()
    if floatButton then return end
    local b = BuildDMmeButton("DMmeFloatingButton", UIParent)
    b:SetScale((ns.DB.floatButton.size or 36) / FLOAT_BASE)
    b:SetScript("OnDragStart", function(self)
        if ns.DB.floatButton.locked then return end
        GameTooltip:Hide()
        self:StartMoving()
    end)
    b:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveFloatPosition(self)
        PositionFloatButton() -- re-anchor from the saved spot (independent of scale)
    end)
    b:EnableMouseWheel(true)
    b:SetScript("OnMouseWheel", function(_, delta)
        if IsControlKeyDown() and not ns.DB.floatButton.locked then
            SetFloatSize((ns.DB.floatButton.size or 36) + delta * 2)
        end
    end)
    b:SetScript("OnEnter", function(self) ShowSessionTooltip(self, "ANCHOR_LEFT", "float") end)
    floatButton = b
    PositionFloatButton()
    ns.UpdateSessionUI()
end

local function SetFloatShown(show)
    ns.DB.floatButton.show = show and true or false
    if show then
        ns.CreateFloatButton()
        floatButton:Show()
    elseif floatButton then
        floatButton:Hide()
    end
end

-- Put the floating button back in the middle of the screen at the default size.
local function ResetFloatButton()
    SetFloatSize(36)              -- first: resizing keeps the current spot...
    ns.DB.floatButton.pos = nil   -- ...then forget the spot
    if floatButton then PositionFloatButton() end
end

local function SetMinimapShown(show)
    ns.DB.minimap.hide = not show
    if show then
        ns.CreateMinimapButton()
        if mmButton then mmButton:Show() end
    elseif mmButton then
        mmButton:Hide()
    end
end

ns.UpdateSessionUI = function()
    if not ns.DB then return end
    local n
    for _, b in ipairs({ mmButton or false, floatButton or false }) do
        if b then
            n = n or UnreadConversations()
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
    end
    if ns.sessionPanel and ns.sessionPanel:IsShown() then ns.sessionPanel:Refresh() end
end

-- shared with the files after this one (see their 'from earlier files')
ns.ShowSessionTooltip = ShowSessionTooltip
ns.ToggleSessionPanel = ToggleSessionPanel
ns.ClearAllUnread = ClearAllUnread
ns.SetMinimapDetached = SetMinimapDetached
ns.SetMinimapShown = SetMinimapShown
ns.SetFloatShown = SetFloatShown
ns.SetFloatSize = SetFloatSize
ns.ResetFloatButton = ResetFloatButton
