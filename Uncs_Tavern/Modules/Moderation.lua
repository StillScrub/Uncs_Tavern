-- Modules\Moderation.lua: moderators (ranks the guild leader allows, Permissions.lua)
-- can delete any request and clear any claim. Every action shows in the public Guild
-- log; the optional reason goes to the officer log only.
--
-- Messages (protocol 2):
--   MD|requester|created|rand|t              GUILD   "I deleted this request"
--   MC|requester|created|rand|claimer|t      GUILD   "I cleared this claim"
--   OM|kind|requester|created|rand|claimer|t|reason   OFFICER + WHISPER only (category
--                                            "officer"): the details for the officer log
--
-- TRUST: the moderator is the sender (set by the server). Every client checks the
-- sender's rank against the leader's config FROM ITS OWN ROSTER before applying
-- anything; nothing in the message counts as a rank. Moderators only ever announce
-- their OWN actions (no relaying), and re-announce them for 14 days when a guildmate
-- logs in, so people who were offline catch up. When the owner of the request (or the
-- claimer) receives it, their own client marks it removed and announces that like any
-- edit of their own, so it stays removed.
local _, ns = ...
local W, Comm, Perms = ns.Wishlist, ns.Comm, ns.Perms

local Mod = {}
ns.Moderation = Mod

local KEEP_DAYS    = 14   -- own actions re-announced this long
local MAX_ACTIONS  = 200
local ANNOUNCE_GAP = 120
local FUTURE_SLACK = 3600
local MAX_REASON   = 60
local MOD_COLOR    = "|cffff8000"

Mod.rejected = 0 -- moderation messages refused (for /tavern securitytest)

local Now = W.Now

local function ReqId(requester, created, rand)
    return ("%s:%d:%d"):format(requester, created, rand)
end

local function Actions()
    local key = ns:GuildKey()
    if not key then return nil end
    if type(ns.db.modActions[key]) ~= "table" then ns.db.modActions[key] = {} end
    return ns.db.modActions[key]
end

-- What the request asks for, as text (for the log and messages to the owner).
local function What(req)
    if not req then return "a request" end
    if req.rule then return W:RuleText(req.rule) end
    return C_Item.GetItemInfo(req.itemID) or ("item " .. req.itemID)
end

local function FindClaim(reqId, claimer)
    for _, c in ipairs(W:AllClaims()) do
        if c.reqId == reqId and c.claimer == claimer then return c end
    end
end

---------------------------------------------------------------------------
-- Applying an action (from anyone, after the rank check)
---------------------------------------------------------------------------
-- Returns true if the action was valid (a moderator, sane fields), even if there was
-- nothing left to change.
local function Apply(moderator, kind, requester, created, rand, claimer, t)
    requester = ns:ValidName(requester)
    created, rand = ns:Int(created, 1), ns:Int(rand, 0, 99999)
    t = ns:Int(t, Now() - KEEP_DAYS * 86400 - FUTURE_SLACK, Now() + FUTURE_SLACK)
    if not (requester and created and rand and t) then Mod.rejected = Mod.rejected + 1 return false end
    if kind == "C" then
        claimer = ns:ValidName(claimer)
        if not claimer then Mod.rejected = Mod.rejected + 1 return false end
    end
    -- The rank comes from OUR roster, never from the message.
    if not Perms:Can(moderator, "mod") then Mod.rejected = Mod.rejected + 1 return false end

    local reqId = ReqId(requester, created, rand)
    local req = W:Get(reqId)
    local me = ns:PlayerName()
    if kind == "D" then
        if req and not req.deleted then
            req.deleted = true
            req.modBy = moderator
            req.updated = math.max(t, (req.updated or 0) + 1)
            -- The owner's own client announces the removal like any edit of their own.
            local mine = W:IsMine(req)
            ns:Fire("WISHLIST_CHANGED", req, mine and "local" or "remote")
            if mine and moderator ~= me then
                ns:Print(("%sModerator|r %s removed your request for %s."):format(MOD_COLOR, moderator, What(req)))
            end
        end
    else
        local c = FindClaim(reqId, claimer)
        if c and not c.deleted then
            c.deleted = true
            c.modBy = moderator
            c.updated = math.max(t, (c.updated or 0) + 1)
            local mine = claimer == me
            local source = mine and "local" or "remote"
            ns:Fire("CLAIM_CHANGED", c, source)
            ns:Fire("WISHLIST_CHANGED", nil, source)
            if mine and moderator ~= me then
                ns:Print(("%sModerator|r %s cleared your claim on %s's request for %s."):format(
                    MOD_COLOR, moderator, requester, What(req)))
            end
        end
    end
    ns:Fire("MODERATION", {
        id = "M:" .. kind .. ":" .. reqId .. (kind == "C" and ("#" .. claimer) or ""),
        kind = kind, actor = moderator, requester = requester, claimer = claimer, t = t,
        itemID = req and req.itemID, rule = req and req.rule and W:RuleText(req.rule),
        armor = req and req.rule and req.rule.armor,
    })
    return true
