-- Modules\Alerts.lua: tell the player when their bags can help the guild wishlist.
--
--   * Tooltip lines: on any item tooltip, "Wanted by <name>: N more · price" for every
--     open request the item fits (item requests and rule requests). Your own requests
--     show as "On your wishlist: N more".
--   * Popup once per login, the first time you open a vendor, auction house or mailbox
--     with items in your bags that are on the guild wishlist: "N items in your bags are
--     on the guild wishlist", listing them, with Show me / Ignore forever (the X just
--     closes it). It sits at the top of the screen and never blocks selling.
--   * Sell warning: if you sell an item a guildmate asked for, a red on-screen and chat
--     message names it and points to the vendor's Buyback tab. (The sale itself is never
--     stopped; we only notice it afterwards, from the buyback list.)
--   * COD warning: a guildmate's mail whose items are all on your wishlist, but whose
--     COD is more than quantity x your price, gets a red warning when the mailbox shows
--     it. Blizzard's own COD confirmation is never touched; you still decide.
--   * Minimap badge: how many guildmates' requests arrived since you last opened the
--     Wishlist tab.
--
-- Event-driven only. Tooltip lines use TooltipDataProcessor (the game's API for addon
-- tooltip lines); the popup is our own frame.
local _, ns = ...
local W = ns.Wishlist

local Alerts = {}
ns.Alerts = Alerts

local MAX_TOOLTIP_LINES = 4
local MAX_POPUP_LINES   = 6
local GOLD = "|cffe6b422"

local function Short(name) return name and Ambiguate(name, "guild") or "?" end
local function Setting(key) return ns.db and ns.db.settings[key] end

