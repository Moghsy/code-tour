local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 110
vim.env.HERDR_ENV, vim.env.HERDR_SESSION, vim.env.HERDR_PANE_ID = nil, nil, nil
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 100 do lines[i] = "local value" .. i .. " = " .. i end
for _, file in ipairs({ "a.lua", "b.lua", "c.lua" }) do vim.fn.writefile(lines, root .. "/" .. file) end
local tour, model = require("tour"), require("code-tour.stops")
local sent, fail = {}, false
require("code-tour.conversation").deliver = function(_, _root, prompt, _, callback)
  sent[#sent + 1] = prompt
  callback(not fail, fail and "Test delivery failure" or nil)
end
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function state() return tour.state() end
local function here()
  local s = state()
  local stop = s.stops[s.stop]
  return stop.title .. ":" .. s.box
end
local function part(first, last, calls)
  return { start = first, ["end"] = last, note = "Part " .. first, calls = calls }
end
local function stop(file, first, last, title, parts)
  return { file = file, start = first, ["end"] = last, title = title, note = title, parts = parts }
end
local function lazy()
  return { file = "b.lua", start = 20, ["end"] = 30, title = "Optional B", lazy = true }
end
local function show(calls)
  tour.show({
    stop("a.lua", 1, 9, "A", { part(1, 3), part(4, 6, calls), part(7, 9) }),
    stop("a.lua", 80, 85, "Tail"),
  }, { root = root })
end
local function callsite()
  tour.next_explanation(2)
  check(here() == "A:3", "Reach the middle caller box")
end
local function test()
  tour.setup({ smooth_scroll = false, walk = false })
  local b = stop("b.lua", 20, 25, "B", { part(20, 22), part(23, 25) })
  show({ b })
  check(model.outline(state().stops):find("Call from 1.3", 1, true), "Outline identifies caller box")
  local saved = state().id
  local invalid = lazy()
  invalid.parts = { part(20, 30) }
  check(not pcall(show, { invalid }), "Lazy branches reject eager parts")
  check(state().id == saved, "Invalid payload leaves current tour intact")

  show({ stop("b.lua", 20, 21, "First"), stop("c.lua", 40, 41, "Second") })
  callsite()
  local siblings = model.calls(state().stops, state().stops[1].parts[2])
  check(#siblings == 2 and siblings[1].title == "First", "Sibling calls keep authored order")
  tour.expand_call(siblings[1])
  check(here() == "First:1", "First sibling is entered explicitly")
  tour.next_explanation(1)
  check(here() == "A:3", "Finishing sibling restores its caller without entering other methods")
  tour.expand_call(siblings[2])
  check(here() == "Second:1", "Second sibling is entered explicitly")
  tour.next_explanation(1)
  check(here() == "A:3", "Last sibling restores the same caller explanation")

  -- Concurrent lazy requests preserve their own placeholder identities and do
  -- not steal focus from the most recently requested call.
  show({ lazy(), { file = "c.lua", start = 40, ["end"] = 45, title = "Other", lazy = true } })
  callsite()
  local caller = state().stops[1].parts[2]
  tour.ask("Keep this Q&A", "stay")
  local calls = model.calls(state().stops, caller)
  local first, prompt = tour.expand_call(calls[1])
  check(prompt:find("[code-tour definition] tour: ", 1, true), "Definition prompt cites the tour file and no rules")
  local second = tour.expand_call(calls[2])
  check(first ~= second and state().pending[first] and state().pending[second], "Requests stay independent")
  local result = tour.fill(first, { stop("b.lua", 20, 30, "First ready") })
  check(not result.navigate and here() == "A:3", "Earlier reply does not replace the latest inspect intent")
  result = tour.fill(second, { stop("c.lua", 40, 45, "Second ready") })
  check(result.navigate and here() == "Second ready:1", "Latest requested explanation opens when ready")
  tour.answer("Still the original caller", "1.3")
  check(caller.thread[1].answer == "Still the original caller", "Caller Q&A survives concurrent replies")
  tour.return_to_caller()
  check(here() == "A:3", "Concurrent branches retain their exact common return point")

  show({ lazy() })
  callsite()
  local id = tour.expand_call()
  local mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function() return { mode = "i" } end
  result = tour.fill(id, { stop("b.lua", 20, 30, "Typing B") })
  vim.api.nvim_get_mode = mode
  check(not result.navigate and here() == "A:3" and state().arrival, "Typing reader stays in caller")
  tour.expand_call()
  check(here() == "Typing B:1", "Completed explanation is ready for explicit entry")

  -- A selected-code reply can attach definitions from another file while the
  -- selection coverage validation continues to apply to the caller only.
  show(nil)
  tour.next_explanation(1)
  local selection = require("code-tour.selection").capture(state(), { start = 1, ["end"] = 3 })
  id = tour.explain_range(selection)
  local selected = stop("a.lua", 1, 3, "Selected", { part(1, 3, { stop("b.lua", 20, 25, "Selection B") }) })
  tour.fill(id, { selected })
  check(state().box == 3, "Selection keeps its inserted part")
  local adopted = model.calls_in(state().stops, state().stops[1], state().stops[1].parts[2])
  check(#adopted == 1 and adopted[1].title == "Selection B", "Refinement adopts callee at the selected part")
  tour.expand_call()
  check(here() == "Selection B:1", "Selected-code callee can be entered")
  tour.next_explanation(1)
  check(here() == "A:3", "Selected-code callee restores its inserted caller explanation")

  show(nil)
  tour.next_explanation(1)
  selection = require("code-tour.selection").capture(state(), { start = 1, ["end"] = 3 })
  id = tour.explain_range(selection)
  selected = stop("a.lua", 1, 3, "Selected")
  selected.calls = { stop("b.lua", 20, 25, "Overview B") }
  tour.fill(id, { selected })
  adopted = model.calls_in(state().stops, state().stops[1], state().stops[1].parts[2])
  check(#adopted == 1 and adopted[1].title == "Overview B", "Overview-only reply retains its callee")
  tour.expand_call()
  check(here() == "Overview B:1", "Overview-only callee can be entered")
  tour.next_explanation(1)
  check(here() == "A:3", "Overview-only callee restores its caller explanation")

  show({ lazy(), { file = "c.lua", start = 40, ["end"] = 45, title = "Other", lazy = true } })
  callsite()
  local select_ui = vim.ui.select
  vim.ui.select = function(items, _, callback) callback(items[2]) end
  tour.expand_call()
  vim.ui.select = select_ui
  local _, pending = next(state().pending)
  check(pending.placeholder.title == "Other" and here() == "A:3", "Multiple lazy calls are chosen explicitly without premature entry")
  check(vim.deep_equal(vim.fn.readfile(root .. "/a.lua"), lines), "Navigation never changes source")
  tour.stop()
  print("PASS: " .. checks .. " branch ownership assertions")
end
local ok, err = xpcall(test, debug.traceback)
require("code-tour.instance").unregister()
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