end

Comm:RegisterHandler("MD", function(sender, requester, created, rand, t)
    Apply(sender, "D", requester, created, rand, nil, t)
end, "wishlist")

Comm:RegisterHandler("MC", function(sender, requester, created, rand, claimer, t)
    Apply(sender, "C", requester, created, rand, claimer, t)
end, "wishlist")

-- Officer details. Comm only lets this in over OFFICER or WHISPER, from guild members.
Comm:RegisterHandler("OM", function(sender, kind, requester, created, rand, claimer, t, reason)
    if kind ~= "D" and kind ~= "C" then Mod.rejected = Mod.rejected + 1 return end
    if not Perms:Can(sender, "mod") or not Perms:ICan("log") then Mod.rejected = Mod.rejected + 1 return end
    requester = ns:ValidName(requester)
    created, rand = ns:Int(created, 1), ns:Int(rand, 0, 99999)
    t = ns:Int(t, Now() - KEEP_DAYS * 86400 - FUTURE_SLACK, Now() + FUTURE_SLACK)
    claimer = kind == "C" and ns:ValidName(claimer) or nil
    if not (requester and created and rand and t) or (kind == "C" and not claimer) then
        Mod.rejected = Mod.rejected + 1
        return
    end
    local reqId = ReqId(requester, created, rand)
    ns:Fire("OFFICER_NOTE", {
        id = "O:" .. kind .. ":" .. reqId .. (claimer and ("#" .. claimer) or ""),
        kind = kind, actor = sender, requester = requester, claimer = claimer, t = t,
        reason = ns:CleanText(reason, MAX_REASON),
    })
end, "officer")

