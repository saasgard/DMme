-- DMme: Buttons, quick replies, emoji picker, whisper windows and tabs.
-- Part of DMme; loads after the files before it in DMme.toc and shares
-- names with them through the addon namespace (ns).
local ADDON, ns = ...

-- from earlier files (these never change after loading)
local ApplyUIAccent = ns.ApplyUIAccent
local BACKDROP_TEMPLATE = ns.BACKDROP_TEMPLATE
local BNInfo = ns.BNInfo
local BNResolve = ns.BNResolve
local C = ns.C
local ClassRGB = ns.ClassRGB
local Colorize = ns.Colorize
local Emoji = ns.Emoji
local FLAT = ns.FLAT
local FormatEntry = ns.FormatEntry
local FullName = ns.FullName
local GuildInviteName = ns.GuildInviteName
local HEADER_H = ns.HEADER_H
local HandleLink = ns.HandleLink
local IsBN = ns.IsBN
local IsGameStyle = ns.IsGameStyle
local KeyColorize = ns.KeyColorize
local KeyHighlight = ns.KeyHighlight
local KeyInfo = ns.KeyInfo
local KeyRGB = ns.KeyRGB
local MEDIA_GEAR = ns.MEDIA_GEAR
local OnTheme = ns.OnTheme
local PartyInviteName = ns.PartyInviteName
local Print = ns.Print
local SendWhisperTo = ns.SendWhisperTo
local ShortName = ns.ShortName
local ShowPlayerMenu = ns.ShowPlayerMenu
local Skin = ns.Skin
local SkinHeader = ns.SkinHeader
local TOOLTIP_BD = ns.TOOLTIP_BD
local UIAccent = ns.UIAccent
local WHITE = ns.WHITE
local WhoName = ns.WhoName
local msgFont = ns.msgFont
local windows = ns.windows

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
    local function normal()
        if opts.bare then
            b:SetBackdropColor(0, 0, 0, 0)
            b:SetBackdropBorderColor(0, 0, 0, 0)
        else
            b:SetBackdropColor(unpack(C.button))
            b:SetBackdropBorderColor(unpack(C.border))
        end
        b.label:SetTextColor(unpack(C.btnText))
    end
    b.cwFlat = true
    b.label = b:CreateFontString(nil, "OVERLAY", opts.font or "GameFontHighlightSmall")
    b.label:SetPoint("CENTER")
    b.label:SetText(text)
    b:SetSize(opts.width or (b.label:GetStringWidth() + 18), opts.height or 20)
    OnTheme(function(classic)
        b:SetBackdrop((classic and not opts.bare) and TOOLTIP_BD or FLAT)
        normal()
    end)

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
-- Quick replies: saved messages you can send with one click
-- (the "Replies" button in a whisper window). Stored in DB.replies.
----------------------------------------------------------------------
local MAX_REPLIES = 20
local DEFAULT_REPLIES = {
    "Thanks!",
    "On my way!",
    "Sorry, busy right now - I'll get back to you soon.",
    "Can't right now, maybe later.",
}
-- shared between files: ns.replyMenu
local REPLY_ROW_H = 20

local function Trim(s) return (s or ""):match("^%s*(.-)%s*$") end

