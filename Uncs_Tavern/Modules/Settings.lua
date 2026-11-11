-- Modules/Settings.lua: Settings tab (placeholder for the skeleton).
local _, ns = ...

ns.MainFrame:RegisterTab("settings", "Settings", 30, function(panel)
    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
    text:SetPoint("CENTER")
    text:SetText("Settings: coming soon")
end)
