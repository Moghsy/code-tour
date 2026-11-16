-- Find explanations whose source changed, and the explanations linked to them.
-- Only saved tours track freshness; boxes without a saved entry are never stale.
local stops = require("code-tour.stops")
local M = {}

local function overlaps(a, b)
  return a.path ~= nil and a.path == b.path and a.start <= b["end"] and b.start <= a["end"]
end

local function flagged(box)
  local status = box._saved and box._saved.status
  return status == "source_changed" or status == "unresolved"
end

-- Returns a list of { id, saved_id, status, reason, file, start, end, update_also = { ... } }.
-- Each update_also item names a box whose prose depends on the stale one:
--   overview (summarises the stale part), caller (calls into the stale code, on the
--   caller chain or from any other snippet whose callee overlaps it), callee (calls
--   made by the stale box: verify their call sites).
function M.collect(state, id_of)
  local result = {}
  for _, stop in ipairs(state.stops) do
    for _, box in ipairs(stops.boxes(stop)) do
      if flagged(box) then
        local item = {
          id = id_of(stop, box),
          saved_id = box._saved.id,
          status = box._saved.status,
          reason = box._saved.reason,
          file = stop.file,
          start = box.start,
          ["end"] = box["end"],
          update_also = {},
        }
        local seen = { [box] = true }
        local function add(s, b, relation)
          if not s or not b or seen[b] then
            return
          end
          seen[b] = true
          item.update_also[#item.update_also + 1] = {
            id = id_of(s, b),
            saved_id = b._saved and b._saved.id or nil,
            relation = relation,
            stale = flagged(b) or nil,
            file = s.file,
            start = b.start,
            ["end"] = b["end"],
          }
        end
        if box ~= stop then
          add(stop, stop, "overview")
        end
        -- Whoever called into this snippet, all the way up the call chain.
        local parent_stop, parent_box = stop._parent_stop, stop._parent_box
        while parent_stop and parent_box do
          add(parent_stop, parent_box, "caller")
          parent_stop, parent_box = parent_stop._parent_stop, parent_stop._parent_box
        end
        -- Other snippets whose called definition covers the stale code.
        for _, other in ipairs(state.stops) do
          if other ~= stop and other._parent_stop and other._parent_box and overlaps(other, box) then
            add(other._parent_stop, other._parent_box, "caller")
          end
        end
        for _, call in ipairs(stops.calls(state.stops, box)) do
          add(call, call, "callee")
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

-- Keep a JSON report beside the tour file so the agent can read exact ranges and links.
function M.write(items, path, tour)
  if #items == 0 then
    vim.uv.fs_unlink(path)
    return
  end
  vim.fn.writefile({ vim.json.encode({ tour = tour, stale = items }) }, path)
end

return M
