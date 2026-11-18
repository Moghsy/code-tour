-- The tree view: outline text, markers, current-node highlight, float and tab windows, jumping.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 40, 120
local tree = require("code-tour.tree")
local function node(id, label, extra)
  return vim.tbl_extend("force", { id = id, label = label, source_file = "a.lua", start = 1, ["end"] = 5, stops = { 1 }, boxes = {} }, extra or {})
end
local graph = {
  nodes = { node("A", "Entry", { root = true, boxes = { { role = "overview" }, { role = "part" }, { role = "part" } } }), node("B", "Helper"), node("C", "Side"), node("D", "Second", { root = true }) },
  links = {
    { source = "A", target = "B", relation = "next", via = "call" },
    { source = "A", target = "C", relation = "optional", via = "call" },
    { source = "B", target = "A", relation = "next", via = "call" }, -- recursion must not loop
    { source = "A", target = "D", relation = "next", via = "sequence" },
  },
}
local lines, rows, spans, current = tree.outline(graph, "B")
assert(#lines == 5, vim.inspect(lines)) -- Entry, Helper, its back-reference to Entry, Side, Second
assert(lines[1]:find("1. Entry", 1, true) and lines[1]:find("(2 parts)", 1, true), lines[1])
assert(lines[2]:find("├─▶", 1, true) or lines[2]:find("├─●", 1, true), lines[2])
assert(current == 2 and rows[2].id == "B", tostring(current))
assert(lines[3]:find("↺", 1, true), lines[3]) -- recursion shows a reference, not a loop
assert(lines[4]:find("└─○", 1, true), lines[4])
local has_current = false
for _, span in ipairs(spans) do has_current = has_current or (span[4] == "CodeTourTreeCurrent" and span[1] == 1) end
assert(has_current)
-- float, jump, toggle
local picked
tree.open("float", graph, "A", function(n) picked = n.id end)
assert(tree.is_open() and vim.api.nvim_win_get_config(0).relative == "editor")
vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
assert(picked == "C" and not tree.is_open(), tostring(picked))
tree.open("float", graph, "A", function() end)
tree.open("float", graph, "A", function() end) -- second call toggles it closed
assert(not tree.is_open())
-- tab
tree.open("tab", graph, "A", function() end)
assert(#vim.api.nvim_list_tabpages() == 2 and tree.is_open())
vim.api.nvim_feedkeys("q", "x", false)
assert(#vim.api.nvim_list_tabpages() == 1 and not tree.is_open())
assert(not pcall(tree.open, "bogus", graph, nil, function() end))
print("tree OK")
