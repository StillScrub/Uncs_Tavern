-- Modules\MinimapButton.lua: minimap button.
--   Left-click: open/close the window.  Right-click: open Settings.  Drag: move around the minimap.
-- Position (angle) and visibility are saved account-wide in ns.db.settings.
-- An OnUpdate script runs only while the button is being dragged, to follow the cursor;
-- it is removed on release.
local _, ns = ...

local ICON = "Interface\\AddOns\\Uncs_Tavern\\Media\\Icon"
local DEFAULT_ANGLE = 210 -- degrees, measured counter-clockwise from the right (lower left of the minimap)

local button

local function UpdatePosition()
    local angle = math.rad(ns.db.settings.minimapAngle or DEFAULT_ANGLE)
    local radius = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    ns.db.settings.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
    UpdatePosition()
end

local function OnEnter(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(ns.title)
    GameTooltip:AddLine("|cffffffffLeft-click:|r open / close", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffRight-click:|r settings", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("|cffffffffDrag:|r move", 0.8, 0.8, 0.8)
    GameTooltip:Show()
end

local function Create()
    button = CreateFrame("Button", "UncsTavernMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(19, 19)
    icon:SetPoint("TOPLEFT", 6, -5)
    if button.CreateMaskTexture and icon.AddMaskTexture then
        local mask = button:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(icon)
        icon:AddMaskTexture(mask)
    end

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            ns.MainFrame:Show("settings")
        else
            ns.MainFrame:Toggle()
        end
    end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)
    button:SetScript("OnEnter", OnEnter)
    button:SetScript("OnLeave", GameTooltip_Hide)

    UpdatePosition()
end

local function UpdateVisibility()
    if ns.db.settings.minimapButton then
        if not button then Create() end
        button:Show()
    elseif button then
        button:Hide()
    end
end

ns:RegisterEvent("PLAYER_LOGIN", UpdateVisibility)

ns.Settings:RegisterToggle({
    key = "minimapButton",
    label = "Show minimap button",
    description = "Left-click opens the window, right-click opens Settings, drag to move it.",
    order = 90,
    onChange = UpdateVisibility,
})
