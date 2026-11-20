-- Modules\History.lua: your own wishlist history, and the "Helped" count on the roster.
--
-- Worked out from the wishlist requests themselves. Every request carries "received
-- from" per sender, booked only by the REQUESTER's own client when they take the items
-- from the mailbox (AutoComplete), and only ever sent by the requester (no relaying,
-- see WishlistSync.lua). So "received from" is the receiver's confirmation:
--   Received = senders on MY requests.
--   Sent     = OTHER players' requests whose requester confirmed me as a sender.
-- Marking your own request as received by hand ("Got") doesn't add a sender, so it
-- never counts. Nobody can count their own help: a helper's claim never counts, and
-- a requester listing themselves is dropped.
--
-- Entries are copied into charDB.history.byGuild[guildKey] (max MAX_ENTRIES), so they
-- outlive the requests.
--
-- HELPED: every client keeps a ledger of confirmations it has seen, per guild and
-- account-wide: ns.db.helpedLedger[guildKey]["receiver|reqId|helper"] = { r, h, n, day, t }.
-- Helped(helper) = number of confirmed requests, at most DAILY_CAP per receiver-helper
-- pair per day. Nothing about Helped is sent separately: it travels inside the
-- receiver's own requests. Players who install later see confirmations from the last
-- requestExpiryDays days plus everything after, so counts can differ a little between
-- players.
--
-- Tab: Items received | Items sent side by side ("My history"). Other modules add views
-- with History:RegisterView (GuildLog.lua: Guild log, Officer log).
local _, ns = ...
local W = ns.Wishlist

local History = {}
ns.History = History

local SCAN_DELAY  = 1    -- coalesce bursts of wishlist changes into one scan
local DAILY_CAP   = 3    -- confirmations counted per receiver-helper pair per day
local MAX_LEDGER  = 5000 -- confirmations kept per guild
local MAX_ENTRIES = 500  -- history entries kept per guild per character

local scanPending = false
local helpedCache -- [helper] = count, rebuilt when the ledger changes

local function Short(name) return name and Ambiguate(name, "guild") or nil end

local function IsMe(name)
    local me = ns:PlayerName()
    return name == me or name == Short(me)
end

-- This character's entries for the current guild.
local function Entries()
    local key = ns:GuildKey()
    if not key then return nil end
    local h = ns.charDB.history
    h.byGuild = type(h.byGuild) == "table" and h.byGuild or {}
    if type(h.byGuild[key]) ~= "table" then h.byGuild[key] = {} end
    -- Entries from before v0.4.0 weren't kept per guild: they belong to the current one.
    if type(h.entries) == "table" then
        for k, e in pairs(h.entries) do h.byGuild[key][k] = h.byGuild[key][k] or e end
    end
    h.entries, h.sent, h.received, h.deliveredTo = nil, nil, nil, nil
    return h.byGuild[key]
end

local function Ledger()
    local key = ns:GuildKey()
    if not key then return nil end
    if type(ns.db.helpedLedger[key]) ~= "table" then ns.db.helpedLedger[key] = {} end
    return ns.db.helpedLedger[key]
end

-- What a request asks for, saved with the entry (so it survives the request's purge).
local function Describe(req)
    if req.rule then return { rule = W:RuleText(req.rule), armor = req.rule.armor } end
    return { itemID = req.itemID }
end

local function Trim(t, max)
    local n, oldest, oldestKey = 0, nil, nil
    for _ in pairs(t) do n = n + 1 end
    while n > max do
        oldest, oldestKey = nil, nil
        for k, e in pairs(t) do
            if not oldest or (e.t or 0) < oldest then oldest, oldestKey = e.t or 0, k end
        end
        t[oldestKey] = nil
        n = n - 1
    end
end

---------------------------------------------------------------------------
-- Scan the requests -> history entries + Helped ledger
---------------------------------------------------------------------------
local function Scan()
    scanPending = false
    local entries, ledger = Entries(), Ledger()
    if not entries or not ledger then return end
    local now = W.Now()
    local histChanged, ledgerChanged = false, false
    for _, req in ipairs(W:All()) do
        if req.receivedFrom then
            local mine = W:IsMine(req)
            for who, n in pairs(req.receivedFrom) do
                -- Helped ledger: the requester confirmed `who` delivered.
                if who ~= req.requester then
                    local lk = req.requester .. "|" .. req.id .. "|" .. who
                    if not ledger[lk] then
                        local t = math.min(req.updated or now, now)
                        ledger[lk] = { r = req.requester, h = who, n = n, day = math.floor(t / 86400), t = t }
                        ledgerChanged = true
                    end
                end
                -- My own history
                local key, kind, other
                if mine then
                    key, kind, other = "R:" .. req.id .. ":" .. who, "received", who
                elseif IsMe(who) then
                    key, kind, other = "S:" .. req.id, "sent", req.requester
                end
                if key then
                    local e = entries[key]
                    if not e then
                        e = Describe(req)
                        e.kind, e.who, e.qty = kind, other, 0
                        entries[key] = e
                    end
                    if n > e.qty then
                        e.qty, e.t = n, req.updated or time()
                        histChanged = true
                    end
                end
            end
        end
    end
    if histChanged then
        Trim(entries, MAX_ENTRIES)
        ns:Fire("HISTORY_CHANGED")
    end
    if ledgerChanged then
        Trim(ledger, MAX_LEDGER)
        helpedCache = nil
        ns:Fire("HELPED_CHANGED")
    end
end

local function ScheduleScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_DELAY, Scan)
end

