-- Modules\PvPStats.lua: my PvP kills and deaths, shared with the guild for the roster.
--
-- KILLS
--   Honorable kills (lifetime, includes assists): the higher of GetPVPLifetimeStats()
--   and statistic 588, read on login and on PLAYER_PVP_KILLS_CHANGED.
--   The Kills column shows world honorable kills only (statistic 381; battleground
--   kills are statistic 382, shown on hover).
--
-- DUELS: won / lost, lifetime statistics 319 / 320, re-read after DUEL_FINISHED.
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
--   killer (so they got no honor). The recap has no levels, so we remember the levels of
--   enemy players seen in the last LEVEL_MEMORY seconds (target, focus, mouseover,
--   nameplates; a skull counts as 10+ levels above me) and match the killer's GUID; if
--   the killer wasn't seen in that time, it isn't counted.
--   Per-killer counts feed "Most killed by".
--
-- SHARING (UNCST, throttled through Comm's queue):
--   2|P|<hk>|<deaths>|<deathsLifetime 1/0>|<dishonorableKills>|<killingBlows>|<topKiller>|<topCount>|<dishonorableDeaths>
--      |<worldHK>|<battlegroundHK>|<duelsWon>|<duelsLost>   (added in 0.4.2)
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
local STAT_WORLD_HK, STAT_BG_HK = 381, 382          -- honorable kills split by place (lifetime)
local STAT_DUELS_WON, STAT_DUELS_LOST = 319, 320
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

-- Honorable kills outside battlegrounds: statistic 381, or total minus statistic 382
-- if the game has no 381.
function PvP:WorldKills()
    local world = StatNumber(STAT_WORLD_HK)
    if world then return world end
    return math.max(0, self:HonorableKills() - (StatNumber(STAT_BG_HK) or 0))
end

function PvP:BattlegroundKills()
    return StatNumber(STAT_BG_HK) or 0
end

-- Returns duels won, duels lost (lifetime statistics).
function PvP:Duels()
    return StatNumber(STAT_DUELS_WON) or 0, StatNumber(STAT_DUELS_LOST) or 0
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
    local dw, dl = PvP:Duels()
    return { hk = PvP:HonorableKills(), deaths = deaths, lifetime = lifetime,
             dk = p.dishonorableKills or 0, kb = p.killingBlows or 0, dd = p.dishonorableDeaths or 0,
             top = top, topN = topN, whk = PvP:WorldKills(), bghk = PvP:BattlegroundKills(),
             dw = dw, dl = dl, t = time() }
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
    ns.Comm:Send("P", r.hk, r.deaths, r.lifetime and 1 or 0, r.dk, r.kb, r.top or "", r.topN or 0, r.dd,
        r.whk, r.bghk, r.dw, r.dl)
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
    ns.Comm:RegisterHandler("P", function(sender, hk, deaths, lifetime, dk, kb, top, topN, dd, whk, bghk, dw, dl)
        local store = GuildStore()
        if not store then return end
        local rec = PvP:CleanRecord({ hk = hk, deaths = deaths, lifetime = lifetime == "1", dk = dk, kb = kb,
                                      dd = dd, top = top, topN = topN, whk = whk, bghk = bghk,
                                      dw = dw, dl = dl, t = time() })
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
    -- Midnight hides some event values as "secret" (BugSack: comparing them is an error).
    -- We can't read those, so that kill isn't counted here; the honor/stat signals still are.
    if issecretvalue and (issecretvalue(attackerGUID) or issecretvalue(targetGUID)) then return end
    -- Belt and braces in case issecretvalue is missing: any error comparing means "skip".
    local ok, mine = pcall(function()
        return (attackerGUID == UnitGUID("player") or attackerGUID == UnitGUID("pet"))
            and targetGUID:match("^Player%-") ~= nil
    end)
    if not ok or not mine then return end

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

-- Levels of enemy players seen recently: [guid] = { level (-1 = skull), when (GetTime) }.
-- Filled whenever an enemy player is targeted, focused, moused over or gets a nameplate,
-- so a killer seen shortly before the death still counts after they've left the screen.
-- Entries older than LEVEL_MEMORY seconds are dropped; the table is capped at LEVEL_CAP.
local LEVEL_MEMORY, LEVEL_CAP = 300, 200
local seenLevels, seenCount = {}, 0

local function PruneLevels(now)
    for guid, e in pairs(seenLevels) do
        if now - e.t > LEVEL_MEMORY then
            seenLevels[guid] = nil
            seenCount = seenCount - 1
        end
    end
end

local function NoteLevel(unit)
    if not (unit and UnitExists(unit) and UnitIsPlayer(unit) and UnitCanAttack("player", unit)) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local now = GetTime()
    local e = seenLevels[guid]
    if not e then
        if seenCount >= LEVEL_CAP then PruneLevels(now) end
        if seenCount >= LEVEL_CAP then return end
        e = {}
        seenLevels[guid] = e
        seenCount = seenCount + 1
    end
    e.level, e.t = UnitLevel(unit), now
end

local function SnapshotLevels()
    NoteLevel("target"); NoteLevel("focus"); NoteLevel("mouseover")
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            if plate.namePlateUnitToken then NoteLevel(plate.namePlateUnitToken) end
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
    local e = killerGUID and seenLevels[killerGUID]
    if not e or GetTime() - e.t > LEVEL_MEMORY then return nil end
    local lvl = e.level
    if type(lvl) ~= "number" then return nil end
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
    -- Added in 0.4.2: left nil when the sender runs an older version (shown as unknown).
    for _, k in ipairs({ "whk", "bghk", "dw", "dl" }) do
        local v = r[k]
        if v ~= nil and v ~= "" then
            v = ns:Int(v, 0, MAX_STAT)
            if not v then return nil end
            out[k] = v
        end
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

-- Returns kills (world honorable kills; all honorable kills for members on a version
-- older than 0.4.2), deaths, dishonorableKills, duelsWon, duelsLost (nil = unknown).
function PvP:Get(fullName)
    local name = Short(fullName)
    if IsMe(name) then
        local deaths = self:Deaths()
        local dw, dl = self:Duels()
        return self:WorldKills(), deaths, Mine().dishonorableKills or 0, dw, dl
    end
    local store = GuildStore()
    local s = store and store[name]
    if s then return s.whk or s.hk, s.deaths, s.dk or s.nhk, s.dw, s.dl end
end

-- Extra tooltip lines for a roster row.
function PvP:AddTooltip(tooltip, fullName)
    local name = Short(fullName)
    local hk, deaths, lifetime, dk, kb, top, topN, dd, whk, bghk, dw, dl
    if IsMe(name) then
        local p = Mine()
        hk = self:HonorableKills()
        whk, bghk = self:WorldKills(), self:BattlegroundKills()
        dw, dl = self:Duels()
        deaths, lifetime = self:Deaths()
        dk, kb, dd = p.dishonorableKills or 0, p.killingBlows or 0, p.dishonorableDeaths or 0
        top, topN = self:TopKiller()
    else
        local store = GuildStore()
        local s = store and store[name]
        if not s then return end
        hk, deaths, lifetime, kb, top, topN = s.hk, s.deaths, s.lifetime, s.kb, s.top, s.topN
        dk, dd = s.dk or s.nhk, s.dd
        whk, bghk, dw, dl = s.whk, s.bghk, s.dw, s.dl
    end
    tooltip:AddLine(" ")
    tooltip:AddLine(IsMe(name) and "PvP" or "PvP |cff808080(self-reported)|r", 1, 0.82, 0)
    local function Line(label, value, note)
        tooltip:AddDoubleLine(label, tostring(value or 0) .. (note and ("  |cff808080" .. note .. "|r") or ""),
            0.8, 0.8, 0.8, 1, 1, 1)
    end
    if whk then
        Line("World honorable kills", whk, "lifetime")
        Line("Battleground honorable kills", bghk, "lifetime")
    else
        Line("Honorable kills", hk, "lifetime, all (older version)")
    end
    Line("Dishonorable kills", dk, "since install")
    Line("Killing blows on players", kb, "since install")
    Line("Deaths to players", deaths, lifetime and "lifetime" or "since install")
    if dd then Line("Dishonorable deaths", dd, "since install") end
    if dw then Line("Duels won / lost", ("%d / %d"):format(dw, dl or 0), "lifetime") end
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
ns:RegisterEvent("PLAYER_TARGET_CHANGED", function() NoteLevel("target") end)
ns:RegisterEvent("PLAYER_FOCUS_CHANGED", function() NoteLevel("focus") end)
ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() NoteLevel("mouseover") end)
ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) NoteLevel(unit) end)
ns:RegisterEvent("DUEL_FINISHED", function()
    duelEndedAt = GetTime()
    C_Timer.After(3, Changed) -- the duel statistics update a moment after the duel
end)


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
    local dw, dl = PvP:Duels()
    out(("World HK: statistic %d=%s, battleground HK: statistic %d=%s -> Kills column %d; duels %d/%d"):format(
        STAT_WORLD_HK, tostring(StatNumber(STAT_WORLD_HK)), STAT_BG_HK, tostring(StatNumber(STAT_BG_HK)),
        PvP:WorldKills(), dw, dl))
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

