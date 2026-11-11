-- Modules\PvPTest.lua: SPEC step 0. Probes what WoW: Forever exposes for PvP kills/deaths.
--   /tavern pvptest         one-shot report (chat + saved to UncsTavernDB.debug.pvptest)
--   /tavern pvptest listen  toggle logging of PvP-related events until /reload
-- Everything is wrapped in pcall: the point is to learn what works, not to error.
-- Temporary module; delete it once PvPStats.lua picks an approach.
local _, ns = ...

local MAX_CHAT_STAT_LINES = 40
local MAX_LISTEN_LINES    = 200

-- Statistic IDs believed (from retail) to be PvP-related. The client's own
-- name for each ID is printed next to it, so a wrong guess is obvious.
local CANDIDATE_STATS = { 588, 1487, 60, 1501 }

-- Matched case-insensitively against statistic names during the full scan.
local STAT_KEYWORDS = { "honorable", "killing blow", "death", "player" }

local EVENTS = {
    "PLAYER_PVP_KILLS_CHANGED",
    "CHAT_MSG_COMBAT_HONOR_GAIN",
    "HONOR_XP_UPDATE",
    "PLAYER_DEAD",
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function fmt(v)
    if issecretvalue and issecretvalue(v) then return "<secret>" end
    local ok, s = pcall(tostring, v)
    return ok and s or "<unprintable>"
end

local function pack(...) return { n = select("#", ...), ... } end

local function joinResults(res, from)
    local parts = {}
    for i = from, res.n do parts[#parts + 1] = fmt(res[i]) end
    return (#parts > 0) and table.concat(parts, ", ") or "(no values)"
end

-- Calls fn safely and returns a one-line description of the outcome.
local function try(label, fn, ...)
    if type(fn) ~= "function" then return label .. ": not available" end
    local res = pack(pcall(fn, ...))
    if not res[1] then return label .. ": ERROR " .. fmt(res[2]) end
    return label .. " = " .. joinResults(res, 2)
end

local function sortedKeys(t, pattern)
    local keys = {}
    if type(t) ~= "table" then return keys end
    for k in pairs(t) do
        local name = fmt(k)
        if not pattern or name:lower():find(pattern) then keys[#keys + 1] = name end
    end
    table.sort(keys)
    return keys
end

local function isEventValid(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        local ok, valid = pcall(C_EventUtils.IsEventValid, event)
        if ok then return valid end
    end
    local probe = CreateFrame("Frame")
    local ok = pcall(probe.RegisterEvent, probe, event)
    pcall(probe.UnregisterEvent, probe, event)
    return ok
end

local function saveDebug(key, value)
    ns.db.debug = ns.db.debug or {}
    ns.db.debug[key] = value
end

---------------------------------------------------------------------------
-- One-shot report
---------------------------------------------------------------------------
local function StatName(id)
    local ok, _, name = pcall(GetAchievementInfo, id)
    return (ok and name) and fmt(name) or "?"
end

local function ScanStatistics(lines)
    if type(GetStatisticsCategoryList) ~= "function" then
        lines[#lines + 1] = "  GetStatisticsCategoryList: not available (no scan)"
        return
    end
    local ok, cats = pcall(GetStatisticsCategoryList)
    if not ok or type(cats) ~= "table" then
        lines[#lines + 1] = "  GetStatisticsCategoryList: ERROR " .. fmt(cats)
        return
    end
    local found = 0
    for _, cat in ipairs(cats) do
        local okC, catName = pcall(GetCategoryInfo, cat)
        if not okC or not catName then catName = "?" end
        local okN, n = pcall(GetCategoryNumAchievements, cat)
        for i = 1, (okN and tonumber(n) or 0) do
            local okA, id, name = pcall(GetAchievementInfo, cat, i)
            if okA and id and name then
                local lname = fmt(name):lower()
                for _, kw in ipairs(STAT_KEYWORDS) do
                    if lname:find(kw, 1, true) then
                        local okS, val = pcall(GetStatistic, id)
                        lines[#lines + 1] = ("  [%s] %s > %s = %s"):format(
                            fmt(id), fmt(catName), fmt(name), okS and fmt(val) or "ERROR")
                        found = found + 1
                        break
                    end
                end
            end
        end
    end
    lines[#lines + 1] = ("  scan: %d categories, %d matching statistics"):format(#cats, found)
end

local function BuildReport()
    local lines = {}
    local function add(s) lines[#lines + 1] = s end

    add(try("GetBuildInfo()", GetBuildInfo))

    add("== 1. Character statistics ==")
    if type(GetStatistic) ~= "function" then
        add("  GetStatistic: not available")
    else
        for _, id in ipairs(CANDIDATE_STATS) do
            local okS, val = pcall(GetStatistic, id)
            add(("  candidate [%d] %s = %s"):format(id, StatName(id), okS and fmt(val) or ("ERROR " .. fmt(val))))
        end
        ScanStatistics(lines)
    end

    add("== 2. Honorable kill counters / events ==")
    add("  " .. try("GetPVPLifetimeStats()", GetPVPLifetimeStats))
    add("  " .. try("GetPVPSessionStats()", GetPVPSessionStats))
    add("  " .. try("GetPVPYesterdayStats()", GetPVPYesterdayStats))
    if C_PvP then
        local keys = sortedKeys(C_PvP)
        local hits = {}
        for _, k in ipairs(keys) do
            local l = k:lower()
            if l:find("kill") or l:find("honor") or l:find("stat") or l:find("death") then hits[#hits + 1] = k end
        end
        add(("  C_PvP: %d functions; kill/honor/stat/death ones: %s"):format(
            #keys, (#hits > 0) and table.concat(hits, ", ") or "none"))
    else
        add("  C_PvP: not available")
    end
    for _, e in ipairs(EVENTS) do
        add(("  event %s: %s"):format(e, isEventValid(e) and "exists" or "NOT available"))
    end

    add("== 3. Death recap ==")
    if C_DeathRecap then
        local keys = sortedKeys(C_DeathRecap)
        add("  C_DeathRecap functions: " .. ((#keys > 0) and table.concat(keys, ", ") or "none"))
    else
        add("  C_DeathRecap: not available")
    end
    add("  " .. try("DeathRecap_HasEvents()", DeathRecap_HasEvents))
    add("  GetDeathRecapLink: " .. (type(GetDeathRecapLink) == "function" and "exists" or "not available"))
    add("  Tip: '/tavern pvptest listen', then die to a player, to test recap contents.")

    return lines
end

local function RunReport()
    local lines = BuildReport()
    saveDebug("pvptest", { time = date("%Y-%m-%d %H:%M:%S"), lines = lines })

    ns:Print("PvP test report:")
    local statLines, hidden = 0, 0
    for _, line in ipairs(lines) do
        local isStat = line:find("^  %[")
        if isStat then statLines = statLines + 1 end
        if isStat and statLines > MAX_CHAT_STAT_LINES then
            hidden = hidden + 1
        else
            DEFAULT_CHAT_FRAME:AddMessage(line)
        end
    end
    if hidden > 0 then
        DEFAULT_CHAT_FRAME:AddMessage(("  ...%d more statistic lines not shown in chat."):format(hidden))
    end
    ns:Print("Full report saved. /reload to write it to SavedVariables\\Uncs_Tavern.lua.")
end

---------------------------------------------------------------------------
-- Listen mode
---------------------------------------------------------------------------
local listening = false
local listenFrame
local listenLog = {}

local function Log(line)
    line = date("%H:%M:%S ") .. line
    DEFAULT_CHAT_FRAME:AddMessage("|cffe6b422[pvptest]|r " .. line)
    listenLog[#listenLog + 1] = line
    if #listenLog > MAX_LISTEN_LINES then table.remove(listenLog, 1) end
    saveDebug("pvplisten", listenLog)
end

-- Recap IDs count up per death in a session in retail; probe a small range.
local function DumpDeathRecap()
    local R = C_DeathRecap
    if not R then Log("death recap: C_DeathRecap not available") return end
    local newest
    for id = 1, 20 do
        local ok, has = pcall(R.HasRecapEvents, id)
        if ok and has then newest = id end
    end
    if not newest then
        Log("death recap: no recap IDs 1-20 have events. " .. try("HasRecapEvents()", R.HasRecapEvents))
        return
    end
    local ok, events = pcall(R.GetRecapEvents, newest)
    if not ok or type(events) ~= "table" then
        Log(("death recap #%d: GetRecapEvents ERROR %s"):format(newest, fmt(events)))
        return
    end
    Log(("death recap #%d: %d events. Fields of each (first = killing blow in retail):"):format(newest, #events))
    for i = 1, math.min(#events, 3) do
        local parts = {}
        for _, k in ipairs(sortedKeys(events[i])) do
            parts[#parts + 1] = k .. "=" .. fmt(events[i][k])
        end
        Log(("  #%d %s"):format(i, table.concat(parts, " ")))
    end
end

local function OnListenEvent(_, event, ...)
    Log(event .. ": " .. joinResults(pack(...), 1))
    if event == "PLAYER_PVP_KILLS_CHANGED" or event == "CHAT_MSG_COMBAT_HONOR_GAIN" then
        Log("  " .. try("GetPVPSessionStats()", GetPVPSessionStats))
        Log("  " .. try("GetPVPLifetimeStats()", GetPVPLifetimeStats))
    elseif event == "PLAYER_DEAD" then
        -- One-shot delay: the recap may not be populated the instant we die.
        C_Timer.After(2, DumpDeathRecap)
    end
end

local function ToggleListen()
    listenFrame = listenFrame or CreateFrame("Frame")
    listening = not listening
    if listening then
        listenFrame:SetScript("OnEvent", OnListenEvent)
        local on = {}
        for _, e in ipairs(EVENTS) do
            if isEventValid(e) and pcall(listenFrame.RegisterEvent, listenFrame, e) then on[#on + 1] = e end
        end
        ns:Print("pvptest listening to: " .. ((#on > 0) and table.concat(on, ", ") or "nothing (no events exist)"))
    else
        listenFrame:UnregisterAllEvents()
        ns:Print("pvptest listening stopped.")
    end
end

ns:RegisterCommand("pvptest", function(arg)
    if arg:lower() == "listen" then ToggleListen() else RunReport() end
end, "print what PvP data this client exposes ('pvptest listen' logs live events)")
