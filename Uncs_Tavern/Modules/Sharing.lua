-- Modules\Sharing.lua: opt-in to sharing with the current guild, and what is shared.
--
--   * First login in each guild: "Enable Unc's Tavern sharing for <guild>?" Until the
--     player clicks Enable, the addon sends nothing and accepts nothing (Comm.lua
--     enforces this); the guild tab still works from the game's own roster.
--   * Settings (right column): the master switch, one switch per category (wishlist,
--     PvP stats, Helped/History), how long others' requests are kept, and
--     "Delete this guild's data".
-- The choice is saved per guild for the whole WoW account (ns.db.sharing[guildKey]).
local _, ns = ...
local Comm = ns.Comm

local ASK_DELAY = 12 -- seconds after login, so the UI and guild info have settled

local function GuildName()
    return ns:CleanText(IsInGuild() and GetGuildInfo("player") or "", 48)
end

local WHAT = {
    wishlist = "your wishlist requests (item or rule, quantity, price, note), your claims, and what you've received",
    pvp      = "your honorable kills, deaths to players, dishonorable kills/deaths, killing blows, \"Most killed by\" and this week's kills, deaths and best streak",
    helped   = "who delivered items to you (counts toward their Helped and your History)",
    kos      = "the enemy players you put on the guild Kill on Sight list, with your reason, and where you spot players on it",
}

---------------------------------------------------------------------------
-- The opt-in popup (our own frame; never blocks anything)
---------------------------------------------------------------------------
local popup

local function CreatePopup()
    popup = CreateFrame("Frame", "UncsTavernSharingPopup", UIParent, "BasicFrameTemplateWithInset")
    popup:SetSize(440, 250) -- height fits the text (FitPopup)
    popup:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    popup:SetFrameStrata("DIALOG")
    popup:SetClampedToScreen(true)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)

    local title = popup.TitleText or popup:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if not popup.TitleText then title:SetPoint("TOP", popup, "TOP", 0, -5) end
    title:SetText(ns.title)

    popup.question = popup:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    popup.question:SetPoint("TOPLEFT", popup, "TOPLEFT", 16, -34)
    popup.question:SetPoint("RIGHT", popup, "RIGHT", -16, 0)
    popup.question:SetJustifyH("LEFT")

    local body = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    popup.body = body
    body:SetPoint("TOPLEFT", popup.question, "BOTTOMLEFT", 0, -10)
    body:SetPoint("RIGHT", popup, "RIGHT", -16, 0)
    body:SetJustifyH("LEFT")
    body:SetSpacing(2)
    body:SetText("Shared only with this guild's members who run the addon:\n"
        .. "  - " .. WHAT.wishlist .. "\n"
        .. "  - " .. WHAT.pvp .. "\n"
        .. "  - " .. WHAT.helped .. "\n"
        .. "  - " .. WHAT.kos .. "\n"
        .. "  - moderator actions (if your rank may moderate) and, for the guild leader, the rank permissions\n\n"
        .. "|cff999999Never shared: your bags, gold, mail, or which characters are yours. "
        .. "You can switch each part off in Settings.|r")

    local yes = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    yes:SetSize(120, 22)
    yes:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -4, 12)
    yes:SetText("Enable")
    yes:SetScript("OnClick", function()
        popup:Hide()
        Comm:SetSharing("optIn", true)
        ns:Print(("Sharing with %s is on. Change it any time in Settings."):format(GuildName()))
        ns:Fire("SETTINGS_REFRESH")
    end)

    local no = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
    no:SetSize(120, 22)
    no:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 4, 12)
    no:SetText("Not now")
    no:SetScript("OnClick", function()
        popup:Hide()
        Comm:SetSharing("optIn", false)
        ns:Print("Sharing is off. You can turn it on in Settings.")
        ns:Fire("SETTINGS_REFRESH")
    end)
    if popup.CloseButton then popup.CloseButton:Hide() end -- answer with a button
    popup:Hide()
end

local function MaybeAsk()
    local s = Comm:Sharing()
    if not s or s.asked or ns.testGuildKey then return end
    if not popup then CreatePopup() end
    popup.question:SetText(("Enable Unc's Tavern sharing for %s?"):format(GuildName()))
    -- Grow to fit: title bar + question + gap + text + gap + buttons.
    popup:Show()
    popup:SetHeight(34 + popup.question:GetStringHeight() + 10 + popup.body:GetStringHeight() + 18 + 22 + 14)
end

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() C_Timer.After(ASK_DELAY, MaybeAsk) end)
ns:RegisterCallback("GUILD_CHANGED", function(_, key)
    if popup then popup:Hide() end
    if key then C_Timer.After(3, MaybeAsk) end
end)

