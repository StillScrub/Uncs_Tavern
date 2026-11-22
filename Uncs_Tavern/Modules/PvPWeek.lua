-- Modules\PvPWeek.lua: this week's PvP numbers and the guild's weekly leaderboard.
--
-- MY WEEK (per character): at the first reading of a new week, remember my lifetime
-- open-world honorable kills (PvPStats:WorldKills, like the roster's Kills column) and
-- my PvP deaths counted since install. This week's numbers are the difference:
--   kills  = world honorable kills now - at the start of the week
--   deaths = PvP deaths now - at the start of the week
--   streak = kills since my last PvP death; best = the longest streak this week
-- (Installing mid-week counts from then.) The week is the game's weekly reset
-- (C_DateAndTime.GetSecondsUntilWeeklyReset); its id is the time of the NEXT reset,
-- rounded to the hour, so every client agrees on it.
--
-- SHARING (protocol 2, GUILD, sharing category "pvp", like the roster PvP stats):
--   PW|week|kills|deaths|best
--   Sent ~20 s after login, at most once a minute after my own kills or deaths, and
--   shortly after a Sync or a guildmate's login.
--   SELF-REPORTED: each player sends only their own numbers, stored under the sender's
--   (server-set) name. Whole numbers in range, best <= kills, and the week must be the
--   current one; anything else is dropped. Shown as self-reported.
--
-- LEADERBOARD: PvP tab > Leaderboard, most kills first (then K/D). The leader gets a
-- crown on the guild roster; the most kills get a trophy, the best streak a flame.
--
-- RECORDS: each player's best week ever (most kills, best streak), from the numbers
-- this client has received directly (or my own). Shown as the guild's all-time weekly
-- high scores; players no longer in the guild drop out of them. Nothing extra is sent.
--
-- Stored: ns.charDB.pvpWeek = { w, k0, d0, kd, best } (my baseline),
--         ns.db.pvpWeek[guildKey][name] = { w, k, d, s } (guildmates and my characters)
--         ns.db.pvpRecords[guildKey][name] = { k, kw, s, sw } (best week: kills / streak)
local _, ns = ...
local PvP, Comm = ns.PvPStats, ns.Comm

local Week = {}
ns.PvPWeek = Week

local MAX_RECORDS = 1000

local MAX_NUM       = 100000
local SHARE_LOGIN   = 20
local SHARE_CHANGED = 60
local CROWN         = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:0|t"

Week.CROWN = CROWN
-- Game icons, cropped inside their border: most kills / best streak.
Week.TROPHY = "|TInterface\\Icons\\INV_Misc_Trophy_Argent:14:14:0:0:64:64:5:59:5:59|t"
Week.FLAME  = "|TInterface\\Icons\\Spell_Fire_Fire:14:14:0:0:64:64:5:59:5:59|t"
Week.rejected = 0 -- messages refused (for /tavern securitytest)

local function Now() return GetServerTime and GetServerTime() or time() end
local function Me() return ns:PlayerName() end

-- Seconds until the weekly reset, or nil when the game can't tell.
local function SecondsLeft()
    if not (C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset) then return nil end
    local ok, s = pcall(C_DateAndTime.GetSecondsUntilWeeklyReset)
    s = ok and tonumber(s)
    return s and s >= 0 and s or nil
end

-- The current week's id: the next reset, rounded to the hour.
function Week:Id()
    local left = SecondsLeft()
    if left then return math.floor((Now() + left + 1800) / 3600) * 3600 end
    return math.floor(Now() / 604800) * 604800 + 604800 -- fallback: plain 7-day blocks
end

local function Store()
    local key = ns:GuildKey()
    if not key then return nil end
    if type(ns.db.pvpWeek[key]) ~= "table" then ns.db.pvpWeek[key] = {} end
    return ns.db.pvpWeek[key]
end

local function Records()
    local key = ns:GuildKey()
    if not key then return nil end
    if type(ns.db.pvpRecords[key]) ~= "table" then ns.db.pvpRecords[key] = {} end
    return ns.db.pvpRecords[key]
end

-- Remember a player's best week (numbers already checked).
local function NoteRecord(name, w, k, s)
    local rec = Records()
    if not rec or (k == 0 and s == 0) then return end
    local r = rec[name]
    if not r then
        local n = 0
        for _ in pairs(rec) do n = n + 1 end
        if n >= MAX_RECORDS then return end
        r = { k = 0, kw = w, s = 0, sw = w }
        rec[name] = r
    end
    if k > r.k then r.k, r.kw = k, w end
    if s > r.s then r.s, r.sw = s, w end
end

---------------------------------------------------------------------------
-- My week
---------------------------------------------------------------------------
local function Kills() return PvP:WorldKills() or 0 end
local function Deaths() return (ns.charDB.pvp and ns.charDB.pvp.deaths) or 0 end

local ready = false -- the game's statistics are read only after login has settled

local function Base()
    local b = ns.charDB.pvpWeek
    if type(b) ~= "table" then b = {} ns.charDB.pvpWeek = b end
    local id = Week:Id()
    if b.w ~= id then
        local k, d = Kills(), Deaths()
        b.w, b.k0, b.d0, b.kd, b.best = id, k, d, k, 0
    end
    -- Counters can only go up; if one went down (data reset), start over from here.
    local k, d = Kills(), Deaths()
    if k < (b.k0 or 0) then b.k0, b.kd = k, k end
    if d < (b.d0 or 0) then b.d0 = d end
    if k < (b.kd or 0) then b.kd = k end
    return b
end

-- My numbers this week: kills, deaths, best streak, current streak.
function Week:Mine()
    if not ready then return 0, 0, 0, 0 end
    local b = Base()
    local k, d = Kills(), Deaths()
    local streak = k - (b.kd or b.k0)
    b.best = math.max(b.best or 0, streak)
    return math.min(k - b.k0, MAX_NUM), math.min(d - b.d0, MAX_NUM), math.min(b.best, MAX_NUM), streak
end

local function SaveOwn()
    local store = Store()
    if not store or not ready then return end
    local k, d, s = Week:Mine()
    store[Me()] = { w = Week:Id(), k = k, d = d, s = s }
    NoteRecord(Me(), Week:Id(), k, s)
end

---------------------------------------------------------------------------
-- Sharing
---------------------------------------------------------------------------
local sharePending = false
local function ShareNow()
    sharePending = false
    if not ready or not (IsInGuild() and Comm:IsSharing("pvp")) then return end
    SaveOwn()
    local k, d, s = Week:Mine()
    Comm:Send("PW", Week:Id(), k, d, s)
end

local function ScheduleShare(delay)
    if sharePending then return end
    sharePending = true
    C_Timer.After(delay, ShareNow)
end

local function Changed()
    SaveOwn()
    ns:Fire("PVP_WEEK_CHANGED")
    ScheduleShare(SHARE_CHANGED)
end

-- Returns true if stored. Also used by the security test.
function Week:Receive(sender, w, k, d, s)
    local store = Store()
    if not store then return false end
    sender = ns:ValidName(sender)
    w, k, d, s = ns:Int(w, 1), ns:Int(k, 0, MAX_NUM), ns:Int(d, 0, MAX_NUM), ns:Int(s, 0, MAX_NUM)
    if not (sender and w and k and d and s) or s > k then self.rejected = self.rejected + 1 return false end
    if math.abs(w - self:Id()) > 3600 then return false end -- another week: not current
    store[sender] = { w = w, k = k, d = d, s = s }
    NoteRecord(sender, w, k, s)
    ns:Fire("PVP_WEEK_CHANGED")
    return true
end

Comm:RegisterHandler("PW", function(sender, ...) Week:Receive(sender, ...) end, "pvp")

ns:RegisterCallback("HELLO", function(_, _, flag)
    if flag == "Q" then ScheduleShare(3 + math.random() * 6) end
end)
ns:RegisterCallback("SYNC_REQUESTED", function() ScheduleShare(4 + math.random() * 5) end)
ns:RegisterCallback("SHARING_CHANGED", function(_, field, value)
    if value and (field == "optIn" or field == "pvp") then ScheduleShare(6) end
end)

-- My own kills and deaths (never guildmates' updates, so answers don't echo around).
ns:RegisterEvent("PLAYER_PVP_KILLS_CHANGED", function() if ready then Changed() end end)
ns:RegisterCallback("PVP_DEATH", function()
    if not ready then return end
    Week:Mine() -- bank the streak before it ends
    local b = Base()
    b.kd = Kills()
    Changed()
end)

-- A new week starts while I'm online: one timer for the reset moment.
local resetTimer
local function ScheduleReset()
    if resetTimer then resetTimer:Cancel() end
    local left = SecondsLeft()
    if not left then return end
    resetTimer = C_Timer.NewTimer(left + 30, function()
        resetTimer = nil
        Changed()
        ScheduleReset()
    end)
end

local started = false
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if started then return end
    started = true
    C_Timer.After(SHARE_LOGIN, function()
        ready = true
        Base()
        SaveOwn()
        ns:Fire("PVP_WEEK_CHANGED")
        ScheduleShare(0)
        ScheduleReset()
    end)
end)

