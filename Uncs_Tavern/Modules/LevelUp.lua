-- Modules\LevelUp.lua: post the player's own level-ups to guild chat.
-- The Discord bot parses this line, so FORMAT must never change:
--   [Unc's Tavern] <Name> reached level <N>!
local _, ns = ...

local FORMAT = "[Unc's Tavern] %s reached level %d!"
local MAX_LOG = 30

local pending -- level waiting for combat to end

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

-- Returns true on success, or false plus the error text.
local function Send(msg, chatType, target)
    local fn, via
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        fn, via = C_ChatInfo.SendChatMessage, "C_ChatInfo.SendChatMessage"
    elseif SendChatMessage then
        fn, via = SendChatMessage, "SendChatMessage"
    else
        Log("send: no chat send function exists")
        return false, "no chat send function"
    end
    local ok, err = pcall(fn, msg, chatType, nil, target)
    Log(("send %s via %s: %s"):format(chatType, via, ok and "ok" or ("ERROR " .. tostring(err))))
    return ok, err
end

local function Post(level)
    local ok, err = Send(Message(level), "GUILD")
    if not ok then ns:Print("Could not post your level-up: " .. tostring(err)) end
end

local function OnRegenEnabled()
    ns:UnregisterEvent("PLAYER_REGEN_ENABLED", OnRegenEnabled)
    Log("combat ended, pending=" .. tostring(pending))
    if pending and IsInGuild() and ns.db.settings.levelUpPosts then
        Post(pending)
    end
    pending = nil
end

local function OnLevelUp(_, level)
    Log(("PLAYER_LEVEL_UP level=%s enabled=%s inGuild=%s combat=%s"):format(
        tostring(level), tostring(ns.db.settings.levelUpPosts), tostring(IsInGuild()), tostring(InCombatLockdown())))
    if not ns.db.settings.levelUpPosts or not IsInGuild() then return end
    level = tonumber(level)
    if not level then return end
    -- Level-ups usually happen mid-fight; post once combat ends so chat
    -- restrictions in combat can't drop the message.
    if InCombatLockdown() then
        if not pending then ns:RegisterEvent("PLAYER_REGEN_ENABLED", OnRegenEnabled) end
        pending = level
    else
        Post(level)
    end
end
ns:RegisterEvent("PLAYER_LEVEL_UP", OnLevelUp)

ns.Settings:RegisterToggle({
    key = "levelUpPosts",
    label = "Post my level-ups to guild chat",
    description = "Sends \"[Unc's Tavern] <Name> reached level <N>!\" when you level up. Preview with /tavern levelup.",
    order = 10,
})

--   /tavern levelup        preview locally, sends nothing
--   /tavern levelup test   whisper the message to yourself to prove sending works
ns:RegisterCommand("levelup", function(arg)
    local msg = Message(UnitLevel("player") + 1)
    if arg:lower() == "test" then
        local ok, err = Send(msg, "WHISPER", ns:PlayerName())
        ns:Print(ok and "Test whisper sent to yourself (check chat)." or ("Test whisper failed: " .. tostring(err)))
        return
    end
    local state = ns.db.settings.levelUpPosts and "ON" or "OFF"
    ns:Print("Level-up posts are " .. state .. ". Your next one would read:")
    DEFAULT_CHAT_FRAME:AddMessage("  " .. msg)
end, "preview your level-up message ('levelup test' whispers it to yourself)")
