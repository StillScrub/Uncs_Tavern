-- Modules\Milestones.lua: notices when a guildmate reaches the level cap and plays the
-- celebration (Modules\Cheers.lua) for them.
--
-- Trust: the guild roster is the proof; nothing in a message is believed.
--   * The addon remembers each guildmate's last seen level, per guild
--     (ns.db.milestones[guildKey].levels). A celebration plays when MY OWN roster shows
--     someone who was below the cap now at the cap, and they were never celebrated in
--     this guild before (.done, once per character, ever).
--   * The first roster read of each session only records levels, so dings that happened
--     while I was offline never play late.
--   * "Doorbell": on my own ding to the cap, the addon sends an empty "LV" addon message
--     (only if my sharing is on). It carries nothing; receivers just ask the server for a
--     fresh roster (and again a little later, in case the level hadn't updated yet), so
--     the roster check runs at once instead of whenever the roster next refreshes.
--     Rate-limited per sender. Comm's gate drops it from anyone not in the guild.
--   * Any roster refresh (opening the guild window, Sync, people logging on) runs the
--     same check, so a missed doorbell still celebrates.
-- One show at a time, at most MAX_QUEUE waiting. In combat: wait for combat to end (up
-- to COMBAT_WAIT seconds), then play the short quiet version; still fighting after that
-- = no show, just the chat line. Settings > General "Celebrations" turns it all off.
local _, ns = ...

local LEVEL_CAP    = 60
local SCAN_DELAY   = 2    -- roster events come in bursts: one scan per burst
local BELL_GAP     = 120  -- seconds: one doorbell per sender per this long
local BELL_RECHECK = 12   -- seconds: ask for the roster again (server throttles roster requests)
local BELL_DELAY   = 3    -- seconds after my ding before ringing (let the server update the roster)
local MAX_QUEUE    = 3
local COMBAT_WAIT  = 60

local seeded = {}      -- [guildKey] = true once this session's first roster read is recorded
local scanPending = false
local queue = {}       -- { name, classFile, quiet }
local playing = false
local waiting = false  -- waiting for combat to end
local waitToken = 0
local lastBell = {}    -- [sender] = GetTime()
local testCaps = {}    -- /tavern milestonetest: [name] = level treated as the cap, once

local function Enabled()
    return ns.db and ns.db.settings.celebrations
end

local function IsMe(name)
    local me = ns:PlayerName()
    return name == me or name == Ambiguate(me, "guild")
end

-- This guild's saved data, created on first use.
local function Data()
    local key = ns:GuildKey()
    if not key or not ns.db then return nil end
    local d = ns.db.milestones[key]
    if type(d) ~= "table" then
        d = { levels = {}, done = {} }
        ns.db.milestones[key] = d
    end
    return d, key
end

local function RequestRoster()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster() -- answer arrives as GUILD_ROSTER_UPDATE
    elseif GuildRoster then
        GuildRoster()
    end
end

---------------------------------------------------------------------------
-- Queue
---------------------------------------------------------------------------
local PlayNext

local function Finished()
    playing = false
    PlayNext()
end

local function OnRegen()
    ns:UnregisterEvent("PLAYER_REGEN_ENABLED", OnRegen)
    if not waiting then return end
    waiting = false
    for _, item in ipairs(queue) do item.quiet = true end
    PlayNext()
end

local function WaitForCombat()
    waiting = true
    waitToken = waitToken + 1
    local mine = waitToken
    ns:UnregisterEvent("PLAYER_REGEN_ENABLED", OnRegen) -- never twice
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", OnRegen)
    C_Timer.After(COMBAT_WAIT, function()
        if not waiting or waitToken ~= mine then return end
        -- Still fighting after a minute: no show, just the chat line(s).
        waiting = false
        ns:UnregisterEvent("PLAYER_REGEN_ENABLED", OnRegen)
        for _, item in ipairs(queue) do ns.Cheers:ChatLine(item.name, item.classFile) end
        wipe(queue)
    end)
end

PlayNext = function()
    if playing or waiting or #queue == 0 then return end
    if not Enabled() then wipe(queue) return end
    if InCombatLockdown() then WaitForCombat() return end
    local item = table.remove(queue, 1)
    playing = true
    ns.Cheers:Play(item.name, item.classFile, nil, { quiet = item.quiet, onDone = Finished })
end

local function Celebrate(name, classFile)
    if not Enabled() or #queue >= MAX_QUEUE then return end
    queue[#queue + 1] = { name = name, classFile = classFile }
    PlayNext()
end

---------------------------------------------------------------------------
-- Roster check
---------------------------------------------------------------------------
local function Scan()
    scanPending = false
    local d, key = Data()
    local n = GetNumGuildMembers() or 0
    if not d or n == 0 then return end
    local first = not seeded[key]
    seeded[key] = true
    local present = {}
    for i = 1, n do
        local full, _, _, level, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
        local name = full and Ambiguate(full, "guild")
        level = ns:Int(level, 1, LEVEL_CAP)
        if ns:ValidName(name) and level then
            present[name] = true
            local before = d.levels[name]
            d.levels[name] = level
            local cap = testCaps[name] or LEVEL_CAP
            if not first and before and before < cap and level == cap
                and not d.done[name] and not IsMe(name) then
                d.done[name] = true
                if testCaps[name] then
                    testCaps[name] = nil
                    d.done[name] = nil -- a test never counts as the real celebration
                end
                Celebrate(name, ns:ValidClass(classFile))
            end
        end
    end
    -- Forget levels of people who left (the guild size bounds this table).
    for name in pairs(d.levels) do
        if not present[name] then d.levels[name] = nil end
    end
end

ns:RegisterEvent("GUILD_ROSTER_UPDATE", function()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_DELAY, Scan)
end)

---------------------------------------------------------------------------
-- Doorbell
---------------------------------------------------------------------------
ns.Comm:RegisterHandler("LV", function(sender)
    if not Enabled() then return end
    local now = GetTime()
    if lastBell[sender] and now - lastBell[sender] < BELL_GAP then return end
    lastBell[sender] = now
    RequestRoster()
    C_Timer.After(BELL_RECHECK, RequestRoster)
end)

ns:RegisterEvent("PLAYER_LEVEL_UP", function(_, level)
    if tonumber(level) ~= LEVEL_CAP or not IsInGuild() then return end
    C_Timer.After(BELL_DELAY, function() ns.Comm:Send("LV") end) -- Send checks sharing
end)

ns:RegisterCallback("GUILD_CHANGED", function()
    wipe(lastBell)
end)

---------------------------------------------------------------------------
-- Saved data check
---------------------------------------------------------------------------
ns:RegisterCallback("VALIDATE_DB", function()
    local all = ns.db.milestones
    for key, d in pairs(all) do
        if type(key) ~= "string" or type(d) ~= "table" then
            all[key] = nil
        else
            if type(d.levels) ~= "table" then d.levels = {} end
            if type(d.done) ~= "table" then d.done = {} end
            for name, lv in pairs(d.levels) do
                if not ns:ValidName(name) or not ns:Int(lv, 1, LEVEL_CAP) then d.levels[name] = nil end
            end
            for name, v in pairs(d.done) do
                if not ns:ValidName(name) or v ~= true then d.done[name] = nil end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Setting (deliberately vague) and a hidden test
---------------------------------------------------------------------------
ns.Settings:RegisterToggle({
    category = "general",
    key = "celebrations",
    label = "Celebrations",
    description = "Show a little something when guildmates reach milestones.",
    order = 20,
    onChange = function(value)
        if not value then wipe(queue) end
    end,
})

-- /tavern milestonetest [name]: treats a guildmate's CURRENT level as the cap for one
-- check and pretends they were one level below it, then runs the real roster check 5
-- seconds later (time to start a fight, to try the combat wait). Works with any level,
-- so no level-60 guildmate is needed. Local only; sends nothing; never marks anyone as
-- celebrated. With no name, uses the highest-level guildmate (not me).
ns:RegisterCommand("milestonetest", function(arg)
    local d, key = Data()
    if not d then ns:Print("Not in a guild.") return end
    if not seeded[key] then Scan() end
    local want = strtrim(arg or ""):lower()
    local pick, pickLevel
    for i = 1, GetNumGuildMembers() or 0 do
        local full, _, _, level = GetGuildRosterInfo(i)
        local name = full and Ambiguate(full, "guild")
        level = ns:Int(level, 2, LEVEL_CAP)
        if name and level and not IsMe(name)
            and (want == "" or name:lower() == want or name:lower():find(want, 1, true))
            and (not pickLevel or level > pickLevel) then
            pick, pickLevel = name, level
        end
    end
    if not pick then
        ns:Print("No guildmate (level 2+) found" .. (want ~= "" and (" matching '" .. want .. "'") or "") .. ".")
        return
    end
    testCaps[pick] = pickLevel
    d.levels[pick] = pickLevel - 1
    ns:Print(("Testing with %s (level %d): roster check in 5 seconds."):format(pick, pickLevel))
    C_Timer.After(5, Scan)
end, nil, true)
