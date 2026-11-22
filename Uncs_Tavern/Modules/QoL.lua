-- Modules\QoL.lua: quality-of-life warnings about my own buffs. Local only: reads my own
-- buffs, nothing is sent.
--
--   * Well Rested watch (the sleeping-bag buff, up to 3 stacks): warns when I don't have
--     it, when it has fewer than 3 stacks, and 15 minutes before it runs out (using the
--     sleeping bag while it's still up skips the full wait).
--   * XP food watch: warns when no "Well Fed" buff that gives bonus experience is up.
--     Not every Well Fed buff gives XP, so a Well Fed buff counts only if its tooltip
--     mentions experience; the answer is remembered per spell ID (db.xpFood). On
--     non-English clients any Well Fed counts.
-- Small pop-up only (never an always-on indicator), middle of the screen by default,
-- draggable. Both buffs only matter for XP, so nothing is said at max level.
-- When: 10 s after login, on leaving a rest area, when a buff drops off, and the
-- 15-minute Well Rested reminder (one C_Timer). Never in combat or while dead (it waits).
-- Event-driven: UNIT_AURA (player), PLAYER_UPDATE_RESTING, PLAYER_REGEN_ENABLED.
local _, ns = ...

local WELL_RESTED_ID = 429959
local WELL_RESTED_MAX = 3
local XP_FOOD_IDS = { [1249519] = true }   -- confirmed in game; more are learned
local WELL_FED_ID = 1249519                 -- for the localized "Well Fed" name
local REFRESH_BEFORE = 15 * 60
local LOGIN_DELAY = 10
local SAME_WARNING_GAP = 300                -- seconds before the same warning repeats
local TOAST_SECONDS = 10
-- Icons: the buffs' own, read from the game (fallbacks: sleep / food icons).
local function SpellIcon(id, fallback)
    local ok, t = pcall(C_Spell and C_Spell.GetSpellTexture or function() end, id)
    return ok and t or fallback
end
local REST_ICON = SpellIcon(WELL_RESTED_ID, 136090)
local FOOD_ICON = SpellIcon(WELL_FED_ID, 133974)

local QoL = {}
ns.QoL = QoL

local lastShown = {}      -- [warning key] = GetTime()
local had = {}            -- { rested = bool, food = bool } at the last scan
local pending             -- reason waiting for combat to end
local refreshTimer, refreshToken
local warnedExpiry        -- expirationTime the 15-minute reminder was shown for
local scanQueued = false

local function S() return ns.db.settings end

local function Secret(v) return issecretvalue and issecretvalue(v) end

local MAX_LEVEL = 60 -- Forever's level cap (the client's own max-level APIs are retail's)
local function AtMaxLevel()
    local lvl = UnitLevel("player")
    return type(lvl) == "number" and lvl >= MAX_LEVEL
end

---------------------------------------------------------------------------
-- Reading my buffs
---------------------------------------------------------------------------
local function English()
    local l = GetLocale and GetLocale() or "enUS"
    return l == "enUS" or l == "enGB"
end

local wellFedName
local function WellFedName()
    if not wellFedName and C_Spell and C_Spell.GetSpellName then
        local ok, n = pcall(C_Spell.GetSpellName, WELL_FED_ID)
        if ok and type(n) == "string" and n ~= "" then wellFedName = n end
    end
    return wellFedName or "Well Fed"
end

-- Does this Well Fed buff give XP? Known IDs, learned IDs, else its tooltip text.
local function GivesXP(aura)
    local id = aura.spellId
    if type(id) ~= "number" or Secret(id) then return false end
    if XP_FOOD_IDS[id] then return true end
    local learned = ns.db.xpFood[id]
    if learned ~= nil then return learned end
    if not English() then return true end
    if not (C_TooltipInfo and C_TooltipInfo.GetUnitBuffByAuraInstanceID) then return false end
    local ok, data = pcall(C_TooltipInfo.GetUnitBuffByAuraInstanceID, "player", aura.auraInstanceID)
    if not ok or type(data) ~= "table" or type(data.lines) ~= "table" then return false end
    local xp = false
    for _, line in ipairs(data.lines) do
        local t = line.leftText
        if type(t) == "string" and not Secret(t) and t:lower():find("experience", 1, true) then xp = true break end
    end
    ns.db.xpFood[id] = xp
    return xp
end

-- { rested = aura or nil, food = bool }, or nil when the buffs can't be read now.
local function Scan()
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return nil end
    local out = { food = false }
    local okR, r = pcall(C_UnitAuras.GetPlayerAuraBySpellID, WELL_RESTED_ID)
    if okR and type(r) == "table" then out.rested = r end
    local fed = WellFedName()
    for i = 1, 80 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
        if not ok then return nil end
        if type(a) ~= "table" then break end
        if Secret(a.name) then return nil end
        if a.name == fed and GivesXP(a) then out.food = true break end
    end
    return out
end

---------------------------------------------------------------------------
-- The pop-up
---------------------------------------------------------------------------
local toast

local function SavePos()
    local point, _, relPoint, x, y = toast:GetPoint(1)
    ns.charDB.qolPos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function CreateToast()
    toast = CreateFrame("Frame", "UncsTavernQoLToast", UIParent, "BackdropTemplate")
    toast:SetSize(360, 50)
    toast:SetFrameStrata("HIGH")
    toast:SetClampedToScreen(true)
    toast:SetMovable(true)
    toast:EnableMouse(true)
    toast:RegisterForDrag("LeftButton")
    toast:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    toast:SetBackdropColor(0, 0, 0, 0.85)
    toast:SetBackdropBorderColor(0.7, 0.55, 0.3, 1)
    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetSize(32, 32)
    toast.icon:SetPoint("LEFT", toast, "LEFT", 10, 0)
    toast.title = toast:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 10, 2)
    toast.title:SetPoint("RIGHT", toast, "RIGHT", -10, 0)
    toast.title:SetJustifyH("LEFT")
    toast.text = toast:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    toast.text:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -3)
    toast.text:SetPoint("RIGHT", toast, "RIGHT", -10, 0)
    toast.text:SetJustifyH("LEFT")
    toast.text:SetSpacing(2)

    local fade = toast:CreateAnimationGroup()
    local a = fade:CreateAnimation("Alpha")
    a:SetFromAlpha(1)
    a:SetToAlpha(0)
    a:SetDuration(1.5)
    fade:SetScript("OnFinished", function() toast:Hide() end)
    toast.fade = fade

    toast:SetScript("OnDragStart", function(self) self.fade:Stop() self:SetAlpha(1) self:StartMoving() end)
    toast:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePos() end)
    toast:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then
            ns.charDB.qolPos = nil
            self:ClearAllPoints()
            self:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
        else
            self:Hide()
        end
    end)
    toast:SetScript("OnEnter", function(self)
        self.fade:Stop()
        self:SetAlpha(1)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(ns.title)
        GameTooltip:AddLine("Click to close. Drag to move; right-click puts it back in the middle.", 1, 1, 1, true)
        GameTooltip:AddLine("Turn these off in Settings > Quality of life.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    toast:SetScript("OnLeave", function(self)
        GameTooltip_Hide()
        self.hideAt = GetTime() + 3
        C_Timer.After(3, function() if toast:IsShown() and GetTime() >= toast.hideAt then toast.fade:Play() end end)
    end)

    local p = ns.charDB.qolPos
    if type(p) == "table" and type(p.point) == "string" and type(p.x) == "number" and type(p.y) == "number" then
        toast:SetPoint(p.point, UIParent, type(p.relPoint) == "string" and p.relPoint or p.point, p.x, p.y)
    else
        toast:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    end
    toast:Hide()
end

-- lines = { { key, text }, ... }
local function ShowToast(icon, lines)
    if #lines == 0 then return end
    if not toast then CreateToast() end
    local texts = {}
    for _, l in ipairs(lines) do texts[#texts + 1] = l[2] end
    toast.icon:SetTexture(icon)
    toast.title:SetText(ns.title)
    toast.text:SetText(table.concat(texts, "\n"))
    toast:SetHeight(math.max(50, 24 + toast.title:GetStringHeight() + toast.text:GetStringHeight()))
    toast.fade:Stop()
    toast:SetAlpha(1)
    toast:Show()
    toast.hideAt = GetTime() + TOAST_SECONDS
    C_Timer.After(TOAST_SECONDS, function()
        if toast:IsShown() and GetTime() >= toast.hideAt and not toast:IsMouseOver() then toast.fade:Play() end
    end)
    PlaySound(SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPEN or 850)
end

---------------------------------------------------------------------------
-- Deciding what to say
---------------------------------------------------------------------------
local function Remaining(aura)
    local exp = aura and aura.expirationTime
    if type(exp) ~= "number" or Secret(exp) or exp == 0 then return nil end
    return exp - GetTime(), exp
end

local function ScheduleRefresh(aura)
    refreshToken = nil
    local left, exp = Remaining(aura)
    if not left or left <= REFRESH_BEFORE then return end
    local token = {}
    refreshToken = token
    C_Timer.After(left - REFRESH_BEFORE + 1, function()
        if refreshToken == token then QoL:Check("refresh") end
    end)
end

-- reason: "login", "rest" (left a rest area), "drop", "refresh", "test", "command"
function QoL:Check(reason)
    if not ns.db then return end
    local wantRested, wantFood = S().qolWellRested, S().qolXPFood
    if not (wantRested or wantFood) and reason ~= "test" then return end
    if InCombatLockdown() or UnitIsDeadOrGhost("player") then pending = reason return end
    local st = Scan()
    if not st then pending = reason return end

    if reason == "test" then
        ShowToast(REST_ICON, { { "t1", "|cffffd100Test:|r Only 2 of 3 Well Rested stacks. Use your sleeping bag." },
            { "t2", "|cffffd100Test:|r No XP food buff. Eat food that gives bonus experience." } })
        return
    end
    if AtMaxLevel() then return end

    local now, lines, icon = GetTime(), {}, REST_ICON
    local function Add(key, text, ic)
        if reason ~= "command" and lastShown[key] and now - lastShown[key] < SAME_WARNING_GAP then return end
        lastShown[key] = now
        lines[#lines + 1] = { key, text }
        if #lines == 1 then icon = ic end
    end

    local general = reason == "login" or reason == "rest" or reason == "command"
    if wantRested then
        local r = st.rested
        local stacks = r and (not Secret(r.applications)) and (r.applications or 0) or 0
        local left, exp = Remaining(r)
        if not r then
            if general or (reason == "drop" and had.rested) then
                Add("noRest", "No Well Rested buff. Use your sleeping bag.", REST_ICON)
            end
        elseif general and stacks > 0 and stacks < WELL_RESTED_MAX then
            Add("lowRest", ("Only %d of %d Well Rested stacks. Use your sleeping bag.")
                :format(stacks, WELL_RESTED_MAX), REST_ICON)
        end
        if r and left and left <= REFRESH_BEFORE and left > 0 and warnedExpiry ~= exp then
            warnedExpiry = exp
            Add("refresh", ("Well Rested ends in %d min. Use your sleeping bag now.")
                :format(math.max(1, math.floor(left / 60))), REST_ICON)
        end
        ScheduleRefresh(r)
    end
    if wantFood and not st.food then
        if general or (reason == "drop" and had.food) then
            Add("noFood", "No XP food buff. Eat food that gives bonus experience.", FOOD_ICON)
        end
    end
    had.rested, had.food = st.rested ~= nil, st.food
    ShowToast(icon, lines)
end

-- Buff changes: only a buff dropping off says anything (or the reminder timer moving).
local function OnAura(_, unit)
    if unit ~= "player" or scanQueued or not ns.db then return end
    scanQueued = true
    C_Timer.After(1, function()
        scanQueued = false
        if InCombatLockdown() then return end -- re-checked after combat if needed
        local st = Scan()
        if not st then return end
        local dropped = (had.rested and not st.rested) or (had.food and not st.food)
        if dropped then
            QoL:Check("drop")
        else
            had.rested, had.food = st.rested ~= nil, st.food
            if S().qolWellRested then ScheduleRefresh(st.rested) end
        end
    end)
end

local wasResting
ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isLogin, isReload)
    wasResting = IsResting()
    if isLogin or isReload then C_Timer.After(LOGIN_DELAY, function() QoL:Check("login") end) end
end)
ns:RegisterEvent("PLAYER_UPDATE_RESTING", function()
    local now = IsResting()
    if wasResting and not now then QoL:Check("rest") end
    wasResting = now
end)
ns:RegisterEvent("UNIT_AURA", OnAura)
ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
    if pending then local r = pending pending = nil C_Timer.After(2, function() QoL:Check(r) end) end
end)
ns:RegisterEvent("PLAYER_UNGHOST", function()
    if pending then local r = pending pending = nil C_Timer.After(2, function() QoL:Check(r) end) end
end)

