-- Modules\WishlistData.lua: wishlist storage and rules (no UI).
-- Used by the Wishlist tab now, and later by sync, mail and alerts.
--
-- Stored per guild in ns.db.wishlist[guildKey].requests[id]:
--   id        "<requester>:<created>:<rand>"  (unique across the guild)
--   requester full two-part name, e.g. "Hexual Defect"
--   class     class file name of the requester (for coloring), e.g. "SHAMAN"
--   itemID    number (item requests), or nil for a rule request
--   rule      rule requests only: { armor, slot, minLevel, stat, minStat }
--             armor = 1 Cloth | 2 Leather | 3 Mail | 4 Plate (armor subclass IDs)
--             slot = "" (any) or an equip slot like "INVTYPE_HEAD"
--             minLevel = lowest required level; stat = "INT" | "STR" | ... ; minStat >= 1
--             optional second stat: stat2, minStat2 (the item needs both)
--   qty       how many wanted in total
--   received  how many have arrived so far
--   receivedFrom  { [senderName] = n } who sent them (so their claims count as delivered)
--   price     copper per item the requester will pay; 0 = gift
--   note      short free text
--   created / updated   GetServerTime() stamps (same clock for everyone); sync merges by `updated`
--   deleted   true = removed (kept as a tombstone so sync can spread the removal)
--
-- Fires ns callback "WISHLIST_CHANGED" after any change.
--
-- Data-safety rules (sync must keep these; see "Security rules" in CLAUDE.md):
--   * Every request has its own unique id, so two requests can never overwrite each other.
--   * Only the owner sends their requests (no relaying): Merge() takes the server-set
--     sender and accepts a request only when sender == requester. Same for claims:
--     sender == claimer. Every field is validated; notes and names are cleaned.
--   * Caps: MAX_OPEN_OWN open requests per player, MAX_STORED requests and MAX_CLAIMS
--     claims per guild. Other players' requests expire after settings.requestExpiryDays
--     without hearing from their owner (bucket.seen[owner]).
--   * Removing is a tombstone (deleted = true), never a hard delete, so a stale copy
--     arriving later can't bring a removed request back.
--   * A request leaves the list only when the requester removes it, or when received
--     reaches qty (fulfilled).
--   * Claims ("I'm sending N") live in a separate table, one per claimer per request.
--     Only the claimer changes their own claim; a claim can never touch the request.
local _, ns = ...

local Wishlist = {}
ns.Wishlist = Wishlist

Wishlist.MAX_QTY        = 1000
Wishlist.MAX_PRICE      = 9999 * 10000 -- 9999 gold
Wishlist.MAX_NOTE       = 60
Wishlist.MAX_OPEN_OWN   = 25
Wishlist.MAX_STORED     = 2000 -- requests per guild, all players, incl. removed ones
Wishlist.MAX_CLAIMS     = 2000
Wishlist.TOMBSTONE_DAYS = 30 -- removed requests are forgotten after this

local function Now()
    return GetServerTime and GetServerTime() or time()
end
Wishlist.Now = Now

-- Per-guild bucket: { requests = {}, claims = {}, seen = { [owner] = serverTime last heard from } }
local function Bucket()
    local key = ns:GuildKey()
    if not key then return nil end
    ns.db.wishlist[key] = ns.db.wishlist[key] or { requests = {} }
    return ns.db.wishlist[key]
end
Wishlist.Bucket = Bucket

local function Store()
    local b = Bucket()
    return b and b.requests
end

-- source: "local" (this player changed it) or "remote" (arrived via sync)
local function Changed(req, source)
    ns:Fire("WISHLIST_CHANGED", req, source or "local")
end

function Wishlist:IsOpen(req)
    return req and not req.deleted and (req.received or 0) < req.qty
end

function Wishlist:IsMine(req)
    return req and req.requester == ns:PlayerName()
end

---------------------------------------------------------------------------
-- Rule requests: "any Cloth item, required level 26+, with 4+ Intellect".
---------------------------------------------------------------------------
local ARMOR_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Armor) or 4
Wishlist.ARMOR_TYPES = { 1, 2, 3, 4 } -- Cloth, Leather, Mail, Plate
local ARMOR_FALLBACK = { "Cloth", "Leather", "Mail", "Plate" }
-- "" = any slot. Robes count as chest.
Wishlist.SLOTS = { "", "INVTYPE_HEAD", "INVTYPE_SHOULDER", "INVTYPE_CLOAK", "INVTYPE_CHEST", "INVTYPE_WRIST",
    "INVTYPE_HAND", "INVTYPE_WAIST", "INVTYPE_LEGS", "INVTYPE_FEET" }
