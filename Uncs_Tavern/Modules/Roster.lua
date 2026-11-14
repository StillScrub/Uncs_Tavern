-- Modules\Roster.lua: the guild tab (roster). Class icon + class-colored name, level,
-- zone / last online, rank, and PvP columns (filled by a PvP stats provider once one
-- exists, "—" until then). Hover a row for rank and public note.
--
-- Event-driven: GUILD_ROSTER_UPDATE fires in bursts, so rebuilds are coalesced into one
-- per THROTTLE seconds (a single C_Timer one-shot, no polling), and only while the tab
-- is visible; otherwise it just marks itself dirty and rebuilds on next show.
--
-- Optional providers other modules can set later (no edits needed here):
--   ns.PvPStats:Get(fullName) -> kills, deaths, dishonorableKills   (nil = member has no data)
--   ns.PvPStats:AddTooltip(tooltip, fullName)     extra row-tooltip lines
--   ns.History:HelpedCount(fullName) -> n          wishlist deliveries (nil = no data)
--   ns.Comm:CountAddonUsers() -> number
local _, ns = ...

local ROW_HEIGHT = 18
local ICON_SIZE  = 14
local DASH       = "—"
local THROTTLE   = 2 -- seconds between roster rebuilds

local COLUMNS = {
    { key = "name",   label = "Name",          width = 165 },
    { key = "level",  label = "Level",         width = 40,  justify = "CENTER" },
    { key = "zone",   label = "Zone / Status", width = 115, flex = 3 },
    { key = "rank",   label = "Rank",          width = 85,  flex = 2 },
    { key = "kills",  label = "Kills",         width = 52,  justify = "CENTER",
      tip = "Honorable kills, lifetime (includes assists)." },
    { key = "deaths", label = "Deaths",        width = 52,  justify = "CENTER",
      tip = "Deaths to players. Lifetime when the game tracks it; otherwise deaths tracked since installing Unc's Tavern." },
    { key = "kd",     label = "K/D",           width = 48,  justify = "CENTER",
      tip = "Kills / Deaths (deaths count as at least 1)." },
    { key = "dk",     label = "Dishonorable",  width = 78,  justify = "CENTER",
      tip = "Killing blows on players too low level to give honor, since installing Unc's Tavern. Not part of K/D." },
    { key = "helped", label = "Helped",        width = 52,  justify = "CENTER",
      tip = "Times they delivered wishlist items to a guildmate (counted when the requester takes them from the mailbox)." },
}
-- Zone and Rank grow with the window; the rest stay sized to their content.
ns.Columns.Layout(COLUMNS, 0)
local layoutVersion = 0

local panel, scrollBox, dataProvider, searchBox, offlineCheck, footer, emptyText
local headers = {}
local members = {}   -- full unfiltered list from the last roster read
local dirty = true
local pendingRebuild = false -- a throttled rebuild is scheduled

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

