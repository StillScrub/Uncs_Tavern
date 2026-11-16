-- UI\Dialog.lua: our own small question / number dialog (Claim, Got, Delete, moderation).
--
-- Why not Blizzard's StaticPopup: its dialog frames and their edit box are shared with
-- the game's own popups (guild invite, send money, ...), and anything an addon leaves
-- on them stays behind. Our Claim/Got popups set the shared edit box to numbers-only,
-- so the guild "Add member" box afterwards refused letters; and values our code wrote
-- into the shared frames can make the game block the action of the next Blizzard popup.
-- So we never use StaticPopup. This frame is ours alone.
--
--   ns.Dialog:Show({
--       text = "Question?",            -- plain text (already formatted)
--       accept = "OK", cancel = "Cancel",
--       edit = { numeric = true, maxLetters = 4, default = 5 },  -- optional input box
--                                      -- (width = n for a wider, left-aligned text box)
--       timeout = 120,                 -- optional, seconds
--       onAccept = function(text) end, -- text = the input box's text (or nil)
--   })
local _, ns = ...

local Dialog = {}
ns.Dialog = Dialog

local FRAME_NAME = "UncsTavernDialog"
local WIDTH = 380
local frame, current
local token = 0 -- changes on every Show, so an old timeout can't close a newer dialog

local function Accept()
    local opts = current
    local text = frame.edit:IsShown() and frame.edit:GetText() or nil
    frame:Hide()
    if opts and opts.onAccept then opts.onAccept(text) end
end

local function Create()
    frame = CreateFrame("Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, 140)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -180)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetScript("OnHide", function()
        frame.edit:ClearFocus()
        current = nil
    end)

    local title = frame.TitleText or frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not frame.TitleText then title:SetPoint("TOP", frame, "TOP", 0, -5) end
    title:SetText(ns.title)

    frame.text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    frame.text:SetPoint("TOP", frame, "TOP", 0, -36)
    frame.text:SetWidth(WIDTH - 40)
    frame.text:SetJustifyH("CENTER")
    frame.text:SetSpacing(2)

    frame.edit = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.edit:SetSize(80, 20)
    frame.edit:SetAutoFocus(false)
    frame.edit:SetJustifyH("CENTER")
    frame.edit:SetScript("OnEnterPressed", Accept)
    frame.edit:SetScript("OnEscapePressed", function() frame:Hide() end)

    frame.accept = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.accept:SetSize(110, 22)
    frame.accept:SetPoint("BOTTOMRIGHT", frame, "BOTTOM", -4, 12)
    frame.accept:SetScript("OnClick", Accept)

    frame.cancel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.cancel:SetSize(110, 22)
    frame.cancel:SetPoint("BOTTOMLEFT", frame, "BOTTOM", 4, 12)
    frame.cancel:SetScript("OnClick", function() frame:Hide() end)

    tinsert(UISpecialFrames, FRAME_NAME) -- Escape closes it
    frame:Hide()
end

function Dialog:Show(opts)
    if not frame then Create() end
    token = token + 1
    current = opts
    frame.text:SetText(opts.text or "")
    frame.accept:SetText(opts.accept or OKAY or "OK")
    frame.cancel:SetText(opts.cancel or CANCEL or "Cancel")

    local height = 36 + frame.text:GetStringHeight() + 16
    local e = opts.edit
    if e then
        frame.edit:SetNumeric(e.numeric and true or false)
        frame.edit:SetMaxLetters(e.maxLetters or 0)
        frame.edit:SetWidth(e.width or 80)
        frame.edit:SetJustifyH(e.width and "LEFT" or "CENTER")
        frame.edit:SetText(e.default ~= nil and tostring(e.default) or "")
        frame.edit:ClearAllPoints()
        frame.edit:SetPoint("TOP", frame.text, "BOTTOM", 0, -12)
        frame.edit:Show()
        height = height + 32
    else
        frame.edit:Hide()
    end
    frame:SetHeight(height + 40)
    frame:Show()
    frame:Raise()
    if e then
        frame.edit:SetFocus()
        frame.edit:HighlightText()
    end

    if opts.timeout then
        local mine = token
        C_Timer.After(opts.timeout, function()
            if token == mine and frame:IsShown() then frame:Hide() end
        end)
    end
end

function Dialog:Hide()
    if frame then frame:Hide() end
end
