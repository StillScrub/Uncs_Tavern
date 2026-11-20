-- Modules\PvPTab.lua: the PvP tab (Nearby, Enemies, Ignored; KOS and Leaderboard come later).
--
-- Shows the local enemy book from Enemies.lua. Only you see it; nothing is sent.
-- Right-click a row: ignore / stop ignoring / forget. Hover: details.
-- While the Nearby view is open, it refreshes every NEARBY_REFRESH seconds (a ticker
-- that runs only while that view is visible: enemies age out of "Nearby" without any
-- event, so there's nothing to wait for).
local _, ns = ...
local Enemies = ns.Enemies
local History = ns.History

local NEARBY_REFRESH = 5

local panel, introText
local lists, viewButtons, placeholders = {}, {}, {}
local current = "nearby"
local ticker

local views = {
    { key = "nearby",  label = "Nearby" },
    { key = "enemies", label = "Enemies" },
    { key = "ignored", label = "Ignored" },
    { key = "kos",     label = "Kill on Sight", soon = true },
    { key = "board",   label = "Leaderboard", soon = true },
}

local GREY = History.GREY
local RED  = { r = 1, g = 0.35, b = 0.35 }
local GREEN = { r = 0.4, g = 1, b = 0.4 }

---------------------------------------------------------------------------
-- Cell texts
---------------------------------------------------------------------------
local function ClassColor(e)
    local c = e and e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
    return c or HIGHLIGHT_FONT_COLOR
end

local function LevelText(e)
    if not e or not e.level then return "", GREY end
    if e.level == -1 then return "??", RED end
    return tostring(e.level)
end

local function Ago(seconds)
    seconds = math.max(0, math.floor(seconds or 0))
    if seconds < 60 then return seconds .. "s ago" end
    return math.floor(seconds / 60) .. "m ago"
end

local function WhenText(t)
    if not t or t == 0 then return "" end
    local d = time() - t
    if d < 3600 then return Ago(d) end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return date("%b %d", t)
end

local function Record(e)
    local w, l = e and e.wins or 0, e and e.losses or 0
    if w == 0 and l == 0 then return "-", GREY end
    return ("%d / %d"):format(w, l), (w > l and GREEN) or (l > w and RED) or HIGHLIGHT_FONT_COLOR
end

local function ClassName(e)
    local token = e and e.class
    if not token then return nil end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]) or token:lower():gsub("^%l", string.upper)
end

