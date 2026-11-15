-- Modules\Permissions.lua: which guild ranks may moderate requests/claims and see the
-- officer log. Set by the guild leader only.
--
-- Message (protocol 2, GUILD):
--   K|t|mod|log|days|ranks
--     t     = server time the leader saved it (newer wins)
--     mod   = bit mask of rank indexes that may moderate (bit 0 = guild leader)
--     log   = bit mask of rank indexes that may see the officer log
--     days  = how long guild log entries are kept (1-90)
--     ranks = checksum of the guild's rank names when it was saved
--
-- TRUST: accepted ONLY when our own roster says the sender is rank 0 (guild leader).
-- Nothing in a message ever grants a rank: every check reads the person's rank from
-- our own roster (Comm:RankIndex) and tests it against the leader's masks. If the
-- guild's ranks changed since the leader saved (renamed, added, removed: the checksum
-- differs), everything falls back to "guild leader only" until the leader saves again.
-- The leader re-announces the config when a guildmate logs in or presses Sync (that is
-- the leader's own data, so it's not relaying).
--
-- Stored per guild: ns.db.perms[guildKey] = { t, mod, log, days, ranks }
local _, ns = ...
local Comm = ns.Comm

local Perms = {}
ns.Perms = Perms

local MAX_RANKS     = 10
local DEFAULT_DAYS  = 30
local DAY_CHOICES   = { 7, 14, 30, 60, 90 }
local ANNOUNCE_GAP  = 60 -- seconds between the leader's re-announcements
local FUTURE_SLACK  = 3600

Perms.rejected = 0 -- configs refused (for /tavern securitytest)

local function Now() return GetServerTime and GetServerTime() or time() end

local function Bit(mask, index)
    return math.floor((mask or 0) / 2 ^ index) % 2 == 1
end

local function SetBit(mask, index, on)
    mask = mask or 0
    if Bit(mask, index) == on then return mask end
    return on and mask + 2 ^ index or mask - 2 ^ index
end

---------------------------------------------------------------------------
-- Ranks of the current guild
---------------------------------------------------------------------------
-- [rankIndex] = name for 0 .. n-1. Uses the guild's rank list when the client has it,
-- else the names seen on the roster.
function Perms:RankNames()
    local names = {}
    local n = GuildControlGetNumRanks and GuildControlGetNumRanks() or 0
    if n and n > 0 and GuildControlGetRankName then
        for i = 1, math.min(n, MAX_RANKS) do names[i - 1] = GuildControlGetRankName(i) or ("Rank " .. i) end
    else
        for index, name in pairs(Comm:RosterRankNames()) do
            if index >= 0 and index < MAX_RANKS then names[index] = name end
        end
    end
    return names
end

function Perms:NumRanks()
    local n = 0
    for index in pairs(self:RankNames()) do n = math.max(n, index + 1) end
    return n
end

