-- Modules\PvPProbe.lua: developer probe for the PvP update (hidden: /tavern pvpprobe).
-- Finds out what WoW: Forever lets an addon see before the features are built:
--   enemy players from nameplates / target / mouseover / focus (and whether values are
--   "secret" in combat), the right-click unit menus, the death popup and death recap,
--   PARTY_KILL, the player's buffs (Well Rested, XP food), the weekly reset, and Spy.
-- Reads only. Sends nothing. The one visible thing: a 10-second test skull over the
-- target's nameplate, and a title line in right-click menus ("Unc's Tavern probe: ...").
-- Results go to chat and to UncsTavernDB.pvpProbe (read from the SavedVariables file
-- after /reload). Removed once the PvP features are built.
local _, ns = ...

local MAX_EVENTS = 250
local MAX_UNITS  = 60 -- unit snapshots logged per session
local MENU_TAGS = { "MENU_UNIT_SELF", "MENU_UNIT_PLAYER", "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_TARGET",
                    "MENU_UNIT_FOCUS", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_FRIEND",
                    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER" }

local watching = false
local menusHooked = false
local unitsLogged, seenGUIDs = 0, {}

local function Out(s) DEFAULT_CHAT_FRAME:AddMessage("  " .. s) end

-- Any value as plain text; secret values are never compared or concatenated.
local function Safe(v)
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    if v == nil then return "nil" end
    local ok, s = pcall(tostring, v)
    return ok and s or "<error>"
end

local function IsSecret(v) return issecretvalue and issecretvalue(v) or false end

-- Calls fn safely; returns its results as Safe text joined by ", ".
local function Call(fn, ...)
    if type(fn) ~= "function" then return "<missing>" end
    local r = (function(...) return { n = select("#", ...), ... } end)(pcall(fn, ...))
    if not r[1] then return "<error: " .. Safe(r[2]) .. ">" end
    local parts = {}
    for i = 2, math.max(2, r.n) do parts[#parts + 1] = Safe(r[i]) end
    return table.concat(parts, ", ")
end

local function Store()
    if type(ns.db.pvpProbe) ~= "table" then ns.db.pvpProbe = {} end
    local s = ns.db.pvpProbe
    s.events = type(s.events) == "table" and s.events or {}
    return s
end

local function Log(kind, data)
    local events = Store().events
    data.kind, data.t, data.combat = kind, date("%H:%M:%S"), InCombatLockdown() and true or false
    events[#events + 1] = data
    while #events > MAX_EVENTS do table.remove(events, 1) end
end

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------
local function UnitInfo(unit)
    local d = { unit = unit }
    d.exists        = Call(UnitExists, unit)
    d.isPlayer      = Call(UnitIsPlayer, unit)
    d.isEnemy       = Call(UnitIsEnemy, "player", unit)
    d.canAttack     = Call(UnitCanAttack, "player", unit)
    d.unitName      = Call(UnitName, unit)            -- name, realm
    d.getUnitName   = Call(GetUnitName, unit, true)   -- "Name - Realm" form
    d.fullName      = Call(UnitFullName, unit)
    d.class         = Call(UnitClass, unit)           -- name, token, id
    d.race          = Call(UnitRace, unit)
    d.level         = Call(UnitLevel, unit)
    d.guild         = Call(GetGuildInfo, unit)
    d.guid          = Call(UnitGUID, unit)
    d.pvp           = Call(UnitIsPVP, unit)
    d.faction       = Call(UnitFactionGroup, unit)
    local okN, name = pcall(UnitName, unit)
    d.nameSecret = okN and IsSecret(name) or "error"
    local okG, guid = pcall(UnitGUID, unit)
    d.guidSecret = okG and IsSecret(guid) or "error"
    return d, okG and not IsSecret(guid) and guid or nil
end

-- Logs enemy players (and up to 5 friendly players, so readability can be tested
-- without enemies around). Once per GUID per session.
local friendlyLogged = 0
local function NoteUnit(unit, source)
    if not watching or unitsLogged >= MAX_UNITS then return end
    local okP, isPlayer = pcall(UnitIsPlayer, unit)
    if not okP or IsSecret(isPlayer) or not isPlayer then return end
    local okA, canAttack = pcall(UnitCanAttack, "player", unit)
    local enemy = okA and not IsSecret(canAttack) and canAttack
    if not enemy and friendlyLogged >= 5 then return end
    local d, guid = UnitInfo(unit)
    if guid then
        if seenGUIDs[guid] then return end
        seenGUIDs[guid] = true
    end
    if not enemy then friendlyLogged = friendlyLogged + 1 end
    d.source, d.who = source, enemy and "enemy" or "friendly/other"
    unitsLogged = unitsLogged + 1
    Log("unit", d)
end

local function NoteAllPlates(source)
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return 0 end
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    if not ok or type(plates) ~= "table" then return 0 end
    for _, plate in ipairs(plates) do
        if plate.namePlateUnitToken then NoteUnit(plate.namePlateUnitToken, source) end
    end
    return #plates
end

---------------------------------------------------------------------------
-- Skull test over the target's nameplate (our own frame, parented to the plate)
---------------------------------------------------------------------------
local skull
local function SkullTest()
    if not UnitExists("target") then return "no target" end
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return "GetNamePlateForUnit missing" end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, "target")
    if not ok then return "error: " .. Safe(plate) end
    if not plate then return "no nameplate for the target (not shown, or forbidden)" end
    local okF, err = pcall(function()
        skull = skull or CreateFrame("Frame")
        skull:SetParent(plate)
        skull:ClearAllPoints()
        skull:SetPoint("BOTTOM", plate, "TOP", 0, 2)
        skull:SetSize(24, 24)
        skull:SetFrameStrata("HIGH")
        skull.tex = skull.tex or skull:CreateTexture(nil, "OVERLAY")
        skull.tex:SetAllPoints()
        skull.tex:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
        skull:Show()
    end)
    if not okF then return "error placing it: " .. Safe(err) end
    C_Timer.After(10, function() if skull then skull:Hide() skull:SetParent(UIParent) end end)
    return "placed (should show for 10 s)"
end

---------------------------------------------------------------------------
-- Right-click menus
---------------------------------------------------------------------------
local function HookMenus()
    if menusHooked then return "already hooked" end
    if not (Menu and Menu.ModifyMenu) then return "Menu.ModifyMenu missing" end
    local hooked = 0
    for _, tag in ipairs(MENU_TAGS) do
        local ok = pcall(Menu.ModifyMenu, tag, function(owner, root, context)
            if not watching then return end
            local d = { tag = tag }
            if type(context) == "table" then
                d.ctxUnit = Safe(context.unit)
                d.ctxName = Safe(context.name)
                d.ctxServer = Safe(context.server)
                d.ctxWhich = Safe(context.which)
            end
            d.owner = owner and owner.GetName and Safe(owner:GetName()) or "?"
            Log("menu", d)
            pcall(function()
                root:CreateDivider()
                root:CreateTitle("Unc's Tavern probe: " .. tag)
            end)
        end)
        if ok then hooked = hooked + 1 end
    end
    menusHooked = true
    return ("%d of %d menu tags hooked"):format(hooked, #MENU_TAGS)
end

---------------------------------------------------------------------------
-- Death popup and death recap
---------------------------------------------------------------------------
local function Popups()
    local found = {}
    for i = 1, (STATICPOPUP_NUMDIALOGS or 4) do
        local f = _G["StaticPopup" .. i]
        if f and f:IsShown() then
            local b = {}
            for j = 1, 4 do
                local btn = f["button" .. j] or _G["StaticPopup" .. i .. "Button" .. j]
                if btn and btn:IsShown() then b[#b + 1] = Safe(btn:GetText()) end
            end
            local okW, w = pcall(f.GetWidth, f)
            local okH, h = pcall(f.GetHeight, f)
            found[#found + 1] = ("StaticPopup%d which=%s buttons=[%s] size=%sx%s"):format(i, Safe(f.which),
                table.concat(b, " | "), okW and Safe(math.floor(w)) or "?", okH and Safe(math.floor(h)) or "?")
        end
    end
    return #found > 0 and table.concat(found, " ;; ") or "none shown"
end

local function Recap()
    local DR = C_DeathRecap
    if not (DR and DR.GetRecapEvents) then return "C_DeathRecap missing" end
    local events, how
    local ok, ev = pcall(DR.GetRecapEvents)
    if ok and type(ev) == "table" and #ev > 0 then
        events, how = ev, "no id"
    elseif DR.HasRecapEvents then
        for id = 30, 1, -1 do
            local okH, has = pcall(DR.HasRecapEvents, id)
            if okH and has then
                local okE, e2 = pcall(DR.GetRecapEvents, id)
                if okE and type(e2) == "table" and #e2 > 0 then events, how = e2, "id " .. id break end
            end
        end
    end
    if not events then return "no recap events" end
    local last
    for _, e in ipairs(events) do
        if not last or (tonumber(Safe(e.timestamp)) or 0) >= (tonumber(Safe(last.timestamp)) or 0) then last = e end
    end
    return ("%s, %d events; killing blow: source=%s guid=%s flags=%s spell=%s"):format(how, #events,
        Safe(last.sourceName), Safe(last.sourceGUID), Safe(last.sourceFlags), Safe(last.spellName))
end

local function OnDead()
    if not watching then return end
    local at = GetTime()
    for _, delay in ipairs({ 0, 1, 4 }) do
        C_Timer.After(delay, function()
            Log("death", { after = delay, popups = Popups(), recap = Recap(),
                           deathRecapFrame = Safe(DeathRecapFrame ~= nil), elapsed = Safe(GetTime() - at) })
        end)
    end
end

local function OnPartyKill(_, attackerGUID, targetGUID)
    if not watching then return end
    local d = { attackerSecret = IsSecret(attackerGUID), targetSecret = IsSecret(targetGUID),
                attacker = Safe(attackerGUID), target = Safe(targetGUID) }
    if not IsSecret(targetGUID) and type(targetGUID) == "string" then
        d.victim = Call(GetPlayerInfoByGUID, targetGUID) -- class, token, race, raceToken, sex, name, realm
        d.mine = Safe(attackerGUID == UnitGUID("player"))
    end
    Log("partykill", d)
end

---------------------------------------------------------------------------
-- Buffs, weekly reset, zone, Spy, APIs
---------------------------------------------------------------------------
local function Auras()
    local list = {}
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return { "C_UnitAuras.GetAuraDataByIndex missing" } end
    for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok then list[#list + 1] = "error: " .. Safe(a) break end
        if not a then break end
        local left = "?"
        if not IsSecret(a.expirationTime) and type(a.expirationTime) == "number" then
            left = a.expirationTime == 0 and "no end" or ("%dm%02ds"):format(math.floor((a.expirationTime - GetTime()) / 60),
                math.floor((a.expirationTime - GetTime()) % 60))
        end
        list[#list + 1] = ("%s (spell %s) stacks=%s duration=%s left=%s secret=%s"):format(Safe(a.name), Safe(a.spellId),
            Safe(a.applications), Safe(a.duration), left, Safe(IsSecret(a.name) or IsSecret(a.applications)))
    end
    return list
end

local function Weekly()
    local f = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
    if not f then return "C_DateAndTime.GetSecondsUntilWeeklyReset missing" end
    local ok, s = pcall(f)
    if not ok or type(s) ~= "number" then return "error: " .. Safe(s) end
    return ("%d s -> %s (local time)"):format(s, date("%a %d %b %H:%M", time() + s))
end

local function Zone()
    return ("zone=%s / %s mapID=%s pvpType=%s instance=%s"):format(Safe(GetZoneText()), Safe(GetSubZoneText()),
        Call(C_Map and C_Map.GetBestMapForUnit, "player"), Call(GetZonePVPInfo), Call(IsInInstance))
end

local function Keys(t, max)
    local out = {}
    for k in pairs(t) do
        out[#out + 1] = Safe(k)
        if #out >= max then break end
    end
    table.sort(out)
    return table.concat(out, ", ")
end

local function SpyInfo()
    local lines = {}
    local spy = _G.Spy
    lines[#lines + 1] = ("Spy global: %s, version=%s, signature=%s, enabled=%s"):format(type(spy),
        type(spy) == "table" and Safe(spy.Version) or "-", type(spy) == "table" and Safe(spy.Signature) or "-",
        type(spy) == "table" and Safe(spy.IsEnabled) or "-")
    local pc = _G.SpyPerCharDB
    if type(pc) == "table" then
        local kos = type(pc.KOSData) == "table" and pc.KOSData or {}
        local n = 0
        for _ in pairs(kos) do n = n + 1 end
        lines[#lines + 1] = ("SpyPerCharDB: version=%s, KOSData entries=%d, first keys: %s"):format(Safe(pc.version), n, Keys(kos, 3))
        local first = next(kos)
        local pd = type(pc.PlayerData) == "table" and first and pc.PlayerData[first]
        if type(pd) == "table" then
            lines[#lines + 1] = "  PlayerData fields: " .. Keys(pd, 40)
            lines[#lines + 1] = "  reason type: " .. type(pd.reason) .. (type(pd.reason) == "table" and (" keys: " .. Keys(pd.reason, 5)) or "")
        end
    else
        lines[#lines + 1] = "SpyPerCharDB: " .. type(pc)
    end
    local sdb = _G.SpyDB
    lines[#lines + 1] = ("SpyDB: %s, kosData=%s"):format(type(sdb), type(sdb) == "table" and type(sdb.kosData) or "-")
    if C_AddOns and C_AddOns.GetAddOnInfo then
        for _, name in ipairs({ "Spy", "Spy-Forever", "SpyForever" }) do
            local info = Call(C_AddOns.GetAddOnInfo, name)
            if not info:find("<") then lines[#lines + 1] = ("AddOn %s: %s"):format(name, info) end
        end
    end
    return lines
end

local function APIs()
    local function has(path)
        local t = _G
        for part in path:gmatch("[^%.]+") do
            if type(t) ~= "table" then return false end
            t = t[part]
        end
        return t ~= nil
    end
    local list = { "C_NamePlate.GetNamePlates", "C_NamePlate.GetNamePlateForUnit", "Menu.ModifyMenu", "issecretvalue",
                   "C_DeathRecap.GetRecapEvents", "C_DeathRecap.HasRecapEvents", "DeathRecapFrame", "StaticPopup_FindVisible",
                   "C_UnitAuras.GetAuraDataByIndex", "C_UnitAuras.GetPlayerAuraBySpellID",
                   "C_DateAndTime.GetSecondsUntilWeeklyReset", "GetUnitName", "UnitFullName", "GetGuildInfo",
                   "C_Map.GetBestMapForUnit", "GetZonePVPInfo", "C_CVar.GetCVar" }
    local yes, no = {}, {}
    for _, p in ipairs(list) do
        if has(p) then yes[#yes + 1] = p else no[#no + 1] = p end
    end
    return yes, no
end

local function CVars()
    if not (C_CVar and C_CVar.GetCVar) then return "C_CVar missing" end
    local parts = {}
    for _, name in ipairs({ "nameplateShowEnemies", "nameplateShowAll", "nameplateShowFriends" }) do
        parts[#parts + 1] = name .. "=" .. Call(C_CVar.GetCVar, name)
    end
    return table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Events while watching
---------------------------------------------------------------------------
local function OnTarget() NoteUnit("target", "target") end
local function OnMouseover() NoteUnit("mouseover", "mouseover") end
local function OnFocus() NoteUnit("focus", "focus") end
local function OnPlate(_, unit) NoteUnit(unit, "nameplate") end

local function StartWatching()
    if watching then return end
    watching = true
    ns:RegisterEvent("PLAYER_TARGET_CHANGED", OnTarget)
    ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", OnMouseover)
    ns:RegisterEvent("PLAYER_FOCUS_CHANGED", OnFocus)
    ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", OnPlate)
    ns:RegisterEvent("PLAYER_DEAD", OnDead)
    ns:RegisterEvent("PARTY_KILL", OnPartyKill)
end

local function StopWatching()
    if not watching then return end
    watching = false
    ns:UnregisterEvent("PLAYER_TARGET_CHANGED", OnTarget)
    ns:UnregisterEvent("UPDATE_MOUSEOVER_UNIT", OnMouseover)
    ns:UnregisterEvent("PLAYER_FOCUS_CHANGED", OnFocus)
    ns:UnregisterEvent("NAME_PLATE_UNIT_ADDED", OnPlate)
    ns:UnregisterEvent("PLAYER_DEAD", OnDead)
    ns:UnregisterEvent("PARTY_KILL", OnPartyKill)
end

---------------------------------------------------------------------------
-- /tavern pvpprobe [auras | off | clear]
---------------------------------------------------------------------------
local function RunAll()
    local s = Store()
    local build, _, _, toc = GetBuildInfo()
    local yes, no = APIs()
    local snap = { build = Safe(build), toc = Safe(toc), t = date("%Y-%m-%d %H:%M:%S"),
                   apisFound = table.concat(yes, ", "), apisMissing = table.concat(no, ", "),
                   zone = Zone(), weekly = Weekly(), cvars = CVars(), auras = Auras(), spy = SpyInfo(),
                   skull = SkullTest(), menus = HookMenus() }
    s.run = snap
    StartWatching()
    local plates = NoteAllPlates("nameplate (at run)")
    NoteUnit("target", "target (at run)")
    NoteUnit("mouseover", "mouseover (at run)")
    NoteUnit("focus", "focus (at run)")

    ns:Print("PvP probe (reads only, sends nothing):")
    Out("Build " .. snap.build .. ", toc " .. snap.toc)
    Out("APIs missing: " .. (snap.apisMissing ~= "" and snap.apisMissing or "none"))
    Out("Zone: " .. snap.zone)
    Out("Weekly reset in " .. snap.weekly)
    Out("Nameplate settings: " .. snap.cvars .. " (" .. plates .. " plates now)")
    Out("Skull test on target: " .. snap.skull)
    Out("Right-click menus: " .. snap.menus)
    Out("Buffs:")
    for _, line in ipairs(snap.auras) do Out("  " .. line) end
    for _, line in ipairs(snap.spy) do Out(line) end
    local tu = Store().events
    local last = tu[#tu]
    if last and last.kind == "unit" then
        Out(("Last unit logged (%s, %s): name=%s secret=%s class=%s level=%s guild=%s"):format(last.source, last.who,
            last.unitName, Safe(last.nameSecret), last.class, last.level, last.guild))
    end
    Out("|cff40ff40Watching now|r (until /reload or /tavern pvpprobe off): enemy players you see, right-click menus,")
    Out("deaths and kills are logged. Then /reload and tell me; results are saved.")
end

ns:RegisterCommand("pvpprobe", function(arg)
    arg = (arg or ""):lower()
    if arg == "off" then
        StopWatching()
        ns:Print("PvP probe: stopped watching (results kept until /tavern pvpprobe clear).")
    elseif arg == "clear" then
        ns.db.pvpProbe = nil
        unitsLogged, friendlyLogged, seenGUIDs = 0, 0, {}
        ns:Print("PvP probe: results cleared.")
    elseif arg == "auras" then
        local list = Auras()
        Store().auras = list
        Log("auras", { list = table.concat(list, " ;; ") })
        ns:Print("PvP probe, buffs now:")
        for _, line in ipairs(list) do Out(line) end
    else
        RunAll()
    end
end, "developer: PvP update probe (reads only)", true)
