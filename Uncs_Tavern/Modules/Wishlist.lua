-- Modules\Wishlist.lua: Wishlist tab (UI only; data lives in WishlistData.lua).
-- Step 1: add a request (drag an item into the slot, quantity, note, payment) and
-- list open requests with filters. Claims: other people's rows have a Claim
-- button ("I'm sending N"). Rule requests and item search come in later steps. (Shift-click was dropped: on stacks it opens the bag's
-- split-stack box, which then grabs keyboard input.)
local _, ns = ...
local W = ns.Wishlist

local ROW_HEIGHT = 22
local COLUMNS = {
    { key = "item",      label = "Item",      width = 165 },
    { key = "progress",  label = "Progress",  width = 55, justify = "CENTER" },
    { key = "requester", label = "Requester", width = 110 },
    { key = "payment",   label = "Payment",   width = 90 },
    { key = "note",      label = "Note",      width = 100 },
    { key = "claims",    label = "Claimed",   width = 75, justify = "CENTER" },
    { key = "actions",   label = "",          width = 55 },
}
do
    local x = 0
    for _, col in ipairs(COLUMNS) do col.x = x; x = x + col.width end
end

local FILTERS = {
    { key = "all",  label = "All" },
    { key = "mats", label = "Mats" },
    { key = "gear", label = "Gear" },
    { key = "mine", label = "Mine" },
}

local panel, scrollBox, emptyText, countText, hideMineCheck
local slot, qtyBox, noteBox, giftRadio, payRadio, goldBox, silverBox, copperBox
local filterButtons = {}
local filter = "all"
local selectedItemID

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function Prefs()
    ns.charDB.wishlist = ns.charDB.wishlist or { hideMine = false }
    return ns.charDB.wishlist
end

-- Icon straight from the client's item table: works even when the item isn't cached yet.
local function ItemIcon(itemID)
    return select(5, C_Item.GetItemInfoInstant(itemID)) or C_Item.GetItemIconByID(itemID)
end

local function ClassColor(classFile)
    local c = classFile and C_ClassColor and C_ClassColor.GetClassColor(classFile)
    return c or HIGHLIGHT_FONT_COLOR
end

local function QualityColor(quality)
    local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return c and c.color or c or HIGHLIGHT_FONT_COLOR
end

