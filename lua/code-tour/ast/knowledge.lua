-- Read and write current AST knowledge without opening a tour (§13).
local ast = require("code-tour.ast")
local outline = require("code-tour.ast.outline")
local route = require("code-tour.ast.route")

local M = {}

local function resolve(idx, spec)
  local ids, err = route.new(idx):resolve_entry(spec)
  if not ids then
    error(err, 0)
  end
  return ids
end

local function live_for(opts)
  local live, err = require("code-tour.ast.live").new({
    entries = { opts.symbol },
    detail = opts.detail,
    root = opts.root,
    through = opts.through,
    overrides = opts.overrides,
  })
  if not live then
    error(err, 0)
  end
  return live
end

local function box(live, sn, region, gist_only)
  local address = region and region.address or sn.symbol
  local result = { id = region and region.id or "overview", address = address }
  local found, status, reason = live:lookup(sn, region)
  if found then
    result.gist = found.gist
    if not gist_only then
      result.body = found.body
      result.level = found.level
      result.example = found.note and found.note.example
    end
  elseif status == "stale" then
    result.stale = reason or "code changed"
  else
    result.missing = true
  end
  return result
end

local function collect_boxes(live, sn, gist_only)
  local boxes = { box(live, sn, nil, gist_only) }
  for _, region in ipairs(sn.regions) do
    boxes[#boxes + 1] = box(live, sn, region, gist_only)
  end
  return boxes
end

local function tests_for(idx, ids)
  return require("code-tour.ast.examples").tests(idx, ids)
end

local function explain(opts)
  local live = live_for(opts)
  local items, stale = {}, {}
  for _, sn in ipairs(live.tour.snippets) do
    if sn.depth == 0 then
      local boxes = collect_boxes(live, sn)
      for _, item in ipairs(boxes) do
        if item.stale then
          stale[#stale + 1] = { address = item.address, reason = item.stale }
        end
      end
      items[#items + 1] = { id = sn.n, symbol = sn.symbol, label = sn.label, file = sn.file,
        lines = sn.lines, boxes = boxes, tests = tests_for(live.idx, { sn.symbol }) }
    end
  end
  return { root = live.root, detail = live.detail, symbols = items, stale = stale }
end

local function flow(opts)
  local live = live_for(opts)
  local tour = outline.data(live.tour)
  local main, snippets = {}, {}
  for i, sn in ipairs(live.tour.snippets) do
    if sn.main then
      local item = tour.snippets[i]
      item.boxes = collect_boxes(live, sn, true)
      main[sn.n] = true
      snippets[#snippets + 1] = item
    end
  end
  for _, sn in ipairs(snippets) do
    for _, site in ipairs(sn.sites) do
      if site.to and not main[site.to] then
        site.to, site.mode, site.why = nil, "lazy", "off main flow"
      end
    end
    if not opts.json then
      sn._lines = outline.snippet_lines(sn, function() return "" end)
    end
  end
  tour.root = live.root
  tour.snippets = snippets
  tour.route = vim.tbl_filter(function(edge)
    return edge.main and main[edge.from.n] and (not edge.to or main[edge.to])
  end, tour.route)
  return tour
end

local function call_graph(idx)
  idx:scan()
  local incoming, outgoing = {}, {}
  for _, file in ipairs(idx.files) do
    if idx.loaded[file] then
      for _, edge in ipairs(idx.resolver:edges(file)) do
        if edge.relation == "calls" then
          incoming[edge.target] = incoming[edge.target] or {}
          outgoing[edge.source] = outgoing[edge.source] or {}
          table.insert(incoming[edge.target], edge)
          table.insert(outgoing[edge.source], edge)
        end
      end
    end
  end
  return incoming, outgoing
end

-- Reach callers in increasing distance. Report each call site, including multiple sites
-- in one caller and calls to an interface declaration.
local function callers(incoming, symbols, max_depth)
  local seen, queue, sites, emitted = {}, {}, {}, {}
  for _, id in ipairs(symbols) do
    seen[id] = 0
    queue[#queue + 1] = id
  end
  local i = 1
  while queue[i] do
    local id = queue[i]
    i = i + 1
    local depth = seen[id] + 1
    for _, edge in ipairs(incoming[id] or {}) do
      if not emitted[edge] then
        emitted[edge] = true
        sites[#sites + 1] = vim.tbl_extend("force", edge, { depth = depth })
      end
      if depth < max_depth and seen[edge.source] == nil then
        seen[edge.source] = depth
        queue[#queue + 1] = edge.source
      end
    end
  end
  return sites
end

local function impact(idx, symbols)
  local incoming = call_graph(idx)
  local sites = callers(incoming, symbols, 3)
  local store = require("code-tour.ast.store").new(idx, ast.options)
  local affected, seen = {}, {}
  for _, version in ipairs(store:all()) do
    local key = version.file .. "\0" .. version.region
    if not seen[key] then
      local matches = vim.tbl_filter(function(id)
        return version.evidence.callees and version.evidence.callees[id] ~= nil
      end, symbols)
      if #matches > 0 and store:is_fresh(version) then
        affected[#affected + 1] = { address = version.region, file = version.file, callees = matches }
        seen[key] = true
      end
    end
  end
  return { callers = sites, notes = affected, tests = tests_for(idx, symbols), max_depth = 3 }
end

-- Reverse distances give shortest directed paths. Traverse only edges that get a
-- step closer to the destination, so recursion never follows a call cycle.
local function paths(idx, starts, targets)
  local incoming, outgoing = call_graph(idx)
  local result, capped = {}, false
  for _, target in ipairs(targets) do
    local dist, queue = { [target] = 0 }, { target }
    local i = 1
    while queue[i] do
      local id = queue[i]
      i = i + 1
      for _, edge in ipairs(incoming[id] or {}) do
        if dist[edge.source] == nil then
          dist[edge.source] = dist[id] + 1
          queue[#queue + 1] = edge.source
        end
      end
    end
    local symbols, sites = {}, {}
    local function visit(id)
      symbols[#symbols + 1] = id
      if id == target then
        if #result == 100 then
          capped = true
        else
          result[#result + 1] = { symbols = vim.deepcopy(symbols), sites = vim.deepcopy(sites) }
        end
      else
        for _, edge in ipairs(outgoing[id] or {}) do
          if dist[edge.target] == dist[id] - 1 and not capped then
            sites[#sites + 1] = edge
            visit(edge.target)
            sites[#sites] = nil
          end
        end
      end
      symbols[#symbols] = nil
    end
    for _, start in ipairs(starts) do
      if dist[start] and not capped then
        visit(start)
      end
    end
    if capped then
      break
    end
  end
  return { paths = result, from = starts, to = targets, truncated = capped or nil }
end

local function search(idx, query)
  query = vim.fn.tolower(vim.trim(query))
  assert(query ~= "", "search text is empty")
  idx:scan()
  local function matches(value)
    return value and vim.fn.tolower(value):find(query, 1, true) ~= nil
  end
  local hits = {}
  local function add(sym, score)
    local hit = hits[sym.id] or { symbol = sym.id, label = sym.label, file = sym.file, score = 0, gists = {} }
    hit.score = math.max(hit.score, score)
    hits[sym.id] = hit
    return hit
  end
  for _, sym in pairs(idx.symbols) do
    if matches(sym.name) or matches(sym.label) or matches(sym.id) then
      local exact = sym.name and vim.fn.tolower(sym.name) == query
      add(sym, exact and 100 or 50)
    end
  end
  local store = require("code-tour.ast.store").new(idx, ast.options)
  local seen, current = {}, {}
  for _, version in ipairs(store:all()) do
    local symbol = version.symbol or version.region:match("^[^/]+")
    local sym = idx:symbol(symbol)
    if sym and not seen[version.region] and store:is_fresh(version) then
      seen[version.region] = true
      local gist_match = matches(version.gist)
      local body_match = false
      for _, body in pairs(version.bodies) do
        if matches(body.text) then
          body_match = true
          break
        end
      end
      local entry = { address = version.region, gist = version.gist }
      current[symbol] = current[symbol] or {}
      current[symbol][#current[symbol] + 1] = entry
      if gist_match or body_match then
        local hit = add(sym, gist_match and 20 or 10)
        hit.gists[#hit.gists + 1] = entry
      end
    end
  end
  local result = vim.tbl_values(hits)
  for _, hit in ipairs(result) do
    if #hit.gists == 0 then
      hit.gists = current[hit.symbol] or {}
    end
  end
  table.sort(result, function(a, b)
    return a.score > b.score or (a.score == b.score and a.symbol < b.symbol)
  end)
  return { results = result }
end

local function note(opts)
  local live = live_for(opts)
  if #live.prep.entries ~= 1 then
    error("Write notes for one symbol at a time. Use a qualified symbol ID from explain or flow.", 0)
  end
  local sn = live.snippets[live.ids[live.prep.entries[1]]]
  local regions = {}
  for _, region in ipairs(sn.regions) do
    regions[region.id] = region
    regions[region.address] = region
  end
  local sections = require("code-tour.ast.fill").parse(opts.markdown, sn.n, function(heading)
    if heading == sn.symbol then
      return sn.n, "overview"
    end
    if vim.startswith(heading, sn.symbol .. "/") then
      return sn.n, heading
    end
  end)
  local pending = {}
  for _, section in ipairs(sections) do
    local region = regions[section.box]
    local address = section.box == "overview" and sn.symbol or (region and region.address)
    if not address and vim.startswith(section.box, sn.symbol .. "/") then
      address = section.box
    end
    if section.n ~= sn.n or not address then
      error(("Unknown box %q for %s at %s detail"):format(section.heading, sn.symbol, live.detail), 0)
    end
    local fingerprint = sn._fps[address]
    if not fingerprint then
      local range
      fingerprint, range = live.store:region_fingerprint(address, { file = sn.file, symbol = sn.symbol })
      if not fingerprint or not range then
        error("Region no longer resolves: " .. address, 0)
      end
      region = { _range = range }
    end
    pending[#pending + 1] = {
      address = address,
      note = { file = sn.file, symbol = sn.symbol, fingerprint = fingerprint, detail = live.detail,
        gist = section.gist, body = section.body, example = section.example, source = "coding", model = opts.model,
        relocation_fingerprint = not region and sn._relocation_fingerprint or nil,
        callees = live:callees(sn, region) },
    }
  end
  local written = {}
  for _, item in ipairs(pending) do
    live.store:put(item.address, item.note)
    written[#written + 1] = item.address
  end
  return { symbol = sn.symbol, detail = live.detail, written = written, count = #written }
end

function M.run(action, opts)
  if action == "explain" then
    return explain(opts)
  elseif action == "flow" then
    return flow(opts)
  elseif action == "note" then
    return note(opts)
  end
  local idx = ast.index({ root = opts.root })
  if action == "prune" then
    return require("code-tour.ast.store").new(idx, ast.options):prune()
  end
  if action == "search" then
    local result = search(idx, opts.query)
    result.root, result.truncated = idx.root, idx.truncated
    return result
  end
  local symbols = resolve(idx, opts.symbol)
  local result
  if action == "callers" then
    result = { callers = callers(call_graph(idx), symbols, 1) }
  elseif action == "impact" then
    result = impact(idx, symbols)
  elseif action == "path" then
    result = paths(idx, symbols, resolve(idx, opts.target))
  else
    error("unknown knowledge command " .. tostring(action), 0)
  end
  result.root, result.symbols = idx.root, symbols
  result.truncated = result.truncated or idx.truncated
  return result
end

return M
