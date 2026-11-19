-- Modules\Cheers.lua: a celebration when a guildmate reaches the level cap.
--
-- Cheers:Play(name, classFile, theme, opts) plays it; Modules\Milestones.lua decides
-- when. /tavern cheers test plays it for yourself, locally. Nothing is sent from here.
--
-- Our own painted plate and medal (Media\Cheers) plus the game's fonts, sound kits and
-- glow textures (by path).
-- Everything animates with AnimationGroups (no OnUpdate); the sequence uses one-shot
-- C_Timer calls that check a show token, so skipping cancels the rest. Frames are
-- created on the first show and reused; after the show they're hidden with every
-- animation stopped.
local _, ns = ...

local Cheers = {}
ns.Cheers = Cheers

local LEVEL_CAP  = 60
local DURATION   = 12.0  -- seconds until the fade-out finishes
local FADE_AT    = 10.5
local QUIET_FADE_AT = 4.0 -- quiet version (after combat): banner only, short
local FONT       = "Fonts\\FRIZQT__.TTF"
local BURSTS     = 9     -- firework bursts in the pool
local SPARKS     = 10    -- sparks per burst
local CONFETTI   = 75
local CONFETTI_WAVES = { 0.4, 1.0, 1.7, 2.5, 3.4, 4.4, 5.4, 6.4, 7.4, 8.4 } -- seconds

-- Sounds (game sound kits), played at these seconds into the show.
local SOUNDS = {
    { 0.00, 339650 }, -- fanfare start
    { 0.05, 50111 },  -- raid boss defeated
    { 0.35, 63971 },  -- legendary loot toast (medallion)
    { 0.40, 74702 },  -- cheers (crowd)
    { 0.95, 167127 }, -- adventurer level up (name)
    { 1.20, 74702 },  -- cheers
    { 1.40, 325723 }, -- celebration (firework)
    { 2.10, 74702 },  -- cheers
    { 2.50, 218231 }, -- celebration (firework)
    { 3.30, 171878 }, -- celebration
    { 3.60, 74702 },  -- cheers
    { 4.40, 171876 }, -- celebration
    { 5.00, 46893 },  -- follower level up (second flash)
    { 5.40, 74702 },  -- cheers
    { 6.20, 325723 }, -- celebration (firework)
    { 7.10, 74702 },  -- cheers
    { 7.60, 218231 }, -- celebration (firework)
    { 8.70, 171878 }, -- celebration (finale)
    { 8.80, 74702 },  -- cheers
    { 10.30, 166310 }, -- legendary power (fade)
}
-- Firework bursts: { seconds, x, y } with x/y as fractions of the screen (0..1 from the
-- bottom-left), placed around the banner. Ends with a finale of quick bursts.
local FIREWORKS = {
    { 0.70, 0.30, 0.80 }, { 1.00, 0.70, 0.82 }, { 1.40, 0.42, 0.92 },
    { 1.80, 0.62, 0.58 }, { 2.10, 0.22, 0.66 }, { 2.50, 0.78, 0.68 },
    { 2.90, 0.52, 0.90 }, { 3.20, 0.33, 0.56 }, { 3.60, 0.68, 0.88 },
    { 4.00, 0.18, 0.84 }, { 4.30, 0.82, 0.56 }, { 4.70, 0.40, 0.78 },
    { 5.10, 0.60, 0.92 }, { 5.40, 0.26, 0.58 }, { 5.80, 0.74, 0.80 },
    { 6.20, 0.48, 0.88 }, { 6.50, 0.15, 0.72 }, { 6.90, 0.85, 0.70 },
    { 7.30, 0.36, 0.86 }, { 7.60, 0.64, 0.60 },
    -- finale
    { 8.20, 0.25, 0.74 }, { 8.35, 0.75, 0.74 }, { 8.50, 0.40, 0.88 },
    { 8.65, 0.60, 0.88 }, { 8.80, 0.50, 0.58 }, { 8.95, 0.18, 0.86 },
    { 9.10, 0.82, 0.86 }, { 9.25, 0.33, 0.64 }, { 9.40, 0.67, 0.64 },
}

