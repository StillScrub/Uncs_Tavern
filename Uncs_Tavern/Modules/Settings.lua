-- Modules\Settings.lua: Settings tab. Other modules add their own toggles:
--   ns.Settings:RegisterToggle({ key = "levelUpPosts", label = "...", description = "...",
--                                order = 10, onChange = function(value) end })
-- Values live in ns.db.settings[key] (account-wide). Register at load time, before
-- the window is first opened. Modules that use this must load after Settings.lua.
local _, ns = ...

local Settings = {}
ns.Settings = Settings

local toggles = {}

function Settings:RegisterToggle(def)
    assert(def.key and def.label, "Unc's Tavern: toggle needs key and label")
    toggles[#toggles + 1] = def
end

function Settings:Get(key)
    return ns.db and ns.db.settings[key]
end

local function Build(panel)
    table.sort(toggles, function(a, b) return (a.order or 100) < (b.order or 100) end)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -10)
    title:SetText("Settings")

    local anchor, offset = title, -12
    for _, def in ipairs(toggles) do
        local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
        cb:SetSize(26, 26)
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", (anchor == title) and -4 or 0, offset)

        local label = cb.Text or cb.text
        if not label then
            label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
            label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
        end
        label:SetFontObject("GameFontHighlight")
        label:SetText(def.label)

        cb:SetChecked(ns.db.settings[def.key] and true or false)
        cb:SetScript("OnClick", function(self)
            local value = self:GetChecked() and true or false
            ns.db.settings[def.key] = value
            if SOUNDKIT then
                PlaySound(value and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
            end
            if def.onChange then def.onChange(value) end
        end)
        -- Keep in sync if the value is changed elsewhere (e.g. a slash command).
        cb:SetScript("OnShow", function(self) self:SetChecked(ns.db.settings[def.key] and true or false) end)

        anchor, offset = cb, -6
        if def.description then
            local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
            desc:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 30, 2)
            desc:SetPoint("RIGHT", panel, "RIGHT", -20, 0)
            desc:SetJustifyH("LEFT")
            desc:SetText(def.description)
            -- next checkbox lines up with the checkbox column, not the indented text
            offset = -10
            anchor = CreateFrame("Frame", nil, panel)
            anchor:SetSize(1, 1)
            anchor:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -30, 0)
        end
    end

    if #toggles == 0 then
        local none = panel:CreateFontString(nil, "ARTWORK", "GameFontDisable")
        none:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
        none:SetText("No settings yet.")
    end
end

ns.MainFrame:RegisterTab("settings", "Settings", 30, Build)