ns:RegisterCallback("WISHLIST_CHANGED", ScheduleScan)
ns:RegisterCallback("GUILD_CHANGED", function() helpedCache = nil ScheduleScan() end)
ns:RegisterEvent("PLAYER_LOGIN", function() C_Timer.After(5, ScheduleScan) end)

-- For /tavern securitytest: scan right away instead of after SCAN_DELAY.
function History:ScanNow() Scan() helpedCache = nil end

function History:Entries(kind)
    local out = {}
    for _, e in pairs(Entries() or {}) do
        if e.kind == kind then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return out
end

-- Helped count for a guild member (nil = none known).
function History:HelpedCount(fullName)
    if not helpedCache then
        helpedCache = {}
        local perPairDay = {}
        for _, e in pairs(Ledger() or {}) do
            local pd = e.r .. "|" .. e.h .. "|" .. e.day
            perPairDay[pd] = (perPairDay[pd] or 0) + 1
            if perPairDay[pd] <= DAILY_CAP then helpedCache[e.h] = (helpedCache[e.h] or 0) + 1 end
        end
    end
    local name = Short(fullName)
    if IsMe(name) then return helpedCache[ns:PlayerName()] or helpedCache[name] or 0 end
    return helpedCache[name]
end

-- Saved data: drop anything malformed.
ns:RegisterCallback("VALIDATE_DB", function()
    for key, ledger in pairs(ns.db.helpedLedger) do
        if type(ledger) ~= "table" then
            ns.db.helpedLedger[key] = nil
        else
            for k, e in pairs(ledger) do
                if type(e) ~= "table" or not ns:ValidName(e.r) or not ns:ValidName(e.h) or e.r == e.h
                    or not ns:Int(e.n, 1) or not ns:Int(e.day, 0) then
                    ledger[k] = nil
                end
            end
        end
    end
    local h = ns.charDB.history
    for _, list in pairs(type(h.byGuild) == "table" and h.byGuild or {}) do
        if type(list) == "table" then
            for k, e in pairs(list) do
                if type(e) ~= "table" or not ns:ValidName(e.who) or (e.kind ~= "sent" and e.kind ~= "received") then
                    list[k] = nil
                elseif e.rule then
                    e.rule = ns:CleanText(e.rule, 80)
                end
            end
        end
    end
end)

---------------------------------------------------------------------------
-- Tab
---------------------------------------------------------------------------
local ROW_HEIGHT = 20
local ARMOR_ICONS = {
    "Interface\\Icons\\INV_Chest_Cloth_17", "Interface\\Icons\\INV_Chest_Leather_09",
    "Interface\\Icons\\INV_Chest_Chain_05", "Interface\\Icons\\INV_Chest_Plate06",
}

local panel, lists = nil, {}

local function EntryIcon(e)
    if e.rule then return ARMOR_ICONS[e.armor] or "Interface\\Icons\\INV_Misc_QuestionMark" end
    return select(5, C_Item.GetItemInfoInstant(e.itemID)) or C_Item.GetItemIconByID(e.itemID)
end

local function EntryName(e)
    if e.rule then return e.rule, NORMAL_FONT_COLOR end
    local name, _, quality = C_Item.GetItemInfo(e.itemID)
    local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    return name or ("item " .. tostring(e.itemID)), (c and (c.color or c)) or HIGHLIGHT_FONT_COLOR
end

