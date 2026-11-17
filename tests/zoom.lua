local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, cb) cb(true) end
local tour, view = require("tour"), require("code-tour.tour-view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 30 do lines[i] = "line " .. i end
vim.fn.writefile(lines, root .. "/main.lua")
local notes = {}
vim.notify = function(message) notes[#notes + 1] = message end
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function header() return view.state().rows[2][2][1] end
local function title() local s = tour.state(); return s.stops[s.stop].title end
local function call(file_start, file_end, name, site, calls)
  return { file = "main.lua", start = file_start, ["end"] = file_end, title = name, note = name, next = true,
    callsite = { start = site, ["end"] = site, symbol = "line" }, calls = calls }
end
local function marks()
  local s, found = tour.state(), {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.stops[1].buf,
    vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })) do
    local g = mark[4].hl_group
    if g and g:match("^CodeTour%a+Call$") then found[mark[2] + 1] = g end
  end
  return found
end
local function walk_titles()
  tour.next_explanation(-40)
  local seen = { title() }
  for _ = 1, 20 do
    local before = tour.state().stop .. "." .. tour.state().box
    tour.next_explanation(1)
    if tour.state().stop .. "." .. tour.state().box == before then break end
    seen[#seen + 1] = title()
  end
  return table.concat(seen, " ")
end
local function run()
  tour.setup({ smooth_scroll = false })
  local shown = tour.show({
    { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A", calls = {
      call(6, 8, "B", 2, { call(10, 12, "C", 7, { call(14, 16, "D", 11) }) }) } },
    { file = "main.lua", start = 18, ["end"] = 20, title = "E", note = "E" },
  }, { root = root })
  check(shown.route.snippets == 5, "Five snippets walked at full detail")
  local w = walk_titles(); check(w == "A B C D C B A E", "Full walk: " .. w)
  tour.next_explanation(-20)
  -- Zoom out one level: D is folded.
  tour.zoom(-1)
  local w = walk_titles(); check(w == "A B C B A E", "Depth 2 folds D: " .. w)
  tour.next_explanation(-20)
  check(header():find("+1 folded", 1, true), "Header counts folded snippets: " .. header())
  tour.zoom(-1)
  tour.zoom(-1)
  local w0 = walk_titles(); check(tour.state().zoom == 0 and w0 == "A E", "Depth 0 keeps only the top-level snippets: " .. w0)
  tour.zoom(-1)
  check(tour.state().zoom == 0, "Zoom stops at depth 0")
  tour.next_explanation(-20)
  check(header():find("+3 folded", 1, true), "Header: " .. header())
  -- Folded calls are drawn in their own colour.
  local g = marks()
  check(g[2] == "CodeTourFoldedCall", "The folded call is marked: " .. vim.inspect(g))
  -- Zoom back in, one level at a time, until nothing is folded.
  tour.zoom(1)
  local w1 = walk_titles(); check(tour.state().zoom == 1 and w1 == "A B A E", "Depth 1: " .. w1)
  tour.zoom(1)
  tour.zoom(1)
  local w2 = walk_titles(); check(tour.state().zoom == nil and w2 == "A B C D C B A E", "Zooming in far enough shows everything again: " .. w2)
  tour.next_explanation(-20)
  check(not header():find("folded", 1, true), "No folded marker at full detail: " .. header())
  -- A reader inside a branch that folds is moved to the nearest snippet still on the walk.
  tour.next_snippet(3)
  check(title() == "D", "Standing in D: " .. title())
  tour.zoom(-1)
  check(title() == "C", "Zooming out pulls the reader back to the nearest walked snippet: " .. title())
  tour.zoom(-1)
  check(title() == "B", "...and again: " .. title())
  -- The agent's route report ignores the zoom: it describes what was authored.
  tour.zoom(1)
  check(tour.state().zoom == 2, "Zoom level kept")
  -- Spine calls never fold: only branches off the spine do.
  local function sp(c) c.spine = true; return c end
  tour.show({
    { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A", calls = {
      sp(call(6, 8, "B", 2, { sp(call(10, 12, "C", 7, { sp(call(14, 16, "D", 11)) })) })),
      call(22, 24, "X", 3, { call(26, 28, "Y", 23) }) } },
    { file = "main.lua", start = 18, ["end"] = 20, title = "E", note = "E" },
  }, { root = root })
  local sw = walk_titles(); check(sw == "A B C D C B A X Y X A E", "Spine full walk: " .. sw)
  tour.zoom(-1)
  local s1 = walk_titles(); check(s1 == "A B C D C B A X A E", "Depth 1 folds only Y: " .. s1)
  tour.zoom(-1)
  local s0 = walk_titles(); check(tour.state().zoom == 0 and s0 == "A B C D C B A E", "Level 0 is the spine alone: " .. s0)
  tour.zoom(-1)
  check(tour.state().zoom == 0, "Zoom stops at the spine")
  tour.zoom(1)
  tour.zoom(1)
  check(tour.state().zoom == nil, "Back to full detail")
  -- A new tour resets the zoom.
  tour.show({ { file = "main.lua", start = 1, ["end"] = 4, title = "Fresh", note = "x" } }, { root = root })
  check(tour.state().zoom == nil, "A new tour starts unfolded")
  tour.stop()
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else print("PASS: " .. checks .. " zoom checks"); vim.cmd("qa!") end
