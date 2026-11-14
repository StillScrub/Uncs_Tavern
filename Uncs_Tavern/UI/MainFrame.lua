-- UI\MainFrame.lua: the Unc's Tavern window, swapped with the Guild & Communities window (J).
--
-- Our icon sits inside the guild window's portrait (top-left). Clicking it closes the
-- guild window and opens our own window at the same spot. Our window has the same icon
-- in its portrait; clicking it closes ours and reopens the guild window at our spot.
-- Only one of the two is ever open.
--
-- Our window can be dragged (title bar / background) and resized (grip, bottom-right).
-- The button next to the close X resets it to the guild window's size and position.
-- Size: follows the guild window until the player resizes ours; reset goes back to following.
--
-- What we do to Blizzard's UI, and nothing more:
--   * our button (parented to CommunitiesFrame) over its portrait, with a copy of the
--     window's own portrait-ring art drawn on top so it looks built in;
--   * HideUIPanel / ShowUIPanel(CommunitiesFrame) when the player swaps, and placing
--     the guild window's top-left where ours was, so the swap is seamless;
--   * HookScript OnShow on CommunitiesFrame (show the button, close our window).
--
-- Tabs are registered by modules at load time:
--   ns.MainFrame:RegisterTab(key, label, order, buildFn)
-- label may be a string or a function returning one (e.g. the live guild name).
-- buildFn(panel) runs once, the first time that tab is shown.
local _, ns = ...

local MainFrame = {}
ns.MainFrame = MainFrame

local FRAME_NAME = "UncsTavernMainFrame"
local ICON       = "Interface\\AddOns\\Uncs_Tavern\\Media\\Icon"
-- The guild window's large size (from /tavern frametest). In small mode (322 wide) our
-- content doesn't fit, so we use at least this width.
local DEFAULT_W, DEFAULT_H = 814, 426
local MIN_W, MIN_H = 780, 380
-- Frame-level offset for our buttons, so they draw above the window's own art
-- (+20 was hidden behind the windows' border and the guild emblem).
local ON_TOP = 500
-- Where a left-side UI panel opens, for when we have never seen the guild window.
local DEFAULT_X, DEFAULT_Y = 16, -116

local tabs = {}   -- { key, label, order, build, panel, button }
local frame, toggle

function MainFrame:RegisterTab(key, label, order, build)
    assert(not frame, "Unc's Tavern: tabs must be registered at load time")
    tabs[#tabs + 1] = { key = key, label = label, order = order or 100, build = build }
end

local function PlaySoundSafe(kit)
    if SOUNDKIT and SOUNDKIT[kit] then PlaySound(SOUNDKIT[kit]) end
end

local function LabelOf(t)
    local text = type(t.label) == "function" and t.label() or t.label
    return text or "?"
end

local function CharDB() return ns.charDB or {} end

---------------------------------------------------------------------------
-- Portrait art helpers
---------------------------------------------------------------------------
local function AddCircleMask(owner, ...)
    if not owner.CreateMaskTexture then return end
    local mask = owner:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints()
    for i = 1, select("#", ...) do
        local tex = select(i, ...)
        if tex.AddMaskTexture then tex:AddMaskTexture(mask) end
    end
end

-- Draw a copy of a window's top-left border piece (the one holding the portrait ring)
-- over our icon, so our icon sits inside the ring instead of on top of it.
-- Read-only: we only copy the art and anchor to it.
local function CopyRing(owner, window)
    local corner = window and window.NineSlice and window.NineSlice.TopLeftCorner
    if not corner then return end
    local ring = owner:CreateTexture(nil, "OVERLAY", nil, 7)
    local atlas = corner.GetAtlas and corner:GetAtlas()
    if atlas then
        ring:SetAtlas(atlas)
    else
        ring:SetTexture(corner:GetTexture())
        ring:SetTexCoord(corner:GetTexCoord())
    end
    ring:SetAllPoints(corner)
end

local function PortraitOf(window)
    if window.GetPortrait then
        local p = window:GetPortrait()
        if p then return p end
    end
    return window.portrait or (window.PortraitContainer and window.PortraitContainer.portrait)
end

-- A click target over a window's portrait: our icon (masked round), a faint round
-- hover glow, and the window's ring art on top.
local function CreatePortraitButton(name, window, portrait, tooltip, onClick)
    local b = CreateFrame("Button", name, window)
    b:SetAllPoints(portrait)
    -- Well above everything in the window (the guild window draws its guild emblem
    -- over the portrait in a high child frame). The ring copy below keeps it looking
    -- inset even though we're on top.
    b:SetFrameLevel(window:GetFrameLevel() + ON_TOP)

    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetAllPoints()
    local glow = b:CreateTexture(nil, "HIGHLIGHT")
    glow:SetColorTexture(1, 0.85, 0.5, 0.12)
    glow:SetAllPoints()
    AddCircleMask(b, icon, glow)
    CopyRing(b, window)

    b:SetScript("OnClick", onClick)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tooltip)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

local function SimpleTooltip(widget, text)
    widget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text)
        GameTooltip:Show()
    end)
    widget:SetScript("OnLeave", GameTooltip_Hide)
