-- Modules\Mail.lua: the mailbox "Guild Requests" panel (SPEC section 5).
--
-- A panel docked to the right edge of the mail window (our own frame; nothing is added
-- to Blizzard's mail window or its tabs) listing other players' open guild requests you
-- can fill from your bags. Its X closes it; a small mug button on the mail window's
-- edge (shown only while the panel is closed) opens it again. Remembered per character.
--
-- Step 2 of the build: the list only (read-only). "Fill Send Mail" comes next. The
-- addon never sends mail: Fill only pre-fills Blizzard's form, the player presses Send.
--
-- Event-driven: refreshed on mailbox, bag and wishlist events while the panel shows
-- (coalesced into one refresh per burst), never on a timer.
local _, ns = ...
local W = ns.Wishlist

local Mail = {}
ns.Mail = Mail

local WIDTH      = 320
local ROW_HEIGHT = 38
local REFRESH_DELAY = 0.2 -- bag events come in bursts: one refresh per burst

local panel, toggle, scrollBox
local selectedId
local refreshPending = false

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

    for _, e in ipairs(out) do
        e.need = e.req.qty - (e.req.received or 0)
        local claim = W:MyClaim(e.req.id)
        e.mine = claim and W:ClaimOutstanding(claim) or nil
        if e.mine == 0 then e.mine = nil end
        e.complete = e.have >= (e.mine or e.need)
    end
    table.sort(out, function(a, b)
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
    GameTooltip:AddDoubleLine("Still needed", tostring(e.need), 1, 0.82, 0, 1, 1, 1)
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
    local others = W:ClaimedTotal(req.id) - (e.mine or 0)
    if others > 0 then GameTooltip:AddDoubleLine("Claimed by others", tostring(others), 1, 0.82, 0, 1, 1, 1) end
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
    local extra = {}
    if e.bank and e.bank > 0 then extra[#extra + 1] = "bank " .. e.bank end
    if e.altTotal and e.altTotal > 0 then extra[#extra + 1] = "alts " .. e.altTotal end
    row.sub:SetText(("for %s%s"):format(c:WrapTextInColorCode(Ambiguate(req.requester, "guild")),
        #extra > 0 and ("  |cff999999" .. table.concat(extra, " · ") .. "|r") or ""))
    local wanted = e.mine and ("claim %d"):format(e.mine) or ("needs %d"):format(e.need)
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
    local list = Mail:Fillable()
    local found = false
    for _, e in ipairs(list) do
        if e.req.id == selectedId then found = true break end
    end
    if not found then selectedId = nil end
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

function Mail:UpdateButton()
    if not panel then return end
    -- Step 3 turns this on. Shown now so the layout is final.
    panel.fill:SetEnabled(false)
end

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
    scrollBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 44)
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
    panel.fill:SetSize(150, 24)
    panel.fill:SetPoint("BOTTOM", panel, "BOTTOM", 0, 12)
    panel.fill:SetText("Fill Send Mail")
    panel.fill:SetMotionScriptsWhileDisabled(true)
    panel.fill:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Fill Send Mail", 1, 1, 1)
        GameTooltip:AddLine("Coming in the next step.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
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
    if panel then panel:Hide() end
    if toggle then toggle:Hide() end
end

ns:RegisterEvent("MAIL_SHOW", OnMailShow)
ns:RegisterEvent("MAIL_CLOSED", OnMailClosed)
ns:RegisterEvent("BAG_UPDATE_DELAYED", QueueRefresh)
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", QueueRefresh) -- names and rule matches need item data
ns:RegisterCallback("WISHLIST_CHANGED", QueueRefresh)
ns:RegisterCallback("SHARING_CHANGED", QueueRefresh)
