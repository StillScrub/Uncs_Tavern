-- Modules\WishlistSync.lua: shares YOUR wishlist requests and claims with the guild.
--
-- Messages (protocol 2, see Comm.lua for the envelope and the security gate):
--   R  |class|itemID|qty|received|price|created|rand|updated|deleted|note|from
--        one of the sender's own item requests. The requester is the sender (set by
--        the server), so the id is rebuilt as "<sender>:created:rand"; nobody can send
--        a request in someone else's name.
--        from = "Name:5,Other:3": who delivered, as booked by the requester's own client
--        when they took the items from the mailbox. This is the receiver's confirmation
--        that the Helped column counts (History.lua). Empty when the requester switched
--        off Helped/History sharing.
--   RR |class|rule|qty|received|price|created|rand|updated|deleted|note|from
--        a rule request (rule = "armor:slot:minLevel:stat:minStat[:stat2:minStat2]").
--   C  |requester|created|rand|class|qty|updated|deleted
--        the sender's own claim ("I'm sending N") on the request requester:created:rand.
--
-- NO RELAYING: nobody re-sends another player's data. Each player announces their own
-- requests (open ones, plus those closed within the expiry window so removals spread)
-- and their own claims:
--   * ~15 s after login (or after opting in),
--   * when a guildmate logs in or presses Sync (their hello "Q"), at most once every
--     ANNOUNCE_GAP seconds, after a random delay,
--   * live, whenever they add, change or remove one.
-- So you see a request once its owner has been online at the same time as you.
-- Other players' requests expire after settings.requestExpiryDays without hearing
-- from them (WishlistData.lua).
local _, ns = ...
local W, Comm = ns.Wishlist, ns.Comm

local LOGIN_DELAY  = 15   -- seconds after login (after Comm's hello at 10 s)
local ANNOUNCE_GAP = 120  -- at most one full announce per this many seconds

---------------------------------------------------------------------------
-- Sending (own data only)
---------------------------------------------------------------------------
local function From(req)
    if not Comm:IsSharing("helped") then return "" end
    return W:EncodeFrom(req.receivedFrom)
end

local function SendRecord(req)
    if not W:IsMine(req) then return end -- never relay
    local rand = req.id:match(":(%d+)$") or "0"
    local msgType, what = "R", req.itemID
    if req.rule then msgType, what = "RR", W:EncodeRule(req.rule) end
    Comm:Send(msgType, req.class or "", what, req.qty, req.received or 0,
        req.price or 0, req.created, rand, req.updated, req.deleted and 1 or 0, req.note or "", From(req))
end

local function SendClaim(c)
    if c.claimer ~= ns:PlayerName() then return end -- never relay
    local requester, created, rand = c.reqId:match("^(.*):(%d+):(%d+)$")
    if not requester then return end
    Comm:Send("C", requester, created, rand, c.class or "", c.qty, c.updated, c.deleted and 1 or 0)
end

local lastAnnounce = -ANNOUNCE_GAP
local announcePending = false

local function AnnounceOwn()
    announcePending = false
    if not Comm:IsSharing("wishlist") then return end
    lastAnnounce = GetTime()
    local since = W.Now() - W:ExpiryDays() * 86400
    for _, req in ipairs(W:All()) do
        if W:IsMine(req) and (W:IsOpen(req) or req.updated >= since) then SendRecord(req) end
    end
    local me = ns:PlayerName()
    for _, c in ipairs(W:AllClaims()) do
        if c.claimer == me and c.updated >= since then SendClaim(c) end
    end
end

local function ScheduleAnnounce(delay)
    if announcePending then return end
    local wait = math.max(delay, ANNOUNCE_GAP - (GetTime() - lastAnnounce))
    announcePending = true
    C_Timer.After(wait, AnnounceOwn)
end

---------------------------------------------------------------------------
-- Receiving (sender = the server-set name; Merge checks sender == owner)
---------------------------------------------------------------------------
local mergedCount = 0 -- requests changed by sync this session (for the summary)

local function Record(sender, class, itemID, rule, qty, received, price, created, rand, updated, deleted, note, from)
    created = ns:Int(created, 1)
    rand = ns:Int(rand, 0, 99999)
    if not created or not rand then return end
    local rec = {
        id = ("%s:%d:%d"):format(sender, created, rand),
        requester = sender, class = class, itemID = itemID, rule = rule,
        qty = qty, received = received, price = price, created = created, updated = updated,
        deleted = deleted == "1", note = note,
        receivedFrom = Comm:IsSharing("helped") and W:DecodeFrom(from) or nil,
    }
    W:SeenOwner(sender)
    if W:Merge(rec, sender) then mergedCount = mergedCount + 1 end
end

Comm:RegisterHandler("R", function(sender, class, itemID, ...)
    Record(sender, class, itemID, nil, ...)
end, "wishlist")

Comm:RegisterHandler("RR", function(sender, class, ruleText, ...)
    local rule = W:DecodeRule(ruleText)
    if not rule then return end
    Record(sender, class, nil, rule, ...)
end, "wishlist")

Comm:RegisterHandler("C", function(sender, requester, created, rand, class, qty, updated, deleted)
    if not ns:ValidName(requester) or not ns:Int(created, 1) or not ns:Int(rand, 0, 99999) then return end
    local rec = {
        reqId = ("%s:%s:%s"):format(requester, created, rand),
        claimer = sender, class = class, qty = qty, updated = updated, deleted = deleted == "1",
    }
    W:SeenOwner(sender)
    if W:MergeClaim(rec, sender) then mergedCount = mergedCount + 1 end
end, "wishlist")

---------------------------------------------------------------------------
-- Live changes, login, hellos, Sync button
---------------------------------------------------------------------------
ns:RegisterCallback("WISHLIST_CHANGED", function(_, req, source)
    if source == "local" and req and W:IsMine(req) then SendRecord(req) end
end)

ns:RegisterCallback("CLAIM_CHANGED", function(_, claim, source)
    if source == "local" and claim then SendClaim(claim) end
end)

-- A guildmate logged in or pressed Sync: let them see my requests.
ns:RegisterCallback("HELLO", function(_, sender, flag)
    W:SeenOwner(sender)
    if flag == "Q" then ScheduleAnnounce(3 + math.random() * 7) end
end)

local started = false
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if started then return end
    started = true
    C_Timer.After(LOGIN_DELAY, function()
        if not IsInGuild() then return end
        W:Purge()
        ScheduleAnnounce(0)
    end)
end)

