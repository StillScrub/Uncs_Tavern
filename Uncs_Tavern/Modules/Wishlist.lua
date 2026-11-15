-- Modules\Wishlist.lua: Wishlist tab (UI only; data lives in WishlistData.lua).
-- Add a request in one of two modes:
--   Item: drag an item into the slot, or type in the search box (ItemSearch.lua) and
--         pick from the list. (Shift-click was dropped: on stacks it opens the bag's
--         split-stack box, which then grabs keyboard input.)
--   Rule: armor type + slot + minimum required level + one stat with a minimum.
-- Both take quantity, note and payment. The list shows open requests with filters;
-- other people's rows have a Claim button ("I'm sending N"), your own Got and remove.
local _, ns = ...
local W = ns.Wishlist

local ROW_HEIGHT = 22
local FORM_HEIGHT = { item = 108, rule = 142 }
-- "Pay up to" is greyed out: COD mail fails on the WoW: Forever server ("Internal mail
-- database error", 2026-11-15, even with no addons), so paid requests can't be filled.
-- Set to false when COD works again; nothing else needs changing.
local PAY_DISABLED = true
-- Item and Note grow with the window; the rest are sized to fit their content
-- (Requester fits a full two-part name).
local COLUMNS = {
    { key = "item",      label = "Item",      width = 170, flex = 3 },
    { key = "progress",  label = "Progress",  width = 55, justify = "CENTER" },
    { key = "requester", label = "Requester", width = 140 },
    { key = "payment",   label = "Payment",   width = 95 },
    { key = "note",      label = "Note",      width = 90, flex = 2 },
    { key = "claims",    label = "Claimed",   width = 70, justify = "CENTER" },
    { key = "actions",   label = "",          width = 55 },
}
ns.Columns.Layout(COLUMNS, 0)
local headerCells = {}
local layoutVersion = 0
local LayoutRow -- defined with the rows

local FILTERS = {
    { key = "all",  label = "All" },
    { key = "mats", label = "Mats" },
    { key = "gear", label = "Gear" },
    { key = "mine", label = "Mine" },
}

local ARMOR_ICONS = {
    "Interface\\Icons\\INV_Chest_Cloth_17", "Interface\\Icons\\INV_Chest_Leather_09",
    "Interface\\Icons\\INV_Chest_Chain_05", "Interface\\Icons\\INV_Chest_Plate06",
}
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local panel, scrollBox, emptyText, countText, hideMineCheck
local slot, qtyBox, noteBox, giftRadio, payRadio, goldBox, silverBox, copperBox
local filterButtons = {}
local filter = "all"
local selectedItemID
local mode = "item"                     -- "item" | "rule"
local modeButtons = {}
local itemPane, rulePane, searchBox, pickList
local armorButton, slotButton, statButton, levelBox, statBox
local stat2Check, stat2Box, stat2Button, qtyLabel, form, noteLabel
local ruleDraft = { armor = 1, slot = "", stat = "INT", stat2 = "STA" }

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

local function RequestIcon(req)
    if req.rule then return ARMOR_ICONS[req.rule.armor] or QUESTION_ICON end
    return ItemIcon(req.itemID)
end

---------------------------------------------------------------------------
-- Pick list: a small drop-down list under a widget, used by the search box and
-- the rule's Armor / Slot / Stat buttons. entries = { { text, icon, color, value } }
---------------------------------------------------------------------------
local PICK_ROW = 18

local function HidePickList()
    if pickList then pickList:Hide() end
end

local function ShowPickList(anchor, entries, onPick, width)
    if not pickList then
        pickList = CreateFrame("Frame", nil, panel, "TooltipBackdropTemplate")
        pickList:SetFrameStrata("DIALOG")
        pickList:EnableMouse(true)
        pickList.buttons = {}
    end
    if #entries == 0 then pickList:Hide() return end
    pickList:ClearAllPoints()
    pickList:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", -4, -2)
    pickList:SetSize(width or anchor:GetWidth() + 8, #entries * PICK_ROW + 12)
    for i, e in ipairs(entries) do
        local b = pickList.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, pickList)
            b:SetHeight(PICK_ROW)
            b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * PICK_ROW)
            b:SetPoint("RIGHT", -6, 0)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetSize(PICK_ROW - 2, PICK_ROW - 2)
            b.icon:SetPoint("LEFT")
            b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            b.text:SetJustifyH("LEFT")
            b.text:SetWordWrap(false)
            pickList.buttons[i] = b
        end
        b.icon:SetTexture(e.icon)
        b.icon:SetShown(e.icon ~= nil)
        b.text:ClearAllPoints()
        b.text:SetPoint("LEFT", b, "LEFT", e.icon and PICK_ROW + 2 or 2, 0)
        b.text:SetPoint("RIGHT")
        b.text:SetText(e.text)
        local c = e.color or HIGHLIGHT_FONT_COLOR
        b.text:SetTextColor(c.r, c.g, c.b)
        b:SetScript("OnClick", function()
            pickList:Hide()
            onPick(e.value)
        end)
        b:Show()
    end
    for i = #entries + 1, #pickList.buttons do pickList.buttons[i]:Hide() end
    pickList:Show()