ns:RegisterCallback("VALIDATE_DB", function()
    for key, store in pairs(ns.db.pvpWeek) do
        if type(key) ~= "string" or type(store) ~= "table" then
            ns.db.pvpWeek[key] = nil
        else
            for name, r in pairs(store) do
                local ok = ns:ValidName(name) and type(r) == "table" and ns:Int(r.w, 1) and ns:Int(r.k, 0, MAX_NUM)
                    and ns:Int(r.d, 0, MAX_NUM) and ns:Int(r.s, 0, MAX_NUM)
                if not ok then store[name] = nil end
            end
        end
    end
    for key, rec in pairs(ns.db.pvpRecords) do
        if type(key) ~= "string" or type(rec) ~= "table" then
            ns.db.pvpRecords[key] = nil
        else
            for name, r in pairs(rec) do
                local ok = ns:ValidName(name) and type(r) == "table" and ns:Int(r.k, 0, MAX_NUM) and ns:Int(r.s, 0, MAX_NUM)
                    and ns:Int(r.kw, 1) and ns:Int(r.sw, 1)
                if not ok then rec[name] = nil end
            end
        end
    end
    local b = ns.charDB.pvpWeek
    if b ~= nil and (type(b) ~= "table" or not ns:Int(b.w, 1) or not ns:Int(b.k0, 0) or not ns:Int(b.d0, 0)) then
        ns.charDB.pvpWeek = nil
    end
end)

