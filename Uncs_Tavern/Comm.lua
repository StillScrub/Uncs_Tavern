-- Comm.lua: guild addon messaging (prefix UNCST), presence, and the security gate
-- every incoming message goes through.
--
-- Wire format (every message is versioned):   <protocol>|<type>|<field>|<field>...
--   2|H|<addonVersion>|Q   hello, "who else runs the addon?" (sent once after login, and by Sync)
--   2|H|<addonVersion>|R   reply to a hello (sent once, coalesced, after a random delay)
-- Protocol 2 = the security pass (v0.4.0). Protocol 1 messages (older clients, which
-- relayed other players' data) are ignored.
--
-- TRUST (see "Security rules" in CLAUDE.md): the sender name is set by the server and
-- trusted; the message content never is. Before a handler sees a message:
--   * GUILD channel only, our prefix, protocol 2, a known type, at most MAX_FIELDS fields;
--   * the player has opted in to sharing with this guild, and the message's category
--     (wishlist / pvp) is switched on;
--   * the sender is on our own cached guild roster. Unknown senders: we ask the server
--     for a roster update once, hold the message briefly, re-check, then drop it;
--   * per-sender rate limit (token bucket: burst RATE_BURST, then RATE_PER_SEC).
-- Anything else is dropped silently (counted in Comm.stats for /tavern sync).
-- Handlers still validate every field themselves.
--
-- Officer data (handlers registered with category "officer") is the one exception to
-- "GUILD only": it travels ONLY over OFFICER or as WHISPER to rank-checked members, and
-- is dropped if it arrives on GUILD. Anything else arriving on OFFICER/WHISPER is
-- dropped. Whispers pass the same roster check, so non-guildies are ignored.
--
-- Outgoing: a throttled queue (1 msg/s). Each queued message remembers the guild it
-- was meant for and is dropped if the guild changes. Nothing is sent while sharing is
-- off, or for a category that is switched off.
--
-- API for other modules:
--   ns.Comm:Send(type, ...fields)                 queue a guild message (throttled)
--   ns.Comm:SendOfficer(type, targets, ...fields) officer data: OFFICER channel, plus a
--                                                 WHISPER to each roster name in targets
--   ns.Comm:OnlineMembers() -> { {name, full, rankIndex} }   from our roster cache
--   ns.Comm:RegisterHandler(type, fn, category)   fn(sender, ...fields); category = "wishlist" | "pvp" | nil (presence)
--   ns.Comm:IsSharing(category)                   opted in (and that category on) for the current guild?
--   ns.Comm:Sharing()                             this guild's sharing settings table (or nil)
--   ns.Comm:IsMember(name) / RankIndex(name)      from our own roster cache
--   ns.Comm:HasAddon(name) -> version|nil         ns.Comm:CountAddonUsers() -> n
-- Fires "ADDON_USERS_CHANGED" when someone new is seen, "HELLO" (sender, flag) for every
-- hello, "SHARING_CHANGED" when sharing settings change, "GUILD_CHANGED" when the guild does.
local _, ns = ...

local Comm = {}
ns.Comm = Comm

local PREFIX         = "UNCST"
local PROTOCOL       = "2"
local SEND_INTERVAL  = 1.0   -- seconds between our messages (the server allows about 1/s sustained)
local RETRY_DELAY    = 5     -- seconds before retrying a refused send
local MAX_TRIES      = 3
local HELLO_DELAY    = 10    -- seconds after login before announcing (let the UI settle)
local USER_EXPIRY    = 30 * 24 * 3600 -- forget users not seen for 30 days
local MAX_MSG_LEN    = 255
local MAX_FIELDS     = 16
local RATE_BURST     = 60    -- messages a sender may send in a burst...
local RATE_PER_SEC   = 1     -- ...then this many per second
local HOLD_SECONDS   = 15    -- how long a message from an unknown sender waits for the roster
local MAX_HELD       = 30
local ROSTER_ASK_GAP = 10    -- seconds between our roster update requests

local handlers   = {}  -- [type] = { fn, category }
local queue      = {}
local sending    = false
local replyPending = false
local newerVersionWarned = false

Comm.stats = { accepted = 0, dropped = {} }
local function Drop(reason)
    Comm.stats.dropped[reason] = (Comm.stats.dropped[reason] or 0) + 1
end

local function Normalize(name)
    return name and Ambiguate(name, "guild") or nil
end

local function IsMe(name)
    local me = ns:PlayerName()
    return name == me or name == Normalize(me)
end

---------------------------------------------------------------------------
-- Sharing (opt-in per guild, account-wide): ns.db.sharing[guildKey]
---------------------------------------------------------------------------
local test -- securitytest state (see Comm:TestBegin)

function Comm:Sharing()
    local key = ns:GuildKey()
    if not key or not ns.db then return nil end
    local s = ns.db.sharing[key]
    if type(s) ~= "table" then
        s = { wishlist = true, pvp = true, helped = true }
        ns.db.sharing[key] = s
    end
    return s
end

function Comm:IsSharing(category)
    if test then return true end
    local s = self:Sharing()
    if not s or s.optIn ~= true then return false end
    if category == nil or category == "presence" then return true end
    return s[category] ~= false
end

function Comm:SetSharing(field, value)
    local s = self:Sharing()
    if not s then return end
    s[field] = value and true or false
    if field == "optIn" then s.asked = true end
    ns:Fire("SHARING_CHANGED", field, s[field])
end

---------------------------------------------------------------------------
-- Roster cache (our own view of who is in the guild, and their rank)
---------------------------------------------------------------------------
local members = {}     -- [short name] = rankIndex
local fullNames = {}   -- [short name] = the name as the roster gives it (for whispers)
local online = {}      -- [short name] = true while online
local rankNames = {}   -- [rankIndex] = rank name, as seen on the roster
local memberCount = 0
local lastRosterAsk = -ROSTER_ASK_GAP
local held = {}        -- messages from senders not (yet) on our roster

local function AskRoster()
    if GetTime() - lastRosterAsk < ROSTER_ASK_GAP then return end
    lastRosterAsk = GetTime()
    if C_GuildInfo and C_GuildInfo.GuildRoster then
        C_GuildInfo.GuildRoster()
    elseif GuildRoster then
        GuildRoster()
    end
end

-- Fires "ROSTER_CHANGED" when someone joined or left (kicked members' requests are
-- hidden at once; see Wishlist:List).
local function RebuildRoster()
    local before, beforeCount = {}, memberCount
    for name in pairs(members) do before[name] = true end
    wipe(members)
    wipe(fullNames)
    wipe(online)
    wipe(rankNames)
    memberCount = 0
    if IsInGuild() then
        for i = 1, GetNumGuildMembers() or 0 do
            local full, rankName, rankIndex, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
            local name = Normalize(full)
            if name then
                members[name] = rankIndex
                fullNames[name] = full
                online[name] = isOnline and true or nil
                if rankIndex and rankName then rankNames[rankIndex] = rankName end
                memberCount = memberCount + 1
            end
        end
    end
    -- Joined or left = the member set differs.
    local changed = memberCount ~= beforeCount
    if not changed then
        for name in pairs(members) do
            if not before[name] then changed = true break end
        end
    end
    if changed then ns:Fire("ROSTER_CHANGED") end
end

-- True once we have a guild roster to check names against (it is empty for a moment
-- after login).
function Comm:RosterReady()
    if test then return true end
    return memberCount > 0
end

function Comm:IsMember(name)
    name = Normalize(name)
    if not name then return false end
    if test then return test.roster[name] ~= nil end
    return members[name] ~= nil
end

function Comm:RankIndex(name)
    name = Normalize(name)
    if test then return name and test.roster[name] end
    return name and members[name]
end

-- Rank names seen on the roster: [rankIndex] = name (ranks nobody holds are missing).
function Comm:RosterRankNames()
    return rankNames
end

-- Online guild members other than me: { { name = short, full = roster name, rankIndex } }
function Comm:OnlineMembers()
    local out = {}
    if test then return out end
    for name in pairs(online) do
        if not IsMe(name) then
            out[#out + 1] = { name = name, full = fullNames[name] or name, rankIndex = members[name] }
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Sending (throttled queue, drained with one-shot timers only while non-empty)
---------------------------------------------------------------------------
local function RawSend(text, channel, target)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        local ok, ret = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, channel or "GUILD", target)
        if not ok then return false, tostring(ret) end
        -- Newer clients return a result enum (0 = success), older ones a boolean.
        if ret == false or (type(ret) == "number" and ret ~= 0) then return false, "result " .. tostring(ret) end
        return true
    end
    return false, "C_ChatInfo.SendAddonMessage not available"
end

local Drain
Drain = function()
    local item = queue[1]
    if not item or not IsInGuild() then
        wipe(queue)
        sending = false
        return
    end
    -- Meant for another guild (the player changed guild since), or sharing turned off.
    if item.key ~= ns:GuildKey() or not Comm:IsSharing(item.category) then
        table.remove(queue, 1)
        return Drain()
    end
    local ok, err = RawSend(item.text, item.channel, item.target)
    if ok then
        table.remove(queue, 1)
    else
        item.tries = item.tries + 1
        Comm.lastError = err
        if item.tries >= MAX_TRIES then table.remove(queue, 1) end
        C_Timer.After(RETRY_DELAY, Drain)
        return
    end
    if #queue > 0 then
        C_Timer.After(SEND_INTERVAL, Drain)
    else
        sending = false
    end
end

local function Build(msgType, ...)
    local parts = { PROTOCOL, msgType }
    for i = 1, select("#", ...) do
        -- "|" separates fields; nothing we send may contain one.
        parts[#parts + 1] = (tostring((select(i, ...))):gsub("|", ""))
    end
    local text = table.concat(parts, "|")
    if #text > MAX_MSG_LEN then
        ns:Print("Comm: message too long, not sent (" .. msgType .. ")")
        return nil
    end
    return text
end

local function Enqueue(text, category, channel, target)
    queue[#queue + 1] = { text = text, tries = 0, key = ns:GuildKey(), category = category,
                          channel = channel, target = target }
    if not sending then
        sending = true
        Drain()
    end
end

-- The security test never sends anything; it only counts what would have gone out.
local function Suppressed()
    if test then test.suppressed = test.suppressed + 1 return true end
    return false
end

function Comm:Send(msgType, ...)
    local category = handlers[msgType] and handlers[msgType].category
    if category == "officer" then return end -- officer data never goes on GUILD
    if Suppressed() or not IsInGuild() or not self:IsSharing(category) then return end
    local text = Build(msgType, ...)
    if text then Enqueue(text, category, "GUILD") end
end

-- Officer data: over the OFFICER addon channel (reaches members who can read officer
-- chat) and as a WHISPER to every roster name in `targets` (members our own roster says
-- may see the officer log, which covers ranks without officer chat). Receivers drop
-- duplicates.
function Comm:SendOfficer(msgType, targets, ...)
    if Suppressed() or not IsInGuild() or not self:IsSharing() then return end
    local text = Build(msgType, ...)
    if not text then return end
    Enqueue(text, "officer", "OFFICER")
    for _, full in ipairs(targets or {}) do Enqueue(text, "officer", "WHISPER", full) end
end

-- For /tavern probe: send one harmless message (an unknown type every client drops) on
-- a channel and report what the game said.
function Comm:ProbeSend(channel)
    if not IsInGuild() then return false, "not in a guild" end
    return RawSend(PROTOCOL .. "|PING", channel)
end

function Comm:QueueLength()
    return #queue
end

function Comm:RegisterHandler(msgType, fn, category)
    handlers[msgType] = { fn = fn, category = category }
end

---------------------------------------------------------------------------
-- Receiving: the gate
---------------------------------------------------------------------------
local buckets = {} -- [sender] = { tokens, t }

local function RateOK(sender)
    local now = GetTime()
    local b = buckets[sender]
    if not b then
        b = { tokens = RATE_BURST, t = now }
        buckets[sender] = b
    end
    b.tokens = math.min(RATE_BURST, b.tokens + (now - b.t) * RATE_PER_SEC)
    b.t = now
    if b.tokens < 1 then return false end
    b.tokens = b.tokens - 1
    return true
end

local function Dispatch(name, fields)
    local h = handlers[fields[2]]
    if not Comm:IsSharing(h.category) then Drop("category off") return end
    if not RateOK(name) then Drop("rate limit") return end
    Comm.stats.accepted = Comm.stats.accepted + 1
    local ok, err = pcall(h.fn, name, select(3, unpack(fields)))
    if not ok then Drop("handler error") Comm.lastHandlerError = err end
end

-- Returns nothing; every rejection is counted in Comm.stats.dropped.
local function Receive(text, channel, sender)
    if channel ~= "GUILD" and channel ~= "OFFICER" and channel ~= "WHISPER" then Drop("channel") return end
    if type(text) ~= "string" or #text > MAX_MSG_LEN then Drop("malformed") return end
    local fields = { strsplit("|", text) }
    if fields[1] ~= PROTOCOL then Drop("old protocol") return end
    if #fields > MAX_FIELDS or not handlers[fields[2]] then Drop("unknown type") return end
    -- Officer data only off GUILD; everything else only on GUILD.
    local officer = handlers[fields[2]].category == "officer"
    if officer ~= (channel ~= "GUILD") then Drop("channel") return end
    local name = Normalize(sender)
    if not ns:ValidName(name) then Drop("bad sender") return end
    if IsMe(name) then return end
    if not ns:GuildKey() then Drop("not in guild") return end
    if not Comm:IsSharing() then Drop("sharing off") return end
    if Comm:IsMember(name) then
        Dispatch(name, fields)
    elseif test then
        Drop("not in guild roster")
    else
        -- Maybe they just joined: hold briefly, ask for a fresh roster, re-check once.
        if #held >= MAX_HELD then Drop("not in guild roster") return end
        held[#held + 1] = { name = name, fields = fields, t = GetTime() }
        AskRoster()
    end
end

local function RecheckHeld()
    local list = held
    held = {}
    for _, m in ipairs(list) do
        if Comm:IsMember(m.name) then
            Dispatch(m.name, m.fields)
        elseif GetTime() - m.t < HOLD_SECONDS and lastRosterAsk < m.t then
            held[#held + 1] = m -- the roster we asked for hasn't arrived yet
        else
            Drop("not in guild roster")
        end
    end
end

local function OnAddonMessage(_, prefix, text, channel, sender)
    if prefix ~= PREFIX then return end
    Comm.lastSenderRaw = sender -- kept for /tavern sync diagnostics
    Receive(text, channel, sender)
end

---------------------------------------------------------------------------
-- Presence
---------------------------------------------------------------------------
local function Users()
    local key = ns:GuildKey()
    if not key then return nil end
    if type(ns.db.roster[key]) ~= "table" then ns.db.roster[key] = { users = {} } end
    ns.db.roster[key].users = ns.db.roster[key].users or {}
    return ns.db.roster[key].users
end

local function VersionNumber(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)$")
    if not a then return 0 end
    return tonumber(a) * 10000 + tonumber(b) * 100 + (tonumber(c) or 0)
end

local function SendHello(flag)
    Comm:Send("H", ns.version, flag)
end

local helloCount = 0 -- hellos heard this session (for the Sync button's summary)
function Comm:HelloCount() return helloCount end

Comm:RegisterHandler("H", function(sender, version, flag)
    if flag ~= "Q" and flag ~= "R" then return end
    if type(version) ~= "string" or #version > 12 or not version:match("^%d+%.%d+%.?%d*$") then return end
    helloCount = helloCount + 1
    local users = Users()
    if not users then return end
    local isNew = not users[sender] or users[sender].version ~= version
    users[sender] = { version = version, seen = time() }
    if isNew then ns:Fire("ADDON_USERS_CHANGED", sender) end
    ns:Fire("HELLO", sender, flag)

    if not newerVersionWarned and VersionNumber(version) > VersionNumber(ns.version) then
        newerVersionWarned = true
        ns:Print(("%s has a newer version (%s, you have %s)."):format(sender, version, ns.version))
    end

    -- Answer a login hello once, after a random delay; several hellos in a row share one reply.
    if flag == "Q" and not replyPending then
        replyPending = true
        C_Timer.After(1 + math.random() * 3, function()
            replyPending = false
            SendHello("R")
        end)
    end
end)

-- Manual sync (Roster's Sync button): ask everyone to announce themselves again.
-- Other modules can piggyback via ns:RegisterCallback("SYNC_REQUESTED", fn).
-- Returns true, or false + seconds left on the cooldown (0 = not in a guild, "off" = sharing off).
local SYNC_COOLDOWN = 30
local lastSync = -SYNC_COOLDOWN
Comm.SYNC_COOLDOWN = SYNC_COOLDOWN

function Comm:RequestSync()
    if not IsInGuild() then return false, 0 end
    if not self:IsSharing() then return false, "off" end
    local left = SYNC_COOLDOWN - (GetTime() - lastSync)
    if left > 0 then return false, math.ceil(left) end
    lastSync = GetTime()
    SendHello("Q")
    ns:Fire("SYNC_REQUESTED")
    return true
end

function Comm:HasAddon(name)
    local users = Users()
    local u = users and users[Normalize(name)]
    return u and u.version or nil
end

-- Counts current guild members known to run the addon (including you).
function Comm:CountAddonUsers()
    local users = Users()
    if not users then return 0 end
    local n = 0
    for i = 1, GetNumGuildMembers() or 0 do
        local full = GetGuildRosterInfo(i)
        local name = Normalize(full)
        if name and (users[name] or IsMe(name)) then n = n + 1 end
    end
    return n
end

local function PruneOld()
    local users = Users()
    if not users then return end
    local cutoff = time() - USER_EXPIRY
    for name, u in pairs(users) do
        if type(u) ~= "table" or (u.seen or 0) < cutoff then users[name] = nil end
    end
end

local helloSent = false
local function SayHello()
    if helloSent or not IsInGuild() or not Comm:IsSharing() then return end
    helloSent = true
    PruneOld()
    SendHello("Q")
end

local function OnEnteringWorld()
    C_Timer.After(HELLO_DELAY, SayHello)
end

-- Guild changes: forget the old roster, drop anything still queued for the old guild.
local currentKey
local function OnGuildUpdate()
    local key = ns:GuildKey()
    if key == currentKey then return end
    currentKey = key
    ns:AdoptOldGuildKey(key) -- old realm-name keys -> realm-ID key (Core.lua)
    wipe(queue)
    wipe(held)
    wipe(buckets)
    RebuildRoster()
    AskRoster()
    helloSent = false
    ns:Fire("GUILD_CHANGED", key)
end

---------------------------------------------------------------------------
-- Security test hooks (Modules\SecurityTest.lua). While a test runs, nothing is
-- sent, the roster is a fake one, and data goes to a throwaway guild key.
---------------------------------------------------------------------------
function Comm:TestBegin(roster)
    test = { roster = roster, suppressed = 0 }
    wipe(buckets)
end

function Comm:TestReceive(sender, text, channel)
    Receive(text, channel or "GUILD", sender)
end

function Comm:TestEnd()
    local suppressed = test and test.suppressed or 0
    test = nil
    wipe(buckets)
    return suppressed
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end
ns:RegisterEvent("CHAT_MSG_ADDON", OnAddonMessage)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    OnGuildUpdate()
    OnEnteringWorld()
end)
ns:RegisterEvent("PLAYER_GUILD_UPDATE", OnGuildUpdate)
ns:RegisterEvent("GUILD_ROSTER_UPDATE", function()
    OnGuildUpdate()
    RebuildRoster()
    if #held > 0 then RecheckHeld() end
end)
-- Opting in later: say hello then (modules announce their own data on SHARING_CHANGED).
ns:RegisterCallback("SHARING_CHANGED", function(_, field, value)
    if field == "optIn" and value then SayHello() end
end)

-- /tavern sync: who runs the addon, plus transport diagnostics.
ns:RegisterCommand("sync", function()
    local users = Users()
    if not users then ns:Print("Not in a guild.") return end
    ns:Print(("Guild key: %s. Sharing: %s. Known addon users:"):format(ns:GuildKey(),
        Comm:IsSharing() and "on" or "|cffff4040off|r"))
    local names = {}
    for name in pairs(users) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local u = users[name]
        DEFAULT_CHAT_FRAME:AddMessage(("  %s  v%s  seen %s"):format(name, tostring(u.version), date("%Y-%m-%d %H:%M", u.seen or 0)))
    end
    if #names == 0 then DEFAULT_CHAT_FRAME:AddMessage("  (nobody else yet)") end
    DEFAULT_CHAT_FRAME:AddMessage(("  in guild with addon (incl. you): %d | roster cache: %d members"):format(
        Comm:CountAddonUsers(), memberCount))
    DEFAULT_CHAT_FRAME:AddMessage(("  last sender as received: %s | queued: %d | last send error: %s"):format(
        tostring(Comm.lastSenderRaw), #queue, tostring(Comm.lastError)))
    local drops = {}
    for reason, n in pairs(Comm.stats.dropped) do drops[#drops + 1] = reason .. " " .. n end
    DEFAULT_CHAT_FRAME:AddMessage(("  accepted %d | dropped: %s"):format(Comm.stats.accepted,
        #drops > 0 and table.concat(drops, ", ") or "none"))
end, "list guild members running the addon")
