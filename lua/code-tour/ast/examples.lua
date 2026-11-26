-- Test discovery and deterministic example selection (§12).
local route = require("code-tour.ast.route")
local deadline = require("code-tour.ast.deadline")
local M = {}

local function is_test(sym, owner)
  if sym.kind ~= "method" and sym.kind ~= "function" then return false end
  if sym.test then return true end
  for _, annotation in ipairs(sym.annotations or {}) do
    local name = annotation:match("[^.]+$")
    if name == "Test" or name == "ParameterizedTest" or name == "RepeatedTest" then return true end
  end
  return sym.file:match("^tests?/") or sym.file:match("/tests?/")
    or (owner and owner.name and owner.name:match("Tests?$"))
    or (sym.id:match("^python:") and sym.name:match("^test_"))
end

-- `pause` is called between units of work: a background build yields there.
local function build(idx, pause)
  local candidates = {}
  for _, file in ipairs(idx:grep("@.*(Test|ParameterizedTest|RepeatedTest)|class[[:space:]]+[[:alnum:]_]+Tests?")) do
    candidates[file] = true
  end
  local count = 0
  for _, file in ipairs(idx.files) do
    local base = vim.fs.basename(file)
    if candidates[file] or file:match("^tests?/") or file:match("/tests?/")
        or base:match("Tests?%.java$") or base:match("^test_.*%.py$") or base:match("_test%.py$")
        or base:match("%.test%.[mc]?[tj]sx?$") or base:match("%.spec%.[mc]?[tj]sx?$") or file:match("__tests__/") then
      pause()
      idx:facts(file)
      count = count + 1
      if count >= idx.max_files then break end
    end
  end
  local rt = route.new(idx)
  local tests, reached = {}, {}
  -- distance over resolved calls (a fact about the graph, not a judgement of importance)
  local function main_path(id)
    if reached[id] then return reached[id] end
    local dist, queue, head = { [id] = { depth = 0 } }, { id }, 1
    while head <= #queue do
      local at = queue[head]
      head = head + 1
      if dist[at].depth < 4 then
        pause()
        local body = rt:body(at)
        for _, site in ipairs(body and body.sites or {}) do
          for _, t in ipairs(site.targets or {}) do
            if not dist[t.symbol] then
              dist[t.symbol] = { depth = dist[at].depth + 1 }
              queue[#queue + 1] = t.symbol
            end
          end
        end
      end
    end
    reached[id] = dist
    return dist
  end
  local ids = vim.tbl_keys(idx.symbols)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local sym = idx.symbols[id]
    if is_test(sym, sym.owner and idx:symbol(sym.owner)) then
      pause()
      local body = rt:body(id)
      if body then
        local targets, assertions = {}, 0
        for _, site in ipairs(body.sites) do
          if (site.name or site.text):match("^assert") then assertions = assertions + 1 end
          for _, target in ipairs(site.targets or {}) do targets[target.symbol] = 1 end
          if site.declared then targets[site.declared.symbol] = 1 end
        end
        local direct = vim.tbl_keys(targets)
        local function extend(entry, initial_depth)
          for target, node in pairs(main_path(entry)) do
            if target ~= id then targets[target] = math.min(targets[target] or math.huge, initial_depth + node.depth) end
          end
        end
        extend(id, 0)
        for _, target in ipairs(direct) do extend(target, 1) end
        local first, last = require("code-tour.ast.outline").lines_of(sym.range)
        tests[#tests + 1] = { id = id, label = sym.label, file = sym.file, lines = { first, last },
          assertions = assertions, targets = targets }
      end
    end
  end
  return tests
end

local function catalog(idx)
  if not idx.example_catalog then
    idx.example_catalog = build(idx, deadline.check)
  end
  return idx.example_catalog
end

function M.ready(idx)
  return idx.example_catalog ~= nil
end

local slice_ns = 10e6

-- Build the catalog without blocking the editor: in slices of about 10 ms, with input and RPC
-- handled between them. `done` runs when it is ready, if `alive()` still holds. The build is
-- dropped once nobody waiting for it is alive. Returns the job (also `idx.example_job`).
function M.prepare(idx, alive, done)
  local waiter = { alive = alive, done = done }
  if idx.example_job then
    table.insert(idx.example_job.waiting, waiter)
    return idx.example_job
  end
  local job = { waiting = { waiter } }
  idx.example_job = job
  local slice_end
  local co = coroutine.create(function()
    return build(idx, function()
      if vim.uv.hrtime() >= slice_end then coroutine.yield() end
    end)
  end)
  local function step()
    if idx.example_job ~= job then return end
    job.waiting = vim.tbl_filter(function(w) return w.alive() end, job.waiting)
    if #job.waiting == 0 then
      idx.example_job = nil
      return
    end
    -- a synchronous caller may have built it meanwhile
    if not idx.example_catalog then
      slice_end = vim.uv.hrtime() + slice_ns
      local ok, result = coroutine.resume(co)
      if not ok then
        idx.example_job = nil
        vim.notify("code-tour: test examples unavailable: " .. tostring(result), vim.log.levels.WARN)
        return
      end
      if coroutine.status(co) ~= "dead" then
        vim.defer_fn(step, 5)
        return
      end
      idx.example_catalog = result
    end
    idx.example_job = nil
    for _, w in ipairs(job.waiting) do
      w.done()
    end
  end
  vim.defer_fn(step, 5)
  return job
end

function M.tests(idx, targets, max_depth)
  local out = {}
  for _, test in ipairs(catalog(idx)) do
    local distance = math.huge
    for _, target in ipairs(targets) do distance = math.min(distance, test.targets[target] or math.huge) end
    if distance < math.huge and (not max_depth or distance <= max_depth) then
      out[#out + 1] = { id = test.id, label = test.label, file = test.file, lines = test.lines,
        distance = distance, assertions = test.assertions }
    end
  end
  table.sort(out, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.assertions ~= b.assertions then return a.assertions > b.assertions end
    return a.id < b.id
  end)
  return out
end

function M.snippet(test)
  return { kind = "example", title = test.label, file = test.file, start = test.lines[1], ["end"] = test.lines[2],
    why = "example: test", note = "Test example · " .. test.label, example = { source = "test", test = test.id } }
end

return M