Wishlist.STATS = {
    { key = "STA", mod = "ITEM_MOD_STAMINA_SHORT",   fallback = "Stamina" },
    { key = "STR", mod = "ITEM_MOD_STRENGTH_SHORT",  fallback = "Strength" },
    { key = "AGI", mod = "ITEM_MOD_AGILITY_SHORT",   fallback = "Agility" },
    { key = "INT", mod = "ITEM_MOD_INTELLECT_SHORT", fallback = "Intellect" },
    { key = "SPI", mod = "ITEM_MOD_SPIRIT_SHORT",    fallback = "Spirit" },
}
local STAT_BY_KEY = {}
for _, s in ipairs(Wishlist.STATS) do STAT_BY_KEY[s.key] = s end
local SLOT_OK = {}
for _, s in ipairs(Wishlist.SLOTS) do SLOT_OK[s] = true end
Wishlist.MAX_LEVEL = 60
Wishlist.MAX_STAT  = 999

-- Localized names, straight from the game.
function Wishlist:ArmorName(armor)
    local f = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
    local name = f and f(ARMOR_CLASS, armor)
    return name or ARMOR_FALLBACK[armor] or "?"
end

function Wishlist:SlotName(slot)
    if not slot or slot == "" then return "Any slot" end
    return _G[slot] or slot:gsub("^INVTYPE_", "")
end

function Wishlist:StatName(key)
    local s = STAT_BY_KEY[key]
    return s and (_G[s.mod] or s.fallback) or "?"
end