ns:RegisterCallback("SHARING_CHANGED", function(_, field, value)
    if value and (field == "optIn" or field == "wishlist" or field == "helped") then ScheduleAnnounce(5) end
end)
ns:RegisterCallback("GUILD_CHANGED", function() W:Purge() end)

-- Roster's Sync button: announce mine; everyone else announces theirs on my hello.
local SUMMARY_DELAY = 20
ns:RegisterCallback("SYNC_REQUESTED", function()
    local hellos, merged = Comm:HelloCount(), mergedCount
    lastAnnounce = -ANNOUNCE_GAP
    ScheduleAnnounce(1)
    C_Timer.After(SUMMARY_DELAY, function()
        local answered = Comm:HelloCount() - hellos
        local got = mergedCount - merged
        if answered == 0 then
            ns:Print("Sync done: no other online guild member with " .. ns.title .. " answered. "
                .. "Your requests are saved and are shared when someone is online.")
        else
            ns:Print(("Sync done: %d guild member(s) answered, %d wishlist update(s) received."):format(answered, got))
        end
    end)
end)

-- /tavern wishlist: sync status
ns:RegisterCommand("wishlist", function()
    local b = W.Bucket()
    if not b then ns:Print("Not in a guild.") return end
    local open, removed, mine, total = 0, 0, 0, 0
    for _, req in ipairs(W:All()) do
        total = total + 1
        if req.deleted then removed = removed + 1 elseif W:IsOpen(req) then open = open + 1 end
        if W:IsMine(req) and W:IsOpen(req) then mine = mine + 1 end
    end
    ns:Print(("Wishlist: %d open (%d yours), %d removed, %d stored."):format(open, mine, removed, total))
    DEFAULT_CHAT_FRAME:AddMessage(("  sharing: %s | messages waiting to send: %d | others' requests expire after %d days unseen"):format(
        Comm:IsSharing("wishlist") and "on" or "off", Comm:QueueLength(), W:ExpiryDays()))
end, "show wishlist sync status")
