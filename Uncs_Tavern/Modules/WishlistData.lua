-- Modules\WishlistData.lua: wishlist storage and rules (no UI).
-- Used by the Wishlist tab now, and later by sync, mail and alerts.
--
-- Stored per guild in ns.db.wishlist[guildKey].requests[id]:
--   id        "<requester>:<created>:<rand>"  (unique across the guild)
--   requester full two-part name, e.g. "Hexual Defect"
--   class     class file name of the requester (for coloring), e.g. "SHAMAN"
--   itemID    number
--   qty       how many wanted in total
--   received  how many have arrived so far
--   price     copper per item the requester will pay; 0 = gift
--   note      short free text
--   created / updated   GetServerTime() stamps (same clock for everyone); sync merges by `updated`
--   deleted   true = removed (kept as a tombstone so sync can spread the removal)
--
-- Fires ns callback "WISHLIST_CHANGED" after any change.
--
-- Data-safety rules (sync must keep these):
--   * Every request has its own unique id, so two requests can never overwrite each other.
--   * The requester's copy is the authority for its own request: sync only replaces a
--     stored request with a copy that has a newer `updated`, and never lets another
--     player edit or delete someone else's request. (Claims will be stored separately.)
--   * Removing is a tombstone (deleted = true), never a hard delete, so a stale copy
--     arriving later can't bring a removed request back.
--   * A request leaves the list only when the requester removes it, or when received
--     reaches qty (fulfilled).
--   * Claims ("I'm sending N") live in a separate table, one per claimer per request.
--     Only the claimer changes their own claim; a claim can never touch the request.
local _, ns = ...

local Wishlist = {}
ns.Wishlist = Wishlist

Wishlist.MAX_QTY        = 9999
Wishlist.MAX_PRICE      = 9999 * 10000 -- 9999 gold
Wishlist.MAX_NOTE       = 60
Wishlist.MAX_OPEN_OWN   = 25
Wishlist.TOMBSTONE_DAYS = 30 -- removed requests are forgotten after this

local function Now()
    return GetServerTime and GetServerTime() or time()
end
Wishlist.Now = Now

-- Per-guild bucket: { requests = {}, lastSync = serverTime of last complete catch-up }
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

-- "Gear" = weapons and armor; everything else counts as "Mats".
function Wishlist:Category(itemID)
    local classID = select(6, C_Item.GetItemInfoInstant(itemID))
    local weapon = Enum and Enum.ItemClass and Enum.ItemClass.Weapon or 2
    local armor  = Enum and Enum.ItemClass and Enum.ItemClass.Armor or 4
    return (classID == weapon or classID == armor) and "gear" or "mats"
end

-- Open requests, newest first. filter: "all" | "mats" | "gear" | "mine"
function Wishlist:List(filter)
    local out = {}
    local store = Store()
    if not store then return out end
    for _, req in pairs(store) do
        if self:IsOpen(req) then
            local keep = filter == nil or filter == "all"
                or (filter == "mine" and self:IsMine(req))
                or (filter ~= "mine" and self:Category(req.itemID) == filter)
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
function Wishlist:Add(itemID, qty, price, note)
    local store = Store()
    if not store then return nil, "You are not in a guild." end
    itemID, qty, price = tonumber(itemID), tonumber(qty), tonumber(price) or 0
    note = strtrim(note or ""):gsub("|", "") -- "|" would break chat links and the sync format
    if not itemID or not C_Item.GetItemInfoInstant(itemID) then return nil, "Pick an item first." end
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
        itemID = math.floor(itemID),
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

-- Validates a request that arrived from another player and merges it.
-- Rules (see header): newer `updated` wins; on a tie a removal wins; nobody
-- else's copy may change one of MY requests that I already have.
-- Returns true if the store changed.
function Wishlist:Merge(rec)
    local store = Store()
    if not store or type(rec) ~= "table" then return false end
    if type(rec.id) ~= "string" or type(rec.requester) ~= "string" then return false end
    if rec.id:sub(1, #rec.requester + 1) ~= rec.requester .. ":" then return false end
    if not rec.itemID or not C_Item.GetItemInfoInstant(rec.itemID) then return false end
    if not rec.qty or rec.qty < 1 or rec.qty > self.MAX_QTY then return false end
    if not rec.price or rec.price < 0 or rec.price > self.MAX_PRICE then return false end
    if not rec.updated or not rec.created then return false end
    if rec.deleted and rec.updated < Now() - self.TOMBSTONE_DAYS * 86400 then return false end

    local cur = store[rec.id]
    if cur then
        if self:IsMine(cur) then return false end -- my own copy is the authority
        local newer = rec.updated > cur.updated or (rec.updated == cur.updated and rec.deleted and not cur.deleted)
        if not newer then return false end
    end
    store[rec.id] = {
        id = rec.id, requester = rec.requester, class = rec.class,
        itemID = rec.itemID, qty = rec.qty, received = math.min(rec.received or 0, rec.qty),
        price = rec.price, note = (rec.note or ""):sub(1, self.MAX_NOTE),
        created = rec.created, updated = rec.updated, deleted = rec.deleted or nil,
    }
    Changed(store[rec.id], "remote")
    return true
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
        if c.reqId == reqId and self:IsClaimActive(c) then out[#out + 1] = c end
    end
    table.sort(out, function(a, b) return a.updated < b.updated end)
    return out
end

function Wishlist:ClaimedTotal(reqId)
    local n = 0
    for _, c in ipairs(self:ClaimsFor(reqId)) do n = n + c.qty end
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
        if mine then claimed = claimed - mine.qty end
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

-- Validates a claim from another player and merges it. Same rules as requests:
-- newer wins, cancellation wins ties, nobody else can change MY claim.
function Wishlist:MergeClaim(rec)
    local claims = Claims()
    if not claims or type(rec) ~= "table" then return false end
    if type(rec.reqId) ~= "string" or type(rec.claimer) ~= "string" or rec.claimer == "" then return false end
    if not rec.qty or rec.qty < 0 or rec.qty > self.MAX_QTY or not rec.updated then return false end
    if rec.updated < Now() - self.TOMBSTONE_DAYS * 86400 then return false end
    local id = rec.reqId .. "#" .. rec.claimer
    local cur = claims[id]
    if cur then
        if cur.claimer == ns:PlayerName() then return false end -- my claim is mine
        local newer = rec.updated > cur.updated or (rec.updated == cur.updated and rec.deleted and not cur.deleted)
        if not newer then return false end
    end
    claims[id] = {
        reqId = rec.reqId, claimer = rec.claimer, class = rec.class, qty = rec.qty,
        updated = rec.updated, deleted = rec.deleted or nil,
    }
    ClaimChanged(claims[id], "remote")
    return true
end

-- Forget removed requests and old claims after TOMBSTONE_DAYS.
function Wishlist:Purge()
    local store = Store()
    if not store then return end
    local cutoff = Now() - self.TOMBSTONE_DAYS * 86400
    for id, req in pairs(store) do
        if req.deleted and (req.updated or 0) < cutoff then store[id] = nil end
    end
    local claims = Claims()
    for id, c in pairs(claims) do
        if (c.updated or 0) < cutoff then claims[id] = nil end
    end
end

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
