-- Modules\Roster.lua: Roster tab. Guild members with level, class, zone / last online,
-- and PvP columns (filled by a PvP stats provider once one exists, "—" until then).
--
-- Event-driven: rebuilds on GUILD_ROSTER_UPDATE only while the tab is visible;
-- otherwise just marks itself dirty and rebuilds on next show.
--
-- Optional providers other modules can set later (no edits needed here):
--   ns.PvPStats:Get(fullName) -> kills, deaths   (nil = member has no data)
--   ns.Comm:CountAddonUsers() -> number
local _, ns = ...

local ROW_HEIGHT = 18
local DASH       = "—"

local COLUMNS = {
    { key = "name",   label = "Name",   width = 150 },
    { key = "level",  label = "Level",  width = 40,  justify = "CENTER" },
    { key = "class",  label = "Class",  width = 95 },
    { key = "zone",   label = "Zone",   width = 190 },
    { key = "kills",  label = "Kills",  width = 55,  justify = "CENTER" },
    { key = "deaths", label = "Deaths", width = 55,  justify = "CENTER" },
    { key = "kd",     label = "K/D",    width = 50,  justify = "CENTER" },
}
do
    local x = 0
    for _, col in ipairs(COLUMNS) do col.x = x; x = x + col.width end
end

local panel, scrollBox, dataProvider, searchBox, offlineCheck, footer, emptyText
local headers = {}
local members = {}   -- full unfiltered list from the last roster read
local dirty = true

local function Prefs()
    ns.charDB.roster = ns.charDB.roster or { showOffline = false, sortKey = "zone", sortAsc = true }
    return ns.charDB.roster
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
local function ClassColor(classFile)
    if C_ClassColor and C_ClassColor.GetClassColor and classFile then
        local c = C_ClassColor.GetClassColor(classFile)
        if c then return c end
    end
    local c = RAID_CLASS_COLORS and classFile and RAID_CLASS_COLORS[classFile]
    if c then return c end
    return HIGHLIGHT_FONT_COLOR
end

local function OfflineText(mins)
    if mins < 60 then return "Offline <1h" end
    local h = math.floor(mins / 60)
    if h < 24 then return "Offline " .. h .. "h" end
    local d = math.floor(h / 24)
    if d < 30 then return "Offline " .. d .. "d" end
    local mo = math.floor(d / 30)
    if mo < 12 then return "Offline " .. mo .. "mo" end
    return "Offline " .. math.floor(mo / 12) .. "y"
end

