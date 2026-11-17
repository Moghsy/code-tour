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
check(trace(plan) == "a1 a2 b1 a2^ c1 a2^ d1 d2 a2^ a3", "Every branch returns to its caller, the last included: " .. trace(plan))
check(plan.steps[3].kind == "enter" and plan.steps[3].via.source == "A", "Entering a node records its edge")

-- Every call returns to its caller, except the closing run of returns, which leads nowhere.
plan = assert(plan_of({ node("A", "a1"), node("B", "b1"), node("C", "c1") }, { edge("A", "B", "a1"), edge("A", "C", "a1") }))
check(trace(plan) == "a1 b1 a1^ c1", "The walk ends on the last snippet it reached: " .. trace(plan))

-- Nested branches walk back up one level at a time.
plan = assert(plan_of(
  { node("A", "a1"), node("B", "b1", "b2"), node("C", "c1"), node("D", "d1"), node("E", "e1") },
  { edge("A", "B", "a1"), edge("A", "E", "a1"), edge("B", "C", "b2"), edge("B", "D", "b2") }
))
check(trace(plan) == "a1 b1 b2 c1 b2^ d1 b2^ a1^ e1", "Walking back up through nested branches: " .. trace(plan))

-- Main route edges (no box) come after the node's own boxes and calls.
plan = assert(plan_of(
  { node("A", "a1", "a2"), node("B", "b1"), node("N", "n1") },
  { edge("A", "B", "a1"), { source = "A", target = "N", relation = "next", via = "sequence" } }
))
check(trace(plan) == "a1 b1 a1^ a2 n1", "Route edges follow the node and have no return: " .. trace(plan))

-- A shared node is walked once; the second edge becomes a reference.
plan = assert(plan_of(
  { node("A", "a1"), node("B", "b1"), node("C", "c1"), node("D", "d1") },
  { edge("A", "B", "a1"), edge("A", "C", "a1"), edge("B", "D", "b1"), edge("C", "D", "c1") }
))
check(trace(plan) == "a1 b1 d1 b1^ a1^ c1", "Shared node is walked once: " .. trace(plan))
check(#plan.refs == 1 and plan.refs[1].why == "shared" and plan.refs[1].to == "D", "Shared edge reported as a reference")

-- No stray return when a later sibling was claimed by an earlier subtree.
plan = assert(plan_of(
  { node("A", "a1"), node("B", "b1"), node("C", "c1") },
  { edge("A", "B", "a1"), edge("A", "C", "a1"), edge("B", "C", "b1") }
))
check(trace(plan) == "a1 b1 c1", "A claimed sibling leaves no dangling return: " .. trace(plan))

-- Cycles are not errors: the edge back onto the path becomes a reference.
local cyclic = { node("A", "a1"), node("B", "b1") }
plan = assert(plan_of(cyclic, { edge("A", "B", "a1"), edge("B", "A", "b1") }))
check(trace(plan) == "a1 b1" and plan.refs[1].why == "recursive" and plan.refs[1].to == "A", "Recursion is a reference: " .. trace(plan))
plan = assert(plan_of(cyclic, { edge("A", "B", "a1"), edge("B", "A", "b1", { ref = true }) }))
check(trace(plan) == "a1 b1" and plan.refs[1].why == "marked", "An author-marked ref stays a marked reference")
plan = assert(plan_of({ node("A", "a1") }, { edge("A", "A", "a1") }))
check(trace(plan) == "a1" and plan.refs[1].why == "recursive", "Self-recursion is a reference")
-- A loop with no entry from outside still gets read once, from its first snippet.
plan = assert(plan_of({ node("A", "a1"), node("B", "b1"), node("C", "c1") },
  { edge("A", "B", "a1"), edge("B", "C", "b1"), edge("C", "A", "c1") }))
check(trace(plan) == "a1 b1 c1" and #plan.refs == 1, "A closed loop is walked once: " .. trace(plan))
-- Mutual recursion below a root.
plan = assert(plan_of({ node("R", "r1"), node("A", "a1"), node("B", "b1") },
  { edge("R", "A", "r1"), edge("A", "B", "a1"), edge("B", "A", "b1") }))
check(trace(plan) == "r1 a1 b1" and plan.refs[1].why == "recursive", "Mutual recursion terminates: " .. trace(plan))

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

-- Optional edges are never walked automatically, and their snippets are not roots.
plan = assert(plan_of({ node("A", "a1"), node("B", "b1"), node("C", "c1"), node("O", "o1") },
  { edge("A", "B", "a1", { relation = "optional" }), edge("A", "C", "a1"), edge("B", "O", "b1", { relation = "optional" }) }))
check(trace(plan) == "a1 c1", "Only gold edges are walked: " .. trace(plan))
-- A gold edge from an optional snippet is still part of that snippet's own branch only.
plan = assert(plan_of({ node("A", "a1"), node("B", "b1"), node("C", "c1") },
  { edge("A", "B", "a1", { relation = "optional" }), edge("B", "C", "b1") }))
check(trace(plan) == "a1", "Branches below an optional snippet wait for the reader: " .. trace(plan))
print("PASS: " .. checks .. " tour walk checks")
