-- Modules\PvPStats.lua: my PvP kills and deaths, shared with the guild for the roster.
--
-- KILLS
--   Honorable kills (lifetime, includes assists): the higher of GetPVPLifetimeStats()
--   and statistic 588, read on login and on PLAYER_PVP_KILLS_CHANGED.
--   Killing blows on players (since install): PARTY_KILL where the killer is me or my
--   pet and the victim's GUID is a player.
--   Dishonorable kills (since install): a killing blow on a player with no honor signal
--   (PLAYER_PVP_KILLS_CHANGED / CHAT_MSG_COMBAT_HONOR_GAIN) within HONOR_WINDOW seconds,
--   i.e. the victim was too low level to give honor. Assists that give no honor leave
--   no signal, so they can't be counted. Shown on the roster, not part of K/D.
--
-- DEATHS
--   PLAYER_DEAD -> wait CONFIRM_DELAY s (ignores Feign Death) -> still dead? -> read the
--   death recap; the killing blow's source is a player (or a player's pet) = PvP death.
--   Mobs, environment and deaths right around a duel's end are ignored.
--   Shown value: statistic 1501 ("deaths from other players", lifetime) when the game
--   fills it, otherwise our own count since install.
--   Dishonorable deaths (since install): a PvP death where my level was grey to the
--   killer (so they got no honor). The recap has no levels, so at PLAYER_DEAD we note the
--   levels of nearby enemy players we can see (target, focus, mouseover, nameplates) and
--   match the killer's GUID; if the killer's level is unknown, it isn't counted.
--   Per-killer counts feed "Most killed by".
--
-- SHARING (UNCST, throttled through Comm's queue):
--   2|P|<hk>|<deaths>|<deathsLifetime 1/0>|<dishonorableKills>|<killingBlows>|<topKiller>|<topCount>|<dishonorableDeaths>
--   (fields are only ever appended; older clients ignore extra ones)
--   Sent ~15 s after login, at most once a minute after changes, and shortly after a
--   Sync or when a new addon user shows up. Only when PvP sharing is on.
--   SELF-REPORTED: each player sends only their own numbers, stored under the sender's
--   (server-set) name. Every number must be a whole number in 0..MAX_STAT, the killer
--   name is cleaned; anything else drops the message. Shown as "self-reported".
--   My own row always comes from my local numbers. My other characters on this account
--   are saved in the same account-wide store, locally only (never sent).
--
-- Event-driven only (no combat log, no polling); timers are one-shots.
local _, ns = ...

local PvP = {}
ns.PvPStats = PvP

local STAT_HK, STAT_PVP_DEATHS = 588, 1501
local HONOR_WINDOW   = 1.5     -- seconds between a killing blow and its honor signal
local CONFIRM_DELAY  = 4       -- seconds after PLAYER_DEAD to confirm a real death
local DUEL_WINDOW    = 6       -- seconds around a duel's end in which deaths are ignored
local SHARE_LOGIN    = 15
local SHARE_CHANGED  = 60
local MAX_STAT       = 10000000

local lastHonorSignal = -100   -- GetTime() of the last honor signal
local lastHonorEvent           -- text for /tavern pvpdebug
local duelEndedAt = -100
local sharePending = false
local lastRecapID = 0

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function Mine()
    local p = ns.charDB.pvp
    p.killers = p.killers or {}
    return p
end

local function GuildStore()
    local key = ns:GuildKey()
    if not key then return nil end
    ns.db.pvp[key] = ns.db.pvp[key] or {}
    return ns.db.pvp[key]
end

local function Short(name) return name and Ambiguate(name, "guild") or nil end

local function IsMe(name)
    local me = ns:PlayerName()
    return name == me or name == Short(me)
end

---------------------------------------------------------------------------
-- Reading the game's counters
---------------------------------------------------------------------------
local function StatNumber(id)
    if type(GetStatistic) ~= "function" then return nil end
    local ok, v = pcall(GetStatistic, id)
    if not ok or v == nil then return nil end
    local digits = tostring(v):gsub("%D", "")
    return tonumber(digits) or 0 -- "--" means zero
end

local function LifetimeAPI()
    if type(GetPVPLifetimeStats) ~= "function" then return nil end
    local ok, hk = pcall(GetPVPLifetimeStats)
    return ok and tonumber(hk) or nil
end

function PvP:HonorableKills()
    return math.max(LifetimeAPI() or 0, StatNumber(STAT_HK) or 0)
end

-- Returns deaths, isLifetime.
function PvP:Deaths()
    local tracked = Mine().deaths or 0
    local stat = StatNumber(STAT_PVP_DEATHS) or 0
    if stat > 0 and stat >= tracked then return stat, true end
    return tracked, false
end

function PvP:TopKiller(killers)
    local best, bestN
    for name, k in pairs(killers or Mine().killers) do
        if not bestN or k.count > bestN then best, bestN = name, k.count end
    end
    return best, bestN
end

---------------------------------------------------------------------------
-- Sharing
---------------------------------------------------------------------------
-- My current numbers, in the same shape guildmates' shared stats are stored in.
local function OwnRecord()
    local p = Mine()
    local deaths, lifetime = PvP:Deaths()
    local top, topN = PvP:TopKiller()
    return { hk = PvP:HonorableKills(), deaths = deaths, lifetime = lifetime,
             dk = p.dishonorableKills or 0, kb = p.killingBlows or 0, dd = p.dishonorableDeaths or 0,
             top = top, topN = topN, t = time() }
end

-- Also keep my numbers in the account-wide store, so my other characters on this
-- account (never online at the same time) see them too.
local function SaveOwn()
    local store = GuildStore()
    if store then store[Short(ns:PlayerName())] = OwnRecord() end
end

local function ShareNow()
    sharePending = false
    if not (IsInGuild() and ns.Comm and ns.Comm:IsSharing("pvp")) then return end
    local r = OwnRecord()
    SaveOwn()
    ns.Comm:Send("P", r.hk, r.deaths, r.lifetime and 1 or 0, r.dk, r.kb, r.top or "", r.topN or 0, r.dd)
end

local function ScheduleShare(delay)
    if sharePending then return end
    sharePending = true
    C_Timer.After(delay, ShareNow)
end

local function Changed()
    SaveOwn()
    ns:Fire("PVP_STATS_CHANGED")
    ScheduleShare(SHARE_CHANGED)
end

if ns.Comm then
    ns.Comm:RegisterHandler("P", function(sender, hk, deaths, lifetime, dk, kb, top, topN, dd)
        local store = GuildStore()
        if not store then return end
        local rec = PvP:CleanRecord({ hk = hk, deaths = deaths, lifetime = lifetime == "1", dk = dk, kb = kb,
                                      dd = dd, top = top, topN = topN, t = time() })
        if not rec then return end
        store[sender] = rec
        ns:Fire("PVP_STATS_CHANGED")
    end, "pvp")
end

-- Someone logged in or pressed Sync (their hello asks "Q"), I pressed Sync, or a new
-- addon user appeared: send ours soon (random spread, so answers don't all arrive at once).
ns:RegisterCallback("HELLO", function(_, _, flag)
    if flag == "Q" then ScheduleShare(2 + math.random() * 6) end
end)
ns:RegisterCallback("SYNC_REQUESTED", function() ScheduleShare(3 + math.random() * 5) end)
ns:RegisterCallback("SHARING_CHANGED", function(_, field, value)
    if value and (field == "optIn" or field == "pvp") then ScheduleShare(5) end
end)
ns:RegisterCallback("ADDON_USERS_CHANGED", function() ScheduleShare(3 + math.random() * 5) end)

---------------------------------------------------------------------------
-- Kills
---------------------------------------------------------------------------
local function HonorSignal(what)
    lastHonorSignal = GetTime()
    lastHonorEvent = what .. " at " .. date("%H:%M:%S")
end

-- Honor-gain text -> pattern, built from the game's own strings (any language).
local honorPatterns
local function HonorPatterns()
    if honorPatterns then return honorPatterns end
    honorPatterns = {}
    for _, key in ipairs({ "COMBATLOG_HONORGAIN", "COMBATLOG_HONORGAIN_NO_RANK" }) do
        local fmt = _G[key]
        if type(fmt) == "string" then
            local pat = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") -- escape magic chars
            -- "%s" / "%d" (and positional "%1$s", whose "$" is escaped too) -> captures
            pat = pat:gsub("%%%%%d?%%?%$?s", "(.+)"):gsub("%%%%%d?%%?%$?d", "(%%d+)")
            honorPatterns[#honorPatterns + 1] = "^" .. pat .. "$"
        end
    end
    return honorPatterns
end

local function OnHonorGain(_, msg)
    HonorSignal("CHAT_MSG_COMBAT_HONOR_GAIN")
    for _, pat in ipairs(HonorPatterns()) do
        local victim = msg:match(pat)
        if victim then
            local p = Mine()
            p.lastHonorVictim = { name = victim, t = time() }
            break
        end
    end
end

local function OnPvPKillsChanged()
    HonorSignal("PLAYER_PVP_KILLS_CHANGED")
    Changed()
end

local function OnPartyKill(_, attackerGUID, targetGUID)
    if not (attackerGUID and targetGUID) then return end
    if attackerGUID ~= UnitGUID("player") and attackerGUID ~= UnitGUID("pet") then return end
    if not targetGUID:match("^Player%-") then return end

    local victim = select(6, GetPlayerInfoByGUID(targetGUID)) or "?"
    local p = Mine()
    p.killingBlows = (p.killingBlows or 0) + 1
    local kill = { name = victim, t = time(), honor = "checking" }
    p.lastKill = kill
    local at = GetTime()
    C_Timer.After(HONOR_WINDOW, function()
        if lastHonorSignal >= at - HONOR_WINDOW then
            kill.honor = "honorable"
        else
            kill.honor = "dishonorable"
            p.dishonorableKills = (p.dishonorableKills or 0) + 1
        end
        Changed()
    end)
end

---------------------------------------------------------------------------
-- Deaths
---------------------------------------------------------------------------
local function RecapEvents()
    local DR = C_DeathRecap
    if not (DR and DR.GetRecapEvents) then return nil, "C_DeathRecap missing" end
    -- Newest recap: try without an ID first, then walk IDs upward from the last one used.
    local ok, events = pcall(DR.GetRecapEvents)
    if ok and type(events) == "table" and #events > 0 then return events, "recap (no id)" end
    if DR.HasRecapEvents then
        local id = lastRecapID
        while true do
            local okH, has = pcall(DR.HasRecapEvents, id + 1)
            if not (okH and has) then break end
            id = id + 1
        end
        if id > 0 then
            lastRecapID = id
            local okE, ev = pcall(DR.GetRecapEvents, id)
            if okE and type(ev) == "table" and #ev > 0 then return ev, "recap id " .. id end
        end
    end
    return nil, "no recap events"
end

local PLAYER_CONTROLLED = 0x100 -- COMBATLOG_OBJECT_CONTROL_PLAYER

-- Levels of enemy players visible at the moment of death: [guid] = level (-1 = skull).
local seenLevels = {}
local function SnapshotLevels()
    wipe(seenLevels)
    local function Note(unit)
        if UnitExists(unit) and UnitIsPlayer(unit) and UnitCanAttack("player", unit) then
            local guid = UnitGUID(unit)
            if guid then seenLevels[guid] = UnitLevel(unit) end
        end
    end
    Note("target"); Note("focus"); Note("mouseover")
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            if plate.namePlateUnitToken then Note(plate.namePlateUnitToken) end
        end
    end
end

-- Highest level that is grey (gives no honor) to someone of the given level
-- (the classic grey-level rule).
local function GreyLevel(level)
    if level <= 5 then return 0 end
    if level <= 39 then return level - math.floor(level / 10) - 5 end
    if level <= 59 then return level - math.floor(level / 5) - 1 end
    return level - 9
end

-- true = dishonorable (I was grey to the killer), false = honorable, nil = unknown.
local function WasDishonorable(killerGUID)
    local lvl = killerGUID and seenLevels[killerGUID]
    if not lvl then return nil end
    if lvl == -1 then return true, "??" end -- skull: 10+ levels above me
    return UnitLevel("player") <= GreyLevel(lvl), lvl
end

-- The killing blow is the newest event in the recap.
local function KillingBlow(events)
    local best
    for _, e in ipairs(events) do
        if not best or (e.timestamp or 0) >= (best.timestamp or 0) then best = e end
    end
    return best
end

local function IsPlayerSource(e)
    local guid = e.sourceGUID
    if type(guid) == "string" and (guid:match("^Player%-") or guid:match("^Pet%-")) then return true end
    local flags = e.sourceFlags
    return type(flags) == "number" and bit.band(flags, PLAYER_CONTROLLED) ~= 0
end

local function RecordDeath(deathAt)
    local p = Mine()
    if not UnitIsDeadOrGhost("player") then
        p.lastDeath = { t = time(), result = "ignored: alive again (Feign Death?)" }
        return
    end
    if math.abs(duelEndedAt - deathAt) <= DUEL_WINDOW then
        p.lastDeath = { t = time(), result = "ignored: duel" }
        return
    end
    local events, how = RecapEvents()
    local e = events and KillingBlow(events)
    if not e then
        p.lastDeath = { t = time(), result = "not counted: " .. how }
        return
    end
    local killer = e.sourceName or (e.environmentalType and ("environment: " .. tostring(e.environmentalType))) or "?"
    local spell = e.spellName or e.event or "?"
    if not IsPlayerSource(e) then
        p.lastDeath = { t = time(), killer = killer, spell = spell, result = "not PvP (mob/environment), " .. how }
        return
    end

    p.deaths = (p.deaths or 0) + 1
    local dishonor, killerLevel = WasDishonorable(e.sourceGUID)
    local kind = (dishonor == true) and "dishonorable" or (dishonor == false) and "honorable" or "killer level unknown"
    if dishonor then p.dishonorableDeaths = (p.dishonorableDeaths or 0) + 1 end
    p.lastDeath = { t = time(), killer = killer, spell = spell,
        result = ("PvP death counted (%s%s), %s"):format(kind,
            killerLevel and (", killer level " .. killerLevel) or "", how) }
    local k = p.killers[killer] or { count = 0 }
    p.killers[killer] = k
    k.count = k.count + 1
    k.last = time()
    k.times, k.warned = nil, nil -- left over from the removed farming warning
    Changed()
end

local function OnPlayerDead()
    local at = GetTime()
    SnapshotLevels()
    C_Timer.After(CONFIRM_DELAY, function() RecordDeath(at) end)
end

---------------------------------------------------------------------------
-- Provider for the roster
---------------------------------------------------------------------------
-- kills, deaths, dishonorableKills for a roster name (nil = no data).
-- A shared stats record with every number checked (0..MAX_STAT, whole), or nil.
function PvP:CleanRecord(r)
    if type(r) ~= "table" then return nil end
    local out = { lifetime = r.lifetime == true, t = ns:Int(r.t, 0) or time() }
    for _, k in ipairs({ "hk", "deaths", "dk", "kb", "dd", "topN" }) do
        local v = r[k]
        if v == nil or v == "" then
            v = 0
        else
            v = ns:Int(v, 0, MAX_STAT)
            if not v then return nil end
        end
        out[k] = v
    end
    local top = ns:CleanText(r.top, 48)
    out.top = top ~= "" and top or nil
    return out
end

ns:RegisterCallback("VALIDATE_DB", function()
    for key, store in pairs(ns.db.pvp) do
        if type(store) ~= "table" then
            ns.db.pvp[key] = nil
        else
            for name, r in pairs(store) do
                store[name] = ns:ValidName(name) and PvP:CleanRecord(r) or nil
            end
        end
    end
end)

function PvP:Get(fullName)
    local name = Short(fullName)
    if IsMe(name) then
        local deaths = self:Deaths()
        return self:HonorableKills(), deaths, Mine().dishonorableKills or 0
    end
    local store = GuildStore()
    local s = store and store[name]
    if s then return s.hk, s.deaths, s.dk or s.nhk end
end

-- Extra tooltip lines for a roster row.
function PvP:AddTooltip(tooltip, fullName)
    local name = Short(fullName)
    local hk, deaths, lifetime, dk, kb, top, topN, dd
    if IsMe(name) then
        local p = Mine()
        hk = self:HonorableKills()
        deaths, lifetime = self:Deaths()
        dk, kb, dd = p.dishonorableKills or 0, p.killingBlows or 0, p.dishonorableDeaths or 0
        top, topN = self:TopKiller()
    else
        local store = GuildStore()
        local s = store and store[name]
        if not s then return end
        hk, deaths, lifetime, kb, top, topN = s.hk, s.deaths, s.lifetime, s.kb, s.top, s.topN
        dk, dd = s.dk or s.nhk, s.dd
    end
    tooltip:AddLine(" ")
    tooltip:AddLine(IsMe(name) and "PvP" or "PvP |cff808080(self-reported)|r", 1, 0.82, 0)
    local function Line(label, value, note)
        tooltip:AddDoubleLine(label, tostring(value or 0) .. (note and ("  |cff808080" .. note .. "|r") or ""),
            0.8, 0.8, 0.8, 1, 1, 1)
    end
    Line("Honorable kills", hk, "lifetime")
    Line("Dishonorable kills", dk, "since install")
    Line("Killing blows on players", kb, "since install")
    Line("Deaths to players", deaths, lifetime and "lifetime" or "since install")
    if dd then Line("Dishonorable deaths", dd, "since install") end
    if top and topN and topN > 0 then
        tooltip:AddDoubleLine("Most killed by", ("%s (%d)"):format(top, topN), 0.8, 0.8, 0.8, 1, 0.4, 0.4)
    end
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
ns:RegisterEvent("PLAYER_LOGOUT", SaveOwn)
ns:RegisterEvent("PLAYER_LOGIN", function()
    if RequestPVPRewardsUpdate then pcall(RequestPVPRewardsUpdate) end
    C_Timer.After(5, SaveOwn) -- statistics are readable a moment after login
    C_Timer.After(SHARE_LOGIN, function() ScheduleShare(0) end)
end)
ns:RegisterEvent("PLAYER_PVP_KILLS_CHANGED", OnPvPKillsChanged)
ns:RegisterEvent("CHAT_MSG_COMBAT_HONOR_GAIN", OnHonorGain)
ns:RegisterEvent("PARTY_KILL", OnPartyKill)
ns:RegisterEvent("PLAYER_DEAD", OnPlayerDead)
ns:RegisterEvent("DUEL_FINISHED", function() duelEndedAt = GetTime() end)


---------------------------------------------------------------------------
-- /tavern pvpdebug
---------------------------------------------------------------------------
local function When(t) return t and date("%m-%d %H:%M:%S", t) or "never" end

ns:RegisterCommand("pvpdebug", function()
    local p = Mine()
    local out = function(s) DEFAULT_CHAT_FRAME:AddMessage("  " .. s) end
    ns:Print("PvP debug:")
    out(("Lifetime HK: GetPVPLifetimeStats=%s, statistic %d=%s -> shown %d"):format(
        tostring(LifetimeAPI()), STAT_HK, tostring(StatNumber(STAT_HK)), PvP:HonorableKills()))
    local okS, sHK, sHonor = pcall(GetPVPSessionStats or function() end)
    out(("Session: HK=%s honor=%s"):format(tostring(okS and sHK), tostring(okS and sHonor)))
    local deaths, lifetime = PvP:Deaths()
    out(("Deaths: statistic %d=%s, tracked since install=%d -> shown %d (%s)"):format(
        STAT_PVP_DEATHS, tostring(StatNumber(STAT_PVP_DEATHS)), p.deaths or 0, deaths,
        lifetime and "lifetime" or "since install"))
    out(("Killing blows on players=%d, dishonorable kills=%d, dishonorable deaths=%d"):format(
        p.killingBlows or 0, p.dishonorableKills or 0, p.dishonorableDeaths or 0))
    out("Last honor signal: " .. tostring(lastHonorEvent or "none this session"))
    local hv = p.lastHonorVictim
    out("Last honor-gain victim: " .. (hv and (hv.name .. " at " .. When(hv.t)) or "none"))
    local k = p.lastKill
    out("Last killing blow: " .. (k and ("%s at %s (%s)"):format(k.name, When(k.t), k.honor) or "none"))
    local d = p.lastDeath
    out("Last death: " .. (d and ("%s - killer %s, %s - %s"):format(When(d.t), tostring(d.killer or "?"),
        tostring(d.spell or "?"), d.result) or "none"))
    local top, topN = PvP:TopKiller()
    out("Most killed by: " .. (top and ("%s (%d)"):format(top, topN) or "nobody"))
    local store, names = GuildStore(), {}
    for name, s in pairs(store or {}) do
        names[#names + 1] = ("%s (%s K / %s D, %s)"):format(name, tostring(s.hk), tostring(s.deaths), When(s.t))
    end
    table.sort(names)
    out(("Guildmates' stats received: %d"):format(#names))
    for _, line in ipairs(names) do out("  " .. line) end
end, "show PvP kill/death numbers and the last signals")