end

---------------------------------------------------------------------------
-- Item slot
---------------------------------------------------------------------------
local function SetSlotItem(itemID)
    selectedItemID = itemID
    if not itemID then
        slot.icon:SetTexture(nil)
        slot.border:Hide()
        slot.name:SetText("|cff808080Drag an item onto the slot, or search above|r")
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
-- Claim dialog: "How many will you send?" (0 cancels your claim)
-- "Got" dialog (own requests): fix the received count by hand, e.g. after a trade
-- or items you gathered yourself. Mail is counted automatically.
-- Both use our own dialog (UI\Dialog.lua), never Blizzard's shared StaticPopup.
---------------------------------------------------------------------------
local function OpenClaim(req)
    local reqId = req.id
    local mine = W:MyClaim(reqId)
    local free = W:Unclaimed(req, true)
    ns.Dialog:Show({
        text = ("How many will you send?\n%s for %s (%d still unclaimed)\n\n(0 cancels your claim)")
            :format(W:Label(req), req.requester, free),
        accept = "Claim",
        edit = { numeric = true, maxLetters = 4, default = mine and mine.qty or free },
        onAccept = function(text)
            local claim, err = W:SetClaim(reqId, text)
            if not claim then
                ns:Print(err)
            elseif claim.deleted then
                ns:Print("Claim cancelled.")
            else
                ns:Print(("You claimed %d. The requester and guild can see it."):format(claim.qty))
            end
        end,
    })
end

local function OpenGot(req)
    local reqId = req.id
    ns.Dialog:Show({
        text = ("How many have you received so far?\n%s (wanted %d; reaching %d completes it)")
            :format(W:Label(req), req.qty, req.qty),
        accept = "Save",
        edit = { numeric = true, maxLetters = 4, default = req.received or 0 },
        onAccept = function(text)
            local saved, err = W:SetReceived(reqId, text)
            if not saved then
                ns:Print(err)
            elseif not W:IsOpen(saved) then
                ns:Print("Request complete - removed from the wishlist.")
            end
        end,
    })
end

