-- Modules\GuildLog.lua: the Guild log and the Officer log (History tab views).
--
-- GUILD LOG (everyone): wishlist deliveries and moderator actions.
--   Deliveries are worked out locally from data every client already has, so no new
--   message type exists for them (and nobody can post a "log entry" about anyone):
--     the helper's claim ("I'm sending N", sent only by the helper) and
--     the receiver's confirmation (who delivered how many, sent only by the receiver).
--   Status:  Confirmed    both sides agree
--            Unconfirmed  only one side (a confirmation without a claim, or a claim that
--                         lapsed / whose request closed with nothing confirmed)
--            Mismatch     less was confirmed than claimed, and the claim lapsed or the
--                         request closed (shown in red). More than claimed = Confirmed.
--   (A COD check is planned with the mailbox panel: COD mail is broken on the server.)
--   Moderator actions come from Moderation.lua after its rank check.
--
-- OFFICER LOG (ranks the leader allows to "See officer log"): moderator actions with
-- their reasons (they only ever arrive over OFFICER/WHISPER, and are only kept when our
-- own roster says we may see them) plus every Mismatch. A new mismatch is also printed
-- to officers once.
--
-- Both keep at most MAX_ENTRIES and drop entries older than the leader's "Keep guild
-- log entries" (Permissions.lua, default 30 days). Stored per guild:
--   ns.db.guildLog[guildKey][id], ns.db.officerLog[guildKey][id]
local _, ns = ...
local W, Perms, History = ns.Wishlist, ns.Perms, ns.History

local Log = {}
ns.GuildLog = Log

local MAX_ENTRIES = 200
local SCAN_DELAY  = 1.5

local GREEN  = { r = 0.25, g = 1, b = 0.25 }
local RED    = { r = 1, g = 0.25, b = 0.25 }
local ORANGE = { r = 1, g = 0.5, b = 0 }
local LIGHT  = { r = 0.75, g = 0.75, b = 0.75 }
local STATUS = { Confirmed = GREEN, Unconfirmed = LIGHT, Mismatch = RED }

local function Store(db)
    local key = ns:GuildKey()
    if not key then return nil end
    if type(db[key]) ~= "table" then db[key] = {} end
    return db[key]
end

local function Trim(t)
    local cutoff = W.Now() - Perms:LogDays() * 86400
    local list = {}
    for id, e in pairs(t) do
        if (e.t or 0) < cutoff then t[id] = nil else list[#list + 1] = { id = id, t = e.t } end
    end
    if #list > MAX_ENTRIES then
        table.sort(list, function(a, b) return a.t > b.t end)
        for i = MAX_ENTRIES + 1, #list do t[list[i].id] = nil end
    end
end

local function Changed()
    if History.Refresh then History.Refresh() end
end

---------------------------------------------------------------------------
-- Deliveries: claims vs. confirmations
---------------------------------------------------------------------------
local function Status(req, claim, got)
    local settled = not W:IsOpen(req) or (claim and not W:IsClaimActive(claim))
    if got > 0 and not claim then return "Unconfirmed" end
    if got == 0 then return settled and "Unconfirmed" or nil end -- still on its way
    -- More than claimed is fine (e.g. "Fill anyway" when others had claimed the rest, so
    -- the claim was capped): the requester got at least what was promised.
    if got >= claim.qty then return "Confirmed" end
    if settled then return "Mismatch" end
    return nil -- part delivered, rest still on its way
end

local scanPending = false
local function Scan()
    scanPending = false
    local log = Store(ns.db.guildLog)
    if not log then return end
    -- Claims per request: only the claimer's own, and not ones a moderator cleared.
    local claimsBy = {}
    for _, c in ipairs(W:AllClaims()) do
        if not c.modBy and not c.deleted then
            claimsBy[c.reqId] = claimsBy[c.reqId] or {}
            claimsBy[c.reqId][c.claimer] = c
        end
    end
    local changed = false
    local newMismatch
    for _, req in ipairs(W:All()) do
        local helpers = {}
        for who in pairs(req.receivedFrom or {}) do helpers[who] = true end
        for who in pairs(claimsBy[req.id] or {}) do helpers[who] = true end
        for helper in pairs(helpers) do
            if helper ~= req.requester then
                local claim = claimsBy[req.id] and claimsBy[req.id][helper]
                local got = (req.receivedFrom and req.receivedFrom[helper]) or 0
                local status = Status(req, claim, got)
                if status then
                    local id = "D:" .. req.id .. "#" .. helper
                    local e = log[id]
                    local claimed = claim and claim.qty or nil
                    if not e or e.status ~= status or e.got ~= got or e.claimed ~= claimed then
                        local t = math.max(got > 0 and req.updated or 0, claim and claim.updated or 0)
                        e = History.Describe(req)
                        e.kind, e.t, e.requester, e.helper = "deliver", t, req.requester, helper
                        e.claimed, e.got, e.status = claimed, got, status
                        if status == "Mismatch" and (not log[id] or log[id].status ~= "Mismatch") then newMismatch = e end
                        log[id] = e
                        changed = true
                    end
                end
            end
        end
    end
    if changed then
        Trim(log)
        Changed()
    end
    if newMismatch and Perms:ICan("log") then
        ns:Print(("|cffff4040Officer log:|r mismatch - %s confirmed %d from %s, who claimed %s."):format(
            newMismatch.requester, newMismatch.got, newMismatch.helper, tostring(newMismatch.claimed or 0)))
    end
end

local function ScheduleScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_DELAY, Scan)
end
ns:RegisterCallback("WISHLIST_CHANGED", ScheduleScan)
ns:RegisterCallback("GUILD_CHANGED", ScheduleScan)
ns:RegisterCallback("PERMS_CHANGED", Changed)

