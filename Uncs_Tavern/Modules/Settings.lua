-- Modules\Settings.lua: Settings tab, two columns. Other modules add their own entries:
--   ns.Settings:RegisterToggle({ key = "levelUpPosts", label = "...", description = "...",
--                                order = 10, column = 1, onChange = function(value) end })
--     Values live in ns.db.settings[key] (account-wide), unless the def gives its own
--     get() / set(value). disabled() greys it out.
--     tooltip = "..." | function shows on hover (also while greyed out).
--   ns.Settings:RegisterHeader({ text = "..." | function, order, column })
--   ns.Settings:RegisterText({ text = "..." | function, order, column })
--   ns.Settings:RegisterButton({ label = "...", onClick = fn, order, column, width })
--   ns.Settings:RegisterChoice({ key, label, choices = { 7, 14, 30 }, format = fn(v), order, column })
--     a button that cycles through the choices; value in ns.db.settings[key].
-- Register at load time, before the window is first opened. Texts and states are
-- refreshed every time the tab is shown and on ns:Fire("SETTINGS_REFRESH").
local _, ns = ...

local Settings = {}
ns.Settings = Settings

local defs = {}
local widgets = {} -- { refresh = fn }

local function Add(kind, def)
    def.kind = kind
    defs[#defs + 1] = def
end

function Settings:RegisterToggle(def)
    assert(def.label and (def.key or def.get), "Unc's Tavern: toggle needs key/get and label")
    Add("toggle", def)
end
function Settings:RegisterHeader(def) Add("header", def) end
function Settings:RegisterText(def) Add("text", def) end
function Settings:RegisterButton(def) Add("button", def) end
function Settings:RegisterChoice(def) Add("choice", def) end

function Settings:Get(key)
    return ns.db and ns.db.settings[key]
end

local function TextOf(v)
    if type(v) == "function" then return v() or "" end
    return v or ""
end

local buttons = {} -- { b, def, col } for buttons and choices

-- Buttons in one column share one width (the widest text), so they line up.
local function SizeButtons()
    local width = {}
    for _, e in ipairs(buttons) do
        local need = math.max(e.def.width or 190, e.b:GetTextWidth() + 28)
        width[e.col] = math.max(width[e.col] or 0, need)
    end
    for _, e in ipairs(buttons) do e.b:SetWidth(width[e.col]) end
end

local function Refresh()
    for _, w in ipairs(widgets) do w.refresh() end
    SizeButtons()
end

local function Build(tab)
    table.sort(defs, function(a, b) return (a.order or 100) < (b.order or 100) end)

    -- Everything sits on a scroll child, so a small window scrolls instead of the
    -- last entries running into the border.
    local scroll = CreateFrame("ScrollFrame", nil, tab, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -28, 8)
    local panel = CreateFrame("Frame", nil, scroll)
    panel:SetSize(math.max(scroll:GetWidth(), 400), 400)
    scroll:SetScrollChild(panel)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -10)
    title:SetText("Settings")

    -- One anchor per column; each element goes below the previous one in its column.
    local column2 = CreateFrame("Frame", nil, panel)
    column2:SetSize(1, 1)
    column2:SetPoint("TOPLEFT", panel, "TOP", 0, -10)
    local cols = {
        { anchor = title, offset = -12, x = 12 },
        { anchor = column2, offset = 0, x = 0 },
    }
    local function Place(frame, col, indent, gap)
        frame:SetPoint("TOPLEFT", col.anchor, "BOTTOMLEFT", indent or 0, col.offset - (gap or 0))
        frame:SetPoint("RIGHT", panel, col == cols[1] and "CENTER" or "RIGHT", -16, 0)
    end
    local function Next(col, frame, offset)
        col.anchor, col.offset = frame, offset
    end

    for _, def in ipairs(defs) do
        local col = cols[def.column == 2 and 2 or 1]
        if def.kind == "header" then
            local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
            fs:SetJustifyH("LEFT")
            Place(fs, col, 0, 6)
            Next(col, fs, -6)
            widgets[#widgets + 1] = { refresh = function() fs:SetText(TextOf(def.text)) end }

        elseif def.kind == "text" then
            local fs = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            fs:SetJustifyH("LEFT")
            fs:SetSpacing(2)
            Place(fs, col, 4, 0)
            Next(col, fs, -8)
            widgets[#widgets + 1] = { refresh = function() fs:SetText(TextOf(def.text)) end }

        elseif def.kind == "button" or def.kind == "choice" then
            local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
            b:SetSize(def.width or 190, 22)
            b:SetPoint("TOPLEFT", col.anchor, "BOTTOMLEFT", 4, col.offset - 2)
            Next(col, b, -8)
            buttons[#buttons + 1] = { b = b, def = def, col = col }
            if def.kind == "button" then
                b:SetScript("OnClick", function() def.onClick() Refresh() end)
                widgets[#widgets + 1] = { refresh = function()
                    b:SetText(TextOf(def.label))
                    b:SetEnabled(not (def.disabled and def.disabled()))
                end }
            else
                local function Label()
                    local v = ns.db.settings[def.key]
                    b:SetText(def.label .. ": " .. (def.format and def.format(v) or tostring(v)))
                end
                b:SetScript("OnClick", function()
                    local cur, nextValue = ns.db.settings[def.key], def.choices[1]
                    for i, v in ipairs(def.choices) do
                        if v == cur then nextValue = def.choices[i % #def.choices + 1] end
                    end
                    ns.db.settings[def.key] = nextValue
                    if def.onChange then def.onChange(nextValue) end
                    Refresh()
                end)
                widgets[#widgets + 1] = { refresh = Label }
            end

        else -- toggle
            local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
            cb:SetSize(26, 26)
            cb:SetPoint("TOPLEFT", col.anchor, "BOTTOMLEFT", (col.anchor == title) and -4 or 0, col.offset)
            local label = cb.Text or cb.text
            if not label then
                label = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                label:SetPoint("LEFT", cb, "RIGHT", 2, 0)
            end
            label:SetFontObject("GameFontHighlight")
            label:SetText(def.label)
            -- The label is part of the button (hover and click), so a tooltip shows there too.
            cb:SetHitRectInsets(0, -(label:GetStringWidth() + 6), 0, 0)
            if def.tooltip then
                cb:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(def.label, 1, 1, 1)
                    GameTooltip:AddLine(TextOf(def.tooltip), 1, 0.82, 0, true)
                    GameTooltip:Show()
                end)
                cb:SetScript("OnLeave", GameTooltip_Hide)
            end

            local function Value()
                if def.get then return def.get() and true or false end
                return ns.db.settings[def.key] and true or false
            end
            cb:SetScript("OnClick", function(self)
                local value = self:GetChecked() and true or false
                if def.set then def.set(value) else ns.db.settings[def.key] = value end
                if SOUNDKIT then
                    PlaySound(value and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
                end
                if def.onChange then def.onChange(value) end
                Refresh()
            end)
            widgets[#widgets + 1] = { refresh = function()
                cb:SetChecked(Value())
                local off = def.disabled and def.disabled()
                cb:SetEnabled(not off)
                label:SetFontObject(off and "GameFontDisable" or "GameFontHighlight")
            end }

            Next(col, cb, -6)
            if def.description then
                local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
                desc:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 30, 2)
                desc:SetPoint("RIGHT", panel, col == cols[1] and "CENTER" or "RIGHT", -16, 0)
                desc:SetJustifyH("LEFT")
                desc:SetText(def.description)
                -- next element lines up with the checkbox column, not the indented text
                local anchor = CreateFrame("Frame", nil, panel)
                anchor:SetSize(1, 1)
                anchor:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -30, 0)
                Next(col, anchor, -10)
            end
        end
    end

    -- Scroll height = from the top down to the lowest element of either column.
    local function UpdateHeight()
        local top = panel:GetTop()
        local b1, b2 = cols[1].anchor:GetBottom(), cols[2].anchor:GetBottom()
        if not (top and b1 and b2) then return end
        local h = top - math.min(b1, b2) + 16
        panel:SetHeight(h)
        local bar = scroll.ScrollBar
        if bar then bar:SetShown(h > scroll:GetHeight() + 1) end
    end
    local function RefreshAll()
        Refresh()
        C_Timer.After(0, UpdateHeight) -- after text wrapping has been laid out
    end
    scroll:SetScript("OnSizeChanged", function(_, width)
        panel:SetWidth(width)
        C_Timer.After(0, UpdateHeight)
    end)

    tab:SetScript("OnShow", RefreshAll)
    ns:RegisterCallback("SETTINGS_REFRESH", function() if tab:IsVisible() then RefreshAll() end end)
    RefreshAll()
end

ns.MainFrame:RegisterTab("settings", "Settings", 30, Build)
