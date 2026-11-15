-- Modules\Settings.lua: the Settings tab, laid out like the game's own Options window.
--
--   Left:  a category list in groups (like Gameplay > Controls, Interface, ...).
--   Right: the chosen category's page: a big title with a divider and a Defaults
--          button, then rows with the setting's name on the left and its control
--          (checkbox, dropdown with arrows, button) in a column. Hovering a row
--          highlights it and shows its description in a tooltip.
-- Blizzard art is used by atlas name when the client has it, with plain fallbacks.
--
-- Other modules add categories and entries (at load time, before the window opens):
--   ns.Settings:RegisterCategory({ key = "sharing", name = "Sharing", group = "Guild",
--                                  order = 10, title = "..." | fn })
--   ns.Settings:RegisterToggle({ category = "alerts", key = "tooltipLines", label = "...",
--                                description = "...", order = 10, indent = 1, onChange = fn(value) })
--     Values live in ns.db.settings[key] (account-wide), unless the def gives its own
--     get() / set(value). disabled() greys it out. tooltip = "..." | fn adds a line.
--   ns.Settings:RegisterHeader({ category, text = "..." | fn, order })  -- a section inside a page
--   ns.Settings:RegisterButton({ category, label, buttonText, onClick = fn, order })
--   ns.Settings:RegisterChoice({ category, key, label, choices = { 7, 14 }, format = fn(v), order })
-- Defaults resets the page's own ns.db.settings keys to Core's defaults.
-- Texts and states refresh when the tab is shown and on ns:Fire("SETTINGS_REFRESH").
local _, ns = ...

local Settings = {}
ns.Settings = Settings

local LIST_WIDTH     = 190
local ROW_HEIGHT     = 32
local HEADER_HEIGHT  = 44
local LABEL_X        = 34
local INDENT         = 18
local CONTROL_OFFSET = -10 -- controls start this far from the middle of the page
local PAD_RIGHT      = 30  -- room for the scroll bar

local categories = {} -- { key, name, group, order, title }
local defs = {}
local widgets = {}    -- { refresh = fn }
local selected        -- category key