local GOLD = { 1, 0.82, 0.2 }
local PALETTE = {
    { 1, 0.82, 0.2 }, { 1, 0.95, 0.6 }, { 1, 0.35, 0.3 },
    { 0.4, 0.8, 1 }, { 0.5, 1, 0.45 }, { 0.85, 0.5, 1 }, { 1, 1, 1 },
}
-- Firework colors per theme (neutral also mixes in the class color).
local FIREWORK_COLORS = {
    horde    = { { 1, 0.55, 0.1 }, { 1, 0.3, 0.05 }, { 1, 0.8, 0.25 }, { 0.9, 0.15, 0.05 }, { 1, 0.95, 0.6 } },
    alliance = { { 1, 0.82, 0.2 }, { 0.3, 0.55, 1 }, { 1, 0.95, 0.7 }, { 0.15, 0.4, 0.95 }, { 1, 1, 1 } },
}
local MUG = "|TInterface\\AddOns\\Uncs_Tavern\\Media\\Icon:14:14|t"

local root, showToken = nil, 0
local loops = {}      -- animation groups that loop (stopped when the show ends)
local bursts, confetti = {}, {}
local onDone   -- called once when the current show ends (skipped, finished or replaced)
local onlyPart -- debug: show just one medallion light (/tavern cheers only)

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function Atlas(tex, name)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) then
        tex:SetAtlas(name, true)
        return true
    end
    return false
end

local function Color(c) return c[1], c[2], c[3] end

local function ClassColorOf(classFile)
    local c = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function Later(token, delay, fn)
    C_Timer.After(delay, function()
        if token == showToken then fn() end
    end)
end

local function Alpha(group, from, to, duration, delay)
    local a = group:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(duration)
    a:SetStartDelay(delay or 0)
    return a
end

local function Scale(group, fx, fy, tx, ty, duration, delay)
    local s = group:CreateAnimation("Scale")
    s:SetScaleFrom(fx, fy)
    s:SetScaleTo(tx, ty)
    s:SetDuration(duration)
    s:SetStartDelay(delay or 0)
    return s
end

---------------------------------------------------------------------------
-- Banner: our own painted plate and "60" medallion (Media\Cheers, three themes:
-- neutral, alliance, horde), with the game's circular glows behind the medallion
-- and a light shimmer sweeping across the plate.
---------------------------------------------------------------------------
local MEDIA = "Interface\\AddOns\\Uncs_Tavern\\Media\\Cheers\\"
-- Plate art is 3:1 (1024 x 341), stored at the top of a 1024 x 512 file; the rest is
-- transparent. Shown at its natural 3:1 shape so it never looks stretched.
local PLATE_W, PLATE_H = 640, 213
local PLATE_V = 341 / 512           -- how much of the file height the art fills
local MEDAL_SIZE = 150              -- art is 256 x 256
local TEXT_W = {                    -- width of each plate's empty text area, in plate pixels
    neutral = 470, alliance = 440, horde = 440,
}

-- Theme from my faction (a guild is always one faction): "neutral" if unknown.
local function ThemeOf(override)
    if override == "neutral" or override == "alliance" or override == "horde" then return override end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if faction == "Horde" then return "horde" end
    if faction == "Alliance" then return "alliance" end
    return "neutral"
end

-- A texture on `parent` with optional ADD blend, size and loop animations.
local function Glow(parent, layer, sub, size, setup)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetPoint("CENTER")
    setup(t)
    t:SetSize(size, size)
    return t
end

