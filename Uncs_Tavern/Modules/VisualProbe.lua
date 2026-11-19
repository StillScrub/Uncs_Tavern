-- Modules\VisualProbe.lua: developer tool. Shows candidate game art, fonts, models and
-- sounds one at a time, so we can see which ones exist on WoW: Forever and how they
-- look before using them. Everything is the game's own (referenced by path, atlas name
-- or sound kit); nothing is copied. Reads only and sends nothing.
--
--   /tavern partyprobe            open at the first item (or where you left off)
--   /tavern partyprobe <n>        jump to item n
--   /tavern partyprobe list       print every item with its number and status
--
-- Hidden from /tavern help. Frames are created on first use.
local _, ns = ...

local W, H = 520, 230 -- display area

-- kind: atlas | tex | font | model | sound
local ITEMS = {
    -- Banners and frames
    { kind = "atlas", id = "BossBanner-BgBanner-Top" },
    { kind = "atlas", id = "BossBanner-BgBanner-Mid" },
    { kind = "atlas", id = "BossBanner-BgBanner-Bottom" },
    { kind = "atlas", id = "BossBanner-SkullCircle" },
    { kind = "atlas", id = "BossBanner-LeftFillagree" },
    { kind = "atlas", id = "BossBanner-RightFillagree" },
    { kind = "atlas", id = "BossBanner-BottomFillagree" },
    { kind = "atlas", id = "BossBanner-RedFlash" },
    { kind = "tex",   id = "Interface\\LevelUp\\LevelUpTex" },
    { kind = "tex",   id = "Interface\\LevelUp\\BossBanner" },
    { kind = "tex",   id = "Interface\\AchievementFrame\\UI-Achievement-Alert-Background" },
    { kind = "tex",   id = "Interface\\AchievementFrame\\UI-Achievement-Alert-Glow" },
    { kind = "tex",   id = "Interface\\AchievementFrame\\UI-Achievement-Guild" },
    { kind = "tex",   id = "Interface\\Icons\\Achievement_Level_60" },
    { kind = "tex",   id = "Interface\\Icons\\Achievement_Level_50" },
    -- Glows, sparkles and bursts
    { kind = "atlas", id = "ArtifactsFX-SpinningGlowys" },
    { kind = "atlas", id = "Relic-Arcane-TraitGlow" },
    { kind = "atlas", id = "loottoast-glow" },
    { kind = "atlas", id = "collections-upgradeglow" },
    { kind = "tex",   id = "Interface\\FullScreenTextures\\LowHealth", gold = true, note = "screen-edge flash, tinted gold" },
    { kind = "tex",   id = "Interface\\FullScreenTextures\\OutOfControl", gold = true, note = "screen-edge flash, tinted gold" },
    { kind = "tex",   id = "Interface\\Cooldown\\star4", add = true },
    { kind = "tex",   id = "Interface\\Cooldown\\starburst", add = true },
    { kind = "tex",   id = "Interface\\Cooldown\\ping4", add = true },
    { kind = "tex",   id = "Interface\\SpellActivationOverlay\\IconAlert", add = true },
    { kind = "tex",   id = "Interface\\Spellbook\\UI-GlyphFrame-Glow", add = true },
    { kind = "tex",   id = "Interface\\CastingBar\\UI-CastingBar-Spark", add = true },
    -- Fonts (shown as "LEVEL 60")
    { kind = "font",  id = "Fonts\\MORPHEUS.TTF" },
    { kind = "font",  id = "Fonts\\FRIZQT__.TTF" },
    { kind = "font",  id = "Fonts\\skurri.ttf" },
    { kind = "font",  id = "Fonts\\ARIALN.TTF" },
    -- 3D effect models
    { kind = "model", id = "spells\\levelup\\levelup.m2", note = "the level-up light" },
    { kind = "model", id = "spells\\fireworks_red_01.m2" },
    { kind = "model", id = "spells\\fireworks_blue_01.m2" },
    { kind = "model", id = "spells\\fireworks_green_01.m2" },
    { kind = "model", id = "spells\\fireworks_yellow_01.m2" },
    { kind = "model", id = "spells\\fireworks_purple_01.m2" },
    { kind = "model", id = "spells\\fireworks_white_01.m2" },
    -- Sounds: numbered kits; matching SOUNDKIT names are added at runtime below.
    { kind = "sound", id = 888, note = "classic level-up" },
}

-- Sound kits whose names sound celebratory (added once, sorted, capped).
local SOUND_WORDS = { "LEVEL", "ACHIEV", "FIREWORK", "CHEER", "BOSS", "LEGENDARY",
                      "FANFARE", "QUEST_COMPLETE", "GUILD_LEVEL", "CELEBRAT", "PARTY" }
local MAX_SOUNDS = 40
local soundsAdded = false

