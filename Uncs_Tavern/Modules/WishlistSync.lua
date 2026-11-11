-- Modules\WishlistSync.lua: spreads wishlist requests across the guild over Comm.
--
-- Messages (protocol 1, see Comm.lua for the envelope):
--   R  |requester|class|itemID|qty|received|price|created|rand|updated|deleted|note
--        one request. id is rebuilt as "requester:created:rand". Sent live whenever
--        you add/remove a request, and during catch-up.
--   WQ |since          "send me everything updated since <serverTime>" (0 = everything)
--   WS |asker          "I'm answering <asker>" - other would-be answerers stand down
--   WE |asker|time     end of the answer; the asker stores <time> as lastSync
--
-- Catch-up: after login you ask once (WQ with your lastSync minus a margin). Every
-- online member with data waits a random 2-6s; the first to answer sends WS, the
-- rest cancel. Everyone who overhears R messages merges them too. Anything changed
-- after your last complete catch-up has a newer `updated`, so nothing is missed;
-- if the answer is cut off, lastSync isn't advanced and the next login asks again.
-- You also re-send your own recent requests on login, in case a send was lost.
--
-- Merging (rules in WishlistData.lua): newer wins, removals win ties, and other
-- players' copies never override your own requests.
local _, ns = ...
local W, Comm = ns.Wishlist, ns.Comm

local LOGIN_DELAY   = 15   -- seconds after login (after Comm's hello at 10s)
local SINCE_MARGIN  = 300  -- re-ask 5 minutes before lastSync, to cover edge cases
local OWN_PUSH_DAYS = 2    -- on login, re-send own requests changed in this window

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
local function SendRecord(req)
    local rand = req.id:match(":(%d+)$") or "0"
    Comm:Send("R", req.requester, req.class or "", req.itemID, req.qty, req.received or 0,
        req.price or 0, req.created, rand, req.updated, req.deleted and 1 or 0, req.note or "")
end

local function DecodeRecord(requester, class, itemID, qty, received, price, created, rand, updated, deleted, note)
    created = tonumber(created)
    if not requester or not created or not tonumber(rand) then return nil end
    return {
        id = ("%s:%d:%s"):format(requester, created, rand),
        requester = requester,
        class = (class ~= "" and class) or nil,
        itemID = tonumber(itemID),
        qty = tonumber(qty),
        received = tonumber(received) or 0,
        price = tonumber(price),
        created = created,
        updated = tonumber(updated),
        deleted = deleted == "1",
        note = note or "",
    }
end

---------------------------------------------------------------------------
-- Catch-up
---------------------------------------------------------------------------
local pendingAnswers = {} -- [asker] = timer

local function SendQuery(full)
    local b = W.Bucket()
    if not b then return end
    local since = full and 0 or math.max(0, (b.lastSync or 0) - SINCE_MARGIN)
    Comm:Send("WQ", since)
end

local function PushOwn(sinceTime)
    for _, req in ipairs(W:All()) do
        if W:IsMine(req) and req.updated >= sinceTime then SendRecord(req) end
    end
end

local function Answer(asker, since)
    local startTime = W.Now()
    Comm:Send("WS", asker)
    for _, req in ipairs(W:All()) do
        if req.updated >= since then SendRecord(req) end
    end
    Comm:Send("WE", asker, startTime)
end

Comm:RegisterHandler("WQ", function(sender, since)
    since = tonumber(since) or 0
    local b = W.Bucket()
    if not b or pendingAnswers[sender] then return end
    -- Members who have caught up themselves answer a bit sooner.
    local delay = 2 + math.random() * 4 + ((b.lastSync and 0) or 3)
    pendingAnswers[sender] = C_Timer.NewTimer(delay, function()
        pendingAnswers[sender] = nil
        Answer(sender, since)
    end)
end)

Comm:RegisterHandler("WS", function(_, asker)
    local t = asker and pendingAnswers[asker]
    if t then
        t:Cancel()
        pendingAnswers[asker] = nil
    end
end)

Comm:RegisterHandler("WE", function(_, asker, endTime)
    endTime = tonumber(endTime)
    local b = W.Bucket()
    if not b or not endTime then return end
    local me = ns:PlayerName()
    if asker == me or asker == Ambiguate(me, "guild") then
        b.lastSync = math.max(b.lastSync or 0, endTime)
    end
end)

local mergedCount = 0 -- requests changed by sync this session (for the summary)

Comm:RegisterHandler("R", function(_, ...)
    local rec = DecodeRecord(...)
    if rec and W:Merge(rec) then mergedCount = mergedCount + 1 end
end)

---------------------------------------------------------------------------
-- Live changes, login, Sync button
---------------------------------------------------------------------------
ns:RegisterCallback("WISHLIST_CHANGED", function(_, req, source)
    if source == "local" and req and W:IsMine(req) then SendRecord(req) end
end)

local started = false
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if started then return end
    started = true
    C_Timer.After(LOGIN_DELAY, function()
        if not IsInGuild() then return end
        W:Purge()
        SendQuery(false)
        PushOwn(W.Now() - OWN_PUSH_DAYS * 86400)
    end)
end)

-- Roster's Sync button: full catch-up plus all of your own requests.
-- Prints a summary once answers have had time to arrive.
local SUMMARY_DELAY = 20
ns:RegisterCallback("SYNC_REQUESTED", function()
    local hellos, merged = Comm:HelloCount(), mergedCount
    SendQuery(true)
    PushOwn(0)
    C_Timer.After(SUMMARY_DELAY, function()
        local answered = Comm:HelloCount() - hellos
        local got = mergedCount - merged
        if answered == 0 then
            ns:Print("Sync done: no other online guild member with " .. ns.title .. " answered. "
                .. "Your requests are saved and will spread when someone is online.")
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
    DEFAULT_CHAT_FRAME:AddMessage(("  last complete catch-up: %s | messages waiting to send: %d"):format(
        b.lastSync and date("%Y-%m-%d %H:%M", b.lastSync) or "never", Comm:QueueLength()))
end, "show wishlist sync status")