-- InputBoxTemplate draws its left edge ~5px outside the frame, so callers leave
-- a gap of about 8px after a label. Focus is set explicitly on click.
local function TextBox(parent, width, maxLetters)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 20)
    box:SetAutoFocus(false)
    box:SetMaxLetters(maxLetters)
    box:EnableMouse(true)
    box:EnableKeyboard(true)
    box:SetScript("OnMouseDown", function(self) self:SetFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

local function NumBox(parent, width, maxLetters)
    local box = TextBox(parent, width, maxLetters)
    box:SetNumeric(true)
    box:SetJustifyH("CENTER")
    return box
end

local function CoinIcon(parent, box, coin)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture("Interface\\MoneyFrame\\UI-" .. coin .. "Icon")
    t:SetSize(13, 13)
    t:SetPoint("LEFT", box, "RIGHT", 2, 0)
    return t
end

---------------------------------------------------------------------------
-- Item slot
---------------------------------------------------------------------------
local function SetSlotItem(itemID)
    selectedItemID = itemID
    if not itemID then
        slot.icon:SetTexture(nil)
        slot.border:Hide()
        slot.name:SetText("|cff808080Drag an item from your bags onto this slot|r")
        return
    end
    slot.icon:SetTexture(ItemIcon(itemID))
    local item = Item:CreateFromItemID(itemID)
    item:ContinueOnItemLoad(function()
        if selectedItemID ~= itemID then return end
        local c = QualityColor(item:GetItemQuality())
        slot.name:SetText(item:GetItemName() or ("item:" .. itemID))
        slot.name:SetTextColor(c.r, c.g, c.b)
        slot.icon:SetTexture(item:GetItemIcon() or ItemIcon(itemID))
        slot.border:SetVertexColor(c.r, c.g, c.b)
        slot.border:Show()
    end)
end

local function TakeCursorItem()
    local kind, itemID = GetCursorInfo()
    if kind == "item" and itemID then
        SetSlotItem(itemID)
        ClearCursor() -- the item just goes back to the bag; nothing is moved or traded
        return true
    end
end

---------------------------------------------------------------------------
-- Claim popup: "How many will you send?" (0 cancels your claim)
---------------------------------------------------------------------------
local CLAIM_POPUP = "UNCSTAVERN_CLAIM"

local function PopupEditBox(popup)
    return popup.editBox or popup.EditBox or (popup.GetEditBox and popup:GetEditBox())
end

local function SubmitClaim(popup, reqId)
    local box = PopupEditBox(popup)
    local claim, err = W:SetClaim(reqId, box and box:GetText())
    if not claim then
        ns:Print(err)
    elseif claim.deleted then
        ns:Print("Claim cancelled.")
    else
        ns:Print(("You claimed %d. The requester and guild can see it."):format(claim.qty))
    end
end

StaticPopupDialogs[CLAIM_POPUP] = {
    text = "How many will you send?\n%s\n\n(0 cancels your claim)",
    button1 = "Claim",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = 4,
    OnShow = function(self, data)
        local box = PopupEditBox(self)
        if box and data then
            box:SetNumeric(true)
            box:SetText(tostring(data.default))
            box:HighlightText()
            box:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        if data then SubmitClaim(self, data.reqId) end
    end,
    EditBoxOnEnterPressed = function(box, data)
        local popup = box:GetParent()
        if data then SubmitClaim(popup, data.reqId) end
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function OpenClaim(req)
    local mine = W:MyClaim(req.id)
    local free = W:Unclaimed(req, true)
    local name = C_Item.GetItemInfo(req.itemID) or ("item " .. req.itemID)
    local line = ("%s for %s (%d still unclaimed)"):format(name, req.requester, free)
    StaticPopup_Show(CLAIM_POPUP, line, nil, { reqId = req.id, default = mine and mine.qty or free })
end

-- "Got" popup (own requests): fix the received count by hand, e.g. after a trade
-- or items you gathered yourself. Mail is counted automatically.
local GOT_POPUP = "UNCSTAVERN_GOT"

local function SubmitGot(popup, reqId)
    local box = PopupEditBox(popup)
    local req, err = W:SetReceived(reqId, box and box:GetText())
    if not req then
        ns:Print(err)
    elseif not W:IsOpen(req) then
        ns:Print("Request complete - removed from the wishlist.")
    end
end

StaticPopupDialogs[GOT_POPUP] = {
    text = "How many have you received so far?\n%s",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = true,
    maxLetters = 4,
    OnShow = function(self, data)
        local box = PopupEditBox(self)
        if box and data then
            box:SetNumeric(true)
            box:SetText(tostring(data.default))
            box:HighlightText()
            box:SetFocus()
        end
    end,
    OnAccept = function(self, data)
        if data then SubmitGot(self, data.reqId) end
    end,
    EditBoxOnEnterPressed = function(box, data)
        local popup = box:GetParent()
        if data then SubmitGot(popup, data.reqId) end
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function OpenGot(req)
    local name = C_Item.GetItemInfo(req.itemID) or ("item " .. req.itemID)
    local line = ("%s (wanted %d; reaching %d completes it)"):format(name, req.qty, req.qty)
    StaticPopup_Show(GOT_POPUP, line, nil, { reqId = req.id, default = req.received or 0 })
end

---------------------------------------------------------------------------
-- List rows
---------------------------------------------------------------------------
local function RowOnEnter(row)
    local req = row.data
    if not req then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    -- Own lines only: a full item tooltip refreshes itself when data arrives and wipes added lines.
    local name, _, quality = C_Item.GetItemInfo(req.itemID)
    local qc = QualityColor(quality)
    GameTooltip:AddLine(name or ("item:" .. req.itemID), qc.r, qc.g, qc.b)
    local c = ClassColor(req.class)
    GameTooltip:AddDoubleLine("Requested by", req.requester, 1, 0.82, 0, c.r, c.g, c.b)
    GameTooltip:AddDoubleLine("Wanted", ("%d / %d"):format(req.received or 0, req.qty), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Payment", W:PriceText(req.price) .. (req.price > 0 and " each" or ""), 1, 0.82, 0, 1, 1, 1)
    if req.note and req.note ~= "" then GameTooltip:AddDoubleLine("Note", req.note, 1, 0.82, 0, 1, 1, 1) end
    local claims = W:ClaimsFor(req.id)
    if #claims > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Being sent by:", 1, 0.82, 0)
        for _, cl in ipairs(claims) do
            local cc = ClassColor(cl.class)
            local delivered = cl.qty - W:ClaimOutstanding(cl)
            local amount = delivered > 0 and ("%d (%d delivered)"):format(cl.qty, delivered) or tostring(cl.qty)
            GameTooltip:AddDoubleLine("  " .. cl.claimer, amount .. date("   (%b %d %H:%M)", cl.updated),
                cc.r, cc.g, cc.b, 1, 1, 1)
        end
        GameTooltip:AddLine(("Unclaimed: %d"):format(W:Unclaimed(req)), 0.8, 0.8, 0.8)
    end
    if req.receivedFrom and next(req.receivedFrom) then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Received from:", 1, 0.82, 0)
        for who, n in pairs(req.receivedFrom) do
            GameTooltip:AddDoubleLine("  " .. who, tostring(n), 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(date("Added %Y-%m-%d %H:%M", req.created), 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Hover the icon for item details", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function InitRow(row, entry)
    local req = entry.req
    if not row.cells then
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0.04)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

        row.iconButton = CreateFrame("Button", nil, row)
        row.iconButton:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
        row.iconButton:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.icon = row.iconButton:CreateTexture(nil, "ARTWORK")
        row.icon:SetAllPoints()
        row.iconButton:SetScript("OnEnter", function(self)
            local r = self:GetParent().data
            if not r then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(r.itemID)
            GameTooltip:Show()
        end)
        row.iconButton:SetScript("OnLeave", GameTooltip_Hide)

        row.cells = {}
        for i, col in ipairs(COLUMNS) do
            local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            local left = col.x + 4 + (i == 1 and ROW_HEIGHT or 0)
            fs:SetPoint("LEFT", row, "LEFT", left, 0)
            fs:SetWidth(col.width - 8 - (i == 1 and ROW_HEIGHT or 0))
            fs:SetJustifyH(col.justify or "LEFT")
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end

        local actions = COLUMNS[#COLUMNS]
        row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        row.remove:SetSize(ROW_HEIGHT, ROW_HEIGHT)
        row.remove:SetPoint("LEFT", row, "LEFT", actions.x + 33, 0)
        row.remove:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Remove this request")
            GameTooltip:Show()
        end)
        row.remove:SetScript("OnLeave", GameTooltip_Hide)
        row.remove:SetScript("OnClick", function(self)
            local r = self:GetParent().data
            if r then W:Remove(r.id) end
        end)

        row.got = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.got:SetSize(32, ROW_HEIGHT - 4)
        row.got:SetPoint("LEFT", row, "LEFT", actions.x + 1, 0)
        row.got:SetNormalFontObject("GameFontNormalSmall")
        row.got:SetHighlightFontObject("GameFontHighlightSmall")
        row.got:SetText("Got")
        row.got:SetScript("OnClick", function(self)
            local r = self:GetParent().data
            if r then OpenGot(r) end
        end)
        row.got:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Received so far")
            GameTooltip:AddLine("Items taken from the mailbox count automatically. "
                .. "Use this for trades or items you gathered yourself.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row.got:SetScript("OnLeave", GameTooltip_Hide)

        row.claim = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.claim:SetSize(actions.width - 6, ROW_HEIGHT - 4)
        row.claim:SetPoint("LEFT", row, "LEFT", actions.x + 2, 0)
        row.claim:SetNormalFontObject("GameFontNormalSmall")
        row.claim:SetHighlightFontObject("GameFontHighlightSmall")
        row.claim:SetScript("OnClick", function(self)
            local r = self:GetParent().data
            if r then OpenClaim(r) end
        end)
        row.claim:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("I'm sending...")
            GameTooltip:AddLine("Tell the guild how many you'll send, so nobody doubles up. "
                .. "Claims last " .. W.CLAIM_HOURS .. " hours.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        row.claim:SetScript("OnLeave", GameTooltip_Hide)

        row:SetScript("OnEnter", RowOnEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)
    end

    row.data = req
    row.bg:SetShown(entry.index % 2 == 0)
    row.icon:SetTexture(ItemIcon(req.itemID))

    local cells = row.cells
    local item = Item:CreateFromItemID(req.itemID)
    cells[1]:SetText("item:" .. req.itemID)
    cells[1]:SetTextColor(1, 1, 1)
    item:ContinueOnItemLoad(function()
        if row.data ~= req then return end
        local c = QualityColor(item:GetItemQuality())
        cells[1]:SetText(item:GetItemName())
        cells[1]:SetTextColor(c.r, c.g, c.b)
    end)

    cells[2]:SetText(("%d / %d"):format(req.received or 0, req.qty))
    local c = ClassColor(req.class)
    cells[3]:SetText(req.requester)
    cells[3]:SetTextColor(c.r, c.g, c.b)
    cells[4]:SetText(W:PriceText(req.price))
    cells[5]:SetText(req.note or "")
    cells[5]:SetTextColor(0.8, 0.8, 0.8)
    local claimed = W:ClaimedTotal(req.id)
    local mine = W:MyClaim(req.id)
    local myOut = mine and W:ClaimOutstanding(mine) or 0
    if mine then
        cells[6]:SetText(claimed > myOut and ("You %d +%d"):format(myOut, claimed - myOut) or ("You " .. myOut))
        cells[6]:SetTextColor(0.25, 1, 0.25)
    elseif claimed > 0 then
        cells[6]:SetText(claimed)
        cells[6]:SetTextColor(1, 0.82, 0)
    else
        cells[6]:SetText("")
    end
    cells[7]:SetText("")

    local isMine = W:IsMine(req)
    row.remove:SetShown(isMine)
    row.got:SetShown(isMine)
    row.claim:SetShown(not isMine and (mine ~= nil or W:Unclaimed(req) > 0))
    row.claim:SetText(mine and "Edit" or "Claim")
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local function Refresh()
    if not panel then return end
    for _, b in ipairs(filterButtons) do
        if b.key == filter then b:LockHighlight() else b:UnlockHighlight() end
    end
    if not IsInGuild() then
        scrollBox:SetDataProvider(CreateDataProvider())
        emptyText:SetText("You are not in a guild.")
        emptyText:Show()
        countText:SetText("")
        return
    end
    local hideMine = Prefs().hideMine and filter ~= "mine"
    hideMineCheck:SetEnabled(filter ~= "mine")
    hideMineCheck.label:SetFontObject(filter ~= "mine" and "GameFontHighlightSmall" or "GameFontDisableSmall")
    local list = {}
    for _, req in ipairs(W:List(filter)) do
        if not (hideMine and W:IsMine(req)) then list[#list + 1] = req end
    end
    local entries = {} -- wrap so row-only data (index) never lands in SavedVariables
    for i, req in ipairs(list) do entries[i] = { req = req, index = i } end
    scrollBox:SetDataProvider(CreateDataProvider(entries), ScrollBoxConstants.RetainScrollPosition)
    emptyText:SetText(filter == "mine" and "You have no open requests." or "No open requests.")
    emptyText:SetShown(#list == 0)
    countText:SetText(("%d open  ·  %d of %d yours"):format(#W:List("all"), W:CountOpenOwn(), W.MAX_OPEN_OWN))
end

local function SetPayMode(pay)
    giftRadio:SetChecked(not pay)
    payRadio:SetChecked(pay)
    for _, box in ipairs({ goldBox, silverBox, copperBox }) do
        box:SetAlpha(pay and 1 or 0.6)
    end
end

local function ResetForm()
    SetSlotItem(nil)
    qtyBox:SetText("1")
    noteBox:SetText("")
    goldBox:SetText(""); silverBox:SetText(""); copperBox:SetText("")
    SetPayMode(false)
end

local function Submit()
    local price = 0
    if payRadio:GetChecked() then
        price = (tonumber(goldBox:GetText()) or 0) * 10000
            + (tonumber(silverBox:GetText()) or 0) * 100
            + (tonumber(copperBox:GetText()) or 0)
        if price <= 0 then
            ns:Print("Enter a price, or choose Gift.")
            return
        end
    end
    local req, err = W:Add(selectedItemID, qtyBox:GetText(), price, noteBox:GetText())
    if not req then
        ns:Print(err)
        return
    end
    if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
    ResetForm()
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------
local function Label(parent, text, anchorTo, x)
    local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetPoint("LEFT", anchorTo, "RIGHT", x or 10, 0)
    fs:SetText(text)
    return fs
end

local function Radio(parent, text)
    local r = CreateFrame("CheckButton", nil, parent, "UIRadioButtonTemplate")
    local fs = r.text or r.Text
    if not fs then
        fs = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", r, "RIGHT", 2, 0)
    end
    fs:SetFontObject("GameFontHighlightSmall")
    fs:SetText(text)
    r.label = fs
    return r
end

local function Build(p)
    panel = p

    -- Form background
    local form = CreateFrame("Frame", nil, panel)
    form:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -2)
    form:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -2)
    form:SetHeight(100)
    form:SetFrameLevel(panel:GetFrameLevel() + 10)
    local formBg = form:CreateTexture(nil, "BACKGROUND")
    formBg:SetAllPoints()
    formBg:SetColorTexture(0, 0, 0, 0.25)

    -- Item slot
    slot = CreateFrame("Button", nil, form)
    slot:SetSize(37, 37)
    slot:SetPoint("TOPLEFT", form, "TOPLEFT", 8, -8)
    local slotBg = slot:CreateTexture(nil, "BACKGROUND") -- below the icon, so it can never cover it
    slotBg:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    slotBg:SetAllPoints()
    slot:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetAllPoints()
    slot.border = slot:CreateTexture(nil, "OVERLAY")
    slot.border:SetTexture("Interface\\Common\\WhiteIconFrame")
    slot.border:SetAllPoints()
    slot.border:Hide()
    slot.name = form:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    slot.name:SetPoint("TOPLEFT", slot, "TOPRIGHT", 8, -2)
    slot.name:SetWidth(360)
    slot.name:SetJustifyH("LEFT")
    slot.name:SetWordWrap(false)
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slot:SetScript("OnReceiveDrag", TakeCursorItem)
    slot:SetScript("OnClick", function(_, mouseButton)
        if TakeCursorItem() then return end
        if mouseButton == "RightButton" then SetSlotItem(nil) end
    end)
    slot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if selectedItemID then
            GameTooltip:SetItemByID(selectedItemID)
            GameTooltip:AddLine("Right-click to clear", 0.5, 0.5, 0.5)
        else
            GameTooltip:AddLine("Item to request")
            GameTooltip:AddLine("Drag an item from your bags onto this slot.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", GameTooltip_Hide)

    -- Quantity + note (second line beside the slot)
    local qtyLabel = form:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    qtyLabel:SetPoint("BOTTOMLEFT", slot, "BOTTOMRIGHT", 8, 2)
    qtyLabel:SetText("Qty")
    qtyBox = NumBox(form, 40, 4)
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)

    local noteLabel = Label(form, "Note", qtyBox, 12)
    noteBox = TextBox(form, 190, W.MAX_NOTE)
    noteBox:SetPoint("LEFT", noteLabel, "RIGHT", 8, 0)

    -- Payment (right side)
    local payTitle = form:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    payTitle:SetPoint("TOPLEFT", form, "TOPLEFT", 400, -8)
    payTitle:SetText("Payment")

    giftRadio = Radio(form, "Gift")
    giftRadio:SetPoint("TOPLEFT", payTitle, "BOTTOMLEFT", -2, -2)
    payRadio = Radio(form, "Pay up to")
    payRadio:SetPoint("TOPLEFT", giftRadio, "BOTTOMLEFT", 0, -2)
    giftRadio:SetScript("OnClick", function() SetPayMode(false) end)
    payRadio:SetScript("OnClick", function() SetPayMode(true) end)

    goldBox = NumBox(form, 44, 4)
    goldBox:SetPoint("LEFT", payRadio.label, "RIGHT", 8, 0)
    local g = CoinIcon(form, goldBox, "Gold")
    silverBox = NumBox(form, 24, 2)
    silverBox:SetPoint("LEFT", g, "RIGHT", 8, 0)
    local s = CoinIcon(form, silverBox, "Silver")
    copperBox = NumBox(form, 24, 2)
    copperBox:SetPoint("LEFT", s, "RIGHT", 8, 0)
    local c = CoinIcon(form, copperBox, "Copper")
    local each = form:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    each:SetPoint("LEFT", c, "RIGHT", 4, 0)
    each:SetText("each")

    local addButton = CreateFrame("Button", nil, form, "UIPanelButtonTemplate")
    addButton:SetSize(110, 22)
    addButton:SetPoint("BOTTOMRIGHT", form, "BOTTOMRIGHT", -8, 8)
    addButton:SetText("Add request")
    addButton:SetScript("OnClick", Submit)

    local clearButton = CreateFrame("Button", nil, form, "UIPanelButtonTemplate")
    clearButton:SetSize(70, 22)
    clearButton:SetPoint("RIGHT", addButton, "LEFT", -6, 0)
    clearButton:SetText("Clear")
    clearButton:SetScript("OnClick", function()
        for _, box in ipairs({ qtyBox, noteBox, goldBox, silverBox, copperBox }) do box:ClearFocus() end
        ResetForm()
    end)

    for _, box in ipairs({ goldBox, silverBox, copperBox }) do
        box:HookScript("OnEditFocusGained", function() SetPayMode(true) end)
    end

    -- Enter submits
    for _, box in ipairs({ qtyBox, noteBox, goldBox, silverBox, copperBox }) do
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); Submit() end)
    end

    -- Filters
    local prev
    for _, f in ipairs(FILTERS) do
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b.key = f.key
        b:SetSize(60, 20)
        b:SetText(f.label)
        if prev then
            b:SetPoint("LEFT", prev, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", form, "BOTTOMLEFT", 0, -6)
        end
        b:SetScript("OnClick", function(self)
            filter = self.key
            Refresh()
        end)
        filterButtons[#filterButtons + 1] = b
        prev = b
    end

    hideMineCheck = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    hideMineCheck:SetSize(24, 24)
    hideMineCheck:SetPoint("LEFT", prev, "RIGHT", 12, 0)
    local hl = hideMineCheck.Text or hideMineCheck.text
    if not hl then
        hl = hideMineCheck:CreateFontString(nil, "ARTWORK")
        hl:SetPoint("LEFT", hideMineCheck, "RIGHT", 2, 0)
    end
    hl:SetFontObject("GameFontHighlightSmall")
    hl:SetText("Hide mine")
    hideMineCheck.label = hl
    hideMineCheck:SetChecked(Prefs().hideMine)
    hideMineCheck:SetScript("OnClick", function(self)
        Prefs().hideMine = self:GetChecked() and true or false
        Refresh()
    end)

    -- List
    scrollBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    scrollBox:SetPoint("TOPLEFT", form, "BOTTOMLEFT", 0, -52)
    scrollBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 22)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    for _, col in ipairs(COLUMNS) do
        local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fs:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", col.x + 4, 6)
        fs:SetWidth(col.width - 8)
        fs:SetJustifyH(col.justify or "LEFT")
        fs:SetText(col.label)
    end
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 0.82, 0, 0.25)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", 0, 2)
    divider:SetPoint("BOTTOMRIGHT", scrollBox, "TOPRIGHT", 0, 2)

    emptyText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
    emptyText:SetPoint("CENTER", scrollBox, "CENTER")

    countText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    countText:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 6)

    ns:RegisterCallback("WISHLIST_CHANGED", function() if panel:IsVisible() then Refresh() end end)
    panel:SetScript("OnShow", Refresh)

    ResetForm()
    Refresh()
end

ns.MainFrame:RegisterTab("wishlist", "Wishlist", 20, Build)
