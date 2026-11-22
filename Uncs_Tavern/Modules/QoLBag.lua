-- Modules\QoLBag.lua: "Sleeping bag not in your bags" (quality of life). Local only:
-- reads my own bags, nothing is sent.
--
-- The sleeping bag (gives Well Rested) is an item each character has or hasn't. Once
-- this character has been seen carrying one, a small warning stays on screen whenever
-- it isn't in the bags (left in the bank, sold, deleted), until it's back or I click
-- Ignore. Ignore lasts until the sleeping bag is in the bags again. Never before the
-- addon has seen one on this character, and nothing at max level (Well Rested only
-- matters for XP).
--
-- Finding it: an item whose use spell is Well Rested, or (English clients) named
-- "Sleeping Bag". Found item IDs are remembered account-wide (db.qolBagIDs), so later
-- checks are by ID only.
-- Event-driven: BAG_UPDATE_DELAYED, a check after login, PLAYER_LEVEL_UP.
local _, ns = ...

local WELL_RESTED_ID = 429959
local MAX_LEVEL      = 60
local LOGIN_DELAY    = 12

local Bag = {}
ns.QoLBag = Bag

local checked = {} -- [itemID] = true: looked at this session, not a sleeping bag

local function S() return ns.db.settings end

local function Char()
    local c = ns.charDB.qolBag
    if type(c) ~= "table" then c = {} ns.charDB.qolBag = c end
    return c
end

local function AtMaxLevel()
    local lvl = UnitLevel("player")
    return type(lvl) == "number" and lvl >= MAX_LEVEL
end

---------------------------------------------------------------------------
-- Looking through the bags
---------------------------------------------------------------------------
local function IsSleepingBag(id)
    if ns.db.qolBagIDs[id] then return true end
    if checked[id] then return false end
    local _, spellID = C_Item.GetItemSpell(id)
    if spellID == WELL_RESTED_ID then ns.db.qolBagIDs[id] = true return true end
    local name = C_Item.GetItemInfo(id)
    if not name then return false end -- not cached yet: ask again on the next scan
    checked[id] = true
    if type(name) == "string" and name:lower():find("sleeping bag", 1, true) then
        ns.db.qolBagIDs[id] = true
        return true
    end
    return false
end

-- The sleeping bag's item ID if it's in my bags, else nil.
function Bag:Find()
    if not (C_Container and C_Container.GetContainerNumSlots) then return nil end
    local last = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
    for bag = 0, last do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local id = C_Container.GetContainerItemID(bag, slot)
            if id and IsSleepingBag(id) then return id end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- The warning (stays until the bag is back or Ignore)
---------------------------------------------------------------------------
local warn

