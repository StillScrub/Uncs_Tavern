-- UI\Columns.lua: column widths that follow the window size.
--
-- A column is { width = n } (fixed), or { width = n, flex = weight } (n is its minimum;
-- it takes a share of any spare width by weight). Layout fills in col.x and col.w.
-- Lists call it from their scroll box's OnSizeChanged and then re-anchor headers and
-- visible rows; new rows read col.x / col.w when they're set up.
local _, ns = ...

local Columns = {}
ns.Columns = Columns

function Columns.Layout(cols, total)
    local fixed, weight = 0, 0
    for _, c in ipairs(cols) do
        fixed = fixed + c.width
        if c.flex then weight = weight + c.flex end
    end
    local extra = math.max(0, (total or 0) - fixed)
    local x = 0
    for _, c in ipairs(cols) do
        local add = (c.flex and weight > 0) and math.floor(extra * c.flex / weight) or 0
        c.x, c.w = x, c.width + add
        x = x + c.w
    end
end

-- Calls fn(cols) now and whenever the scroll box changes width.
function Columns.Watch(scrollBox, cols, fn)
    Columns.Layout(cols, scrollBox:GetWidth())
    scrollBox:HookScript("OnSizeChanged", function(self, width)
        Columns.Layout(cols, width)
        fn(cols)
    end)
end
