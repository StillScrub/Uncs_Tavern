-- Modules\Mail.lua: the mailbox "Guild Requests" panel (SPEC section 5).
--
-- A panel docked to the right edge of the mail window (our own frame; nothing is added
-- to Blizzard's mail window or its tabs) listing other players' open guild requests you
-- can fill from your bags. Its X closes it; a small mug button on the mail window's
-- edge (shown only while the panel is closed) opens it again. Remembered per character.
--
-- "Fill Send Mail" pre-fills Blizzard's Send Mail form for the selected request. The
-- addon never sends mail: the player checks the form and presses Blizzard's Send.
--
-- Event-driven: refreshed on mailbox, bag and wishlist events while the panel shows
-- (coalesced into one refresh per burst), never on a timer.
local _, ns = ...
local W = ns.Wishlist

local Mail = {}
ns.Mail = Mail

local WIDTH      = 360
local ROW_HEIGHT = 38
local REFRESH_DELAY = 0.2 -- bag events come in bursts: one refresh per burst

local panel, toggle, scrollBox
local selectedId
local refreshPending = false
local currentList = {} -- what the panel shows now
local filling = false  -- a Fill is in progress

local function Prefs()
    ns.charDB.mail = type(ns.charDB.mail) == "table" and ns.charDB.mail or { hidden = false }
    return ns.charDB.mail
end

local function ClassColor(classFile)
    local c = classFile and C_ClassColor and C_ClassColor.GetClassColor(classFile)
    return c or HIGHLIGHT_FONT_COLOR
end

local function QualityColor(quality)
    local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return c and c.color or c or HIGHLIGHT_FONT_COLOR
end

---------------------------------------------------------------------------
-- Elsewhere (optional): if the player runs Syndicator (bundled with Baganator), its
-- public API tells how many of an item sit in my bank and mail and on my other
-- characters (as of when each was last logged in). Read only, never required, never
-- sent anywhere. Item requests only (Syndicator counts exact items, not rules).
-- Syndicator counts soulbound copies too, so these numbers are a guide.
---------------------------------------------------------------------------
local function SynAPI()
    local api = Syndicator and Syndicator.API
    if not api or not api.GetInventoryInfoByItemID or not api.IsReady then return nil end
    local ok, ready = pcall(api.IsReady)
    return ok and ready and api or nil
end

-- Returns bank (my bank + mail), alts total, alts list { { name, class, n }, ... }.
local function Elsewhere(api, itemID)
    local ok, info = pcall(api.GetInventoryInfoByItemID, itemID, true, true)
    if not ok or type(info) ~= "table" or type(info.characters) ~= "table" then return 0, 0, {} end
    local okMe, me = pcall(api.GetCurrentCharacter)
    me = okMe and me or nil
    local bank, altTotal, alts = 0, 0, {}
    for _, ch in ipairs(info.characters) do
        local key = tostring(ch.character) .. ((ch.realmNormalized and ch.realmNormalized ~= "") and ("-" .. ch.realmNormalized) or "")
        local b, k, m = tonumber(ch.bags) or 0, tonumber(ch.bank) or 0, tonumber(ch.mail) or 0
        if key == me then
            bank = bank + k + m -- my bags are counted live, from the bags themselves
        elseif b + k + m > 0 then
            altTotal = altTotal + b + k + m
            alts[#alts + 1] = { name = tostring(ch.character), class = ns:ValidClass(ch.className), n = b + k + m,
                                bags = b, bank = k, mail = m }
        end
    end
    table.sort(alts, function(a, b) return a.n > b.n end)
    return bank, altTotal, alts
end

---------------------------------------------------------------------------
-- Mail I already sent (any of my characters: account-wide, per guild), so the panel can
-- grey those requests out and nobody on this account sends twice by mistake.
--   ns.db.mailSent[guildKey][reqId] = { n = items sent, by = character, t = time }
-- Local only; forgotten once the requester confirms receipt, the request closes, or after
-- SENT_DAYS.
---------------------------------------------------------------------------
local SENT_DAYS = 30

local function SentStore()
    local key = ns:GuildKey()
    if not key or not ns.db then return nil end
    ns.db.mailSent = type(ns.db.mailSent) == "table" and ns.db.mailSent or {}
    ns.db.mailSent[key] = type(ns.db.mailSent[key]) == "table" and ns.db.mailSent[key] or {}
    return ns.db.mailSent[key]
end

-- How many of my sent items the requester has confirmed since I sent them. `base` =
-- what they had already confirmed from me before (earlier mails to the same request).
local function Confirmed(rec, req)
    local delivered = req and req.receivedFrom and req.receivedFrom[rec.by] or 0
    return math.max(0, delivered - (rec.base or delivered))
end

local function NoteSent(req, n)
    local store = SentStore()
    if not store then return end
    local me = ns:PlayerName()
    local cur = store[req.id]
    if cur and cur.by == me then
        -- Another mail to the same request: drop what they've confirmed already.
        local open = math.max(0, cur.n - Confirmed(cur, req))
        local delivered = req.receivedFrom and req.receivedFrom[me] or 0
        store[req.id] = { n = math.min(W.MAX_QTY, open + n), by = me, t = time(), base = delivered }
    else
        local delivered = req.receivedFrom and req.receivedFrom[me] or 0
        store[req.id] = { n = math.min(W.MAX_QTY, n), by = me, t = time(), base = delivered }
    end
end

-- Forget entries for requests that are closed, gone or old.
local function PruneSent()
    local store = SentStore()
    if not store then return end
    local cutoff = time() - SENT_DAYS * 86400
    for id, rec in pairs(store) do
        local req = W:Get(id)
        -- closed, old, or the requester has confirmed receiving all of it since (then
        -- only what's still needed shows, as a normal row)
        if not W:IsOpen(req) or (rec.t or 0) < cutoff or not rec.base or Confirmed(rec, req) >= rec.n then
            store[id] = nil
        end
    end
end

ns:RegisterCallback("VALIDATE_DB", function()
    local all = ns.db.mailSent
    if type(all) ~= "table" then ns.db.mailSent = nil return end
    for key, store in pairs(all) do
        if type(key) ~= "string" or type(store) ~= "table" then
            all[key] = nil
        else
            for id, rec in pairs(store) do
                if type(id) ~= "string" or type(rec) ~= "table" or not ns:Int(rec.n, 1, W.MAX_QTY)
                    or not ns:ValidName(rec.by) or type(rec.t) ~= "number"
                    or (rec.base ~= nil and not ns:Int(rec.base, 0, W.MAX_QTY)) then
                    store[id] = nil
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- What my bags can fill
---------------------------------------------------------------------------
-- Returns a list of
--   { req, need, have, mine, slots = { { bag, slot, count, link }, ... }, link }
-- for other players' open requests that my unbound bag items fit, sorted: requests I
-- can fill completely first, then oldest first.
--   need = still wanted (quantity minus received)
--   have = how many of my bag items fit (a rule takes one item per match)
--   mine = my active claim on it (Fill will use that amount), or nil
--   bank, altTotal, alts = elsewhere counts (only with Syndicator, item requests only)
-- With Syndicator, requests I can't fill from my bags but could from my bank or alts
-- are listed too (have = 0, sorted last), so I know what to fetch.
function Mail:Fillable()
    local out = {}
    if not ns:GuildKey() then return out end
    local reqs = {}
    for _, req in ipairs(W:List("all")) do
        if not W:IsMine(req) then reqs[#reqs + 1] = req end
    end
    if #reqs == 0 then return out end

    local byId = {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                for _, req in ipairs(reqs) do
                    local fits
                    if req.rule then
                        fits = W:MatchesRule(req.rule, info.hyperlink) == true
                    else
                        fits = req.itemID == info.itemID
                    end
                    if fits then
                        local e = byId[req.id]
                        if not e then
                            e = { req = req, have = 0, slots = {}, link = info.hyperlink }
                            byId[req.id] = e
                            out[#out + 1] = e
                        end
                        local count = req.rule and 1 or (info.stackCount or 1)
                        e.have = e.have + count
                        e.slots[#e.slots + 1] = { bag = bag, slot = slot, count = count, link = info.hyperlink }
                    end
                end
            end
        end
    end

    local api = SynAPI()
    if api then
        for _, req in ipairs(reqs) do
            if req.itemID and not byId[req.id] then
                local e = { req = req, have = 0, slots = {} }
                e.bank, e.altTotal, e.alts = Elsewhere(api, req.itemID)
                if e.bank + e.altTotal > 0 then
                    byId[req.id] = e
                    out[#out + 1] = e
                end
            elseif req.itemID then
                local e = byId[req.id]
                e.bank, e.altTotal, e.alts = Elsewhere(api, req.itemID)
            end
        end
    end

    local sentStore = SentStore() or {}
    for _, e in ipairs(out) do
        e.sent = sentStore[e.req.id]
        e.need = e.req.qty - (e.req.received or 0)
        local sentN = e.sent and math.max(0, e.sent.n - Confirmed(e.sent, e.req)) or 0 -- not yet confirmed
        e.left = math.max(0, e.need - sentN)       -- still needed after mail I already sent
        e.sentAll = e.sent ~= nil and e.left == 0  -- my mail covers everything: greyed out
        local claim = W:MyClaim(e.req.id)
        local mine = claim and W:ClaimOutstanding(claim) or 0
        mine = math.max(0, mine - sentN)           -- the part of my claim not sent yet
        e.mine = mine > 0 and mine or nil
        e.complete = not e.sentAll and e.have >= (e.mine or e.left)
        -- Who else is sending (their claims minus what they already delivered).
        e.senders = {}
        for _, c in ipairs(W:ClaimsFor(e.req.id)) do
            local left = W:ClaimOutstanding(c)
            if c.claimer ~= ns:PlayerName() and left > 0 then
                e.senders[#e.senders + 1] = { name = c.claimer, class = c.class, n = left }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.sentAll ~= b.sentAll then return b.sentAll end -- fully sent already: last
        if a.complete ~= b.complete then return a.complete end
        if (a.have > 0) ~= (b.have > 0) then return a.have > 0 end -- bags before bank/alts only
        return a.req.created < b.req.created
    end)
    return out
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function RowOnEnter(row)
    local e = row.data
    if not e then return end
    local req = e.req
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if req.rule then
        GameTooltip:AddLine("Any item matching:", 1, 0.82, 0)
        GameTooltip:AddLine(W:RuleText(req.rule), 1, 1, 1)
    else
        local name, _, quality = C_Item.GetItemInfo(req.itemID)
        local qc = QualityColor(quality)
        GameTooltip:AddLine(name or ("item:" .. req.itemID), qc.r, qc.g, qc.b)
    end
    local c = ClassColor(req.class)
    GameTooltip:AddDoubleLine("Requested by", req.requester, 1, 0.82, 0, c.r, c.g, c.b)
    if e.sent then
        local by = e.sent.by == ns:PlayerName() and "you" or Ambiguate(e.sent.by, "guild")
        GameTooltip:AddLine(("Mail already sent by %s: %d (%s)"):format(by, e.sent.n, date("%b %d %H:%M", e.sent.t)),
            0.25, 1, 0.25, true)
        GameTooltip:AddLine("It stays listed until they open the mail.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:AddDoubleLine("Still needed", tostring(e.left), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("In your bags", tostring(e.have), 1, 0.82, 0, 1, 1, 1)
    if e.bank and e.bank > 0 then
        GameTooltip:AddDoubleLine("In your bank / mail", tostring(e.bank), 1, 0.82, 0, 1, 1, 1)
    end
    if e.alts and #e.alts > 0 then
        GameTooltip:AddLine("On your other characters:", 1, 0.82, 0)
        for i, a in ipairs(e.alts) do
            if i > 6 then GameTooltip:AddLine(("  +%d more"):format(#e.alts - 6), 0.6, 0.6, 0.6) break end
            local ac = ClassColor(a.class)
            local where = {}
            if a.bags > 0 then where[#where + 1] = "bags " .. a.bags end
            if a.bank > 0 then where[#where + 1] = "bank " .. a.bank end
            if a.mail > 0 then where[#where + 1] = "mail " .. a.mail end
            GameTooltip:AddDoubleLine("  " .. a.name, table.concat(where, ", "), ac.r, ac.g, ac.b, 1, 1, 1)
        end
    end
    if e.have == 0 then GameTooltip:AddLine("Fetch some into your bags to fill this one.", 0.6, 0.6, 0.6, true) end
    if e.mine then GameTooltip:AddDoubleLine("Your claim", tostring(e.mine), 1, 0.82, 0, 1, 1, 1) end
    if #e.senders > 0 then
        GameTooltip:AddLine("Already being sent by:", 1, 0.82, 0)
        for _, sd in ipairs(e.senders) do
            local sc = ClassColor(sd.class)
            GameTooltip:AddDoubleLine("  " .. Ambiguate(sd.name, "guild"), tostring(sd.n), sc.r, sc.g, sc.b, 1, 1, 1)
        end
    end
    GameTooltip:AddDoubleLine("Payment", W:PriceText(req.price) .. (req.price > 0 and " each" or ""),
        1, 0.82, 0, 1, 1, 1)
    if req.note and req.note ~= "" then GameTooltip:AddDoubleLine("Note", req.note, 1, 0.82, 0, 1, 1, 1) end
    GameTooltip:Show()
end

local function IconOnEnter(icon)
    local e = icon:GetParent().data
    if not e then return end
    GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(e.link or ("item:" .. tostring(e.req.itemID)))
    GameTooltip:Show()
end

local function InitRow(row, e)
    if not row.icon then
        row:SetHeight(ROW_HEIGHT)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.sel = row:CreateTexture(nil, "BACKGROUND")
        row.sel:SetAllPoints()
        row.sel:SetColorTexture(1, 0.82, 0, 0.18)

        local iconBtn = CreateFrame("Frame", nil, row)
        iconBtn:SetSize(ROW_HEIGHT - 6, ROW_HEIGHT - 6)
        iconBtn:SetPoint("LEFT", 3, 0)
        iconBtn:EnableMouse(true)
        iconBtn:SetScript("OnEnter", IconOnEnter)
        iconBtn:SetScript("OnLeave", GameTooltip_Hide)
        row.icon = iconBtn:CreateTexture(nil, "ARTWORK")
        row.icon:SetAllPoints()
        row.iconBtn = iconBtn

        row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", iconBtn, "TOPRIGHT", 6, -2)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.sub = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.sub:SetPoint("BOTTOMLEFT", iconBtn, "BOTTOMRIGHT", 6, 2)
        row.sub:SetJustifyH("LEFT")
        row.sub:SetWordWrap(false)

        row.counts = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.counts:SetPoint("TOPRIGHT", row, "TOPRIGHT", -4, -5)
        row.counts:SetJustifyH("RIGHT")
        row.pay = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.pay:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -4, 5)
        row.pay:SetJustifyH("RIGHT")
        -- Each left text runs up to the text on its right (no fixed cut-off).
        row.name:SetPoint("RIGHT", row.counts, "LEFT", -6, 0)
        row.sub:SetPoint("RIGHT", row.pay, "LEFT", -6, 0)

        row:SetScript("OnEnter", RowOnEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:SetScript("OnClick", function(self)
            selectedId = self.data and self.data.req.id
            scrollBox:ForEachFrame(function(r) r.sel:SetShown(r.data and r.data.req.id == selectedId) end)
            Mail:UpdateButton()
        end)
    end
    row.data = e
    local req = e.req
    if req.rule then
        row.icon:SetTexture(C_Item.GetItemIconByID(e.link) or 134400)
        row.name:SetText(W:RuleText(req.rule))
        row.name:SetTextColor(1, 0.82, 0)
    else
        row.icon:SetTexture(select(5, C_Item.GetItemInfoInstant(req.itemID)) or C_Item.GetItemIconByID(req.itemID))
        local name, _, quality = C_Item.GetItemInfo(req.itemID)
        local qc = QualityColor(quality)
        row.name:SetText(name or ("item " .. req.itemID))
        row.name:SetTextColor(qc.r, qc.g, qc.b)
    end
    local c = ClassColor(req.class)
    row:SetAlpha(e.sentAll and 0.5 or 1) -- everything still needed already sent: greyed out
    local extra = {}
    if e.bank and e.bank > 0 then extra[#extra + 1] = "bank " .. e.bank end
    if e.altTotal and e.altTotal > 0 then extra[#extra + 1] = "alts " .. e.altTotal end
    if #e.senders > 0 then
        local first = Ambiguate(e.senders[1].name, "guild")
        extra[#extra + 1] = "sent by " .. first .. (#e.senders > 1 and (" +" .. (#e.senders - 1)) or "")
    end
    local sentBy = e.sent and (e.sent.by == ns:PlayerName() and "you" or Ambiguate(e.sent.by, "guild"))
    if e.sentAll then
        row.sub:SetText(("for %s  |cff40ff40Mail sent by %s (%d)|r"):format(
            c:WrapTextInColorCode(Ambiguate(req.requester, "guild")), sentBy, e.sent.n))
    else
        if e.sent then table.insert(extra, 1, ("|cff40ff40%s sent %d|r|cff999999"):format(sentBy, e.sent.n)) end
        row.sub:SetText(("for %s%s"):format(c:WrapTextInColorCode(Ambiguate(req.requester, "guild")),
            #extra > 0 and ("  |cff999999" .. table.concat(extra, " · ") .. "|r") or ""))
    end
    local wanted = e.mine and ("claim %d"):format(e.mine) or ("needs %d"):format(e.left)
    local haveColor = e.complete and "|cff40ff40" or (e.have > 0 and "|cffffd100" or "|cff999999")
    row.counts:SetText(("%s · %shave %d|r"):format(wanted, haveColor, e.have))
    row.pay:SetText(W:PriceText(req.price) .. (req.price > 0 and " ea" or ""))
    row.sel:SetShown(req.id == selectedId)
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
local function Refresh()
    refreshPending = false
    if not panel or not panel:IsVisible() then return end
    PruneSent()
    local list = Mail:Fillable()
    local found = false
    for _, e in ipairs(list) do
        if e.req.id == selectedId then found = true break end
    end
    if not found then selectedId = nil end
    currentList = list
    scrollBox:SetDataProvider(CreateDataProvider(list), ScrollBoxConstants.RetainScrollPosition)

    local msg
    if not ns.Comm:IsSharing("wishlist") then
        msg = "Wishlist sharing is off, so no guild requests are shown.\nTurn it on in Settings > Sharing."
    elseif #list == 0 then
        msg = SynAPI() and "Nothing in your bags, bank or other characters fits an open guild request right now."
            or "Nothing in your bags fits an open guild request right now."
    end
    panel.empty:SetText(msg or "")
    panel.empty:SetShown(msg ~= nil)
    local complete = 0
    for _, e in ipairs(list) do if e.complete then complete = complete + 1 end end
    panel.count:SetText(#list == 0 and "" or ("%d request%s you can help with (%d in full)"):format(
        #list, #list == 1 and "" or "s", complete))
    Mail:UpdateButton()
end

local function QueueRefresh()
    if refreshPending or not panel or not panel:IsVisible() then return end
    refreshPending = true
    C_Timer.After(REFRESH_DELAY, Refresh)
end
Mail.Refresh = QueueRefresh

---------------------------------------------------------------------------
-- Fill Send Mail
--   Puts the requester, a subject and the items into Blizzard's Send Mail form. The
--   player checks it and presses Blizzard's Send; we never call SendMail.
--   Attachments point at a bag slot (the whole stack in it), so a part stack is first
--   split into an empty slot in a normal bag, and we wait for the server to finish
--   (bag/lock events, not a timer) before attaching it. Whole stacks are attached as
--   they are. One split at most per Fill. Only works from a click (the button).
--   No COD while COD mail is broken on the server (see PAY_DISABLED in Wishlist.lua):
--   the price shows in the panel as text only.
---------------------------------------------------------------------------
local MAX_ATTACH = ATTACHMENTS_MAX_SEND or 12
local SUBJECT_MAX = 64

local function Selected()
    for _, e in ipairs(currentList) do
        if e.req.id == selectedId then return e end
    end
end

local function SendMailOpen()
    return SendMailFrame and SendMailFrame:IsVisible()
end

local function NameBox() return SendMailNameEditBox or (SendMailFrame and SendMailFrame.SendMailNameEditBox) end
local function SubjectBox() return SendMailSubjectEditBox or (SendMailFrame and SendMailFrame.SendMailSubjectEditBox) end

local function AttachedCount()
    local n = 0
    for i = 1, MAX_ATTACH do
        if GetSendMailItem(i) then n = n + 1 end
    end
    return n
end

local function FreeAttachSlot()
    for i = 1, MAX_ATTACH do
        if not GetSendMailItem(i) then return i end
    end
end

-- An empty slot in a normal bag (not a profession bag), or nil.
local function FindEmpty()
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local free, family = C_Container.GetContainerNumFreeSlots(bag)
        if (free or 0) > 0 and (family or 0) == 0 then
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
            end
        end
    end
end

-- Calls done(ok) once test() is true (checked on bag/lock/mail events), or done(false)
-- after timeout seconds.
local waitFrame = CreateFrame("Frame")
local function WaitFor(test, timeout, done)
    local finished = false
    local function finish(ok)
        if finished then return end
        finished = true
        waitFrame:UnregisterAllEvents()
        waitFrame:SetScript("OnEvent", nil)
        done(ok)
    end
    if test() then finish(true) return end
    waitFrame:RegisterEvent("BAG_UPDATE_DELAYED")
    waitFrame:RegisterEvent("ITEM_LOCK_CHANGED")
    waitFrame:RegisterEvent("MAIL_SEND_INFO_UPDATE")
    waitFrame:SetScript("OnEvent", function()
        if test() then finish(true) return end
        C_Timer.After(0.1, function() if not finished and test() then finish(true) end end)
    end)
    C_Timer.After(timeout, function() finish(test()) end)
end

local function Status(text, r, g, b)
    if not panel then return end
    panel.status:SetText(text or "")
    panel.status:SetTextColor(r or 1, g or 0.82, b or 0)
end

-- How many Fill will put in: my claim if I have one, else what's still unclaimed;
-- never more than my bags hold. When others have claimed everything still needed,
-- "anyway" = true and it uses what's still needed (the player chose to send anyway).
local function Amount(e)
    if e.left <= 0 then return 0, false end -- my mail already covers it
    local others = 0
    for _, sd in ipairs(e.senders) do others = others + sd.n end
    local want = e.mine or (e.left - others)
    if want <= 0 then return math.min(e.left, e.have), true end
    return math.min(want, e.left, e.have), false
end

-- Picks bag slots for `amount` items: an exact-size stack if there is one, else whole
-- stacks (largest first) and at most one part stack to split.
-- Returns plan = { whole = { slot... }, split = { bag, slot, n } | nil }, and how many
-- couldn't be planned (normally 0).
local function Plan(e, amount)
    local slots = {}
    for _, sl in ipairs(e.slots) do
        local info = C_Container.GetContainerItemInfo(sl.bag, sl.slot)
        if info and not info.isLocked and not info.isBound then
            local count = e.req.rule and 1 or (info.stackCount or 1)
            slots[#slots + 1] = { bag = sl.bag, slot = sl.slot, count = count }
        end
    end
    table.sort(slots, function(a, b) return a.count > b.count end)
    local plan, left = { whole = {} }, amount
    for _, sl in ipairs(slots) do
        if sl.count == left then
            plan.whole[1] = sl
            return plan, 0
        end
    end
    for _, sl in ipairs(slots) do
        if left <= 0 then break end
        if sl.count <= left then
            plan.whole[#plan.whole + 1] = sl
            left = left - sl.count
        elseif not plan.split then
            plan.split = { bag = sl.bag, slot = sl.slot, n = left }
            left = 0
        end
    end
    return plan, left
end

local function Finish(ok, text)
    filling = false
    if ok then Status(text, 0.25, 1, 0.25) else Status(text, 1, 0.3, 0.3) end
    if CursorHasItem() then ClearCursor() end
    Mail:UpdateButton()
end

-- Attaches the given bag slots one by one (waiting for each to show in the form).
local function AttachAll(list, i, done)
    if i > #list then done(true) return end
    if not SendMailOpen() then done(false, "The Send Mail tab was closed.") return end
    local sl = list[i]
    local index = FreeAttachSlot()
    if not index then done(false, "No free attachment slot left.") return end
    local before = AttachedCount()
    C_Container.PickupContainerItem(sl.bag, sl.slot)
    if not CursorHasItem() then done(false, "Couldn't pick up an item (is it locked?).") return end
    ClickSendMailItemButton(index)
    WaitFor(function() return AttachedCount() > before end, 3, function(ok)
        if not ok then done(false, "An item didn't attach. Try again.") return end
        AttachAll(list, i + 1, done)
    end)
end

function Mail:Fill()
    local e = Selected()
    if filling or not e then return end
    if not SendMailOpen() then Status("Open the Send Mail tab first.", 1, 0.3, 0.3) return end
    if InCombatLockdown() then Status("Try again out of combat.", 1, 0.3, 0.3) return end
    if AttachedCount() > 0 then
        Status("Send Mail already has attachments: remove them first.", 1, 0.3, 0.3) return
    end
    local amount = Amount(e)
    if amount <= 0 then Status("Nothing in your bags for this one.", 1, 0.3, 0.3) return end
    local plan, left = Plan(e, amount)
    amount = amount - left
    local stacks = #plan.whole + (plan.split and 1 or 0)
    if stacks == 0 or amount <= 0 then Status("Nothing in your bags for this one.", 1, 0.3, 0.3) return end
    if stacks > MAX_ATTACH then
        Status(("That needs %d attachments; a mail holds %d. Stack your items first."):format(stacks, MAX_ATTACH),
            1, 0.3, 0.3)
        return
    end
    local empty
    if plan.split then
        local eb, es = FindEmpty()
        if not eb then
            Status("Free one bag slot so the exact amount can be split off.", 1, 0.3, 0.3) return
        end
        empty = { bag = eb, slot = es }
    end

    filling = true
    Mail:UpdateButton()
    Status("Filling Send Mail...")
    if CursorHasItem() then ClearCursor() end

    -- Recipient and subject.
    local req = e.req
    local itemName = C_Item.GetItemInfo(req.rule and e.link or req.itemID) or "item"
    local subject = ("Unc's Tavern: %s x%d"):format(itemName, amount)
    if #subject > SUBJECT_MAX then subject = subject:sub(1, SUBJECT_MAX) end
    local nameBox, subjectBox = NameBox(), SubjectBox()
    if nameBox then nameBox:SetText(req.requester) end
    if subjectBox then subjectBox:SetText(subject) end

    local function attachRest()
        AttachAll(plan.whole, 1, function(ok, err)
            if not ok then Finish(false, err) return end
            Finish(true, ("Ready: %d x %s to %s. Check it, then press Send."):format(
                amount, itemName, Ambiguate(req.requester, "guild")))
        end)
    end

    if not plan.split then attachRest() return end
    -- Split the part stack into the empty slot, wait until the server is done, then
    -- attach it along with the whole stacks.
    local sp = plan.split
    C_Container.SplitContainerItem(sp.bag, sp.slot, sp.n)
    C_Container.PickupContainerItem(empty.bag, empty.slot)
    WaitFor(function()
        local new = C_Container.GetContainerItemInfo(empty.bag, empty.slot)
        local old = C_Container.GetContainerItemInfo(sp.bag, sp.slot)
        return new and new.stackCount == sp.n and not new.isLocked and not (old and old.isLocked)
    end, 5, function(ok)
        if not ok then
            Finish(false, "The split didn't finish in time. Check your bags and try again.") return
        end
        table.insert(plan.whole, 1, { bag = empty.bag, slot = empty.slot, count = sp.n })
        attachRest()
    end)
end

function Mail:UpdateButton()
    if not panel then return end
    local e = Selected()
    local anyway = e and select(2, Amount(e))
    panel.fill:SetText(anyway and "Fill anyway" or "Fill Send Mail")
    panel.fill:SetEnabled(not filling and e ~= nil and Amount(e) > 0)
    panel.clear:SetEnabled(not filling)
end

-- Empties Blizzard's Send Mail form: every attachment back to the bags, recipient and
-- subject cleared. (Split-off items stay as their own small stacks in the bags.)
function Mail:Clear()
    if filling then return end
    if not SendMailOpen() then Status("Open the Send Mail tab first.", 1, 0.3, 0.3) return end
    if CursorHasItem() then ClearCursor() end
    for i = MAX_ATTACH, 1, -1 do
        if GetSendMailItem(i) then ClickSendMailItemButton(i, true) end -- true = take it back out
    end
    local nameBox, subjectBox = NameBox(), SubjectBox()
    if nameBox then nameBox:SetText("") end
    if subjectBox then subjectBox:SetText("") end
    Status("Send Mail cleared.")
end

---------------------------------------------------------------------------
-- Auto-claim on send
--   When a mail actually goes out (MAIL_SEND_SUCCESS) to a guildmate with open
--   requests, the items in it become my claim ("I'm sending N") on those requests, so
--   everyone sees it's on its way. Works for any mail, filled by us or by hand.
--   SendMail is watched with hooksecurefunc, which runs AFTER Blizzard's own call and
--   can't change or block it (same as the inbox hooks in AutoComplete.lua); it only
--   notes the recipient and the attachments, which are still in the form at that point.
--   The requester's own client still confirms on receipt (Received / Helped).
---------------------------------------------------------------------------
local outgoing -- { to, items = { { itemID, link, count } } } between SendMail and its result

local function SameName(a, b)
    if not a or not b then return false end
    a = strtrim(a):lower()
    b = strtrim(b):lower()
    return a == b or Ambiguate(a, "none") == Ambiguate(b, "none")
end

local function OnSendMail(recipient)
    outgoing = nil
    if type(recipient) ~= "string" or recipient == "" or not ns:GuildKey() then return end
    local items = {}
    for i = 1, MAX_ATTACH do
        local name, itemID, _, count = GetSendMailItem(i)
        if name and itemID then
            items[#items + 1] = { itemID = itemID, count = tonumber(count) or 1,
                                  link = GetSendMailItemLink and GetSendMailItemLink(i) }
        end
    end
    if #items > 0 then outgoing = { to = recipient, items = items } end
end

if SendMail then
    hooksecurefunc("SendMail", function(recipient) OnSendMail(recipient) end)
end

local function OnSendSuccess()
    local out = outgoing
    outgoing = nil
    if not out then return end
    -- The recipient's open requests, oldest first.
    local reqs = {}
    for _, req in ipairs(W:List("all")) do
        if not W:IsMine(req) and SameName(req.requester, out.to) then reqs[#reqs + 1] = req end
    end
    if #reqs == 0 then return end
    table.sort(reqs, function(a, b) return a.created < b.created end)
    local me = ns:PlayerName()
    for _, req in ipairs(reqs) do
        local sent = 0
        for _, it in ipairs(out.items) do
            if it.count > 0 then
                local fits
                if req.rule then
                    fits = it.link and W:MatchesRule(req.rule, it.link) == true
                else
                    fits = it.itemID == req.itemID
                end
                if fits then
                    local need = req.qty - (req.received or 0) - sent
                    local take = math.min(it.count, math.max(0, need))
                    sent = sent + take
                    it.count = it.count - take
                end
            end
        end
        if sent > 0 then
            NoteSent(req, sent)
            local cur = W:MyClaim(req.id)
            local delivered = req.receivedFrom and req.receivedFrom[me] or 0
            local outstanding = cur and math.max(0, cur.qty - delivered) or 0
            local want = (cur and cur.qty or delivered) + math.max(0, sent - outstanding)
            local max = W:Unclaimed(req, true) + delivered -- the most SetClaim accepts
            local qty = math.min(want, max)
            local label = W:Label(req)
            if qty > 0 and (not cur or qty ~= cur.qty) then
                local ok, err = W:SetClaim(req.id, qty)
                if ok then
                    ns:Print(("Sent %d x %s to %s: marked as on its way."):format(sent, label,
                        Ambiguate(req.requester, "guild")))
                else
                    ns:Print(("Sent %d x %s to %s (not marked: %s)"):format(sent, label,
                        Ambiguate(req.requester, "guild"), tostring(err)))
                end
            elseif not cur or qty < want then
                ns:Print(("Sent %d x %s to %s (others had already claimed the rest)."):format(sent, label,
                    Ambiguate(req.requester, "guild")))
            end
        end
    end
    QueueRefresh()
end

ns:RegisterEvent("MAIL_SEND_SUCCESS", OnSendSuccess)
ns:RegisterEvent("MAIL_FAILED", function() outgoing = nil end)

local function CreatePanel()
    -- Parented to the mail window so it closes with it, however the mail window closes.
    panel = CreateFrame("Frame", "UncsTavernMailPanel", MailFrame, "BasicFrameTemplateWithInset")
    panel:SetSize(WIDTH, 424)
    panel:SetFrameStrata(MailFrame and MailFrame:GetFrameStrata() or "MEDIUM")
    panel:SetToplevel(true)
    panel:EnableMouse(true)
    if panel.CloseButton then
        panel.CloseButton:SetScript("OnClick", function()
            Prefs().hidden = true
            panel:Hide()
            if MailFrame and MailFrame:IsShown() then toggle:Show() end
        end)
    end
    if panel.TitleText then panel.TitleText:SetText("Guild Requests") end

    panel.count = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    panel.count:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -32)
    panel.count:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    panel.count:SetJustifyH("LEFT")

    scrollBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -50)
    scrollBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 62)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    panel.empty = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    panel.empty:SetPoint("TOPLEFT", scrollBox, "TOPLEFT", 10, -20)
    panel.empty:SetPoint("RIGHT", scrollBox, "RIGHT", -10, 0)
    panel.empty:SetJustifyH("CENTER")
    panel.empty:SetSpacing(2)

    panel.fill = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.fill:SetSize(130, 24)
    panel.fill:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -3, 12)
    panel.fill:SetText("Fill Send Mail")
    panel.fill:SetMotionScriptsWhileDisabled(true)
    panel.fill:SetScript("OnClick", function() Mail:Fill() end)
    panel.fill:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Fill Send Mail", 1, 1, 1)
        GameTooltip:AddLine("Pick a request, open the Send Mail tab, then click: the recipient, "
            .. "subject and items are filled in for you. Check it and press Send yourself.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("Uses your claim if you have one, otherwise what's still unclaimed. "
            .. "\"Fill anyway\" means others have claimed the rest; it fills what's still needed.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("When the mail goes out, it's marked as on its way (your claim).", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)

    panel.clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    panel.clear:SetSize(130, 24)
    panel.clear:SetPoint("BOTTOMLEFT", panel, "BOTTOM", 3, 12)
    panel.clear:SetText("Clear")
    panel.clear:SetScript("OnClick", function() Mail:Clear() end)
    panel.clear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Clear Send Mail", 1, 1, 1)
        GameTooltip:AddLine("Takes every attachment out and empties the recipient and subject.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    panel.clear:SetScript("OnLeave", GameTooltip_Hide)

    panel.status = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    panel.status:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 14, 42)
    panel.status:SetPoint("RIGHT", panel, "RIGHT", -14, 0)
    panel.status:SetJustifyH("CENTER")
    panel.status:SetWordWrap(true)
    panel.fill:SetScript("OnLeave", GameTooltip_Hide)

    panel:SetScript("OnShow", function() Refresh() end)
    panel:Hide()
end

local function Place()
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, 0)
    panel:SetHeight(math.max(300, MailFrame:GetHeight()))
end

-- The small open/close button on the mail window's right edge (our own frame).
local function CreateToggle()
    toggle = CreateFrame("Button", "UncsTavernMailToggle", MailFrame)
    toggle:SetSize(32, 32)
    toggle:SetFrameStrata(MailFrame and MailFrame:GetFrameStrata() or "MEDIUM")
    toggle:SetFrameLevel((MailFrame and MailFrame:GetFrameLevel() or 1) + 20)
    toggle:SetNormalTexture("Interface\\AddOns\\Uncs_Tavern\\Media\\Icon")
    toggle:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    toggle:SetScript("OnClick", function()
        Prefs().hidden = false
        toggle:Hide()
        Place()
        panel:Show()
    end)
    toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Guild Requests", 1, 1, 1)
        GameTooltip:AddLine("Show guild requests you can fill from your bags.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    toggle:SetScript("OnLeave", GameTooltip_Hide)
    toggle:Hide()
end

local function OnMailShow()
    if not IsInGuild() or not MailFrame then return end
    if not panel then CreatePanel() CreateToggle() end
    panel.status:SetText("")
    toggle:ClearAllPoints()
    toggle:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 2, -60)
    if Prefs().hidden then
        toggle:Show()
    else
        toggle:Hide()
        Place()
        panel:Show()
    end
end

local function OnMailClosed()
    outgoing = nil
    if panel then panel:Hide() end
    if toggle then toggle:Hide() end
end

ns:RegisterEvent("MAIL_SHOW", OnMailShow)
ns:RegisterEvent("MAIL_CLOSED", OnMailClosed)
ns:RegisterEvent("BAG_UPDATE_DELAYED", QueueRefresh)
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", QueueRefresh) -- names and rule matches need item data
ns:RegisterCallback("WISHLIST_CHANGED", QueueRefresh)
ns:RegisterCallback("SHARING_CHANGED", QueueRefresh)