local function SavePos()
    local point, _, relPoint, x, y = warn:GetPoint(1)
    ns.charDB.qolBagPos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function CreateWarn()
    warn = CreateFrame("Frame", "UncsTavernSleepingBagWarning", UIParent, "BackdropTemplate")
    warn:SetSize(300, 44)
    warn:SetFrameStrata("MEDIUM")
    warn:SetClampedToScreen(true)
    warn:SetMovable(true)
    warn:EnableMouse(true)
    warn:RegisterForDrag("LeftButton")
    warn:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    warn:SetBackdropColor(0, 0, 0, 0.85)
    warn:SetBackdropBorderColor(1, 0.35, 0.2, 1)
    warn.icon = warn:CreateTexture(nil, "ARTWORK")
    warn.icon:SetSize(28, 28)
    warn.icon:SetPoint("LEFT", warn, "LEFT", 9, 0)
    warn.ignore = CreateFrame("Button", nil, warn, "UIPanelButtonTemplate")
    warn.ignore:SetSize(64, 22)
    warn.ignore:SetPoint("RIGHT", warn, "RIGHT", -9, 0)
    warn.ignore:SetText("Ignore")
    warn.ignore:SetScript("OnClick", function()
        Char().ignored = true
        warn:Hide()
        ns:Print("Sleeping bag warning ignored on this character until the sleeping bag is in your bags again.")
    end)
    warn.title = warn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    warn.title:SetPoint("TOPLEFT", warn.icon, "TOPRIGHT", 9, 0)
    warn.title:SetPoint("RIGHT", warn.ignore, "LEFT", -6, 0)
    warn.title:SetJustifyH("LEFT")
    warn.title:SetText("Sleeping bag not in your bags")
    warn.text = warn:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    warn.text:SetPoint("TOPLEFT", warn.title, "BOTTOMLEFT", 0, -3)
    warn.text:SetPoint("RIGHT", warn.ignore, "LEFT", -6, 0)
    warn.text:SetJustifyH("LEFT")
    warn.text:SetText("Get it from your bank to keep Well Rested.")

    warn:SetScript("OnDragStart", function(self) self:StartMoving() end)
    warn:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePos() end)
    warn:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            ns.charDB.qolBagPos = nil
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
        end
    end)
    warn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(ns.title)
        GameTooltip:AddLine("This character had a sleeping bag before. The warning stays until it's back in your bags.", 1, 1, 1, true)
        GameTooltip:AddLine("Drag to move; right-click puts it back in the middle. Turn it off in Settings > Quality of life.",
            0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    warn:SetScript("OnLeave", GameTooltip_Hide)

    local p = ns.charDB.qolBagPos
    if type(p) == "table" and type(p.point) == "string" and type(p.x) == "number" and type(p.y) == "number" then
        warn:SetPoint(p.point, UIParent, type(p.relPoint) == "string" and p.relPoint or p.point, p.x, p.y)
    else
        warn:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    end
    warn:Hide()
end

local function Icon()
    for id in pairs(ns.db.qolBagIDs) do
        local tex = C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
        if tex then return tex end
    end
    return 134065 -- a bedroll icon (fallback)
end

local function ShowWarn(show)
    if show then
        if not warn then CreateWarn() end
        warn.icon:SetTexture(Icon())
        if not warn:IsShown() then
            warn:Show()
            PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
        end
    elseif warn then
        warn:Hide()
    end
end

---------------------------------------------------------------------------
-- Checking
---------------------------------------------------------------------------
local ready = false

function Bag:Update()
    if not ready or not ns.db then return end
    local c = Char()
    local found = self:Find()
    if found then
        c.seen, c.ignored = true, nil
        ShowWarn(false)
        return
    end
    ShowWarn(c.seen and not c.ignored and S().qolSleepingBag and not AtMaxLevel())
end

ns:RegisterEvent("BAG_UPDATE_DELAYED", function() Bag:Update() end)
ns:RegisterEvent("PLAYER_LEVEL_UP", function() C_Timer.After(1, function() Bag:Update() end) end)
ns:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
    if ready and not Char().seen then Bag:Update() end -- an item name arrived: maybe the bag
end)
local started = false
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    if started then return end
    started = true
    C_Timer.After(LOGIN_DELAY, function() ready = true Bag:Update() end)
end)

-- For /tavern qol.
function Bag:Status()
    local c = Char()
    local found = ready and self:Find()
    if found then
        local name = C_Item.GetItemInfo(found) or ("item " .. found)
        return ("Sleeping bag: in your bags (%s)."):format(name)
    elseif not c.seen then
        return "Sleeping bag: not seen on this character yet, so no warning."
    elseif c.ignored then
        return "Sleeping bag: not in your bags (warning ignored until it's back)."
    end
    return "Sleeping bag: not in your bags."
end

ns:RegisterCallback("VALIDATE_DB", function()
    if type(ns.db.qolBagIDs) ~= "table" then ns.db.qolBagIDs = {} end
    for k, v in pairs(ns.db.qolBagIDs) do
        if not ns:Int(k, 1) or v ~= true then ns.db.qolBagIDs[k] = nil end
    end
    local c = ns.charDB.qolBag
    if c ~= nil and type(c) ~= "table" then ns.charDB.qolBag = nil end
end)

ns.Settings:RegisterToggle({
    category = "qol", key = "qolSleepingBag", order = 15, indent = 1,
    label = "Warn when my sleeping bag isn't in my bags",
    description = "Only on characters the addon has seen carrying a sleeping bag. The warning stays until it's back "
        .. "in your bags, or until you click Ignore.",
    onChange = function() Bag:Update() end,
})
