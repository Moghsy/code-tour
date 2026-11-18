-- Projection of the live tour into a graph: one node per snippet, edges for the
-- reading route (`next`) and optional detours (`optional`). The output is
-- NetworkX node-link JSON, the shape graphify uses, so the two can be merged.
-- The tour tree stays the source of truth; nothing here is ever read back.
local stops = require("code-tour.stops")
local M = {}

local function key(stop)
  return ("%s:%d-%d"):format(stop.path, stop.start, stop["end"])
end

M.key = key

-- id_of(stop, box) -> "S.K" request box ID.
function M.build(state, id_of, tour)
  local nodes, by_key, stop_node = {}, {}, {}
  for i, stop in ipairs(state.stops) do
    if (not stop.placeholder or stop.stream) and stop.path then
      local id = key(stop)
      local node = by_key[id]
      if not node then
        node = {
          id = id,
          label = stop.title or "Snippet",
          source_file = stop.path,
          source_location = ("L%d-%d"):format(stop.start, stop["end"]),
          file_type = "code-tour",
          start = stop.start,
          ["end"] = stop["end"],
          lazy = true,
          pending = true,
          stops = {},
          boxes = {},
        }
        by_key[id] = node
        nodes[#nodes + 1] = node
      end
      node.lazy = node.lazy and stop.lazy or false
      node.root = node.root or not stop._parent_stop
      node.pending = node.pending and stop.stream == true
      node.stops[#node.stops + 1] = i
      stop_node[stop] = node
      for k, box in ipairs(stops.boxes(stop)) do
        local status = box._saved and box._saved.status
        node.boxes[#node.boxes + 1] = {
          id = id_of(stop, box),
          stop = i,
          role = k == 1 and "overview" or "part",
          -- Parts form a tree inside the snippet: the parent is the box this one refines.
          parent = k > 1 and id_of(stop, box._parent_part or stop) or nil,
          depth = k > 1 and (box._depth or 1) or 0,
          start = box.start,
          ["end"] = box["end"],
          saved_id = box._saved and box._saved.id or nil,
          status = status,
          stale = (status == "source_changed" or status == "unresolved") or nil,
        }
      end
    end
  end
  local links, seen = {}, {}
  local function link(from, to, relation, extra)
    local dedupe = table.concat({ from, to, relation, extra.from_box or "", extra.label or "" }, "|")
    if seen[dedupe] then
      return
    end
    seen[dedupe] = true
    links[#links + 1] = vim.tbl_extend("force", { source = from, target = to, relation = relation, confidence = "EXTRACTED" }, extra)
  end
  -- Call edges: caller snippet -> callee snippet, from the exact caller box.
  for _, stop in ipairs(state.stops) do
    local to, from = stop_node[stop], stop._parent_stop and stop_node[stop._parent_stop]
    if to and from and stop._parent_box then
      local site = stop.callsite
      link(from.id, to.id, stop.next and "next" or "optional", {
        via = "call",
        ref = stop.ref or nil,
        level = stop.level,
        from_box = id_of(stop._parent_stop, stop._parent_box),
        symbol = site and site.symbol or nil,
        callsite = site and { start = site.start, ["end"] = site["end"], start_col = site.start_col, end_col = site.end_col } or nil,
      })
    end
  end
  if state.machine then
    -- With a machine, its transitions are the route and consecutive snippets are not.
    M.machine_links(state, stop_node, link, id_of)
  else
    -- The main route: consecutive top-level snippets.
    local previous
    for _, stop in ipairs(stops.roots(state.stops)) do
      local node = stop_node[stop]
      if node then
        if previous and previous ~= node then
          link(previous.id, node.id, "next", { via = "sequence" })
        end
        previous = node
      end
    end
  end
  -- Different snippets that cover some of the same lines (stale code affects both).
  for a = 1, #nodes do
    for b = a + 1, #nodes do
      local x, y = nodes[a], nodes[b]
      if x.source_file == y.source_file and x.start <= y["end"] and y.start <= x["end"] then
        link(x.id, y.id, "overlaps", { via = "range" })
      end
    end
  end
  local start
  if state.machine then
    local machine = state.machine
    start = M.machine_node(state, stop_node, machine.start)
  end
  return { directed = true, multigraph = false, graph = { kind = "code-tour", tour = tour, start = start and start.id or nil }, nodes = nodes, links = links }
end

-- The graph node of a state, following states with no code (they only route) to the
-- next state that has some. nil when the chain never reaches a snippet.
function M.machine_node(state, stop_node, id, seen)
  local machine = state.machine
  seen = seen or {}
  if seen[id] then return nil end
  seen[id] = true
  local item = machine.by_id[id]
  for _, candidate in ipairs(state.stops) do
    if item.stop and candidate.id == item.stop then return stop_node[candidate] end
  end
  local happy = item.next
  for _, outcome in ipairs(item.on and item.on.outcomes or {}) do
    if outcome.happy then happy = outcome.to end
  end
  return happy and M.machine_node(state, stop_node, happy, seen) or nil
end

-- Edges of the machine: the happy transition of each state is a `next` link (walked, like
-- the sequence of a plain tour); everything else is `optional` and left to the reader.
function M.machine_links(state, stop_node, link, id_of)
  local machine = require("code-tour.machine")
  local list = state.machine
  local function stop_of(id)
    for _, stop in ipairs(state.stops) do
      if stop.id == id then return stop end
    end
  end
  local function last_box(item)
    local stop = item.stop and stop_of(item.stop)
    local last
    for _, step in ipairs(item.steps) do
      if step.part then last = step.part end
    end
    if not stop then return nil end
    for _, box in ipairs(stops.boxes(stop)) do
      if last and box.id == last then return id_of(stop, box) end
    end
    return id_of(stop, stop)
  end
  for _, item in ipairs(list.states) do
    local from = M.machine_node(state, stop_node, item.id)
    if from and item.stop then
      for _, edge in ipairs(machine.edges(list, item)) do
        local to = M.machine_node(state, stop_node, edge.target)
        if to then
          local happy = edge.happy
          local kind = happy and "transition" or (edge.loop and "loop" or (edge.exit and "exit" or "branch"))
          link(from.id, to.id, happy and "next" or "optional", {
            via = "machine", kind = kind, label = edge.label, guard = edge.guard,
            from_box = (not happy) and last_box(item) or nil,
          })
        end
      end
      for _, step in ipairs(item.steps) do
        local prompt = step.prompt and stop_of(step.prompt)
        local to = prompt and stop_node[prompt]
        if to and to ~= from then
          link(from.id, to.id, "optional", { via = "machine", kind = "prompt", label = step.name, from_box = last_box(item) })
        end
      end
    end
  end
  local start = M.machine_node(state, stop_node, list.start)
  for _, item in ipairs(list.catch) do
    local to = M.machine_node(state, stop_node, item.to)
    if start and to then link(start.id, to.id, "optional", { via = "machine", kind = "catch", label = "catch " .. item.error }) end
  end
  local abort = list.on_abort and M.machine_node(state, stop_node, list.on_abort)
  if start and abort then link(start.id, abort.id, "optional", { via = "machine", kind = "abort", label = "on abort" }) end
end

function M.write(graph, path)
  vim.fn.writefile({ vim.json.encode(graph) }, path)
  return path
end

return M
