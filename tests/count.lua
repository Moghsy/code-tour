local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, cb) cb(true) end
local tour, view = require("tour"), require("code-tour.tour-view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 50 do lines[i] = "local value = " .. i end
vim.fn.writefile(lines, root .. "/source.lua")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function state() return tour.state() end
local function header() return view.state().rows[2][2][1] end
local function snippet(first, last, title)
  return { file = "source.lua", start = first, ["end"] = last, title = title, note = title }
end
local function test()
  tour.setup({ smooth_scroll = false })
  local method = snippet(10, 12, "Method")
  method.calls = {{ file = "source.lua", start = 15, ["end"] = 16, title = "Deep lazy", lazy = true,
    callsite = { start = 11, ["end"] = 11 } }}
  local first = snippet(1, 8, "First")
  first.parts = {
    { start = 1, ["end"] = 4, note = "Part one", calls = { method } },
    { start = 5, ["end"] = 8, note = "Part two", calls = {
      { file = "source.lua", start = 17, ["end"] = 18, title = "Other lazy", lazy = true },
    } },
  }
  local result = tour.show({ first, snippet(20, 23, "Second") }, { root = root })
  check(#state().stops == 5, "Fixture includes main, nested and lazy storage entries")
  check(result.shown == 2, "Show reports the number of main snippets")
  check(header():find("Snippet 1/2", 1, true), "Subparts and method branches do not inflate main total")
  tour.next_explanation(1)
  check(header():find("Snippet 1/2", 1, true) and header():find("Part 1/2", 1, true), "Part counter is separate")
  tour.expand_call(state().stops[2])
  check(header():find("Snippet 1/2", 1, true), "Entered method keeps its owning main-snippet number")
  tour.next_snippet(1)
  check(state().stop == 5 and header():find("Snippet 2/2", 1, true), "Next snippet uses main order despite flat storage gaps")
  tour.next_snippet(-1)
  check(state().stop == 1 and header():find("Snippet 1/2", 1, true), "Previous main snippet skips method branches")
  tour.expand_call(state().stops[2])
  local request = tour.explain_location({ uri = vim.uri_from_fname(root .. "/source.lua"),
    range = { start = { line = 9, character = 0 }, ["end"] = { line = 11, character = 1 } } })
  local refined = snippet(10, 12, "Refinement")
  refined.parts = { { start = 10, ["end"] = 10, note = "Setup" }, { start = 11, ["end"] = 12, note = "Work" } }
  tour.fill(request, { refined })
  check(header():find("Snippet 1/2", 1, true) and header():find("Part 1/2", 1, true), "Refining a method never changes snippet total")
  tour.next_explanation(1)
  request = tour.expand_call(state().stops[3])
  check(header():find("Snippet 1/2", 1, true), "Pending lazy generation does not change main count")
  tour.fill(request, { snippet(15, 16, "Ready deep method") })
  check(header():find("Snippet 1/2", 1, true), "Completing lazy generation does not change main count")
  local selection = require("code-tour.selection").capture(state(), { start = 30, ["end"] = 31 })
  request = tour.explain_range(selection)
  check(header():find("Snippet 1/2", 1, true), "Pending standalone explanation is excluded")
  tour.fill(request, { snippet(30, 31, "New main snippet") })
  check(header():find("Snippet 3/3", 1, true), "A genuinely new main snippet increments main count")
  tour.stop()
  print("PASS: " .. checks .. " main-snippet counter assertions")
end
local ok, err = xpcall(test, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
