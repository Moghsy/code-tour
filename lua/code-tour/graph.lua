-- Projection of the live tour into a graph: one node per snippet, edges for the
-- reading route (`next`) and optional detours (`optional`). The output is
-- NetworkX node-link JSON, the shape graphify uses, so the two can be merged.
-- The tour tree stays the source of truth; nothing here is ever read back.
local stops = require("code-tour.stops")
local M = {}

local function key(stop)
  return ("%s:%d-%d"):format(stop.path, stop.start, stop["end"])
end

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
    local dedupe = table.concat({ from, to, relation, extra.from_box or "" }, "|")
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
        spine = stop.spine or nil,
        from_box = id_of(stop._parent_stop, stop._parent_box),
        symbol = site and site.symbol or nil,
        callsite = site and { start = site.start, ["end"] = site["end"], start_col = site.start_col, end_col = site.end_col } or nil,
      })
    end
  end
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
  -- Different snippets that cover some of the same lines (stale code affects both).
  for a = 1, #nodes do
    for b = a + 1, #nodes do
      local x, y = nodes[a], nodes[b]
      if x.source_file == y.source_file and x.start <= y["end"] and y.start <= x["end"] then
        link(x.id, y.id, "overlaps", { via = "range" })
      end
    end
  end
  return { directed = true, multigraph = false, graph = { kind = "code-tour", tour = tour }, nodes = nodes, links = links }
end

function M.write(graph, path)
  vim.fn.writefile({ vim.json.encode(graph) }, path)
  return path
end

return M