-- One list: columns { label, width, flex, fit, get(entry) -> text, r, g, b }
-- fit = true: the column is as wide as its longest text (header included), at least
-- `width`, at most FIT_MAX. Flex columns (the item) take whatever is left.
-- opts (optional): { onClick = fn(entry, mouseButton, row), onEnter = fn(entry, row) }
-- makes rows clickable / hoverable (with a highlight).
local FIT_MAX = 180
local function MakeList(parent, title, cols, opts)
    local l = { cols = cols, headers = {} }
    l.frame = CreateFrame("Frame", nil, parent)
    l.title = l.frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    l.title:SetPoint("TOPLEFT", 4, 0)
    l.title:SetText(title)

    l.scrollBox = CreateFrame("Frame", nil, l.frame, "WowScrollBoxList")
    l.scrollBox:SetPoint("TOPLEFT", l.frame, "TOPLEFT", 0, -38)
    l.scrollBox:SetPoint("BOTTOMRIGHT", l.frame, "BOTTOMRIGHT", -18, 0)
    local bar = CreateFrame("EventFrame", nil, l.frame, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", l.scrollBox, "TOPRIGHT", 4, 0)
    bar:SetPoint("BOTTOMLEFT", l.scrollBox, "BOTTOMRIGHT", 4, 0)
    l.empty = l.frame:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    l.empty:SetPoint("CENTER", l.scrollBox)

    for i, col in ipairs(cols) do
        local fs = l.frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        fs:SetJustifyH("LEFT")
        fs:SetText(col.label)
        l.headers[i] = fs
    end
    l.probe = l.frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    l.probe:SetAlpha(0) -- invisible but still measured (some clients give 0 for hidden text)
    l.probe:SetPoint("TOPLEFT")
    for _, col in ipairs(cols) do col.minWidth = col.width end

    local divider = l.frame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(1, 0.82, 0, 0.25)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT", l.scrollBox, "TOPLEFT", 0, 2)
    divider:SetPoint("BOTTOMRIGHT", l.scrollBox, "TOPRIGHT", 0, 2)

    l.version = 0
    local function LayoutRow(row)
        for i, col in ipairs(cols) do
            local pad = (i == 1 and col.icon) and ROW_HEIGHT or 0
            row.cells[i]:ClearAllPoints()
            row.cells[i]:SetPoint("LEFT", row, "LEFT", col.x + 4 + pad, 0)
            row.cells[i]:SetWidth(col.w - 8 - pad)
        end
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", cols[1].x + 4, 0)
        row.version = l.version
    end

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Frame", function(row, item)
        if not row.cells then
            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()
            row.bg:SetColorTexture(1, 1, 1, 0.04)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(ROW_HEIGHT - 4, ROW_HEIGHT - 4)
            row.cells = {}
            for i in ipairs(cols) do
                local fs = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
                fs:SetJustifyH("LEFT")
                fs:SetWordWrap(false)
                row.cells[i] = fs
            end
            if opts then
                local hl = row:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 0.82, 0, 0.12)
                row:EnableMouse(true)
                row:SetScript("OnMouseUp", function(self, button)
                    if opts.onClick and self.entry then opts.onClick(self.entry, button, self) end
                end)
                row:SetScript("OnEnter", function(self)
                    if opts.onEnter and self.entry then opts.onEnter(self.entry, self) end
                end)
                row:SetScript("OnLeave", GameTooltip_Hide)
            end
        end
        row.entry = item.e
        if row.version ~= l.version then LayoutRow(row) end
        row.bg:SetShown(item.index % 2 == 0)
        row.icon:SetShown(cols[1].icon ~= nil)
        if cols[1].icon then row.icon:SetTexture(cols[1].icon(item.e)) end
        for i, col in ipairs(cols) do
            local text, c = col.get(item.e)
            row.cells[i]:SetText(text or "")
            c = c or HIGHLIGHT_FONT_COLOR
            row.cells[i]:SetTextColor(c.r, c.g, c.b)
        end
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(l.scrollBox, bar, view)

    local function LayoutHeaders()
        for i, col in ipairs(cols) do
            l.headers[i]:ClearAllPoints()
            l.headers[i]:SetPoint("BOTTOMLEFT", l.scrollBox, "TOPLEFT", col.x + 4, 6)
            l.headers[i]:SetWidth(col.w - 8)
        end
    end
    local function Relayout()
        l.version = l.version + 1
        LayoutHeaders()
        l.scrollBox:ForEachFrame(LayoutRow)
    end
    ns.Columns.Watch(l.scrollBox, cols, Relayout)
    LayoutHeaders()

    -- The probe has no width set, so this is the text's full width, never cut off.
    local function TextWidth(fs, text)
        fs:SetText(text or "")
        return math.ceil(fs:GetStringWidth() or 0) + 10 -- 8 cell padding + a little air
    end
    -- Size the fit columns to this content; true if any width changed.
    local function FitColumns(entries)
        local changed = false
        for i, col in ipairs(cols) do
            if col.fit then
                local w = math.max(col.minWidth, TextWidth(l.probe, col.label))
                for _, e in ipairs(entries) do
                    w = math.max(w, TextWidth(l.probe, (col.get(e))))
                end
                w = math.min(w, FIT_MAX)
                if w ~= col.width then col.width, changed = w, true end
            end
        end
        return changed
    end

    function l:SetEntries(entries, emptyText)
        local wrapped = {}
        for i, e in ipairs(entries) do wrapped[i] = { e = e, index = i } end
        if FitColumns(entries) then
            ns.Columns.Layout(cols, self.scrollBox:GetWidth())
            Relayout()
        end
        self.scrollBox:SetDataProvider(CreateDataProvider(wrapped), ScrollBoxConstants.RetainScrollPosition)
        self.empty:SetText(emptyText)
        self.empty:SetShown(#entries == 0)
    end
    return l
end

local function When(t) return t and date("%b %d %H:%M", t) or "" end
local GREY = { r = 0.6, g = 0.6, b = 0.6 }

-- For other modules' views (GuildLog.lua): the same lists, icons and names.
History.MakeList, History.EntryIcon, History.EntryName = MakeList, EntryIcon, EntryName
History.When, History.GREY, History.Describe = When, GREY, Describe

---------------------------------------------------------------------------
-- Views: "My history" (here) plus views other modules add with
--   History:RegisterView({ key, label, order, intro = "..." | fn, shown = fn,
--                          build = fn(frame), refresh = fn() })
---------------------------------------------------------------------------
local views = {
    { key = "mine", label = "My history", order = 10, intro = "Your own wishlist deliveries. Only you see this." },
}
local current = "mine"
local viewButtons, introText = {}, nil

function History:RegisterView(v)
    views[#views + 1] = v
end

local function View(key)
    for _, v in ipairs(views) do if v.key == key then return v end end
end

local function Visible(v) return not v.shown or v.shown() end

local function Refresh()
    if not panel then return end
    if not Visible(View(current) or {}) then current = "mine" end
    local x = -4
    for i = #views, 1, -1 do
        local v, b = views[i], viewButtons[views[i].key]
        if b then
            b:SetShown(Visible(v))
            if Visible(v) then
                b:ClearAllPoints()
                b:SetPoint("TOPRIGHT", panel, "TOPRIGHT", x, -4)
                x = x - b:GetWidth() - 4
                if v.key == current then b:LockHighlight() else b:UnlockHighlight() end
            end
        end
    end
    local v = View(current)
    introText:SetText(type(v.intro) == "function" and v.intro() or v.intro or "")
    local mine = current == "mine"
    lists.received.frame:SetShown(mine)
    lists.sent.frame:SetShown(mine)
    for _, o in ipairs(views) do
        if o.frame then o.frame:SetShown(o.key == current) end
    end
    if mine then
        lists.received:SetEntries(History:Entries("received"), "Nothing received yet.")
        lists.sent:SetEntries(History:Entries("sent"), "Nothing sent yet.")
    elseif v.refresh then
        v.refresh()
    end
end
History.Refresh = function() if panel and panel:IsVisible() then Refresh() end end

local function Build(p)
    panel = p
    introText = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    introText:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
    introText:SetPoint("RIGHT", panel, "RIGHT", -340, 0)
    introText:SetJustifyH("LEFT")
    introText:SetWordWrap(false)

    table.sort(views, function(a, b) return (a.order or 100) < (b.order or 100) end)
    for _, v in ipairs(views) do
        local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
        b:SetHeight(22)
        b:SetText(v.label)
        b:SetWidth(math.max(90, b:GetTextWidth() + 24))
        b:SetScript("OnClick", function() current = v.key Refresh() end)
        viewButtons[v.key] = b
        if v.build then
            v.frame = CreateFrame("Frame", nil, panel)
            v.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, -34)
            v.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
            v.frame:Hide()
            v.build(v.frame)
        end
    end

    local qtyText = function(e) return "x" .. tostring(e.qty or 0) end
    local nameText = function(e) return EntryName(e) end

    lists.received = MakeList(panel, "Items received", {
        { label = "Item", width = 100, flex = 1, icon = EntryIcon, get = nameText },
        { label = "Qty", width = 40, get = qtyText },
        { label = "From", width = 60, fit = true, get = function(e) return e.who or "?" end },
        { label = "When", width = 60, fit = true, get = function(e) return When(e.t), GREY end },
    })
    lists.sent = MakeList(panel, "Items sent", {
        { label = "Item", width = 100, flex = 1, icon = EntryIcon, get = nameText },
        { label = "Qty", width = 40, get = qtyText },
        { label = "To", width = 60, fit = true, get = function(e) return e.who or "?" end },
        { label = "When", width = 60, fit = true, get = function(e) return When(e.t), GREY end },
    })
    local top = -34
    lists.received.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, top)
    lists.received.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -6, 4)
    lists.sent.frame:SetPoint("TOPLEFT", panel, "TOP", 6, top)
    lists.sent.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)

    panel:SetScript("OnShow", Refresh)
    ns:RegisterCallback("HISTORY_CHANGED", function() if panel:IsVisible() then Refresh() end end)
    Refresh()
end

ns.MainFrame:RegisterTab("history", "History", 25, Build)
