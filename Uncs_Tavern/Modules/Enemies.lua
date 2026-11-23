-- Modules\Enemies.lua: enemy players I've seen, and my wins/losses against each.
--
-- LOCAL ONLY: nothing here is ever sent. Account-wide (ns.db.enemies), so my other
-- characters share the same enemy book.
--
-- SEEN: an enemy player (attackable, other faction) on a nameplate, as my target, focus
-- or mouseover. Not tracked inside instances (dungeons, battlegrounds) or sanctuaries.
-- The combat log is closed, so this is all an addon can see. Names, class, race, level
-- and guild come from the game itself, but are still cleaned (no escape codes, length caps).
--   e = { class, race, level (-1 = skull), guild, zone, first, last, met, wins, losses }
--   met = encounters: a sighting more than ENCOUNTER_GAP after the previous one.
-- WINS / LOSSES: PvPStats fires PVP_KILL (my killing blow on a player) and PVP_DEATH
-- (a player's killing blow on me, from the death recap); duels are already left out there.
--
-- NEARBY: enemies in view right now (a nameplate, or my target / focus / mouseover),
-- kept NEARBY_SECONDS after they drop out of view so they don't flicker (session memory only).
--
-- IGNORE LIST (ns.db.enemyIgnore): ignored players are hidden from the PvP tab and no
-- longer updated (later: never alerted on). Their old record is kept for un-ignoring.
--
-- Event-driven: nameplate / target / mouseover / focus events. A unit seen again within
-- RESEEN_THROTTLE seconds only refreshes its time. Changes are announced as
-- ENEMIES_CHANGED, coalesced to at most one per NOTIFY_DELAY.
local _, ns = ...

local Enemies = {}
ns.Enemies = Enemies

local MAX_ENEMIES     = 1000   -- oldest (by last seen) dropped beyond this
local NEARBY_SECONDS  = 15     -- grace after leaving view
local RESEEN_THROTTLE = 10
local ENCOUNTER_GAP   = 600    -- 10 minutes
local NOTIFY_DELAY    = 0.5
local MAX_COUNT       = 100000

Enemies.NEARBY_SECONDS = NEARBY_SECONDS

local nearby = {}          -- [name] = GetTime() last seen (this session)
local count = 0            -- entries in ns.db.enemies
local trackingHere = true  -- false in instances and sanctuaries
local myFaction
local notifyPending = false

---------------------------------------------------------------------------
-- Safe reads (Midnight-era clients can return "secret" values: treated as unknown)
---------------------------------------------------------------------------
local function Secret(v) return issecretvalue and issecretvalue(v) or false end

local function Plain(ok, ...)
    if not ok then return end
    local n = select("#", ...)
    local out = { ... }
    for i = 1, n do
        if Secret(out[i]) then out[i] = nil end
    end
    return unpack(out, 1, n)
end

local function Get(fn, ...)
    if type(fn) ~= "function" then return end
    return Plain(pcall(fn, ...))
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function Book() return ns.db.enemies end
local function IgnoreList() return ns.db.enemyIgnore end

function Enemies:Enabled()
    return ns.db and ns.db.settings.enemyTracker and true or false
end

function Enemies:TrackingHere() return trackingHere end

local function Notify()
    if notifyPending then return end
    notifyPending = true
    C_Timer.After(NOTIFY_DELAY, function()
        notifyPending = false
        ns:Fire("ENEMIES_CHANGED")
    end)
end

local function Prune()
    local book = Book()
    while count > MAX_ENEMIES do
        local oldest, oldestName
        for name, e in pairs(book) do
            if not oldest or (e.last or 0) < oldest then oldest, oldestName = e.last or 0, name end
        end
        if not oldestName then break end
        book[oldestName] = nil
        count = count - 1
    end
end

local function Entry(name)
    local book = Book()
    local e = book[name]
    if not e then
        e = { first = time(), met = 0, wins = 0, losses = 0 }
        book[name] = e
        count = count + 1
        Prune()
    end
    return e
end

---------------------------------------------------------------------------
-- Reading a unit
---------------------------------------------------------------------------
-- "First Second" (Forever's two-part names), cleaned, or nil.
local function FullName(unit)
    local n = Get(GetUnitName, unit, true)
    if type(n) ~= "string" or n == "" then
        local a, b = Get(UnitName, unit)
        if type(a) ~= "string" or a == "" then return nil end
        n = (type(b) == "string" and b ~= "") and (a .. " " .. b) or a
    end
    return ns:ValidName(ns:CleanText(n, 48))
end

-- An attackable player of the other faction (so duel partners and same-faction
-- players in free-for-all areas are left out).
local function IsEnemyPlayer(unit)
    if Get(UnitIsPlayer, unit) ~= true then return false end
    if Get(UnitCanAttack, "player", unit) ~= true then return false end
    myFaction = myFaction or Get(UnitFactionGroup, "player")
    local faction = Get(UnitFactionGroup, unit)
    if type(faction) == "string" and type(myFaction) == "string" and faction == myFaction then return false end
    return true
end

-- "First Second" of a unit when it's an enemy player, else nil (KOSAlert.lua).
function Enemies:EnemyName(unit)
    if Get(UnitExists, unit) ~= true or not IsEnemyPlayer(unit) then return nil end
    return FullName(unit)
end

local function Note(unit)
    if not trackingHere or not Enemies:Enabled() then return end
    if not IsEnemyPlayer(unit) then return end
    local name = FullName(unit)
    if not name or IgnoreList()[name] then return end

    local nowT, now = GetTime(), time()
    local wasNearby = nearby[name] and nowT - nearby[name] <= NEARBY_SECONDS
    nearby[name] = nowT

    local e = Book()[name]
    if e and e.last and now - e.last < RESEEN_THROTTLE then
        e.last = now
        if not wasNearby then Notify() end
        return
    end

    e = Entry(name)
    if now - (e.last or 0) > ENCOUNTER_GAP then e.met = math.min((e.met or 0) + 1, MAX_COUNT) end
    local _, class = Get(UnitClass, unit)
    e.class = ns:ValidClass(class) or e.class
    local race = Get(UnitRace, unit)
    if type(race) == "string" and race ~= "" then e.race = ns:CleanText(race, 24) end
    local level = ns:Int(Get(UnitLevel, unit), -1, 60)
    if level and level ~= 0 and (level > 0 or not e.level) then e.level = level end
    local guild = Get(GetGuildInfo, unit)
    if type(guild) == "string" and guild ~= "" then e.guild = ns:CleanText(guild, 48) end
    local zone = Get(GetZoneText)
    if type(zone) == "string" and zone ~= "" then e.zone = ns:CleanText(zone, 40) end
    e.last = now
    Notify()
end

-- Enemies still on a nameplate count as nearby even without a new event.
local function RefreshPlates()
    if not (trackingHere and Enemies:Enabled() and C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local plates = Get(C_NamePlate.GetNamePlates)
    if type(plates) ~= "table" then return end
    local nowT = GetTime()
    for _, plate in ipairs(plates) do
        local unit = plate.namePlateUnitToken
        if unit and IsEnemyPlayer(unit) then
            local name = FullName(unit)
            if name and nearby[name] then nearby[name] = nowT end
        end
    end
    for _, unit in ipairs({ "target", "focus", "mouseover" }) do
        if Get(UnitExists, unit) and IsEnemyPlayer(unit) then
            local name = FullName(unit)
            if name and nearby[name] then nearby[name] = nowT end
        end
    end
end

---------------------------------------------------------------------------
-- Wins and losses (from PvPStats)
---------------------------------------------------------------------------
local function Result(name, guid, field)
    -- Open world only: battleground and arena fights don't count (nor for Nemesis).
    if not trackingHere or not Enemies:Enabled() then return end
    local class, race
    if type(guid) == "string" and not Secret(guid) and guid:match("^Player%-") then
        local _, c, r, _, _, gname = Get(GetPlayerInfoByGUID, guid)
        class, race = c, r
        if type(gname) == "string" and gname ~= "" then name = gname end
    elseif type(guid) == "string" and not Secret(guid) and guid:match("^Pet%-") then
        return -- a pet's name isn't its owner's
    end
    if Secret(name) or type(name) ~= "string" then return end
    name = ns:ValidName(ns:CleanText(name, 48))
    if not name or name == "?" or IgnoreList()[name] then return end
    local e = Entry(name)
    e[field] = math.min((e[field] or 0) + 1, MAX_COUNT)
    e.class = ns:ValidClass(class) or e.class
    if type(race) == "string" and race ~= "" and not e.race then e.race = ns:CleanText(race, 24) end
    e.last = math.max(e.last or 0, time())
    Notify()
end

ns:RegisterCallback("PVP_KILL", function(_, victim, guid) Result(victim, guid, "wins") end)
ns:RegisterCallback("PVP_DEATH", function(_, killer, guid) Result(killer, guid, "losses") end)

---------------------------------------------------------------------------
-- Public API (PvPTab.lua)
---------------------------------------------------------------------------
function Enemies:Get(name) return Book()[name] end

local function ByLast(a, b)
    if (a.e.last or 0) ~= (b.e.last or 0) then return (a.e.last or 0) > (b.e.last or 0) end
    return a.name < b.name
end

-- { { name, e, ago (seconds) }, ... } seen in the last NEARBY_SECONDS, newest first.
function Enemies:Nearby()
    RefreshPlates()
    local out, nowT, book, ignore = {}, GetTime(), Book(), IgnoreList()
    for name, t in pairs(nearby) do
        local ago = nowT - t
        if ago > NEARBY_SECONDS then
            nearby[name] = nil
        elseif book[name] and not ignore[name] then
            out[#out + 1] = { name = name, e = book[name], ago = ago }
        end
    end
    table.sort(out, function(a, b) return a.ago < b.ago end)
    return out
end

-- Every enemy in the book (not ignored), last seen first.
function Enemies:All()
    local out, ignore = {}, IgnoreList()
    for name, e in pairs(Book()) do
        if not ignore[name] then out[#out + 1] = { name = name, e = e } end
    end
    table.sort(out, ByLast)
    return out
end

function Enemies:Ignored()
    local out, book = {}, Book()
    for name in pairs(IgnoreList()) do out[#out + 1] = { name = name, e = book[name] or {} } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function Enemies:IsIgnored(name) return IgnoreList()[name] == true end

function Enemies:SetIgnored(name, ignored)
    if not ns:ValidName(name) then return end
    IgnoreList()[name] = ignored and true or nil
    if ignored then nearby[name] = nil end
    Notify()
end

function Enemies:Forget(name)
    if Book()[name] then
        Book()[name] = nil
        count = count - 1
    end
    nearby[name] = nil
    Notify()
end

function Enemies:ForgetAll()
    wipe(Book())
    wipe(nearby)
    count = 0
    Notify()
end

function Enemies:Count() return count end

---------------------------------------------------------------------------
-- Saved data: drop anything malformed
---------------------------------------------------------------------------
ns:RegisterCallback("VALIDATE_DB", function()
    local book = ns.db.enemies
    count = 0
    for name, e in pairs(book) do
        if type(e) ~= "table" or not ns:ValidName(name) then
            book[name] = nil
        else
            local clean = {
                class = ns:ValidClass(e.class),
                level = ns:Int(e.level, -1, 60),
                first = ns:Int(e.first, 0) or time(),
                last  = ns:Int(e.last, 0) or 0,
                met    = ns:Int(e.met, 0, MAX_COUNT) or 0,
                wins   = ns:Int(e.wins, 0, MAX_COUNT) or 0,
                losses = ns:Int(e.losses, 0, MAX_COUNT) or 0,
            }
            for _, k in ipairs({ "race", "guild", "zone" }) do
                local s = type(e[k]) == "string" and ns:CleanText(e[k], k == "guild" and 48 or 40) or ""
                clean[k] = s ~= "" and s or nil
            end
            book[name] = clean
            count = count + 1
        end
    end
    Prune()
    for name, v in pairs(ns.db.enemyIgnore) do
        if v ~= true or not ns:ValidName(name) then ns.db.enemyIgnore[name] = nil end
    end
end)

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function UpdateZone()
    local inInstance = Get(IsInInstance)
    local pvpType = Get((C_PvP and C_PvP.GetZonePVPInfo) or GetZonePVPInfo)
    local was = trackingHere
    trackingHere = not inInstance and pvpType ~= "sanctuary"
    myFaction = Get(UnitFactionGroup, "player") or myFaction
    if was ~= trackingHere then Notify() end
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", UpdateZone)
ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", UpdateZone)
ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Note(unit) end)
-- A plate gone: once the grace time is over, tell the lists so they drop that enemy.
ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function()
    if trackingHere and Enemies:Enabled() then C_Timer.After(NEARBY_SECONDS + 1, Notify) end
end)
ns:RegisterEvent("PLAYER_TARGET_CHANGED", function() Note("target") end)
ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() Note("mouseover") end)
ns:RegisterEvent("PLAYER_FOCUS_CHANGED", function() Note("focus") end)

---------------------------------------------------------------------------
-- Settings > PvP
---------------------------------------------------------------------------
ns.Settings:RegisterCategory({ key = "pvp", name = "PvP", group = ns.title, order = 25 })
ns.Settings:RegisterToggle({
    category = "pvp", key = "enemyTracker", order = 10,
    label = "Remember enemy players",
    description = "Keep a list of enemy players you see (nameplates, target, mouseover) and your wins "
        .. "and losses against each, for the PvP tab. Only you see it: nothing is sent. "
        .. "Not tracked in dungeons, battlegrounds or sanctuaries.",
    onChange = function() Notify() end,
})
ns.Settings:RegisterButton({
    category = "pvp", order = 20, label = "Forget all enemies", buttonText = "Forget all",
    description = "Clears your enemy list, including wins and losses. Your ignore list stays.",
    onClick = function()
        ns.Dialog:Show({
            text = ("Forget all %d enemy players you've seen, with their wins and losses?"):format(count),
            accept = "Forget all",
            onAccept = function() Enemies:ForgetAll() end,
        })
    end,
})