-- Open requests this item fits: { { req = req, need = n }, ... }, oldest first.
local function RequestsFor(itemID, link)
    local out = {}
    if not itemID or not ns:GuildKey() then return out end
    for _, req in ipairs(W:List("all")) do
        local fits
        if req.rule then
            fits = link and W:MatchesRule(req.rule, link) == true
        else
            fits = req.itemID == itemID
        end
        if fits then out[#out + 1] = { req = req, need = req.qty - (req.received or 0) } end
    end
    table.sort(out, function(a, b) return a.req.created < b.req.created end)
    return out
end

---------------------------------------------------------------------------
-- Tooltip lines
---------------------------------------------------------------------------
local function AddLines(tooltip)
    if not Setting("tooltipLines") or not tooltip.GetItem then return end
    local _, link = tooltip:GetItem()
    if not link then return end
    local itemID = C_Item.GetItemInfoInstant(link)
    local list = RequestsFor(itemID, link)
    if #list == 0 then return end
    for i, e in ipairs(list) do
        if i > MAX_TOOLTIP_LINES then
            tooltip:AddLine(("+%d more guild requests"):format(#list - MAX_TOOLTIP_LINES), 0.6, 0.6, 0.6)
            break
        end
        local kind = e.req.rule and " (rule)" or ""
        if W:IsMine(e.req) then
            tooltip:AddLine(("%sOn your wishlist|r%s: %d more"):format(GOLD, kind, e.need), 1, 1, 1)
        else
            tooltip:AddLine(("%sWanted by|r %s%s: %d more · %s"):format(GOLD, Short(e.req.requester), kind,
                e.need, W:PriceText(e.req.price)), 1, 1, 1)
        end
    end
    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip)
        if tooltip == GameTooltip or tooltip == ItemRefTooltip then AddLines(tooltip) end
    end)
else
    GameTooltip:HookScript("OnTooltipSetItem", AddLines)
    ItemRefTooltip:HookScript("OnTooltipSetItem", AddLines)
end

---------------------------------------------------------------------------
-- What my bags can fill (others' requests only, unbound items only)
---------------------------------------------------------------------------
-- Returns { { req, count, link }, ... } and the total item count.
function Alerts:Fillable()
    local have = {} -- reqId -> { req, count, link }
    local order = {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    for bag = 0, last do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and not info.isBound then
                for _, e in ipairs(RequestsFor(info.itemID, info.hyperlink)) do
                    local req = e.req
                    if not W:IsMine(req) then
                        local h = have[req.id]
                        if not h then
                            h = { req = req, count = 0, link = info.hyperlink }
                            have[req.id] = h
                            order[#order + 1] = h
                        end
                        -- a rule takes one item per match; item requests take the stack
                        h.count = h.count + (req.rule and 1 or (info.stackCount or 1))
                    end
                end
            end
        end
    end
    local out, total = {}, 0
    for _, h in ipairs(order) do
        h.count = math.min(h.count, W:Unclaimed(h.req, true))
        if h.count > 0 then
            out[#out + 1] = h
            total = total + h.count
        end
    end
    return out, total
end

---------------------------------------------------------------------------
-- Popup
---------------------------------------------------------------------------
local popup

local function CreatePopup()
    popup = CreateFrame("Frame", "UncsTavernAlertPopup", UIParent, "BasicFrameTemplateWithInset")
    popup:SetSize(360, 120)
    popup:SetPoint("TOP", UIParent, "TOP", 0, -120)
    popup:SetFrameStrata("DIALOG")
    popup:SetClampedToScreen(true)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)

    local title = popup.TitleText or popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not popup.TitleText then title:SetPoint("TOP", popup, "TOP", 0, -5) end
    title:SetText(ns.title)

    popup.header = popup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    popup.header:SetPoint("TOPLEFT", popup, "TOPLEFT", 14, -32)
    popup.header:SetPoint("RIGHT", popup, "RIGHT", -14, 0)
    popup.header:SetJustifyH("LEFT")

    popup.lines = {}
    for i = 1, MAX_POPUP_LINES + 1 do
        local fs = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", popup.header, "BOTTOMLEFT", 4, -6 - (i - 1) * 16)
        fs:SetPoint("RIGHT", popup, "RIGHT", -14, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        popup.lines[i] = fs
    end

    local show = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    show:SetSize(100, 22)
    show:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 10)
    show:SetText("Show me")
    show:SetScript("OnClick", function()
        popup:Hide()
        ns.MainFrame:Show("wishlist")
    end)

    local ignore = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    ignore:SetSize(110, 22)
    ignore:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 10)
    ignore:SetText("Ignore forever")
    ignore:SetScript("OnClick", function()
        popup:Hide()
        ns.db.settings.vendorPopup = false
        ns:Print("The wishlist reminder is off. Turn it back on in Settings. "
            .. "(The sell warning stays on.)")
        ns:Fire("SETTINGS_REFRESH")
    end)
    popup:Hide()
end

local shownThisSession = false -- once per login, whichever window comes first

local function ShowPopup()
    if shownThisSession or not Setting("vendorPopup") or not IsInGuild() then return end
    local list, total = Alerts:Fillable()
    if total == 0 then return end
    shownThisSession = true
    if not popup then CreatePopup() end

    popup.header:SetText(total == 1 and "1 item in your bags is on the guild wishlist:"
        or ("%d items in your bags are on the guild wishlist:"):format(total))
    local shown = math.min(#list, MAX_POPUP_LINES)
    for i, fs in ipairs(popup.lines) do
        local h = list[i]
        if i <= shown then
            local icon = C_Item.GetItemIconByID(h.req.itemID or h.link) or 134400
            local what = h.req.rule and (h.link or W:Label(h.req)) or (select(2, C_Item.GetItemInfo(h.req.itemID)) or W:Label(h.req))
            fs:SetText(("|T%s:14|t %s x%d  ->  %s  ·  %s"):format(icon, what, h.count, Short(h.req.requester),
                W:PriceText(h.req.price)))
            fs:Show()
        elseif i == shown + 1 and #list > shown then
            fs:SetText(("|cff999999+%d more|r"):format(#list - shown))
            fs:Show()
        else
            fs:Hide()
        end
    end
    local rows = shown + ((#list > shown) and 1 or 0)
    popup:SetHeight(92 + rows * 16)
    popup:Show()
end

local function HidePopup()
    if popup then popup:Hide() end
end

-- A moment after the window opens, so the vendor/AH/mail frame is up first.
local function OnOpen() C_Timer.After(0.3, ShowPopup) end
ns:RegisterEvent("MAIL_SHOW", OnOpen)
ns:RegisterEvent("AUCTION_HOUSE_SHOW", OnOpen)

---------------------------------------------------------------------------
-- Sell warning: watch the vendor's buyback list; a new newest entry = something sold.
---------------------------------------------------------------------------
local merchantOpen = false
local buyback = {}  -- links in the buyback list, as last seen
local checkPending = false

local function BuybackLinks()
    local out = {}
    for i = 1, (GetNumBuybackItems and GetNumBuybackItems() or 0) do
        out[i] = GetBuybackItemLink(i) or ""
    end
    return out
end

local function WarnSold(link)
    if not Setting("sellWarnings") or not link or link == "" then return end
    local itemID = C_Item.GetItemInfoInstant(link)
    for _, e in ipairs(RequestsFor(itemID, link)) do
        if not W:IsMine(e.req) then
            local text = ("%s is on %s's wishlist! Buy it back from the vendor's Buyback tab.")
                :format(link, Short(e.req.requester))
            ns:Print("|cffff4040" .. text .. "|r")
            UIErrorsFrame:AddMessage(text, 1, 0.25, 0.25)
            if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
            return
        end
    end
end

local function CheckBuyback()
    checkPending = false
    if not merchantOpen then return end
    local now = BuybackLinks()
    local changed = #now ~= #buyback
    for i = 1, #now do if now[i] ~= buyback[i] then changed = true break end end
    -- Sold: the list grew, or (when full) shifted with a new newest entry.
    -- Bought back: the list shrank; nothing to warn about.
    if changed and #now >= #buyback and #now > 0 then WarnSold(now[#now]) end
    buyback = now
end

local function ScheduleCheck()
    if not merchantOpen or checkPending then return end
    checkPending = true
    C_Timer.After(0.2, CheckBuyback)
end

ns:RegisterEvent("MERCHANT_SHOW", function()
    merchantOpen = true
    buyback = BuybackLinks()
    OnOpen()
end)
ns:RegisterEvent("MERCHANT_UPDATE", ScheduleCheck)
ns:RegisterEvent("BAG_UPDATE_DELAYED", ScheduleCheck)
ns:RegisterEvent("MERCHANT_CLOSED", function()
    merchantOpen = false
    HidePopup()
end)
ns:RegisterEvent("MAIL_CLOSED", HidePopup)
ns:RegisterEvent("AUCTION_HOUSE_CLOSED", HidePopup)

---------------------------------------------------------------------------
-- COD warning (mailbox)
---------------------------------------------------------------------------
local MAX_ATTACH = ATTACHMENTS_MAX_RECEIVE or 16
local codWarned = {} -- mails already warned about this session

local function MoneyText(copper)
    if GetMoneyString then return GetMoneyString(copper, true) end
    return tostring(copper)
end

-- What my wishlist says this attachment is worth, or nil if it's not on my wishlist.
local function MyPrice(itemID, link, count)
    for _, req in ipairs(W:List("mine")) do
        local fits
        if req.rule then
            fits = link and W:MatchesRule(req.rule, link) == true
        else
            fits = req.itemID == itemID
        end
        if fits then return count * (req.price or 0) end
    end
    return nil
end

local function CheckCOD()
    if not Setting("codWarning") or not ns.Comm then return end
    for i = 1, (GetInboxNumItems and GetInboxNumItems() or 0) do
        local _, _, sender, _, _, cod, _, hasItem = GetInboxHeaderInfo(i)
        sender = sender and Short(sender)
        if cod and cod > 0 and hasItem and sender and ns.Comm:IsMember(sender) then
            local expected, items, judged = 0, {}, true
            for a = 1, MAX_ATTACH do
                local _, itemID, _, count = GetInboxItem(i, a)
                if itemID then
                    local price = MyPrice(itemID, GetInboxItemLink and GetInboxItemLink(i, a), count or 1)
                    if not price then judged = false break end -- not all on my wishlist: can't judge
                    expected = expected + price
                    items[#items + 1] = itemID .. "x" .. (count or 1)
                end
            end
            local key = sender .. "|" .. cod .. "|" .. table.concat(items, ",")
            if judged and #items > 0 and cod > expected and not codWarned[key] then
                codWarned[key] = true
                local text = ("COD warning: %s's mail asks %s, but your wishlist price for these items is %s.")
                    :format(ns:CleanText(sender, 64), MoneyText(cod), W:PriceText(expected))
                ns:Print("|cffff4040" .. text .. "|r")
                UIErrorsFrame:AddMessage(text, 1, 0.25, 0.25)
                if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
            end
        end
    end
end

local codPending = false
ns:RegisterEvent("MAIL_INBOX_UPDATE", function()
    if codPending then return end
    codPending = true
    C_Timer.After(0.5, function() codPending = false CheckCOD() end)
end)

---------------------------------------------------------------------------
-- Minimap badge: guildmates' requests created since I last looked at the Wishlist tab
---------------------------------------------------------------------------
local currentTab
local badgePending = false

local function AlertsDB()
    ns.charDB.alerts = ns.charDB.alerts or {}
    return ns.charDB.alerts
end

function Alerts:NewCount()
    local seen = AlertsDB().lastSeen or 0
    local n = 0
    for _, req in ipairs(W:List("all")) do
        if not W:IsMine(req) and (req.created or 0) > seen then n = n + 1 end
    end
    return n
end

local function WishlistVisible()
    local f = _G.UncsTavernMainFrame
    return currentTab == "wishlist" and f and f:IsShown()
end

local function MarkSeen()
    AlertsDB().lastSeen = W.Now()
end

local function Badge()
    local button = _G.UncsTavernMinimapButton
    if not button then return nil end
    if not button.uncsBadge then
        local b = CreateFrame("Frame", nil, button)
        b:SetSize(16, 16)
        b:SetPoint("CENTER", button, "TOPRIGHT", -7, -7)
        b:SetFrameLevel(button:GetFrameLevel() + 5)
        local bg = b:CreateTexture(nil, "ARTWORK")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        bg:SetVertexColor(0.8, 0.1, 0.1)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER", 0, 0)
        button.uncsBadge = b
        button:HookScript("OnEnter", function()
            local n = Alerts:NewCount()
            if n > 0 and Setting("minimapBadge") and GameTooltip:IsOwned(button) then
                GameTooltip:AddLine(("%d new guild request%s"):format(n, n == 1 and "" or "s"), 1, 0.3, 0.3)
                GameTooltip:Show()
            end
        end)
    end
    return button.uncsBadge
end

local function UpdateBadge()
    badgePending = false
    if not ns.charDB then return end
    if WishlistVisible() then MarkSeen() end
    local n = Setting("minimapBadge") and Alerts:NewCount() or 0
    local b = (n > 0) and Badge() or (_G.UncsTavernMinimapButton and _G.UncsTavernMinimapButton.uncsBadge)
    if not b then return end
    b.text:SetText(n > 9 and "9+" or tostring(n))
    b:SetShown(n > 0)
end

local function ScheduleBadge()
    if badgePending then return end
    badgePending = true
    C_Timer.After(1, UpdateBadge)
end

ns:RegisterCallback("WISHLIST_CHANGED", ScheduleBadge)
ns:RegisterCallback("TAB_SHOWN", function(_, key)
    currentTab = key
    if key == "wishlist" then MarkSeen() end
    ScheduleBadge()
end)
ns:RegisterEvent("PLAYER_LOGIN", function()
    -- First run: start counting from now instead of flagging every existing request.
    if not AlertsDB().lastSeen then MarkSeen() end
    C_Timer.After(3, UpdateBadge)
end)

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
ns.Settings:RegisterToggle({
    category = "alerts",
    key = "tooltipLines",
    label = "Guild requests on tooltips",
    description = "\"Wanted by <name>: N more\" on items someone in the guild has asked for.",
    order = 40,
})
ns.Settings:RegisterToggle({
    category = "alerts",
    key = "vendorPopup",
    label = "Wishlist reminder popup",
    description = "Once per login, at a vendor, the auction house or the mailbox: a popup when items in your bags are on the guild wishlist. Never blocks selling.",
    order = 41,
    onChange = function(v) if not v then HidePopup() end end,
})
ns.Settings:RegisterToggle({
    category = "alerts",
    key = "sellWarnings",
    label = "Warn when selling a wanted item",
    description = "A red warning if you sell an item a guildmate asked for, pointing to the vendor's Buyback tab.",
    order = 41.5,
})
ns.Settings:RegisterToggle({
    category = "alerts",
    key = "codWarning",
    label = "Warn when a COD is too high",
    description = "A red warning if a guildmate's mail asks more COD than your wishlist price.",
    order = 41.6,
})
ns.Settings:RegisterToggle({
    category = "minimap",
    key = "minimapBadge",
    label = "New request badge",
    description = "A number on the minimap button counting guildmates' new requests until you open the Wishlist tab.",
    order = 95,
    onChange = UpdateBadge,
})
