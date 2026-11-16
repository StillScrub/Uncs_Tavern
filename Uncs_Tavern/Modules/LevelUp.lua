-- Modules\LevelUp.lua: offer to post the player's own level-ups to guild chat.
-- Guilds' own Discord tools may parse this line, so FORMAT must never change:
--   [Unc's Tavern] <Name> reached level <N>!
--
-- WoW: Forever blocks addons from sending guild chat on their own: a send that
-- isn't triggered by a click or keypress is dropped with ADDON_ACTION_BLOCKED
-- (confirmed 2026-11-11), and even a click on a plain addon button is blocked
-- (2026-11-15). So on level-up we show a small popup whose "Post" button is a secure
-- macro button: the player's click runs "/g <line>" like their own macro.
local _, ns = ...

local FORMAT  = "[Unc's Tavern] %s reached level %d!"
local MAX_LOG = 30

local pending -- level waiting for combat to end before the popup is shown

local function Message(level)
    return FORMAT:format(ns:PlayerName(), level)
end

-- Diagnostics: every step is logged to UncsTavernDB.debug.levelup (written on /reload).
local function Log(text)
    ns.db.debug = ns.db.debug or {}
    local log = ns.db.debug.levelup or {}
    ns.db.debug.levelup = log
    log[#log + 1] = date("%Y-%m-%d %H:%M:%S ") .. text
    while #log > MAX_LOG do table.remove(log, 1) end
end

local function OnBlocked(event, addon, func)
    if addon == ns.name then Log(("%s: %s"):format(event, tostring(func))) end
end
ns:RegisterEvent("ADDON_ACTION_BLOCKED", OnBlocked)
ns:RegisterEvent("ADDON_ACTION_FORBIDDEN", OnBlocked)

---------------------------------------------------------------------------
-- Popup
---------------------------------------------------------------------------
-- Forever blocks a guild chat send even from a click on a plain addon button
-- (ADDON_ACTION_BLOCKED "UNKNOWN()", 2026-11-15); only Blizzard's StaticPopup click got
-- through, and we don't use StaticPopup any more (UI\Dialog.lua says why). So "Post" is
-- a SecureActionButton running the macro "/g <line>": the same as the player clicking
-- their own macro. Its macro text is set only out of combat (the popup is only shown
-- then). A frame holding a secure button can't be hidden in combat, so a close during
-- combat waits for combat to end. Several level-ups in a row: the newest replaces the
-- question. Not in UISpecialFrames (Escape would try to hide it in combat).
local TIMEOUT = 120
local WIDTH = 380
local popup
local token = 0

local function HideNow()
    ns:UnregisterEvent("PLAYER_REGEN_ENABLED", HideNow)
    if popup then popup:Hide() end
end

local function ClosePopup()
    if not popup or not popup:IsShown() then return end
    if InCombatLockdown() then
        ns:UnregisterEvent("PLAYER_REGEN_ENABLED", HideNow) -- never twice
        ns:RegisterEvent("PLAYER_REGEN_ENABLED", HideNow)
    else
        popup:Hide()
    end
end

local function CreatePopup()
    popup = CreateFrame("Frame", "UncsTavernLevelUpPopup", UIParent, "BasicFrameTemplateWithInset")
    popup:SetSize(WIDTH, 120)
    popup:SetPoint("TOP", UIParent, "TOP", 0, -180)
    popup:SetFrameStrata("DIALOG")
    popup:SetToplevel(true)
    popup:SetClampedToScreen(true)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    if popup.CloseButton then popup.CloseButton:Hide() end -- its HideUIPanel isn't combat-safe here

    local title = popup.TitleText or popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not popup.TitleText then title:SetPoint("TOP", popup, "TOP", 0, -5) end
    title:SetText(ns.title)

    popup.text = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    popup.text:SetPoint("TOP", popup, "TOP", 0, -36)
    popup.text:SetWidth(WIDTH - 40)
    popup.text:SetJustifyH("CENTER")
    popup.text:SetSpacing(2)

    local post = CreateFrame("Button", "UncsTavernLevelUpPost", popup, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    post:SetSize(110, 22)
    post:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 12)
    post:SetText("Post")
    -- Secure buttons act on key-down or key-up depending on the ActionButtonUseKeyDown
    -- setting; registering both lets whichever one the game wants through.
    post:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
    post:SetAttribute("type", "macro")
    post:SetScript("PostClick", function(_, _, down)
        if down ~= GetCVarBool("ActionButtonUseKeyDown") then return end -- the half that didn't act
        Log("post clicked")
        popup.text:SetText("Posted to guild chat.")
        ClosePopup()
    end)
    popup.post = post

    local cancel = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    cancel:SetSize(110, 22)
    cancel:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 12)
    cancel:SetText("Not now")
    cancel:SetScript("OnClick", ClosePopup)
    popup:Hide()
end

local function ShowPopup(level)
    if InCombatLockdown() then return false end -- the macro text can't be set in combat
    if not popup then CreatePopup() end
    ns:UnregisterEvent("PLAYER_REGEN_ENABLED", HideNow)
    popup.post:SetAttribute("macrotext", "/g " .. Message(level))
    popup.text:SetText(("You reached level %d!\nPost it to guild chat?"):format(level))
    popup:SetHeight(36 + popup.text:GetStringHeight() + 56)
    popup:Show()
    popup:Raise()
    token = token + 1
    local mine = token
    C_Timer.After(TIMEOUT, function()
        if token == mine then ClosePopup() end
    end)
    return true
end

local function Offer(level)
    if not IsInGuild() or not ns.db.settings.levelUpPosts then return end
    Log("offering post for level " .. level)
    ShowPopup(level)
end

local function OnRegenEnabled()
    ns:UnregisterEvent("PLAYER_REGEN_ENABLED", OnRegenEnabled)
    if pending then Offer(pending) end
    pending = nil
end

local function OnLevelUp(_, level)
    level = tonumber(level)
    Log(("PLAYER_LEVEL_UP level=%s combat=%s"):format(tostring(level), tostring(InCombatLockdown())))
    if not level or not ns.db.settings.levelUpPosts or not IsInGuild() then return end
    -- Don't pop up mid-fight; wait until combat ends.
    if InCombatLockdown() then
        if not pending then ns:RegisterEvent("PLAYER_REGEN_ENABLED", OnRegenEnabled) end
        pending = level
    else
        Offer(level)
    end
end
ns:RegisterEvent("PLAYER_LEVEL_UP", OnLevelUp)

ns.Settings:RegisterToggle({
    category = "general",
    key = "levelUpPosts",
    label = "Offer level-up posts",
    description = "On level-up a small popup asks to post \"[Unc's Tavern] <Name> reached level <N>!\". "
        .. "Click Post to send it (the game only lets addons post to guild when you click).\n" .. ns.DISCORD_NOTE,
    order = 10,
})

--   /tavern levelup          preview the line locally (sends nothing)
--   /tavern levelup popup    show the popup now, to try it (Post really sends)
ns:RegisterCommand("levelup", function(arg)
    if arg:lower() == "popup" then
        if not ShowPopup(UnitLevel("player")) then ns:Print("Try again out of combat.") end
        return
    end
    local state = ns.db.settings.levelUpPosts and "ON" or "OFF"
    ns:Print("Level-up posts are " .. state .. ". Your next one would read:")
    DEFAULT_CHAT_FRAME:AddMessage("  " .. Message(UnitLevel("player") + 1))
end, "preview your level-up line ('levelup popup' shows the popup)")