local function CreateReplyMenu()
    local m = CreateFrame("Frame", "DMmeReplies", UIParent, BACKDROP_TEMPLATE)
    m:SetWidth(260)
    Skin(m, "list")
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    m:SetToplevel(true)
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    m:Hide()
    tinsert(UISpecialFrames, "DMmeReplies")
    m.rows = {}

    local title = m:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText("Quick replies")
    local hint = m:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPRIGHT", -10, -8)
    m.hint = hint -- text set in Refresh (depends on the Shift-to-send setting)

    m.empty = m:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    m.empty:SetPoint("TOPLEFT", 10, -28)
    m.empty:SetPoint("RIGHT", -10, 0)
    m.empty:SetJustifyH("LEFT")
    m.empty:SetText("No saved replies yet.")

    -- save whatever is typed in the whisper box as a new quick reply
    local add = FlatButton(m, "+ Save typed text", { tooltip = "Save a quick reply",
        tooltipText = "Type a message in the whisper box, then click this to save it as a quick reply." })
    add:SetPoint("BOTTOMLEFT", 8, 8)
    add:SetPoint("BOTTOMRIGHT", -8, 8)
    add:SetScript("OnClick", function()
        local f = m.owner
        if not f then return end
        local text = Trim(f.edit:GetText())
        if text == "" then
            Print("Type the reply in the whisper box first, then click |cffffd100+ Save typed text|r.")
            f.edit:SetFocus()
            return
        end
        for _, r in ipairs(ns.DB.replies) do
            if r == text then Print("That reply is already saved."); return end
        end
        if #ns.DB.replies >= MAX_REPLIES then
            Print("You can save up to " .. MAX_REPLIES .. " quick replies. Delete one first (the x next to it).")
            return
        end
        tinsert(ns.DB.replies, text)
        f.edit:SetText("")
        m:Refresh()
    end)

    local function Row(i)
        local row = m.rows[i]
        if row then return row end
        row = CreateFrame("Button", nil, m, BACKDROP_TEMPLATE)
        row:SetHeight(REPLY_ROW_H)
        row:SetPoint("TOPLEFT", 4, -(24 + (i - 1) * REPLY_ROW_H))
        row:SetPoint("TOPRIGHT", -4, -(24 + (i - 1) * REPLY_ROW_H))
        row:SetBackdrop({ bgFile = WHITE })
        row:SetBackdropColor(0, 0, 0, 0)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 8, 0)
        row.text:SetPoint("RIGHT", -58, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.del = FlatButton(row, "x", { bare = true, width = 18, height = 18, hoverColor = { 0.9, 0.25, 0.25 },
            tooltip = "Delete", tooltipText = "Remove this quick reply." })
        row.del:SetPoint("RIGHT", -2, 0)
        row.del:SetScript("OnClick", function()
            tremove(ns.DB.replies, row.index)
            m:Refresh()
        end)
        -- move up / down
        local function Arrow(up)
            local a = CreateFrame("Button", nil, row)
            a:SetSize(16, 16)
            local base = up and "Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-" or "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-"
            a:SetNormalTexture(base .. "Up")
            a:SetPushedTexture(base .. "Down")
            a:SetDisabledTexture(base .. "Disabled")
            a:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
            a:SetScript("OnClick", function()
                local idx = row.index
                local j = up and idx - 1 or idx + 1
                local list = ns.DB.replies
                if list[idx] and list[j] then
                    list[idx], list[j] = list[j], list[idx]
                    m:Refresh()
                end
            end)
            a:SetScript("OnEnter", function(self) ShowTooltip(self, up and "Move up" or "Move down") end)
            a:SetScript("OnLeave", function() GameTooltip:Hide() end)
            return a
        end
        row.down = Arrow(false)
        row.down:SetPoint("RIGHT", row.del, "LEFT", -1, 0)
        row.up = Arrow(true)
        row.up:SetPoint("RIGHT", row.down, "LEFT", 0, 0)
        row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(1, 1, 1, 0.08)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.reply or "", 1, 1, 1, 1, true)
            if ns.DB.replyShiftSend then
                GameTooltip:AddLine("Click: put it in the box", 1, 0.82, 0)
                GameTooltip:AddLine("Shift-click: send now", 1, 0.82, 0)
            else
                GameTooltip:AddLine("Click: send now", 1, 0.82, 0)
                GameTooltip:AddLine("Right-click or Shift-click: put it in the box to edit first", 1, 0.82, 0)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0, 0, 0, 0)
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function(self, button)
            local f = m.owner
            if not (f and self.reply) then return end
            m:Hide()
            local send
            if ns.DB.replyShiftSend then
                -- safety on: only Shift + left-click sends
                send = button == "LeftButton" and IsShiftKeyDown()
            else
                send = button == "LeftButton" and not IsShiftKeyDown()
            end
            if not send then
                f.edit:SetText(self.reply)
                f.edit:SetFocus()
                f.edit:SetCursorPosition(#self.reply)
            else
                SendWhisperTo(f.key, self.reply)
            end
        end)
        m.rows[i] = row
        return row
    end

    function m:Refresh()
        self.hint:SetText(ns.DB.replyShiftSend and "click: edit   shift-click: send" or "click: send   right-click: edit")
        local n = #ns.DB.replies
        for i = 1, n do
            local row = Row(i)
            row.index = i
            row.reply = ns.DB.replies[i]
            row.text:SetText(Emoji.Render(ns.DB.replies[i]))
            row.up:SetEnabled(i > 1)
            row.down:SetEnabled(i < n)
            row:Show()
        end
        for i = n + 1, #self.rows do self.rows[i]:Hide() end
        self.empty:SetShown(n == 0)
        self:SetHeight(24 + math.max(n, 1) * REPLY_ROW_H + 36)
    end

    ns.replyMenu = m
    return m
