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
local function call(file_start, file_end, name, site, calls, level)
  return { file = "main.lua", start = file_start, ["end"] = file_end, title = name, note = name, next = true, level = level or 1,
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
      call(6, 8, "B", 2, { call(10, 12, "C", 7, { call(14, 16, "D", 11, nil, 3) }, 2) }, 1) } },
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
  -- Explicit levels: level 0 calls never fold, whatever their depth.
  local function sp(c) c.level = 0; return c end
  tour.show({
    { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A", calls = {
      sp(call(6, 8, "B", 2, { sp(call(10, 12, "C", 7, { sp(call(14, 16, "D", 11)) })) })),
      call(22, 24, "X", 3, { call(26, 28, "Y", 23, nil, 2) }, 1) } },
    { file = "main.lua", start = 18, ["end"] = 20, title = "E", note = "E" },
  }, { root = root })
  local sw = walk_titles(); check(sw == "A B C D C B A X Y X A E", "Spine full walk: " .. sw)
  tour.zoom(-1)
  local s1 = walk_titles(); check(s1 == "A B C D C B A X A E", "Depth 1 folds only Y: " .. s1)
  tour.zoom(-1)
  local s0 = walk_titles(); check(tour.state().zoom == 0 and s0 == "A B C D C B A E", "Level 0 is the essential path alone: " .. s0)
  tour.zoom(-1)
  check(tour.state().zoom == 0, "Zoom stops at level 0")
  tour.zoom(1)
  tour.zoom(1)
  check(tour.state().zoom == nil, "Back to full detail")
  -- The route report gives the deepest level and flags calls that claim a level above their parent.
  local shown2 = tour.show({
    { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A", calls = {
      call(6, 8, "B", 2, { call(10, 12, "C", 7, nil, 2) }, 1) } },
  }, { root = root })
  check(shown2.route.levels == 2 and #shown2.route.shadowed == 0, "Report: deepest level 2, nothing shadowed")
  local shown3 = tour.show({
    { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A", calls = {
      call(6, 8, "B", 2, { sp(call(10, 12, "C", 7)) }) } },
  }, { root = root })
  check(#shown3.route.shadowed == 1 and shown3.route.shadowed[1].to == "C", "A level 0 call under a level 1 call is reported as shadowed")
  -- A call may carry a why, a skipped call a reason the reader can see.
  check(pcall(tour.show, { { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A", calls = {
    { file = "main.lua", start = 6, ["end"] = 8, title = "log", lazy = true, why = "logging helper",
      callsite = { start = 2, ["end"] = 2, symbol = "line" } } } } }, { root = root }), "A lazy call can say why it was skipped")
  local lazy_call = tour.state().stops[2]
  check(lazy_call.why == "logging helper", "The reason is kept on the call")
  pcall(tour.expand_call, lazy_call)
  local said = false
  for _, n in ipairs(notes) do if n:find("Skipped earlier: logging helper", 1, true) then said = true end end
  check(said, "Opening a skipped call says why it was skipped")
  -- There is one schema: a gold call without a level is rejected, and the tour stays as it was.
  local before_id = tour.state().id
  local no_level = call(6, 8, "B", 2); no_level.level = nil
  check(not pcall(tour.show, { { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A", calls = { no_level } } }, { root = root })
    and tour.state().id == before_id, "A gold call without a level is rejected without replacing the tour")
  -- A new tour resets the zoom.
  tour.show({ { file = "main.lua", start = 1, ["end"] = 4, title = "Fresh", note = "x" } }, { root = root })
  check(tour.state().zoom == nil, "A new tour starts unfolded")
  tour.stop()
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else print("PASS: " .. checks .. " zoom checks"); vim.cmd("qa!") end
