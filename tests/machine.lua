-- The state-machine layer: schema, edges, graph, walk, layout, view and the tour wiring.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
vim.env.HERDR_ENV, vim.env.HERDR_SESSION, vim.env.HERDR_PANE_ID = nil, nil, nil
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_STATE_HOME, vim.env.XDG_DATA_HOME = root .. "/state", root .. "/data"
require("code-tour.instance").register = function() end
local lines = {}
for i = 1, 80 do lines[i] = "line " .. i end
vim.fn.writefile(lines, root .. "/job.lua")
vim.fn.writefile(lines, root .. "/fix.md")
local tour = require("tour")
local machine_lib = require("code-tour.machine")
local stops = require("code-tour.stops")

local function payload()
  return {
    stops = {
      { id = "claim", file = "job.lua", start = 1, ["end"] = 9, title = "claim", note = "Claim the item.",
        parts = { { id = "claim.claim-fix", start = 1, ["end"] = 9, note = "Mark it as fixing." } } },
      { id = "fix", file = "job.lua", start = 10, ["end"] = 30, title = "fix", note = "Try a fix, then decide.",
        parts = {
          { id = "fix.begin", start = 10, ["end"] = 13, note = "Begin a try." },
          { id = "fix.fix", start = 14, ["end"] = 20, note = "The agent writes the change." },
          { id = "fix.check", start = 21, ["end"] = 30, note = "Run the checks." },
        } },
      { id = "fix.prompt", file = "fix.md", start = 1, ["end"] = 10, title = "fix prompt", note = "The prompt for the fix step." },
      { id = "commit", file = "job.lua", start = 31, ["end"] = 40, title = "commit", note = "Commit the change." },
      { id = "gave-up", file = "job.lua", start = 41, ["end"] = 50, title = "gave up", note = "Out of tries." },
    },
    machine = {
      path = { "machines", "fixer" },
      start = "claim",
      catch = { { error = "ItemFailed", to = "errored" } },
      on_abort = "released",
      states = {
        { id = "claim", steps = { { part = "claim.claim-fix", kind = "computer", status = "fixing" } }, next = "fix" },
        { id = "fix",
          steps = {
            { part = "fix.begin", kind = "computer", status = "fixing" },
            { part = "fix.fix", kind = "agent", model = "muse-ember", effort = "xhigh", prompt = "fix.prompt" },
            { part = "fix.check", kind = "computer", feedback = true },
          },
          on = { name = "tried", outcomes = {
            { id = "passed", to = "commit", happy = true },
            { id = "refused", when = { { visits = "fix", below = 10, to = "fix" } }, otherwise = { exit = "gave-up" } },
          } } },
        { id = "commit", next = "done" },
        { id = "gave-up", exit = true, ["end"] = "out of tries" },
        { id = "errored", exit = true },
        { id = "released", exit = true },
        { id = "done", exit = true, ["end"] = "fixed" },
      },
    },
  }
end

local function loads(mutate)
  local data = payload()
  mutate(data.machine, data)
  local list = stops.normalize(data.stops, root)
  return pcall(machine_lib.normalize, data.machine, list)
end
local function rejects(label, mutate, expect)
  local ok, err = loads(mutate)
  assert(not ok, label .. ": should be rejected")
  assert(tostring(err):find(expect, 1, true), label .. ": " .. tostring(err) .. " (wanted " .. expect .. ")")
end

-- schema -------------------------------------------------------------------
assert(loads(function() end))
rejects("unknown state", function(m) m.states[1].next = "nowhere" end, "unknown state")
rejects("duplicate state", function(m) m.states[2].id = "claim" end, "duplicate state id")
rejects("unknown part", function(m) m.states[1].steps[1].part = "claim.nope" end, "not an id")
rejects("part of another stop", function(m) m.states[1].steps[1].part = "fix.begin" end, "not a part of the stop")
rejects("two happy", function(m)
  m.states[2].on.outcomes[2] = { id = "also", to = "gave-up", happy = true }
end, "two outcomes are marked happy")
rejects("exit must be exit state", function(m) m.states[2].on.outcomes[2].otherwise = { exit = "commit" } end, "exit = true")
rejects("bad kind", function(m) m.states[1].steps[1].kind = "robot" end, "kind must be")
rejects("agent fields on computer", function(m) m.states[1].steps[1].model = "x" end, "belong to agent")
rejects("bad guard", function(m) m.states[2].on.outcomes[2].when[1].below = 0 end, "positive integer")
rejects("two routes", function(m) m.states[2].next = "commit" end, "only one of")
rejects("catch to nowhere", function(m) m.catch[1].to = "nope" end, "unknown state")
rejects("start", function(m) m.start = "nope" end, "unknown state")
rejects("unknown field", function(m) m.states[1].flavour = "x" end, "unknown field")
rejects("step needs part", function(m) m.states[1].steps[1].part = nil end, "needs a part")
rejects("duplicate id", function(_, data) data.stops[4].id = "fix" end, "Duplicate id")
rejects("prompt id", function(m) m.states[2].steps[2].prompt = "nope" end, "prompt")
rejects("only_on_catch", function(m) m.states[1].only_on_catch = { "Nope" } end, "not a catch error")

