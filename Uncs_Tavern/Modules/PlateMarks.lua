-- Modules\PlateMarks.lua: a skull drawn over enemy nameplates. Only you see it.
--
-- Raid marks can't be put on enemy players on Forever, so this is our own icon:
-- a small frame parented to the nameplate, shown while that plate is on screen.
--   PlateMarks:SetSkull(name)   my one "skull" target (nil clears it); session only.
--   PlateMarks:Toggle(name)     sets it, or clears it if it's already that name.
--   PlateMarks:AddSource(fn)    fn(name) -> true to also show a skull (e.g. Kill on Sight later).
--   PlateMarks:Refresh()        redraw all plates (call after a source's data changes).
-- Event-driven: nameplate added / removed. Nothing is sent or saved.
local _, ns = ...

local PlateMarks = {}
ns.PlateMarks = PlateMarks

local SIZE = 22
local SKULL_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8"

local mine          -- name ("First Second") of my skull target, or nil
local sources = {}  -- extra fn(name) -> bool
local marks = {}    -- [plate] = our icon frame (reused per plate)

local function PlateName(unit)
    local ok, name = pcall(GetUnitName, unit, true)
    if ok and type(name) == "string" and not (issecretvalue and issecretvalue(name)) then return name end
end

local function Wanted(name)
    if not name then return false end
    if name == mine then return true end
    for _, fn in ipairs(sources) do
        local ok, yes = pcall(fn, name)
        if ok and yes then return true end
    end
    return false
end

local function Mark(plate)
    local m = marks[plate]
    if not m then
        m = CreateFrame("Frame", nil, plate)
        m:SetSize(SIZE, SIZE)
        m:SetPoint("BOTTOM", plate, "TOP", 0, 2)
        m:SetFrameStrata("HIGH")
        local tex = m:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetTexture(SKULL_TEXTURE)
        marks[plate] = m
    end
    return m
end

local function Apply(unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if not ok or not plate then return end
    if Wanted(PlateName(unit)) then
        pcall(function() Mark(plate):Show() end)
    elseif marks[plate] then
        marks[plate]:Hide()
    end
end

function PlateMarks:Refresh()
    for _, m in pairs(marks) do m:Hide() end
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    if not ok or type(plates) ~= "table" then return end
    for _, plate in ipairs(plates) do
        if plate.namePlateUnitToken then Apply(plate.namePlateUnitToken) end
    end
end

function PlateMarks:SetSkull(name)
    mine = name
    self:Refresh()
end

function PlateMarks:Skull() return mine end

-- Returns true if the skull is now on that name, false if it was removed.
function PlateMarks:Toggle(name)
    if mine == name then self:SetSkull(nil) return false end
    self:SetSkull(name)
    return true
end

function PlateMarks:AddSource(fn)
    sources[#sources + 1] = fn
end

ns:RegisterEvent("NAME_PLATE_UNIT_ADDED", function(_, unit) Apply(unit) end)
ns:RegisterEvent("NAME_PLATE_UNIT_REMOVED", function(_, unit)
    if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if ok and plate and marks[plate] then marks[plate]:Hide() end
end)
