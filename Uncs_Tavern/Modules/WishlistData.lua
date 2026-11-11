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
--   created / updated   time() stamps; sync will merge by `updated`
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
local _, ns = ...

local Wishlist = {}
ns.Wishlist = Wishlist

Wishlist.MAX_QTY        = 9999
Wishlist.MAX_PRICE      = 9999 * 10000 -- 9999 gold
Wishlist.MAX_NOTE       = 60
Wishlist.MAX_OPEN_OWN   = 25

local function Store()
    local key = ns:GuildKey()
    if not key then return nil end
    ns.db.wishlist[key] = ns.db.wishlist[key] or { requests = {} }
    return ns.db.wishlist[key].requests
end

local function Changed(req)
    ns:Fire("WISHLIST_CHANGED", req)
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

    local now = time()
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
    req.updated = time()
    Changed(req)
    return true
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
