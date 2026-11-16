local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
local walk = require("code-tour.walk")
local checks = 0
local function check(value, message)
  assert(value, message)
  checks = checks + 1
end
-- node(id, boxes): boxes are ids; the first is the overview.
local function node(id, ...)
  local boxes = {}
  for k, box in ipairs({ ... }) do
    boxes[k] = { id = box, stop = 1, role = k == 1 and "overview" or "part" }
  end
  return { id = id, label = id, stops = { 1 }, boxes = boxes }
end
local function edge(from, to, from_box, extra)
  return vim.tbl_extend("force", { source = from, target = to, relation = "next", via = "call", from_box = from_box }, extra or {})
end
local function trace(plan)
  local out = {}
  for _, step in ipairs(plan.steps) do
    out[#out + 1] = step.box .. (step.kind == "return" and "^" or "")
  end
  return table.concat(out, " ")
end
local function plan_of(nodes, links)
  return walk.plan({ nodes = nodes, links = links })
end

-- A calls B, C and D from its second box; B and C come back, D (last edge) does not.
local plan = assert(plan_of(
  { node("A", "a1", "a2", "a3"), node("B", "b1"), node("C", "c1"), node("D", "d1", "d2") },
  { edge("A", "B", "a2"), edge("A", "C", "a2"), edge("A", "D", "a2") }
))
check(trace(plan) == "a1 a2 b1 a2^ c1 a2^ d1 d2 a3", "Visit each edge, returning until the last: " .. trace(plan))
check(plan.steps[3].kind == "enter" and plan.steps[3].via.source == "A", "Entering a node records its edge")

-- The last edge is followed with no return when the node has nothing left to show.
plan = assert(plan_of({ node("A", "a1"), node("B", "b1"), node("C", "c1") }, { edge("A", "B", "a1"), edge("A", "C", "a1") }))
check(trace(plan) == "a1 b1 a1^ c1", "No return after the final edge of a finished node: " .. trace(plan))

-- Nested branches walk back up one level at a time.
plan = assert(plan_of(
  { node("A", "a1"), node("B", "b1", "b2"), node("C", "c1"), node("D", "d1"), node("E", "e1") },
  { edge("A", "B", "a1"), edge("A", "E", "a1"), edge("B", "C", "b2"), edge("B", "D", "b2") }
))
check(trace(plan) == "a1 b1 b2 c1 b2^ d1 a1^ e1", "Walking back up through nested branches: " .. trace(plan))

-- Main route edges (no box) come after the node's own boxes and calls.
plan = assert(plan_of(
  { node("A", "a1", "a2"), node("B", "b1"), node("N", "n1") },
  { edge("A", "B", "a1"), { source = "A", target = "N", relation = "next", via = "sequence" } }
))
check(trace(plan) == "a1 b1 a2 n1", "Route edges follow the node: " .. trace(plan))

-- A shared node is walked once; the second edge becomes a reference.
plan = assert(plan_of(
  { node("A", "a1"), node("B", "b1"), node("C", "c1"), node("D", "d1") },
  { edge("A", "B", "a1"), edge("A", "C", "a1"), edge("B", "D", "b1"), edge("C", "D", "c1") }
))
check(trace(plan) == "a1 b1 d1 a1^ c1", "Shared node is walked once: " .. trace(plan))
check(#plan.refs == 1 and plan.refs[1].why == "shared" and plan.refs[1].to == "D", "Shared edge reported as a reference")

-- No stray return when a later sibling was claimed by an earlier subtree.
plan = assert(plan_of(
  { node("A", "a1"), node("B", "b1"), node("C", "c1") },
  { edge("A", "B", "a1"), edge("A", "C", "a1"), edge("B", "C", "b1") }
))
check(trace(plan) == "a1 b1 c1", "Claimed sibling leaves no dangling return: " .. trace(plan))

-- Cycles are rejected by name unless the closing edge is marked ref.
local cyclic = { node("A", "a1"), node("B", "b1") }
local bad, err = plan_of(cyclic, { edge("A", "B", "a1"), edge("B", "A", "b1") })
check(bad == nil and err:find("A → B → A", 1, true), "Cycle error names the loop: " .. tostring(err))
plan = assert(plan_of(cyclic, { edge("A", "B", "a1"), edge("B", "A", "b1", { ref = true }) }))
check(trace(plan) == "a1 b1" and plan.refs[1].why == "marked", "Marked recursion is a reference")
local self_loop = select(2, plan_of({ node("A", "a1") }, { edge("A", "A", "a1") }))
check(self_loop and self_loop:find("cycle", 1, true), "Self-recursion must be marked ref")

-- Several roots are walked in authored order.
plan = assert(plan_of({ node("A", "a1"), node("B", "b1") }, {}))
check(trace(plan) == "a1 b1" and plan.steps[2].kind == "root", "Independent snippets are all roots")

-- The cursor steps forward and back along the plan, including returns.
plan = assert(plan_of(
  { node("A", "a1"), node("B", "b1"), node("C", "c1") }, { edge("A", "B", "a1"), edge("A", "C", "a1") }
))
local cursor = walk.cursor(plan)
check(cursor:next().box == "b1" and cursor:next().kind == "return" and cursor:next().box == "c1", "Cursor goes forward")
check(cursor:next() == nil and cursor:prev().kind == "return" and cursor:prev().box == "b1", "Cursor walks back up")
check(cursor:seek("C").box == "c1" and cursor.index == 4, "Cursor can seek a node")

-- Optional edges are walked too, in authored order.
plan = assert(plan_of({ node("A", "a1"), node("B", "b1"), node("C", "c1") },
  { edge("A", "B", "a1", { relation = "optional" }), edge("A", "C", "a1") }))
check(trace(plan) == "a1 b1 a1^ c1", "Optional edges are walked as well")
print("PASS: " .. checks .. " tour walk checks")
