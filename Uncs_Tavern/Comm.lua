-- Comm.lua: guild addon messaging (prefix UNCST) and presence.
--
-- Wire format (every message is versioned):   <protocol>|<type>|<field>|<field>...
--   1|H|<addonVersion>|Q   hello, "who else runs the addon?" (sent once after login)
--   1|H|<addonVersion>|R   reply to a hello (sent once, coalesced, after a random delay)
-- Unknown protocol versions and unknown types are ignored, so older clients
-- keep working when newer ones add message types.
--
-- API for other modules:
--   ns.Comm:Send(type, ...fields)            queue a guild message (throttled)
--   ns.Comm:RegisterHandler(type, fn)        fn(sender, ...fields)
--   ns.Comm:HasAddon(name) -> version|nil    ns.Comm:CountAddonUsers() -> n
-- Fires ns callback "ADDON_USERS_CHANGED" when someone new is seen.
local _, ns = ...

local Comm = {}
ns.Comm = Comm

local PREFIX         = "UNCST"
local PROTOCOL       = "1"
local SEND_INTERVAL  = 1.5   -- seconds between our messages (well under server limits)
local RETRY_DELAY    = 5     -- seconds before retrying a refused send
local MAX_TRIES      = 3
local HELLO_DELAY    = 10    -- seconds after login before announcing (let the UI settle)
local USER_EXPIRY    = 30 * 24 * 3600 -- forget users not seen for 30 days
local MAX_MSG_LEN    = 255

local handlers = {}
local queue = {}
local sending = false
local replyPending = false
local newerVersionWarned = false

---------------------------------------------------------------------------
-- Storage: ns.db.roster[guildKey].users[name] = { version, seen }
---------------------------------------------------------------------------
local function GuildKey() return ns:GuildKey() end

local function Users()
    local key = GuildKey()
    if not key then return nil end
    ns.db.roster[key] = ns.db.roster[key] or { users = {} }
    return ns.db.roster[key].users
end

local function Normalize(name)
    return name and Ambiguate(name, "guild") or nil
end

local function IsMe(name)
    local me = ns:PlayerName()
    return name == me or name == Normalize(me)
end

---------------------------------------------------------------------------
-- Sending (throttled queue, drained with one-shot timers only while non-empty)
---------------------------------------------------------------------------
local function RawSend(text)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        local ok, ret = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, "GUILD")
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
        sending = false
        return
    end
    local ok, err = RawSend(item.text)
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

function Comm:Send(msgType, ...)
    local parts = { PROTOCOL, msgType }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local text = table.concat(parts, "|")
    if #text > MAX_MSG_LEN then
        ns:Print("Comm: message too long, not sent (" .. msgType .. ")")
        return
    end
    queue[#queue + 1] = { text = text, tries = 0 }
    if not sending then
        sending = true
        Drain()
    end
end

function Comm:RegisterHandler(msgType, fn)
    handlers[msgType] = fn
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function OnAddonMessage(_, prefix, text, channel, sender)
    if prefix ~= PREFIX or channel ~= "GUILD" then return end
    Comm.lastSenderRaw = sender -- kept for /tavern sync diagnostics
    local fields = { strsplit("|", text) }
    if fields[1] ~= PROTOCOL then return end
    local name = Normalize(sender)
    if not name or IsMe(name) then return end
    local fn = handlers[fields[2]]
    if fn then fn(name, select(3, unpack(fields))) end
end

---------------------------------------------------------------------------
-- Presence
---------------------------------------------------------------------------
local function VersionNumber(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    if not a then return 0 end
    return tonumber(a) * 10000 + tonumber(b) * 100 + (tonumber(c) or 0)
end

local function SendHello(flag)
    Comm:Send("H", ns.version, flag)
end

Comm:RegisterHandler("H", function(sender, version, flag)
    local users = Users()
    if not users then return end
    local isNew = not users[sender] or users[sender].version ~= version
    users[sender] = { version = version, seen = time() }
    if isNew then ns:Fire("ADDON_USERS_CHANGED", sender) end

    if not newerVersionWarned and VersionNumber(version) > VersionNumber(ns.version) then
        newerVersionWarned = true
        ns:Print(("%s has a newer version (%s, you have %s)."):format(sender, tostring(version), ns.version))
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
-- Returns true, or false + seconds left on the cooldown.
local SYNC_COOLDOWN = 30
local lastSync = -SYNC_COOLDOWN
Comm.SYNC_COOLDOWN = SYNC_COOLDOWN

function Comm:RequestSync()
    if not IsInGuild() then return false, 0 end
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
        if (u.seen or 0) < cutoff then users[name] = nil end
    end
end

local helloSent = false
local function OnEnteringWorld()
    if helloSent then return end
    helloSent = true
    C_Timer.After(HELLO_DELAY, function()
        if not IsInGuild() then return end
        PruneOld()
        SendHello("Q")
    end)
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
end
ns:RegisterEvent("CHAT_MSG_ADDON", OnAddonMessage)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", OnEnteringWorld)

-- /tavern sync: who runs the addon, plus transport diagnostics.
ns:RegisterCommand("sync", function()
    local users = Users()
    if not users then ns:Print("Not in a guild.") return end
    ns:Print(("Guild key: %s. Known addon users:"):format(GuildKey()))
    local names = {}
    for name in pairs(users) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local u = users[name]
        DEFAULT_CHAT_FRAME:AddMessage(("  %s  v%s  seen %s"):format(name, tostring(u.version), date("%Y-%m-%d %H:%M", u.seen or 0)))
    end
    if #names == 0 then DEFAULT_CHAT_FRAME:AddMessage("  (nobody else yet)") end
    DEFAULT_CHAT_FRAME:AddMessage(("  in guild with addon (incl. you): %d"):format(Comm:CountAddonUsers()))
    DEFAULT_CHAT_FRAME:AddMessage(("  last sender as received: %s | queued: %d | last send error: %s"):format(
        tostring(Comm.lastSenderRaw), #queue, tostring(Comm.lastError)))
end, "list guild members running the addon")