end

-- Open/close the quick reply list for whisper window f, under `anchor`.
local function ToggleReplies(f, anchor)
    local m = ns.replyMenu or CreateReplyMenu()
    if m:IsShown() and m.owner == f then m:Hide(); return end
    m.owner = f
    m:SetScale(ns.DB.scale or 1)
    m:ClearAllPoints()
    m:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    m:Refresh()
    m:Show()
    m:Raise()
end

-- Emoji picker: a grid of every emoji; clicking one types its shortcut into
-- the whisper box (the other player sees the shortcut, e.g. ":fire:", unless
-- they use DMme too).
Emoji.COLS, Emoji.CELL = 8, 26
function Emoji.CreatePicker()
    local EMOJI_COLS, EMOJI_CELL = Emoji.COLS, Emoji.CELL
    local p = CreateFrame("Frame", "DMmeEmoji", UIParent, BACKDROP_TEMPLATE)
    local rows = math.ceil(#Emoji.LIST / EMOJI_COLS)
    p:SetSize(EMOJI_COLS * EMOJI_CELL + 12, rows * EMOJI_CELL + 12)
    Skin(p, "list")
    p:SetFrameStrata("FULLSCREEN_DIALOG")
    p:SetToplevel(true)
    p:SetClampedToScreen(true)
    p:EnableMouse(true)
    p:Hide()
    tinsert(UISpecialFrames, "DMmeEmoji")
    for i, e in ipairs(Emoji.LIST) do
        local b = CreateFrame("Button", nil, p)
        b:SetSize(EMOJI_CELL, EMOJI_CELL)
        local col, row = (i - 1) % EMOJI_COLS, math.floor((i - 1) / EMOJI_COLS)
        b:SetPoint("TOPLEFT", 6 + col * EMOJI_CELL, -6 - row * EMOJI_CELL)
        local t = b:CreateTexture(nil, "ARTWORK")
        t:SetPoint("TOPLEFT", 3, -3)
        t:SetPoint("BOTTOMRIGHT", -3, 3)
        t:SetTexture(Emoji.PATH .. e[1])
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(table.concat(e[3], "   "), 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function()
            local f = p.owner
            if not f then return end
            local cur = f.edit:GetText() or ""
            local sep = (cur ~= "" and not cur:find("%s$")) and " " or ""
            f.edit:SetFocus()
            f.edit:Insert(sep .. e[3][1] .. " ")
            if not IsShiftKeyDown() then p:Hide() end -- Shift-click: pick several
        end)
    end
    Emoji.picker = p
    return p
end

function Emoji.TogglePicker(f, anchor)
    local p = Emoji.picker or Emoji.CreatePicker()
    if p:IsShown() and p.owner == f then p:Hide(); return end
    p.owner = f
    p:SetScale(ns.DB.scale or 1)
    p:ClearAllPoints()
    p:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 4, 4)
    p:Show()
    p:Raise()
end

