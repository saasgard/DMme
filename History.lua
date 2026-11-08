-- DMme: History browser and the copy window.
-- Part of DMme; loads after the files before it in DMme.toc and shares
-- names with them through the addon namespace (ns).
local ADDON, ns = ...

-- from earlier files (these never change after loading)
local BACKDROP_TEMPLATE = ns.BACKDROP_TEMPLATE
local C = ns.C
local Colorize = ns.Colorize
local DayHeader = ns.DayHeader
local FlatButton = ns.FlatButton
local FormatEntry = ns.FormatEntry
local FullName = ns.FullName
local GuildInviteName = ns.GuildInviteName
local HEADER_H = ns.HEADER_H
local HandleLink = ns.HandleLink
local KeyRGB = ns.KeyRGB
local OnTheme = ns.OnTheme
local OnUIAccent = ns.OnUIAccent
local SetLogging = ns.SetLogging
local ShortName = ns.ShortName
local Skin = ns.Skin
local SkinHeader = ns.SkinHeader
local UIAccent = ns.UIAccent
local WHITE = ns.WHITE
local msgFont = ns.msgFont
local playerName = ns.playerName

----------------------------------------------------------------------
-- History browser
----------------------------------------------------------------------
local ROWS, ROW_H = 13, 26
-- shared between files: ns.hist -- the frame (global name DMmeHistory)

StaticPopupDialogs["DMME_DELETE_LOG"] = {
    text = "Delete the saved whisper log with %s?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(self, data)
        ns.DB.log[data] = nil
        if ns.hist then
            if ns.hist.selected == data then ns.hist.selected = nil end
            ns.hist:Refresh()
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
    local log = ns.DB.log[key]
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
        Skin(c, "window")
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
        OnTheme(function(classic) shadow:SetShown(not classic) end) -- game windows have no drop shadow

        local header = c:CreateTexture(nil, "BORDER")
        SkinHeader(header, 29)
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
        Skin(box, "inset")

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
    copyLog:SetScale(ns.DB.scale or 1)
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
    Skin(h, "window")
    h:SetFrameStrata("DIALOG")
    h:SetToplevel(true)
    h:SetClampedToScreen(true)
    h:SetScale(ns.DB.scale or 1)
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
    OnTheme(function(classic) shadow:SetShown(not classic) end) -- game windows have no drop shadow

    -- Header
    local header = h:CreateTexture(nil, "BORDER")
    SkinHeader(header, HEADER_H - 1)
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
    toggle:SetScript("OnClick", function() SetLogging(not ns.DB.logEnabled) end)
    function h:UpdateToggle()
        if ns.DB.logEnabled then
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
    Skin(left, "inset")

    local searchBox = CreateFrame("Frame", nil, left, BACKDROP_TEMPLATE)
    searchBox:SetPoint("TOPLEFT", 6, -6)
    searchBox:SetPoint("TOPRIGHT", -6, -6)
    searchBox:SetHeight(22)
    Skin(searchBox, "input")
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
        row:SetPoint("TOPLEFT", 6, -(32 + (i - 1) * ROW_H))
        row:SetPoint("TOPRIGHT", -6, -(32 + (i - 1) * ROW_H))
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
    Skin(right, "inset")

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
    chat:SetScript("OnClick", function() if h.selected then ns.OpenWindow(h.selected) end end)
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
    OnTheme(function(classic)
        local pad = classic and 4 or 1
        sep:ClearAllPoints()
        sep:SetPoint("TOPLEFT", pad, -32)
        sep:SetPoint("TOPRIGHT", -pad, -32)
        if classic then sep:SetVertexColor(unpack(C.sep)) else sep:SetVertexColor(0.16, 0.16, 0.2, 1) end
    end)
    sep:SetHeight(1)

    local view = CreateFrame("ScrollingMessageFrame", nil, right)
    view:SetPoint("TOPLEFT", 10, -40)
    view:SetPoint("BOTTOMRIGHT", -10, 8)
    view:SetFontObject(msgFont)
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
        for key, log in pairs(ns.DB.log) do
            local match = q == "" or ShortName(key):lower():find(q, 1, true)
            if not match then
                for _, e in ipairs(log.entries) do
                    if e.m:lower():find(q, 1, true) then match = true; break end
                end
            end
            if match then self.list[#self.list + 1] = key end
        end
        table.sort(self.list, function(a, b) return (ns.DB.log[a].last or 0) > (ns.DB.log[b].last or 0) end)
    end

    function h:RefreshRows()
        for i, row in ipairs(self.rows) do
            local key = self.list[self.offset + i]
            row.key = key
            if key then
                local log = ns.DB.log[key]
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
        local log = key and ns.DB.log[key]
        for _, b in ipairs(self.toolButtons) do b:SetShown(log ~= nil) end
        if not log then
            self.who:SetText("")
            if next(ns.DB.log) == nil then
                self.empty:SetText(ns.DB.logEnabled
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
            local text = FormatEntry(key, e)
            if q ~= "" and e.m:lower():find(q, 1, true) then
                text = "|cffffd100>|r " .. text   -- mark search hits
            end
            self.view:AddMessage(text)
        end
        self.view:ScrollToBottom()
    end

    function h:Refresh()
        self:BuildList()
        if self.selected and not ns.DB.log[self.selected] then self.selected = nil end
        if not self.selected and self.list[1] then self.selected = self.list[1] end
        self.offset = math.min(self.offset, math.max(0, #self.list - ROWS))
        self:RefreshRows()
        self:ShowLog()
    end

    h:SetScript("OnShow", function(self) self:UpdateToggle() end)
    ns.hist = h
    return h
end

ns.ShowHistory = function(name)
    local h = ns.hist or CreateHistory()
    if name then
        h.selected = FullName(name)
        if h.selected and ns.DB.log[h.selected] then
            -- make sure the selected contact is visible in the list
            h.offset = 0
        end
    end
    if h:IsShown() then h:UpdateToggle() else h:Show() end
    h:Raise()
end

-- shared with the files after this one (see their 'from earlier files')
ns.ShowCopyLog = ShowCopyLog
