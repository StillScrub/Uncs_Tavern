-- Core.lua: namespace, event dispatch, saved variables, /tavern slash command.
local ADDON_NAME, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

ns.name    = ADDON_NAME
ns.title   = "Unc's Tavern"
ns.version = (GetMeta and GetMeta(ADDON_NAME, "Version")) or "dev"

-- Shown in the level-up setting's description: Blizzard's guild chat <-> Discord bridge
-- only carries messages from players whose Battle.net account is linked to Discord.
-- Worded for any guild (many have no Discord bridge at all).
ns.DISCORD_NOTE = "|cffffd100Discord:|r if your guild mirrors guild chat to Discord, your post only "
    .. "reaches it when your Battle.net account is linked to Discord."

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
local PREFIX = "|cffe6b422Unc's Tavern|r: "

function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. table.concat(parts, " "))
end

---------------------------------------------------------------------------
-- Player name. Forever characters have two names ("First Second"):
-- UnitName returns them as two values, GetUnitName(unit, true) joins them
-- with a space, and the guild roster uses the joined form.
---------------------------------------------------------------------------
function ns:PlayerName()
    local full = GetUnitName and GetUnitName("player", true)
    if full and full ~= "" then return full end
    local first, second = UnitName("player")
    if second and second ~= "" then return first .. " " .. second end
    return first
end

-- Key for per-guild data ("Guild Name@Realm"), or nil when not in a guild.
-- The guild is detected at runtime; nothing is hardcoded.
-- /tavern securitytest swaps in a throwaway key (ns.testGuildKey) while it runs.
function ns:GuildKey()
    if ns.testGuildKey then return ns.testGuildKey end
    local guild = IsInGuild() and GetGuildInfo("player")
    if not guild then return nil end
    return guild .. "@" .. (GetRealmName() or "")
end

---------------------------------------------------------------------------
-- Validation of anything that came from another player (or from saved data).
-- Message content is never trusted: see "Security rules" in CLAUDE.md.
---------------------------------------------------------------------------
-- Integer in [min, max], or nil.
function ns:Int(v, min, max)
    v = tonumber(v)
    if not v or v ~= v or v ~= math.floor(v) then return nil end
    if (min and v < min) or (max and v > max) then return nil end
    return v
end

-- Plain text: every "|" escape (colors, links, textures, atlases...) and control
-- character removed, trimmed, capped at max characters.
function ns:CleanText(text, max)
    if type(text) ~= "string" then return "" end
    text = text:gsub("|", ""):gsub("[%c]", "")
    text = strtrim(text)
    if max and #text > max then text = text:sub(1, max) end
    return text
end

-- For text that ends up inside a format pattern or a gsub replacement.
function ns:EscapePercent(text)
    return (tostring(text or ""):gsub("%%", "%%%%"))
end

-- A real class token ("WARRIOR"...), or nil.
function ns:ValidClass(class)
    if type(class) ~= "string" or class == "" then return nil end
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then return class end
    return nil
end

-- A character name as Ambiguate(name, "guild") gives it: no escapes, sane length.
function ns:ValidName(name)
    if type(name) ~= "string" or name == "" or #name > 64 or name:find("[|%c:,]") then return nil end
    return name
end

function ns:PlayerClass()
    return UnitClassBase and UnitClassBase("player") or select(2, UnitClass("player"))
end

---------------------------------------------------------------------------
-- Events: one frame, many handlers. Modules call ns:RegisterEvent(event, fn).
---------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local handlers = {}

function ns:RegisterEvent(event, fn)
    local list = handlers[event]
    if not list then
        list = {}
        handlers[event] = list
        eventFrame:RegisterEvent(event)
    end
    list[#list + 1] = fn
end

function ns:UnregisterEvent(event, fn)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then table.remove(list, i) end
    end
    if #list == 0 then
        handlers[event] = nil
        eventFrame:UnregisterEvent(event)
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    -- Snapshot, so a handler can unregister itself (or others) mid-dispatch safely.
    local n = #list
    local snapshot = { unpack(list, 1, n) }
    for i = 1, n do
        snapshot[i](event, ...)
    end
end)

---------------------------------------------------------------------------
-- Internal callbacks between modules (not game events):
--   ns:RegisterCallback("ADDON_USERS_CHANGED", fn)   ns:Fire("ADDON_USERS_CHANGED", ...)
---------------------------------------------------------------------------
local callbacks = {}

function ns:RegisterCallback(name, fn)
    callbacks[name] = callbacks[name] or {}
    table.insert(callbacks[name], fn)
end

function ns:Fire(name, ...)
    local list = callbacks[name]
    if not list then return end
    for _, fn in ipairs({ unpack(list) }) do fn(name, ...) end
end

---------------------------------------------------------------------------
-- Saved variables (with dbVersion + migrations)
---------------------------------------------------------------------------
local DB_VERSION      = 3
local CHAR_DB_VERSION = 2

