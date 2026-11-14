-- Modules\AutoComplete.lua: when items you requested arrive by mail (or items that
-- fit one of your rule requests), your request's "received" count goes up; when it reaches the quantity, the request is done and
-- disappears for everyone (the change syncs like any other edit).
--
-- How: post-hooks on TakeInboxItem / AutoLootMailItem (they never block or change
-- the mailbox) note which wanted items you are taking and who sent them. The count
-- is only booked after BAG_UPDATE_DELAYED shows the items really landed in your
-- bags, so full bags or a cancelled COD never count. Pending notes expire after 10s.
local _, ns = ...
local W = ns.Wishlist

local EXPIRE = 10
local MAX_ATTACH = ATTACHMENTS_MAX_RECEIVE or 16

local pending = {} -- { itemID, link, count, sender, before, time }
local listening = false

local function BagCount(itemID)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(itemID) or 0 end
    return GetItemCount(itemID) or 0
end

local OnBagsChanged

local function Listen(on)
    if on == listening then return end
    listening = on
    if on then
        ns:RegisterEvent("BAG_UPDATE_DELAYED", OnBagsChanged)
    else
        ns:UnregisterEvent("BAG_UPDATE_DELAYED", OnBagsChanged)
    end
end

local function NoteAttachment(mailIndex, attachIndex)
    local ok, _, itemID, _, count = pcall(GetInboxItem, mailIndex, attachIndex)
    if not ok or not itemID or not count or count < 1 then return end
    local link = GetInboxItemLink and GetInboxItemLink(mailIndex, attachIndex)
    if not W:WantsItem(itemID) and not (link and #W:MyRulesMatching(link) > 0) then return end
    local sender = select(3, GetInboxHeaderInfo(mailIndex))
    sender = sender and Ambiguate(sender, "guild") or nil
    -- Several attachments of the same item: they share one "before" count.
    local before = BagCount(itemID)
    for _, p in ipairs(pending) do
        if p.itemID == itemID then before = p.before break end
    end
    pending[#pending + 1] = { itemID = itemID, link = link, count = count, sender = sender, before = before, time = GetTime() }
    Listen(true)
end

OnBagsChanged = function()
    local now = GetTime()
    -- Group by item: how much of each actually arrived since we noted it?
    local arrived = {}
    for _, p in ipairs(pending) do
        if arrived[p.itemID] == nil then
            arrived[p.itemID] = math.max(0, BagCount(p.itemID) - p.before)
        end
    end
    local keep = {}
    for _, p in ipairs(pending) do
        local avail = arrived[p.itemID]
        local got = math.min(p.count, avail)
        if got > 0 then
            arrived[p.itemID] = avail - got
            local counted = W:AddReceived(p.itemID, got, p.sender)
            if counted < got and p.link then
                counted = counted + W:AddReceivedRule(p.link, got - counted, p.sender)
            end
            if counted > 0 then
                local name = C_Item.GetItemInfo(p.itemID) or ("item " .. p.itemID)
                ns:Print(("Wishlist: +%d %s%s."):format(counted, name, p.sender and (" from " .. p.sender) or ""))
            end
            p.count = p.count - got
        end
        if p.count > 0 and now - p.time < EXPIRE then keep[#keep + 1] = p end
    end
    -- Later notes of the same item measure from the new bag count.
    for _, p in ipairs(keep) do p.before = BagCount(p.itemID) end
    pending = keep
    if #pending == 0 then Listen(false) end
end

if TakeInboxItem then
    hooksecurefunc("TakeInboxItem", function(mailIndex, attachIndex)
        NoteAttachment(mailIndex, attachIndex)
    end)
end
if AutoLootMailItem then
    hooksecurefunc("AutoLootMailItem", function(mailIndex)
        for a = 1, MAX_ATTACH do NoteAttachment(mailIndex, a) end
    end)
end
