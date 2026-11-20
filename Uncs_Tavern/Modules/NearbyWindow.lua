-- Modules\NearbyWindow.lua: a small movable window listing nearby enemy players.
--
-- Stays on screen like other trackers (no need to open the Unc's Tavern window).
-- Reads Enemies.lua only; nothing is sent.
--   Drag to move (unless locked); the position is saved per character (charDB.nearbyPos).
--   Rows: class-colored name, level, seconds since seen. Hover = details,
--   right-click a row = ignore / forget (same menu as the PvP tab).
--   Right-click the title = window options. The X hides it (/tavern nearby brings it back).
-- Updates on ENEMIES_CHANGED, plus a ticker every REFRESH seconds while it shows enemies
-- (they age out of "nearby" without any game event).
local _, ns = ...
local Enemies = ns.Enemies

local WIDTH, ROW_H, TITLE_H, MAX_ROWS = 230, 16, 22, 10
local REFRESH = 5

local frame, rows, ticker = nil, {}, nil

local function S() return ns.db.settings end

local function Tab() return ns.PvPTab end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------
local function SavePosition()
    local point, _, relPoint, x, y = frame:GetPoint(1)
    ns.charDB.nearbyPos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestorePosition()
    local p = ns.charDB.nearbyPos
    frame:ClearAllPoints()
    if type(p) == "table" and type(p.point) == "string" and type(p.x) == "number" and type(p.y) == "number" then
        frame:SetPoint(p.point, UIParent, type(p.relPoint) == "string" and p.relPoint or p.point, p.x, p.y)
    else
        frame:SetPoint("RIGHT", UIParent, "RIGHT", -260, 120)
    end
end

---------------------------------------------------------------------------
-- Menus
---------------------------------------------------------------------------
local Update

local function SetAndUpdate(key, value)
    S()[key] = value
    ns:Fire("SETTINGS_REFRESH")
    Update()
end

local function WindowMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Nearby enemies")
        root:CreateCheckbox("Lock position", function() return S().nearbyLocked end,
            function() SetAndUpdate("nearbyLocked", not S().nearbyLocked) end)
        root:CreateCheckbox("Hide when nobody is nearby", function() return S().nearbyHideEmpty end,
            function() SetAndUpdate("nearbyHideEmpty", not S().nearbyHideEmpty) end)
        root:CreateButton("Open the PvP tab", function() if ns.MainFrame then ns.MainFrame:Show("pvp") end end)
        root:CreateButton("Hide this window", function()
            SetAndUpdate("nearbyWindow", false)
            ns:Print("Nearby window hidden. Bring it back with /tavern nearby or Settings > PvP.")
        end)
    end)
end

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function CreateRow(i)
    local r = CreateFrame("Button", nil, frame)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(TITLE_H + (i - 1) * ROW_H))
    r:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -(TITLE_H + (i - 1) * ROW_H))
    r:RegisterForClicks("RightButtonUp")
    r.bar = r:CreateTexture(nil, "BACKGROUND")
    r.bar:SetAllPoints()
    r.bar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    local hl = r:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.12)
    r.right = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    r.right:SetPoint("RIGHT", r, "RIGHT", -4, 0)
    r.right:SetJustifyH("RIGHT")
    r.name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", r, "LEFT", 4, 0)
    r.name:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r:SetScript("OnClick", function(self, button)
        if self.item and Tab() then Tab().RowMenu(self.item, button, self) end
    end)
    r:SetScript("OnEnter", function(self) if self.item and Tab() then Tab().ShowTooltip(self.item, self) end end)
    r:SetScript("OnLeave", GameTooltip_Hide)
    -- Rows don't block dragging the window.
    r:RegisterForDrag("LeftButton")
    r:SetScript("OnDragStart", function() frame:GetScript("OnDragStart")(frame) end)
    r:SetScript("OnDragStop", function() frame:GetScript("OnDragStop")(frame) end)
    return r
end