local function AddSoundKits()
    if soundsAdded or type(SOUNDKIT) ~= "table" then return end
    soundsAdded = true
    local names = {}
    for name, id in pairs(SOUNDKIT) do
        if type(name) == "string" and type(id) == "number" then
            for _, w in ipairs(SOUND_WORDS) do
                if name:find(w, 1, true) then names[#names + 1] = name break end
            end
        end
    end
    table.sort(names)
    for i = 1, math.min(#names, MAX_SOUNDS) do
        ITEMS[#ITEMS + 1] = { kind = "sound", id = SOUNDKIT[names[i]], note = "SOUNDKIT." .. names[i] }
    end
end

local frame, current = nil, 1

local function Status(text, ok)
    frame.status:SetText(text)
    if ok == true then frame.status:SetTextColor(0.3, 1, 0.3)
    elseif ok == false then frame.status:SetTextColor(1, 0.3, 0.3)
    else frame.status:SetTextColor(1, 1, 1) end
end

local function ClearDisplay()
    frame.tex:Hide()
    frame.tex:SetVertexColor(1, 1, 1, 1)
    frame.tex:SetBlendMode("BLEND")
    frame.tex:SetTexCoord(0, 1, 0, 1)
    frame.text:Hide()
    frame.model:Hide()
    frame.play:Hide()
end

-- Fit a w x h image inside the display area, keeping its shape.
local function FitTexture(w, h)
    w, h = (w and w > 0) and w or W, (h and h > 0) and h or H
    local s = math.min(W / w, H / h, 2)
    frame.tex:SetSize(w * s, h * s)
end

local function PlayItemSound(item)
    local ok, willPlay = pcall(PlaySound, item.id, "Master")
    Status(("sound kit %s %s"):format(tostring(item.id), (ok and willPlay) and "played" or "did NOT play"),
        ok and willPlay and true or false)
end

local function ShowItem(i)
    current = math.max(1, math.min(i, #ITEMS))
    local item = ITEMS[current]
    ClearDisplay()
    frame.title:SetText(("%d / %d   %s"):format(current, #ITEMS, item.kind))
    frame.name:SetText(tostring(item.id) .. (item.note and ("  |cff808080(" .. item.note .. ")|r") or ""))

    if item.kind == "atlas" then
        local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(item.id)
        if info then
            frame.tex:SetAtlas(item.id)
            FitTexture(info.width, info.height)
            frame.tex:Show()
            Status(("atlas found (%dx%d)"):format(info.width or 0, info.height or 0), true)
        else
            Status("atlas NOT found in this client", false)
        end
    elseif item.kind == "tex" then
        local ok = frame.tex:SetTexture(item.id)
        FitTexture(W, H)
        if item.gold then frame.tex:SetVertexColor(1, 0.8, 0.2, 1) end
        if item.add then frame.tex:SetBlendMode("ADD") end
        frame.tex:Show()
        Status(ok == false and "texture NOT found" or "texture loaded (blank = missing)", ok ~= false)
    elseif item.kind == "font" then
        local ok = frame.text:SetFont(item.id, 54, "OUTLINE")
        frame.text:SetText("LEVEL 60")
        frame.text:Show()
        Status(ok and "font loaded" or "font NOT found (default font shown)", ok and true or false)
    elseif item.kind == "model" then
        frame.model:Show()
        frame.model:ClearModel()
        local ok = pcall(frame.model.SetModel, frame.model, item.id)
        local fileID = ok and frame.model.GetModelFileID and frame.model:GetModelFileID()
        Status(fileID and ("model loaded (file %s)"):format(tostring(fileID)) or "model NOT loaded",
            fileID and true or false)
    elseif item.kind == "sound" then
        frame.play:Show()
        PlayItemSound(item)
    end
end

local function Create()
    frame = CreateFrame("Frame", "UncsTavernVisualProbe", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(W + 40, H + 130)
    frame:SetPoint("TOP", UIParent, "TOP", 0, -80)
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    tinsert(UISpecialFrames, "UncsTavernVisualProbe")

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -5)

    frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.name:SetPoint("TOP", frame, "TOP", 0, -32)
    frame.name:SetWidth(W)

    local area = CreateFrame("Frame", nil, frame)
    area:SetSize(W, H)
    area:SetPoint("TOP", frame, "TOP", 0, -52)
    local bg = area:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.08, 1) -- dark, like a game scene at night

    frame.tex = area:CreateTexture(nil, "ARTWORK")
    frame.tex:SetPoint("CENTER")
    frame.text = area:CreateFontString(nil, "ARTWORK")
    frame.text:SetPoint("CENTER")
    frame.text:SetFontObject("GameFontNormalHuge")
    frame.text:SetTextColor(1, 0.82, 0)
    frame.model = CreateFrame("PlayerModel", nil, area)
    frame.model:SetAllPoints()

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetPoint("TOP", area, "BOTTOM", 0, -8)

    local function Button(label, x, onClick)
        local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        b:SetSize(90, 22)
        b:SetPoint("BOTTOM", frame, "BOTTOM", x, 12)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        return b
    end
    Button("< Prev", -100, function() ShowItem(current - 1) end)
    Button("Next >", 100, function() ShowItem(current + 1) end)
    frame.play = Button("Play again", 0, function() PlayItemSound(ITEMS[current]) end)
end

-- Save the numbered list to SavedVariables (written on /reload), so it can be read
-- outside the game. Developer-only; removed together with this probe.
local function SaveList()
    if not ns.db then return end
    local list = {}
    for i, item in ipairs(ITEMS) do
        list[i] = ("%d %s %s %s"):format(i, item.kind, tostring(item.id), tostring(item.note or ""))
    end
    ns.db.probeList = list
end

ns:RegisterCommand("partyprobe", function(arg)
    AddSoundKits()
    SaveList()
    arg = (arg or ""):lower()
    if arg == "list" then
        ns:Print(("Visual probe: %d items"):format(#ITEMS))
        for i, item in ipairs(ITEMS) do
            local found = ""
            if item.kind == "atlas" then
                found = (C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(item.id)) and " (found)" or " (missing)"
            end
            DEFAULT_CHAT_FRAME:AddMessage(("  %d %s %s%s"):format(i, item.kind, tostring(item.note or item.id), found))
        end
        return
    end
    if not frame then Create() end
    frame:Show()
    ShowItem(tonumber(arg) or current)
end, nil, true)
