-- Modules\MailProbe.lua: TEMPORARY developer check for the mailbox panel (SPEC section 5,
-- step 1). Removed once the panel is built.
--
-- Forever blocked guild chat from a plain addon button click, so before building the
-- panel we check what an addon may do to Blizzard's Send Mail form from a click:
--   1. "Fill": set recipient + subject, split 1 off a stack in your bags and attach it.
--   2. "Clear": take the attachment back out and empty recipient + subject.
-- It NEVER sends: SendMail is never called, money and COD fields are never touched.
-- Every step, and anything the game blocks (ADDON_ACTION_BLOCKED/FORBIDDEN), is printed.
local _, ns = ...

local panel
local watching = false
local blocked = {}

local function Say(ok, text)
    DEFAULT_CHAT_FRAME:AddMessage(("  %s %s"):format(ok and "|cff40ff40OK|r" or "|cffff4040FAIL|r", text))
end

local function OnBlocked(event, addon, func)
    if watching and addon == ns.name then blocked[#blocked + 1] = event .. ": " .. tostring(func) end
end
ns:RegisterEvent("ADDON_ACTION_BLOCKED", OnBlocked)
ns:RegisterEvent("ADDON_ACTION_FORBIDDEN", OnBlocked)

local function NameBox() return SendMailNameEditBox or (SendMailFrame and SendMailFrame.SendMailNameEditBox) end
local function SubjectBox() return SendMailSubjectEditBox or (SendMailFrame and SendMailFrame.SendMailSubjectEditBox) end

local function SendMailOpen()
    return SendMailFrame and SendMailFrame:IsVisible()
end

local function ReportBlocked(step)
    if #blocked == 0 then
        Say(true, step .. ": nothing blocked by the game")
    else
        for _, b in ipairs(blocked) do Say(false, step .. ": " .. b) end
    end
    wipe(blocked)
end

-- A mailable stack of 2+ in my bags (not soulbound, not locked), or nil.
local function FindStack()
    local C = C_Container
    if not C or not C.GetContainerItemInfo then return nil end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C.GetContainerNumSlots(bag) or 0 do
            local info = C.GetContainerItemInfo(bag, slot)
            if info and (info.stackCount or 1) >= 2 and not info.isLocked and not info.isBound then
                local bound = false
                if C_Item and C_Item.IsBound and ItemLocation then
                    local ok, b = pcall(C_Item.IsBound, ItemLocation:CreateFromBagAndSlot(bag, slot))
                    bound = ok and b
                end
                if not bound then return bag, slot, info end
            end
        end
    end
end

local lastSplit -- { bag, slot, eBag, eSlot }: Clear puts the split item back on its stack

-- An empty slot in my bags, or nil.
local function FindEmpty()
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local free, family = C_Container.GetContainerNumFreeSlots(bag)
        if (free or 0) > 0 and (family or 0) == 0 then -- normal bags only, not profession bags
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                if not C_Container.GetContainerItemInfo(bag, slot) then return bag, slot end
            end
        end
    end
end
-- Calls done(ok, seconds) once test() is true (checked on bag/lock/mail events), or
-- done(false, seconds) after timeout seconds.
local waitFrame = CreateFrame("Frame")
local function WaitFor(test, timeout, done)
    local t0, finished = GetTime(), false
    local function finish(ok)
        if finished then return end
        finished = true
        waitFrame:UnregisterAllEvents()
        waitFrame:SetScript("OnEvent", nil)
        done(ok, GetTime() - t0)
    end
    if test() then finish(true) return end
    waitFrame:RegisterEvent("BAG_UPDATE_DELAYED")
    waitFrame:RegisterEvent("ITEM_LOCK_CHANGED")
    waitFrame:RegisterEvent("MAIL_SEND_INFO_UPDATE")
    waitFrame:SetScript("OnEvent", function()
        -- Lock changes land a moment after the event; check now and once just after.
        if test() then finish(true) return end
        C_Timer.After(0.1, function() if not finished and test() then finish(true) end end)
    end)
    C_Timer.After(timeout, function() finish(test()) end)
end

local function Fill()
    ns:Print("Mail probe: Fill")
    if not SendMailOpen() then ns:Print("Open the Send Mail tab first.") return end
    watching = true
    wipe(blocked)

    -- 1. Recipient and subject.
    local nameBox, subjectBox = NameBox(), SubjectBox()
    if nameBox then
        nameBox:SetText(ns:PlayerName())
        Say(nameBox:GetText() == ns:PlayerName(), "recipient filled (your own name; nothing is sent)")
    else
        Say(false, "recipient box not found")
    end
    if subjectBox then
        subjectBox:SetText("Unc's Tavern: probe")
        Say(subjectBox:GetText() == "Unc's Tavern: probe", "subject filled")
    else
        Say(false, "subject box not found")
    end

    -- 2. Split 1 off a stack and attach it.
    Say(C_Container and C_Container.SplitContainerItem ~= nil, "C_Container.SplitContainerItem exists")
    Say(ClickSendMailItemButton ~= nil, "ClickSendMailItemButton exists")
    Say(GetSendMailItem ~= nil, "GetSendMailItem exists")
    local bag, slot, info = FindStack()
    if not bag then
        Say(false, "no mailable stack of 2 or more in your bags: put one in (e.g. cloth or herbs) and try again")
    elseif C_Container.SplitContainerItem and ClickSendMailItemButton then
        if GetSendMailItem(1) then
            Say(false, "attachment slot 1 is already filled: click Clear first")
            ReportBlocked("Fill") watching = false return
        end
        if CursorHasItem and CursorHasItem() then ClearCursor() end
        -- Attachments point at a bag slot (the whole stack in it), so split 1 into an
        -- EMPTY bag slot first, wait until the server has finished (bag events, not a
        -- fixed timer), then attach that slot.
        local eBag, eSlot = FindEmpty()
        if not eBag then
            Say(false, "no empty slot in a normal bag: free one up and try again")
            ReportBlocked("Fill") watching = false return
        end
        ns:Print(("  Splitting 1 off %s (stack of %d, bag %d slot %d) into empty bag %d slot %d"):format(
            info.hyperlink or "?", info.stackCount or 0, bag, slot, eBag, eSlot))
        C_Container.SplitContainerItem(bag, slot, 1)
        Say(CursorHasItem and CursorHasItem(), "1 item is on the cursor after the split")
        C_Container.PickupContainerItem(eBag, eSlot)
        Say(not (CursorHasItem and CursorHasItem()), "cursor empty after dropping it in the empty slot")
        lastSplit = { bag = bag, slot = slot, eBag = eBag, eSlot = eSlot }
        WaitFor(function() -- split finished: new slot has exactly 1, nothing locked
            local new = C_Container.GetContainerItemInfo(eBag, eSlot)
            local old = C_Container.GetContainerItemInfo(bag, slot)
            return new and new.stackCount == 1 and not new.isLocked and not (old and old.isLocked)
        end, 5, function(ok, took)
            local new = C_Container.GetContainerItemInfo(eBag, eSlot)
            Say(ok, ("split finished in %.1f s: new slot holds %s"):format(took,
                new and (new.stackCount .. " item(s)") or "nothing"))
            if not ok then ReportBlocked("Fill") watching = false return end
            C_Container.PickupContainerItem(eBag, eSlot)
            Say(CursorHasItem and CursorHasItem(), "picked up the single item")
            ClickSendMailItemButton(1)
            WaitFor(function() return GetSendMailItem(1) ~= nil end, 3, function(ok2, took2)
                local r = { GetSendMailItem(1) }
                Say(ok2 and r[4] == 1, ("attached in %.1f s: slot 1 holds %s x%s"):format(
                    took2, tostring(r[1]), tostring(r[4])))
                if CursorHasItem and CursorHasItem() then
                    ClearCursor()
                    Say(false, "item was still on the cursor (put back)")
                end
                ReportBlocked("Fill")
                watching = false
                ns:Print("Look at the Send Mail form now (it should show 1), then click Clear. Don't press Send.")
            end)
        end)
        return
    end
    ReportBlocked("Fill")
    watching = false
end

local function Clear()
    ns:Print("Mail probe: Clear")
    if not SendMailOpen() then ns:Print("Open the Send Mail tab first.") return end
    watching = true
    wipe(blocked)
    local had = GetSendMailItem and GetSendMailItem(1)
    if had and ClickSendMailItemButton then
        ClickSendMailItemButton(1, true) -- true = take the attachment back out
    end
    local nameBox, subjectBox = NameBox(), SubjectBox()
    if nameBox then nameBox:SetText("") end
    if subjectBox then subjectBox:SetText("") end
    C_Timer.After(0.5, function()
        if had then
            local still = GetSendMailItem and GetSendMailItem(1)
            Say(still == nil, "attachment taken back out (it should be back in your bags)")
        else
            ns:Print("  (no attachment to remove)")
        end
        Say((not nameBox or nameBox:GetText() == "") and (not subjectBox or subjectBox:GetText() == ""),
            "recipient and subject emptied")
        -- Tidy up: put the split-off item back on its original stack.
        local sp = lastSplit
        lastSplit = nil
        if sp and C_Container.GetContainerItemInfo(sp.eBag, sp.eSlot) then
            C_Container.PickupContainerItem(sp.eBag, sp.eSlot)
            C_Container.PickupContainerItem(sp.bag, sp.slot)
            if CursorHasItem and CursorHasItem() then ClearCursor() end
            C_Timer.After(0.8, function()
                Say(not C_Container.GetContainerItemInfo(sp.eBag, sp.eSlot), "split item put back on its stack")
                ReportBlocked("Clear")
                watching = false
            end)
            return
        end
        ReportBlocked("Clear")
        watching = false
    end)
end

local function CreatePanel()
    panel = CreateFrame("Frame", "UncsTavernMailProbe", UIParent, "BasicFrameTemplateWithInset")
    panel:SetSize(200, 110)
    panel:SetFrameStrata("DIALOG")
    panel:SetMovable(true)
    panel:EnableMouse(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    if panel.TitleText then panel.TitleText:SetText("Mail probe") end
    local fill = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    fill:SetSize(160, 24)
    fill:SetPoint("TOP", panel, "TOP", 0, -34)
    fill:SetText("1. Fill")
    fill:SetScript("OnClick", Fill)
    local clear = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clear:SetSize(160, 24)
    clear:SetPoint("TOP", fill, "BOTTOM", 0, -8)
    clear:SetText("2. Clear")
    clear:SetScript("OnClick", Clear)
end

-- /tavern mailprobe: shows the probe panel next to the mail window (a click on its
-- buttons is the real test, because the panel will work from clicks too).
ns:RegisterCommand("mailprobe", function()
    if not SendMailOpen() then ns:Print("Open a mailbox and the Send Mail tab first, then type /tavern mailprobe again.") return end
    if not panel then CreatePanel() end
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", MailFrame or SendMailFrame, "TOPRIGHT", 8, 0)
    panel:Show()
end, nil, true)
