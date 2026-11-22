-- Modules\Sightings.lua: telling the guild where Kill on Sight players are, and the
-- Nemesis alert.
--
--   * Sighting (shared): when I spot a player on the guild Kill on Sight list
--     (nameplate, target, mouseover), my client tells the guild "seen in <zone>".
--     Once per enemy per SEND_COOLDOWN, at most one per SEND_GAP. Only where enemies
--     are tracked (not in dungeons, battlegrounds or sanctuaries).
--   * Receiving: a chat line "X seen in <zone> by <guildmate>", once per enemy per
--     SHOW_COOLDOWN, only while that enemy is on MY copy of the list. If one of the
--     entries is mine, a bigger alert in the middle of the screen as well.
--   * Nemesis (local, nothing sent): the enemy who has killed me the most (at least
--     NEMESIS_MIN times) gets an alert when they show up, once per NEMESIS_COOLDOWN.
--
-- Message (protocol 2, GUILD, sharing category "kos"):
--   KV|target|level|zone
--
-- TRUST: the sighter is the sender (set by the server) and is always named. A sighting
-- is only a hint: it's shown only for enemies already on our own list, the zone text is
-- cleaned and capped, and nothing is stored or passed on (no relaying).
local _, ns = ...
local KOS, Enemies, Comm = ns.KOS, ns.Enemies, ns.Comm

local SEND_COOLDOWN    = 300
local SEND_GAP         = 10
local SHOW_COOLDOWN    = 300
local MAX_ZONE         = 60
local NEMESIS_MIN      = 2
local NEMESIS_COOLDOWN = 600
local MOD_ORANGE       = "|cffff8040"

local sent, shown, nemesisAlerted = {}, {}, {}
local lastSend = -SEND_GAP

local function S() return ns.db.settings end

local function Announce(text, r, g, b, sound)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, text, { r = r, g = g, b = b })
    else
        UIErrorsFrame:AddMessage(text, r, g, b)
    end
    if sound and SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
end

local function ZoneText()
    local zone, sub = GetZoneText and GetZoneText() or "", GetSubZoneText and GetSubZoneText() or ""
    local text = (sub ~= "" and sub ~= zone) and (sub .. ", " .. zone) or zone
    return ns:CleanText(text, MAX_ZONE)
end

local function LevelOf(unit)
    local ok, lvl = pcall(UnitLevel, unit)
    if not ok or type(lvl) ~= "number" or (issecretvalue and issecretvalue(lvl)) then return nil end
    return lvl
end

local function LevelSuffix(lvl)
    if not lvl then return "" end
    return lvl == -1 and " (??)" or (" (" .. lvl .. ")")
end

---------------------------------------------------------------------------
-- Nemesis: the enemy with the most kills on me (cached until the book changes)
---------------------------------------------------------------------------
local nemesis, nemesisCount -- nil = rebuild; false = none

local function Nemesis()
    if nemesis == nil then
        nemesis, nemesisCount = false, 0
        for _, item in ipairs(Enemies:All()) do
            local n = item.e.losses or 0
            if n >= NEMESIS_MIN and (n > nemesisCount or (n == nemesisCount and item.name < nemesis)) then
                nemesis, nemesisCount = item.name, n
            end
        end
    end
    return nemesis, nemesisCount
end
ns:RegisterCallback("ENEMIES_CHANGED", function() nemesis = nil end)

---------------------------------------------------------------------------
-- Spotting
---------------------------------------------------------------------------
local function Check(unit)
    if not ns.db or not Enemies:TrackingHere() then return end
    local name = Enemies:EnemyName(unit)
    if not name then return end
    local now = GetTime()

    if ns:GuildKey() and KOS:IsKOS(name) then
        if S().kosSightShare and Comm:IsSharing("kos") and now - lastSend >= SEND_GAP
            and not (sent[name] and now - sent[name] < SEND_COOLDOWN) then
            local zone = ZoneText()
            if zone ~= "" then
                sent[name], lastSend = now, now
                local lvl = LevelOf(unit)
                Comm:Send("KV", name, lvl or "", zone)
            end
        end
        -- The Kill on Sight alert (KOSAlert.lua) already covers a nemesis on the list.
        if S().kosAlert then return end
    end

    if not S().nemesisAlert then return end
    local nem, count = Nemesis()
    if name ~= nem then return end
    if nemesisAlerted[name] and now - nemesisAlerted[name] < NEMESIS_COOLDOWN then return end
    nemesisAlerted[name] = now
    Announce(("Your nemesis %s%s is nearby!"):format(name, LevelSuffix(LevelOf(unit))), 1, 0.5, 0.1, S().nemesisSound)
    ns:Print(("%sNemesis:|r %s is nearby (killed you %d times)."):format(MOD_ORANGE, name, count))
end

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Check(unit) end)
ns:RegisterEvent("PLAYER_TARGET_CHANGED", function() Check("target") end)
ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", function() Check("mouseover") end)