---------------------------------------------------------------------------
-- List rows
---------------------------------------------------------------------------
local function RowOnEnter(row)
    local req = row.data
    if not req then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    -- Own lines only: a full item tooltip refreshes itself when data arrives and wipes added lines.
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
    if not req.rule then GameTooltip:AddLine("Hover the icon for item details", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
end

-- Places a row's cells and buttons for the current column widths.
LayoutRow = function(row)
    for i, col in ipairs(COLUMNS) do
        local pad = (i == 1) and ROW_HEIGHT or 0 -- the item cell leaves room for the icon
        local fs = row.cells[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", row, "LEFT", col.x + 4 + pad, 0)
        fs:SetWidth(col.w - 8 - pad)
    end
    local actions = COLUMNS[#COLUMNS]
    row.remove:ClearAllPoints()
    row.remove:SetPoint("LEFT", row, "LEFT", actions.x + 33, 0)
    row.got:ClearAllPoints()
    row.got:SetPoint("LEFT", row, "LEFT", actions.x + 1, 0)
    row.claim:ClearAllPoints()
    row.claim:SetPoint("LEFT", row, "LEFT", actions.x + 2, 0)
    row.layoutVersion = layoutVersion
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
            if r.rule then
                GameTooltip:AddLine("Rule request")
                GameTooltip:AddLine(W:RuleText(r.rule), 1, 1, 1)
                GameTooltip:AddLine("Any unbound item that fits counts.", 0.8, 0.8, 0.8, true)
            else
                GameTooltip:SetItemByID(r.itemID)
            end
            GameTooltip:Show()
        end)
        row.iconButton:SetScript("OnLeave", GameTooltip_Hide)

        row.cells = {}
        for i, col in ipairs(COLUMNS) do
            local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            fs:SetJustifyH(col.justify or "LEFT")
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end

        row.remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        row.remove:SetSize(ROW_HEIGHT, ROW_HEIGHT)
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
        row.claim:SetSize(COLUMNS[#COLUMNS].width - 6, ROW_HEIGHT - 4)
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

    if row.layoutVersion ~= layoutVersion then LayoutRow(row) end
    row.data = req
    row.bg:SetShown(entry.index % 2 == 0)
    row.icon:SetTexture(RequestIcon(req))

    local cells = row.cells
    if req.rule then
        cells[1]:SetText(W:RuleText(req.rule))
        cells[1]:SetTextColor(1, 0.82, 0)
    else
        local item = Item:CreateFromItemID(req.itemID)
        cells[1]:SetText("item:" .. req.itemID)
        cells[1]:SetTextColor(1, 1, 1)
        item:ContinueOnItemLoad(function()
            if row.data ~= req then return end
            local c = QualityColor(item:GetItemQuality())
            cells[1]:SetText(item:GetItemName())
            cells[1]:SetTextColor(c.r, c.g, c.b)
        end)
    end

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
    if PAY_DISABLED then pay = false end
    giftRadio:SetChecked(not pay)
    payRadio:SetChecked(pay)
    for _, box in ipairs({ goldBox, silverBox, copperBox }) do
        box:SetAlpha(PAY_DISABLED and 0.35 or (pay and 1 or 0.6))
    end
end

local function UpdateRuleButtons()
    armorButton:SetText(W:ArmorName(ruleDraft.armor))
    slotButton:SetText(W:SlotName(ruleDraft.slot))
    statButton:SetText(W:StatName(ruleDraft.stat))
    stat2Button:SetText(W:StatName(ruleDraft.stat2))
    local on = stat2Check:GetChecked()
    stat2Box:SetEnabled(on)
    stat2Button:SetEnabled(on)
    stat2Box:SetAlpha(on and 1 or 0.5)
end

local function SetMode(m)
    mode = m
    HidePickList()
    itemPane:SetShown(m == "item")
    rulePane:SetShown(m == "rule")
    -- Gear rules are always for one item: no quantity.
    qtyLabel:SetShown(m == "item")
    qtyBox:SetShown(m == "item")
    -- Rule mode: Note lines up with the rule grid's label and field columns.
    noteLabel:ClearAllPoints()
    noteBox:ClearAllPoints()
    if m == "rule" then
        noteLabel:SetPoint("LEFT", qtyLabel, "LEFT", 0, 0)
        -- qtyLabel sits at x = 10; the grid's field column starts at x = 92 (+6 for the box border)
        noteBox:SetPoint("LEFT", noteLabel, "LEFT", 92 + 6 - 10, 0)
        noteBox:SetWidth(290)
    else
        noteLabel:SetPoint("LEFT", qtyBox, "RIGHT", 12, 0)
        noteBox:SetPoint("LEFT", noteLabel, "RIGHT", 8, 0)
        noteBox:SetWidth(190)
    end
    form:SetHeight(FORM_HEIGHT[m])
    for _, b in ipairs(modeButtons) do
        if b.key == m then b:LockHighlight() else b:UnlockHighlight() end
    end
end

local function ResetForm()
    SetSlotItem(nil)
    searchBox:SetText("")
    HidePickList()
    ruleDraft.armor, ruleDraft.slot, ruleDraft.stat, ruleDraft.stat2 = 1, "", "INT", "STA"
    levelBox:SetText("")
    statBox:SetText("")
    stat2Box:SetText("")
    stat2Check:SetChecked(false)
    UpdateRuleButtons()
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
    local what = selectedItemID
    if mode == "rule" then
        what = { armor = ruleDraft.armor, slot = ruleDraft.slot, stat = ruleDraft.stat,
                 minLevel = tonumber(levelBox:GetText()) or 1, minStat = tonumber(statBox:GetText()) }
        if stat2Check:GetChecked() then
            what.stat2, what.minStat2 = ruleDraft.stat2, tonumber(stat2Box:GetText())
        end
    end
    local qty = (mode == "rule") and 1 or qtyBox:GetText()
    local req, err = W:Add(what, qty, price, noteBox:GetText())
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

-- Build is split into parts: Lua allows a function at most 60 outside variables
-- (upvalues), and the whole tab in one function went over that.
local function BuildItemPane()
    -- Item pane (row 2-3): slot, search box, item name
    itemPane = CreateFrame("Frame", nil, form)
    itemPane:SetPoint("TOPLEFT", form, "TOPLEFT", 0, -30)
    itemPane:SetSize(395, 46)

    slot = CreateFrame("Button", nil, itemPane)
    slot:SetSize(37, 37)
    slot:SetPoint("TOPLEFT", itemPane, "TOPLEFT", 8, -2)
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
    slot.name = itemPane:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    slot.name:SetPoint("BOTTOMLEFT", slot, "BOTTOMRIGHT", 8, 2)
    slot.name:SetWidth(330)
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
            GameTooltip:AddLine("Drag an item from your bags onto this slot, or search by name above.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", GameTooltip_Hide)

    -- Search box (beside the slot, above the item name)
    searchBox = CreateFrame("EditBox", nil, itemPane, "SearchBoxTemplate")
    searchBox:SetSize(200, 20)
    searchBox:SetPoint("TOPLEFT", slot, "TOPRIGHT", 12, 0)
    searchBox:SetAutoFocus(false)
    if searchBox.Instructions then searchBox.Instructions:SetText("Search items by name or ID") end
    local function RunSearch()
        local text = searchBox:GetText()
        if not searchBox:HasFocus() or strtrim(text) == "" then HidePickList() return end
        local entries = {}
        for _, id in ipairs(ns.ItemSearch:Find(text, 8)) do
            local name, _, quality = C_Item.GetItemInfo(id)
            entries[#entries + 1] = { text = name or ("item " .. id), icon = ItemIcon(id),
                                      color = QualityColor(quality), value = id }
        end
        ShowPickList(searchBox, entries, function(id)
            SetSlotItem(id)
            searchBox:SetText("")
            searchBox:ClearFocus()
        end, 260)
    end
    searchBox:HookScript("OnTextChanged", RunSearch)
    searchBox:HookScript("OnEditFocusGained", function()
        ns.ItemSearch:Preload()
        RunSearch()
    end)
    searchBox:HookScript("OnEditFocusLost", function()
        -- Clicking a result takes focus away first; keep the list open while the mouse is on it.
        if pickList and pickList:IsShown() and not pickList:IsMouseOver() then HidePickList() end
    end)
    searchBox:SetScript("OnEnterPressed", function(self)
        local first = ns.ItemSearch:Find(self:GetText(), 1)[1]
        if first then SetSlotItem(first) self:SetText("") end
        self:ClearFocus()
    end)
    ns:RegisterCallback("ITEM_SEARCH_UPDATED", function()
        if searchBox:HasFocus() then RunSearch() end
    end)

end

-- Rule pane: a two-column grid, labels left-aligned in their own columns.
--   Armor  [Cloth        ]      Slot       [Any slot ]
--   Stat   [ 4] [Intellect]     Min. level [26] +
--   [x] 2nd stat [ 3] [Stamina]
local GRID = { a = 10, b = 92, c = 236, d = 312 } -- label / field / label / field
local GRID_ROW = 26

local function GridLabel(text, col, row)
    local fs = rulePane:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    fs:SetPoint("LEFT", rulePane, "TOPLEFT", GRID[col], -12 - (row - 1) * GRID_ROW)
    fs:SetText(text)
    return fs
end

local function GridButton(col, row, offset, width)
    local b = CreateFrame("Button", nil, rulePane, "UIPanelButtonTemplate")
    b:SetSize(width, 20)
    b:SetPoint("LEFT", rulePane, "TOPLEFT", GRID[col] + (offset or 0), -12 - (row - 1) * GRID_ROW)
    b:SetNormalFontObject("GameFontHighlightSmall")
    b:SetDisabledFontObject("GameFontDisableSmall")
    return b
end

local function GridBox(col, row)
    local box = NumBox(rulePane, 32, 3)
    -- InputBoxTemplate draws its border ~5px left of the frame.
    box:SetPoint("LEFT", rulePane, "TOPLEFT", GRID[col] + 6, -12 - (row - 1) * GRID_ROW)
    return box
end

local function StatEntries()
    local entries = {}
    for _, st in ipairs(W.STATS) do entries[#entries + 1] = { text = W:StatName(st.key), value = st.key } end
    return entries
end

local function BuildRulePane()
    rulePane = CreateFrame("Frame", nil, form)
    rulePane:SetPoint("TOPLEFT", itemPane, "TOPLEFT")
    rulePane:SetSize(395, 3 * GRID_ROW + 4)

    -- Row 1: armor type, slot
    GridLabel("Armor", "a", 1)
    armorButton = GridButton("b", 1, 0, 120)
    armorButton:SetScript("OnClick", function(self)
        local entries = {}
        for _, a in ipairs(W.ARMOR_TYPES) do
            entries[#entries + 1] = { text = W:ArmorName(a), icon = ARMOR_ICONS[a], value = a }
        end
        ShowPickList(self, entries, function(v) ruleDraft.armor = v UpdateRuleButtons() end, 128)
    end)
    GridLabel("Slot", "c", 1)
    slotButton = GridButton("d", 1, 0, 90)
    slotButton:SetScript("OnClick", function(self)
        local entries = {}
        for _, sl in ipairs(W.SLOTS) do entries[#entries + 1] = { text = W:SlotName(sl), value = sl } end
        ShowPickList(self, entries, function(v) ruleDraft.slot = v UpdateRuleButtons() end, 120)
    end)

    -- Row 2: first stat, minimum required level
    GridLabel("Stat", "a", 2)
    statBox = GridBox("b", 2)
    statButton = GridButton("b", 2, 42, 78)
    statButton:SetScript("OnClick", function(self)
        ShowPickList(self, StatEntries(), function(v) ruleDraft.stat = v UpdateRuleButtons() end, 110)
    end)
    GridLabel("Min. level", "c", 2)
    levelBox = GridBox("d", 2)
    local plus = rulePane:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    plus:SetPoint("LEFT", levelBox, "RIGHT", 3, 0)
    plus:SetText("+")

    -- Row 3: optional second stat (the item needs both)
    stat2Check = CreateFrame("CheckButton", nil, rulePane, "UICheckButtonTemplate")
    stat2Check:SetSize(22, 22)
    stat2Check:SetPoint("LEFT", rulePane, "TOPLEFT", GRID.a - 5, -12 - 2 * GRID_ROW)
    local s2Label = stat2Check.Text or stat2Check.text
    if not s2Label then
        s2Label = stat2Check:CreateFontString(nil, "ARTWORK")
        s2Label:SetPoint("LEFT", stat2Check, "RIGHT", 1, 0)
    end
    s2Label:SetFontObject("GameFontNormalSmall")
    s2Label:SetText("2nd stat")
    stat2Box = GridBox("b", 3)
    stat2Button = GridButton("b", 3, 42, 78)
    stat2Button:SetScript("OnClick", function(self)
        ShowPickList(self, StatEntries(), function(v) ruleDraft.stat2 = v UpdateRuleButtons() end, 110)
    end)
    stat2Check:SetScript("OnClick", function() UpdateRuleButtons() end)

    rulePane:SetScript("OnHide", HidePickList)
end

local function BuildQtyNoteAndPayment()
    -- Quantity + note (bottom row of the form, shared by both modes)
    qtyLabel = form:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    qtyLabel:SetPoint("BOTTOMLEFT", form, "BOTTOMLEFT", 10, 12)
    qtyLabel:SetText("Qty")
    qtyBox = NumBox(form, 40, 4)
    qtyBox:SetPoint("LEFT", qtyLabel, "RIGHT", 8, 0)

    noteLabel = Label(form, "Note", qtyBox, 12)
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

    if PAY_DISABLED then
        payRadio:Disable()
        payRadio.label:SetFontObject("GameFontDisableSmall")
        each:SetFontObject("GameFontDisableSmall")
        for _, box in ipairs({ goldBox, silverBox, copperBox }) do box:Disable() end
        local note = form:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        note:SetPoint("TOPLEFT", payRadio, "BOTTOMLEFT", 4, -1)
        note:SetWordWrap(false)
        note:SetTextColor(1, 0.5, 0.25)
        note:SetText("Disabled: COD mail is broken on the server right now.")
    end

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
        for _, box in ipairs({ qtyBox, noteBox, goldBox, silverBox, copperBox, levelBox, statBox, stat2Box, searchBox }) do box:ClearFocus() end
        ResetForm()
    end)

    for _, box in ipairs({ goldBox, silverBox, copperBox }) do
        box:HookScript("OnEditFocusGained", function() SetPayMode(true) end)
    end

    -- Enter submits
    for _, box in ipairs({ qtyBox, noteBox, goldBox, silverBox, copperBox, levelBox, statBox, stat2Box }) do
        box:SetScript("OnEnterPressed", function(self) self:ClearFocus(); Submit() end)
    end

end

local function BuildList()
    -- Section break: the form above is for making a request, everything below is the
    -- guild's list. A gold rule and a heading, with the filters on the heading's row.
    local rule = panel:CreateTexture(nil, "ARTWORK")
    rule:SetColorTexture(1, 0.82, 0, 0.45)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", form, "BOTTOMLEFT", 0, -8)
    rule:SetPoint("TOPRIGHT", form, "BOTTOMRIGHT", 0, -8)
    local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heading:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 6, -10)
    heading:SetText("Guild requests")

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
            b:SetPoint("LEFT", heading, "RIGHT", 14, 0)
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
    scrollBox:SetPoint("TOPLEFT", form, "BOTTOMLEFT", 0, -64)
    scrollBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -22, 22)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)

    for i, col in ipairs(COLUMNS) do
        local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fs:SetJustifyH(col.justify or "LEFT")
        fs:SetText(col.label)
        headerCells[i] = fs
    end
    local function LayoutHeaders()
        for i, col in ipairs(COLUMNS) do
            local fs = headerCells[i]
            fs:ClearAllPoints()
            fs:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", col.x + 4, 6)
            fs:SetWidth(col.w - 8)
        end
    end
    ns.Columns.Watch(scrollBox, COLUMNS, function()
        layoutVersion = layoutVersion + 1
        LayoutHeaders()
        scrollBox:ForEachFrame(LayoutRow)
    end)
    LayoutHeaders()
    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 0.82, 0, 0.25)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT", scrollBox, "TOPLEFT", 0, 2)
    divider:SetPoint("BOTTOMRIGHT", scrollBox, "TOPRIGHT", 0, 2)

    emptyText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
    emptyText:SetPoint("CENTER", scrollBox, "CENTER")

    countText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    countText:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 6)

end

local function Build(p)
    panel = p

    -- Form background
    form = CreateFrame("Frame", nil, panel)
    form:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -2)
    form:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -4, -2)
    form:SetHeight(FORM_HEIGHT.item)
    form:SetFrameLevel(panel:GetFrameLevel() + 10)
    local formBg = form:CreateTexture(nil, "BACKGROUND")
    formBg:SetAllPoints()
    formBg:SetColorTexture(0, 0, 0, 0.25)

    -- Item / Rule switch
    local prevMode
    for _, m in ipairs({ { key = "item", label = "Item" }, { key = "rule", label = "Rule" } }) do
        local b = CreateFrame("Button", nil, form, "UIPanelButtonTemplate")
        b.key = m.key
        b:SetSize(56, 20)
        b:SetText(m.label)
        if prevMode then b:SetPoint("LEFT", prevMode, "RIGHT", 4, 0) else b:SetPoint("TOPLEFT", form, "TOPLEFT", 8, -6) end
        b:SetScript("OnClick", function(self) SetMode(self.key) end)
        modeButtons[#modeButtons + 1] = b
        prevMode = b
    end
    local modeHint = form:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    modeHint:SetPoint("LEFT", prevMode, "RIGHT", 10, 0)
    modeHint:SetText("Item: one specific item.  Rule: any gear that fits.")

    BuildItemPane()
    BuildRulePane()
    BuildQtyNoteAndPayment()
    BuildList()

    ns:RegisterCallback("WISHLIST_CHANGED", function() if panel:IsVisible() then Refresh() end end)
    panel:SetScript("OnShow", Refresh)

    panel:HookScript("OnHide", HidePickList)

    ResetForm()
    SetMode("item")
    Refresh()
end

ns.MainFrame:RegisterTab("wishlist", "Wishlist", 20, Build)