---------------------------------------------------------------------------
-- Delete this guild's data
---------------------------------------------------------------------------
local function DeleteGuildData()
    local key = ns:GuildKey()
    if not key then return end
    ns.db.wishlist[key] = nil
    ns.db.pvp[key] = nil
    ns.db.helpedLedger[key] = nil
    ns.db.roster[key] = nil
    ns.db.perms[key] = nil      -- comes back from the guild leader while sharing is on
    ns.db.modActions[key] = nil
    ns.db.guildLog[key] = nil
    ns.db.officerLog[key] = nil
    ns.db.kos[key] = nil
    ns.db.kosMod[key] = nil
    ns.db.pvpWeek[key] = nil
    ns.db.pvpRecords[key] = nil
    local h = ns.charDB.history
    if type(h.byGuild) == "table" then h.byGuild[key] = nil end
    ns:Fire("WISHLIST_CHANGED", nil, "remote")
    ns:Fire("PVP_STATS_CHANGED")
    ns:Fire("HISTORY_CHANGED")
    ns:Fire("GUILD_CHANGED", key) -- caches (Helped, Kill on Sight) rebuild
    ns:Print(("Deleted the saved data for %s on this account (your own requests too). "
        .. "Your other characters' History for this guild is kept until you delete it on them."):format(GuildName()))
end

-- Our own dialog (UI\Dialog.lua), not Blizzard's shared StaticPopup.
local function ConfirmDelete()
    ns.Dialog:Show({
        text = ("|cffff4040Delete everything saved for %s?|r\n"
            .. "Wishlist requests (yours too), claims, PvP stats, Kill on Sight entries, Helped and this character's History.\n\n"
            .. "This can't be undone. If sharing stays on, guildmates' data comes back as they log in.")
            :format(GuildName()),
        accept = "Delete",
        onAccept = DeleteGuildData,
    })
end

---------------------------------------------------------------------------
-- Settings: the "Sharing" page in the "Guild" group
---------------------------------------------------------------------------
local function Off() return not Comm:IsSharing() end

ns.Settings:RegisterCategory({
    key = "sharing", name = "Sharing", group = "Guild", order = 100,
    title = function()
        local g = GuildName()
        return g ~= "" and ("Sharing with " .. g) or "Sharing (not in a guild)"
    end,
})
ns.Settings:RegisterToggle({
    category = "sharing", order = 2,
    label = "Share with this guild",
    description = "Off: nothing is sent or accepted. Only this guild's members with the addon receive it.",
    get = function() local s = Comm:Sharing() return s and s.optIn == true end,
    set = function(v) Comm:SetSharing("optIn", v) end,
    disabled = function() return not IsInGuild() end,
})
ns.Settings:RegisterToggle({
    category = "sharing", order = 3, indent = 1,
    label = "Wishlist",
    description = "Your requests, claims, and what you've received.",
    get = function() local s = Comm:Sharing() return s and s.wishlist ~= false end,
    set = function(v) Comm:SetSharing("wishlist", v) end,
    disabled = Off,
})
ns.Settings:RegisterToggle({
    category = "sharing", order = 4, indent = 1,
    label = "PvP stats",
    description = "Your kills, deaths, killing blows and \"Most killed by\".",
    get = function() local s = Comm:Sharing() return s and s.pvp ~= false end,
    set = function(v) Comm:SetSharing("pvp", v) end,
    disabled = Off,
})
ns.Settings:RegisterToggle({
    category = "sharing", order = 5, indent = 1,
    label = "Helped / History",
    description = "Who delivered items to you (their Helped).",
    get = function() local s = Comm:Sharing() return s and s.helped ~= false end,
    set = function(v) Comm:SetSharing("helped", v) end,
    disabled = Off,
})
ns.Settings:RegisterChoice({
    category = "sharing", order = 6,
    key = "requestExpiryDays",
    label = "Keep others' requests",
    description = "Guildmates' requests are forgotten after this many days without hearing from their owner.",
    choices = { 7, 14, 30, 60 },
    format = function(v) return ("%d days unseen"):format(tonumber(v) or 14) end,
    onChange = function() if ns.Wishlist then ns.Wishlist:Purge() end end,
})
ns.Settings:RegisterButton({
    category = "sharing", order = 7,
    label = "Delete this guild's data",
    buttonText = "Delete",
    description = "Removes this guild's wishlist, claims, PvP stats, Kill on Sight list and Helped from this account, and this character's History. Asks first.",
    disabled = function() return not ns:GuildKey() end,
    onClick = ConfirmDelete,
})
