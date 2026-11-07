-- DMme: Settings window, slash commands and the addon compartment.
-- Part of DMme; loads after the files before it in DMme.toc and shares
-- names with them through the addon namespace (ns).
local ADDON, ns = ...

-- from earlier files (these never change after loading)
local ApplyFontSize = ns.ApplyFontSize
local ApplyPosition = ns.ApplyPosition
local BACKDROP_TEMPLATE = ns.BACKDROP_TEMPLATE
local BN_SOUND_OPTIONS = ns.BN_SOUND_OPTIONS
local C = ns.C
local CloseAllWindows = ns.CloseAllWindows
local CountExpired = ns.CountExpired
local DefaultFontSize = ns.DefaultFontSize
local Emoji = ns.Emoji
local FLAT = ns.FLAT
local FONT_MAX = ns.FONT_MAX
local FONT_MIN = ns.FONT_MIN
local FlatButton = ns.FlatButton
local FullName = ns.FullName
local GuildInviteName = ns.GuildInviteName
local HEADER_H = ns.HEADER_H
local IsGameStyle = ns.IsGameStyle
local KEEP_OPTIONS = ns.KEEP_OPTIONS
local KeepOption = ns.KeepOption
local LayoutButtons = ns.LayoutButtons
local LoadPalette = ns.LoadPalette
local MEDIA_GEAR = ns.MEDIA_GEAR
local OnTheme = ns.OnTheme
local OnUIAccent = ns.OnUIAccent
local PALETTE = ns.PALETTE
local PlayWhisperSound = ns.PlayWhisperSound
local Print = ns.Print
local PruneHistory = ns.PruneHistory
local RecolorAll = ns.RecolorAll
local RunThemeHooks = ns.RunThemeHooks
local SOUND_OPTIONS = ns.SOUND_OPTIONS
local SetLogging = ns.SetLogging
local SetMinimapDetached = ns.SetMinimapDetached
local SetMinimapShown = ns.SetMinimapShown
local SetTabbed = ns.SetTabbed
local ShowCopyLog = ns.ShowCopyLog
local ShowSessionTooltip = ns.ShowSessionTooltip
local ShowSpamEditor = ns.ShowSpamEditor
local ShowTooltip = ns.ShowTooltip
local Skin = ns.Skin
local SkinHeader = ns.SkinHeader
local SpamLogText = ns.SpamLogText
local THEME_OPTIONS = ns.THEME_OPTIONS
local ToggleSessionPanel = ns.ToggleSessionPanel
local UIAccent = ns.UIAccent
local WHITE = ns.WHITE
local spamLog = ns.spamLog
local windows = ns.windows

----------------------------------------------------------------------
-- Settings panel
----------------------------------------------------------------------
local function ApplyScale(s)
    s = math.floor(s * 100 + 0.5) / 100
    ns.DB.scale = s
    for _, f in pairs(windows) do f:SetScale(s) end
    if ns.hist then ns.hist:SetScale(s) end
    if ns.settings then ns.settings:SetScale(s) end
    if ns.DB.tabbed then ns.RefreshTabs() end
end

-- History retention / clearing ---------------------------------------
local function AfterHistoryChanged()
    if ns.hist and ns.hist:IsShown() then ns.hist:Refresh() end
    RecolorAll() -- redraw windows (they show recent saved lines)
    if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
end

local function ApplyLogKeep(id)
    ns.DB.logKeep = KeepOption(id).id
    local n = PruneHistory()
    if n > 0 then Print("Deleted " .. n .. " saved messages older than " .. KeepOption(id).label .. ".") end
    AfterHistoryChanged()
end

-- Change the keep setting; asks first if that would delete saved messages.
local function SetLogKeep(id)
    local n = CountExpired(id)
    if n > 0 then
        StaticPopup_Show("DMME_KEEP_HISTORY", n, KeepOption(id).label, id)
    else
        ApplyLogKeep(id)
    end
end