local function Spin(tex, seconds, degrees)
    local g = tex:CreateAnimationGroup()
    local r = g:CreateAnimation("Rotation")
    r:SetDegrees(degrees or -360)
    r:SetDuration(seconds)
    g:SetLooping("REPEAT")
    loops[#loops + 1] = g
end

local function Pulse(tex, low, high, seconds)
    local g = tex:CreateAnimationGroup()
    Alpha(g, low, high, seconds)
    g:SetLooping("BOUNCE")
    loops[#loops + 1] = g
end

local function CreateBanner()
    local banner = CreateFrame("Button", nil, root)
    banner:SetSize(PLATE_W, PLATE_H) -- placed at Play (a third of the way down the screen)
    banner:SetFrameLevel(root:GetFrameLevel() + 10)
    banner:RegisterForClicks("AnyUp")
    banner:SetScript("OnClick", function() Cheers:Stop() end) -- click to skip

    local plate = banner:CreateTexture(nil, "BACKGROUND", nil, 1)
    plate:SetAllPoints()

    -- Shimmer: a soft light streak sweeping left to right, kept inside the plate's shape.
    -- The mask covers the whole file (art + transparent bottom), so it lines up with the plate.
    local shimmerMask = banner:CreateMaskTexture()
    shimmerMask:SetPoint("TOPLEFT", banner, "TOPLEFT")
    shimmerMask:SetSize(PLATE_W, PLATE_H / PLATE_V)
    local shimmer = banner:CreateTexture(nil, "ARTWORK", nil, 1)
    shimmer:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    shimmer:SetBlendMode("ADD")
    shimmer:SetVertexColor(1, 0.9, 0.6)
    shimmer:SetSize(90, PLATE_H * 1.4)
    shimmer:SetPoint("CENTER", banner, "LEFT", -60, 0)
    shimmer:SetAlpha(0)
    shimmer:AddMaskTexture(shimmerMask)
    local glowFlash = shimmer:CreateAnimationGroup()
    local sweep = glowFlash:CreateAnimation("Translation")
    sweep:SetOffset(PLATE_W + 120, 0)
    sweep:SetDuration(1.1)
    sweep:SetSmoothing("IN_OUT")
    Alpha(glowFlash, 0, 0.55, 0.2)
    Alpha(glowFlash, 0.55, 0, 0.3, 0.8)

    -- Medallion above the plate. Layers: crest (anchor, below the plate), glows (fade in
    -- slowly), medal (our art; pops in).
    local crest = CreateFrame("Frame", nil, root)
    crest:SetSize(MEDAL_SIZE, MEDAL_SIZE)
    crest:SetPoint("BOTTOM", banner, "TOP", 0, 14)
    crest:SetFrameLevel(banner:GetFrameLevel() - 3)
    local glows = CreateFrame("Frame", nil, crest)
    glows:SetAllPoints()
    glows:SetFrameLevel(crest:GetFrameLevel() + 1)
    local medal = CreateFrame("Frame", nil, crest)
    medal:SetAllPoints()
    medal:SetFrameLevel(crest:GetFrameLevel() + 2)

    local rays = Glow(glows, "BACKGROUND", 0, 300, function(t)
        if not Atlas(t, "ArtifactsFX-SpinningGlowys") then t:SetTexture("Interface\\Cooldown\\starburst") end
        t:SetBlendMode("ADD")
    end)
    Spin(rays, 8)
    rays:SetAlpha(0.6)
    local burst = Glow(glows, "BACKGROUND", 1, 250, function(t)
        t:SetTexture("Interface\\Cooldown\\starburst")
        t:SetBlendMode("ADD")
        t:SetVertexColor(1, 0.8, 0.3)
    end)
    Spin(burst, 14, 360)
    Pulse(burst, 0.15, 0.4, 1.6)
    local halo = Glow(glows, "BORDER", 1, 200, function(t)
        t:SetTexture(MEDIA .. "Halo") -- our own soft round glow (the glyph glow wasn't centred)
        t:SetBlendMode("ADD")
        t:SetVertexColor(1, 0.85, 0.4)
    end)
    Pulse(halo, 0.25, 0.6, 1.3)
    local parts = { { "rays", rays }, { "burst", burst }, { "halo", halo } } -- for /tavern cheers only
    for i = 1, 2 do -- light beams turning slowly behind the medallion
        local beam = glows:CreateTexture(nil, "BACKGROUND", nil, 2)
        parts[#parts + 1] = { "beam" .. i, beam }
        beam:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
        beam:SetBlendMode("ADD")
        beam:SetVertexColor(1, 0.85, 0.45)
        beam:SetSize(70, 280)
        beam:SetPoint("CENTER")
        beam:SetRotation(i * math.pi / 2)
        beam:SetAlpha(0.6)
        Spin(beam, 10 + i * 2, (i == 1) and 360 or -360)
    end

    local art = medal:CreateTexture(nil, "ARTWORK")
    art:SetAllPoints()
    local twinkle = Glow(medal, "OVERLAY", 3, 56, function(t)
        t:SetTexture("Interface\\Cooldown\\star4")
        t:SetBlendMode("ADD")
    end)
    twinkle:ClearAllPoints()
    twinkle:SetPoint("CENTER", medal, "TOPRIGHT", -26, -30)
    Pulse(twinkle, 0, 1, 0.6)
    parts[#parts + 1] = { "twinkle", twinkle }
    root.glowParts = parts

    -- Text in the plate's empty middle, with a soft dark shadow so it sits in the art.
    local name = banner:CreateFontString(nil, "OVERLAY")
    name:SetFont(FONT, 20, "OUTLINE")
    name:SetShadowColor(0, 0, 0, 0.9)
    name:SetShadowOffset(1, -1)
    name:SetPoint("CENTER", banner, "CENTER", 12, 14) -- +12: room for the class icon
    local classIcon = banner:CreateTexture(nil, "OVERLAY")
    classIcon:SetSize(22, 22)
    classIcon:SetPoint("RIGHT", name, "LEFT", -6, 0)
    classIcon:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
    local level = banner:CreateFontString(nil, "OVERLAY")
    level:SetFont(FONT, 15, "OUTLINE")
    level:SetShadowColor(0, 0, 0, 0.9)
    level:SetShadowOffset(1, -1)
    level:SetTextColor(Color(GOLD))
    level:SetPoint("CENTER", banner, "CENTER", 0, -12)
    level:SetText(("has reached level %d!"):format(LEVEL_CAP))

    -- Animations: unfurl the plate, pop the medallion, reveal the text.
    local unfurl = banner:CreateAnimationGroup()
    Scale(unfurl, 1, 0.05, 1, 1, 0.4):SetSmoothing("OUT")
    Alpha(unfurl, 0, 1, 0.25)
    local textIn = medal:CreateAnimationGroup() -- medallion: gentle pop
    Alpha(textIn, 0, 1, 0.4)
    Scale(textIn, 0.6, 0.6, 1.08, 1.08, 0.35):SetSmoothing("OUT")
    Scale(textIn, 1, 1, 0.926, 0.926, 0.15, 0.35)
    local glowIn = glows:CreateAnimationGroup() -- glows fade in slowly, no flash
    Alpha(glowIn, 0, 1, 1.5)
    local nameIn = name:CreateAnimationGroup()
    Alpha(nameIn, 0, 1, 0.4)
    Scale(nameIn, 1.4, 1.4, 1, 1, 0.3)
    local levelIn = level:CreateAnimationGroup()
    Alpha(levelIn, 0, 1, 0.4)

    root.banner, root.crest, root.glows, root.glowIn = banner, medal, glows, glowIn
    root.plate, root.medalArt, root.shimmerMask = plate, art, shimmerMask
    root.level, root.name, root.classIcon = level, name, classIcon
    root.unfurl, root.textIn, root.nameIn, root.levelIn, root.glowFlash =
        unfurl, textIn, nameIn, levelIn, glowFlash
end

-- Puts the theme's art in place and fits the name into the plate's text area.
local function ApplyTheme(theme)
    root.plate:SetTexture(MEDIA .. "Plate-" .. theme)
    root.plate:SetTexCoord(0, 1, 0, PLATE_V) -- only the art part of the file
    root.shimmerMask:SetTexture(MEDIA .. "Plate-" .. theme, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    root.medalArt:SetTexture(MEDIA .. "Medal-" .. theme)
    local room = (TEXT_W[theme] or PLATE_W * 0.66) - 30 -- minus the class icon
    for size = 20, 12, -2 do
        root.name:SetFont(FONT, size, "OUTLINE")
        if root.name:GetStringWidth() <= room then break end
    end
end

---------------------------------------------------------------------------
-- Fireworks: a starburst, an expanding ring and sparks flying outwards.
---------------------------------------------------------------------------
local function CreateBurst()
    local f = CreateFrame("Frame", nil, root)
    f:SetSize(1, 1)
    f.parts = {}
    local function Part(texture, size)
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetTexture(texture)
        t:SetBlendMode("ADD")
        t:SetSize(size, size)
        t:SetPoint("CENTER")
        t:SetAlpha(0)
        return t
    end
    local core = Part("Interface\\Cooldown\\starburst", 150)
    f.core = core
    local cg = core:CreateAnimationGroup()
    Alpha(cg, 0, 1, 0.08)
    Alpha(cg, 1, 0, 0.7, 0.15)
    Scale(cg, 0.2, 0.2, 1.4, 1.4, 0.85)
    f.parts[#f.parts + 1] = cg

    local ring = Part("Interface\\Cooldown\\ping4", 120)
    f.ring = ring
    local rg = ring:CreateAnimationGroup()
    Alpha(rg, 0.9, 0, 0.9)
    Scale(rg, 0.3, 0.3, 2.2, 2.2, 0.9)
    f.parts[#f.parts + 1] = rg

    f.sparks = {}
    for i = 1, SPARKS do
        local s = Part("Interface\\Cooldown\\star4", 26)
        local g = s:CreateAnimationGroup()
        local angle = (i - 1) / SPARKS * 2 * math.pi
        local move = g:CreateAnimation("Translation")
        move:SetOffset(math.cos(angle) * 110, math.sin(angle) * 110 - 25) -- a little gravity
        move:SetDuration(1.0)
        move:SetSmoothing("OUT")
        Alpha(g, 0, 1, 0.05)
        Alpha(g, 1, 0, 0.6, 0.45)
        Scale(g, 1, 1, 0.4, 0.4, 1.0)
        s.group = g
        f.sparks[i] = s
        f.parts[#f.parts + 1] = g
    end
    return f
end

local nextBurst = 0
local function Firework(x, y, r, g, b)
    nextBurst = nextBurst % BURSTS + 1
    local f = bursts[nextBurst]
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", UIParent:GetWidth() * x, UIParent:GetHeight() * y)
    f.core:SetVertexColor(r, g, b)
    f.ring:SetVertexColor(r, g, b)
    for _, s in ipairs(f.sparks) do s:SetVertexColor(r, g, b) end
    f:Show()
    for _, group in ipairs(f.parts) do group:Stop(); group:Play() end
end

---------------------------------------------------------------------------
-- Confetti, themed:
--   neutral   colored paper and sparkles
--   horde     glowing embers that shrink as they cool, with a few bright sparks
--   alliance  golden motes of light, white/gold twinkles, blue and gold paper
---------------------------------------------------------------------------
local EMBERS = { { 1, 0.55, 0.1 }, { 1, 0.35, 0.05 }, { 1, 0.75, 0.25 }, { 0.9, 0.2, 0.05 } }
local LIGHT  = { { 1, 0.85, 0.35 }, { 1, 0.95, 0.7 }, { 1, 1, 1 } }
local BLUES  = { { 0.15, 0.35, 0.85 }, { 0.3, 0.55, 1 }, { 1, 0.82, 0.2 } }

local function CreateConfetti()
    local t = root:CreateTexture(nil, "ARTWORK", nil, -1)
    t:SetAlpha(0)
    local g = t:CreateAnimationGroup()
    t.move = g:CreateAnimation("Translation")
    t.spin = g:CreateAnimation("Rotation")
    t.shrink = g:CreateAnimation("Scale")
    Alpha(g, 0, 1, 0.2)
    t.fade = Alpha(g, 1, 0, 0.8)
    g:SetScript("OnFinished", function() t:SetAlpha(0) end)
    t.group = g
    return t
end

local function Pick(list) return list[math.random(#list)] end

-- Sets the piece's look; returns color, fall time range and how much it spins/shrinks.
local function Dress(t, theme, classColor)
    local roll = math.random()
    if theme == "horde" then
        if roll < 0.85 then -- ember: soft glowing dot
            t:SetTexture(MEDIA .. "Halo")
            t:SetBlendMode("ADD")
            local s = math.random(7, 14)
            t:SetSize(s, s)
            return Pick(EMBERS), 3.8, 1.8, 0, 0.35
        end
        t:SetTexture("Interface\\Cooldown\\star4") -- bright spark
        t:SetBlendMode("ADD")
        t:SetSize(10, 10)
        return { 1, 0.9, 0.5 }, 2.6, 1.0, 360, 0.5
    elseif theme == "alliance" then
        if roll < 0.4 then -- mote of light
            t:SetTexture(MEDIA .. "Halo")
            t:SetBlendMode("ADD")
            local s = math.random(8, 13)
            t:SetSize(s, s)
            return Pick(LIGHT), 4.0, 1.5, 0, 1
        elseif roll < 0.7 then -- twinkle
            t:SetTexture("Interface\\Cooldown\\star4")
            t:SetBlendMode("ADD")
            t:SetSize(14, 14)
            return Pick(LIGHT), 3.5, 1.5, 180, 0.6
        end
        t:SetColorTexture(1, 1, 1, 1) -- blue and gold paper
        t:SetBlendMode("BLEND")
        t:SetSize(math.random(5, 8), math.random(9, 14))
        return Pick(BLUES), 3.0, 1.5, 540, 1
    end
    local c = (math.random() < 0.3 and classColor) or Pick(PALETTE)
    if roll < 0.25 then
        t:SetTexture("Interface\\Cooldown\\star4")
        t:SetBlendMode("ADD")
        t:SetSize(14, 14)
    else
        t:SetColorTexture(1, 1, 1, 1)
        t:SetBlendMode("BLEND")
        t:SetSize(math.random(5, 8), math.random(9, 14))
    end
    return c, 3.0, 1.5, 720, 1
end

local function DropConfetti(t, classColor, theme)
    local w, h = UIParent:GetWidth(), UIParent:GetHeight()
    local c, fallMin, fallRange, spin, endScale = Dress(t, theme, classColor)
    t:SetVertexColor(Color(c))
    t:ClearAllPoints()
    t:SetPoint("CENTER", UIParent, "TOPLEFT", w * (0.1 + math.random() * 0.8), math.random(0, 60))
    local fall = fallMin + math.random() * fallRange
    local drift = (theme == "horde") and 120 or 220 -- embers drift less
    t.move:SetOffset((math.random() - 0.5) * drift, -h * (0.55 + math.random() * 0.35))
    t.move:SetDuration(fall)
    t.spin:SetDegrees(spin == 0 and 0 or (math.random() < 0.5 and -1 or 1) * math.random(spin / 4, spin))
    t.spin:SetDuration(fall)
    t.shrink:SetScaleFrom(1, 1)
    t.shrink:SetScaleTo(endScale, endScale)
    t.shrink:SetDuration(fall)
    t.fade:SetStartDelay(fall - 0.8)
    t.group:Stop()
    t.group:Play()
end

---------------------------------------------------------------------------
-- Show
---------------------------------------------------------------------------
local function Create()
    root = CreateFrame("Frame", "UncsTavernCheers", UIParent)
    root:SetAllPoints(UIParent)
    root:SetFrameStrata("FULLSCREEN_DIALOG")
    root:EnableMouse(false) -- never blocks the game; only the banner takes a click
    root:Hide()
    CreateBanner()
    for i = 1, BURSTS do bursts[i] = CreateBurst() end
    for i = 1, CONFETTI do confetti[i] = CreateConfetti() end
    local fade = root:CreateAnimationGroup()
    Alpha(fade, 1, 0, DURATION - FADE_AT)
    fade:SetScript("OnFinished", function() Cheers:Stop() end)
    root.fade = fade
end

function Cheers:Stop()
    showToken = showToken + 1
    if not root then return end
    root.fade:Stop()
    for _, g in ipairs({ root.unfurl, root.textIn, root.glowIn, root.nameIn, root.levelIn, root.glowFlash }) do
        g:Stop()
    end
    for _, g in ipairs(loops) do g:Stop() end
    for _, f in ipairs(bursts) do
        for _, group in ipairs(f.parts) do group:Stop() end
        f:Hide()
    end
    for _, t in ipairs(confetti) do t.group:Stop(); t:SetAlpha(0) end
    root:SetAlpha(1)
    root:Hide()
    local done = onDone
    onDone = nil
    if done then C_Timer.After(0.5, done) end
end

-- "<mug> <Name> has reached level 60!" in my own chat only (never sent).
-- name comes from my own roster (or is my own), never from a message.
function Cheers:ChatLine(name, classFile)
    local r, g, b = ClassColorOf(classFile)
    DEFAULT_CHAT_FRAME:AddMessage(("%s |cff%02x%02x%02x%s|r has reached level %d!"):format(
        MUG, math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), name or "?", LEVEL_CAP))
end

-- name: character name to show; classFile: e.g. "WARRIOR" (for color and icon).
-- theme: "neutral" / "alliance" / "horde" to force one (preview); default = my faction.
-- opts (optional): quiet = true for the short banner-only version (no sounds, fireworks
-- or confetti); onDone = fn called once the show ends, however it ends.
function Cheers:Play(name, classFile, theme, opts)
    if not root then Create() end
    self:Stop()
    onDone = opts and opts.onDone
    local quiet = opts and opts.quiet
    local token = showToken
    local r, g, b = ClassColorOf(classFile)

    root.name:SetText(("Congratulations, %s!"):format(name or "?"))
    root.name:SetTextColor(r, g, b)
    theme = ThemeOf(theme)
    ApplyTheme(theme)
    local coords = classFile and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[classFile]
    if coords then
        root.classIcon:SetTexCoord(unpack(coords))
        root.classIcon:Show()
    else
        root.classIcon:Hide()
    end
    root.crest:SetAlpha(0)
    root.name:SetAlpha(0)
    root.level:SetAlpha(0)
    root.banner:ClearAllPoints()
    root.banner:SetPoint("CENTER", UIParent, "TOP", 0, -UIParent:GetHeight() / 3)
    root:SetAlpha(1)
    root:Show()

    self:ChatLine(name, classFile) -- in case the banner is skipped or missed

    for _, p in ipairs(root.glowParts) do -- debug: /tavern cheers only <part>
        p[2]:SetShown(onlyPart == nil or onlyPart == p[1])
    end

    root.unfurl:Play()
    for _, group in ipairs(loops) do group:Play() end
    root.glows:SetAlpha(0)
    Later(token, 0.3, function() root.crest:SetAlpha(1); root.textIn:Play() end)
    Later(token, 0.6, function() root.glows:SetAlpha(1); root.glowIn:Play() end)
    Later(token, 0.9, function() root.name:SetAlpha(1); root.nameIn:Play(); root.glowFlash:Play() end)
    Later(token, 1.3, function() root.level:SetAlpha(1); root.levelIn:Play() end)
    for _, at in ipairs({ 3.0, 5.0, 7.0, 9.0 }) do -- the shimmer sweeps again every 2 s
        Later(token, at, function() root.glowFlash:Stop(); root.glowFlash:Play() end)
    end

    if quiet then
        Later(token, QUIET_FADE_AT, function() root.fade:Play() end)
        return
    end

    for _, s in ipairs(SOUNDS) do
        Later(token, s[1], function() pcall(PlaySound, s[2], "Master") end)
    end
    local classColor = { r, g, b }
    local themed = FIREWORK_COLORS[theme]
    for i, fw in ipairs(FIREWORKS) do
        local c
        if themed then
            c = themed[(i - 1) % #themed + 1]
        else
            c = (i % 3 == 0) and classColor or PALETTE[(i - 1) % #PALETTE + 1]
        end
        Later(token, fw[1], function() Firework(fw[2], fw[3], Color(c)) end)
    end
    -- Confetti in waves; the pool is split in 5 groups used in turn (pieces fall in
    -- 3-4.5 s, and a group comes round again about 5 s later).
    local perWave = math.floor(CONFETTI / 5)
    for wave, at in ipairs(CONFETTI_WAVES) do
        local first = ((wave - 1) % 5) * perWave
        Later(token, at, function()
            for i = first + 1, first + perWave do DropConfetti(confetti[i], classColor, theme) end
        end)
    end
    Later(token, FADE_AT, function() root.fade:Play() end)
end

-- Hidden preview: plays the show for yourself. Local only, sends nothing.
ns:RegisterCommand("cheers", function(arg)
    arg = (arg or ""):lower()
    local cmd, theme = arg:match("^(%S*)%s*(%S*)")
    if cmd == "test" then -- /tavern cheers test [neutral|alliance|horde]
        local _, classFile = UnitClass("player")
        Cheers:Play(ns:PlayerName(), classFile, theme ~= "" and theme or nil)
    elseif cmd == "stop" then
        Cheers:Stop()
    elseif cmd == "only" then -- /tavern cheers only <part|none|all>: show one medallion light
        if not root then Create() end
        local names = {}
        for _, p in ipairs(root.glowParts) do names[#names + 1] = p[1] end
        if theme == "all" then
            onlyPart = nil
        elseif theme == "none" or tContains(names, theme) then
            onlyPart = theme
        else
            ns:Print("Lights: " .. table.concat(names, ", ") .. ", none, all")
            return
        end
        ns:Print("Medallion lights: " .. (onlyPart or "all"))
        local _, classFile = UnitClass("player")
        Cheers:Play(ns:PlayerName(), classFile)
    end
end, nil, true)