---------------------------------------------------------------------------
-- Row actions
---------------------------------------------------------------------------
local function ShowTooltip(item, row)
    local e = item.e or {}
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local c = ClassColor(e)
    GameTooltip:AddLine(item.name, c.r, c.g, c.b)
    local parts = {}
    local lvl = LevelText(e)
    if lvl ~= "" then parts[#parts + 1] = "Level " .. lvl end
    if e.race then parts[#parts + 1] = e.race end
    if ClassName(e) then parts[#parts + 1] = ClassName(e) end
    if #parts > 0 then GameTooltip:AddLine(table.concat(parts, " "), 1, 1, 1) end
    if e.guild then GameTooltip:AddLine("<" .. e.guild .. ">", 0.6, 1, 0.6) end
    GameTooltip:AddLine(" ")
    local function Line(label, value)
        GameTooltip:AddDoubleLine(label, value, 0.8, 0.8, 0.8, 1, 1, 1)
    end
    Line("Your kills / deaths", ("%d / %d"):format(e.wins or 0, e.losses or 0))
    if e.met and e.met > 0 then Line("Encounters", tostring(e.met)) end
    if e.last and e.last > 0 then
        Line("Last seen", WhenText(e.last) .. (e.zone and (", " .. e.zone) or ""))
    end
    if e.first then Line("First seen", date("%b %d %Y", e.first)) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click for options. Only you see this list.", 0.5, 0.5, 0.5, true)
    GameTooltip:Show()
end

local function RowMenu(item, button, row)
    if button ~= "RightButton" then return end
    local name = item.name
    local ignored = Enemies:IsIgnored(name)
    local function Forget()
        ns.Dialog:Show({
            text = ("Forget %s, including your kills and deaths against them?"):format(name),
            accept = "Forget",
            onAccept = function() Enemies:Forget(name) end,
        })
    end
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(row, function(_, root)
            root:CreateTitle(name)
            if ignored then
                root:CreateButton("Stop ignoring", function() Enemies:SetIgnored(name, false) end)
            else
                root:CreateButton("Ignore (hide, don't track)", function() Enemies:SetIgnored(name, true) end)
            end
            root:CreateButton("Forget this player", Forget)
        end)
    else
        -- No menu API: ignoring is the main action, so offer just that.
        ns.Dialog:Show({
            text = ignored and ("Stop ignoring %s?"):format(name) or ("Ignore %s? They'll be hidden and not tracked."):format(name),
            accept = ignored and "Stop ignoring" or "Ignore",
            onAccept = function() Enemies:SetIgnored(name, not ignored) end,
        })
    end
end

-- Shared with the Nearby window (NearbyWindow.lua).
ns.PvPTab = { ShowTooltip = ShowTooltip, RowMenu = RowMenu, ClassColor = ClassColor,
              LevelText = LevelText, Ago = Ago, Record = Record }

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------
local function NearbyEmpty()
    if not Enemies:Enabled() then return "Enemy tracking is off (Settings > PvP)." end
    if not Enemies:TrackingHere() then return "Not tracking here (dungeons, battlegrounds and sanctuaries)." end
    return ("No enemy players seen in the last %d minutes. Turn on enemy nameplates (Shift+V) to spot more.")
        :format(Enemies.NEARBY_SECONDS / 60)
end

local INTROS = {
    nearby  = "Enemy players seen in the last 2 minutes. Only you see this.",
    enemies = "Every enemy player you've seen, with your kills and deaths against them. Only you see this.",
    ignored = "Ignored players are hidden and not tracked. Right-click to stop ignoring.",
    kos     = "The guild's Kill on Sight list.",
    board   = "This week's guild PvP leaderboard.",
}

local function StopTicker()
    if ticker then ticker:Cancel() ticker = nil end
end

local Refresh
local function UpdateTicker()
    local want = panel and panel:IsVisible() and current == "nearby"
    if want and not ticker then
        ticker = C_Timer.NewTicker(NEARBY_REFRESH, function()
            if panel and panel:IsVisible() and current == "nearby" then Refresh() else StopTicker() end
        end)
    elseif not want then
        StopTicker()
    end
end

function Refresh()
    if not panel then return end
    local x = -4
    for i = #views, 1, -1 do
        local v = views[i]
        local b = viewButtons[v.key]
        b:ClearAllPoints()
        b:SetPoint("TOPRIGHT", panel, "TOPRIGHT", x, -4)
        x = x - b:GetWidth() - 4
        if v.key == current then b:LockHighlight() else b:UnlockHighlight() end
    end
    introText:SetText(INTROS[current] or "")
    for key, l in pairs(lists) do l.frame:SetShown(key == current) end
    for key, f in pairs(placeholders) do f:SetShown(key == current) end

    if current == "nearby" then
        lists.nearby:SetEntries(Enemies:Nearby(), NearbyEmpty())
    elseif current == "enemies" then
        local all = Enemies:All()
        lists.enemies:SetEntries(all, Enemies:Enabled() and "No enemy players seen yet." or "Enemy tracking is off (Settings > PvP).")
    elseif current == "ignored" then
        lists.ignored:SetEntries(Enemies:Ignored(), "Nobody ignored. Right-click a player in Nearby or Enemies to ignore them.")
    end
    UpdateTicker()
end

local function Build(p)
    panel = p
    introText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    introText:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
    introText:SetPoint("RIGHT", panel, "RIGHT", -470, 0)
    introText:SetJustifyH("LEFT")
    introText:SetWordWrap(false)

    for _, v in ipairs(views) do
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetHeight(22)
        b:SetText(v.label)
        b:SetWidth(math.max(80, b:GetTextWidth() + 24))
        b:SetScript("OnClick", function() current = v.key Refresh() end)
        viewButtons[v.key] = b
    end

    local opts = { onClick = RowMenu, onEnter = ShowTooltip }
    local nameCol = function() return { label = "Name", width = 120, flex = 1,
        get = function(i) return i.name, ClassColor(i.e) end } end
    local levelCol = function() return { label = "Lvl", width = 36, get = function(i) return LevelText(i.e) end } end
    local guildCol = function() return { label = "Guild", width = 80, fit = true,
        get = function(i) return i.e.guild or "", GREY end } end
    local recordCol = function() return { label = "K / D", width = 50, fit = true,
        get = function(i) return Record(i.e) end } end

    lists.nearby = History.MakeList(panel, "Nearby", {
        nameCol(), levelCol(), guildCol(), recordCol(),
        { label = "Seen", width = 60, fit = true, get = function(i) return Ago(i.ago), GREY end },
    }, opts)
    lists.enemies = History.MakeList(panel, "Enemies", {
        nameCol(), levelCol(), guildCol(), recordCol(),
        { label = "Met", width = 36, get = function(i) return tostring(i.e.met or 0), GREY end },
        { label = "Last seen", width = 70, fit = true, get = function(i)
            return WhenText(i.e.last) .. (i.e.zone and (", " .. i.e.zone) or ""), GREY end },
    }, opts)
    lists.ignored = History.MakeList(panel, "Ignored", {
        nameCol(), levelCol(), guildCol(),
    }, opts)

    for _, l in pairs(lists) do
        l.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -34)
        l.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    end

    for _, v in ipairs(views) do
        if v.soon then
            local f = CreateFrame("Frame", nil, panel)
            f:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -34)
            f:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
            local fs = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
            fs:SetPoint("CENTER")
            fs:SetText("Coming soon.")
            f:Hide()
            placeholders[v.key] = f
        end
    end

    panel:SetScript("OnShow", Refresh)
    panel:SetScript("OnHide", StopTicker)
    ns:RegisterCallback("ENEMIES_CHANGED", function() if panel:IsVisible() then Refresh() end end)
    Refresh()
end

ns.MainFrame:RegisterTab("pvp", "PvP", 27, Build)