---------------------------------------------------------------------------
-- Leaderboard
---------------------------------------------------------------------------
local function KD(k, d) return k / math.max(d, 1) end

-- { { name, k, d, s, kd, me }, ... } best first. Only this week, only guild members.
function Week:Board()
    local store = Store()
    if not store then return {} end
    local id, me, out = self:Id(), Me(), {}
    local rosterReady = Comm:RosterReady()
    for name, r in pairs(store) do
        if name ~= me and math.abs(r.w - id) <= 3600 and (not rosterReady or Comm:IsMember(name)) then
            out[#out + 1] = { name = name, k = r.k, d = r.d, s = r.s, kd = KD(r.k, r.d) }
        end
    end
    if ready then
        local k, d, s = self:Mine()
        out[#out + 1] = { name = me, k = k, d = d, s = s, kd = KD(k, d), me = true }
    end
    table.sort(out, function(a, b)
        if a.k ~= b.k then return a.k > b.k end
        if a.kd ~= b.kd then return a.kd > b.kd end
        return a.name < b.name
    end)
    local topK, topS = 0, 0
    for _, row in ipairs(out) do topK, topS = math.max(topK, row.k), math.max(topS, row.s) end
    for i, row in ipairs(out) do
        row.place = i
        row.topKills = topK > 0 and row.k == topK      -- ties all get it
        row.topStreak = topS > 0 and row.s == topS
    end
    return out
end

-- The guild's all-time weekly high scores among current members:
-- { name, n, week } for most kills and for best streak (nil = none yet).
function Week:AllTime()
    local rec = Records()
    if not rec then return nil, nil end
    if ready then SaveOwn() end
    local rosterReady, me = Comm:RosterReady(), Me()
    local kills, streak
    for name, r in pairs(rec) do
        if name == me or not rosterReady or Comm:IsMember(name) then
            if r.k > 0 and (not kills or r.k > kills.n or (r.k == kills.n and r.kw < kills.week)) then
                kills = { name = name, n = r.k, week = r.kw }
            end
            if r.s > 0 and (not streak or r.s > streak.n or (r.s == streak.n and r.sw < streak.week)) then
                streak = { name = name, n = r.s, week = r.sw }
            end
        end
    end
    return kills, streak
end

-- "Nov 12": the first day of the week with this id (the id is the next reset).
function Week:WeekText(id)
    return date("%b %d", id - 604800)
end

-- The week's leader (most kills, at least 1), or nil.
function Week:Leader()
    local top = self:Board()[1]
    return top and top.k > 0 and top.name or nil
end

-- Roster provider: a crown in front of the leader's name.
local leaderCache
ns:RegisterCallback("PVP_WEEK_CHANGED", function() leaderCache = nil end)
ns:RegisterCallback("GUILD_CHANGED", function() leaderCache = nil end)
function Week:Badge(fullName)
    if leaderCache == nil then leaderCache = self:Leader() or false end
    return leaderCache and fullName and (fullName == leaderCache or Ambiguate(fullName, "guild") == Ambiguate(leaderCache, "guild"))
        and CROWN or nil
end

function Week:ResetText()
    local left = SecondsLeft()
    if not left then return "" end
    local days, hours = math.floor(left / 86400), math.floor((left % 86400) / 3600)
    if days > 0 then return ("Resets in %dd %dh."):format(days, hours) end
    return ("Resets in %dh %dm."):format(hours, math.floor((left % 3600) / 60))
end
