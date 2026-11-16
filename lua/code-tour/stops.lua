local M = {}
local serial = 0

local function integer(n, low, high)
  return type(n) == "number" and n == math.floor(n) and n >= low and n <= high
end

local function text(value, label)
  assert(type(value) == "string" and value:find("%S"), label .. " requires text")
  return value
end

local function identity(item)
  serial = serial + 1
  item.uid, item.thread = serial, {}
end

-- Explicit caller coordinates are preferred. Older tours can still identify a
-- call when its symbol occurs in the callee title (for example, "bubble").
function M.callsite(call, parent, box)
  local site = call.callsite and vim.deepcopy(call.callsite)
  if site then
    assert(type(site) == "table", "callsite must contain caller coordinates")
    site["end"] = site["end"] or site.start
    assert(integer(site.start, box.start, box["end"])
      and integer(site["end"], site.start, box["end"]), "Call site must stay inside its caller box")
    assert(site.symbol == nil or type(site.symbol) == "string", "Call symbol must be text")
    if site.start_col ~= nil or site.end_col ~= nil then
      local first = vim.api.nvim_buf_get_lines(parent.buf, site.start - 1, site.start, false)[1]
      local last = vim.api.nvim_buf_get_lines(parent.buf, site["end"] - 1, site["end"], false)[1]
      assert(integer(site.start_col, 0, #first) and integer(site.end_col, 0, #last)
        and (site["end"] > site.start or site.end_col > site.start_col), "Invalid call-site columns")
    end
    return site
  end
  local names = {}
  for word in (call.title or ""):gmatch("[%a_][%w_]*") do names[word:lower()] = true end
  local lines = vim.api.nvim_buf_get_lines(parent.buf, box.start - 1, box["end"], false)
  for offset, line in ipairs(lines) do
    local from = 1
    while from <= #line do
      local first, last, expression = line:find("([%a_][%w_%.:]*)%s*%(", from)
      if not first then break end
      local symbol = expression:match("([%a_][%w_]*)$")
      local prefix = line:sub(1, first - 1)
      local definition = prefix:match("%f[%w]function%s*$") or prefix:match("%f[%w]def%s*$")
      if symbol and names[symbol:lower()] and not definition then
        local col = first - 1
        return { start = box.start + offset - 1, ["end"] = box.start + offset - 1,
          start_col = col, end_col = col + #expression, symbol = expression }
      end
      from = last + 1
    end
  end
  return { start = box.start, ["end"] = box["end"] }
end

function M.validate_coverage(stop, parts)
  parts = parts or stop.parts or {}
  if #parts == 0 then return true end
  local ranges = {}
  for _, part in ipairs(parts) do
    assert(integer(part.start, stop.start, stop["end"])
      and integer(part["end"], part.start, stop["end"]), "Subexplanation outside overview")
    ranges[#ranges + 1] = part
  end
  table.sort(ranges, function(a, b) return a.start < b.start end)
  local covered = stop.start - 1
  for _, part in ipairs(ranges) do
    assert(part.start <= covered + 1,
      ("Subexplanations must cover the whole overview; missing lines %d-%d"):format(covered + 1, part.start - 1))
    covered = math.max(covered, part["end"])
  end
  assert(covered == stop["end"],
    ("Subexplanations must cover the whole overview; missing lines %d-%d"):format(covered + 1, stop["end"]))
  return true
end

-- Convert the former watched-file format at the boundary, keeping one internal model.
function M.normalize(input, root)
  if input.snippets then
    local converted = {}
    for _, item in ipairs(input.snippets) do
      local parts = {}
      for _, part in ipairs(item.sections or {}) do
        parts[#parts + 1] =
          { start = part.start_line, ["end"] = part.end_line, note = part.explanation, title = part.title }
      end
      converted[#converted + 1] = {
        file = item.file,
        start = item.start_line,
        ["end"] = item.end_line,
        note = item.overview,
        title = item.title,
        parts = parts,
        example = item.example,
        old = item.old,
      }
    end
    input = converted
  end
  assert(type(input) == "table" and vim.islist(input) and #input > 0, "Expected a nonempty JSON list of stops")
  local result = {}
  root = vim.fs.normalize(root)
  local function normalize(stop, parent_stop, parent_box)
    -- Generation evidence is host-owned; author payloads cannot assert it.
    for key in pairs(stop) do
      if type(key) == "string" and key:sub(1, 1) == "_" then stop[key] = nil end
    end
    stop.byte_range = nil
    -- Parent references are internal; payloads describe branches only through calls.
    stop._parent_stop, stop._parent_box, stop.placeholder = parent_stop, parent_box, nil
    if parent_stop then
      stop.callsite = M.callsite(stop, parent_stop, parent_box)
      -- An overview call with known coordinates belongs after the part that
      -- explains those lines, rather than immediately after the overview.
      if parent_box == parent_stop then
        local best
        for _, part in ipairs(parent_stop.parts) do
          if part.start <= stop.callsite.start and part["end"] >= stop.callsite["end"]
            and (not best or part["end"] - part.start <= best["end"] - best.start) then
            best = part
          end
        end
        stop._parent_box = best or parent_box
      end
    end
    assert(stop.lazy == nil or type(stop.lazy) == "boolean", "lazy must be a boolean")
    assert(not stop.lazy or parent_box, "Only a call branch can be lazy")
    assert(stop.next == nil or type(stop.next) == "boolean", "next must be a boolean")
    assert(not stop.next or parent_box, "Only a call branch can be next")
    assert(not stop.next or not stop.lazy, "Next calls require a prepared explanation")
    assert(stop.ref == nil or type(stop.ref) == "boolean", "ref must be a boolean")
    assert(not stop.ref or parent_box, "Only a call branch can be a ref")
    if stop.lazy then
      assert(not stop.parts or #stop.parts == 0, "Lazy calls must omit parts")
      assert(not stop.calls or #stop.calls == 0, "Lazy calls must omit nested calls")
      stop.note = stop.note or "Expand to explain this call."
    end
    assert(type(stop.file) == "string", "Stop requires a file")
    local path = vim.fs.normalize(stop.file:sub(1, 1) == "/" and stop.file or root .. "/" .. stop.file)
    path = assert(vim.uv.fs_realpath(path), "File does not exist: " .. path)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    local count = vim.api.nvim_buf_line_count(buf)
    assert(
      integer(stop.start, 1, count) and integer(stop["end"], stop.start, count),
      "Invalid stop range: " .. stop.file
    )
    text(stop.note, "Stop")
    assert(stop.title == nil or type(stop.title) == "string", "Title must be text")
    stop.file, stop.path, stop.buf = vim.fs.relpath(root, path) or path, path, buf
    stop.tick = vim.api.nvim_buf_get_changedtick(buf)
    stop.parts = stop.parts or {}
    assert(vim.islist(stop.parts), "Parts must be a list")
    for _, part in ipairs(stop.parts) do
      for key in pairs(part) do
        if type(key) == "string" and key:sub(1, 1) == "_" then part[key] = nil end
      end
      part.byte_range = nil
      assert(
        integer(part.start, stop.start, stop["end"]) and integer(part["end"], part.start, stop["end"]),
        "Part outside stop"
      )
      text(part.note, "Part")
      identity(part)
    end
    M.validate_coverage(stop)
    assert(stop.old == nil or type(stop.old) == "string", "old must be the replaced text")
    stop.example = stop.example or stop.examples
    if stop.example then
      assert(type(stop.example) == "table", "Example must contain input, output and/or values")
      local values = {}
      for line, value in pairs(stop.example.values or {}) do
        assert(integer(tonumber(line), stop.start, stop["end"]), "Example value outside stop")
        assert(
          type(value) == "string"
            or (
              type(value) == "table"
              and type(value.value) == "string"
              and (value.detail == nil or type(value.detail) == "string")
            ),
          "Example value must be text or {value, detail}"
        )
        values[tostring(line)] = value
      end
      if stop.example.values then
        stop.example.values = values
      end
    end
    identity(stop)
    result[#result + 1] = stop
    for _, box in ipairs(M.boxes(stop)) do
      local calls = box.calls or {}
      assert(type(calls) == "table" and vim.islist(calls), "Calls must be a list")
      box.calls = nil
      for _, call in ipairs(calls) do
        assert(type(call) == "table", "Call requires a stop")
        normalize(call, stop, box)
      end
    end
  end
  for _, stop in ipairs(vim.deepcopy(input)) do
    normalize(stop)
  end
  return result
end

function M.boxes(stop)
  local boxes = { stop }
  vim.list_extend(boxes, stop.parts)
  return boxes
end

-- Only source-checked prepared entries may use this path. Ordinary authored
-- normalization above retains its complete-coverage requirement.
function M.hydrate_saved(item, location, entries)
  local source = require("code-tour.source")
  local stop = { title = item.title, path = location.path, file = location.path, buf = location.buf,
    parts = {}, _saved_stop = item, _saved_stop_id = item.id }
  identity(stop)
  for index, entry in ipairs(entries) do
    if entry.capture then
      local box = index == 1 and stop or {}
      if box ~= stop then identity(box); stop.parts[#stop.parts + 1] = box end
      box.start, box["end"] = source.lines(entry.capture.range)
      box.byte_range, box._saved, box._saved_id = vim.deepcopy(entry.capture.range), entry, entry.id
      box.note = entry.status == "ready" and entry.model.note or "Loading explanation…"
      entry.runtime = box
    end
  end
  if not entries[1].capture then
    stop._unlocated = true
    stop.note = "Overview source unavailable"
    stop.start, stop["end"] = stop.parts[1].start, stop.parts[1]["end"]
  end
  return stop
end

function M.first_box(stop)
  for index, box in ipairs(M.boxes(stop)) do
    if not box._unlocated then return index end
  end
  return 1
end

function M.note(box)
  return require("code-tour.saved").note(box)
end

function M.roots(items)
  return vim.tbl_filter(function(stop) return not stop._parent_stop end, items)
end

-- The main tour has one position per top-level snippet. Method branches and
-- explanation parts belong to that snippet, regardless of flat storage IDs.
function M.snippet_position(items, stop)
  local root = stop
  while root and root._parent_stop do root = root._parent_stop end
  local index, total
  total = 0
  for _, item in ipairs(items) do
    if not item._parent_stop and M.ready(item) then
      total = total + 1
      if item == root then index = total end
    end
  end
  return index, total
end

function M.calls(items, box)
  return vim.tbl_filter(function(stop) return stop._parent_box == box end, items)
end

function M.calls_in(items, stop, box, ready_only)
  return vim.tbl_filter(function(call)
    local site = call.callsite
    return not box._unlocated and (not box._saved or box._saved.status == "ready")
      and call._parent_stop == stop and site and site.start >= box.start and site["end"] <= box["end"]
      and (not ready_only or M.ready(call))
  end, items)
end

function M.ready(call)
  if call._saved_stop then
    local located = false
    for _, box in ipairs(M.boxes(call)) do if not box._unlocated then located = true end end
    if not located then return false end
  end
  return not call.lazy and not call.placeholder
end

-- Gold calls join the reading order after their owning explanation, then return
-- to its following box. Red calls remain optional, scoped inspections.
function M.level_route(items, scope)
  local result, children = {}, {}
  for i, call in ipairs(items) do
    if call._parent_box and call.callsite and call.next and M.ready(call)
      and (not call._parent_box._saved or call._parent_box._saved.status == "ready") then
      children[call._parent_box] = children[call._parent_box] or {}
      table.insert(children[call._parent_box], i)
    end
  end
  local function visit(i)
    for k, box in ipairs(M.boxes(items[i])) do
      if not box._unlocated then result[#result + 1] = { stop = i, box = k } end
      for _, child in ipairs(children[box] or {}) do visit(child) end
    end
  end
  for i, stop in ipairs(items) do
    if (scope and stop == scope) or (not scope and not stop._parent_stop) then visit(i) end
  end
  return result
end

-- The snippet picker enumerates nested definitions. Box navigation uses only
-- level_route; choosing a method with ad saves a separate return frame.
function M.route(items)
  local children, result = {}, {}
  for i, stop in ipairs(items) do
    if stop._parent_box then
      children[stop._parent_box] = children[stop._parent_box] or {}
      table.insert(children[stop._parent_box], i)
    end
  end
  local function visit(i)
    local stop = items[i]
    if not M.ready(stop) then return end
    for k, box in ipairs(M.boxes(stop)) do
      if not box._unlocated then result[#result + 1] = { stop = i, box = k } end
      for _, child in ipairs(children[box] or {}) do visit(child) end
    end
  end
  for i, stop in ipairs(items) do
    if not stop._parent_stop then visit(i) end
  end
  return result
end

function M.example_range(example, first, last)
  local result = vim.deepcopy(example)
  result.values = {}
  for line, value in pairs(example.values or {}) do
    if tonumber(line) >= first and tonumber(line) <= last then
      result.values[line] = vim.deepcopy(value)
    end
  end
  return result
end

-- Snapshots contain object references, not indexes: insertions cannot retarget replies.
function M.snapshot(stops)
  local result = {}
  for i, stop in ipairs(stops) do
    result[i] = { stop = stop, boxes = M.boxes(stop) }
  end
  return result
end

function M.outline(stops)
  local lines = {}
  for i, stop in ipairs(stops) do
    lines[#lines + 1] = ("%d. %s — %s:%d-%d"):format(i, stop.title or "Snippet", stop.file, stop.start, stop["end"])
    if stop._parent_box then
      for parent_i, parent in ipairs(stops) do
        if parent == stop._parent_stop then
          for k, box in ipairs(M.boxes(parent)) do
            if box == stop._parent_box then
              lines[#lines + 1] = ("  Call from %d.%d%s; %s.")
                :format(parent_i, k, stop.lazy and " (lazy)" or "",
                  stop.next and "next snippet; continue to its following box" or "optional; return to the same box")
            end
          end
        end
      end
    end
    for k, box in ipairs(M.boxes(stop)) do
      lines[#lines + 1] = ("  %d.%d %d-%d %s"):format(i, k, box.start, box["end"], M.note(box):gsub("\n", " "))
    end
  end
  return table.concat(lines, "\n")
end

return M