function Log:ScanNow() Scan() end -- /tavern securitytest

---------------------------------------------------------------------------
-- Moderator actions (public part) and officer notes
---------------------------------------------------------------------------
ns:RegisterCallback("MODERATION", function(_, m)
    local log = Store(ns.db.guildLog)
    if not log or log[m.id] then return end -- re-announcements are the same entry
    log[m.id] = { kind = m.kind == "D" and "moddel" or "modclear", t = m.t, actor = m.actor,
                  requester = m.requester, claimer = m.claimer, itemID = m.itemID, rule = m.rule, armor = m.armor }
    Trim(log)
    Changed()
end)

ns:RegisterCallback("OFFICER_NOTE", function(_, m)
    if not Perms:ICan("log") then return end
    local log = Store(ns.db.officerLog)
    if not log or log[m.id] then return end -- the same note can arrive on OFFICER and by whisper
    log[m.id] = { kind = m.kind, t = m.t, actor = m.actor, requester = m.requester, claimer = m.claimer,
                  reason = m.reason }
    Trim(log)
    Changed()
end)

-- Test hooks (/tavern securitytest)
function Log:Get(id) local log = Store(ns.db.guildLog) return log and log[id] end
function Log:GetOfficer(id) local log = Store(ns.db.officerLog) return log and log[id] end

