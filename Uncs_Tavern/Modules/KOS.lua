-- Modules\KOS.lua: the guild's Kill on Sight list.
--
-- Each guild member keeps their OWN entries ("I put this enemy on Kill on Sight") and
-- announces them; the guild list is everyone's entries together. An enemy is on the
-- list while at least one guildmate's entry is active.
--   entry = { target, adder, class, level, guild, rc, reason, t, added, updated, deleted }
--     rc     = reason preset (1..#PRESETS), 0 = own text in `reason` (or none: quick add)
--     t      = when added / last renewed (server time); active for EXPIRE_DAYS after that
--     added  = when first added (renewing keeps it); moderator removals and approvals
--              cover entries added up to the moment of the action (KOSMod.lua)
--     class / level / guild = what the adder's client saw of the enemy (descriptive only)
--
-- Message (protocol 2, GUILD, sharing category "kos"):
--   KS|target|class|level|guild|rc|reason|t|deleted|updated|added
--
-- TRUST (see "Security rules" in CLAUDE.md):
--   * the adder is the sender (set by the server): nobody can add, renew or remove an
--     entry in someone else's name. No relaying: each player announces only their own.
--   * every field is checked: target a valid name that isn't the sender or a guild
--     member, class from the game's list, level -1..60, texts cleaned (no escape codes)
--     and capped, preset in range, times not in the future and not older than the expiry.
--   * at most MAX_PER_PLAYER active entries per adder; stored entries capped.
-- Moderator removal and approval: KOSMod.lua (sets KOS.filter).
--
-- Announcing (like the wishlist): ~20 s after login, when a guildmate logs in or presses
-- Sync (at most once per ANNOUNCE_GAP), and live on every change. Own removals keep
-- being announced for EXPIRE_DAYS so they reach people who were offline.
--
-- Stored per guild, account-wide: ns.db.kos[guildKey][adder .. "#" .. target] = entry
local _, ns = ...
local Comm = ns.Comm

local KOS = {}
ns.KOS = KOS

local EXPIRE_DAYS    = 30
local MAX_PER_PLAYER = 25
local MAX_STORED     = 2000
local MAX_REASON     = 60
local LOGIN_DELAY    = 20
local ANNOUNCE_GAP   = 120
local FUTURE_SLACK   = 3600

KOS.EXPIRE_DAYS, KOS.MAX_PER_PLAYER, KOS.MAX_REASON = EXPIRE_DAYS, MAX_PER_PLAYER, MAX_REASON
KOS.PRESETS = { "Ganking", "Corpse camping", "Kills low levels", "Griefing questers" }
KOS.SKULL = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_8:0|t"

KOS.rejected = 0 -- messages refused (for /tavern securitytest)

local function Now() return GetServerTime and GetServerTime() or time() end
local EXPIRE = EXPIRE_DAYS * 86400

local cache   -- [target] = { entries }, rebuilt after changes
local pending -- [target] = { entries } waiting for moderator approval

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------
local function Bucket()
    local key = ns:GuildKey()
    if not key then return nil end
    if type(ns.db.kos[key]) ~= "table" then ns.db.kos[key] = {} end
    return ns.db.kos[key]
end

local function Id(adder, target) return adder .. "#" .. target end

local function Me() return ns:PlayerName() end

function KOS:IsActive(e, now)
    return e and not e.deleted and (e.t or 0) + EXPIRE > (now or Now())
end

function KOS:ExpiresAt(e) return (e.t or 0) + EXPIRE end

-- Entries from people who left the guild stop counting (once our roster is known).
local function Counts(e)
    if e.adder == Me() then return true end
    if not Comm:IsSharing("kos") then return false end -- sharing off: only my own
    if not Comm:RosterReady() then return true end
    return Comm:IsMember(e.adder)
end

local function Changed()
    cache = nil
    ns:Fire("KOS_CHANGED")
end

function KOS:Refresh() Changed() end

function KOS:Added(e) return e.added or e.t or 0 end

-- KOS.filter(e) (KOSMod.lua): nil = counts, "hide" = removed by a moderator,
-- "pending" = waiting for moderator approval.
local function Rebuild()
    cache, pending = {}, {}
    local now = Now()
    for _, e in pairs(Bucket() or {}) do
        if KOS:IsActive(e, now) and Counts(e) then
            local state = KOS.filter and KOS.filter(e)
            local into = (state == nil and cache) or (state == "pending" and pending) or nil
            if into then
                into[e.target] = into[e.target] or {}
                table.insert(into[e.target], e)
            end
        end
    end
    for _, t in ipairs({ cache, pending }) do
        for _, list in pairs(t) do
            table.sort(list, function(a, b) return (a.t or 0) < (b.t or 0) end)
        end
    end
end

-- Active entries for a target, oldest first (nil = not on the list).
function KOS:Entries(target)
    if not cache then Rebuild() end
    return target and cache[target]
end

function KOS:IsKOS(target) return self:Entries(target) ~= nil end

-- Entries for a target waiting for moderator approval (nil = none).
function KOS:PendingEntries(target)
    if not cache then Rebuild() end
    return target and pending[target]
end

-- Whether this entry is waiting for approval.
function KOS:IsPending(e)
    local list = e and self:PendingEntries(e.target)
    for _, p in ipairs(list or {}) do if p == e then return true end end
    return false
end

-- My own active entry for a target.
function KOS:Mine(target)
    local b = Bucket()
    local e = b and target and b[Id(Me(), target)]
    return self:IsActive(e) and e or nil
end

local function ActiveCount(adder, except)
    local n, now = 0, Now()
    for id, e in pairs(Bucket() or {}) do
        if e.adder == adder and id ~= except and KOS:IsActive(e, now) then n = n + 1 end
    end
    return n
end

function KOS:MyCount() return ActiveCount(Me()) end

-- { { name, e = { class, level, guild }, entries }, ... } newest first.
-- Targets only waiting for approval are included for moderators and for their adder,
-- with pending = true.
function KOS:Targets()
    if not cache then Rebuild() end
    local out = {}
    local rows = {}
    for target, list in pairs(cache) do rows[target] = { list = list } end
    local isMod = ns.Perms and ns.Perms:ICan("mod")
    for target, list in pairs(pending) do
        if not rows[target] then
            local show = isMod
            for _, e in ipairs(list) do if e.adder == Me() then show = true end end
            if show then rows[target] = { list = list, pending = true } end
        end
    end
    for target, row in pairs(rows) do
        local list = row.list
        local newest = list[#list]
        -- Descriptive info: my own enemy book if I've seen them, else the newest entry's.
        local seen = ns.Enemies and ns.Enemies:Get(target)
        out[#out + 1] = {
            name = target, entries = list, newest = newest.t or 0, pending = row.pending,
            e = { class = (seen and seen.class) or newest.class, level = (seen and seen.level) or newest.level,
                  guild = (seen and seen.guild) or newest.guild,
                  wins = seen and seen.wins, losses = seen and seen.losses, last = seen and seen.last,
                  zone = seen and seen.zone, first = seen and seen.first, met = seen and seen.met },
        }
    end
    table.sort(out, function(a, b)
        if a.newest ~= b.newest then return a.newest > b.newest end
        return a.name < b.name
    end)
    return out
end

function KOS:ReasonText(e)
    if not e then return "" end
    if e.rc and e.rc > 0 then return self.PRESETS[e.rc] or "" end
    return e.reason or ""
end

---------------------------------------------------------------------------
-- Sending (own entries only)
---------------------------------------------------------------------------
local function Send(e)
    if e.adder ~= Me() then return end -- never relay
    Comm:Send("KS", e.target, e.class or "", e.level or "", e.guild or "", e.rc or 0, e.reason or "",
        e.t, e.deleted and 1 or 0, e.updated, KOS:Added(e))
end

local lastAnnounce, announcePending = -ANNOUNCE_GAP, false
local function AnnounceOwn()
    announcePending = false
    if not Comm:IsSharing("kos") then return end
    lastAnnounce = GetTime()
    local me, now = Me(), Now()
    for _, e in pairs(Bucket() or {}) do
        if e.adder == me and (KOS:IsActive(e, now) or (e.updated or 0) > now - EXPIRE) then Send(e) end
    end
end

local function ScheduleAnnounce(delay)
    if announcePending then return end
    announcePending = true
    C_Timer.After(math.max(delay, ANNOUNCE_GAP - (GetTime() - lastAnnounce)), AnnounceOwn)
end

---------------------------------------------------------------------------
-- Own actions
---------------------------------------------------------------------------
local function CleanTarget(name)
    if type(name) ~= "string" then return nil end
    return ns:ValidName(ns:CleanText(name, 48))
end

-- info = { class, level, guild } (from the unit or my enemy book). rc = preset or 0.
-- Returns true, or false + a reason to show.
function KOS:Add(target, info, rc, reason)
    local b = Bucket()
    if not b then return false, "You're not in a guild." end
    target = CleanTarget(target)
    if not target then return false, "That name can't be used." end
    if target == Me() then return false, "You can't put yourself on Kill on Sight." end
    if Comm:IsMember(target) then return false, "That's a guild member." end
    local id = Id(Me(), target)
    local old = b[id]
    if not self:IsActive(old) and ActiveCount(Me(), id) >= MAX_PER_PLAYER then
        return false, ("You have %d players on Kill on Sight already (the most). Remove one first."):format(MAX_PER_PLAYER)
    end
    info = info or (ns.Enemies and ns.Enemies:Get(target)) or {}
    rc = ns:Int(rc, 0, #self.PRESETS) or 0
    reason = rc == 0 and ns:CleanText(reason, MAX_REASON) or ""
    local now = Now()
    local e = {
        target = target, adder = Me(), class = ns:ValidClass(info.class), level = ns:Int(info.level, -1, 60),
        guild = info.guild and ns:CleanText(info.guild, 48) or nil, rc = rc, reason = reason ~= "" and reason or nil,
        t = now, added = self:IsActive(old) and self:Added(old) or now,
        updated = math.max(now, old and (old.updated or 0) + 1 or 0),
    }
    if e.guild == "" then e.guild = nil end
    b[id] = e
    Changed()
    Send(e)
    return true
end

function KOS:Remove(target)
    local e = self:Mine(target)
    if not e then return false end
    e.deleted = true
    e.updated = math.max(Now(), (e.updated or 0) + 1)
    Changed()
    Send(e)
    return true
end

function KOS:Renew(target)
    local e = self:Mine(target)
    if not e then return false end
    local now = Now()
    e.t = now
    e.updated = math.max(now, (e.updated or 0) + 1)
    Changed()
    Send(e)
    return true
end

---------------------------------------------------------------------------
-- Receiving (sender = adder, set by the server)
---------------------------------------------------------------------------
local function Reject() KOS.rejected = KOS.rejected + 1 end

local function Trim(b)
    local n = 0
    for _ in pairs(b) do n = n + 1 end
    while n > MAX_STORED do
        local oldest, oldestId
        for id, e in pairs(b) do
            if e.adder ~= Me() and (not oldest or (e.updated or 0) < oldest) then oldest, oldestId = e.updated or 0, id end
        end
        if not oldestId then break end
        b[oldestId] = nil
        n = n - 1
    end
end

-- Returns true if stored. Also used by the security test.
function KOS:Merge(sender, target, class, level, guild, rc, reason, t, deleted, updated, added)
    local b = Bucket()
    if not b then return false end
    sender = ns:ValidName(sender)
    target = CleanTarget(target)
    local now = Now()
    t = ns:Int(t, now - EXPIRE - FUTURE_SLACK, now + FUTURE_SLACK)
    updated = ns:Int(updated, 1, now + FUTURE_SLACK)
    rc = ns:Int(rc, 0, #self.PRESETS)
    if not (sender and target and t and updated and rc) then Reject() return false end
    added = ns:Int(added, 1, t) or t -- never after the last renewal
    if target == sender or Comm:IsMember(target) then Reject() return false end
    if level ~= nil and level ~= "" then
        level = ns:Int(level, -1, 60)
        if not level then Reject() return false end
    else
        level = nil
    end
    if class ~= nil and class ~= "" and not ns:ValidClass(class) then Reject() return false end
    local id = Id(sender, target)
    local old = b[id]
    if old and (old.updated or 0) >= updated then return false end
    local isDeleted = deleted == 1 or deleted == "1" or deleted == true
    if not isDeleted and t + EXPIRE > now and ActiveCount(sender, id) >= MAX_PER_PLAYER then Reject() return false end
    reason = rc == 0 and ns:CleanText(reason, MAX_REASON) or ""
    guild = ns:CleanText(guild, 48)
    b[id] = {
        target = target, adder = sender, class = ns:ValidClass(class), level = level,
        guild = guild ~= "" and guild or nil, rc = rc, reason = reason ~= "" and reason or nil,
        t = t, added = added, updated = updated, deleted = isDeleted or nil,
    }
    Trim(b)
    Changed()
    ns:Fire("KOS_RECEIVED", b[id], not old or old.deleted or KOS:Added(old) ~= added)
    return true
end

Comm:RegisterHandler("KS", function(sender, ...)
    KOS:Merge(sender, ...)
end, "kos")

---------------------------------------------------------------------------
-- Upkeep
---------------------------------------------------------------------------
-- Drop expired entries and removals older than the expiry (others' only; mine are
-- dropped the same way once they no longer need announcing).
function KOS:Purge()
    local b = Bucket()
    if not b then return end
    local now, changed = Now(), false
    for id, e in pairs(b) do
        if (e.t or 0) + EXPIRE < now - 86400 and (e.updated or 0) < now - EXPIRE then
            b[id] = nil
            changed = true
        end
    end
    if changed then Changed() end
end

ns:RegisterCallback("VALIDATE_DB", function()
    for key, b in pairs(ns.db.kos) do
        if type(b) ~= "table" then
            ns.db.kos[key] = nil
        else
            for id, e in pairs(b) do
                local ok = type(e) == "table" and ns:ValidName(e.target) and ns:ValidName(e.adder)
                    and id == Id(e.adder, e.target) and ns:Int(e.t, 1) and ns:Int(e.updated, 1)
                    and ns:Int(e.rc or 0, 0, #KOS.PRESETS)
                if not ok then
                    b[id] = nil
                else
                    e.class = ns:ValidClass(e.class)
                    e.level = ns:Int(e.level, -1, 60)
                    e.rc = e.rc or 0
                    e.added = ns:Int(e.added, 1, e.t) or e.t
                    for _, k in ipairs({ "guild", "reason" }) do
                        local s = type(e[k]) == "string" and ns:CleanText(e[k], k == "guild" and 48 or MAX_REASON) or ""
                        e[k] = s ~= "" and s or nil
                    end
                    e.deleted = e.deleted == true or nil
                end
            end
        end
    end
end)

ns:RegisterCallback("HELLO", function(_, _, flag)
    if flag == "Q" then ScheduleAnnounce(4 + math.random() * 8) end
end)
ns:RegisterCallback("SYNC_REQUESTED", function() lastAnnounce = -ANNOUNCE_GAP ScheduleAnnounce(2) end)
ns:RegisterCallback("SHARING_CHANGED", function(_, field, value)
    if field == "optIn" or field == "kos" then
        Changed()
        if value then ScheduleAnnounce(5) end
    end
end)
ns:RegisterCallback("GUILD_CHANGED", function() cache = nil KOS:Purge() ns:Fire("KOS_CHANGED") end)
ns:RegisterCallback("ROSTER_CHANGED", Changed)

local started = false
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if started then return end
    started = true
    C_Timer.After(LOGIN_DELAY, function()
        if not IsInGuild() then return end
        KOS:Purge()
        ScheduleAnnounce(0)
    end)
end)

---------------------------------------------------------------------------
-- Adding from the UI: menus, dialog, /tavern kos, key binding
---------------------------------------------------------------------------
local function Report(ok, err, target, what)
    if ok then
        local note = Comm:IsSharing("kos") and "" or " |cff999999(sharing is off: only you see it)|r"
        ns:Print(what:format(target) .. note)
    elseif err then
        ns:Print(err)
    end
end

function KOS:QuickAdd(target, info)
    local ok, err = self:Add(target, info, 0, nil)
    Report(ok, err, target, "Added %s to the guild Kill on Sight list.")
end

function KOS:AddPreset(target, info, rc)
    local ok, err = self:Add(target, info, rc, nil)
    Report(ok, err, target, "Added %s to the guild Kill on Sight list (" .. (self.PRESETS[rc] or "") .. ").")
end

function KOS:AskReason(target, info)
    ns.Dialog:Show({
        text = ("Put %s on the guild Kill on Sight list.\n\nReason (up to %d letters):"):format(target, MAX_REASON),
        accept = "Add",
        edit = { maxLetters = MAX_REASON, width = 260, default = "" },
        onAccept = function(text)
            local ok, err = self:Add(target, info, 0, text)
            Report(ok, err, target, "Added %s to the guild Kill on Sight list.")
        end,
    })
end

function KOS:ConfirmRemove(target)
    ns.Dialog:Show({
        text = ("Take %s off your Kill on Sight entries?"):format(target),
        accept = "Remove",
        onAccept = function()
            if self:Remove(target) then ns:Print(("Removed your Kill on Sight entry for %s."):format(target)) end
        end,
    })
end

-- Adds the Kill on Sight options to a menu (MenuUtil / Menu.ModifyMenu root).
function KOS:FillMenu(root, target, info)
    if not ns:GuildKey() or Comm:IsMember(target) then return end
    if self:Mine(target) then
        root:CreateButton("Kill on Sight: renew (30 more days)", function()
            if self:Renew(target) then ns:Print(("Renewed your Kill on Sight entry for %s."):format(target)) end
        end)
        root:CreateButton("Kill on Sight: remove mine", function() self:ConfirmRemove(target) end)
        if self.FillModMenu then self.FillModMenu(root, target) end
        return
    end
    root:CreateButton("Kill on Sight: quick add", function() self:QuickAdd(target, info) end)
    local sub = root:CreateButton("Kill on Sight: add with reason")
    for i, preset in ipairs(self.PRESETS) do
        sub:CreateButton(preset, function() self:AddPreset(target, info, i) end)
    end
    sub:CreateButton("Your own reason...", function() self:AskReason(target, info) end)
    if self.FillModMenu then self.FillModMenu(root, target) end
end

-- One value from a game function, or nil when it errors or is "secret".
local function Read(index, fn, ...)
    local r = { pcall(fn, ...) }
    if not r[1] then return nil end
    local v = r[index + 1]
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

-- Name and descriptive info of an enemy player unit, or nil.
local function UnitTarget(unit)
    if Read(1, UnitIsPlayer, unit) ~= true or Read(1, UnitCanAttack, "player", unit) ~= true then return nil end
    local name = Read(1, GetUnitName, unit, true)
    if type(name) ~= "string" then return nil end
    local guild = Read(1, GetGuildInfo, unit)
    return CleanTarget(name), {
        class = Read(2, UnitClass, unit), level = Read(1, UnitLevel, unit),
        guild = type(guild) == "string" and guild or nil,
    }
end

-- Right-click menu of enemy players (target frame, focus frame...). Right-clicking a
-- nameplate opens no menu on Forever.
if Menu and Menu.ModifyMenu then
    pcall(Menu.ModifyMenu, "MENU_UNIT_ENEMY_PLAYER", function(_, root, context)
        local unit = type(context) == "table" and context.unit
        if not unit then return end
        local target, info = UnitTarget(unit)
        if not target or not ns:GuildKey() then return end
        root:CreateDivider()
        root:CreateTitle(ns.title)
        KOS:FillMenu(root, target, info)
    end)
end

-- /tavern kos [reason]: quick add your target (with a reason, if given).
ns:RegisterCommand("kos", function(arg)
    local target, info = UnitTarget("target")
    if not target then ns:Print("Target an enemy player first, then /tavern kos [reason].") return end
    arg = strtrim(arg or "")
    if arg ~= "" then
        local ok, err = KOS:Add(target, info, 0, arg)
        Report(ok, err, target, "Added %s to the guild Kill on Sight list.")
    elseif KOS:Mine(target) then
        ns:Print(("%s is already on your Kill on Sight entries (right-click their portrait to renew or remove)."):format(target))
    else
        KOS:QuickAdd(target, info)
    end
end, "put your target on the guild Kill on Sight list: /tavern kos [reason]")

BINDING_NAME_UNCSTAVERN_KOS = "Kill on Sight: add your target"

---------------------------------------------------------------------------
-- Settings > Sharing
---------------------------------------------------------------------------
ns.Settings:RegisterToggle({
    category = "sharing", order = 4.5, indent = 1,
    label = "Kill on Sight list",
    description = "The enemy players you put on Kill on Sight, with your reason. You see guildmates' entries only while this is on.",
    get = function() local s = Comm:Sharing() return s and s.kos ~= false end,
    set = function(v) Comm:SetSharing("kos", v) end,
    disabled = function() return not Comm:IsSharing() end,
})
