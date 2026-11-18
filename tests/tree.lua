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
local lines, rows, spans, current = tree.layout(graph, "B")
local text = table.concat(lines, "\n")
-- every snippet is a box with its title and location; roots are numbered, joined by an arrow
for _, want in ipairs({ "1. Entry", "2 parts", "Helper", "Side", "2. Second", "a.lua:1-5", "▼" }) do
  assert(text:find(want, 1, true), want .. "\n" .. text)
end
-- gold call: ▶ branch, last optional call: └ ┄○, recursion shows a reference instead of looping
assert(text:find("├─▶", 1, true), text)
assert(text:find("└┄○", 1, true) or text:find("└─▶", 1, true) or text:find("┄○", 1, true), text)
assert(text:find("↺", 1, true), text)
assert(select(2, text:gsub("1%. Entry", "")) == 1)
-- the cursor lands on the current snippet's title row, which carries the marker
assert(rows[current].id == "B" and lines[current]:find("● Helper", 1, true), tostring(current) .. lines[current])
local has_current = false
for _, span in ipairs(spans) do has_current = has_current or span[4] == "CodeTourTreeCurrent" end
assert(has_current)
for i, row in ipairs(rows) do assert(row == nil or row.id, i) end
-- float, jump, toggle
local picked
tree.open("float", graph, "A", function(n) picked = n.id end)
assert(tree.is_open() and vim.api.nvim_win_get_config(0).relative == "editor")
local target
for i, row in ipairs(rows) do if row and row.id == "C" then target = i end end
vim.api.nvim_win_set_cursor(0, { target, 0 })
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
