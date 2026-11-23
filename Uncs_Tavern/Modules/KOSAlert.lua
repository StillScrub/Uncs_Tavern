-- Modules\KOSAlert.lua: spotting Kill on Sight players. Local only: nothing is sent.
--
--   * Alert: when a player on the guild Kill on Sight list gets a nameplate, or I target
--     or mouse over them: a raid-warning style message, a chat line with the reason, and
--     a sound. Once per player per ALERT_COOLDOWN, at most one alert per ALERT_GAP.
--     Not in dungeons, battlegrounds or sanctuaries (Enemies:TrackingHere).
--   * Nameplate skull over every Kill on Sight player (PlateMarks.lua).
--   * Tooltip line on Kill on Sight players: reason and who added them
--     (TooltipDataProcessor, the game's API for addon tooltip lines).
--   * Guild warning (off by default): an enemy who isn't on the list, but whose guild
--     has GUILD_MIN or more players on it. Once per guild per GUILD_COOLDOWN, no sound.
-- Event-driven: nameplate added, target changed, mouseover.
local _, ns = ...
local KOS, Enemies, PlateMarks = ns.KOS, ns.Enemies, ns.PlateMarks

local ALERT_COOLDOWN = 300   -- seconds before the same player alerts again
local ALERT_GAP      = 3     -- seconds between any two alerts
local GUILD_MIN      = 2     -- KOS players in a guild before its members are flagged
local GUILD_COOLDOWN = 600

local alerted = {}       -- [name] = GetTime() of the last alert
local guildWarned = {}   -- [guild] = GetTime()
local lastAlert = -100
local guildCounts        -- [guild] = number of KOS players in it (nil = rebuild)

local function S() return ns.db.settings end

local function GuildCounts()
    if not guildCounts then
        guildCounts = {}
        for _, t in ipairs(KOS:Targets()) do
            local g = t.e and t.e.guild
            if g then guildCounts[g] = (guildCounts[g] or 0) + 1 end
        end
    end
    return guildCounts
end

-- "Ganking (added by X)" or "added by X and 2 others".
local function Summary(entries)
    local newest = entries[#entries]
    local reason = KOS:ReasonText(newest)
    local who = newest.adder .. (#entries > 1 and (" +" .. (#entries - 1)) or "")
    return (reason ~= "" and (reason .. ", ") or "") .. "added by " .. who
end

local function Announce(text, r, g, b, sound)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, { r = r, g = g, b = b })
    else
        UIErrorsFrame:AddMessage(text, r, g, b)
    end
    if sound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end

local function LevelOf(unit)
    local ok, lvl = pcall(UnitLevel, unit)
    if not ok or type(lvl) ~= "number" or (issecretvalue and issecretvalue(lvl)) then return "" end
    return lvl == -1 and " (??)" or (" (" .. lvl .. ")")
end

local function Check(unit)
    if not ns.db or not ns:GuildKey() or not Enemies:TrackingHere() then return end
    local name = Enemies:EnemyName(unit)
    if not name then return end
    local now = GetTime()
    local entries = KOS:Entries(name)
    if entries then
        if not S().kosAlert then return end
        if alerted[name] and now - alerted[name] < ALERT_COOLDOWN then return end
        if now - lastAlert < ALERT_GAP then return end -- try again on the next sighting
        alerted[name], lastAlert = now, now
        Announce(KOS.SKULL .. " Kill on Sight: " .. name .. LevelOf(unit) .. " is nearby!", 1, 0.25, 0.25,
            S().kosAlertSound)
        ns:Print(("|cffff4040Kill on Sight:|r %s is nearby (%s)."):format(name, Summary(entries)))
        return
    end
    if not S().kosGuildWarn then return end
    local ok, guild = pcall(GetGuildInfo, unit)
    if not ok or type(guild) ~= "string" or guild == "" or (issecretvalue and issecretvalue(guild)) then return end
    local n = GuildCounts()[guild]
    if not n or n < GUILD_MIN then return end
    if guildWarned[guild] and now - guildWarned[guild] < GUILD_COOLDOWN then return end
    if now - lastAlert < ALERT_GAP then return end
    guildWarned[guild], lastAlert = now, now
    Announce(("%s of <%s> is nearby (%d of that guild on Kill on Sight)"):format(name, guild, n), 1, 0.6, 0.2, false)
    ns:Print(("%s of <%s> is nearby: %d players of that guild are on Kill on Sight."):format(name, guild, n))
end

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Check(unit) end)
ns:RegisterEvent("PLAYER_TARGET_CHANGED", function() Check("target") end)
ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() Check("mouseover") end)

---------------------------------------------------------------------------
-- Nameplate skull
---------------------------------------------------------------------------
PlateMarks:AddSource(function(name)
    return ns.db and S().kosPlateSkull and ns:GuildKey() and Enemies:TrackingHere() and KOS:IsKOS(name)
end)

-- Entering or leaving a battleground or dungeon shows or hides the skulls.
local tracking
ns:RegisterCallback("ENEMIES_CHANGED", function()
    local now = Enemies:TrackingHere()
    if now ~= tracking then
        tracking = now
        PlateMarks:Refresh()
    end
end)

ns:RegisterCallback("KOS_CHANGED", function()
    guildCounts = nil
    PlateMarks:Refresh()
end)
ns:RegisterCallback("GUILD_CHANGED", function()
    guildCounts = nil
    wipe(alerted)
    PlateMarks:Refresh()
end)

---------------------------------------------------------------------------
-- Tooltip line
---------------------------------------------------------------------------
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
        if not (ns.db and S().kosTooltip and ns:GuildKey() and Enemies:TrackingHere()) then return end
        if not (tooltip and tooltip.GetUnit and tooltip.AddLine) then return end
        local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
        if not ok or not unit or (issecretvalue and issecretvalue(unit)) then return end
        local name = Enemies:EnemyName(unit)
        local entries = name and KOS:Entries(name)
        if not entries then return end
        tooltip:AddLine(KOS.SKULL .. " Kill on Sight: " .. Summary(entries), 1, 0.3, 0.3, true)
    end)
end

---------------------------------------------------------------------------
-- Settings > PvP
---------------------------------------------------------------------------
local function Toggle(key, order, label, description, indent, disabled)
    ns.Settings:RegisterToggle({ category = "pvp", key = key, order = order, indent = indent,
        label = label, description = description, disabled = disabled,
        onChange = function() PlateMarks:Refresh() end })
end
Toggle("kosAlert", 35, "Alert when a Kill on Sight player is nearby",
    "A warning in the middle of the screen and a chat line with the reason, once per player every 5 minutes. "
        .. "Not in dungeons, battlegrounds or sanctuaries.")
Toggle("kosAlertSound", 36, "Play a sound with it", nil, 1, function() return not S().kosAlert end)
Toggle("kosPlateSkull", 37, "Skull over Kill on Sight players' nameplates",
    "Only you see it. Enemy nameplates must be on (Shift+V).")
Toggle("kosTooltip", 38, "Kill on Sight line on player tooltips")
Toggle("kosGuildWarn", 39, "Warn about players from guilds with several Kill on Sight players",
    "When an enemy who isn't on the list belongs to a guild with 2 or more players on it. No sound.")
