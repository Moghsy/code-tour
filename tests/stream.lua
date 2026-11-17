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
      { file = "main.lua", start = 6, ["end"] = 8, title = "B", next = true, spine = true, pending = true,
        callsite = { start = 2, ["end"] = 2, symbol = "line" } } } },
    { file = "main.lua", start = 18, ["end"] = 20, title = "E", pending = true },
  }, { root = root })
  check(shown.pending and #shown.pending == 2, "Skeleton returns one fill entry per pending snippet")
  check(shown.pending[1].title == "B" and shown.pending[2].title == "E", "Entries come back in walk order")
  check(shown.pending[1].command:find("--fill " .. shown.pending[1].id, 1, true), "Entry carries its fill command")
  local w = walk_titles(); check(w == "A B A E", "Pending snippets sit on the route: " .. w)
  check(shown.route.snippets == 3, "Route counts the pending snippets: " .. shown.route.snippets)
  -- The reader reaches the placeholder and sees that it is being written.
  tour.next_explanation(-20)
  tour.next_explanation(1)
  check(title() == "B", "Reader can step onto a pending snippet")
  check(tour.state().stops[tour.state().stop].placeholder, "It is still a placeholder")
  -- The agent fills B (and announces C as pending below it); the reader waiting on B lands on it.
  local filled = tour.fill(shown.pending[1].id, {
    { file = "main.lua", start = 6, ["end"] = 8, title = "B", note = "B is written now", calls = {
      { file = "main.lua", start = 10, ["end"] = 12, title = "C", next = true, pending = true,
        callsite = { start = 7, ["end"] = 7, symbol = "line" } } } } })
  check(filled.pending and #filled.pending == 1 and filled.pending[1].title == "C", "A fill can announce further pending snippets")
  check(not tour.state().stops[tour.state().stop].placeholder and title() == "B", "Reader stays on B, now written")
  local s = tour.state()
  check(s.stops[s.stop].note == "B is written now", "B carries its explanation")
  check(s.stops[s.stop].spine == true and s.stops[s.stop].next == true, "Gold and spine marks survive the fill")
  local w2 = walk_titles(); check(w2 == "A B C B A E", "The walk grows as fills arrive: " .. w2)
  -- A fill that arrives while the reader is elsewhere does not move them.
  tour.next_explanation(-20)
  tour.fill(shown.pending[2].id, { { file = "main.lua", start = 18, ["end"] = 20, title = "E", note = "E written" } })
  check(title() == "A", "A fill elsewhere leaves the reader in place: " .. title())
  local w3 = walk_titles(); check(w3 == "A B C B A E", "Walk unchanged by an unrelated fill: " .. w3)
  tour.stop()
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else print("PASS: " .. checks .. " stream checks"); vim.cmd("qa!") end
