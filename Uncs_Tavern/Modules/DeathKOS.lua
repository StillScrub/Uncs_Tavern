-- Modules\DeathKOS.lua: Kill on Sight from the death screen, and a suggestion for
-- players who keep killing me.
--
-- DEATH CARD: our own small frame drawn under Blizzard's death popup (Release Spirit),
-- in the same dialog style so the two look like one. Blizzard's popup is never edited
-- or hooked: the card is only parented and anchored to it, so it hides with it, and
-- Release Spirit stays untouched. The killer comes from the death recap right away
-- (PvPStats:RecapKiller). The button opens the usual Kill on Sight menu (quick add,
-- presets, own reason). Greyed out for deaths to mobs, pets or guild members.
--
-- SUGGESTION: when the same player kills me kosSuggestKills times within
-- kosSuggestMinutes (confirmed PvP deaths from PvPStats' PVP_DEATH; duels never count),
-- ask once: "Add <name> to the guild Kill on Sight list?" Never adds on its own.
-- Kill times are kept in session memory only.
local _, ns = ...
local KOS, Comm = ns.KOS, ns.Comm

local CARD_W, CARD_H = 320, 58
local SHOW_DELAY = 0.3      -- seconds after PLAYER_DEAD (the popup is shown by then)
local RETRY_DELAY = 1.5
local MAX_TRACKED = 50      -- killers remembered for the suggestion

local card
local killTimes = {}  -- [name] = { time(), ... } of PvP deaths to that player, this session
local suggested = {}  -- [name] = time() of the last suggestion
local tracked = 0

local function S() return ns.db.settings end

local function DisplayName(name)
    return ns.PvPTab and ns.PvPTab.DisplayName(name) or name
end

-- The recap's name, or better the GUID's name (the same form the enemy book uses).
local function KillerName(name, guid)
    if type(guid) == "string" and guid:match("^Player%-") then
        local ok, _, _, _, _, _, gname = pcall(GetPlayerInfoByGUID, guid)
        if ok and type(gname) == "string" and gname ~= "" and not (issecretvalue and issecretvalue(gname)) then
            name = gname
        end
    end
    if type(name) ~= "string" or (issecretvalue and issecretvalue(name)) then return nil end
    return ns:ValidName(ns:CleanText(name, 48))
end

local function ClassColored(name)
    local e = ns.Enemies and ns.Enemies:Get(name)
    local c = e and e.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[e.class]
    local shown = DisplayName(name)
    if c and c.colorStr then return "|c" .. c.colorStr .. shown .. "|r" end
    return shown
end

---------------------------------------------------------------------------
-- The card
---------------------------------------------------------------------------
local function OpenMenu(button)
    local name = card.killer
    if not (name and MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle(DisplayName(name))
        KOS:FillMenu(root, name, nil)
    end)
end

local function Create()
    card = CreateFrame("Frame", "UncsTavernDeathCard", UIParent, "BackdropTemplate")
    card:SetSize(CARD_W, CARD_H)
    card:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    card:EnableMouse(true)
    card.text = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    card.text:SetPoint("TOP", card, "TOP", 0, -12)
    card.text:SetWidth(CARD_W - 30)
    card.text:SetWordWrap(false)
    card.button = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    card.button:SetSize(190, 22)
    card.button:SetPoint("BOTTOM", card, "BOTTOM", 0, 10)
    card.button:SetScript("OnClick", OpenMenu)
    card.button:SetMotionScriptsWhileDisabled(true)
    card.button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(ns.title)
        GameTooltip:AddLine(self.tip or "", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    card.button:SetScript("OnLeave", GameTooltip_Hide)
    -- The popup frame is reused for other popups: only show under the death popup.
    card:SetScript("OnShow", function(self)
        local p = self:GetParent()
        if p ~= UIParent and not (p and p.which == "DEATH") then self:Hide() end
    end)
    card:Hide()
end

local function Detach()
    if not card then return end
    card:Hide()
    card:SetParent(UIParent)
    card:ClearAllPoints()
end

local function DeathPopup()
    if not StaticPopup_FindVisible then return nil end
    local ok, popup = pcall(StaticPopup_FindVisible, "DEATH")
    return ok and popup or nil
end

-- Fills the card from the newest death recap. popup = Blizzard's death popup, or nil
-- for /tavern kostest (then the card sits in the middle of the screen).
local function Fill(popup, name, why)
    if not card then Create() end
    card:SetParent(popup or UIParent)
    card:ClearAllPoints()
    if popup then
        card:SetPoint("TOP", popup, "BOTTOM", 0, 6)
        card:SetFrameLevel(popup:GetFrameLevel() + 5)
    else
        card:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
        card:SetFrameStrata("DIALOG")
    end
    card.killer = nil
    local b = card.button
    b:SetText("Add to Kill on Sight")
    if name and Comm:IsMember(name) then
        card.text:SetText("Killed by " .. name .. " (guild member)")
        b.tip = "Guild members can't go on Kill on Sight."
        b:Disable()
    elseif name then
        card.killer = name
        card.text:SetText("Killed by " .. ClassColored(name))
        if KOS:Mine(name) then
            b:SetText("On your Kill on Sight list")
            b.tip = "Click to renew or remove your entry."
        else
            b.tip = "Put them on your guild's Kill on Sight list: quick add, or pick a reason."
        end
        b:Enable()
    else
        card.text:SetText(why == "pet" and "Killed by a player's pet"
            or why == "pve" and "Not killed by a player"
            or "No killer found in the death recap")
        b.tip = why == "pet" and "The death recap doesn't say whose pet it was."
            or "Only deaths to enemy players can be added."
        b:Disable()
    end
    card:Show()
    if popup and popup.which ~= "DEATH" then card:Hide() end
end

local function ShowCard(retry)
    if not (ns.db and S().deathCard and ns:GuildKey()) then return end
    if not UnitIsDeadOrGhost("player") then return end
    local popup = DeathPopup()
    if not popup then
        if not retry then C_Timer.After(RETRY_DELAY, function() ShowCard(true) end) end
        return
    end
    local name, guid = ns.PvPStats:RecapKiller()
    if name then
        Fill(popup, KillerName(name, guid))
    else
        Fill(popup, nil, guid) -- guid holds the reason here ("pet", "pve") or nil
    end
end

ns:RegisterEvent("PLAYER_DEAD", function() C_Timer.After(SHOW_DELAY, function() ShowCard(false) end) end)
ns:RegisterEvent("PLAYER_ALIVE", Detach)
ns:RegisterEvent("PLAYER_UNGHOST", Detach)
ns:RegisterCallback("KOS_CHANGED", function()
    if card and card:IsShown() and card.killer then
        local p = card:GetParent()
        Fill(p ~= UIParent and p or nil, card.killer)
    end
end)

---------------------------------------------------------------------------
-- Suggestion after repeat deaths
---------------------------------------------------------------------------
local function Window()
    return (ns:Int(S().kosSuggestMinutes, 5, 240) or 30) * 60
end

local function Suggest(name, count)
    local minutes = math.floor(Window() / 60)
    ns.Dialog:Show({
        text = ("%s has killed you %s in %d minutes.\n\nAdd them to the guild Kill on Sight list?")
            :format(ClassColored(name), count == 1 and "once" or (count .. " times"), minutes),
        accept = "Add",
        cancel = "Not now",
        onAccept = function()
            local ok, err = KOS:Add(name, nil, 0, ("Killed me %s in %d min"):format(count == 1 and "once" or (count .. " times"), minutes))
            if ok then
                ns:Print(("Added %s to the guild Kill on Sight list."):format(name))
            elseif err then
                ns:Print(err)
            end
        end,
    })
end

local function OnPvPDeath(_, killer, guid)
    if not (ns.db and S().kosSuggest and ns:GuildKey()) then return end
    if type(guid) == "string" and guid:match("^Pet%-") then return end -- a pet's name isn't its owner's
    local name = KillerName(killer, guid)
    if not name or Comm:IsMember(name) then return end
    local now, window = time(), Window()
    local list = killTimes[name]
    if not list then
        if tracked >= MAX_TRACKED then wipe(killTimes) tracked = 0 end
        list = {}
        killTimes[name] = list
        tracked = tracked + 1
    end
    list[#list + 1] = now
    for i = #list, 1, -1 do
        if now - list[i] > window then table.remove(list, i) end
    end
    local need = ns:Int(S().kosSuggestKills, 1, 10) or 2
    if #list < need or KOS:Mine(name) then return end
    if suggested[name] and now - suggested[name] < window then return end
    suggested[name] = now
    Suggest(name, #list)
end

ns:RegisterCallback("PVP_DEATH", OnPvPDeath)

---------------------------------------------------------------------------
-- Settings > PvP
---------------------------------------------------------------------------
ns.Settings:RegisterToggle({
    category = "pvp", key = "deathCard", order = 30,
    label = "Kill on Sight button on the death screen",
    description = "When an enemy player kills you, a small panel under Release Spirit lets you put "
        .. "them on your guild's Kill on Sight list.",
})
ns.Settings:RegisterToggle({
    category = "pvp", key = "kosSuggest", order = 31,
    label = "Suggest adding players who keep killing you",
    description = "Asks (never adds by itself) when the same player kills you several times in a short time.",
})
ns.Settings:RegisterChoice({
    category = "pvp", key = "kosSuggestKills", order = 32, indent = 1,
    label = "Ask after",
    choices = { 1, 2, 3, 4, 5 },
    format = function(v) v = tonumber(v) or 2 return v == 1 and "1 kill" or ("%d kills"):format(v) end,
    disabled = function() return not S().kosSuggest end,
})
ns.Settings:RegisterChoice({
    category = "pvp", key = "kosSuggestMinutes", order = 33, indent = 1,
    label = "Within",
    choices = { 15, 30, 60, 120 },
    format = function(v) return ("%d minutes"):format(tonumber(v) or 30) end,
    disabled = function() return not S().kosSuggest end,
})

---------------------------------------------------------------------------
-- /tavern kostest (hidden, needs /tavern debug on): try both with your target
---------------------------------------------------------------------------
ns:RegisterCommand("kostest", function(arg)
    if not S().debug then ns:Print("Turn on /tavern debug on first.") return end
    local ok, name = pcall(GetUnitName, "target", true)
    name = ok and type(name) == "string" and ns:ValidName(ns:CleanText(name, 48)) or nil
    if not name then ns:Print("Target a player first.") return end
    if strtrim(arg or "") == "suggest" then
        Suggest(name, ns:Int(S().kosSuggestKills, 1, 10) or 2)
    else
        Fill(nil, name)
        C_Timer.After(20, function() if card and card:GetParent() == UIParent then card:Hide() end end)
        ns:Print("Test card shown for 20 seconds. /tavern kostest suggest shows the suggestion.")
    end
end, nil, true)
