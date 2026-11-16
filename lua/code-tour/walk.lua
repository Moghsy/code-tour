-- Depth-first reading order over the tour graph (see graph.lua).
--
-- plan(graph) validates that the tour is a DAG and returns a flat list of steps.
-- Each step shows one box of one snippet. A snippet's boxes are read in order.
-- Edges leave from the box that makes the call. Every edge is walked in turn and,
-- when more edges remain on that box, a `return` step brings the reader back to
-- it before the next edge. After the last edge there is nothing to choose, so the
-- reader carries straight on with the next box (or finishes the snippet).
--
-- An edge becomes a reference (never walked) when:
--   * it is marked `ref` (recursion the author already broke), or
--   * its target was already walked (a shared node in a diamond).
-- An unmarked edge back to a snippet on the current path is a cycle: an error.
local M = {}

local MAX_DEPTH = 128

local function out_edges(graph)
  local by_node = {}
  for index, link in ipairs(graph.links) do
    if link.relation == "next" or link.relation == "optional" then
      local list = by_node[link.source] or {}
      by_node[link.source] = list
      list[#list + 1] = { link = link, order = index }
    end
  end
  return by_node
end

-- Returns { steps = {...}, refs = {...} } or nil, error.
-- step = { node, box, kind = "root" | "enter" | "box" | "return", via? }
function M.plan(graph)
  local nodes = {}
  for _, node in ipairs(graph.nodes) do
    nodes[node.id] = node
  end
  local edges = out_edges(graph)
  local steps, refs = {}, {}
  local state, path = {}, {}

  local function boxes_of(node)
    local first = node.stops[1]
    return vim.tbl_filter(function(box)
      return box.stop == first
    end, node.boxes)
  end

  local visit
  visit = function(id, kind, via)
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
        if item.link.ref then
          refs[#refs + 1] = { from = id, to = target, why = "marked" }
        elseif state[target] == "active" then
          local cycle = {}
          local started
          for _, step in ipairs(path) do
            started = started or step == target
            if started then
              cycle[#cycle + 1] = nodes[step].label
            end
          end
          cycle[#cycle + 1] = nodes[target].label
          return nil, "Tour has a cycle: " .. table.concat(cycle, " → ") .. ". Mark the closing edge as ref."
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
          local ok, problem = visit(item.link.target, "enter", item.link)
          if not ok then
            return nil, problem
          end
          -- Come back only while another edge on this box is still to be walked.
          local more = false
          for j = i + 1, #walk do
            more = more or not state[walk[j].link.target]
          end
          if more then
            steps[#steps + 1] = { node = id, box = box.id, kind = "return" }
          end
        end
      end
      return true
    end
    steps[#steps + 1] = { node = id, box = boxes[1].id, kind = kind, via = via and { source = via.source, relation = via.relation, symbol = via.symbol } or nil }
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

  -- Start at each snippet no walked edge reaches, in authored order.
  local targeted = {}
  for _, list in pairs(edges) do
    for _, item in ipairs(list) do
      if not item.link.ref then
        targeted[item.link.target] = true
      end
    end
  end
  for _, node in ipairs(graph.nodes) do
    if not state[node.id] and not targeted[node.id] then
      local ok, err = visit(node.id, "root")
      if not ok then
        return nil, err
      end
    end
  end
  -- Anything left is only reachable through a cycle of unmarked edges.
  for _, node in ipairs(graph.nodes) do
    if not state[node.id] then
      local ok, err = visit(node.id, "root")
      if not ok then
        return nil, err
      end
    end
  end
  return { steps = steps, refs = refs }
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