-- Checksum of the rank names (any rename, addition or removal changes it).
function Perms:RankHash()
    local names, parts = self:RankNames(), {}
    for i = 0, MAX_RANKS - 1 do parts[#parts + 1] = names[i] or "" end
    local s, h = table.concat(parts, "\031"), 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 16777216 end
    return h
end

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
local function Stored()
    local key = ns:GuildKey()
    return key and ns.db.perms[key] or nil
end

-- The config in force: the leader's, or "leader only" when there is none or the ranks
-- changed since it was saved. Returns cfg, state ("none" | "stale" | "ok").
function Perms:Config()
    local s = Stored()
    if not s then return { mod = 1, log = 1, days = DEFAULT_DAYS }, "none" end
    if s.ranks ~= self:RankHash() then return { mod = 1, log = 1, days = s.days or DEFAULT_DAYS }, "stale" end
    return s, "ok"
end

function Perms:LogDays()
    return (self:Config()).days or DEFAULT_DAYS
end

-- what = "mod" | "log". The rank always comes from our own roster.
function Perms:RankCan(rankIndex, what)
    rankIndex = tonumber(rankIndex)
    if not rankIndex then return false end
    if rankIndex == 0 then return true end -- the guild leader can always do everything
    local cfg = self:Config()
    return Bit(cfg[what], rankIndex)
end

function Perms:Can(name, what)
    return self:RankCan(Comm:RankIndex(name), what)
end

function Perms:IAmLeader()
    return Comm:RankIndex(ns:PlayerName()) == 0
end

function Perms:ICan(what)
    return self:Can(ns:PlayerName(), what)
end

---------------------------------------------------------------------------
-- Sending (guild leader only)
---------------------------------------------------------------------------
local lastAnnounce, announcePending = -ANNOUNCE_GAP, false

local function Announce()
    announcePending = false
    local s = Stored()
    if not s or not Perms:IAmLeader() then return end
    lastAnnounce = GetTime()
    Comm:Send("K", s.t, s.mod, s.log, s.days, s.ranks)
end

local function ScheduleAnnounce(delay)
    if announcePending or not Perms:IAmLeader() or not Stored() then return end
    announcePending = true
    C_Timer.After(math.max(delay, ANNOUNCE_GAP - (GetTime() - lastAnnounce)), Announce)
end

-- Leader edits: field = "mod" | "log" (with rankIndex, on) or "days" (value).
local function Save(field, rankIndex, on)
    if not Perms:IAmLeader() then return end
    local key = ns:GuildKey()
    if not key then return end
    local cur = Perms:Config()
    local s = { mod = cur.mod, log = cur.log, days = cur.days or DEFAULT_DAYS }
    if field == "days" then
        s.days = rankIndex
    elseif rankIndex ~= 0 then
        s[field] = SetBit(s[field], rankIndex, on)
    end
    s.mod, s.log = SetBit(s.mod, 0, true), SetBit(s.log, 0, true)
    local old = ns.db.perms[key]
    s.t = math.max(Now(), old and (old.t or 0) + 1 or 0)
    s.ranks = Perms:RankHash()
    ns.db.perms[key] = s
    ns:Fire("PERMS_CHANGED")
    lastAnnounce = -ANNOUNCE_GAP
    ScheduleAnnounce(1)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function Clean(t, mod, log, days, ranks)
    t = ns:Int(t, 1, Now() + FUTURE_SLACK)
    mod = ns:Int(mod, 0, 2 ^ MAX_RANKS - 1)
    log = ns:Int(log, 0, 2 ^ MAX_RANKS - 1)
    days = ns:Int(days, 1, 90)
    ranks = ns:Int(ranks, 0, 16777215)
    if not (t and mod and log and days and ranks) then return nil end
    return { t = t, mod = SetBit(mod, 0, true), log = SetBit(log, 0, true), days = days, ranks = ranks }
end

Comm:RegisterHandler("K", function(sender, ...)
    -- Only the guild leader, by OUR roster. Nothing in the message counts as a rank.
    if Comm:RankIndex(sender) ~= 0 then Perms.rejected = Perms.rejected + 1 return end
    local rec = Clean(...)
    local key = ns:GuildKey()
    if not rec or not key then Perms.rejected = Perms.rejected + 1 return end
    local cur = ns.db.perms[key]
    if cur and (cur.t or 0) >= rec.t then return end
    ns.db.perms[key] = rec
    ns:Fire("PERMS_CHANGED")
end)

ns:RegisterCallback("HELLO", function(_, _, flag)
    if flag == "Q" then ScheduleAnnounce(2 + math.random() * 4) end
end)
ns:RegisterCallback("SYNC_REQUESTED", function() lastAnnounce = -ANNOUNCE_GAP ScheduleAnnounce(2) end)
ns:RegisterCallback("SHARING_CHANGED", function(_, field, value)
    if field == "optIn" and value then ScheduleAnnounce(6) end
end)
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() C_Timer.After(16, function() ScheduleAnnounce(0) end) end)
ns:RegisterCallback("PERMS_CHANGED", function() ns:Fire("SETTINGS_REFRESH") end)
-- (Rank changes need no event: Config() compares the checksum every time it's asked.)

-- Saved data is checked like a message.
ns:RegisterCallback("VALIDATE_DB", function()
    for key, s in pairs(ns.db.perms) do
        local rec = type(key) == "string" and type(s) == "table" and Clean(s.t, s.mod, s.log, s.days, s.ranks)
        ns.db.perms[key] = rec or nil
    end
end)

---------------------------------------------------------------------------
-- Settings: "Permissions" page in the "Guild" group
---------------------------------------------------------------------------
local S = ns.Settings
local GRID_ROW = 26

local function NotLeader() return not Perms:IAmLeader() end

S:RegisterCategory({ key = "permissions", name = "Permissions", group = "Guild", order = 110 })

S:RegisterCustom({
    category = "permissions", order = 1, height = 64,
    build = function(row)
        local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", row, "TOPLEFT", 34, -6)
        fs:SetPoint("RIGHT", row, "RIGHT", -40, 0)
        fs:SetJustifyH("LEFT")
        fs:SetSpacing(2)
        return function()
            local _, state = Perms:Config()
            local lines = {}
            if not IsInGuild() then
                lines[1] = "Not in a guild."
            elseif Perms:IAmLeader() then
                lines[1] = "You are the guild leader: tick what each rank may do. Guildmates get it when they're online with you."
            else
                lines[1] = "|cff999999Only the guild leader can change these. You see what's in force.|r"
            end
            if state == "stale" then
                lines[#lines + 1] = "|cffff8040The guild's ranks changed since this was saved, so only the guild leader can moderate"
                    .. " until the leader changes any box here.|r"
            elseif state == "none" then
                lines[#lines + 1] = "|cff999999Default: only the guild leader can moderate and see the officer log.|r"
            end
            lines[#lines + 1] = "|cff999999Every client checks ranks from its own guild roster; a message can't claim a rank.|r"
            fs:SetText(table.concat(lines, "\n"))
        end
    end,
})

S:RegisterCustom({
    category = "permissions", order = 2, height = 28 + GRID_ROW * MAX_RANKS,
    build = function(row)
        local COL_MOD, COL_LOG = 0, 130 -- from the middle of the page
        local function Head(text, x)
            local fs = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
            fs:SetPoint("TOPLEFT", row, "TOP", x - 10, -4)
            fs:SetText(text)
        end
        local rankHead = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        rankHead:SetPoint("TOPLEFT", row, "TOPLEFT", 34, -4)
        rankHead:SetText("Rank")
        Head("Moderate requests", COL_MOD)
        Head("See officer log", COL_LOG)

        local lines = {}
        for i = 0, MAX_RANKS - 1 do
            local y = -22 - i * GRID_ROW
            local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            label:SetPoint("TOPLEFT", row, "TOPLEFT", 34, y - 6)
            label:SetPoint("RIGHT", row, "CENTER", -20, 0)
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
            local mod = S.Checkbox(row)
            mod:SetPoint("TOPLEFT", row, "TOP", COL_MOD + 20, y)
            local log = S.Checkbox(row)
            log:SetPoint("TOPLEFT", row, "TOP", COL_LOG + 20, y)
            mod:SetScript("OnClick", function(self) Save("mod", i, self:GetChecked() and true or false) end)
            log:SetScript("OnClick", function(self) Save("log", i, self:GetChecked() and true or false) end)
            lines[i] = { label = label, mod = mod, log = log }
        end
        return function()
            local names = Perms:RankNames()
            local leader = Perms:IAmLeader()
            for i = 0, MAX_RANKS - 1 do
                local l = lines[i]
                local name = names[i]
                l.label:SetShown(name ~= nil)
                l.mod:SetShown(name ~= nil)
                l.log:SetShown(name ~= nil)
                if name then
                    l.label:SetText(ns:CleanText(name, 40) .. (i == 0 and " |cff999999(always)|r" or ""))
                    l.mod:SetChecked(Perms:RankCan(i, "mod"))
                    l.log:SetChecked(Perms:RankCan(i, "log"))
                    l.mod:SetEnabled(leader and i ~= 0)
                    l.log:SetEnabled(leader and i ~= 0)
                end
            end
        end
    end,
})

S:RegisterChoice({
    category = "permissions", order = 3,
    label = "Keep guild log entries",
    description = "Guild log and officer log entries are forgotten after this many days (at most 200 entries). Guild leader only.",
    choices = DAY_CHOICES,
    format = function(v) return ("%d days"):format(tonumber(v) or DEFAULT_DAYS) end,
    get = function() return Perms:LogDays() end,
    set = function(v) Save("days", v) end,
    disabled = NotLeader,
})

---------------------------------------------------------------------------
-- /tavern probe: what this client supports (Forever differs from retail in places)
---------------------------------------------------------------------------
ns:RegisterCommand("probe", function()
    ns:Print("Probe (Phase B):")
    local function Line(text) DEFAULT_CHAT_FRAME:AddMessage("  " .. text) end
    local function Has(v) return v and "|cff40ff40yes|r" or "|cffff4040no|r" end
    Line("GuildControlGetNumRanks: " .. Has(GuildControlGetNumRanks) .. "  ranks: "
        .. tostring(GuildControlGetNumRanks and GuildControlGetNumRanks() or "?"))
    local names = Perms:RankNames()
    local list = {}
    for i = 0, MAX_RANKS - 1 do if names[i] then list[#list + 1] = i .. "=" .. ns:CleanText(names[i], 24) end end
    Line("rank names: " .. (#list > 0 and table.concat(list, ", ") or "none"))
    Line(("my rank index: %s | guild leader: %s | can moderate: %s | sees officer log: %s"):format(
        tostring(Comm:RankIndex(ns:PlayerName())), tostring(Perms:IAmLeader()), tostring(Perms:ICan("mod")),
        tostring(Perms:ICan("log"))))
    local _, state = Perms:Config()
    Line("permissions in force: " .. state)
    Line("MenuUtil.CreateContextMenu: " .. Has(MenuUtil and MenuUtil.CreateContextMenu))
    Line("C_GuildInfo.GuildControlGetRankFlags: " .. Has(C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags))
    local ok, err = Comm:ProbeSend("OFFICER")
    Line("addon message on OFFICER: " .. (ok and "|cff40ff40sent|r" or ("|cffff4040failed|r " .. tostring(err))))
    Line("online guildmates seen: " .. #Comm:OnlineMembers())
end, "check what this client supports for permissions and the officer log")