---------------------------------------------------------------------------
-- /tavern pvpstatprobe: lists every game statistic whose name or category looks
-- PvP-related (id, category, name, value), to find out whether WoW: Forever keeps
-- separate battleground / arena / world kill counts. Reads only; sends nothing.
---------------------------------------------------------------------------
local PROBE_WORDS = { "kill", "honor", "battleground", "arena", "world", "pvp", "player", "death" }

local function Matches(text)
    text = (text or ""):lower()
    for _, w in ipairs(PROBE_WORDS) do
        if text:find(w, 1, true) then return true end
    end
    return false
end

ns:RegisterCommand("pvpstatprobe", function()
    local out = function(s) DEFAULT_CHAT_FRAME:AddMessage("  " .. s) end
    if type(GetStatisticsCategoryList) ~= "function" then
        ns:Print("pvpstatprobe: GetStatisticsCategoryList is missing.")
        return
    end
    local okL, cats = pcall(GetStatisticsCategoryList)
    if not okL or type(cats) ~= "table" then
        ns:Print("pvpstatprobe: could not read the statistics categories.")
        return
    end
    ns:Print(("PvP statistic probe (%d categories):"):format(#cats))
    local shown = 0
    for _, cat in ipairs(cats) do
        local okC, catName, parent = pcall(GetCategoryInfo, cat)
        local parentName = (okC and parent and parent > 0) and select(2, pcall(GetCategoryInfo, parent)) or ""
        local catMatch = okC and (Matches(catName) or Matches(parentName))
        local okN, n = pcall(GetCategoryNumAchievements, cat, true)
        for i = 1, (okN and tonumber(n) or 0) do
            local okA, id, name = pcall(GetAchievementInfo, cat, i)
            if okA and id and (catMatch or Matches(name)) then
                out(("%d [%s] %s = %s"):format(id, tostring(okC and catName or cat), tostring(name),
                    tostring(StatNumber(id) or "?")))
                shown = shown + 1
            end
        end
    end
    local inInstance, kind = IsInInstance()
    out(("%d statistics listed. Here now: %s"):format(shown, inInstance and tostring(kind) or "open world"))
end, "developer: list PvP-related game statistics (reads only)")
