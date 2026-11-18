-- Depth-first reading order over the tour graph (see graph.lua). The graph is a
-- general directed graph (recursion makes cycles); the walk is a spanning tree
-- of it, so every snippet is shown once and the reading order cannot loop.
-- Only gold (`next`) edges are walked. Optional edges stay reader-initiated.
--
-- plan(graph) returns a flat list of steps.
-- Each step shows one box of one snippet. A snippet's boxes are read in order.
-- Edges leave from the box that makes the call. Every edge is walked in turn and
-- every call, the last included, ends with a `return` step that brings the reader
-- back to the calling box before the walk goes on (to the next edge, the next box,
-- or out of the snippet). Moving between top-level snippets is not a call and has
-- no return.
--
-- Every walked snippet has a level: top-level snippets are 0, and a gold call has the
-- `level` its author gave it. Zoom folds the calls whose level is above the chosen one,
-- so level 0 is the essential path.
--
-- A gold edge becomes a reference (never walked) when:
--   * it is marked `ref`, or
--   * its target is on the current path (recursion or a loop), or
--   * its target was already walked (a shared node in a diamond), or
--   * its target is lazy (not explained yet).
local M = {}

local MAX_DEPTH = 128

local function out_edges(graph)
  local by_node = {}
  for index, link in ipairs(graph.links) do
    if link.relation == "next" then
      local list = by_node[link.source] or {}
      by_node[link.source] = list
      list[#list + 1] = { link = link, order = index }
    end
  end
  return by_node
end

-- Gold calls always carry the level their author gave them (stops.normalize enforces it).
local function level_of(link)
  return assert(link.level, "Gold call without a level")
end

-- Returns { steps = {...}, refs = {...} }, or nil, error when nested too deeply.
-- step = { node, box, kind = "root" | "enter" | "box" | "return", via? }
function M.plan(graph, opts)
  opts = opts or {}
  local nodes = {}
  for _, node in ipairs(graph.nodes) do
    nodes[node.id] = node
  end
  local edges = out_edges(graph)
  local steps, refs, folded, shadowed = {}, {}, {}, {}
  local deepest = 0
  local state, path = {}, {}

  local function boxes_of(node)
    local first = node.stops[1]
    return vim.tbl_filter(function(box)
      return box.stop == first
    end, node.boxes)
  end

  local visit
  visit = function(id, kind, via, depth)
    depth = depth or 0
    deepest = math.max(deepest, depth)
    local node = nodes[id]
    if #path >= MAX_DEPTH then
      return nil, "Tour is nested deeper than " .. MAX_DEPTH
    end
    state[id] = "active"
    path[#path + 1] = id
    local boxes = boxes_of(node)
    local position = {}
    for k, box in ipairs(boxes) do
      position[box.id] = k
    end
    -- Group this node's edges by the box they leave from; route edges go last.
    local by_box, route = {}, {}
    for _, item in ipairs(edges[id] or {}) do
      local from = item.link.from_box
      if from and position[from] then
        by_box[from] = by_box[from] or {}
        table.insert(by_box[from], item)
      else
        route[#route + 1] = item
      end
    end
    local function classify(items)
      local walk = {}
      for _, item in ipairs(items) do
        local target = item.link.target
        -- A call whose level is below the snippet it hangs off folds with that snippet,
        -- so it is not part of the essential path it claims to be on.
        if item.link.via == "call" and item.link.level and item.link.level < (depth or 0) then
          shadowed[#shadowed + 1] = { from = id, to = target, level = item.link.level, parent = depth or 0 }
        end
        if item.link.ref then
          refs[#refs + 1] = { from = id, to = target, why = "marked" }
        elseif opts.max_depth and item.link.via == "call" and level_of(item.link) > opts.max_depth then
          -- Zoomed out: a branch below the chosen level is folded, like an optional one.
          folded[#folded + 1] = { source = id, target = target, from_box = item.link.from_box,
            symbol = item.link.symbol, callsite = item.link.callsite }
        elseif nodes[target] and nodes[target].lazy then
          -- Not explained yet: nothing to show, and nothing to come back from.
          refs[#refs + 1] = { from = id, to = target, why = "lazy" }
        elseif state[target] == "active" then
          refs[#refs + 1] = { from = id, to = target, why = "recursive" }
        elseif state[target] then
          refs[#refs + 1] = { from = id, to = target, why = "shared" }
        else
          walk[#walk + 1] = item
        end
      end
      return walk
    end
    local function run(items, box)
      local walk, err = classify(items)
      if not walk then
        return nil, err
      end
      for i, item in ipairs(walk) do
        -- A shared target may be claimed by an earlier sibling in this same list.
        if state[item.link.target] then
          refs[#refs + 1] = { from = id, to = item.link.target, why = "shared" }
        else
          local ok, problem = visit(item.link.target, "enter", item.link, item.link.via == "call" and level_of(item.link) or (depth or 0))
          if not ok then
            return nil, problem
          end
          -- Every branch comes back to the box that made the call, the last one included.
          -- (Route edges between top-level snippets are not calls: nothing to return to.)
          if item.link.via == "call" then
            steps[#steps + 1] = { node = id, box = box.id, kind = "return" }
          end
        end
      end
      return true
    end
    steps[#steps + 1] = { node = id, box = boxes[1].id, kind = kind, via = via and { source = via.source, relation = via.relation, symbol = via.symbol, from_box = via.from_box, callsite = via.callsite } or nil }
    for k, box in ipairs(boxes) do
      if k > 1 then
        steps[#steps + 1] = { node = id, box = box.id, kind = "box" }
      end
      if by_box[box.id] then
        local ok, problem = run(by_box[box.id], box)
        if not ok then
          return nil, problem
        end
      end
    end
    if #route > 0 then
      local ok, problem = run(route, boxes[#boxes])
      if not ok then
        return nil, problem
      end
    end
    path[#path] = nil
    state[id] = "done"
    return true
  end

  -- Start at each snippet no call reaches, in authored order. Snippets reached
  -- only by optional calls are the reader's to open, never roots.
  local gold, called = {}, {}
  for _, link in ipairs(graph.links) do
    if (link.via == "call" or link.via == "sequence" or link.via == "machine") and not link.ref then
      called[link.target] = true
      if link.relation == "next" then
        gold[link.target] = true
      end
    end
  end
  -- A machine names its start state: the walk begins there.
  local start = graph.graph and graph.graph.start
  if start and nodes[start] and not nodes[start].lazy then
    local ok, err = visit(start, "root")
    if not ok then
      return nil, err
    end
  end
  for _, node in ipairs(graph.nodes) do
    if not state[node.id] and not called[node.id] and not node.lazy then
      local ok, err = visit(node.id, "root")
      if not ok then
        return nil, err
      end
    end
  end
  -- Everything below an optional call belongs to the reader until they open it.
  local owned, queue = {}, {}
  for _, link in ipairs(graph.links) do
    if (link.via == "call" or link.via == "machine") and link.relation == "optional" and not state[link.target] and not owned[link.target] then
      owned[link.target] = true
      queue[#queue + 1] = link.target
    end
  end
  -- A call folded by the zoom hands its subtree to the reader as well.
  for _, fold in ipairs(folded) do
    if not state[fold.target] and not owned[fold.target] then
      owned[fold.target] = true
      queue[#queue + 1] = fold.target
    end
  end
  local head = 1
  while head <= #queue do
    local id = queue[head]
    head = head + 1
    for _, link in ipairs(graph.links) do
      if (link.via == "call" or link.via == "machine") and link.source == id and not owned[link.target] and not state[link.target] then
        owned[link.target] = true
        queue[#queue + 1] = link.target
      end
    end
  end
  -- Left over: members of a loop of gold edges with no entry from outside.
  for _, node in ipairs(graph.nodes) do
    if not state[node.id] and gold[node.id] and not owned[node.id] and not node.lazy then
      local ok, err = visit(node.id, "root")
      if not ok then
        return nil, err
      end
    end
  end
  -- Coming back out of the last call leads nowhere new: the walk ends on the last snippet
  -- it reached, not on a caller whose number is lower than the snippets just read.
  while #steps > 0 and steps[#steps].kind == "return" do
    steps[#steps] = nil
  end
  return { steps = steps, refs = refs, folded = folded, shadowed = shadowed, max_depth = deepest }
end

-- A cursor over a plan. Walking back up is just stepping backwards: the
-- `return` steps are already in the list.
function M.cursor(plan, index)
  local cursor = { plan = plan, index = index or 1 }
  function cursor:current()
    return self.plan.steps[self.index]
  end
  function cursor:next()
    if self.index < #self.plan.steps then
      self.index = self.index + 1
      return self.plan.steps[self.index]
    end
  end
  function cursor:prev()
    if self.index > 1 then
      self.index = self.index - 1
      return self.plan.steps[self.index]
    end
  end
  function cursor:seek(node, box)
    for i, step in ipairs(self.plan.steps) do
      if step.node == node and (not box or step.box == box) then
        self.index = i
        return step
      end
    end
  end
  return cursor
end

return M
