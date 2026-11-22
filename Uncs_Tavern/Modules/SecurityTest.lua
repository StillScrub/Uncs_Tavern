-- Modules\SecurityTest.lua: /tavern securitytest (developer check, off by default).
--
--   /tavern debug on      enables it (ns.db.settings.debug)
--   /tavern securitytest  feeds forged and malformed messages into our own receive
--                         path and prints which were rejected.
--
-- Nothing is sent while it runs: Comm swallows every outgoing message (and counts
-- them), the guild roster is a fake one (Alice Test, Bob Test, Carl Test, Lea Der as guild leader), and all data goes to a
-- throwaway guild key that is deleted afterwards. Your real guild's data isn't touched.
local _, ns = ...
local W, Comm = ns.Wishlist, ns.Comm

local KEY = "SecurityTest@local"
local ALICE, BOB, CARL, MALLORY = "Alice Test", "Bob Test", "Carl Test", "Mallory Evil"
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
    ns.db.kos[KEY] = nil
    ns.db.kosMod[KEY] = nil
    ns.db.pvpWeek[KEY] = nil
    if ns.db.mailSent then ns.db.mailSent[KEY] = nil end
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

    -- Mailbox: a sent mail becomes my claim only on the recipient's own requests,
    -- only for matching items, never more than still needed. (Nothing is mailed here.)
    if ns.Mail and ns.Mail.TestSent then
        Send(ALICE, R({ created = now, rand = 4001, qty = 5 }))
        local mailReq = ("%s:%d:%d"):format(ALICE, now, 4001)
        ns.Mail:TestSent(BOB, { { itemID = ITEM, count = 5 } })
        Expect("mail to someone else doesn't claim the request", W:MyClaim(mailReq) == nil)
        ns.Mail:TestSent(ALICE, { { itemID = 2592, count = 5 } }) -- Wool Cloth, not Linen
        Expect("mail with a different item doesn't claim the request", W:MyClaim(mailReq) == nil)
        ns.Mail:TestSent(ALICE, { { itemID = ITEM, count = 99 } })
        local mc = W:MyClaim(mailReq)
        Expect(("mail to the requester claims at most what's needed (claimed %s of 5)"):format(mc and mc.qty or 0),
            mc and mc.qty == 5)
        ns.db.mailSent = ns.db.mailSent or {}
        ns.db.mailSent[KEY] = { bad1 = { n = -4, by = ALICE, t = 1 }, bad2 = { n = 2, by = "|cffff0000x|r", t = 1 },
                                ok = { n = 2, by = ALICE, t = 1 } }
        ns.Mail:CleanSent()
        local ms = ns.db.mailSent[KEY] or {}
        Expect("malformed saved \"already sent\" records dropped", ms.bad1 == nil and ms.bad2 == nil and ms.ok ~= nil)
    end

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

    -- Kill on Sight: 2|KS|target|class|level|guild|rc|reason|t|deleted|updated
    if ns.KOS then
        local K = ns.KOS
        local function KS(target, o)
            o = o or {}
            return Msg("KS", target, o.class or "ROGUE", o.level or 35, o.guild or "", o.rc or 1, o.reason or "",
                o.t or now, o.deleted or 0, o.updated or now)
        end
        local function Kos(adder, target) local b = ns.db.kos[KEY] return b and b[adder .. "#" .. target] end
        Send(ALICE, KS("Enemy One"))
        Expect("valid Kill on Sight entry from its adder accepted", Kos(ALICE, "Enemy One") ~= nil and K:IsKOS("Enemy One"))
        Send(ALICE, KS(BOB))
        Expect("guild member can't be put on Kill on Sight", Kos(ALICE, BOB) == nil)
        Send(ALICE, KS(ALICE))
        Expect("putting yourself on Kill on Sight rejected", Kos(ALICE, ALICE) == nil)
        Send(ALICE, KS("Enemy Two", { level = 999 }))
        Expect("Kill on Sight level 999 rejected", Kos(ALICE, "Enemy Two") == nil)
        Send(ALICE, KS("Enemy Three", { class = "HACKER" }))
        Expect("Kill on Sight unknown class rejected", Kos(ALICE, "Enemy Three") == nil)
        Send(ALICE, KS("Enemy Four", { rc = 99 }))
        Expect("Kill on Sight unknown reason preset rejected", Kos(ALICE, "Enemy Four") == nil)
        Send(ALICE, KS("Enemy Five", { t = now + 86400 * 30, updated = now + 86400 * 30 }))
        Expect("Kill on Sight timestamp in the future rejected", Kos(ALICE, "Enemy Five") == nil)
        Send(ALICE, KS("Enemy Six", { rc = 0, reason = string.rep("x", 150) }))
        local six = Kos(ALICE, "Enemy Six")
        Expect("Kill on Sight reason cut to " .. K.MAX_REASON .. " characters", six and #(six.reason or "") <= K.MAX_REASON)
        K:Merge(ALICE, "Enemy Seven", "ROGUE", 30, "|cffff0000Evil|r", 0, "|Hitem:19019|h[Thunderfury]|h %s", now, 0, now)
        local seven = Kos(ALICE, "Enemy Seven")
        Expect("escape codes stripped from Kill on Sight reason and guild",
            seven and not (seven.reason or ""):find("|", 1, true) and not (seven.guild or ""):find("|", 1, true))
        Send(BOB, KS("Enemy One", { deleted = 1, updated = now + 5 }))
        Expect("someone else can't remove your Kill on Sight entry", K:IsKOS("Enemy One")
            and not (Kos(ALICE, "Enemy One") or {}).deleted)
        Send(ALICE, KS("Enemy One", { deleted = 1, updated = now + 5 }))
        Expect("adder can remove their own Kill on Sight entry", (Kos(ALICE, "Enemy One") or {}).deleted == true)
        local kosAccepted = 0
        for i = 1, K.MAX_PER_PLAYER + 1 do
            if K:Merge(BOB, "Target " .. i, "MAGE", 30, "", 1, "", now, 0, now) then kosAccepted = kosAccepted + 1 end
        end
        Expect(("max %d Kill on Sight entries per player (accepted %d of %d)"):format(K.MAX_PER_PLAYER, kosAccepted,
            K.MAX_PER_PLAYER + 1), kosAccepted == K.MAX_PER_PLAYER)
        Send(MALLORY, KS("Enemy Eight"))
        Expect("Kill on Sight entry from a non-guildie rejected", Kos(MALLORY, "Enemy Eight") == nil)

        -- Moderators (KOSMod.lua): 2|KR|target|at, 2|KA|adder|target|at. Here rank 0-1
        -- may moderate (Lea Der, Alice), Bob and Carl may not.
        local function KSA(target, t) -- with the "added" field
            return Msg("KS", target, "ROGUE", 35, "", 1, "", t, 0, t, t)
        end
        Send(ALICE, KSA("Enemy Nine", now))
        Send(BOB, Msg("KR", "Enemy Nine", now + 1))
        Expect("Kill on Sight removal from a non-moderator rejected", K:IsKOS("Enemy Nine"))
        Send(BOB, Msg("KR", "Enemy Nine", now + 1, "rank=0"))
        Expect("moderator rank claimed in a Kill on Sight removal ignored", K:IsKOS("Enemy Nine"))
        Send(ALICE, Msg("KR", "Enemy Nine", now + 1))
        Expect("Kill on Sight removal by a moderator accepted", not K:IsKOS("Enemy Nine"))
        Expect("Kill on Sight removal shows in the Guild log", ns.GuildLog:Get("K:Enemy Nine:" .. (now + 1)) ~= nil)
        Send(ALICE, KSA("Enemy Nine", now + 2))
        Expect("adding them again after a removal is a new entry", K:IsKOS("Enemy Nine"))
        local rejectedBefore = ns.KOSMod.rejected
        Send(ALICE, Msg("KR", BOB, now + 1))
        Expect("Kill on Sight removal naming a guild member rejected", ns.KOSMod.rejected > rejectedBefore)

        -- Approval on (leader's flag): Carl's entries wait, a moderator approves.
        Send(LEADER, Msg("K", now + 2, 3, 3, 30, hash, 1))
        Expect("approval switch from the guild leader accepted", ns.KOSMod:ApprovalOn())
        Send(BOB, Msg("K", now + 3, 3, 3, 30, hash, 0))
        Expect("approval switch from a non-leader rejected", ns.KOSMod:ApprovalOn())
        Send(CARL, KSA("Enemy Ten", now))
        Expect("entry from a non-moderator waits for approval", not K:IsKOS("Enemy Ten") and K:PendingEntries("Enemy Ten") ~= nil)
        Send(CARL, Msg("KA", CARL, "Enemy Ten", now + 1))
        Expect("approving your own entry rejected (not a moderator)", not K:IsKOS("Enemy Ten"))
        Send(ALICE, Msg("KA", CARL, "Enemy Ten", now + 1))
        Expect("approval by a moderator accepted", K:IsKOS("Enemy Ten"))
        Send(ALICE, KSA("Enemy Eleven", now))
        Expect("a moderator's own entry needs no approval", K:IsKOS("Enemy Eleven"))

        -- Sightings (Sightings.lua): 2|KV|target|level|zone. Shown only for enemies on our list.
        if ns.Sightings then
            local SG = ns.Sightings
            local sgBefore = SG.rejected
            Send(BOB, Msg("KV", "Enemy Eleven", 999, "Somewhere"))
            Expect("sighting with level 999 rejected", SG.rejected > sgBefore)
            Expect("sighting of a player not on the list ignored", SG:Receive(BOB, "Random Person", 30, "Somewhere") == nil)
            Expect("sighting with no zone rejected", SG:Receive(BOB, "Enemy Eleven", 30, "   ") == nil
                and SG:Receive(BOB, "Enemy Eleven", 30, nil) == nil)
            local wasShow = ns.db.settings.kosSightShow
            ns.db.settings.kosSightShow = true
            Expect("valid sighting of a listed enemy shown (escape codes stripped)",
                SG:Receive(BOB, "Enemy Eleven", 30, "|cffff0000Booty|r |Hitem:1|hBay|h") == "guild")
            ns.db.settings.kosSightShow = wasShow
        end
    end

    -- Weekly leaderboard (PvPWeek.lua): 2|PW|week|kills|deaths|best
    if ns.PvPWeek then
        local week = ns.PvPWeek:Id()
        local function WeekRec(name) return ns.db.pvpWeek[KEY] and ns.db.pvpWeek[KEY][name] end
        Send(ALICE, Msg("PW", week, -3, 0, 0))
        Expect("negative weekly kills rejected", WeekRec(ALICE) == nil)
        Send(ALICE, Msg("PW", week, 5, 1, 9))
        Expect("best streak above the week's kills rejected", WeekRec(ALICE) == nil)
        Send(ALICE, Msg("PW", week, 999999999, 0, 0))
        Expect("impossible weekly kills rejected", WeekRec(ALICE) == nil)
        Send(ALICE, Msg("PW", week - 604800, 5, 1, 3))
        Expect("numbers from another week ignored", WeekRec(ALICE) == nil)
        Send(ALICE, Msg("PW", week, 12, 3, 5))
        Expect("valid weekly numbers accepted (stored under the sender only)", (WeekRec(ALICE) or {}).k == 12)
    end

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
    Comm:TestBegin({ [ALICE] = 1, [BOB] = 2, [CARL] = 2, [LEADER] = 0, [ns:PlayerName()] = 1 })
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
