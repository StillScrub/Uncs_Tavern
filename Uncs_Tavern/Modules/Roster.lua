-- Modules/Roster.lua: Roster tab (placeholder for the skeleton).
local _, ns = ...

ns.MainFrame:RegisterTab("roster", "Roster", 10, function(panel)
    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
    text:SetPoint("CENTER")
    text:SetText("Roster: coming soon")
end)