-- Show/hide the picker button in a whisper window (follows the setting).
function Emoji.LayoutButton(f)
    local on = Emoji.On()
    f.emojiBtn:SetShown(on)
    f.edit:ClearAllPoints()
    f.edit:SetPoint("TOPLEFT", 8, 0)
    f.edit:SetPoint("BOTTOMRIGHT", on and -26 or -8, 0)
    if not on and Emoji.picker and Emoji.picker.owner == f then Emoji.picker:Hide() end
end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
local function SavePosition(f)
    local point, _, _, x, y = f:GetPoint(1)
    if not point then return end
    local w, h = f:GetWidth(), f.minimized and f.restoreHeight or f:GetHeight()
    if ns.DB.tabbed then
        ns.DB.tabPos = { point, x, y, w, h }          -- one shared spot for the tabbed window
    else
        ns.DB.positions[f.key] = { point, x, y, w, h, f.minimized }
    end
end

-- Place a window: the shared tabbed spot, or its own saved spot.
local function ApplyPosition(f)
    local p = ns.DB.tabbed and ns.DB.tabPos or (not ns.DB.tabbed and ns.DB.positions[f.key])
    local w, h = ns.DB.width, ns.DB.height
    f:ClearAllPoints()
    if p then
        f:SetPoint(p[1], UIParent, p[1], p[2], p[3])
        w, h = p[4] or w, p[5] or h
    elseif ns.DB.tabbed then
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    else
        local offset = ((ns.windowCount - 1) % 8) * 24
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
        if ns.DB.buttons[btn.id] then
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
    local p = ns.DB.profiles[f.key]
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
            local same = p and p.character == ga.characterName
            local lvl = (same and p.level) and (" " .. p.level) or ""
            sub = sub .. "  -  " .. Colorize(ga.characterName, r, g, b) .. lvl .. (locClass and (" " .. locClass) or "")
            if same and p.guild and p.guild ~= "" then sub = sub .. "  |cff40ff40<" .. p.guild .. ">|r" end
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
    -- game styles: gold line like the game's windows (the name already shows the class)
    local line = IsGameStyle() and C.accent or acc
    f.accentLine:SetVertexColor(line[1], line[2], line[3], 0.9)
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
    if had and ns.UpdateSessionUI then ns.UpdateSessionUI() end
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
        f:SetHeight(f.restoreHeight or ns.DB.height)
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
    local s = ns.session[key]
    local lines = s and s.lines
    local sessionStart = lines and lines[1] and lines[1].t or math.huge
    local log = ns.DB.logEnabled and ns.DB.log[key]
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
    if ns.RefreshTabs then ns.RefreshTabs() end
    if ns.UpdateSessionUI then ns.UpdateSessionUI() end
end