function Settings:RegisterCategory(cat)
    categories[#categories + 1] = cat
end

local function Add(kind, def)
    def.kind = kind
    def.category = def.category or "general"
    defs[#defs + 1] = def
end

function Settings:RegisterToggle(def)
    assert(def.label and (def.key or def.get), "Unc's Tavern: toggle needs key/get and label")
    Add("toggle", def)
end
function Settings:RegisterHeader(def) Add("header", def) end
function Settings:RegisterButton(def) Add("button", def) end
function Settings:RegisterChoice(def) Add("choice", def) end

function Settings:Get(key)
    return ns.db and ns.db.settings[key]
end

Settings:RegisterCategory({ key = "general", name = "General", group = ns.title, order = 10 })
Settings:RegisterCategory({ key = "alerts",  name = "Alerts",  group = ns.title, order = 20 })
Settings:RegisterCategory({ key = "minimap", name = "Minimap", group = ns.title, order = 30 })

local function TextOf(v)
    if type(v) == "function" then return v() or "" end
    return v or ""
end

local function Refresh()
    for _, w in ipairs(widgets) do w.refresh() end
end

---------------------------------------------------------------------------
-- Art helpers (Blizzard atlases when present, simple colors otherwise)
---------------------------------------------------------------------------
local function HasAtlas(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil
end

local function HasTemplate(name)
    return C_XMLUtil and C_XMLUtil.GetTemplateInfo and C_XMLUtil.GetTemplateInfo(name) ~= nil
end

-- texture: atlas if the client has it, else a flat color { r, g, b, a }
local function Art(tex, atlas, color)
    if atlas and HasAtlas(atlas) then
        tex:SetAtlas(atlas)
    else
        tex:SetColorTexture(unpack(color))
    end
end

local function Divider(parent, y, left)
    local t = parent:CreateTexture(nil, "ARTWORK")
    Art(t, "Options_HorizontalDivider", { 1, 0.82, 0, 0.25 })
    t:SetHeight(HasAtlas("Options_HorizontalDivider") and 2 or 1)
    t:SetPoint("TOPLEFT", parent, "TOPLEFT", left or 12, y)
    t:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_RIGHT, y)
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function ShowTip(row, def)
    if not def.description and not def.tooltip then return end
    GameTooltip:SetOwner(row, "ANCHOR_NONE")
    GameTooltip:SetPoint("LEFT", row, "RIGHT", -PAD_RIGHT + 8, 0)
    GameTooltip:SetText(TextOf(def.label), 1, 1, 1)
    if def.description then GameTooltip:AddLine(TextOf(def.description), nil, nil, nil, true) end
    if def.tooltip then GameTooltip:AddLine(TextOf(def.tooltip), nil, nil, nil, true) end
    GameTooltip:Show()
end

-- Highlight + tooltip on the row, also while the pointer is on the row's controls.
local function Hoverable(row, def, ...)
    local hl = row:CreateTexture(nil, "BACKGROUND")
    hl:SetPoint("TOPLEFT", row, "TOPLEFT", 16, 0)
    hl:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -PAD_RIGHT + 4, 0)
    Art(hl, "Options_List_Hover", { 1, 1, 1, 0.06 })
    hl:Hide()
    local function Enter() hl:Show() ShowTip(row, def) end
    local function Leave() hl:Hide() GameTooltip_Hide() end
    row:EnableMouse(true)
    row:SetScript("OnEnter", Enter)
    row:SetScript("OnLeave", Leave)
    for i = 1, select("#", ...) do
        local child = select(i, ...)
        if child then
            child:HookScript("OnEnter", Enter)
            child:HookScript("OnLeave", Leave)
        end
    end
end

local function RowLabel(row, def)
    local fs = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    fs:SetPoint("LEFT", row, "LEFT", LABEL_X + (def.indent or 0) * INDENT, 0)
    fs:SetPoint("RIGHT", row, "CENTER", CONTROL_OFFSET - 10, 0)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    fs:SetText(TextOf(def.label))
    return fs
end

-- The Options window's checkbox (dark square, gold tick) when available.
local function Checkbox(parent)
    if not HasAtlas("checkbox-minimal") then
        local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cb:SetSize(30, 30)
        return cb
    end
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(30, 30)
    local function Tex(atlas, layer, blend)
        local t = cb:CreateTexture(nil, layer or "ARTWORK")
        t:SetAtlas(atlas)
        t:SetAllPoints()
        if blend then t:SetBlendMode(blend) end
        return t
    end
    cb:SetNormalTexture(Tex("checkbox-minimal", "BACKGROUND"))
    cb:SetPushedTexture(Tex("checkbox-minimal", "BACKGROUND"))
    local hl = Tex("checkbox-minimal", "HIGHLIGHT", "ADD")
    hl:SetAlpha(0.25)
    cb:SetHighlightTexture(hl)
    cb:SetCheckedTexture(Tex("checkmark-minimal"))
    cb:SetDisabledCheckedTexture(Tex(HasAtlas("checkmark-minimal-disabled") and "checkmark-minimal-disabled" or "checkmark-minimal"))
    return cb
end

local function ArrowButton(parent, dir)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(26, 26)
    local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. dir .. "Page-"
    b:SetNormalTexture(base .. "Up")
    b:SetPushedTexture(base .. "Down")
    b:SetDisabledTexture(base .. "Disabled")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    return b
end

-- Choice: < [dropdown] > like the Options window. Uses the game's dropdown template
-- when the client has it; otherwise the arrows step through the values.
local function ChoiceControl(row, def)
    local function Index()
        local cur = ns.db.settings[def.key]
        for i, v in ipairs(def.choices) do if v == cur then return i end end
        return 1
    end
    local function TextFor(v) return def.format and def.format(v) or tostring(v) end
    local function Set(i)
        i = math.max(1, math.min(#def.choices, i))
        ns.db.settings[def.key] = def.choices[i]
        if def.onChange then def.onChange(def.choices[i]) end
        if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
        Refresh()
    end

    local prev = ArrowButton(row, "Prev")
    prev:SetPoint("LEFT", row, "CENTER", CONTROL_OFFSET, 0)

    local middle, value
    if HasTemplate("WowStyle1DropdownTemplate") then
        local ok, dd = pcall(CreateFrame, "DropdownButton", nil, row, "WowStyle1DropdownTemplate")
        if ok and dd and dd.SetupMenu then
            dd:SetWidth(170)
            dd:SetupMenu(function(_, root)
                for i, v in ipairs(def.choices) do
                    root:CreateRadio(TextFor(v), function() return Index() == i end, function() Set(i) end)
                end
            end)
            middle = dd
        end
    end
    if not middle then
        middle = CreateFrame("Frame", nil, row)
        middle:SetSize(170, 24)
        value = middle:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        value:SetAllPoints()
        value:SetJustifyH("CENTER")
    end
    middle:SetPoint("LEFT", prev, "RIGHT", 2, 0)
    local nextButton = ArrowButton(row, "Next")
    nextButton:SetPoint("LEFT", middle, "RIGHT", 2, 0)

    prev:SetScript("OnClick", function() Set(Index() - 1) end)
    nextButton:SetScript("OnClick", function() Set(Index() + 1) end)

    local function refresh()
        local i = Index()
        if value then
            value:SetText(TextFor(def.choices[i]))
        elseif middle.GenerateMenu then
            middle:GenerateMenu() -- updates the shown value
        end
        prev:SetEnabled(i > 1)
        nextButton:SetEnabled(i < #def.choices)
    end
    return refresh, prev, middle, nextButton
end

---------------------------------------------------------------------------
-- One category page
---------------------------------------------------------------------------
local function BuildPage(scroll, cat, onDefaults)
    local page = CreateFrame("Frame", nil, scroll)
    page:SetSize(math.max(scroll:GetWidth(), 400), 400)
    page:Hide()

    local title = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", page, "TOPLEFT", 20, -14)
    title:SetPoint("RIGHT", page, "RIGHT", -150, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    widgets[#widgets + 1] = { refresh = function() title:SetText(TextOf(cat.title or cat.name)) end }

    local defaults = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    defaults:SetSize(110, 22)
    defaults:SetPoint("TOPRIGHT", page, "TOPRIGHT", -PAD_RIGHT - 4, -14)
    defaults:SetText(DEFAULTS or "Defaults")
    defaults:SetScript("OnClick", onDefaults)
    Divider(page, -48, 16)

    local y = -56
    local function Row(height)
        local row = CreateFrame("Frame", nil, page)
        row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, y)
        row:SetHeight(height)
        y = y - height
        return row
    end

    local hasDefaults = false
    for _, def in ipairs(defs) do
        if def.category == cat.key then
            if def.key and ns.DEFAULT_SETTINGS and ns.DEFAULT_SETTINGS[def.key] ~= nil then hasDefaults = true end

            if def.kind == "header" then
                local row = Row(HEADER_HEIGHT)
                local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
                fs:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 24, 8)
                fs:SetPoint("RIGHT", row, "RIGHT", -PAD_RIGHT, 0)
                fs:SetJustifyH("LEFT")
                widgets[#widgets + 1] = { refresh = function() fs:SetText(TextOf(def.text)) end }

            elseif def.kind == "toggle" then
                local row = Row(ROW_HEIGHT)
                local label = RowLabel(row, def)
                local cb = Checkbox(row)
                cb:SetPoint("LEFT", row, "CENTER", CONTROL_OFFSET, 0)
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
                Hoverable(row, def, cb)
                widgets[#widgets + 1] = { refresh = function()
                    cb:SetChecked(Value())
                    local off = def.disabled and def.disabled()
                    cb:SetEnabled(not off)
                    label:SetFontObject(off and "GameFontDisable" or "GameFontNormal")
                end }

            elseif def.kind == "choice" then
                local row = Row(ROW_HEIGHT)
                RowLabel(row, def)
                local refresh, a, b, c = ChoiceControl(row, def)
                Hoverable(row, def, a, b, c)
                widgets[#widgets + 1] = { refresh = refresh }

            elseif def.kind == "button" then
                local row = Row(ROW_HEIGHT)
                local label = RowLabel(row, def)
                local b = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                b:SetHeight(22)
                b:SetPoint("LEFT", row, "CENTER", CONTROL_OFFSET + 2, 0)
                b:SetScript("OnClick", function() def.onClick() Refresh() end)
                Hoverable(row, def, b)
                widgets[#widgets + 1] = { refresh = function()
                    b:SetText(TextOf(def.buttonText or def.label))
                    b:SetWidth(math.max(120, b:GetTextWidth() + 32))
                    local off = def.disabled and def.disabled()
                    b:SetEnabled(not off)
                    label:SetFontObject(off and "GameFontDisable" or "GameFontNormal")
                end }
            end
        end
    end
    defaults:SetShown(hasDefaults)
    page.contentHeight = -y + 16
    page:SetHeight(page.contentHeight)
    return page
end

-- Reset this page's settings (the ones stored in ns.db.settings) to Core's defaults.
local function ResetCategory(cat)
    ns.Dialog:Show({
        text = ("Reset the %s settings to their defaults?"):format(TextOf(cat.name)),
        accept = "Reset",
        onAccept = function()
            for _, def in ipairs(defs) do
                local d = def.key and ns.DEFAULT_SETTINGS and ns.DEFAULT_SETTINGS[def.key]
                if def.category == cat.key and d ~= nil and ns.db.settings[def.key] ~= d then
                    ns.db.settings[def.key] = d
                    if def.onChange then def.onChange(d) end
                end
            end
            Refresh()
        end,
    })
end

---------------------------------------------------------------------------
-- Build: category list (left) + page (right)
---------------------------------------------------------------------------
local function Build(tab)
    table.sort(defs, function(a, b) return (a.order or 100) < (b.order or 100) end)
    table.sort(categories, function(a, b) return (a.order or 100) < (b.order or 100) end)

    -- Left: the category list
    local list = CreateFrame("Frame", nil, tab)
    list:SetPoint("TOPLEFT", tab, "TOPLEFT", 2, -2)
    list:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 2, 2)
    list:SetWidth(LIST_WIDTH)
    local listBg = list:CreateTexture(nil, "BACKGROUND")
    listBg:SetAllPoints()
    listBg:SetColorTexture(0, 0, 0, 0.3)
    local edge = list:CreateTexture(nil, "ARTWORK")
    edge:SetPoint("TOPLEFT", list, "TOPRIGHT", 0, 0)
    edge:SetPoint("BOTTOMLEFT", list, "BOTTOMRIGHT", 0, 0)
    edge:SetWidth(2)
    edge:SetColorTexture(0.45, 0.35, 0.2, 0.6)

    -- Right: one scroll frame; its child is the selected page
    local scroll = CreateFrame("ScrollFrame", nil, tab, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", list, "TOPRIGHT", 8, -2)
    scroll:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -28, 8)

    local pages, buttons = {}, {}

    local function UpdateScrollBar()
        local page = pages[selected]
        local bar = scroll.ScrollBar
        if bar and page then bar:SetShown(page.contentHeight > scroll:GetHeight() + 1) end
    end

    local function Select(key)
        selected = key
        for k, page in pairs(pages) do page:SetShown(k == key) end
        scroll:SetScrollChild(pages[key])
        scroll:SetVerticalScroll(0)
        for k, b in pairs(buttons) do
            b.active:SetShown(k == key)
            b.text:SetFontObject(k == key and "GameFontHighlight" or "GameFontNormal")
        end
        UpdateScrollBar()
    end

    local y, group = -6, nil
    for _, cat in ipairs(categories) do
        pages[cat.key] = BuildPage(scroll, cat, function() ResetCategory(cat) end)

        if cat.group ~= group then
            group = cat.group
            if y < -6 then y = y - 12 end
            local header = CreateFrame("Frame", nil, list)
            header:SetPoint("TOPLEFT", list, "TOPLEFT", 4, y)
            header:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, y)
            header:SetHeight(30)
            local bg = header:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            Art(bg, "Options_CategoryHeader_1", { 0.12, 0.09, 0.05, 0.95 })
            if not HasAtlas("Options_CategoryHeader_1") then
                local line = header:CreateTexture(nil, "ARTWORK")
                line:SetPoint("BOTTOMLEFT") line:SetPoint("BOTTOMRIGHT")
                line:SetHeight(1)
                line:SetColorTexture(1, 0.82, 0, 0.35)
            end
            local text = header:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
            text:SetPoint("LEFT", header, "LEFT", 10, 0)
            text:SetPoint("RIGHT", header, "RIGHT", -6, 0)
            text:SetJustifyH("LEFT")
            text:SetWordWrap(false)
            text:SetText(group)
            y = y - 32
        end

        local b = CreateFrame("Button", nil, list)
        b:SetPoint("TOPLEFT", list, "TOPLEFT", 8, y)
        b:SetPoint("TOPRIGHT", list, "TOPRIGHT", -6, y)
        b:SetHeight(24)
        b.active = b:CreateTexture(nil, "BACKGROUND")
        b.active:SetAllPoints()
        Art(b.active, "Options_List_Active", { 1, 0.82, 0, 0.18 })
        b.active:Hide()
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        Art(hl, "Options_List_Hover", { 1, 1, 1, 0.08 })
        b.text = b:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        b.text:SetPoint("LEFT", b, "LEFT", 22, 0)
        b.text:SetPoint("RIGHT", b, "RIGHT", -4, 0)
        b.text:SetJustifyH("LEFT")
        b.text:SetWordWrap(false)
        b.text:SetText(TextOf(cat.name))
        b:SetScript("OnClick", function()
            if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
            Select(cat.key)
        end)
        buttons[cat.key] = b
        y = y - 26
    end

    scroll:SetScript("OnSizeChanged", function(_, width)
        for _, page in pairs(pages) do page:SetWidth(width) end
        UpdateScrollBar()
    end)

    tab:SetScript("OnShow", function() Refresh() UpdateScrollBar() end)
    ns:RegisterCallback("SETTINGS_REFRESH", function() if tab:IsVisible() then Refresh() end end)
    Select(selected or (categories[1] and categories[1].key))
    Refresh()
end

ns.MainFrame:RegisterTab("settings", "Settings", 30, Build)
