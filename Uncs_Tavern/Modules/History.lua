-- Modules\History.lua: your own wishlist history, and the "Helped" count on the roster.
--
-- Worked out from the wishlist requests themselves: every request carries "received
-- from" per sender, filled in only when the requester takes the items from the mailbox
-- (AutoComplete). So:
--   Received = senders on MY requests.
--   Sent     = OTHER players' requests that list me as a sender.
-- Marking your own request as received by hand ("Got") doesn't add a sender, so it
-- never counts as received from anyone, and never counts toward anyone's Helped.
-- Entries are copied into charDB.history.entries, so they outlive the requests
-- (removed/finished requests are forgotten after 30 days). This also picks up
-- deliveries made before the History tab existed.
--
-- Helped = how many guildmates' requests you delivered to. Shared as  1|WH|<helped>
-- (throttled: ~20 s after login, a minute after a change, and in answer to a
-- guildmate's login/Sync hello), stored per guild for the roster.
--
-- Tab: Items received | Items sent side by side. "Show all completed guild requests"
-- (off every time you log in) swaps them for every fulfilled request this client knows.
local _, ns = ...
local W = ns.Wishlist

local History = {}
ns.History = History

local SHARE_LOGIN   = 20
local SHARE_CHANGED = 60
local SCAN_DELAY    = 1   -- coalesce bursts of wishlist changes into one scan

local sharePending, scanPending = false, false

local function Data()
    local h = ns.charDB.history
    h.entries = h.entries or {}
    -- Lists from the first History version (event-logged); replaced by entries.
    h.sent, h.received, h.deliveredTo = nil, nil, nil
    return h
end

local function Short(name) return name and Ambiguate(name, "guild") or nil end

local function IsMe(name)
    local me = ns:PlayerName()
    return name == me or name == Short(me)
end

-- What a request asks for, saved with the entry (so it survives the request's purge).
local function Describe(req)
    if req.rule then return { rule = W:RuleText(req.rule), armor = req.rule.armor } end
    return { itemID = req.itemID }
end

---------------------------------------------------------------------------
-- Scan the requests -> entries
---------------------------------------------------------------------------
local function MyHelped()
    local n = 0
    for _, e in pairs(Data().entries) do
        if e.kind == "sent" then n = n + 1 end
    end
    return n
end

local ScheduleShare, SaveOwn -- below

local function Scan()
    scanPending = false
    if not ns:GuildKey() then return end
    local entries = Data().entries
    local before = MyHelped()
    local changed = false
    for _, req in ipairs(W:All()) do
        if req.receivedFrom then
            local mine = W:IsMine(req)
            for who, n in pairs(req.receivedFrom) do
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
                        changed = true
                    end
                end
            end
        end
    end
    if changed then
        ns:Fire("HISTORY_CHANGED")
        if MyHelped() ~= before then
            SaveOwn()
            ns:Fire("HELPED_CHANGED")
            ScheduleShare(SHARE_CHANGED)
        end
    end
end

local function ScheduleScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_DELAY, Scan)
end

ns:RegisterCallback("WISHLIST_CHANGED", ScheduleScan)
ns:RegisterEvent("PLAYER_LOGIN", function() C_Timer.After(5, ScheduleScan) end)

function History:Entries(kind)
    local out = {}
    for _, e in pairs(Data().entries) do
        if e.kind == kind then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return (a.t or 0) > (b.t or 0) end)
    return out
end

---------------------------------------------------------------------------
-- Sharing the Helped count
---------------------------------------------------------------------------
local function GuildStore()
    local key = ns:GuildKey()
    if not key then return nil end
    ns.db.helped = ns.db.helped or {}
    ns.db.helped[key] = ns.db.helped[key] or {}
    return ns.db.helped[key]
end

-- Keep my count in the account-wide store too, for my other characters on this account.
SaveOwn = function()
    local store = GuildStore()
    if store then store[Short(ns:PlayerName())] = { n = MyHelped(), t = time() } end
end

local function ShareNow()
    sharePending = false
    SaveOwn()
    if IsInGuild() and ns.Comm then ns.Comm:Send("WH", MyHelped()) end
end

ScheduleShare = function(delay)
    if sharePending then return end
    sharePending = true
    C_Timer.After(delay, ShareNow)
end

ns.Comm:RegisterHandler("WH", function(sender, helped)
    local store = GuildStore()
    helped = tonumber(helped)
    if not store or not helped then return end
    store[sender] = { n = helped, t = time() }
    ns:Fire("HELPED_CHANGED")
end)

ns:RegisterCallback("SYNC_REQUESTED", function() ScheduleShare(3 + math.random() * 5) end)
ns:RegisterCallback("ADDON_USERS_CHANGED", function() ScheduleShare(3 + math.random() * 5) end)
ns:RegisterCallback("HELLO", function(_, _, flag)
    if flag == "Q" then ScheduleShare(2 + math.random() * 6) end
end)
ns:RegisterEvent("PLAYER_LOGIN", function()
    C_Timer.After(SHARE_LOGIN, function() ScheduleShare(0) end)
end)
ns:RegisterEvent("PLAYER_LOGOUT", function() SaveOwn() end)