-- Class icon: the modern atlas if Forever has it, else the classic class-circle sheet.
local function SetClassIcon(tex, classFile)
    if not classFile then tex:Hide() return end
    local atlas = "classicon-" .. classFile:lower()
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
        tex:SetAtlas(atlas)
    elseif CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile] then
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        tex:SetTexCoord(unpack(CLASS_ICON_TCOORDS[classFile]))
    else
        tex:Hide()
        return
    end
    tex:Show()
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
        local full, rank, rankIndex, level, classDisplay, zone, note, _, online, _, classFile, _, _, isMobile =
            GetGuildRosterInfo(i)
        if full then
            local m = {
                full = full,
                name = Ambiguate(full, "guild"),
                rank = rank or "",
                rankIndex = rankIndex or 99,
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
            if ns.History then m.helped = ns.History:HelpedCount(full) end
            if pvp and pvp.Get then
                m.kills, m.deaths, m.dk = pvp:Get(full)
                if m.kills and m.deaths then
                    m.kd = m.kills / math.max(m.deaths, 1)
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
    zone   = function(m) return m.offlineMins end, -- online first, then most recently online
    rank   = function(m) return m.rankIndex end,   -- guild master first
    kills  = function(m) return m.kills end,
    deaths = function(m) return m.deaths end,
    kd     = function(m) return m.kd end,
    dk     = function(m) return m.dk end,
    helped = function(m) return m.helped end,
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
    GameTooltip:AddLine(("Level %d %s"):format(m.level, m.class), 1, 1, 1)
    if m.rank ~= "" then GameTooltip:AddLine(m.rank, 1, 1, 1) end
    if m.note and m.note ~= "" then
        GameTooltip:AddLine(m.note, 0.8, 0.8, 0.8, true)
    else
        GameTooltip:AddLine("No public note", 0.5, 0.5, 0.5)
    end
    if ns.PvPStats and ns.PvPStats.AddTooltip then ns.PvPStats:AddTooltip(GameTooltip, m.full) end
    GameTooltip:Show()
end

-- Places a row's cells for the current column widths.
local function LayoutRow(row)
    for i, col in ipairs(COLUMNS) do
        local pad = (i == 1) and (ICON_SIZE + 8) or 4 -- name cell makes room for the icon
        local fs = row.cells[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", row, "LEFT", col.x + pad, 0)
        fs:SetWidth(col.w - pad - 4)
    end
    row.layoutVersion = layoutVersion
end

local function InitRow(row, m)
    if not row.cells then
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0.04)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row.cells = {}
        row.classIcon = row:CreateTexture(nil, "ARTWORK")
        row.classIcon:SetSize(ICON_SIZE, ICON_SIZE)
        row.classIcon:SetPoint("LEFT", row, "LEFT", 4, 0)
        for i, col in ipairs(COLUMNS) do
            local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            fs:SetJustifyH(col.justify or "LEFT")
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row:SetScript("OnEnter", RowOnEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end
    if row.layoutVersion ~= layoutVersion then LayoutRow(row) end
    row.data = m
    row.bg:SetShown(m.index % 2 == 0)

    local c = ClassColor(m.classFile)
    local cells = row.cells
    SetClassIcon(row.classIcon, m.classFile)
    cells[1]:SetText(m.name)
    cells[1]:SetTextColor(c.r, c.g, c.b)
    cells[2]:SetText(m.level)
    cells[3]:SetText(m.zoneText)
    cells[4]:SetText(m.rank)
    cells[5]:SetText(m.kills or DASH)
    cells[6]:SetText(m.deaths or DASH)
    cells[7]:SetText(m.kd and ("%.2f"):format(m.kd) or DASH)
    cells[8]:SetText(m.dk or DASH)
    cells[9]:SetText(m.helped or DASH)

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
    footer:SetText(("%d of %d online  ·  %d using %s"):format(online, #members, users, ns.title))
    UpdateHeaders()
end

local function Rebuild()
    ReadRoster()
    Refresh()
    dirty = false
end

-- Roster events arrive in bursts: rebuild at most once per THROTTLE seconds.
local function OnRosterEvent()
    dirty = true
    if pendingRebuild or not (panel and panel:IsVisible()) then return end
    pendingRebuild = true
    C_Timer.After(THROTTLE, function()
        pendingRebuild = false
        if dirty and panel:IsVisible() then Rebuild() end
    end)
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
        h.col = col
        h:SetHeight(20)
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
        if col.tip then
            h:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(col.label)
                GameTooltip:AddLine(col.tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            h:SetScript("OnLeave", GameTooltip_Hide)
        end
        h:SetScript("OnClick", function(self)
            local pr = Prefs()
            if pr.sortKey == self.key then
                pr.sortAsc = not pr.sortAsc
            else
                pr.sortKey, pr.sortAsc = self.key, (self.key == "name" or self.key == "rank" or self.key == "zone")
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
    ns:RegisterCallback("PVP_STATS_CHANGED", OnRosterEvent)
    ns:RegisterCallback("HELPED_CHANGED", OnRosterEvent)

    local function LayoutHeaders()
        for _, h in ipairs(headers) do
            h:ClearAllPoints()
            h:SetWidth(h.col.w)
            h:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", h.col.x, 4)
        end
    end
    ns.Columns.Watch(scrollBox, COLUMNS, function()
        layoutVersion = layoutVersion + 1
        LayoutHeaders()
        scrollBox:ForEachFrame(LayoutRow)
    end)
    LayoutHeaders()

    panel:SetScript("OnShow", function()
        RequestRoster()
        if dirty then Rebuild() end
    end)
    -- First show: OnShow isn't fired for the build call, so do it now.
    RequestRoster()
    Rebuild()
end

-- The first tab is labelled with the guild name, read live.
ns.MainFrame:RegisterTab("roster", function() return (IsInGuild() and GetGuildInfo("player")) or "Guild" end, 10, Build)