-- "Cloth · Head · Lv 26+ · 4+ Intellect"
function Wishlist:RuleText(rule)
    local parts = { self:ArmorName(rule.armor) }
    if rule.slot ~= "" then parts[#parts + 1] = self:SlotName(rule.slot) end
    if rule.minLevel > 1 then parts[#parts + 1] = ("Lv %d+"):format(rule.minLevel) end
    local stats = ("%d+ %s"):format(rule.minStat, self:StatName(rule.stat))
    if rule.stat2 then stats = stats .. (" & %d+ %s"):format(rule.minStat2, self:StatName(rule.stat2)) end
    parts[#parts + 1] = stats
    return table.concat(parts, " · ")
end

-- Short name of any request (item name, or the rule text).
function Wishlist:Label(req)
    if req.rule then return self:RuleText(req.rule) end
    return C_Item.GetItemInfo(req.itemID) or ("item " .. tostring(req.itemID))
end

-- Validates a rule; returns a clean copy or nil + message.
function Wishlist:CleanRule(rule)
    if type(rule) ~= "table" then return nil, "Set up the rule first." end
    local armor = tonumber(rule.armor)
    local minLevel = tonumber(rule.minLevel) or 1
    local minStat = tonumber(rule.minStat)
    if not armor or armor < 1 or armor > 4 then return nil, "Pick an armor type." end
    if not SLOT_OK[rule.slot or ""] then return nil, "Unknown slot." end
    if minLevel < 1 or minLevel > self.MAX_LEVEL then return nil, "Required level must be 1 to " .. self.MAX_LEVEL .. "." end
    if not STAT_BY_KEY[rule.stat] then return nil, "Pick a stat." end
    if not minStat or minStat < 1 or minStat > self.MAX_STAT then return nil, "Enter the minimum stat (1 or more)." end
    local clean = { armor = math.floor(armor), slot = rule.slot or "", minLevel = math.floor(minLevel),
                    stat = rule.stat, minStat = math.floor(minStat) }
    if rule.stat2 and rule.stat2 ~= "" then
        local minStat2 = tonumber(rule.minStat2)
        if not STAT_BY_KEY[rule.stat2] then return nil, "Pick the second stat." end
        if rule.stat2 == rule.stat then return nil, "The second stat must be different from the first." end
        if not minStat2 or minStat2 < 1 or minStat2 > self.MAX_STAT then
            return nil, "Enter the minimum for the second stat (1 or more)."
        end
        clean.stat2, clean.minStat2 = rule.stat2, math.floor(minStat2)
    end
    return clean
end

-- "armor:slot:minLevel:stat:minStat[:stat2:minStat2]" (for sync)
function Wishlist:EncodeRule(rule)
    local text = ("%d:%s:%d:%s:%d"):format(rule.armor, rule.slot, rule.minLevel, rule.stat, rule.minStat)
    if rule.stat2 then text = text .. (":%s:%d"):format(rule.stat2, rule.minStat2) end
    return text
end

function Wishlist:DecodeRule(text)
    if type(text) ~= "string" then return nil end
    local armor, slot, minLevel, stat, minStat, rest = text:match("^(%d+):([%w_]*):(%d+):(%u+):(%d+)(.*)$")
    if not armor then return nil end
    local stat2, minStat2
    if rest ~= "" then
        stat2, minStat2 = rest:match("^:(%u+):(%d+)$")
        if not stat2 then return nil end
    end
    return self:CleanRule({ armor = armor, slot = slot, minLevel = minLevel, stat = stat, minStat = minStat,
                            stat2 = stat2, minStat2 = minStat2 })
end

local function ItemStats(link)
    local f = (C_Item and C_Item.GetItemStats) or GetItemStats
    if not f then return nil end
    local ok, stats = pcall(f, link)
    return ok and stats or nil
end

-- Does this item (a link, so random-enchant stats count) fit the rule?
-- Returns nil when the item's data isn't loaded yet.
function Wishlist:MatchesRule(rule, link)
    if not link then return false end
    local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(link)
    if classID ~= ARMOR_CLASS or subclassID ~= rule.armor then return false end
    if equipLoc == "INVTYPE_ROBE" then equipLoc = "INVTYPE_CHEST" end
    if rule.slot ~= "" and equipLoc ~= rule.slot then return false end
    local reqLevel = select(5, C_Item.GetItemInfo(link))
    if not reqLevel then return nil end
    if reqLevel < rule.minLevel then return false end
    local stats = ItemStats(link)
    if not stats then return false end
    local s = STAT_BY_KEY[rule.stat]
    if not s or (stats[s.mod] or 0) < rule.minStat then return false end
    if rule.stat2 then
        local s2 = STAT_BY_KEY[rule.stat2]
        if not s2 or (stats[s2.mod] or 0) < rule.minStat2 then return false end
    end
    return true
end

-- My open rule requests this item (link) fits, oldest first.
function Wishlist:MyRulesMatching(link)
    local out = {}
    for _, req in ipairs(self:List("mine")) do
        if req.rule and self:MatchesRule(req.rule, link) then out[#out + 1] = req end
    end
    table.sort(out, function(a, b) return a.created < b.created end)
    return out
end

-- "Gear" = weapons and armor (and all rule requests); everything else counts as "Mats".
function Wishlist:CategoryOf(req)
    if req.rule then return "gear" end
    return self:Category(req.itemID)
end

function Wishlist:Category(itemID)
    local classID = select(6, C_Item.GetItemInfoInstant(itemID))
    local weapon = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
    local armor  = Enum and Enum.ItemClass and Enum.ItemClass.Armor or 4
    return (classID == weapon or classID == armor) and "gear" or "mats"
end

-- Is this player still in the guild? (Until the roster has loaded, assume yes.)
-- Requests and claims of players who left or were kicked stay stored but are hidden
-- everywhere (list, tooltips, popups), so nobody sends items to someone outside the
-- guild. They come back if the player rejoins, and expire like any unseen request.
function Wishlist:InGuild(name)
    local Comm = ns.Comm
    if not Comm or not Comm:RosterReady() then return true end
    return name == ns:PlayerName() or Comm:IsMember(name)
end

-- Open requests, newest first. filter: "all" | "mats" | "gear" | "mine"
function Wishlist:List(filter)
    local out = {}
    local store = Store()
    if not store then return out end
    for _, req in pairs(store) do
        if self:IsOpen(req) and self:InGuild(req.requester) then
            local keep = filter == nil or filter == "all"
                or (filter == "mine" and self:IsMine(req))
                or (filter ~= "mine" and self:CategoryOf(req) == filter)
            if keep then out[#out + 1] = req end
        end
    end
    table.sort(out, function(a, b) return a.created > b.created end)
    return out
end

function Wishlist:CountOpenOwn()
    local n = 0
    for _, req in ipairs(self:List("mine")) do n = n + 1 end
    return n
end

-- Returns the new request, or nil + an error message for the player.
-- what = an itemID, or a rule table for a rule request.
function Wishlist:Add(what, qty, price, note)
    local store = Store()
    if not store then return nil, "You are not in a guild." end
    local itemID, rule
    if type(what) == "table" then
        local err
        rule, err = self:CleanRule(what)
        if not rule then return nil, err end
    else
        itemID = tonumber(what)
        if not itemID or not C_Item.GetItemInfoInstant(itemID) then return nil, "Pick an item first." end
    end
    qty, price = tonumber(qty), tonumber(price) or 0
    note = ns:CleanText(note, self.MAX_NOTE) -- no escape codes; "|" would also break the sync format
    if not qty or qty < 1 or qty > self.MAX_QTY then return nil, "Quantity must be 1 to " .. self.MAX_QTY .. "." end
    if price < 0 or price > self.MAX_PRICE then return nil, "Price is too high." end
    if #note > self.MAX_NOTE then note = note:sub(1, self.MAX_NOTE) end
    if self:CountOpenOwn() >= self.MAX_OPEN_OWN then
        return nil, "You already have " .. self.MAX_OPEN_OWN .. " open requests."
    end

    local now = Now()
    local me = ns:PlayerName()
    local req = {
        id = ("%s:%d:%d"):format(me, now, math.random(1000, 9999)),
        requester = me,
        class = ns:PlayerClass(),
        itemID = itemID and math.floor(itemID),
        rule = rule,
        qty = math.floor(qty),
        received = 0,
        price = math.floor(price),
        note = note,
        created = now,
        updated = now,
    }
    store[req.id] = req
    Changed(req)
    return req
end

function Wishlist:Remove(id)
    local store = Store()
    local req = store and store[id]
    if not req or not self:IsMine(req) then return false end
    req.deleted = true
    req.updated = math.max(Now(), (req.updated or 0) + 1) -- always newer than the copy others hold
    Changed(req)
    return true
end

-- Every stored request including tombstones (for sync).
function Wishlist:All()
    local out = {}
    local store = Store()
    if store then
        for _, req in pairs(store) do out[#out + 1] = req end
    end
    return out
end

-- A clean copy of a request (from a message or from saved data), or nil if anything
-- is invalid. Text is cleaned, numbers range-checked, rules re-validated.
local FUTURE_SLACK = 3600 -- clocks are the server's; allow an hour of skew
function Wishlist:Clean(rec)
    if type(rec) ~= "table" then return nil end
    local requester = ns:ValidName(rec.requester)
    if not requester or type(rec.id) ~= "string" then return nil end
    local idCreated, rand = rec.id:match("^.+:(%d+):(%d+)$")
    if not idCreated or rec.id ~= ("%s:%s:%s"):format(requester, idCreated, rand) then return nil end
    local rule
    if rec.rule ~= nil then
        rule = self:CleanRule(rec.rule)
        if not rule then return nil end
    end
    local itemID = (not rule) and ns:Int(rec.itemID, 1, 10000000) or nil
    if not rule and (not itemID or not C_Item.GetItemInfoInstant(itemID)) then return nil end
    local qty = ns:Int(rec.qty, 1, self.MAX_QTY)
    local price = ns:Int(rec.price, 0, self.MAX_PRICE)
    local updated = ns:Int(rec.updated, 1, Now() + FUTURE_SLACK)
    local created = ns:Int(rec.created, 1, Now() + FUTURE_SLACK)
    if not qty or not price or not updated or not created or created ~= tonumber(idCreated) then
        return nil
    end
    local from
    if type(rec.receivedFrom) == "table" then
        for who, n in pairs(rec.receivedFrom) do
            n = ns:Int(n, 1, self.MAX_QTY)
            if ns:ValidName(who) and who ~= requester and n then
                from = from or {}
                from[who] = n
            end
        end
    end
    return {
        id = rec.id, requester = requester, class = ns:ValidClass(rec.class),
        itemID = itemID, rule = rule, qty = qty, received = math.min(ns:Int(rec.received, 0) or 0, qty),
        price = price, note = ns:CleanText(rec.note, self.MAX_NOTE), receivedFrom = from,
        created = created, updated = updated, deleted = rec.deleted and true or nil,
        modBy = rec.deleted and ns:ValidName(rec.modBy) or nil, -- removed by a moderator (Moderation.lua)
    }
end

local function CountAll(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Note that we heard from a player (any accepted message): their requests stay fresh.
function Wishlist:SeenOwner(name)
    local b = Bucket()
    if not b or not ns:ValidName(name) then return end
    b.seen = b.seen or {}
    b.seen[name] = Now()
end

-- A request that arrived in a message from `sender` (set by the server).
-- Accepted only from its owner. Newer `updated` wins; on a tie a removal wins.
-- Returns true if the store changed.
function Wishlist:Merge(rec, sender)
    local store = Store()
    if not store or not sender then return false end
    rec = self:Clean(rec)
    if not rec or rec.requester ~= sender or self:IsMine(rec) then return false end
    if rec.deleted and rec.updated < Now() - self.TOMBSTONE_DAYS * 86400 then return false end

    local cur = store[rec.id]
    if cur then
        local newer = rec.updated > cur.updated or (rec.updated == cur.updated and rec.deleted and not cur.deleted)
        if not newer then return false end
    else
        if CountAll(store) >= self.MAX_STORED then return false end
        if self:IsOpen(rec) then
            local open = 0
            for _, r in pairs(store) do
                if r.requester == sender and self:IsOpen(r) then open = open + 1 end
            end
            if open >= self.MAX_OPEN_OWN then return false end
        end
    end
    store[rec.id] = rec
    Changed(rec, "remote")
    return true
end

---------------------------------------------------------------------------
-- Received items (only the requester changes these on their own requests)
---------------------------------------------------------------------------
local MAX_FROM = 8 -- senders remembered per request (keeps sync messages small)

-- "Name:5,Other Name:3" <-> { ["Name"] = 5, ... }
function Wishlist:EncodeFrom(from)
    if type(from) ~= "table" then return "" end
    -- Biggest senders first; capped so the sync message stays under 255 bytes.
    local list = {}
    for name, n in pairs(from) do list[#list + 1] = { name = name, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    local parts, len = {}, 0
    for _, e in ipairs(list) do
        local part = e.name .. ":" .. e.n
        if #parts >= MAX_FROM or len + #part > 70 then break end
        parts[#parts + 1] = part
        len = len + #part + 1
    end
    return table.concat(parts, ",")
end

function Wishlist:DecodeFrom(text)
    if type(text) ~= "string" or text == "" then return nil end
    local from, count = {}, 0
    for name, n in text:gmatch("([^,:]+):(%d+)") do
        count = count + 1
        if count > MAX_FROM then break end
        if ns:ValidName(name) then from[name] = math.min(tonumber(n), self.MAX_QTY) end
    end
    return next(from) and from or nil
end

local function Touch(req)
    req.updated = math.max(Now(), (req.updated or 0) + 1)
    Changed(req)
end

-- Items arrived (from the mailbox). Spreads `count` over my open requests for
-- this item, oldest first. Returns how many were counted.
function Wishlist:AddReceived(itemID, count, sender)
    local reqs = {}
    for _, req in ipairs(self:List("mine")) do
        if req.itemID == itemID then reqs[#reqs + 1] = req end
    end
    table.sort(reqs, function(a, b) return a.created < b.created end)
    local used = 0
    for _, req in ipairs(reqs) do
        local take = math.min(count - used, req.qty - (req.received or 0))
        if take > 0 then
            req.received = (req.received or 0) + take
            if sender and sender ~= "" then
                req.receivedFrom = req.receivedFrom or {}
                req.receivedFrom[sender] = (req.receivedFrom[sender] or 0) + take
            end
            used = used + take
            Touch(req)
            ns:Fire("WISHLIST_RECEIVED", req, take, sender)
        end
        if used >= count then break end
    end
    return used
end

-- An item arrived that fits my rule requests: count it toward the oldest ones.
function Wishlist:AddReceivedRule(link, count, sender)
    local used = 0
    for _, req in ipairs(self:MyRulesMatching(link)) do
        local take = math.min(count - used, req.qty - (req.received or 0))
        if take > 0 then
            req.received = (req.received or 0) + take
            if sender and sender ~= "" then
                req.receivedFrom = req.receivedFrom or {}
                req.receivedFrom[sender] = (req.receivedFrom[sender] or 0) + take
            end
            used = used + take
            Touch(req)
            ns:Fire("WISHLIST_RECEIVED", req, take, sender)
        end
        if used >= count then break end
    end
    return used
end

-- Manual correction by the requester ("Got" button).
function Wishlist:SetReceived(reqId, n)
    local req = self:Get(reqId)
    if not req or req.deleted or not self:IsMine(req) then return nil, "Not your request." end
    n = tonumber(n)
    if not n or n < 0 then return nil, "Enter a number." end
    req.received = math.min(math.floor(n), req.qty)
    Touch(req)
    return req
end

function Wishlist:WantsItem(itemID)
    for _, req in ipairs(self:List("mine")) do
        if req.itemID == itemID then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Claims: "I'm sending N".
--   bucket.claims[reqId .. "#" .. claimer] = { reqId, claimer, class, qty, updated, deleted }
-- A claim counts for CLAIM_HOURS after its last change, then lapses, so items
-- aren't blocked forever by someone who never sent them.
---------------------------------------------------------------------------
Wishlist.CLAIM_HOURS = 72

local function Claims()
    local b = Bucket()
    if not b then return nil end
    b.claims = b.claims or {}
    return b.claims
end

local function ClaimChanged(claim, source)
    ns:Fire("CLAIM_CHANGED", claim, source or "local")
    ns:Fire("WISHLIST_CHANGED", nil, source or "local")
end

function Wishlist:IsClaimActive(c)
    return c ~= nil and not c.deleted and (c.qty or 0) > 0
        and (c.updated or 0) >= Now() - self.CLAIM_HOURS * 3600
end

-- Active claims on one request, oldest first.
function Wishlist:ClaimsFor(reqId)
    local out = {}
    local claims = Claims()
    if not claims then return out end
    for _, c in pairs(claims) do
        if c.reqId == reqId and self:IsClaimActive(c) and self:InGuild(c.claimer) then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.updated < b.updated end)
    return out
end

-- A claim minus what that claimer has already delivered.
function Wishlist:ClaimOutstanding(c)
    local req = self:Get(c.reqId)
    local delivered = req and req.receivedFrom and req.receivedFrom[c.claimer] or 0
    return math.max(0, c.qty - delivered)
end

function Wishlist:ClaimedTotal(reqId)
    local n = 0
    for _, c in ipairs(self:ClaimsFor(reqId)) do n = n + self:ClaimOutstanding(c) end
    return n
end

function Wishlist:MyClaim(reqId)
    local claims = Claims()
    local c = claims and claims[reqId .. "#" .. ns:PlayerName()]
    return self:IsClaimActive(c) and c or nil
end

-- How many are still needed and not claimed (optionally not counting my own claim).
function Wishlist:Unclaimed(req, ignoreMine)
    local claimed = self:ClaimedTotal(req.id)
    if ignoreMine then
        local mine = self:MyClaim(req.id)
        if mine then claimed = claimed - self:ClaimOutstanding(mine) end
    end
    return math.max(0, req.qty - (req.received or 0) - claimed)
end

-- Set (or with 0, cancel) my claim. Returns the claim, or nil + a message.
function Wishlist:SetClaim(reqId, qty)
    local claims = Claims()
    local req = self:Get(reqId)
    if not claims or not self:IsOpen(req) then return nil, "That request is no longer open." end
    if self:IsMine(req) then return nil, "You can't claim your own request." end
    qty = tonumber(qty)
    if not qty or qty < 0 then return nil, "Enter a number (0 cancels your claim)." end
    qty = math.floor(qty)
    local max = self:Unclaimed(req, true)
    if qty > max then return nil, ("Only %d still unclaimed."):format(max) end
    local me = ns:PlayerName()
    local id = reqId .. "#" .. me
    local cur = claims[id]
    if qty == 0 and not cur then return nil, "You have no claim on this request." end
    local c = {
        reqId = reqId, claimer = me, class = ns:PlayerClass(), qty = qty,
        updated = math.max(Now(), cur and (cur.updated + 1) or 0),
        deleted = (qty == 0) or nil,
    }
    claims[id] = c
    ClaimChanged(c)
    return c
end

-- Every stored claim including cancelled ones (for sync).
function Wishlist:AllClaims()
    local out = {}
    local claims = Claims()
    if claims then
        for _, c in pairs(claims) do out[#out + 1] = c end
    end
    return out
end

-- A clean copy of a claim, or nil.
function Wishlist:CleanClaim(rec)
    if type(rec) ~= "table" or type(rec.reqId) ~= "string" then return nil end
    local claimer = ns:ValidName(rec.claimer)
    local owner, created, rand = rec.reqId:match("^(.+):(%d+):(%d+)$")
    if not claimer or not ns:ValidName(owner) or owner == claimer then return nil end
    local qty = ns:Int(rec.qty, 0, self.MAX_QTY)
    local updated = ns:Int(rec.updated, 1, Now() + FUTURE_SLACK)
    if not qty or not updated or not created or not rand then return nil end
    local deleted = (rec.deleted or qty == 0) and true or nil
    return { reqId = rec.reqId, claimer = claimer, class = ns:ValidClass(rec.class), qty = qty,
             updated = updated, deleted = deleted,
             modBy = deleted and ns:ValidName(rec.modBy) or nil } -- cleared by a moderator
end

-- A claim that arrived from `sender`: accepted only from the claimer themselves.
-- Newer wins, cancellation wins ties.
function Wishlist:MergeClaim(rec, sender)
    local claims = Claims()
    if not claims or not sender then return false end
    rec = self:CleanClaim(rec)
    if not rec or rec.claimer ~= sender or rec.claimer == ns:PlayerName() then return false end
    if rec.updated < Now() - self.TOMBSTONE_DAYS * 86400 then return false end
    local id = rec.reqId .. "#" .. rec.claimer
    local cur = claims[id]
    if cur then
        local newer = rec.updated > cur.updated or (rec.updated == cur.updated and rec.deleted and not cur.deleted)
        if not newer then return false end
    elseif CountAll(claims) >= self.MAX_CLAIMS then
        return false
    end
    claims[id] = rec
    ClaimChanged(rec, "remote")
    return true
end

-- Forget removed requests and old claims after TOMBSTONE_DAYS, and other players'
-- requests and claims when we haven't heard from them for requestExpiryDays.
function Wishlist:ExpiryDays()
    return ns:Int(ns.db.settings.requestExpiryDays, 1, 365) or 14
end

function Wishlist:Purge()
    local b = Bucket()
    local store = b and b.requests
    if not store then return end
    local now = Now()
    local cutoff = now - self.TOMBSTONE_DAYS * 86400
    local stale = now - self:ExpiryDays() * 86400
    b.seen = b.seen or {}
    b.seen[ns:PlayerName()] = now
    local function Gone(name)
        -- Requests stored before v0.4.0 have no "seen" yet: start their clock now.
        if not b.seen[name] then b.seen[name] = now end
        return b.seen[name] < stale
    end
    local changed = false
    for id, req in pairs(store) do
        -- removed or fulfilled and untouched for TOMBSTONE_DAYS, or the owner is gone
        if (not self:IsOpen(req) and (req.updated or 0) < cutoff) or (not self:IsMine(req) and Gone(req.requester)) then
            store[id] = nil
            changed = true
        end
    end
    local claims = Claims()
    for id, c in pairs(claims) do
        if (c.updated or 0) < cutoff or (c.claimer ~= ns:PlayerName() and Gone(c.claimer)) then claims[id] = nil end
    end
    for name, t in pairs(b.seen) do
        if t < stale - 30 * 86400 then b.seen[name] = nil end
    end
    if changed then Changed(nil, "remote") end
end

-- Saved data is checked like a message: anything invalid is dropped, notes cleaned.
ns:RegisterCallback("VALIDATE_DB", function()
    for key, b in pairs(ns.db.wishlist) do
        if type(key) ~= "string" or type(b) ~= "table" then
            ns.db.wishlist[key] = nil
        else
            local requests = type(b.requests) == "table" and b.requests or {}
            b.requests = {}
            for id, req in pairs(requests) do
                local clean = Wishlist:Clean(req)
                if clean and clean.id == id then b.requests[id] = clean end
            end
            local claims = type(b.claims) == "table" and b.claims or {}
            b.claims = {}
            for id, c in pairs(claims) do
                local clean = Wishlist:CleanClaim(c)
                if clean and id == clean.reqId .. "#" .. clean.claimer then b.claims[id] = clean end
            end
            if type(b.seen) ~= "table" then b.seen = nil end
        end
    end
end)

function Wishlist:Get(id)
    local store = Store()
    return store and store[id]
end

-- Money as the game shows it (with coin icons). 0 = "Gift".
function Wishlist:PriceText(copper)
    if not copper or copper <= 0 then return "Gift" end
    if GetMoneyString then return GetMoneyString(copper, true) end
    return C_CurrencyInfo.GetCoinTextureString(copper)
end

-- Someone joined or left the guild: lists, tooltips and the badge re-check who's in.
ns:RegisterCallback("ROSTER_CHANGED", function()
    ns:Fire("WISHLIST_CHANGED", nil, "roster")
end)
