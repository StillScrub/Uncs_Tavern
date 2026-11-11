-- Modules\LevelUp.lua: offer to post the player's own level-ups to guild chat.
-- The Discord bot parses this line, so FORMAT must never change:
--   [Unc's Tavern] <Name> reached level <N>!
--
-- WoW: Forever blocks addons from sending guild chat on their own: a send that
-- isn't triggered by a click or keypress is dropped with ADDON_ACTION_BLOCKED
-- (confirmed 2026-11-11). So on level-up we show a small popup and the player
-- clicks "Post"; that click is what lets the message through.
local _, ns = ...

local FORMAT  = "[Unc's Tavern] %s reached level %d!"
local POPUP   = "UNCSTAVERN_LEVELUP"
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

-- Must be called from a click or keypress, or the game blocks it.
local function Send(msg, chatType, target)
    local fn = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
    if not fn then return false, "no chat send function" end
    local ok, err = pcall(fn, msg, chatType, nil, target)
    Log(("send %s: %s"):format(chatType, ok and "ok" or ("ERROR " .. tostring(err))))
    return ok, err
end

local function OnBlocked(event, addon, func)
    if addon == ns.name then Log(("%s: %s"):format(event, tostring(func))) end
end
ns:RegisterEvent("ADDON_ACTION_BLOCKED", OnBlocked)
ns:RegisterEvent("ADDON_ACTION_FORBIDDEN", OnBlocked)

---------------------------------------------------------------------------
-- Popup
---------------------------------------------------------------------------
StaticPopupDialogs[POPUP] = {
    text = "|cffe6b422Unc's Tavern|r\n\nYou reached level %d!\nPost it to guild chat?",
    button1 = "Post",
    button2 = "Not now",
    OnAccept = function(_, level)
        if level and IsInGuild() then Send(Message(level), "GUILD") end
    end,
    timeout = 120,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function Offer(level)
    if not IsInGuild() or not ns.db.settings.levelUpPosts then return end
    Log("offering post for level " .. level)
    StaticPopup_Hide(POPUP) -- several level-ups in a row: only offer the newest
    StaticPopup_Show(POPUP, level, nil, level)
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
    key = "levelUpPosts",
    label = "Offer to post my level-ups to guild chat",
    description = "On level-up a small popup asks to post \"[Unc's Tavern] <Name> reached level <N>!\". "
        .. "Click Post to send it (the game only lets addons post to guild when you click).\n" .. ns.DISCORD_NOTE,
    order = 10,
})

--   /tavern levelup          preview the line locally (sends nothing)
--   /tavern levelup popup    show the popup now, to try it (Post really sends)
ns:RegisterCommand("levelup", function(arg)
    if arg:lower() == "popup" then
        StaticPopup_Show(POPUP, UnitLevel("player"), nil, UnitLevel("player"))
        return
    end
    local state = ns.db.settings.levelUpPosts and "ON" or "OFF"
    ns:Print("Level-up posts are " .. state .. ". Your next one would read:")
    DEFAULT_CHAT_FRAME:AddMessage("  " .. Message(UnitLevel("player") + 1))
end, "preview your level-up line ('levelup popup' shows the popup)")
