-- Modules/Wishlist.lua: Wishlist tab (placeholder for the skeleton).
local _, ns = ...

ns.MainFrame:RegisterTab("wishlist", "Wishlist", 20, function(panel)
    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableLarge")
    text:SetPoint("CENTER")
    text:SetText("Wishlist: coming soon")
end)
