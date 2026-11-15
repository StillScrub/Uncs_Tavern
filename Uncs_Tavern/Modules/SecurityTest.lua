-- Modules\SecurityTest.lua: /tavern securitytest (developer check, off by default).
--
--   /tavern debug on      enables it (ns.db.settings.debug)
--   /tavern securitytest  feeds forged and malformed messages into our own receive
--                         path and prints which were rejected.
--
-- Nothing is sent while it runs: Comm swallows every outgoing message (and counts
-- them), the guild roster is a fake one (Alice Test, Bob Test, Lea Der as guild leader), and all data goes to a
-- throwaway guild key that is deleted afterwards. Your real guild's data isn't touched.
local _, ns = ...
local W, Comm = ns.Wishlist, ns.Comm

local KEY = "SecurityTest@local"
local ALICE, BOB, MALLORY = "Alice Test", "Bob Test", "Mallory Evil"
local LEADER = "Lea Der" -- rank 0 in the fake roster
local ITEM = 2589 -- Linen Cloth

local function Msg(...)
    local parts = { "2" }
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, "|")
end

-- 2|R|class|itemID|qty|received|price|created|rand|updated|deleted|note|from
local function R(o)
    local now = W.Now()
    return Msg("R", o.class or "MAGE", o.itemID or ITEM, o.qty or 5, o.received or 0, o.price or 100,
        o.created or now, o.rand or 1111, o.updated or now, o.deleted or 0, o.note or "", o.from or "")
end

local function Wipe()
    ns.db.wishlist[KEY] = nil
    ns.db.pvp[KEY] = nil
    ns.db.helpedLedger[KEY] = nil
    ns.db.roster[KEY] = nil
    ns.db.sharing[KEY] = nil
    ns.db.perms[KEY] = nil
    ns.db.modActions[KEY] = nil
    ns.db.guildLog[KEY] = nil
    ns.db.officerLog[KEY] = nil
    local h = ns.charDB.history
    if type(h.byGuild) == "table" then h.byGuild[KEY] = nil end
end

