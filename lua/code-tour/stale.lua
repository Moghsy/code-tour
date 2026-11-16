-- Find explanations whose source changed, and the explanations linked to them,
-- by walking the tour graph (see graph.lua). Only saved tours track freshness.
local M = {}

-- Returns a list of { id, saved_id, status, reason, file, start, end, update_also = { ... } }.
-- Each update_also item names a box whose prose depends on the stale one:
--   overview / parent (summarise the stale part; the overview is the root of the
--   snippet's part tree), caller (calls into the stale code,
--   directly or through any chain of callers, including snippets that merely
--   overlap it), callee (calls made from the stale box: verify their call sites).
function M.collect(graph)
  local node_of, ref = {}, {}
  for _, node in ipairs(graph.nodes) do
    node_of[node.id] = node
    for _, box in ipairs(node.boxes) do
      ref[box.id] = { node = node, box = box }
    end
  end
  local incoming, outgoing, overlaps = {}, {}, {}
  for _, link in ipairs(graph.links) do
    if link.via == "call" then
      incoming[link.target] = incoming[link.target] or {}
      table.insert(incoming[link.target], link)
      outgoing[link.from_box] = outgoing[link.from_box] or {}
      table.insert(outgoing[link.from_box], link)
    elseif link.relation == "overlaps" then
      overlaps[link.source] = overlaps[link.source] or {}
      table.insert(overlaps[link.source], link.target)
      overlaps[link.target] = overlaps[link.target] or {}
      table.insert(overlaps[link.target], link.source)
    end
  end
  local result = {}
  for _, node in ipairs(graph.nodes) do
    for _, box in ipairs(node.boxes) do
      if box.stale then
        local item = {
          id = box.id,
          saved_id = box.saved_id,
          status = box.status,
          file = node.source_file,
          start = box.start,
          ["end"] = box["end"],
          update_also = {},
        }
        local seen = { [box.id] = true }
        local function add(target, relation)
          if not target or seen[target.id] then
            return
          end
          seen[target.id] = true
          item.update_also[#item.update_also + 1] = {
            id = target.id,
            saved_id = target.saved_id,
            relation = relation,
            stale = target.stale,
            file = (ref[target.id] or {}).node and ref[target.id].node.source_file,
            start = target.start,
            ["end"] = target["end"],
          }
        end
        -- Every box above this one in the snippet's tree summarises it: its parent parts
        -- and, at the top, the overview.
        local up = box.parent and ref[box.parent]
        while up do
          add(up.box, up.box.role == "overview" and "overview" or "parent")
          up = up.box.parent and ref[up.box.parent]
        end
        -- Callers, transitively; start from this snippet and anything overlapping it.
        local queue, visited = { node.id }, { [node.id] = true }
        for _, id in ipairs(overlaps[node.id] or {}) do
          if not visited[id] then
            visited[id] = true
            queue[#queue + 1] = id
          end
        end
        local head = 1
        while head <= #queue do
          local id = queue[head]
          head = head + 1
          for _, link in ipairs(incoming[id] or {}) do
            local caller = ref[link.from_box]
            if caller then
              add(caller.box, "caller")
              if not visited[caller.node.id] then
                visited[caller.node.id] = true
                queue[#queue + 1] = caller.node.id
              end
            end
          end
        end
        for _, link in ipairs(outgoing[box.id] or {}) do
          local callee = node_of[link.target]
          for _, other in ipairs(callee and callee.boxes or {}) do
            if other.role == "overview" then
              add(other, "callee")
              break
            end
          end
        end
        result[#result + 1] = item
      end
    end
  end
  return result
end

-- Short line for requests: "Stale: 2.1, 3.2 · report: PATH" (nil when nothing is stale).
function M.summary(items, path)
  if #items == 0 then
    return nil
  end
  local ids = {}
  for _, item in ipairs(items) do
    ids[#ids + 1] = item.id
  end
  return "Stale: " .. table.concat(ids, ", ") .. " · report: " .. path
end

-- Keep a JSON report outside the library so the agent can read exact ranges and links.
function M.write(items, path, tour)
  if #items == 0 then
    vim.uv.fs_unlink(path)
    return
  end
  vim.fn.writefile({ vim.json.encode({ tour = tour, stale = items }) }, path)
end

return M