local function CreateWindow(key)
    ns.windowCount = ns.windowCount + 1
    local f = CreateFrame("Frame", "DMmeConv" .. ns.windowCount, UIParent, BACKDROP_TEMPLATE)
    f.key = key
    f.unread = 0
    f.actionButtons = {}
    f.accent = C.accent
    Skin(f, "window")
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetScale(ns.DB.scale or 1)
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
    OnTheme(function(classic) shadow:SetShown(not classic) end) -- game windows have no drop shadow

    -- Unread glow (pulsing accent border)
    local glow = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
    OnTheme(function(classic)
        -- game styles: a soft tooltip-style glow around the border, not a hard line
        local out = classic and 4 or 2
        glow:ClearAllPoints()
        glow:SetPoint("TOPLEFT", -out, out)
        glow:SetPoint("BOTTOMRIGHT", out, -out)
        if classic then
            glow:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 16 })
        else
            glow:SetBackdrop({ edgeFile = WHITE, edgeSize = 2 })
        end
        local a = f.accent or C.accent
        glow:SetBackdropBorderColor(a[1], a[2], a[3], 1)
    end)
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
    SkinHeader(header, HEADER_H - 1)

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
        if ns.DB.tabbed then ns.RefreshTabs() end
    end)
    nameBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        local r, g, b = KeyRGB(f.key)
        GameTooltip:SetText(ShortName(f.key), r or 1, g or 1, b or 1)
        local p = ns.DB.profiles[f.key]
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
        if not ns.DB.tabbed then
            f:Hide()
        elseif ns.DB.closeAllTabs then
            ns.CloseAllWindows() -- X closes the whole tabbed window (Settings > General)
        else
            ns.CloseTab(f.key)
        end
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
    gear:SetScript("OnClick", function() ns.ShowSettings() end)

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
        { "history", "History", "Whisper History", "Browse saved whispers with this player.", function() ns.ShowHistory(f.key) end },
        { "replies", "Replies", "Quick replies", "Send a saved reply with one click,\nor save what you have typed for next time.", function(self) ToggleReplies(f, self) end },
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
    Skin(inset, "inset")

    local msg = CreateFrame("ScrollingMessageFrame", nil, inset)
    msg:SetPoint("TOPLEFT", 7, -6)
    msg:SetPoint("BOTTOMRIGHT", -7, 6)
    msg:SetFontObject(msgFont)
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
    Skin(inputBox, "input")
    f.inputBox = inputBox

    local edit = CreateFrame("EditBox", nil, inputBox)
    edit:SetPoint("TOPLEFT", 8, 0)
    edit:SetPoint("BOTTOMRIGHT", -8, 0)
    edit:SetFontObject(msgFont)
    edit:SetAutoFocus(false)
    edit:SetMaxLetters(255)
    edit:SetTextInsets(0, 0, 0, 0)
    f.edit = edit

    -- emoji picker button, inside the right end of the box
    local emojiBtn = CreateFrame("Button", nil, inputBox)
    emojiBtn:SetSize(18, 18)
    emojiBtn:SetPoint("RIGHT", -4, 0)
    local et = emojiBtn:CreateTexture(nil, "ARTWORK")
    et:SetAllPoints()
    et:SetTexture(Emoji.PATH .. "smile")
    et:SetDesaturated(true)
    et:SetAlpha(0.7)
    emojiBtn:SetScript("OnEnter", function(self)
        et:SetDesaturated(false); et:SetAlpha(1)
        ShowTooltip(self, "Emoji", "Pick an emoji to add to your message.\nShift-click to pick several.")
    end)
    emojiBtn:SetScript("OnLeave", function() et:SetDesaturated(true); et:SetAlpha(0.7); GameTooltip:Hide() end)
    emojiBtn:SetScript("OnClick", function(self) Emoji.TogglePicker(f, self) end)
    f.emojiBtn = emojiBtn
    Emoji.LayoutButton(f)

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
    local s = ns.session[key]
    if s and s.unread then
        f.unread = s.unread
        s.unread = nil
    end

    windows[key] = f
    UpdateTitle(f)
    local pos = ns.DB.positions[key]
    if not ns.DB.tabbed and pos and pos[6] then SetMinimized(f, true) end
    f:Hide() -- callers decide when to show it
    f:HookScript("OnHide", function()
        if ns.UpdateSessionUI then ns.UpdateSessionUI() end
        if ns.replyMenu and ns.replyMenu.owner == f then ns.replyMenu:Hide() end
        if Emoji.picker and Emoji.picker.owner == f then Emoji.picker:Hide() end
    end)
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
local tabOrder = {}; -- shared between files: ns.activeKey
local tabButtons = {}; local tabStrip

local function ActiveFrame() return ns.activeKey and windows[ns.activeKey] end

local function IndexOf(list, value)
    for i, v in ipairs(list) do if v == value then return i end end
end

ns.ActivateTab = function(key)
    local f = windows[key] or CreateWindow(key)
    if not IndexOf(tabOrder, key) then tinsert(tabOrder, key) end
    local cur = ActiveFrame()
    if cur and cur ~= f then cur:Hide() end
    ns.activeKey = key
    ApplyPosition(f)
    f:Show()
    f:Raise()
    StopFlash(f)
    ns.RefreshTabs()
    return f
end

