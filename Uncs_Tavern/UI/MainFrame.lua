-- UI\MainFrame.lua: the main window with tabs along the bottom.
-- Tabs are registered by modules at load time:
--   ns.MainFrame:RegisterTab(key, label, order, buildFn)
-- buildFn(panel) runs once, the first time that tab is shown.
local _, ns = ...

local MainFrame = {}
ns.MainFrame = MainFrame

local FRAME_NAME = "UncsTavernMainFrame"
local ICON       = "Interface\\AddOns\\Uncs_Tavern\\Media\\Icon"
local WIDTH, HEIGHT = 700, 480

local tabs = {}   -- { key, label, order, build, panel }
local frame

function MainFrame:RegisterTab(key, label, order, build)
    assert(not frame, "Unc's Tavern: tabs must be registered at load time")
    tabs[#tabs + 1] = { key = key, label = label, order = order or 100, build = build }
end

local function PlaySoundSafe(kit)
    if SOUNDKIT and SOUNDKIT[kit] then PlaySound(SOUNDKIT[kit]) end
end

local function SelectTab(index)
    PanelTemplates_SetTab(frame, index)
    for i, t in ipairs(tabs) do
        if i == index then
            if not t.panel then
                local parent = frame.Inset or frame
                t.panel = CreateFrame("Frame", nil, parent)
                t.panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -4)
                t.panel:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -4, 4)
                if t.build then t.build(t.panel) end
            end
            t.panel:Show()
        elseif t.panel then
            t.panel:Hide()
        end
    end
end

local function Create()
    table.sort(tabs, function(a, b) return a.order < b.order end)

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
    frame:Hide()
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(frame) end

    -- Title
    if frame.SetTitle then
        frame:SetTitle(ns.title)
    elseif frame.TitleText then
        frame.TitleText:SetText(ns.title)
    end

    -- Portrait icon
    if frame.SetPortraitToAsset then
        frame:SetPortraitToAsset(ICON)
    else
        local p = frame.portrait or (frame.PortraitContainer and frame.PortraitContainer.portrait)
        if p then SetPortraitToTexture(p, ICON) end
    end

    -- Bottom tabs (same template as the Character window tabs)
    frame.Tabs = {}
    for i, t in ipairs(tabs) do
        local tab = CreateFrame("Button", FRAME_NAME .. "Tab" .. i, frame, "PanelTabButtonTemplate")
        tab:SetID(i)
        tab:SetText(t.label)
        if i == 1 then
            tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2)
        else
            tab:SetPoint("TOPLEFT", frame.Tabs[i - 1], "TOPRIGHT", 3, 0)
        end
        tab:SetScript("OnClick", function(self)
            PlaySoundSafe("IG_CHARACTER_INFO_TAB")
            SelectTab(self:GetID())
        end)
        PanelTemplates_TabResize(tab, 0)
        frame.Tabs[i] = tab
    end
    PanelTemplates_SetNumTabs(frame, #tabs)

    -- HookScript so we don't replace any handlers the template sets up.
    frame:HookScript("OnShow", function() PlaySoundSafe("IG_CHARACTER_INFO_OPEN") end)
    frame:HookScript("OnHide", function() PlaySoundSafe("IG_CHARACTER_INFO_CLOSE") end)

    -- Escape closes the window
    tinsert(UISpecialFrames, FRAME_NAME)

    if #tabs > 0 then SelectTab(1) end
end

function MainFrame:Show(key)
    if not frame then Create() end
    if key then
        for i, t in ipairs(tabs) do
            if t.key == key then SelectTab(i) break end
        end
    end
    frame:Show()
end

function MainFrame:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Show()
    end
end