---------------------------------------------------------------------------
-- Saved data: drop anything malformed
---------------------------------------------------------------------------
local KINDS = { deliver = true, moddel = true, modclear = true }
ns:RegisterCallback("VALIDATE_DB", function()
    for key, log in pairs(ns.db.guildLog) do
        if type(log) ~= "table" then
            ns.db.guildLog[key] = nil
        else
            for id, e in pairs(log) do
                local ok = type(e) == "table" and KINDS[e.kind] and ns:Int(e.t, 1) and ns:ValidName(e.requester)
                if ok and e.kind == "deliver" then
                    ok = ns:ValidName(e.helper) and STATUS[e.status] and ns:Int(e.got, 0) ~= nil
                elseif ok then
                    ok = ns:ValidName(e.actor) ~= nil
                end
                if not ok then log[id] = nil elseif e.rule then e.rule = ns:CleanText(e.rule, 80) end
            end
        end
    end
    for key, log in pairs(ns.db.officerLog) do
        if type(log) ~= "table" then
            ns.db.officerLog[key] = nil
        else
            for id, e in pairs(log) do
                if type(e) ~= "table" or (e.kind ~= "D" and e.kind ~= "C") or not ns:Int(e.t, 1)
                    or not ns:ValidName(e.actor) or not ns:ValidName(e.requester) then
                    log[id] = nil
                else
                    e.reason = ns:CleanText(e.reason, 60)
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Views
---------------------------------------------------------------------------
local function Sorted(t)
    local out = {}
    for _, e in pairs(t or {}) do out[#out + 1] = e end
    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return out
end

local guildList, officerList

-- A moderator action on a request this client never saw has no item: no lookups then.
local function Icon(e)
    if not e.itemID and not e.rule then return "Interface\\Icons\\INV_Misc_QuestionMark" end
    return History.EntryIcon(e)
end
local function Name(e)
    if not e.itemID and not e.rule then return "(a request)", LIGHT end
    return History.EntryName(e)
end

local function QtyText(e)
    if e.kind ~= "deliver" then return "" end
    if e.claimed then return ("%d of %d"):format(e.got, e.claimed) end
    return "x" .. e.got
end

local function StatusText(e)
    if e.kind == "moddel" then return "Removed by moderator", ORANGE end
    if e.kind == "modclear" then return ("Cleared %s's claim"):format(e.claimer or "?"), ORANGE end
    return e.status, STATUS[e.status]
end

History:RegisterView({
    key = "guild", label = "Guild log", order = 20,
    intro = function()
        return ("Deliveries and moderator actions in this guild, last %d days. Everyone with the addon sees the same kind of list.")
            :format(Perms:LogDays())
    end,
    build = function(frame)
        guildList = History.MakeList(frame, "Guild log", {
            { label = "Item", width = 100, flex = 1, icon = Icon,
              get = function(e) return Name(e) end },
            { label = "Qty", width = 50, fit = true, get = QtyText },
            { label = "Requester", width = 60, fit = true, get = function(e) return e.requester end },
            { label = "By", width = 40, fit = true, get = function(e) return e.helper or e.actor or "?" end },
            { label = "Status", width = 60, fit = true, get = StatusText },
            { label = "When", width = 60, fit = true, get = function(e) return History.When(e.t), History.GREY end },
        })
        guildList.frame:SetAllPoints(frame)
    end,
    refresh = function()
        guildList:SetEntries(Sorted(Store(ns.db.guildLog)), "Nothing logged yet.")
    end,
})

History:RegisterView({
    key = "officer", label = "Officer log", order = 30,
    shown = function() return Perms:ICan("log") end,
    intro = "Officer only: moderator actions with reasons, and every mismatch.",
    build = function(frame)
        officerList = History.MakeList(frame, "Officer log", {
            { label = "Action", width = 60, fit = true, get = function(e)
                if e.kind == "D" then return "Removed request", ORANGE end
                if e.kind == "C" then return "Cleared claim", ORANGE end
                return "Mismatch", RED
            end },
            { label = "By", width = 40, fit = true, get = function(e) return e.actor or e.helper or "?" end },
            { label = "Player", width = 50, fit = true, get = function(e)
                if e.kind == "C" then return ("%s (on %s's request)"):format(e.claimer or "?", e.requester) end
                return e.requester
            end },
            { label = "Details", width = 120, flex = 1, get = function(e)
                if e.kind == "deliver" then
                    return ("%s: claimed %s, confirmed %d"):format(Name(e), tostring(e.claimed or 0), e.got)
                end
                return e.reason ~= "" and e.reason or "(no reason given)", LIGHT
            end },
            { label = "When", width = 60, fit = true, get = function(e) return History.When(e.t), History.GREY end },
        })
        officerList.frame:SetAllPoints(frame)
    end,
    refresh = function()
        local entries = Sorted(Store(ns.db.officerLog))
        for _, e in pairs(Store(ns.db.guildLog) or {}) do
            if e.kind == "deliver" and e.status == "Mismatch" then entries[#entries + 1] = e end
        end
        table.sort(entries, function(a, b) return (a.t or 0) > (b.t or 0) end)
        officerList:SetEntries(entries, "Nothing for officers yet.")
    end,
})
