-- Core.lua: namespace, event dispatch, saved variables, /tavern slash command.
local ADDON_NAME, ns = ...

local GetMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata

ns.name    = ADDON_NAME
ns.title   = "Unc's Tavern"
ns.version = (GetMeta and GetMeta(ADDON_NAME, "Version")) or "dev"

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
-- Player name. Forever characters have two names ("Hexual Defect"):
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
local DB_VERSION      = 1
local CHAR_DB_VERSION = 1

local DEFAULTS = {
    settings = {
        levelUpPosts  = true,
        vendorPopup   = true,
        tooltipLines  = true,
        minimapButton = true,
    },
    wishlist = {},
    roster   = {},
}

local CHAR_DEFAULTS = {}

-- MIGRATIONS[n] upgrades a db from version n-1 to n.
local MIGRATIONS      = {}
local CHAR_MIGRATIONS = {}

local function ApplyDefaults(db, defaults)
    for k, v in pairs(defaults) do
        if db[k] == nil then
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

    UncsTavernDB = UncsTavernDB or {}
    Migrate(UncsTavernDB, DB_VERSION, MIGRATIONS)
    ApplyDefaults(UncsTavernDB, DEFAULTS)
    ns.db = UncsTavernDB

    UncsTavernCharDB = UncsTavernCharDB or {}
    Migrate(UncsTavernCharDB, CHAR_DB_VERSION, CHAR_MIGRATIONS)
    ApplyDefaults(UncsTavernCharDB, CHAR_DEFAULTS)
    ns.charDB = UncsTavernCharDB
end
ns:RegisterEvent("ADDON_LOADED", OnAddonLoaded)

---------------------------------------------------------------------------
-- Slash command: /tavern [subcommand]
-- Modules add subcommands with ns:RegisterCommand(name, fn, help).
---------------------------------------------------------------------------
local commands, commandOrder = {}, {}

function ns:RegisterCommand(name, fn, help)
    name = name:lower()
    if not commands[name] then commandOrder[#commandOrder + 1] = name end
    commands[name] = { fn = fn, help = help }
end

local function PrintHelp()
    ns:Print("v" .. ns.version .. " commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  /tavern - open or close the window")
    for _, name in ipairs(commandOrder) do
        local help = commands[name].help
        DEFAULT_CHAT_FRAME:AddMessage("  /tavern " .. name .. (help and (" - " .. help) or ""))
    end
end
ns:RegisterCommand("help", PrintHelp, "show this list")

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