local function ReadRoster()
    wipe(members)
    if not IsInGuild() then return end
    local pvp = ns.PvPStats
    local n = GetNumGuildMembers() or 0
    for i = 1, n do
        local full, rank, _, level, classDisplay, zone, note, _, online, _, classFile, _, _, isMobile =
            GetGuildRosterInfo(i)
        if full then
            local m = {
                full = full,
                name = Ambiguate(full, "guild"),
                rank = rank,
                note = note,
                level = level or 0,
                class = classDisplay or "",
                classFile = classFile,
                online = online and true or false,
            }
            if m.online then
                m.zoneText = isMobile and "Remote Chat" or zone or ""
                m.offlineMins = -1
            else
                local y, mo, d, h = GetGuildRosterLastOnline(i)
                m.offlineMins = ((y or 0) * 365 * 24 + (mo or 0) * 30 * 24 + (d or 0) * 24 + (h or 0)) * 60
                m.zoneText = isMobile and "Remote Chat" or OfflineText(m.offlineMins)
            end
            if pvp and pvp.Get then
                m.kills, m.deaths = pvp:Get(full)
                if m.kills and m.deaths then
                    m.kd = (m.deaths > 0) and (m.kills / m.deaths) or m.kills
                end
            end
            members[#members + 1] = m
        end
    end
end

-- Members with no value for a column always sort to the bottom.
local SORTERS = {
    name   = function(m) return m.name:lower() end,
    level  = function(m) return m.level end,
    class  = function(m) return m.class end,
    zone   = function(m) return m.offlineMins end, -- online first, then most recently online
    kills  = function(m) return m.kills end,
    deaths = function(m) return m.deaths end,
    kd     = function(m) return m.kd end,
}

local function Sorted(list)
    local prefs = Prefs()
    local get, asc = SORTERS[prefs.sortKey] or SORTERS.name, prefs.sortAsc
    table.sort(list, function(a, b)
        local va, vb = get(a), get(b)
        if va == nil or vb == nil then
            if va ~= vb then return va ~= nil end
        elseif va ~= vb then
            if asc then return va < vb else return va > vb end
        end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function RowOnEnter(row)
    local m = row.data
    if not m then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local c = ClassColor(m.classFile)
    GameTooltip:AddLine(m.full, c.r, c.g, c.b)
    if m.rank then GameTooltip:AddLine(m.rank, 1, 1, 1) end
    if m.note and m.note ~= "" then GameTooltip:AddLine(m.note, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
end

local function InitRow(row, m)
    if not row.cells then
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0.04)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.cells = {}
        for i, col in ipairs(COLUMNS) do
            local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            fs:SetPoint("LEFT", row, "LEFT", col.x + 4, 0)
            fs:SetWidth(col.width - 8)
            fs:SetJustifyH(col.justify or "LEFT")
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row:SetScript("OnEnter", RowOnEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end
    row.data = m
    row.bg:SetShown(m.index % 2 == 0)

    local c = ClassColor(m.classFile)
    local cells = row.cells
    cells[1]:SetText(m.name)
    cells[1]:SetTextColor(c.r, c.g, c.b)
    cells[2]:SetText(m.level)
    cells[3]:SetText(m.class)
    cells[4]:SetText(m.zoneText)
    cells[5]:SetText(m.kills or DASH)
    cells[6]:SetText(m.deaths or DASH)
    cells[7]:SetText(m.kd and ("%.2f"):format(m.kd) or DASH)

    local grey = not m.online
    for i = 2, #cells do
        if grey then cells[i]:SetTextColor(0.5, 0.5, 0.5) else cells[i]:SetTextColor(1, 1, 1) end
    end
    row:SetAlpha(grey and 0.75 or 1)
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function UpdateHeaders()
    local prefs = Prefs()
    for _, h in ipairs(headers) do
        if h.key == prefs.sortKey then
            h.arrow:Show()
            if prefs.sortAsc then h.arrow:SetTexCoord(0, 0.5625, 1, 0) else h.arrow:SetTexCoord(0, 0.5625, 0, 1) end
        else
            h.arrow:Hide()
        end
    end
end

local function Refresh()
    if not IsInGuild() then
        dataProvider:Flush()
        emptyText:SetText("You are not in a guild.")
        emptyText:Show()
        footer:SetText("")
        return
    end

    local prefs = Prefs()
    local filter = searchBox:GetText():lower()
    local shown, online = {}, 0
    for _, m in ipairs(members) do
        if m.online then online = online + 1 end
        if (prefs.showOffline or m.online)
            and (filter == "" or m.name:lower():find(filter, 1, true)) then
            shown[#shown + 1] = m
        end
    end
    Sorted(shown)
    for i, m in ipairs(shown) do m.index = i end

    dataProvider = CreateDataProvider(shown)
    scrollBox:SetDataProvider(dataProvider, ScrollBoxConstants.RetainScrollPosition)

    emptyText:SetText((#members == 0) and "Loading guild roster..." or "No members match.")
    emptyText:SetShown(#shown == 0)

    local users = (ns.Comm and ns.Comm.CountAddonUsers) and ns.Comm:CountAddonUsers() or 0
    footer:SetText(("%d members  ·  %d online  ·  %d with %s"):format(#members, online, users, ns.title))
    UpdateHeaders()
end

local function Rebuild()
    ReadRoster()
    Refresh()
    dirty = false
end

local function OnRosterEvent()
    if panel and panel:IsVisible() then Rebuild() else dirty = true end
end

local function RequestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster() -- server-throttled; answer arrives as GUILD_ROSTER_UPDATE
    elseif GuildRoster then
        GuildRoster()
    end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------
local function Build(p)
    panel = p
    local prefs = Prefs()

    -- Search box
    searchBox = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
    searchBox:SetSize(170, 20)
    searchBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -4)
    searchBox:SetAutoFocus(false)
    searchBox:HookScript("OnTextChanged", function() Refresh() end)

    -- Show offline
    offlineCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    offlineCheck:SetSize(24, 24)
    offlineCheck:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
    local label = offlineCheck.Text or offlineCheck.text
    if not label then
        label = offlineCheck:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        label:SetPoint("LEFT", offlineCheck, "RIGHT", 2, 0)
    end
    label:SetFontObject("GameFontHighlightSmall")
    label:SetText("Show offline")
    offlineCheck:SetChecked(prefs.showOffline)
    offlineCheck:SetScript("OnClick", function(self)
        Prefs().showOffline = self:GetChecked() and true or false
        Refresh()
    end)

    -- List area
    scrollBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -54)
    scrollBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 22)

    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    dataProvider = CreateDataProvider()
    scrollBox:SetDataProvider(dataProvider)

    -- Column headers (click to sort, click again to reverse)
    for _, col in ipairs(COLUMNS) do
        local h = CreateFrame("Button", nil, panel)
        h.key = col.key
        h:SetSize(col.width, 20)
        h:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", col.x, 4)
        h:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local fs = h:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fs:SetPoint("LEFT", h, "LEFT", 4, 0)
        fs:SetPoint("RIGHT", h, "RIGHT", -4, 0)
        fs:SetJustifyH(col.justify or "LEFT")
        fs:SetText(col.label)
        h.arrow = h:CreateTexture(nil, "OVERLAY")
        h.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        h.arrow:SetSize(9, 8)
        h.arrow:SetPoint("RIGHT", h, "RIGHT", -2, 0)
        h:SetScript("OnClick", function(self)
            local pr = Prefs()
            if pr.sortKey == self.key then
                pr.sortAsc = not pr.sortAsc
            else
                pr.sortKey, pr.sortAsc = self.key, (self.key == "name" or self.key == "class" or self.key == "zone")
            end
            if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
            Refresh()
        end)
        headers[#headers + 1] = h
    end

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 0.82, 0, 0.25)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", 0, 2)
    divider:SetPoint("BOTTOMRIGHT", scrollBox, "TOPRIGHT", 0, 2)

    emptyText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
    emptyText:SetPoint("CENTER", scrollBox, "CENTER")
    emptyText:Hide()

    footer = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    footer:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 6)

    local discordNote = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    discordNote:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 6)
    discordNote:SetJustifyH("RIGHT")
    discordNote:SetWordWrap(false)
    discordNote:SetText(ns.DISCORD_NOTE_SHORT)

    -- Sync: ask every guild member running the addon to announce themselves again.
    local syncButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    syncButton:SetSize(80, 22)
    syncButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -3)
    syncButton:SetText("Sync")
    syncButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Sync with guild")
        GameTooltip:AddLine("Asks everyone running " .. ns.title .. " to send their info again.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    syncButton:SetScript("OnLeave", GameTooltip_Hide)
    syncButton:SetScript("OnClick", function(self)
        if not ns.Comm then return end
        local ok, left = ns.Comm:RequestSync()
        if ok then
            ns:Print("Syncing with the guild...")
            RequestRoster()
            self:Disable()
            C_Timer.After(ns.Comm.SYNC_COOLDOWN, function() self:Enable() end)
        elseif left and left > 0 then
            ns:Print(("Sync is on cooldown (%ds)."):format(left))
        else
            ns:Print("You are not in a guild.")
        end
    end)

    ns:RegisterEvent("GUILD_ROSTER_UPDATE", OnRosterEvent)
    ns:RegisterEvent("PLAYER_GUILD_UPDATE", OnRosterEvent)
    ns:RegisterCallback("ADDON_USERS_CHANGED", OnRosterEvent)

    panel:SetScript("OnShow", function()
        RequestRoster()
        if dirty then Rebuild() end
    end)
    -- First show: OnShow isn't fired for the build call, so do it now.
    RequestRoster()
    Rebuild()
end

ns.MainFrame:RegisterTab("roster", "Roster", 10, Build)