local function Run()
    local results = {}
    local function Expect(label, ok) results[#results + 1] = { label = label, ok = ok and true or false } end
    local function Send(sender, text, channel) Comm:TestReceive(sender, text, channel) end
    local function Stored(sender, created, rand) return W:Get(("%s:%d:%d"):format(sender, created, rand)) end
    local now = W.Now()

    -- Control: a valid request from Alice is accepted (so the rejections below mean something).
    Send(ALICE, R({ created = now, rand = 1001 }))
    Expect("valid request from its owner is accepted", Stored(ALICE, now, 1001) ~= nil)

    -- Wrong owner / relaying
    Send(ALICE, "1|R|" .. BOB .. "|MAGE|" .. ITEM .. "|5|0|100|" .. now .. "|1002|" .. now .. "|0||")
    Expect("relayed request (old protocol 1 format) rejected", Stored(BOB, now, 1002) == nil)
    local forged = { id = ("%s:%d:%d"):format(BOB, now, 1003), requester = BOB, itemID = ITEM, qty = 1,
                     price = 0, created = now, updated = now }
    Expect("request in someone else's name rejected (data layer)", not W:Merge(forged, ALICE) and Stored(BOB, now, 1003) == nil)
    Send(ALICE, R({ created = now, rand = 1001, updated = now + 5, deleted = 1 }))
    -- Alice deleting her own request is allowed; nobody else can (no field names another owner).
    Expect("owner can remove their own request", (Stored(ALICE, now, 1001) or {}).deleted == true)
    Expect("claim in someone else's name rejected (data layer)",
        not W:MergeClaim({ reqId = ("%s:%d:%d"):format(ALICE, now, 1001), claimer = BOB, qty = 1, updated = now }, MALLORY))

    -- Senders
    Send(MALLORY, R({ created = now, rand = 1004 }))
    Expect("sender not in the guild roster rejected", Stored(MALLORY, now, 1004) == nil)
    Send(ALICE, R({ created = now, rand = 1005 }), "WHISPER")
    Expect("whisper channel rejected", Stored(ALICE, now, 1005) == nil)

    -- Oversized / out of range
    Send(ALICE, R({ created = now, rand = 1006, qty = 5000 }))
    Expect("quantity 5000 rejected", Stored(ALICE, now, 1006) == nil)
    Send(ALICE, R({ created = now, rand = 1007, price = 999999999999 }))
    Expect("absurd price rejected", Stored(ALICE, now, 1007) == nil)
    Send(ALICE, R({ created = now, rand = 1008, qty = -3 }))
    Expect("negative quantity rejected", Stored(ALICE, now, 1008) == nil)
    Send(ALICE, R({ created = now + 86400 * 30, rand = 1009, updated = now + 86400 * 30 }))
    Expect("timestamp in the future rejected", Stored(ALICE, now + 86400 * 30, 1009) == nil)
    Send(ALICE, R({ created = now, rand = 1010, note = string.rep("x", 150) }))
    local long = Stored(ALICE, now, 1010)
    Expect("long note cut to " .. W.MAX_NOTE .. " characters", long and #long.note <= W.MAX_NOTE)

    -- Fake items and links
    Send(ALICE, R({ created = now, rand = 1011, itemID = 999999999 }))
    Expect("item ID that doesn't exist rejected", Stored(ALICE, now, 1011) == nil)
    Send(ALICE, R({ created = now, rand = 1012, itemID = "[Thunderfury]" }))
    Expect("item name/link text instead of an ID rejected", Stored(ALICE, now, 1012) == nil)

    -- Escape codes (inside a message "|" splits fields, so test the data layer too)
    local esc = { id = ("%s:%d:%d"):format(ALICE, now, 1013), requester = ALICE, itemID = ITEM, qty = 1, price = 0,
                  created = now, updated = now,
                  note = "|cffff0000Free|r |Hitem:19019|h[Thunderfury]|h |TInterface\\Icons\\INV_Misc_Bomb_01:0|t %s%d" }
    W:Merge(esc, ALICE)
    local e = Stored(ALICE, now, 1013)
    Expect("escape codes stripped from notes", e and not e.note:find("|", 1, true))
    local pvpRec = ns.PvPStats:CleanRecord({ hk = 5, deaths = 1, top = "|cffff0000Evil|r|Hplayer:x|h" })
    Expect("escape codes stripped from \"Most killed by\"", pvpRec and not (pvpRec.top or ""):find("|", 1, true))

    -- Claims
    Send(BOB, Msg("C", ALICE, now, 1010, "WARRIOR", 2, now, 0))
    Expect("valid claim from the claimer accepted", W:ClaimedTotal(("%s:%d:%d"):format(ALICE, now, 1010)) == 2)
    Send(BOB, Msg("C", ALICE, now, 1001, "WARRIOR", 99999, now, 0))
    Expect("claim quantity 99999 rejected", W:ClaimedTotal(("%s:%d:%d"):format(ALICE, now, 1001)) == 0)
    Send(BOB, Msg("C", BOB, now, 1001, "WARRIOR", 1, now, 0))
    Expect("claim on your own request rejected", #W:ClaimsFor(("%s:%d:%d"):format(BOB, now, 1001)) == 0)

    -- Helped: only the receiver's confirmation counts
    Send(ALICE, Msg("WH", 500))
    Expect("self-reported Helped count (old WH message) rejected", (ns.History:HelpedCount(ALICE) or 0) == 0)
    Send(ALICE, R({ created = now, rand = 1014, received = 5, from = ALICE .. ":5" }))
    ns.History:ScanNow()
    Expect("helping yourself doesn't count", (ns.History:HelpedCount(ALICE) or 0) == 0)
    for i = 1, 5 do
        Send(ALICE, R({ created = now, rand = 1020 + i, received = 1, qty = 1, from = BOB .. ":1" }))
    end
    ns.History:ScanNow()
    local bobHelped = ns.History:HelpedCount(BOB) or 0
    Expect(("receiver-confirmed Helped counts, capped at 3 per pair per day (got %d)"):format(bobHelped), bobHelped == 3)

    -- Cap: 25 open requests per player
    local accepted = 0
    for i = 1, 26 do
        if W:Merge({ id = ("%s:%d:%d"):format(BOB, now, 2000 + i), requester = BOB, itemID = ITEM, qty = 1,
                     price = 0, created = now, updated = now }, BOB) then
            accepted = accepted + 1
        end
    end
    Expect(("max 25 open requests per player (accepted %d of 26)"):format(accepted), accepted == 25)

    -- PvP
    Send(ALICE, Msg("P", -5, 1, 0, 0, 0, "", 0, 0))
    Expect("negative PvP stat rejected", ns.db.pvp[KEY] == nil or ns.db.pvp[KEY][ALICE] == nil)
    Send(ALICE, Msg("P", 99999999999, 1, 0, 0, 0, "", 0, 0))
    Expect("impossible PvP stat rejected", ns.db.pvp[KEY] == nil or ns.db.pvp[KEY][ALICE] == nil)
    Send(ALICE, Msg("P", 120, 30, 1, 2, 40, "Some Horde", 3, 1))
    Expect("valid PvP stats accepted (stored under the sender only)",
        ns.db.pvp[KEY] and ns.db.pvp[KEY][ALICE] and ns.db.pvp[KEY][ALICE].hk == 120)

    -- Presence
    Send(BOB, Msg("H", "|cffff0000hacked|r", "R"))
    local users = ns.db.roster[KEY] and ns.db.roster[KEY].users
    Expect("bad version string in hello rejected", not (users and users[BOB]))

    -- Phase B: rank config, moderation, officer log
    local hash = ns.Perms:RankHash()
    Send(BOB, Msg("K", now, 1023, 1023, 30, hash))
    Expect("rank config from a non-leader rejected", ns.db.perms[KEY] == nil)
    Send(BOB, Msg("K", now, 1023, 1023, 30, hash, "rank=0"))
    Expect("rank claimed in message content ignored (config still rejected)", ns.db.perms[KEY] == nil)

    Send(ALICE, R({ created = now, rand = 3001 }))
    Send(ALICE, R({ created = now, rand = 3002 }))
    local id1, id2 = ("%s:%d:%d"):format(ALICE, now, 3001), ("%s:%d:%d"):format(ALICE, now, 3002)
    Send(BOB, Msg("C", ALICE, now, 3002, "WARRIOR", 2, now, 0))
    Send(BOB, Msg("MD", ALICE, now, 3001, now))
    Expect("request removal from a non-moderator rejected", not (W:Get(id1) or {}).deleted)
    Send(BOB, Msg("MD", ALICE, now, 3001, now, 0))
    Expect("moderator rank claimed in message content ignored", not (W:Get(id1) or {}).deleted)
    Send(ALICE, Msg("MC", ALICE, now, 3002, BOB, now))
    Expect("claim clear from a rank the leader didn't allow rejected", W:ClaimedTotal(id2) == 2)

    -- Control: the guild leader allows rank 1 (Alice, and you in this test) to moderate.
    Send(LEADER, Msg("K", now, 3, 3, 30, hash))
    Expect("rank config from the guild leader accepted", ns.db.perms[KEY] and ns.db.perms[KEY].mod == 3)
    Send(ALICE, Msg("MC", ALICE, now, 3002, BOB, now + 1))
    Expect("claim clear from an allowed moderator rank accepted", W:ClaimedTotal(id2) == 0)
    Send(LEADER, Msg("MD", ALICE, now, 3001, now + 1))
    Expect("request removal by the guild leader accepted", (W:Get(id1) or {}).deleted == true)
    Expect("moderator action shows in the Guild log", ns.GuildLog:Get("M:D:" .. id1) ~= nil)

    local before = Comm.stats.accepted
    Send(BOB, Msg("L", ALICE, "Confirmed", 99))
    Expect("log entry message about another player dropped (no such message exists)", Comm.stats.accepted == before)
    local officerId = "O:D:" .. id1
    Send(BOB, Msg("OM", "D", ALICE, now, 3001, "", now, "fake reason"), "WHISPER")
    Expect("officer note from a non-moderator rejected", ns.GuildLog:GetOfficer(officerId) == nil)
    Send(LEADER, Msg("OM", "D", ALICE, now, 3001, "", now, "on guild"), "GUILD")
    Expect("officer data sent on the GUILD channel rejected", ns.GuildLog:GetOfficer(officerId) == nil)
    Send(MALLORY, Msg("OM", "D", ALICE, now, 3001, "", now, "outsider"), "WHISPER")
    Expect("whisper from a non-guildie rejected", ns.GuildLog:GetOfficer(officerId) == nil)
    Send(LEADER, Msg("OM", "D", ALICE, now, 3001, "", now, "duplicate item spam"), "WHISPER")
    local note = ns.GuildLog:GetOfficer(officerId)
    Expect("officer note from the guild leader by whisper accepted", note and note.reason == "duplicate item spam")

    -- Unknown types and floods
    before = Comm.stats.accepted
    Send(ALICE, Msg("ZZ", "boom"))
    Expect("unknown message type dropped", Comm.stats.accepted == before)
    before = Comm.stats.accepted
    -- (an invalid claim: it reaches the handler, which ignores it, so nothing else reacts)
    for _ = 1, 100 do Send(BOB, Msg("C", "x")) end
    local got = Comm.stats.accepted - before
    Expect(("flood of 100 messages rate-limited (%d let through)"):format(got), got <= 60)

    return results
end

local function SecurityTest()
    if not ns.db.settings.debug then
        ns:Print("securitytest is a developer check. Turn it on with /tavern debug on.")
        return
    end
    Wipe()
    ns.testGuildKey = KEY
    -- You are rank 1 here too, so the officer-log checks have someone allowed to read it.
    Comm:TestBegin({ [ALICE] = 1, [BOB] = 2, [LEADER] = 0, [ns:PlayerName()] = 1 })
    local ok, results = pcall(Run)
    local suppressed = Comm:TestEnd()
    ns.testGuildKey = nil
    Wipe()
    ns:Fire("WISHLIST_CHANGED", nil, "remote")
    ns:Fire("GUILD_CHANGED", ns:GuildKey())

    if not ok then
        ns:Print("|cffff4040securitytest crashed:|r " .. ns:CleanText(tostring(results), 200))
        return
    end
    local passed = 0
    ns:Print("Security test (nothing is sent; test data deleted afterwards):")
    for _, r in ipairs(results) do
        if r.ok then passed = passed + 1 end
        DEFAULT_CHAT_FRAME:AddMessage(("  %s  %s"):format(r.ok and "|cff40ff40PASS|r" or "|cffff4040FAIL|r", r.label))
    end
    DEFAULT_CHAT_FRAME:AddMessage(("  %d of %d passed. Messages sent: 0 (%d outgoing swallowed by the test)."):format(
        passed, #results, suppressed))
end

ns:RegisterCommand("securitytest", SecurityTest, "developer check: feed forged messages to the addon (needs /tavern debug on)")
ns:RegisterCommand("debug", function(arg)
    arg = (arg or ""):lower()
    if arg == "on" or arg == "off" then ns.db.settings.debug = (arg == "on") end
    ns:Print("Debug mode is " .. (ns.db.settings.debug and "on" or "off") .. ". (/tavern debug on|off)")
end, "developer options on/off")