-- Saved data: db.xpFood = { [spellID] = true|false } only.
ns:RegisterCallback("VALIDATE_DB", function()
    if type(ns.db.xpFood) ~= "table" then ns.db.xpFood = {} return end
    for k, v in pairs(ns.db.xpFood) do
        if not ns:Int(k, 1) or type(v) ~= "boolean" then ns.db.xpFood[k] = nil end
    end
end)

ns:RegisterCommand("qol", function()
    QoL:Check("command")
    if ns.QoLBag then ns:Print(ns.QoLBag:Status()) end
end, "check your Well Rested and XP food buffs, and your sleeping bag, now")

---------------------------------------------------------------------------
-- Settings > Quality of life
---------------------------------------------------------------------------
ns.Settings:RegisterCategory({ key = "qol", name = "Quality of life", group = ns.title, order = 15 })
ns.Settings:RegisterToggle({
    category = "qol", key = "qolWellRested", order = 10,
    label = "Well Rested watch",
    description = "A small pop-up when you don't have Well Rested (the sleeping-bag buff), when it has fewer "
        .. "than 3 stacks, and 15 minutes before it runs out. At login, when you leave a rest area, and when it drops off.",
})
ns.Settings:RegisterToggle({
    category = "qol", key = "qolXPFood", order = 20,
    label = "XP food watch",
    description = "A small pop-up when no Well Fed buff that gives bonus experience is up. "
        .. "At login, when you leave a rest area, and when it drops off.",
})
ns.Settings:RegisterButton({
    category = "qol", order = 30, label = "Show a test pop-up (drag it where you want it)", buttonText = "Test",
    onClick = function() QoL:Check("test") end,
})
