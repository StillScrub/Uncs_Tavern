-- Modules\ItemSearch.lua: find items by name for the wishlist's search box.
--
-- Sources:
--   * COMMON: a built-in list of common mats and leveling items (classic-era item IDs).
--     Names always come from the game client, so they're in the player's language;
--     IDs the client doesn't know are skipped.
--   * Items seen in the player's bags (remembered account-wide, capped at MAX_SEEN).
--   * Items already on the guild wishlist.
--   * Typing a number searches by item ID.
-- Item names load on demand (RequestLoadItemDataByID); GET_ITEM_INFO_RECEIVED fires
-- "ITEM_SEARCH_UPDATED" (coalesced) so an open result list can refresh.
-- Event-driven only: bags are read on login and on BAG_UPDATE_DELAYED.
local _, ns = ...

local Search = {}
ns.ItemSearch = Search

local MAX_SEEN = 3000

local COMMON = {
    -- Cloth and bolts
    2589, 2592, 4306, 4338, 14047, 14256, 2996, 2997, 4305, 4339, 14048,
    -- Ore and bars
    2770, 2771, 2775, 2772, 2776, 7911, 3858, 10620,
    2840, 3576, 2841, 2842, 3575, 3577, 3859, 6037, 3860, 12359,
    -- Stone
    2835, 2836, 2838, 7912, 12365,
    -- Leather and hides
    2934, 2318, 2319, 4234, 4304, 8170, 783, 4232, 4235, 8169, 8171,
    -- Herbs
    765, 2447, 2449, 785, 2450, 2452, 2453, 3820, 3355, 3369, 3356, 3357, 3818, 3821,
    3358, 3819, 4625, 8831, 8836, 8838, 8839, 8845, 8846, 13464, 13463, 13465, 13466,
    13467, 13468,
    -- Enchanting
    10940, 11083, 11137, 11176, 16204, 10938, 10939, 10998, 11082, 11134, 11135, 11174,
    11175, 16202, 16203, 10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344,
    -- Gems
    774, 818, 1210, 1705, 1206, 1529, 3864, 7909, 7910,
    -- Elemental
    7067, 7068, 7069, 7070, 7075, 7076, 7077, 7078, 7080, 7082, 12803, 12808,
    -- Vials, potions
    3371, 3372, 8925, 118, 858, 929, 1710, 3928, 13446, 2455, 3385, 3827, 6149, 13443, 13444,
    -- Bags
    4496, 4245, 10050, 14046,
}

local function Seen()
    ns.db.seenItems = ns.db.seenItems or {}
    return ns.db.seenItems
end

local function Exists(id)
    return id and C_Item.GetItemInfoInstant(id) ~= nil
end

---------------------------------------------------------------------------
-- Bags -> seen items
---------------------------------------------------------------------------
local seenCount
local function RememberBags()
    if not ns.db then return end
    local seen = Seen()
    if not seenCount then
        seenCount = 0
        for _ in pairs(seen) do seenCount = seenCount + 1 end
    end
    local last = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
    for bag = 0, last do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and not seen[id] and seenCount < MAX_SEEN then
                seen[id] = true
                seenCount = seenCount + 1
            end
        end
    end
end

ns:RegisterEvent("PLAYER_LOGIN", RememberBags)
ns:RegisterEvent("BAG_UPDATE_DELAYED", RememberBags)

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------
local updatePending = false
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
    if updatePending then return end
    updatePending = true
    C_Timer.After(0.3, function()
        updatePending = false
        ns:Fire("ITEM_SEARCH_UPDATED")
    end)
end)

local function Candidates()
    local ids, out = {}, {}
    local function Add(id)
        if id and not ids[id] then
            ids[id] = true
            out[#out + 1] = id
        end
    end
    for _, id in ipairs(COMMON) do Add(id) end
    for id in pairs(Seen()) do Add(id) end
    if ns.Wishlist then
        for _, req in ipairs(ns.Wishlist:All()) do Add(req.itemID) end
    end
    return out
end

-- Ask the client to load names we don't have yet (once per session).
local preloaded = false
function Search:Preload()
    if preloaded then return end
    preloaded = true
    for _, id in ipairs(Candidates()) do
        if Exists(id) and not C_Item.GetItemInfo(id) and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(id)
        end
    end
end

---------------------------------------------------------------------------
-- Search: returns up to `max` item IDs; names starting with the text come first.
---------------------------------------------------------------------------
function Search:Find(text, max)
    text = strtrim(text or ""):lower()
    max = max or 8
    local out = {}
    if text == "" then return out end

    local asID = tonumber(text)
    if asID and Exists(asID) then out[1] = asID end
    if #text < 2 then return out end

    local starts, contains = {}, {}
    for _, id in ipairs(Candidates()) do
        if id ~= asID then
            local name = C_Item.GetItemInfo(id)
            if name then
                local lower = name:lower()
                local at = lower:find(text, 1, true)
                if at == 1 then
                    starts[#starts + 1] = { id = id, name = lower }
                elseif at then
                    contains[#contains + 1] = { id = id, name = lower }
                end
            end
        end
    end
    local byName = function(a, b) return a.name < b.name end
    table.sort(starts, byName)
    table.sort(contains, byName)
    for _, list in ipairs({ starts, contains }) do
        for _, e in ipairs(list) do
            if #out >= max then return out end
            out[#out + 1] = e.id
        end
    end
    return out
end
