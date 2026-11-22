-- Modules\KOSMod.lua: moderators and the guild Kill on Sight list, plus a read-only
-- import of the player's own Spy Kill on Sight list.
--
--   * Remove: a moderator takes an enemy off the guild list. Every entry for that enemy
--     added up to that moment stops counting (adding them again later is a new entry).
--     The adders' own clients then remove their entries and announce that like any
--     edit of their own. Shown in the public Guild log.
--   * Approval (optional, set by the guild leader in Settings > PvP): entries from
--     players who can't moderate wait until a moderator approves them. Until then only
--     moderators and the adder see them (PvP tab > Kill on Sight, "Waiting").
--     Rejecting = removing.
--   Moderators are the ranks ticked under Settings > Permissions ("Moderate").
--
-- Messages (protocol 2, GUILD, sharing category "kos"):
--   KR|target|at          "I removed this enemy from the list" (entries added up to `at`)
--   KA|adder|target|at    "I approved this player's entry" (if it was added up to `at`)
--
-- TRUST: the moderator is the sender (set by the server). Every client checks the
-- sender's rank against the leader's config FROM ITS OWN ROSTER, on receipt and again
-- whenever the list is rebuilt (a demoted moderator's actions stop counting). Nothing
-- in a message counts as a rank. Moderators announce only their OWN actions (no
-- relaying) and re-announce them for 30 days (the life of an entry).
--
-- Stored per guild: ns.db.kosMod[guildKey] = { rm = { [target] = { at, by } },
--                                              ok = { [adder#target] = { at, by } } }
local _, ns = ...
local KOS, Comm, Perms = ns.KOS, ns.Comm, ns.Perms

local KOSMod = {}
ns.KOSMod = KOSMod

local KEEP         = KOS.EXPIRE_DAYS * 86400 -- actions matter as long as an entry can live
local MAX_STORED   = 500
local ANNOUNCE_GAP = 120
local FUTURE_SLACK = 3600
local MOD_COLOR    = "|cffff8000"

KOSMod.rejected = 0 -- messages refused (for /tavern securitytest)

local function Now() return GetServerTime and GetServerTime() or time() end
local function Me() return ns:PlayerName() end
local function Id(adder, target) return adder .. "#" .. target end

local function Store()
    local key = ns:GuildKey()
    if not key then return nil end
    local s = ns.db.kosMod[key]
    if type(s) ~= "table" then s = {} ns.db.kosMod[key] = s end
    s.rm = type(s.rm) == "table" and s.rm or {}
    s.ok = type(s.ok) == "table" and s.ok or {}
    return s
end

-- A moderator by our own roster. Before the roster has loaded, stored actions count
-- (they were checked when they arrived).
local function IsMod(name)
    if not Comm:RosterReady() then return true end
    return Perms:Can(name, "mod")
end

function KOSMod:ApprovalOn() return Perms:Flag(Perms.FLAG_KOS_APPROVAL) end

---------------------------------------------------------------------------
-- The rule KOS.lua applies to every entry
---------------------------------------------------------------------------
KOS.filter = function(e)
    local s = Store()
    if not s then return nil end
    local added = KOS:Added(e)
    local rm = s.rm[e.target]
    if rm and added <= rm.at and IsMod(rm.by) then return "hide" end
    if not KOSMod:ApprovalOn() or IsMod(e.adder) then return nil end
    local ok = s.ok[Id(e.adder, e.target)]
    if ok and added <= ok.at and IsMod(ok.by) then return nil end
    return "pending"
end

---------------------------------------------------------------------------
-- Applying an action (mine or a received one, after the rank check)
---------------------------------------------------------------------------
local function Trim(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    while n > MAX_STORED do
        local oldest, oldestId
        for id, a in pairs(t) do
            if a.by ~= Me() and (not oldest or a.at < oldest) then oldest, oldestId = a.at, id end
        end
        if not oldestId then break end
        t[oldestId] = nil
        n = n - 1
    end
end

local function CleanName(name)
    if type(name) ~= "string" then return nil end
    return ns:ValidName(ns:CleanText(name, 48))
end

local function ValidAt(at)
    local now = Now()
    return ns:Int(at, now - KEEP - FUTURE_SLACK, now + FUTURE_SLACK)
end

-- Returns true if the action was valid.
local function ApplyRemove(moderator, target, at)
    target, at = CleanName(target), ValidAt(at)
    if not (target and at) or Comm:IsMember(target) then KOSMod.rejected = KOSMod.rejected + 1 return false end
    if not Perms:Can(moderator, "mod") then KOSMod.rejected = KOSMod.rejected + 1 return false end
    local s = Store()
    if not s then return false end
    local old = s.rm[target]
    if not old or old.at < at then
        s.rm[target] = { at = at, by = moderator }
        Trim(s.rm)
    end
    -- My own entry: remove it, so my client stops announcing it as active.
    local mine = KOS:Mine(target)
    if mine and KOS:Added(mine) <= at then
        KOS:Remove(target)
        if moderator ~= Me() then
            ns:Print(("%sModerator|r %s took %s off the guild Kill on Sight list (your entry too)."):format(
                MOD_COLOR, moderator, target))
        end
    end
    KOS:Refresh()
    ns:Fire("MODERATION", { id = "K:" .. target .. ":" .. at, kind = "K", actor = moderator, requester = target, t = at })
    return true
end

local function ApplyApprove(moderator, adder, target, at)
    adder, target, at = ns:ValidName(adder), CleanName(target), ValidAt(at)
    if not (adder and target and at) then KOSMod.rejected = KOSMod.rejected + 1 return false end
    if not Perms:Can(moderator, "mod") then KOSMod.rejected = KOSMod.rejected + 1 return false end
    local s = Store()
    if not s then return false end
    local id = Id(adder, target)
    local old = s.ok[id]
    if old and old.at >= at then return true end
    s.ok[id] = { at = at, by = moderator }
    Trim(s.ok)
    if adder == Me() and moderator ~= Me() and KOSMod:ApprovalOn() then
        local mine = KOS:Mine(target)
        if mine and KOS:IsPending(mine) and KOS:Added(mine) <= at then
            ns:Print(("%sModerator|r %s approved your Kill on Sight entry for %s."):format(MOD_COLOR, moderator, target))
        end
    end
    KOS:Refresh()
    return true
end

Comm:RegisterHandler("KR", function(sender, target, at) ApplyRemove(sender, target, at) end, "kos")
Comm:RegisterHandler("KA", function(sender, adder, target, at) ApplyApprove(sender, adder, target, at) end, "kos")

-- Test hooks (/tavern securitytest)
KOSMod.ApplyRemove, KOSMod.ApplyApprove = ApplyRemove, ApplyApprove

---------------------------------------------------------------------------
-- My own actions: do, remember, announce
---------------------------------------------------------------------------
local function SendRemove(target, a) Comm:Send("KR", target, a.at) end
local function SendApprove(id, a)
    local adder, target = id:match("^(.-)#(.+)$")
    if adder then Comm:Send("KA", adder, target, a.at) end
end

function KOSMod:Remove(target)
    if not Perms:ICan("mod") then ns:Print("Only ranks the guild leader allows can moderate.") return end
    local at = Now()
    if ApplyRemove(Me(), target, at) then
        SendRemove(target, { at = at })
        ns:Print(("Took %s off the guild Kill on Sight list (logged in the Guild log)."):format(target))
    end
end

function KOSMod:Approve(adder, target)
    if not Perms:ICan("mod") then ns:Print("Only ranks the guild leader allows can moderate.") return end
    local at = Now()
    if ApplyApprove(Me(), adder, target, at) then
        SendApprove(Id(adder, target), { at = at })
        ns:Print(("Approved %s's Kill on Sight entry for %s."):format(adder, target))
    end
end

local lastAnnounce, announcePending = -ANNOUNCE_GAP, false
local function AnnounceOwn()
    announcePending = false
    local s = Store()
    if not s or not Perms:ICan("mod") or not Comm:IsSharing("kos") then return end
    lastAnnounce = GetTime()
    local cutoff, me = Now() - KEEP, Me()
    for target, a in pairs(s.rm) do
        if a.by == me and a.at >= cutoff then SendRemove(target, a) end
    end
    for id, a in pairs(s.ok) do
        if a.by == me and a.at >= cutoff then SendApprove(id, a) end
    end
end

local function ScheduleAnnounce(delay)
    if announcePending then return end
    announcePending = true
    C_Timer.After(math.max(delay, ANNOUNCE_GAP - (GetTime() - lastAnnounce)), AnnounceOwn)
end

ns:RegisterCallback("HELLO", function(_, _, flag)
    if flag == "Q" then ScheduleAnnounce(5 + math.random() * 8) end
end)
ns:RegisterCallback("SYNC_REQUESTED", function() lastAnnounce = -ANNOUNCE_GAP ScheduleAnnounce(3) end)
ns:RegisterCallback("PERMS_CHANGED", function() KOS:Refresh() end)

-- A new entry waiting for my approval: say so once per session.
local told = {}
ns:RegisterCallback("KOS_RECEIVED", function(_, e, isNew)
    if not isNew or not KOSMod:ApprovalOn() or not Perms:ICan("mod") then return end
    local id = Id(e.adder, e.target) .. ":" .. KOS:Added(e)
    if told[id] or not KOS:IsPending(e) then return end
    told[id] = true
    ns:Print(("%sModerator:|r %s put %s on Kill on Sight. Waiting for approval (PvP tab > Kill on Sight)."):format(
        MOD_COLOR, e.adder, e.target))
end)

---------------------------------------------------------------------------
-- Upkeep
---------------------------------------------------------------------------
local function Purge(s)
    local cutoff = Now() - KEEP - 86400
    for _, t in ipairs({ s.rm, s.ok }) do
        for id, a in pairs(t) do if a.at < cutoff then t[id] = nil end end
    end
end

ns:RegisterCallback("VALIDATE_DB", function()
    for key, s in pairs(ns.db.kosMod) do
        if type(key) ~= "string" or type(s) ~= "table" then
            ns.db.kosMod[key] = nil
        else
            for _, field in ipairs({ "rm", "ok" }) do
                local t = type(s[field]) == "table" and s[field] or {}
                s[field] = t
                for id, a in pairs(t) do
                    local valid = type(id) == "string" and type(a) == "table" and ns:Int(a.at, 1) and ns:ValidName(a.by)
                    if valid and field == "rm" then valid = ns:ValidName(id) ~= nil end
                    if valid and field == "ok" then
                        local adder, target = id:match("^(.-)#(.+)$")
                        valid = adder and ns:ValidName(adder) and ns:ValidName(target)
                    end
                    if not valid then t[id] = nil end
                end
            end
            Purge(s)
        end
    end
end)

---------------------------------------------------------------------------
-- Menus (KOS:FillMenu calls this: PvP tab rows, Nearby window, target frame)
---------------------------------------------------------------------------
local function ConfirmRemove(target)
    ns.Dialog:Show({
        text = ("%sModerator:|r take %s off the guild Kill on Sight list?\nEveryone's entries for them stop counting."
            .. " Everyone sees this in the Guild log."):format(MOD_COLOR, target),
        accept = "Remove",
        onAccept = function() KOSMod:Remove(target) end,
    })
end

KOS.FillModMenu = function(root, target)
    if not Perms:ICan("mod") or not ns:GuildKey() then return end
    local active, waiting = KOS:Entries(target), KOS:PendingEntries(target)
    if not active and not waiting then return end
    root:CreateDivider()
    root:CreateTitle(MOD_COLOR .. "Moderator|r")
    for _, e in ipairs(waiting or {}) do
        root:CreateButton(("Approve %s's entry"):format(e.adder), function() KOSMod:Approve(e.adder, target) end)
    end
    root:CreateButton(waiting and not active and "Reject (remove from the list)" or "Remove from the list", function()
        ConfirmRemove(target)
    end)
end

---------------------------------------------------------------------------
-- Import my Spy Kill on Sight list (read-only: Spy's data is never changed or sent)
---------------------------------------------------------------------------
-- Spy keeps per-character data in SpyPerCharDB: KOSData[name] and PlayerData[name],
-- with names written "First-Second".
local function SpyNames()
    local db = rawget(_G, "SpyPerCharDB")
    local kos = type(db) == "table" and db.KOSData
    if type(kos) ~= "table" then return nil end
    local players = type(db.PlayerData) == "table" and db.PlayerData or {}
    local out = {}
    for key in pairs(kos) do
        if type(key) == "string" then
            local name = CleanName((key:gsub("%-", " ", 1)))
            if name then
                local p = players[key]
                p = type(p) == "table" and p or {}
                out[#out + 1] = { name = name, info = {
                    class = type(p.class) == "string" and p.class:upper() or nil,
                    level = tonumber(p.level),
                    guild = type(p.guild) == "string" and p.guild or nil,
                } }
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function KOSMod:ImportSpy()
    if not ns:GuildKey() then ns:Print("Join a guild to use the Kill on Sight list.") return end
    local list = SpyNames()
    if not list then ns:Print("No Spy Kill on Sight list found on this character (Spy must be loaded).") return end
    local todo = {}
    for _, p in ipairs(list) do
        if not KOS:Mine(p.name) and not Comm:IsMember(p.name) and p.name ~= Me() then todo[#todo + 1] = p end
    end
    local room = KOS.MAX_PER_PLAYER - KOS:MyCount()
    if #todo == 0 then ns:Print("Everyone on your Spy Kill on Sight list is already on yours.") return end
    if room <= 0 then
        ns:Print(("You have %d players on Kill on Sight already (the most). Remove some first."):format(KOS.MAX_PER_PLAYER))
        return
    end
    local n = math.min(room, #todo)
    local extra = #todo > room and ("\n\nYou have room for %d, so the first %d (A to Z) are added."):format(room, n) or ""
    ns.Dialog:Show({
        text = ("Add %d players from your Spy Kill on Sight list to the guild list, with the reason \"From Spy\"?%s")
            :format(#todo, extra),
        accept = "Import",
        onAccept = function()
            local added = 0
            for i = 1, n do
                if KOS:Add(todo[i].name, todo[i].info, 0, "From Spy") then added = added + 1 end
            end
            local note = Comm:IsSharing("kos") and "" or " |cff999999(sharing is off: only you see them)|r"
            ns:Print(("Imported %d players from Spy to the guild Kill on Sight list.%s"):format(added, note))
        end,
    })
end

ns:RegisterCommand("kosimport", function() KOSMod:ImportSpy() end,
    "add your Spy Kill on Sight list to the guild list (Spy's own list is not changed)")

---------------------------------------------------------------------------
-- Settings > PvP
---------------------------------------------------------------------------
ns.Settings:RegisterToggle({
    category = "pvp", order = 40,
    label = "Kill on Sight entries need moderator approval",
    description = "Guild leader only. Entries from players who can't moderate wait until a moderator approves them."
        .. " Moderators are the ranks ticked under Settings > Permissions. Guildmates get this when they're online with you.",
    get = function() return KOSMod:ApprovalOn() end,
    set = function(v) Perms:SetFlag(Perms.FLAG_KOS_APPROVAL, v) end,
    disabled = function() return not Perms:IAmLeader() end,
})

ns.Settings:RegisterButton({
    category = "pvp", order = 41,
    label = "Import my Spy Kill on Sight list",
    buttonText = "Import",
    onClick = function() KOSMod:ImportSpy() end,
})