StaticPopupDialogs["DMME_KEEP_HISTORY"] = {
    text = "This will delete %s saved messages older than %s.\nContinue?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(_, data) ApplyLogKeep(data) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

StaticPopupDialogs["DMME_CLEAR_HISTORY"] = {
    text = "Delete all saved whisper history?\nThis can't be undone.",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        wipe(ns.DB.log)
        AfterHistoryChanged()
        Print("All saved whisper history deleted.")
    end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Switch theme ("modern" = Dark, "classic" = Forever, "midnight" = Midnight), live.
local function SetTheme(name)
    local valid = false
    for _, o in ipairs(THEME_OPTIONS) do if o.id == name then valid = true end end
    ns.DB.theme = valid and name or "modern"
    LoadPalette(ns.DB.theme)
    RunThemeHooks()
    RecolorAll() -- messages, titles, tabs, whisper list
    if ns.hist and ns.hist:IsShown() then ns.hist:Refresh() end
    if ns.settings then ns.settings:Refresh() end
end

local function ThemeLabel()
    for _, o in ipairs(THEME_OPTIONS) do if o.id == ns.DB.theme then return o.label end end
    return "Dark"
end

-- Message text size (nil = follow the game's chat font size).
local function SetFontSize(n)
    n = math.max(FONT_MIN, math.min(FONT_MAX, math.floor(n + 0.5)))
    ns.DB.fontSize = (n ~= DefaultFontSize()) and n or nil
    ApplyFontSize()
    RecolorAll() -- re-flow the message windows with the new size
    if ns.hist and ns.hist:IsShown() then ns.hist:Refresh() end
end

local function RelayoutAllButtons()
    for _, f in pairs(windows) do LayoutButtons(f) end
end

local SETTINGS_W = 360

local function CreateSettings()
    local s = CreateFrame("Frame", "DMmeSettings", UIParent, BACKDROP_TEMPLATE)
    s:SetWidth(SETTINGS_W)
    s:SetPoint("CENTER")
    Skin(s, "window")
    s:SetFrameStrata("DIALOG")
    s:SetToplevel(true)
    s:SetClampedToScreen(true)
    s:SetScale(ns.DB.scale or 1)
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
    OnTheme(function(classic) shadow:SetShown(not classic) end) -- game windows have no drop shadow

    local header = s:CreateTexture(nil, "BORDER")
    SkinHeader(header, HEADER_H - 1)
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

    ------------------------------------------------------------------
    -- Builders. Everything is placed on the page being built (P), top to
    -- bottom; every row is ROW high so the spacing is even.
    ------------------------------------------------------------------
    local TAB_Y = -(HEADER_H + 8)
    local PAGE_TOP = HEADER_H + 38
    local ROW = 24
    local pages, tabs = {}, {}
    local checks, dropdowns, refreshers = {}, {}, {}
    local P, y

    local function StyleTabs()
        for i, t in ipairs(tabs) do
            if i == s.page then
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

    local function ShowPage(i)
        s.page = i
        for j, p in ipairs(pages) do p:SetShown(j == i) end
        StyleTabs()
    end

    local function Page(name)
        local i = #pages + 1
        P = CreateFrame("Frame", nil, s)
        P:SetPoint("TOPLEFT", 0, -PAGE_TOP)
        P:SetPoint("TOPRIGHT", 0, -PAGE_TOP)
        P:Hide()
        pages[i] = P
        y = 0
        local t = FlatButton(s, name, { height = 22 })
        t:SetScript("OnClick", function() ShowPage(i) end)
        t:HookScript("OnLeave", StyleTabs)
        tabs[i] = t
    end

    local function EndPage()
        P.depth = -y
        P:SetHeight(-y)
    end

    local function Section(text)
        if y < 0 then y = y - 8 end
        local fs = P:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", 14, y)
        fs:SetText(text:upper())
        OnUIAccent(function(r, g, b) fs:SetTextColor(r, g, b) end)
        local l = P:CreateTexture(nil, "ARTWORK")
        l:SetTexture(WHITE)
        OnTheme(function() l:SetVertexColor(unpack(C.sep)) end)
        l:SetPoint("LEFT", fs, "RIGHT", 8, 0)
        l:SetPoint("RIGHT", P, "RIGHT", -14, 0)
        l:SetHeight(1)
        y = y - 20
    end

    local function Check(label, tip, get, set)
        local b = CreateFrame("Button", nil, P)
        b:SetPoint("TOPLEFT", 16, y)
        b:SetPoint("RIGHT", P, "RIGHT", -16, 0)
        b:SetHeight(20)
        local box = CreateFrame("Frame", nil, b, BACKDROP_TEMPLATE)
        box:SetSize(14, 14)
        box:SetPoint("LEFT", 0, 0)
        box:SetBackdrop(FLAT) -- flat square (Dark theme)
        box:SetBackdropColor(unpack(PALETTE.modern.inputBg))
        box:SetBackdropBorderColor(unpack(C.border))
        local fill = box:CreateTexture(nil, "ARTWORK")
        fill:SetTexture(WHITE)
        fill:SetPoint("TOPLEFT", 3, -3)
        fill:SetPoint("BOTTOMRIGHT", -3, 3)
        OnUIAccent(function(r, g, bl) fill:SetVertexColor(r, g, bl, 1) end)
        -- the game's own check box (game-style themes)
        local cbUp = b:CreateTexture(nil, "ARTWORK")
        cbUp:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
        cbUp:SetSize(24, 24)
        cbUp:SetPoint("CENTER", box, "CENTER", 0, 0)
        local cbCheck = b:CreateTexture(nil, "OVERLAY")
        cbCheck:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        cbCheck:SetAllPoints(cbUp)
        local cbHi = b:CreateTexture(nil, "HIGHLIGHT")
        cbHi:SetTexture("Interface\\Buttons\\UI-CheckBox-Highlight")
        cbHi:SetBlendMode("ADD")
        cbHi:SetAllPoints(cbUp)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        fs:SetPoint("LEFT", box, "RIGHT", 8, 0)
        fs:SetPoint("RIGHT", 0, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetText(label)
        b.Refresh = function()
            local on = get() and true or false
            local game = IsGameStyle()
            box:SetShown(not game)
            cbUp:SetShown(game)
            cbHi:SetShown(game)
            cbCheck:SetShown(game and on)
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
        y = y - ROW
        return b
    end

    -- Label on the left, button on the right that opens a list.
    -- options = { { id, label }, ... }; set(id) is called when one is picked.
    local function Dropdown(labelText, options, get, set, tip, width)
        width = width or 150
        local lbl = P:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 16, y - 4)
        lbl:SetText(labelText)
        local dd = FlatButton(P, "", { width = width, tooltip = labelText, tooltipText = tip })
        dd:SetPoint("TOPRIGHT", -16, y)
        dd.label:ClearAllPoints()
        dd.label:SetPoint("LEFT", 8, 0)
        dd.label:SetPoint("RIGHT", -16, 0)
        dd.label:SetJustifyH("LEFT")
        dd.label:SetWordWrap(false)
        dd:SetScript("OnMouseDown", nil) -- label is anchored left, don't nudge it
        dd:SetScript("OnMouseUp", nil)
        local arrow = dd:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        arrow:SetPoint("RIGHT", -6, 0)
        arrow:SetText("v")

        local list = CreateFrame("Frame", nil, P, BACKDROP_TEMPLATE)
        list:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -2)
        list:SetSize(width, #options * 20 + 6)
        Skin(list, "list")
        list:SetFrameStrata("FULLSCREEN_DIALOG")
        list:EnableMouse(true)
        list:Hide()
        list.rows = {}
        for i, o in ipairs(options) do
            local row = CreateFrame("Button", nil, list, BACKDROP_TEMPLATE)
            row:SetPoint("TOPLEFT", 3, -3 - (i - 1) * 20)
            row:SetPoint("TOPRIGHT", -3, -3 - (i - 1) * 20)
            row:SetHeight(20)
            row:SetBackdrop({ bgFile = WHITE })
            row:SetBackdropColor(0, 0, 0, 0)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetPoint("LEFT", 8, 0)
            row.text:SetText(o.label)
            row:SetScript("OnEnter", function(self) self:SetBackdropColor(1, 1, 1, 0.08) end)
            row:SetScript("OnLeave", function(self) self:SetBackdropColor(0, 0, 0, 0) end)
            row:SetScript("OnClick", function()
                list:Hide()
                set(o.id)
                dd.Refresh()
            end)
            row.id = o.id
            list.rows[i] = row
        end
        function dd.Refresh()
            local cur = get()
            local text = options[1] and options[1].label or ""
            for _, o in ipairs(options) do if o.id == cur then text = o.label end end
            dd.label:SetText(text)
        end
        dd:SetScript("OnClick", function()
            if list:IsShown() then list:Hide(); return end
            for _, d in ipairs(dropdowns) do d.list:Hide() end
            local r, g, b = UIAccent()
            local cur = get()
            for _, row in ipairs(list.rows) do
                if row.id == cur then row.text:SetTextColor(r, g, b) else row.text:SetTextColor(1, 1, 1) end
            end
            list:Show()
        end)
        dd.list = list
        dropdowns[#dropdowns + 1] = dd
        y = y - ROW
        return dd
    end

    -- Label on the left, [-] value [+] on the right. step(-1 / 1).
    local function Stepper(labelText, getText, step, tip)
        local lbl = P:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 16, y - 4)
        lbl:SetText(labelText)
        local plus = FlatButton(P, "+", { width = 22, tooltip = tip and labelText, tooltipText = tip })
        plus:SetPoint("TOPRIGHT", -16, y)
        local value = P:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        value:SetPoint("RIGHT", plus, "LEFT", -6, 0)
        value:SetWidth(44)
        local minus = FlatButton(P, "-", { width = 22, tooltip = tip and labelText, tooltipText = tip })
        minus:SetPoint("RIGHT", value, "LEFT", -6, 0)
        local function show() value:SetText(getText()) end
        plus:SetScript("OnClick", function() step(1); show() end)
        minus:SetScript("OnClick", function() step(-1); show() end)
        refreshers[#refreshers + 1] = show
        y = y - ROW
    end

    -- A row of buttons: { { text, width, onClick, opts }, ... }
    local function Buttons(list)
        local prev
        for _, d in ipairs(list) do
            local opts = d[4] or {}
            opts.width = d[2]
            local b = FlatButton(P, d[1], opts)
            if prev then b:SetPoint("LEFT", prev, "RIGHT", 6, 0) else b:SetPoint("TOPLEFT", 16, y - 2) end
            b:SetScript("OnClick", d[3])
            prev = b
        end
        y = y - 28
    end

    -- Small grey text; `sample` sizes it when the real text is set later.
    local function Note(text, sample)
        local fs = P:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        fs:SetPoint("TOPLEFT", 18, y - 2)
        fs:SetWidth(SETTINGS_W - 36)
        fs:SetJustifyH("LEFT")
        fs:SetText(sample or text)
        local h = fs:GetStringHeight()
        fs:SetText(text)
        y = y - (h + 8)
        return fs
    end

    ------------------------------------------------------------------
    -- General
    ------------------------------------------------------------------
    Page("General")
    Section("Windows")
    Check("Tabbed window", "Put all whisper conversations in one window with a tab per player.\nRight-click a tab to close it.",
        function() return ns.DB.tabbed end, SetTabbed)
    Check("Open automatically on new whisper", nil,
        function() return ns.DB.autoOpen end, function(v) ns.DB.autoOpen = v end)
    Check("Wait until combat ends to open", "In combat, new whisper windows don't pop open in your face.\nThey open as soon as combat ends. You still hear the sound\nand see the minimap badge.",
        function() return ns.DB.combatHold end, function(v) ns.DB.combatHold = v end)
    Check("Hide whispers from the main chat", "Whispers only show in DMme, not in your normal chat tabs.",
        function() return ns.DB.hideFromChat end, function(v) ns.DB.hideFromChat = v end)

    Section("Sound")
    Check("Play sound on new whisper", nil,
        function() return ns.DB.sound end, function(v) ns.DB.sound = v end)
    Dropdown("Whisper sound", SOUND_OPTIONS,
        function() return ns.DB.soundKit end,
        function(id) ns.DB.soundKit = id; PlayWhisperSound(true) end,
        "The sound for whispers from characters.\nPicking one plays it so you can hear it.")
    Dropdown("Battle.net sound", BN_SOUND_OPTIONS,
        function() return ns.DB.soundKitBN or "SAME" end,
        function(id) ns.DB.soundKitBN = id; PlayWhisperSound(true, true) end,
        "The sound for Battle.net whispers.\nPicking one plays it so you can hear it.")

    Section("Minimap button")
    Check("Show minimap button", "Left-click: list of this session's whispers.\nRight-click: settings. Drag to move it.",
        function() return not ns.DB.minimap.hide end, SetMinimapShown)
    Check("Detach from minimap", "Lets you drag the button anywhere on your screen.\nTurn off to snap it back to the minimap edge.",
        function() return ns.DB.minimap.detached end, SetMinimapDetached)

    Section("Floating button")
    Check("Show floating button", "A second DMme button you can put anywhere on your screen.\nAddons that collect minimap buttons leave this one alone,\nso the minimap button can stay tucked away with the rest.\nDrag to move, Ctrl + scroll to resize.",
        function() return ns.DB.floatButton.show end, function(v) ns.SetFloatShown(v) end)
    Check("Lock floating button", "Stops it being dragged or resized by accident.",
        function() return ns.DB.floatButton.locked end, function(v) ns.DB.floatButton.locked = v end)
    Stepper("Floating button size", function() return tostring(ns.DB.floatButton.size or 36) end,
        function(d) ns.SetFloatSize((ns.DB.floatButton.size or 36) + d * 2) end,
        "Size in pixels (the minimap button is 31).\nYou can also hold Ctrl and scroll over the button.")
    Buttons({
        { "Reset position", 110, function() ns.ResetFloatButton() end,
            { tooltip = "Reset position", tooltipText = "Puts the floating button back in the middle of the screen at its normal size." } },
    })
    EndPage()

    ------------------------------------------------------------------
    -- Look
    ------------------------------------------------------------------
    Page("Look")
    Section("Theme")
    Dropdown("Theme", THEME_OPTIONS, function() return ns.DB.theme end, SetTheme,
        "Dark: DMme's flat dark look.\nForever: like the game's classic windows (gold border).\nMidnight: like the current game's dark-metal windows.\nForever and Midnight also show chat lines the game's way:\n\"[Name] whispers: ...\"")
    Check("Class colors for names and messages", "Names, whisper text, unread markers, tabs and list previews use the player's class color.\nOff: the whisper color. Battle.net friends are always blue.",
        function() return ns.DB.classColors end, function(v) ns.DB.classColors = v; RecolorAll() end)
    Check("Show emoji", "Shows pictures for emoji shortcuts like :) :D <3 :fire:\nand for real emoji (e.g. from the Battle.net phone app).\nAlso adds an emoji button to the whisper box.\nOthers see what you typed (\":fire:\") unless they use DMme too.",
        function() return Emoji.On() end,
        function(v)
            ns.DB.emoji = v
            for _, w in pairs(windows) do Emoji.LayoutButton(w) end
            RecolorAll()
            if ns.replyMenu and ns.replyMenu:IsShown() then ns.replyMenu:Refresh() end
            if ns.hist and ns.hist:IsShown() then ns.hist:Refresh() end
        end)

    Section("Size")
    Stepper("Window scale", function() return string.format("%.2f", ns.DB.scale or 1) end,
        function(d) ApplyScale(math.max(0.6, math.min(1.5, (ns.DB.scale or 1) + d * 0.05))) end)
    Stepper("Message text size", function() return tostring(ns.DB.fontSize or DefaultFontSize()) end,
        function(d) SetFontSize((ns.DB.fontSize or DefaultFontSize()) + d) end,
        "Text size in whisper windows and History.\nStarts at your chat font size.")

    Section("Window buttons")
    local function ButtonCheck(id, label, tip)
        Check(label, tip, function() return ns.DB.buttons[id] end,
            function(v) ns.DB.buttons[id] = v; RelayoutAllButtons() end)
    end
    ButtonCheck("guild", "Guild Invite", "Shows the /ginvite command ready to copy and paste.\n(The game blocks addons from sending guild invites.)")
    ButtonCheck("party", "Party Invite")
    ButtonCheck("who", "Who")
    ButtonCheck("history", "History")
    ButtonCheck("replies", "Quick replies", "A Replies button with your saved messages.")
    EndPage()

    ------------------------------------------------------------------
    -- Chat
    ------------------------------------------------------------------
    Page("Chat")
    Section("Quick replies")
    Check("Shift-click to send", "On: clicking a reply only puts it in the whisper box;\nhold Shift and click to send it right away.\nOff: a click sends it, right-click puts it in the box.",
        function() return ns.DB.replyShiftSend end,
        function(v)
            ns.DB.replyShiftSend = v
            if ns.replyMenu and ns.replyMenu:IsShown() then ns.replyMenu:Refresh() end
        end)
    Note("Add, reorder and delete replies with the Replies button in a whisper window.")

    Section("Spam filter")
    Check("Block spam whispers", "Drops whispers that contain one of your spam words\n(gold sellers, boosting ads...). Never blocks friends, guild,\nyour group, Battle.net, or people you already talk to.",
        function() return ns.DB.spamFilter end, function(v) ns.DB.spamFilter = v end)
    local spamInfo = Note("", "00 words  -  000 blocked this session")
    refreshers[#refreshers + 1] = function()
        spamInfo:SetText(#(ns.DB.spamWords or {}) .. " words  -  " .. #spamLog .. " blocked this session")
    end
    Buttons({
        { "Edit words", 100, function() ShowSpamEditor() end },
        { "Show blocked", 100, function() ShowCopyLog("Blocked whispers (this session)", SpamLogText()) end,
            { tooltip = "Show blocked", tooltipText = "Whispers the filter blocked this session, and which word matched." } },
    })

    Section("Muted players")
    local muteInfo = Note("", "000 muted")
    refreshers[#refreshers + 1] = function()
        local n = ns.PruneMutes()
        muteInfo:SetText(n == 0 and "Nobody is muted. Right-click a name > Mute whispers."
            or (n .. (n == 1 and " player" or " players") .. " muted"))
    end
    Buttons({
        { "Show muted", 100, function() ns.ShowMutedList() end,
            { tooltip = "Show muted", tooltipText = "Everyone you muted, how long is left, and Unmute buttons." } },
    })

    Section("Right-click menu on names")
    Check("Guild Invite", "Adds Guild Invite to the right-click menu on player names.",
        function() return ns.DB.menu.guild end, function(v) ns.DB.menu.guild = v end)
    Check("Open Whisper Window", nil,
        function() return ns.DB.menu.open end, function(v) ns.DB.menu.open = v end)
    Check("Mute Whispers", "Mute someone for 1 hour, 24 hours, a week, a month or forever.\nTheir whispers open no window, play no sound and are hidden\nfrom the main chat. They can't tell they are muted.",
        function() return ns.DB.menu.mute end, function(v) ns.DB.menu.mute = v end)
    EndPage()

    ------------------------------------------------------------------
    -- History
    ------------------------------------------------------------------
    Page("History")
    Section("Saved history")
    Check("Save whisper history", "Saves whispers to disk so you can read them later in the History window. Off by default.",
        function() return ns.DB.logEnabled end, SetLogging)
    Dropdown("Keep history for", KEEP_OPTIONS,
        function() return ns.DB.logKeep end,
        function(id) if id ~= ns.DB.logKeep then SetLogKeep(id) end end,
        "Older saved messages are deleted automatically (checked at login and when you change this).")
    Buttons({
        { "Open History", 110, function() ns.ShowHistory() end },
        { "Clear history", 110, function() StaticPopup_Show("DMME_CLEAR_HISTORY") end,
            { hoverColor = { 0.9, 0.25, 0.25 }, tooltip = "Clear history",
              tooltipText = "Delete all saved whisper history.\n(This session's conversations are kept.)" } },
    })
    EndPage()

    ------------------------------------------------------------------
    -- Tabs across the top, window as tall as the tallest page
    ------------------------------------------------------------------
    local n, gap = #tabs, 4
    local tw = math.floor((SETTINGS_W - 28 - gap * (n - 1)) / n)
    for i, t in ipairs(tabs) do
        t:SetWidth(tw)
        t:SetPoint("TOPLEFT", 14 + (i - 1) * (tw + gap), TAB_Y)
    end
    local depth = 0
    for _, p in ipairs(pages) do depth = math.max(depth, p.depth) end
    s:SetHeight(PAGE_TOP + depth + 14)

    function s:Refresh()
        for _, c in ipairs(checks) do c.Refresh() end
        for _, d in ipairs(dropdowns) do d.Refresh() end
        for _, fn in ipairs(refreshers) do fn() end
        StyleTabs()
    end
    s:SetScript("OnShow", function(self) self:Refresh() end)
    s:HookScript("OnHide", function() for _, d in ipairs(dropdowns) do d.list:Hide() end end)
    ShowPage(1)
    ns.settings = s
    return s
end

ns.ShowSettings = function()
    local s = ns.settings or CreateSettings()
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
    b:SetScript("OnClick", function() ns.ShowSettings() end)
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
        ns.ShowSettings()
    elseif cmd == "minimap" then
        SetMinimapShown(ns.DB.minimap.hide)
        Print("Minimap button: " .. (ns.DB.minimap.hide and "hidden" or "shown"))
        if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
    elseif cmd == "detach" then
        SetMinimapDetached(not ns.DB.minimap.detached)
        Print("Minimap button: " .. (ns.DB.minimap.detached and "detached - drag it anywhere" or "attached to the minimap"))
        if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
    elseif cmd == "button" then
        -- /dm button            show/hide the floating button
        -- /dm button <size>     resize it (pixels)
        -- /dm button reset      back to the middle of the screen
        local r = rest:lower()
        local size = tonumber(r)
        if size then
            if not ns.DB.floatButton.show then ns.SetFloatShown(true) end
            ns.SetFloatSize(size)
            Print("Floating button size: " .. ns.DB.floatButton.size)
        elseif r == "reset" then
            ns.SetFloatShown(true)
            ns.ResetFloatButton()
            Print("Floating button moved back to the middle of the screen.")
        else
            ns.SetFloatShown(not ns.DB.floatButton.show)
            Print("Floating button: " .. (ns.DB.floatButton.show and "shown - drag to move, Ctrl + scroll to resize" or "hidden"))
        end
        if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
    elseif cmd == "list" or cmd == "session" or cmd == "friends" then
        local mode = (cmd == "friends") and "friends" or "recent"
        ns.DB.listMode = mode
        if ns.sessionPanel then
            ns.sessionPanel.mode = mode
            if ns.sessionPanel:IsShown() then ns.sessionPanel.offset = 0; ns.sessionPanel:Refresh(); return end
        end
        ToggleSessionPanel()
    elseif cmd == "tabs" then
        SetTabbed(not ns.DB.tabbed)
        if ns.settings and ns.settings:IsShown() then ns.settings:Refresh() end
    elseif cmd == "open" or cmd == "w" then
        if rest ~= "" then ns.OpenWindow(rest) else Print("Usage: /dm open <name>") end
    elseif cmd == "mute" then
        -- /dm mute <name> [1h|24h|week|month|forever]   (default: forever)
        -- the last word is the length if it is one; names can have spaces on Forever
        local name, len = rest:match("^(.-)%s+(%S+)$")
        if not (name and ns.MuteOption(len)) then name, len = rest, "forever" end
        name = name:gsub("^%s+", ""):gsub("%s+$", "")
        if name ~= "" then
            ns.MuteName(name, len)
        else
            Print("Usage: /dm mute <name> [1h|24h|week|month|forever]")
        end
    elseif cmd == "unmute" then
        if rest ~= "" then ns.UnmuteName(rest) else Print("Usage: /dm unmute <name>") end
    elseif cmd == "muted" then
        ns.ShowMutedList()
    elseif cmd == "ginvite" or cmd == "gi" then
        if rest ~= "" then GuildInviteName(FullName(rest)) else Print("Usage: /dm ginvite <name>") end
    elseif cmd == "hide" then
        ns.DB.hideFromChat = not ns.DB.hideFromChat
        Print("Hide whispers from main chat: " .. (ns.DB.hideFromChat and "ON" or "OFF"))
    elseif cmd == "sound" then
        ns.DB.sound = not ns.DB.sound
        Print("Whisper sound: " .. (ns.DB.sound and "ON" or "OFF"))
    elseif cmd == "auto" then
        ns.DB.autoOpen = not ns.DB.autoOpen
        Print("Auto-open windows on whisper: " .. (ns.DB.autoOpen and "ON" or "OFF"))
    elseif cmd == "scale" then
        local s = tonumber(rest)
        if s and s >= 0.5 and s <= 2 then
            ApplyScale(s)
            Print("Window scale set to " .. ns.DB.scale .. ".")
        else
            Print("Usage: /dm scale <0.5 - 2>  (now " .. (ns.DB.scale or 1) .. ")")
        end
    elseif cmd == "keep" then
        local id = rest:lower()
        local valid = false
        for _, o in ipairs(KEEP_OPTIONS) do if o.id == id then valid = true end end
        if valid then
            SetLogKeep(id)
            if KeepOption(id).id == ns.DB.logKeep then Print("Keeping history for: " .. KeepOption(id).label) end
        else
            Print("Usage: /dm keep day|week|month|year|forever  (now " .. KeepOption(ns.DB.logKeep).label .. ")")
        end
    elseif cmd == "log" then
        local r = rest:lower()
        if r == "on" then SetLogging(true)
        elseif r == "off" then SetLogging(false)
        else SetLogging(not ns.DB.logEnabled) end
    elseif cmd == "history" or cmd == "h" then
        ns.ShowHistory(rest ~= "" and rest or nil)
    elseif cmd == "clear" then
        if rest ~= "" then
            local key = FullName(rest)
            ns.DB.log[key] = nil
            Print("Deleted saved log for " .. rest .. ".")
            AfterHistoryChanged()
        else
            StaticPopup_Show("DMME_CLEAR_HISTORY") -- asks before deleting everything
        end
    elseif cmd == "reset" then
        wipe(ns.DB.positions)
        ns.DB.tabPos = nil
        for _, f in pairs(windows) do ApplyPosition(f) end
        if ns.DB.tabbed then ns.RefreshTabs() end
        Print("Window positions reset.")
    elseif cmd == "closeall" then
        CloseAllWindows()
    elseif cmd == "theme" then
        -- /dm theme dark|forever|midnight  (no name = next theme)
        local names = { dark = "modern", modern = "modern", flat = "modern",
            forever = "classic", classic = "classic", game = "classic", midnight = "midnight" }
        local want = names[rest:lower()]
        if not want then
            for i, o in ipairs(THEME_OPTIONS) do
                if o.id == ns.DB.theme then want = (THEME_OPTIONS[i + 1] or THEME_OPTIONS[1]).id end
            end
        end
        SetTheme(want)
        Print("Theme: " .. ThemeLabel())
    else
        Print("Commands:")
        Print("  /dm - open settings")
        Print("  /dm tabs - toggle tabbed window (now " .. (ns.DB.tabbed and "ON" or "OFF") .. ")")
        Print("  /dm list - this session's whispers")
        Print("  /dm friends - online friends (click one to chat)")
        Print("  /dm minimap - show/hide the minimap button")
        Print("  /dm detach - detach/attach the minimap button")
        Print("  /dm button [size|reset] - floating button: show/hide, resize, or reset")
        Print("  /dm open <name> - open a whisper window")
        Print("  /dm ginvite <name> - show the /ginvite command to copy")
        Print("  /dm mute <name> [1h|24h|week|month|forever] - silence someone's whispers")
        Print("  /dm unmute <name> | /dm muted - undo a mute, list muted players")
        Print("  /dm hide - toggle hiding whispers from main chat (now " .. (ns.DB.hideFromChat and "ON" or "OFF") .. ")")
        Print("  /dm sound - toggle whisper sound (now " .. (ns.DB.sound and "ON" or "OFF") .. ")")
        Print("  /dm auto - toggle auto-open on whisper (now " .. (ns.DB.autoOpen and "ON" or "OFF") .. ")")
        Print("  /dm scale <n> - window scale (now " .. (ns.DB.scale or 1) .. ")")
        Print("  /dm log [on|off] - save whispers to disk (now " .. (ns.DB.logEnabled and "ON" or "OFF") .. ")")
        Print("  /dm history [name] - browse saved whispers")
        Print("  /dm keep day|week|month|year|forever - how long history is kept")
        Print("  /dm clear [name] - delete saved logs")
        Print("  /dm theme [dark|forever|midnight] - switch the look (now " .. ThemeLabel() .. ")")
        Print("  /dm reset | closeall")
    end
end

----------------------------------------------------------------------
-- Retail addon compartment (the addon menu next to the minimap).
-- Wired up in DMme.toc; clients without the compartment ignore it.
----------------------------------------------------------------------
function DMme_OnAddonCompartmentClick(_, mouseButton, menuButtonFrame)
    if not ns.DB then return end
    if mouseButton == "RightButton" then
        ns.ShowSettings()
    else
        ToggleSessionPanel(menuButtonFrame)
    end
end

function DMme_OnAddonCompartmentEnter(_, menuButtonFrame)
    if ns.DB and menuButtonFrame then ShowSessionTooltip(menuButtonFrame, "ANCHOR_LEFT") end
end

function DMme_OnAddonCompartmentLeave()
    GameTooltip:Hide()
end