local DEFAULTS = {
    settings = {
        levelUpPosts  = true,
        vendorPopup   = true,
        sellWarnings  = true,
        codWarning    = true,
        tooltipLines  = true,
        minimapButton = true,
        minimapBadge  = true,
        requestExpiryDays = 14, -- forget other players' requests after this many days unseen
        debug         = false,  -- enables /tavern securitytest
    },
    -- [guildKey] = { optIn = true|false, asked = true, wishlist = true, pvp = true, helped = true }
    sharing  = {},
    helpedLedger = {}, -- [guildKey][receiver .. "|" .. reqId .. "|" .. helper] = { ... } (History.lua)
    wishlist = {},
    roster   = {},
    pvp      = {}, -- [guildKey][name] = guildmates' shared PvP stats
    seenItems = {}, -- [itemID] = true, items seen in bags (wishlist search)
    -- Phase B (Permissions.lua, Moderation.lua, GuildLog.lua), all per guild key:
    perms      = {}, -- [guildKey] = { t, mod, log, days, ranks }: rank config from the guild leader
    modActions = {}, -- [guildKey][id] = my own moderator actions (re-announced for 14 days)
    guildLog   = {}, -- [guildKey][id] = public guild log entries
    officerLog = {}, -- [guildKey][id] = officer log entries (kept only if my rank may see them)
}
ns.DEFAULT_SETTINGS = DEFAULTS.settings -- read-only, for the Settings "Defaults" button

local CHAR_DEFAULTS = {
    -- My own PvP tracking (Modules\PvPStats.lua). Lifetime honorable kills come from the game.
    pvp = { deaths = 0, dishonorableKills = 0, dishonorableDeaths = 0, killingBlows = 0, killers = {} },
    -- My wishlist history (Modules\History.lua): byGuild[guildKey] = { [key] = entry }.
    history = { byGuild = {} },
}

-- MIGRATIONS[n] upgrades a db from version n-1 to n.
local MIGRATIONS      = {
    -- 2 (security pass): self-reported Helped counts are no longer trusted; the old
    -- catch-up bookkeeping is gone (no more relaying).
    [2] = function(db)
        db.helped = nil
        for _, bucket in pairs(type(db.wishlist) == "table" and db.wishlist or {}) do
            if type(bucket) == "table" then bucket.lastSync = nil end
        end
    end,
    -- 3 (Phase B): rank permissions and guild log tables (ApplyDefaults adds them).
    [3] = function() end,
}
local CHAR_MIGRATIONS = {
    -- 2: "no-honor kills" renamed to "dishonorable kills".
    [2] = function(db)
        local p = db.pvp
        if p and p.noHonorKills then
            p.dishonorableKills = (p.dishonorableKills or 0) + p.noHonorKills
            p.noHonorKills = nil
        end
    end,
}

local function ApplyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if db[k] == nil or type(db[k]) ~= type(v) then
            db[k] = (type(v) == "table") and CopyTable(v) or v
        elseif type(v) == "table" and type(db[k]) == "table" then
            ApplyDefaults(db[k], v)
        end
    end
end

local function Migrate(db, target, migrations)
    local v = db.dbVersion or 0
    if v > target then return end -- written by a newer addon version; leave it alone
    while v < target do
        v = v + 1
        if migrations[v] then migrations[v](db) end
        db.dbVersion = v
    end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------
local function OnAddonLoaded(event, name)
    if name ~= ADDON_NAME then return end
    ns:UnregisterEvent("ADDON_LOADED", OnAddonLoaded)

    if type(UncsTavernDB) ~= "table" then UncsTavernDB = {} end
    Migrate(UncsTavernDB, DB_VERSION, MIGRATIONS)
    ApplyDefaults(UncsTavernDB, DEFAULTS)
    ns.db = UncsTavernDB

    if type(UncsTavernCharDB) ~= "table" then UncsTavernCharDB = {} end
    Migrate(UncsTavernCharDB, CHAR_DB_VERSION, CHAR_MIGRATIONS)
    ApplyDefaults(UncsTavernCharDB, CHAR_DEFAULTS)
    ns.charDB = UncsTavernCharDB
    -- Modules check their own saved data (types, ranges, escape codes) on this callback.
    ns:Fire("VALIDATE_DB")
end
ns:RegisterEvent("ADDON_LOADED", OnAddonLoaded)

---------------------------------------------------------------------------
-- Slash command: /tavern [subcommand]
-- Modules add subcommands with ns:RegisterCommand(name, fn, help).
---------------------------------------------------------------------------
local commands, commandOrder = {}, {}

-- hidden = true keeps a command out of /tavern help (developer tools).
function ns:RegisterCommand(name, fn, help, hidden)
    name = name:lower()
    if not commands[name] then commandOrder[#commandOrder + 1] = name end
    commands[name] = { fn = fn, help = help, hidden = hidden }
end

local function PrintHelp()
    ns:Print("v" .. ns.version .. " commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  /tavern - open or close Unc's Tavern (swaps with the guild window if open)")
    for _, name in ipairs(commandOrder) do
        local help = commands[name].help
        if not commands[name].hidden then
            DEFAULT_CHAT_FRAME:AddMessage("  /tavern " .. name .. (help and (" - " .. help) or ""))
        end
    end
end
ns:RegisterCommand("help", PrintHelp, "show this list")

-- Key binding names (Bindings.xml): shown in Options > Keybindings > AddOns.
BINDING_HEADER_UNCSTAVERN = ns.title
BINDING_NAME_UNCSTAVERN_TOGGLE = "Open / close Unc's Tavern"

SLASH_UNCSTAVERN1 = "/tavern"
SlashCmdList.UNCSTAVERN = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    if cmd == "" then
        if ns.MainFrame then ns.MainFrame:Toggle() end
        return
    end
    local c = commands[cmd]
    if c then
        c.fn(rest)
    else
        ns:Print("Unknown command '" .. cmd .. "'.")
        PrintHelp()
    end
end