-- Add a tab without switching to it (unless nothing is showing).
local function AddTab(key)
    local f = windows[key] or CreateWindow(key)
    if not IndexOf(tabOrder, key) then tinsert(tabOrder, key) end
    local cur = ActiveFrame()
    if not cur or not cur:IsShown() then return ns.ActivateTab(key) end
    ns.RefreshTabs()
    return f
end

ns.CloseTab = function(key)
    local idx = IndexOf(tabOrder, key)
    if idx then tremove(tabOrder, idx) end
    local f = windows[key]
    if f then f:Hide() end
    if key == ns.activeKey then
        ns.activeKey = nil
        local nextKey = idx and (tabOrder[idx] or tabOrder[idx - 1])
        if nextKey then ns.ActivateTab(nextKey); return end
    end
    ns.RefreshTabs()
end

local function CloseAllWindows()
    for _, f in pairs(windows) do f:Hide() end
    wipe(tabOrder)
    ns.activeKey = nil
    if ns.RefreshTabs then ns.RefreshTabs() end
end

local function StyleTab(b, hover)
    local f = windows[b.key]
    local active = b.key == ns.activeKey
    local r, g, bl = KeyRGB(b.key)
    local unread = f and f.unread or 0
    local name = ShortName(b.key)
    if active then
        b:SetBackdropColor(unpack(C.tabOn))
        b:SetBackdropBorderColor(unpack(C.border))
        b.line:SetVertexColor(r or C.accent[1], g or C.accent[2], bl or C.accent[3], 1)
        b.line:Show()
        b.label:SetText(Colorize(name, r or 1, g or 1, bl or 1))
    else
        b:SetBackdropColor(unpack(hover and C.tabHover or C.tabOff))
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
    b.line = b:CreateTexture(nil, "ARTWORK")
    b.line:SetTexture(WHITE)
    b.line:SetHeight(2)
    OnTheme(function(classic)
        b:SetBackdrop(classic and TOOLTIP_BD or FLAT)
        local pad = classic and 3 or 1
        b.line:ClearAllPoints()
        b.line:SetPoint("TOPLEFT", pad, -pad)
        b.line:SetPoint("TOPRIGHT", -pad, -pad)
        if b.key then StyleTab(b) end
    end)
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", 8, 0)
    b.label:SetPoint("RIGHT", -8, 0)
    b.label:SetWordWrap(false)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            ns.ActivateTab(self.key)
        else
            ns.CloseTab(self.key)
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

ns.RefreshTabs = function()
    if not tabStrip then
        tabStrip = CreateFrame("Frame", nil, UIParent)
        tabStrip:SetHeight(22)
    end
    local host = ActiveFrame()
    if not ns.DB.tabbed or not host or #tabOrder == 0 then
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
    if ns.UpdateSessionUI then ns.UpdateSessionUI() end
end

local function SetTabbed(on)
    CloseAllWindows()
    ns.DB.tabbed = on and true or false
    for _, f in pairs(windows) do ApplyPosition(f) end
    Print("Tabbed window: " .. (ns.DB.tabbed and "ON" or "OFF"))
end

ns.OpenWindow = function(name)
    local key = FullName(name)
    if not key then return end
    local f
    if ns.DB.tabbed then f = ns.ActivateTab(key) else f = GetWindow(key, true) end
    if f.minimized then SetMinimized(f, false) end
    f:Raise()
    f.edit:SetFocus()
end

-- shared with the files after this one (see their 'from earlier files')
ns.ShowTooltip = ShowTooltip
ns.FlatButton = FlatButton
ns.DEFAULT_REPLIES = DEFAULT_REPLIES
ns.Trim = Trim
ns.ApplyPosition = ApplyPosition
ns.LayoutButtons = LayoutButtons
ns.UpdateTitle = UpdateTitle
ns.StartFlash = StartFlash
ns.StopFlash = StopFlash
ns.FillMessages = FillMessages
ns.RecolorAll = RecolorAll
ns.GetWindow = GetWindow
ns.tabOrder = tabOrder
ns.IndexOf = IndexOf
ns.AddTab = AddTab
ns.CloseAllWindows = CloseAllWindows
ns.SetTabbed = SetTabbed