-- edges ---------------------------------------------------------------------
local list = stops.normalize(payload().stops, root)
local machine = machine_lib.normalize(payload().machine, list)
local edges = machine_lib.edges(machine, machine.by_id.fix)
assert(#edges == 3, vim.inspect(edges))
assert(edges[1].target == "commit" and edges[1].happy and not edges[1].loop)
assert(edges[2].kind == "guard" and edges[2].loop and edges[2].guard == "fix visits < 10", vim.inspect(edges[2]))
assert(edges[3].kind == "otherwise" and edges[3].exit == "gave-up")

-- layout ----------------------------------------------------------------------
local text = table.concat((machine_lib and require("code-tour.machine-view").layout(machine, "fix.fix")), "\n")
for _, want in ipairs({
  "machines › fixer", "catch ItemFailed", "⇥ errored", "on abort", "⇥ released", "▶ claim · start",
  "■ fixing", "muse-ember XHIGH", "as feedback", "on tried", "passed → commit", "refused when",
  "fix visits < 10 ↻ fix", "otherwise ⇥ gave-up", "gave-up · exit", "end: out of tries",
}) do
  assert(text:find(want, 1, true), want .. "\n" .. text)
end
local rendered, rows, _, current = require("code-tour.machine-view").layout(machine, "fix.fix")
assert(rendered[current]:find("● fix", 1, true), rendered[current])
assert(rows[current].kind == "step" and rows[current].id == "fix.fix" and rows[current].prompt == "fix.prompt")
assert(text:find("╭", 1, true) and text:find("▸", 1, true), "the loop gets a margin bracket")
assert(vim.deep_equal(rendered, (require("code-tour.machine-view").layout(machine, "fix.fix"))), "layout is deterministic")
local target = require("code-tour.machine-view").target
assert(target(machine, rows[current]) == "fix.fix")

-- through the tour -------------------------------------------------------------
vim.fn.mkdir(root .. "/.git", "p")
local result = tour.show(payload(), { root = root, standalone = true })
assert(result.shown == 5, vim.inspect(result)) -- five top-level stops
local state = tour.state()
assert(state.machine and state.machine.start == "claim")
-- the walk starts at the start state, follows happy transitions and never walks a loop
local walked = {}
local function visit_boxes()
  walked = {}
  local first = state.stops[state.stop].id
  walked[#walked + 1] = first
end
visit_boxes()
assert(walked[1] == "claim", walked[1])
local graph = require("code-tour.graph").build(state, function(stop, box)
  for i, item in ipairs(state.stops) do
    if item == stop then
      for k, b in ipairs(stops.boxes(item)) do if b == box then return i .. "." .. k end end
    end
  end
end, "t")
assert(graph.graph.start, "graph names its start node")
local kinds = {}
for _, l in ipairs(graph.links) do
  if l.via == "machine" then kinds[l.kind] = (kinds[l.kind] or 0) + 1 end
  assert(l.via ~= "sequence", "a machine replaces the plain sequence")
end
assert(kinds.transition == 2 and kinds.loop == 1 and kinds.exit == 1 and kinds.prompt == 1 and kinds.catch == nil, vim.inspect(kinds))
local plan = require("code-tour.walk").plan(graph)
local order = {}
for _, step in ipairs(plan.steps) do order[#order + 1] = step.box end
local function stop_of_box(box) return state.stops[tonumber(box:match("^(%d+)"))].id end
local seq, last = {}, nil
for _, box in ipairs(order) do
  local id = stop_of_box(box)
  if id ~= last then seq[#seq + 1] = id last = id end
end
assert(table.concat(seq, ",") == "claim,fix,commit", table.concat(seq, ",")) -- loop, exit and prompt stay the reader's

-- navigation from the machine view jumps the tour
tour.machine("float")
local view = require("code-tour.machine-view")
assert(view.is_open() and vim.api.nvim_win_get_config(0).relative == "editor")
local buffer = vim.api.nvim_get_current_buf()
local at
for i, line in ipairs(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)) do
  if line:find("check", 1, true) and line:find("computer", 1, true) and line:find("as feedback", 1, true) then at = i end
end
assert(at, "found the check step")
vim.api.nvim_win_set_cursor(0, { at, 0 })
vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
assert(not view.is_open(), "float closes on jump")
local stop, box = state.stops[state.stop], nil
box = stops.boxes(stop)[state.box]
assert(box.id == "fix.check", tostring(box and box.id))
-- a split stays open and follows the tour
tour.machine("split")
assert(view.is_open())
local split_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
local function marked()
  for i, line in ipairs(vim.api.nvim_buf_get_lines(split_buf, 0, -1, false)) do
    if line:find("●", 1, true) then return line end
  end
end
assert(marked() and marked():find("check", 1, true), tostring(marked()))
tour.stop()
assert(not view.is_open(), "stopping the tour closes the view")
-- saved tours keep the machine and the authored ids
require("code-tour.conversation").deliver = function(_, _root, _, _, callback) callback(true) end
tour.show(payload(), { root = root, standalone = true })
local saved_result = tour.save_saved({ title = "Machine tour" })
tour.stop()
tour.open_saved(saved_result.id, { standalone = true })
local reopened = tour.state()
assert(reopened.machine and reopened.machine.start == "claim", "the saved machine is restored")
assert(#reopened.machine.states == 7)
local reopened_ids = {}
for _, item in ipairs(reopened.stops) do
  for _, b in ipairs(stops.boxes(item)) do if b.id then reopened_ids[b.id] = true end end
end
assert(reopened_ids["fix.fix"] and reopened_ids["fix"] and reopened_ids["fix.prompt"], vim.inspect(reopened_ids))
tour.machine("float")
assert(view.is_open())
view.close()
tour.stop()
-- a tour without a machine, and an invalid machine
assert(not pcall(tour.machine))
local bad = payload()
bad.machine.states[1].next = "nowhere"
local ok, err = pcall(tour.show, bad, { root = root, standalone = true })
assert(not ok and tostring(err):find("unknown state"), tostring(err))
assert(pcall(tour.show, payload().stops, { root = root, standalone = true }))
assert(tour.state().machine == nil, "a plain tour clears the machine")
assert(not pcall(tour.show, { stops = payload().stops, flavour = 1 }, { root = root, standalone = true }))
print("machine OK")