---------------------------------------------------------------------------
-- My own actions: do, remember, announce
---------------------------------------------------------------------------
-- Members who may read the officer log, online, with the addon (whisper targets).
local function OfficerTargets()
    local out = {}
    for _, m in ipairs(Comm:OnlineMembers()) do
        if Perms:RankCan(m.rankIndex, "log") and Comm:HasAddon(m.name) then out[#out + 1] = m.full end
    end
    return out
end

local function SendAction(a)
    if a.kind == "D" then
        Comm:Send("MD", a.requester, a.created, a.rand, a.t)
    else
        Comm:Send("MC", a.requester, a.created, a.rand, a.claimer, a.t)
    end
end

local function Do(kind, req, claimer, reason)
    if not Perms:ICan("mod") then ns:Print("Only ranks the guild leader allows can moderate.") return end
    local actions = Actions()
    if not actions then return end
    local created, rand = req.id:match(":(%d+):(%d+)$")
    created, rand = tonumber(created), tonumber(rand)
    local t = Now()
    local me = ns:PlayerName()
    if not Apply(me, kind, req.requester, created, rand, claimer, t) then return end
    local a = { kind = kind, requester = req.requester, created = created, rand = rand, claimer = claimer, t = t }
    actions[kind .. ":" .. req.id .. (claimer and ("#" .. claimer) or "")] = a
    SendAction(a)
    reason = ns:CleanText(reason, MAX_REASON)
    Comm:SendOfficer("OM", OfficerTargets(), kind, req.requester, created, rand, claimer or "", t, reason)
    -- My own officer log gets the details too.
    if Perms:ICan("log") then
        ns:Fire("OFFICER_NOTE", {
            id = "O:" .. kind .. ":" .. req.id .. (claimer and ("#" .. claimer) or ""),
            kind = kind, actor = me, requester = req.requester, claimer = claimer, t = t, reason = reason,
        })
    end
    ns:Print(kind == "D" and ("Removed %s's request (logged in the Guild log)."):format(req.requester)
        or ("Cleared %s's claim (logged in the Guild log)."):format(claimer))
end

local lastAnnounce, announcePending = -ANNOUNCE_GAP, false
local function AnnounceOwn()
    announcePending = false
    local actions = Actions()
    if not actions or not Perms:ICan("mod") then return end
    lastAnnounce = GetTime()
    local cutoff = Now() - KEEP_DAYS * 86400
    for id, a in pairs(actions) do
        if (a.t or 0) < cutoff then actions[id] = nil else SendAction(a) end
    end
end

local function ScheduleAnnounce(delay)
    if announcePending then return end
    announcePending = true
    C_Timer.After(math.max(delay, ANNOUNCE_GAP - (GetTime() - lastAnnounce)), AnnounceOwn)
end

ns:RegisterCallback("HELLO", function(_, _, flag)
    if flag == "Q" then ScheduleAnnounce(4 + math.random() * 8) end
end)
ns:RegisterCallback("SYNC_REQUESTED", function() lastAnnounce = -ANNOUNCE_GAP ScheduleAnnounce(3) end)

ns:RegisterCallback("VALIDATE_DB", function()
    for key, list in pairs(ns.db.modActions) do
        if type(list) ~= "table" then
            ns.db.modActions[key] = nil
        else
            local n = 0
            for id, a in pairs(list) do
                n = n + 1
                if type(a) ~= "table" or (a.kind ~= "D" and a.kind ~= "C") or not ns:ValidName(a.requester)
                    or not ns:Int(a.created, 1) or not ns:Int(a.rand, 0, 99999) or not ns:Int(a.t, 1)
                    or (a.kind == "C" and not ns:ValidName(a.claimer)) or n > MAX_ACTIONS then
                    list[id] = nil
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Wishlist: right-click menu and tooltip line for moderators
---------------------------------------------------------------------------
local function Confirm(kind, req, claimer)
    local text
    if kind == "D" then
        text = ("%sModerator:|r remove %s's request for %s?"):format(MOD_COLOR, req.requester, What(req))
    else
        text = ("%sModerator:|r clear %s's claim on %s's request for %s?"):format(MOD_COLOR, claimer, req.requester, What(req))
    end
    ns.Dialog:Show({
        text = text .. "\nEveryone sees this in the Guild log.\n\nReason (optional, officer log only):",
        accept = kind == "D" and "Remove" or "Clear",
        edit = { maxLetters = MAX_REASON, width = 260, default = "" },
        onAccept = function(reason)
            local cur = W:Get(req.id)
            if not cur or cur.deleted then ns:Print("That request is already gone.") return end
            Do(kind, cur, claimer, reason)
        end,
    })
end

ns:RegisterCallback("WISHLIST_ROW_MENU", function(_, row, req)
    if not Perms:ICan("mod") or not req then return end
    local claims = {}
    for _, c in ipairs(W:ClaimsFor(req.id)) do
        if c.claimer ~= ns:PlayerName() then claims[#claims + 1] = c end
    end
    local canDelete = not W:IsMine(req)
    if not canDelete and #claims == 0 then return end
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(row, function(_, root)
            root:CreateTitle(MOD_COLOR .. "Moderator|r")
            if canDelete then
                root:CreateButton(("Remove %s's request"):format(req.requester), function() Confirm("D", req) end)
            end
            for _, c in ipairs(claims) do
                root:CreateButton(("Clear %s's claim (%d)"):format(c.claimer, c.qty), function() Confirm("C", req, c.claimer) end)
            end
        end)
    elseif canDelete then
        Confirm("D", req) -- no menu on this client: offer the removal directly
    end
end)

ns:RegisterCallback("WISHLIST_ROW_TOOLTIP", function(_, tip, req)
    if not Perms:ICan("mod") or W:IsMine(req) and #W:ClaimsFor(req.id) == 0 then return end
    tip:AddLine(MOD_COLOR .. "Right-click: moderator actions|r")
end)