local function Create()
    frame = CreateFrame("Frame", "UncsTavernNearby", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, TITLE_H + ROW_H + 6)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
    frame:SetBackdropBorderColor(0.7, 0.55, 0.3, 0.9)
    frame:SetScript("OnDragStart", function(self)
        if not S().nearbyLocked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then WindowMenu(self) end
    end)

    -- The addon's mug icon, left of the title: click opens the PvP tab.
    local icon = CreateFrame("Button", nil, frame)
    icon:SetSize(16, 16)
    icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -4)
    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\AddOns\\Uncs_Tavern\\Media\\Icon")
    local glow = icon:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetTexture("Interface\\AddOns\\Uncs_Tavern\\Media\\Icon")
    glow:SetBlendMode("ADD")
    glow:SetAlpha(0.4)
    icon:SetScript("OnClick", function() if ns.MainFrame then ns.MainFrame:Show("pvp") end end)
    icon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(ns.title)
        GameTooltip:AddLine("Click to open the PvP tab.", 1, 1, 1)
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", GameTooltip_Hide)
    icon:RegisterForDrag("LeftButton")
    icon:SetScript("OnDragStart", function() frame:GetScript("OnDragStart")(frame) end)
    icon:SetScript("OnDragStop", function() frame:GetScript("OnDragStop")(frame) end)

    frame.title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    frame.title:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    frame.title:SetJustifyH("LEFT")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(20, 20)
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function()
        SetAndUpdate("nearbyWindow", false)
        ns:Print("Nearby window hidden. Bring it back with /tavern nearby or Settings > PvP.")
    end)

    frame.empty = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    frame.empty:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -(TITLE_H + 2))
    frame.empty:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
    frame.empty:SetJustifyH("LEFT")
    frame.empty:SetWordWrap(false)

    for i = 1, MAX_ROWS do rows[i] = CreateRow(i) end
    RestorePosition()
end

local function StopTicker()
    if ticker then ticker:Cancel() ticker = nil end
end

function Update()
    local want = ns.db and S().nearbyWindow and Enemies:Enabled()
    if not want then
        StopTicker()
        if frame then frame:Hide() end
        return
    end
    if not frame then Create() end

    local list = Enemies:TrackingHere() and Enemies:Nearby() or {}
    if #list == 0 and S().nearbyHideEmpty then
        StopTicker()
        frame:Hide()
        return
    end

    local tab = Tab()
    local shown = math.min(#list, MAX_ROWS)
    frame.title:SetText(#list > 0 and ("Nearby enemies (%d)"):format(#list) or "Nearby enemies")
    for i, r in ipairs(rows) do
        local item = list[i]
        r.item = item
        if item and tab then
            local c = tab.ClassColor(item.e)
            r.bar:SetVertexColor(c.r, c.g, c.b, 0.35)
            r.name:SetText(tab.DisplayName(item.name))
            local lvl = tab.LevelText(item.e)
            r.right:SetText(("%s  |cff999999%s|r"):format(lvl ~= "" and lvl or "", tab.Ago(item.ago)))
            r:Show()
        else
            r:Hide()
        end
    end
    if #list == 0 then
        frame.empty:SetText(Enemies:TrackingHere() and "Nobody nearby." or "Not tracking here.")
        frame.empty:Show()
    else
        frame.empty:Hide()
    end
    if #list > MAX_ROWS then
        frame.title:SetText(("Nearby enemies (%d, showing %d)"):format(#list, MAX_ROWS))
    end
    frame:SetHeight(TITLE_H + math.max(shown, 1) * ROW_H + 8)
    frame:Show()

    if #list > 0 and not ticker then
        ticker = C_Timer.NewTicker(REFRESH, function() Update() end)
    elseif #list == 0 then
        StopTicker()
    end
end

ns:RegisterCallback("ENEMIES_CHANGED", function() Update() end)
ns:RegisterCallback("KOS_CHANGED", function() if frame and frame:IsShown() then Update() end end)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() C_Timer.After(1, Update) end)

---------------------------------------------------------------------------
-- Settings > PvP and /tavern nearby
---------------------------------------------------------------------------
ns.Settings:RegisterToggle({
    category = "pvp", key = "nearbyWindow", order = 12, indent = 1,
    label = "Show the Nearby window",
    description = "A small window you can move anywhere, listing enemy players near you. "
        .. "Drag it to move it; right-click its title for options. Also: /tavern nearby.",
    disabled = function() return not S().enemyTracker end,
    onChange = function() Update() end,
})
ns.Settings:RegisterToggle({
    category = "pvp", key = "nearbyLocked", order = 13, indent = 2,
    label = "Lock its position",
    disabled = function() return not (S().enemyTracker and S().nearbyWindow) end,
})
ns.Settings:RegisterToggle({
    category = "pvp", key = "nearbyHideEmpty", order = 14, indent = 2,
    label = "Hide it when nobody is nearby",
    disabled = function() return not (S().enemyTracker and S().nearbyWindow) end,
    onChange = function() Update() end,
})

ns:RegisterCommand("nearby", function()
    SetAndUpdate("nearbyWindow", not S().nearbyWindow)
    if S().nearbyWindow and not Enemies:Enabled() then
        ns:Print("Enemy tracking is off: turn on Settings > PvP > Remember enemy players.")
    end
end, "show or hide the Nearby enemies window")