---------------------------------------------------------------------------
-- Receiving a guildmate's sighting
---------------------------------------------------------------------------
local Sightings = { rejected = 0 }
ns.Sightings = Sightings

-- Returns what was shown ("mine" | "guild") or nil. Also used by the security test.
function Sightings:Receive(sender, target, level, zone)
    sender = ns:ValidName(sender)
    target = type(target) == "string" and ns:ValidName(ns:CleanText(target, 48)) or nil
    zone = ns:CleanText(zone, MAX_ZONE)
    if level ~= nil and level ~= "" then
        level = ns:Int(level, -1, 60)
        if not level then self.rejected = self.rejected + 1 return nil end
    else
        level = nil
    end
    if not (sender and target) or zone == "" or target == sender then self.rejected = self.rejected + 1 return nil end
    if sender == ns:PlayerName() or not ns:GuildKey() then return nil end
    local entries = KOS:Entries(target)
    if not entries then return nil end -- only enemies on our own list
    local now = GetTime()
    if shown[target] and now - shown[target] < SHOW_COOLDOWN then return nil end
    local mine = KOS:Mine(target) ~= nil
    if mine and S().kosSightMine then
        shown[target] = now
        Announce(("%s Your Kill on Sight %s%s spotted by %s in %s"):format(KOS.SKULL, target, LevelSuffix(level), sender, zone),
            1, 0.35, 0.35, false)
        ns:Print(("|cffff4040Kill on Sight:|r your entry %s%s was spotted by %s in %s."):format(
            target, LevelSuffix(level), sender, zone))
        return "mine"
    elseif S().kosSightShow then
        shown[target] = now
        ns:Print(("|cffff4040Kill on Sight:|r %s%s seen in %s by %s."):format(target, LevelSuffix(level), zone, sender))
        return "guild"
    end
    return nil
end

Comm:RegisterHandler("KV", function(sender, ...) Sightings:Receive(sender, ...) end, "kos")

ns:RegisterCallback("GUILD_CHANGED", function() wipe(sent) wipe(shown) end)

---------------------------------------------------------------------------
-- Settings > PvP
---------------------------------------------------------------------------
local function Toggle(key, order, label, description, indent, disabled)
    ns.Settings:RegisterToggle({ category = "pvp", key = key, order = order, indent = indent,
        label = label, description = description, disabled = disabled })
end
Toggle("kosSightShare", 50, "Tell the guild when I spot a Kill on Sight player",
    "Sends the enemy's name, level and your zone to guildmates, once per enemy every 5 minutes."
        .. " Needs Kill on Sight sharing on (Settings > Sharing). Not in dungeons, battlegrounds or sanctuaries.")
Toggle("kosSightShow", 51, "Show guildmates' sightings in chat",
    "A chat line when a guildmate spots someone on the Kill on Sight list, once per enemy every 5 minutes.")
Toggle("kosSightMine", 52, "Alert me when a guildmate spots one of MY entries",
    "A warning in the middle of the screen when someone you put on Kill on Sight is spotted.")
Toggle("nemesisAlert", 53, "Nemesis alert",
    ("A warning when the enemy who has killed you the most (at least %d times) shows up, once every 10 minutes."
        .. " Only you see it."):format(NEMESIS_MIN))
Toggle("nemesisSound", 54, "Play a sound with it", nil, 1, function() return not S().nemesisAlert end)

---------------------------------------------------------------------------
-- /tavern sighttest [nemesis] (hidden, debug on): fake a guildmate's sighting of the
-- first enemy on the list, or show who the nemesis is and play its alert.
---------------------------------------------------------------------------
ns:RegisterCommand("sighttest", function(arg)
    if not S().debug then ns:Print("Turn on /tavern debug on first.") return end
    if strtrim(arg or "") == "nemesis" then
        local nem, count = Nemesis()
        if not nem then ns:Print(("No nemesis yet: nobody has killed you %d or more times."):format(NEMESIS_MIN)) return end
        Announce(("Your nemesis %s is nearby! (test)"):format(nem), 1, 0.5, 0.1, S().nemesisSound)
        ns:Print(("%sNemesis:|r %s (killed you %d times). This was a test."):format(MOD_ORANGE, nem, count))
        return
    end
    local mineFirst, any
    for _, t in ipairs(KOS:Targets()) do
        if not t.pending then
            any = any or t.name
            if KOS:Mine(t.name) then mineFirst = mineFirst or t.name end
        end
    end
    local target = mineFirst or any
    if not target then ns:Print("Nobody is on the Kill on Sight list.") return end
    shown[target] = nil
    local what = Sightings:Receive("Test Guildmate", target, 42, ZoneText() ~= "" and ZoneText() or "Somewhere")
    if not what then ns:Print("Nothing shown: the matching sighting switch is off in Settings > PvP.") end
end, nil, true)