function History:HelpedCount(fullName)
    local name = Short(fullName)
    if IsMe(name) then return MyHelped() end
    local store = GuildStore()
    local s = store and store[name]
    return s and s.n or nil
end

---------------------------------------------------------------------------
-- Tab
---------------------------------------------------------------------------
local ROW_HEIGHT = 20
local ARMOR_ICONS = {
    "Interface\\Icons\\INV_Chest_Cloth_17", "Interface\\Icons\\INV_Chest_Leather_09",
    "Interface\\Icons\\INV_Chest_Chain_05", "Interface\\Icons\\INV_Chest_Plate06",
}

local panel, showAll, lists = nil, false, {}

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

-- One list: columns { label, width, flex, get(entry) -> text, r, g, b }
local function MakeList(parent, title, cols)
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
        end
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
    ns.Columns.Watch(l.scrollBox, cols, function()
        l.version = l.version + 1
        LayoutHeaders()
        l.scrollBox:ForEachFrame(LayoutRow)
    end)
    LayoutHeaders()

    function l:SetEntries(entries, emptyText)
        local wrapped = {}
        for i, e in ipairs(entries) do wrapped[i] = { e = e, index = i } end
        self.scrollBox:SetDataProvider(CreateDataProvider(wrapped), ScrollBoxConstants.RetainScrollPosition)
        self.empty:SetText(emptyText)
        self.empty:SetShown(#entries == 0)
    end
    return l
end

local function When(t) return t and date("%b %d %H:%M", t) or "" end
local GREY = { r = 0.6, g = 0.6, b = 0.6 }

local function Refresh()
    if not panel then return end
    lists.received.frame:SetShown(not showAll)
    lists.sent.frame:SetShown(not showAll)
    lists.all.frame:SetShown(showAll)
    if showAll then
        local done = {}
        for _, req in ipairs(W:All()) do
            if not req.deleted and (req.received or 0) >= req.qty then done[#done + 1] = req end
        end
        table.sort(done, function(a, b) return a.updated > b.updated end)
        lists.all:SetEntries(done, "No completed requests yet.")
    else
        lists.received:SetEntries(History:Entries("received"), "Nothing received yet.")
        lists.sent:SetEntries(History:Entries("sent"), "Nothing sent yet.")
    end
end

local function Build(p)
    panel = p
    local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    intro:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
    intro:SetText("Your own wishlist deliveries. Only you see this.")

    local check = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    check:SetSize(24, 24)
    check:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -190, -3)
    local label = check.Text or check.text
    if not label then
        label = check:CreateFontString(nil, "ARTWORK")
        label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    end
    label:SetFontObject("GameFontHighlightSmall")
    label:SetText("Show all completed guild requests")
    check:SetChecked(false)
    check:SetScript("OnClick", function(self)
        showAll = self:GetChecked() and true or false
        Refresh()
    end)

    local qtyText = function(e) return "x" .. tostring(e.qty or 0) end
    local nameText = function(e) return EntryName(e) end

    lists.received = MakeList(panel, "Items received", {
        { label = "Item", width = 120, flex = 1, icon = EntryIcon, get = nameText },
        { label = "Qty", width = 40, get = qtyText },
        { label = "From", width = 110, get = function(e) return e.who or "?" end },
        { label = "When", width = 80, get = function(e) return When(e.t), GREY end },
    })
    lists.sent = MakeList(panel, "Items sent", {
        { label = "Item", width = 120, flex = 1, icon = EntryIcon, get = nameText },
        { label = "Qty", width = 40, get = qtyText },
        { label = "To", width = 110, get = function(e) return e.who or "?" end },
        { label = "When", width = 80, get = function(e) return When(e.t), GREY end },
    })
    lists.all = MakeList(panel, "Completed guild requests (kept 30 days)", {
        { label = "Item", width = 170, flex = 2,
          icon = function(req) return EntryIcon(Describe(req)) end,
          get = function(req) return EntryName(Describe(req)) end },
        { label = "Qty", width = 40, get = function(req) return "x" .. req.qty end },
        { label = "Requester", width = 130, get = function(req) return req.requester end },
        { label = "Sent by", width = 150, flex = 1, get = function(req)
            local names = {}
            for who, n in pairs(req.receivedFrom or {}) do names[#names + 1] = ("%s (%d)"):format(who, n) end
            return #names > 0 and table.concat(names, ", ") or "—"
        end },
        { label = "Done", width = 80, get = function(req) return When(req.updated), GREY end },
    })

    local top = -34
    lists.received.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, top)
    lists.received.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOM", -6, 4)
    lists.sent.frame:SetPoint("TOPLEFT", panel, "TOP", 6, top)
    lists.sent.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    lists.all.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 4, top)
    lists.all.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)

    panel:SetScript("OnShow", Refresh)
    ns:RegisterCallback("HISTORY_CHANGED", function() if panel:IsVisible() then Refresh() end end)
    ns:RegisterCallback("WISHLIST_CHANGED", function() if showAll and panel:IsVisible() then Refresh() end end)
    Refresh()
end

ns.MainFrame:RegisterTab("history", "History", 25, Build)
