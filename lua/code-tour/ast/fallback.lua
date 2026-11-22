local M = {}

local function read(idx, file)
  local buf = vim.fn.bufnr(idx:abs(file))
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  if vim.fn.filereadable(idx:abs(file)) == 1 then
    return vim.fn.readfile(idx:abs(file))
  end
end

local function valid(first, last, low, high)
  return type(first) == "number" and first % 1 == 0 and first >= low
    and type(last) == "number" and last % 1 == 0 and last >= first and last <= high
end

local function fingerprint(lines, first, last)
  return vim.fn.sha256(table.concat(lines, "\n", first, last))
end

function M.normalize(idx, input)
  if type(input.file) ~= "string" then
    return nil, "--add requires a file"
  end
  local file = idx:rel(vim.fs.normalize(idx.root .. "/" .. input.file))
  if input.file:sub(1, 1) == "/" then
    file = idx:rel(input.file)
  end
  if file:sub(1, 1) == "/" then
    return nil, "--add file must be in the project"
  end
  local lines = read(idx, file)
  if not lines or not valid(input.start, input["end"], 1, #lines) then
    return nil, "--add requires a valid file range"
  end
  local first, last = input.start, input["end"]
  local fp = fingerprint(lines, first, last)
  local spec = { file = file, start = first, size = last - first + 1, fingerprint = fp,
    id = "agent:" .. file .. ":" .. fp, label = input.label or vim.fs.basename(file), regions = {}, sites = {} }
  if type(spec.label) ~= "string" or (input.regions ~= nil and not vim.islist(input.regions))
      or (input.sites ~= nil and not vim.islist(input.sites)) then
    return nil, "--add expects a string label and arrays of regions and sites"
  end
  local previous = first - 1
  for _, region in ipairs(input.regions or {}) do
    if type(region) ~= "table" or not valid(region.start, region["end"], previous + 1, last) then
      return nil, "--add regions must be consecutive, nonoverlapping ranges inside the snippet"
    end
    spec.regions[#spec.regions + 1] = { first = region.start - first, last = region["end"] - first,
      fingerprint = fingerprint(lines, region.start, region["end"]) }
    previous = region["end"]
  end
  for _, site in ipairs(input.sites or {}) do
    if type(site) ~= "table" or type(site.text) ~= "string" or site.text == ""
        or not valid(site.line, site.line, first, last) or (site.target ~= nil and type(site.target) ~= "string") then
      return nil, "--add requires site text and a line inside the snippet"
    end
    local col = lines[site.line]:find(site.text, 1, true)
    if not col then
      return nil, "--add site text was not found on line " .. site.line
    end
    spec.sites[#spec.sites + 1] = { text = site.text, offset = site.line - first, col = col - 1,
      target = site.target }
  end
  table.sort(spec.sites, function(a, b)
    return a.offset < b.offset or (a.offset == b.offset and a.col < b.col)
  end)
  return spec
end

local function range(lines, first, last)
  return { start = { first - 1, 0 }, ["end"] = { last - 1, #lines[last] } }
end

function M.register(rt, spec)
  local idx = rt.idx
  local lines = read(idx, spec.file) or {}
  local first = spec.start
  if first + spec.size - 1 > #lines or fingerprint(lines, first, first + spec.size - 1) ~= spec.fingerprint then
    first = nil
    for at = 1, #lines - spec.size + 1 do
      if fingerprint(lines, at, at + spec.size - 1) == spec.fingerprint then
        if first then
          return nil, "agent range is ambiguous in " .. spec.file
        end
        first = at
      end
    end
    if not first then
      return nil, "agent range changed in " .. spec.file
    end
  end
  local sym = { id = spec.id, file = spec.file, name = spec.label, label = spec.label, kind = "method",
    source = "agent", params = {}, range = range(lines, first, first + spec.size - 1), agent_regions = {} }
  for _, region in ipairs(spec.regions) do
    sym.agent_regions[#sym.agent_regions + 1] = { address = "agent:" .. spec.file .. ":" .. region.fingerprint,
      range = range(lines, first + region.first, first + region.last) }
  end
  local body = { id = sym.id, sites = {}, locals = {}, stmts = {}, field_writes = {},
    metrics = { lines = spec.size, statements = 0, branches = 0, loops = 0, sites = 0,
      project_sites = 0, field_writes = 0, throws = 0 } }
  for _, site in ipairs(spec.sites) do
    local row = first + site.offset - 1
    local ids = site.target and rt:resolve_entry(site.target)
    local target = ids and #ids == 1 and ids[1] or nil
    body.sites[#body.sites + 1] = { id = "s" .. (#body.sites + 1), name = site.text, kind = "call", text = site.text,
      at = { row, site.col }, range = { start = { row, site.col }, ["end"] = { row, site.col + #site.text } },
      targets = target and { { symbol = target, confidence = "INFERRED", source = "agent", via = "agent" } } or {},
      unresolved = not target and "agent" or nil }
  end
  body.metrics.sites = #body.sites
  body.metrics.project_sites = vim.tbl_count(vim.tbl_filter(function(site) return #site.targets > 0 end, body.sites))
  idx.symbols[sym.id] = sym
  rt.agent_bodies = rt.agent_bodies or {}
  rt.agent_bodies[sym.id] = body
  return true
end

return M