end

---------------------------------------------------------------------------
-- Geometry
--   charDB.guildPos  = last seen guild window { x, y, w, h } (UIParent coords)
--   charDB.tavernSize = { w, h } once the player resizes ours; nil = follow the guild window
---------------------------------------------------------------------------
local function TopLeftOf(f, target)
    local ratio = f:GetEffectiveScale() / target:GetEffectiveScale()
    return f:GetLeft() * ratio, f:GetTop() * ratio, f:GetWidth() * ratio, f:GetHeight() * ratio
end

-- Remember where the guild window is (call while it's shown).
local function RememberGuildWindow()
    local cf = CommunitiesFrame
    if not (cf and cf:IsShown() and cf:GetLeft()) then return end
    local x, y, w, h = TopLeftOf(cf, UIParent)
    CharDB().guildPos = { x = x, y = y, w = w, h = h }
end

local function ApplySize()
    local size = CharDB().tavernSize
    local g = CharDB().guildPos
    if size then
        frame:SetSize(size.w, size.h)
    elseif g then
        frame:SetSize(math.max(g.w, DEFAULT_W), math.max(g.h, MIN_H))
    else
        frame:SetSize(DEFAULT_W, DEFAULT_H)
    end
end

-- Put our window's top-left where the guild window is (or last was).
local function PlaceAtGuildWindow()
    local g = CharDB().guildPos
    frame:ClearAllPoints()
    if g then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", g.x, g.y)
    else
        frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", DEFAULT_X, DEFAULT_Y)
    end
    ApplySize()
end

---------------------------------------------------------------------------
-- Our window
---------------------------------------------------------------------------
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
            ns:Fire("TAB_SHOWN", t.key)
        elseif t.panel then
            t.panel:Hide()
        end
    end
end

local function SelectKey(key)
    for i, t in ipairs(tabs) do
        if t.key == key then SelectTab(i) return end
    end
    if #tabs > 0 then SelectTab(1) end
end

-- Refresh tab labels (the guild tab shows the live guild name).
function MainFrame:UpdateTabLabels()
    if not frame then return end
    for _, t in ipairs(tabs) do
        if t.button then
            t.button:SetText(LabelOf(t))
            PanelTemplates_TabResize(t.button, 0, nil, nil, 200)
        end
    end
end

local SwapToGuild -- defined below

local function ResetWindow()
    CharDB().tavernSize = nil
    RememberGuildWindow()
    PlaceAtGuildWindow()
end

-- The reset button uses Blizzard's own maximize/minimize template (the same red
-- button the guild window has), on our own frame, showing only its "minimize" arrow.
-- Setting the atlas by name rendered nothing on Forever, so we let the template
-- draw it. Fallback: a plain button with the refresh icon.
local function CreateResetButton()
    local close = frame.CloseButton or _G[FRAME_NAME .. "CloseButton"]
    local b
    local ok, mm = pcall(CreateFrame, "Frame", FRAME_NAME .. "ResetFrame", frame, "MaximizeMinimizeButtonFrameTemplate")
    if ok and mm and mm.MinimizeButton then
        if close then
            mm:SetPoint("RIGHT", close, "LEFT", 0, 0)
        else
            mm:SetPoint("TOPRIGHT", -20, 0)
        end
        mm:SetFrameLevel(frame:GetFrameLevel() + ON_TOP)
        if mm.MaximizeButton then mm.MaximizeButton:Hide() end
        mm.MinimizeButton:Show()
        b = mm.MinimizeButton
        b:SetFrameLevel(frame:GetFrameLevel() + ON_TOP + 1)
    else
        b = CreateFrame("Button", FRAME_NAME .. "ResetButton", frame)
        b:SetSize(20, 20)
        b:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        if close then
            b:SetPoint("RIGHT", close, "LEFT", -2, 0)
        else
            b:SetPoint("TOPRIGHT", -26, -4)
        end
        b:SetFrameLevel(frame:GetFrameLevel() + ON_TOP)
    end
    b:SetScript("OnClick", function()
        PlaySoundSafe("IG_MAINMENU_OPTION_CHECKBOX_ON")
        ResetWindow()
    end)
    SimpleTooltip(b, "Reset size and position to the guild window's")
end

local function CreateResizeGrip()
    frame:SetResizable(true)
    if frame.SetResizeBounds then
        frame:SetResizeBounds(MIN_W, MIN_H)
    elseif frame.SetMinResize then
        frame:SetMinResize(MIN_W, MIN_H)
    end
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetFrameLevel(frame:GetFrameLevel() + ON_TOP)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        CharDB().tavernSize = { w = frame:GetWidth(), h = frame:GetHeight() }
    end)
end

