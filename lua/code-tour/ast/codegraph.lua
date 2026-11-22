-- §15: the symbol graph as graphify-compatible NetworkX node-link JSON. Nodes are
-- symbols; links are graphify's relations, and each call site is its own `calls`
-- link keyed by site id, so the multigraph keeps every call.
local M = {}

local function location(range)
  if not range then
    return nil
  end
  local first, last = range.start[1] + 1, range["end"][1] + 1
  if range["end"][2] == 0 and last > first then
    last = last - 1
  end
  return first == last and ("L" .. first) or ("L%d-%d"):format(first, last)
end

function M.build(idx, selected)
  local files = idx.files
  if selected then
    local present = {}
    for id in pairs(selected) do
      local symbol = idx:symbol(id)
      if symbol then present[symbol.file] = true end
    end
    files = vim.tbl_keys(present)
    table.sort(files)
  else
    idx:scan()
  end
  local links = {}
  for _, rel in ipairs(files) do
    if idx.loaded[rel] then vim.list_extend(links, idx.resolver:edges(rel)) end
  end
  local nodes, have = {}, {}
  local ids = vim.tbl_keys(selected or idx.symbols)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local sym = idx.symbols[id]
    local node = {
      id = id,
      label = sym.label,
      file_type = "code",
      source_file = sym.file,
      source_location = location(sym.range),
      kind = sym.kind,
      source = sym.source or "ast",
      signature = sym.signature,
      -- graphify tells deterministic nodes from LLM ones by this stamp (or by a one-line
      -- "L<n>" location); without it, "L15-33" nodes would be re-keyed as semantic ones
      _origin = "ast",
    }
    local facts = idx.loaded[sym.file]
    local body = facts and facts.bodies[id]
    if body and (sym.kind == "method" or sym.kind == "constructor" or sym.kind == "function") then
      node.metrics = body.metrics
    end
    nodes[#nodes + 1] = node
    have[id] = true
  end
  local out = {}
  for _, e in ipairs(links) do
    if have[e.source] and have[e.target] then
      out[#out + 1] = {
        source = e.source,
        target = e.target,
        relation = e.relation,
        confidence = e.confidence,
        source_file = e.file,
        source_location = e.line and ("L" .. e.line) or nil,
        weight = 1.0,
        context = e.context,
        via = e.via,
        key = e.key,
        callsite = e.callsite,
        call_range = e.range,
        site_kind = e.kind,
        -- §3.4 calls this field `source`, which node-link reserves for the endpoint
        origin = e.source_kind,
        _origin = "ast",
      }
    end
  end
  return { directed = true, multigraph = true, graph = { generator = "code-tour", root = idx.root }, nodes = nodes,
    links = out }
end

-- Export the live route, including lazy snippets the reader opened, with its induced symbol graph.
function M.tour(live)
  local outline = require("code-tour.ast.outline")
  local tour = vim.tbl_extend("force", live.tour, { snippets = {}, route = {}, gaps = {} })
  local selected = {}
  for _, sn in ipairs(live:all()) do
    tour.snippets[#tour.snippets + 1] = sn
    selected[sn.symbol] = true
    outline.collect(tour, sn)
  end
  for _, example in pairs(tour.examples or {}) do selected[example.test.id] = true end
  local graph = M.build(live.idx, selected)
  for _, sn in ipairs(tour.snippets) do
    for _, site in ipairs(sn.sites) do
      if site.via == "agent" and selected[site.target] then
        graph.links[#graph.links + 1] = {
          source = sn.symbol, target = site.target, key = site.site, relation = "calls", via = "agent",
          source_file = sn.file, source_location = location(site._range), callsite = site.text,
          confidence = site.confidence, weight = 1, origin = "agent",
        }
      end
    end
  end
  return outline.data(tour), graph
end

return M