local function Create()
    table.sort(tabs, function(a, b) return a.order < b.order end)

    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "ButtonFrameTemplate")
    frame:Hide()
    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", DEFAULT_X, DEFAULT_Y)
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(frame) end

    if frame.SetTitle then
        frame:SetTitle(ns.title)
    elseif frame.TitleText then
        frame.TitleText:SetText(ns.title)
    end

    if frame.SetPortraitToAsset then
        frame:SetPortraitToAsset(ICON)
    end
    local portrait = PortraitOf(frame)
    if portrait then
        CreatePortraitButton(FRAME_NAME .. "Portrait", frame, portrait,
            "Back to Guild & Communities", function() SwapToGuild() end)
    end

    CreateResetButton()
    CreateResizeGrip()

    -- Bottom tabs (same template as the Character window tabs)
    frame.Tabs = {}
    for i, t in ipairs(tabs) do
        local tab = CreateFrame("Button", FRAME_NAME .. "Tab" .. i, frame, "PanelTabButtonTemplate")
        tab:SetID(i)
        if i == 1 then
            tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2)
        else
            tab:SetPoint("TOPLEFT", frame.Tabs[i - 1], "TOPRIGHT", 3, 0)
        end
        tab:SetScript("OnClick", function(self)
            PlaySoundSafe("IG_CHARACTER_INFO_TAB")
            SelectTab(self:GetID())
        end)
        t.button = tab
        frame.Tabs[i] = tab
    end
    PanelTemplates_SetNumTabs(frame, #tabs)
    MainFrame:UpdateTabLabels()

    -- Escape closes the window
    tinsert(UISpecialFrames, FRAME_NAME)
end

-- Open our window on the given tab (default: the first, the guild roster).
local function OpenTavern(key)
    if not frame then Create() end
    PlaceAtGuildWindow()
    MainFrame:UpdateTabLabels()
    SelectKey(key)
    if not frame:IsShown() then
        frame:Show()
        PlaySoundSafe("IG_CHARACTER_INFO_OPEN")
    end
end

---------------------------------------------------------------------------
-- Swapping
---------------------------------------------------------------------------
-- Guild window -> our window, same spot.
function MainFrame:SwapToTavern(key)
    RememberGuildWindow() -- read its position before it closes
    if CommunitiesFrame and CommunitiesFrame:IsShown() then HideUIPanel(CommunitiesFrame) end
    OpenTavern(key)
end

-- Our window -> guild window, at our window's top-left.
function SwapToGuild()
    local x, y
    if frame and frame:IsShown() and frame:GetLeft() then
        x, y = TopLeftOf(frame, UIParent)
        frame:Hide()
    end
    if CommunitiesFrame then
        ShowUIPanel(CommunitiesFrame)
    elseif ToggleGuildFrame then
        ToggleGuildFrame()
    end
    local cf = CommunitiesFrame
    if x and cf and cf:IsShown() then
        local scale = cf:GetEffectiveScale() / UIParent:GetEffectiveScale()
        cf:ClearAllPoints()
        cf:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    end
end

---------------------------------------------------------------------------
-- Our icon inside the guild window's portrait
---------------------------------------------------------------------------
local function UpdateToggleVisibility()
    if toggle then toggle:SetShown(IsInGuild()) end
end

local function CreateToggle()
    local cf = CommunitiesFrame
    local portrait = PortraitOf(cf) or _G.CommunitiesFramePortrait
    if not portrait then return end
    toggle = CreatePortraitButton("UncsTavernToggle", cf, portrait,
        ns.title .. " (click to switch)", function() MainFrame:SwapToTavern() end)

    -- Show hook only: show/hide our button, and keep just one window open
    -- (pressing J while ours is open closes ours).
    cf:HookScript("OnShow", function()
        UpdateToggleVisibility()
        if frame and frame:IsShown() then frame:Hide() end
    end)
    UpdateToggleVisibility()
end

local function TryAttach()
    if toggle or not CommunitiesFrame then return end
    CreateToggle()
end

ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if name == "Blizzard_Communities" then TryAttach() end
end)
-- In case another addon loaded Blizzard_Communities before us.
ns:RegisterEvent("PLAYER_LOGIN", TryAttach)
ns:RegisterEvent("PLAYER_GUILD_UPDATE", function()
    UpdateToggleVisibility()
    MainFrame:UpdateTabLabels()
end)

---------------------------------------------------------------------------
-- Public API (used by /tavern and the minimap button)
--   Ours open -> close it.  Guild window open -> swap to ours.
--   Neither -> open ours where the guild window last was.
-- Opening always starts on the guild tab unless a tab key is given.
---------------------------------------------------------------------------
function MainFrame:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
        PlaySoundSafe("IG_CHARACTER_INFO_CLOSE")
    elseif CommunitiesFrame and CommunitiesFrame:IsShown() then
        self:SwapToTavern()
    else
        OpenTavern()
    end
end

function MainFrame:Show(key)
    if frame and frame:IsShown() then
        SelectKey(key)
    elseif CommunitiesFrame and CommunitiesFrame:IsShown() then
        self:SwapToTavern(key)
    else
        OpenTavern(key)
    end
end
