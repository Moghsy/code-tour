-- Lazy analysis of the persisted project graph (graph.json): communities, hub symbols and
-- cross-community links. The plugin states facts about the graph's shape and makes no
-- judgement about what matters; the agent reads them to understand the code before it
-- designs a tour. Nothing here runs at build time: results are computed on first request
-- and cached in analysis.json beside the graph, keyed by the graph's manifest hash.
local M = {}

local STRUCTURE = { calls = 1, overrides = 1, inherits = 1, implements = 1, extends = 1, references = 0.5 }
local CONTAINS = 2

local function owner_of(id)
  return id:match("^(.-)#")
end

local function package_of(id)
  local qname = id:match("^%a+:([^#]+)")
  return qname and qname:match("^(.*)%.[^.]+$") or ""
end

local function type_of(id)
  local qname = owner_of(id) or id:match("^%a+:(.+)$")
  return qname and qname:match("([^.]+)$") or id
end

-- Weighted undirected adjacency over code symbols; `directed` keeps call/inherit edges by direction.
local function adjacency(graph)
  local nodes, adj, out, into = {}, {}, {}, {}
  for _, node in ipairs(graph.nodes) do
    if node.kind ~= "file" then
      nodes[node.id] = node
      adj[node.id], out[node.id], into[node.id] = {}, {}, {}
    end
  end
  local function link(a, b, weight)
    if a ~= b and adj[a] and adj[b] then
      adj[a][b] = (adj[a][b] or 0) + weight
      adj[b][a] = (adj[b][a] or 0) + weight
    end
  end
  for id in pairs(nodes) do
    local owner = owner_of(id)
    if owner and nodes[owner] then
      link(id, owner, CONTAINS)
    end
  end
  for _, e in ipairs(graph.links) do
    local weight = STRUCTURE[e.relation]
    if weight and nodes[e.source] and nodes[e.target] and e.source ~= e.target then
      link(e.source, e.target, weight)
      if e.relation ~= "references" then
        out[e.source][e.target] = (out[e.source][e.target] or 0) + 1
        into[e.target][e.source] = (into[e.target][e.source] or 0) + 1
      end
    end
  end
  return nodes, adj, out, into
end

-- Label propagation in sorted order: deterministic, no dependencies.
local function propagate(nodes, adj)
  local ids = vim.tbl_keys(nodes)
  table.sort(ids)
  local label = {}
  for _, id in ipairs(ids) do
    label[id] = id
  end
  for _ = 1, 30 do
    local changed = false
    for _, id in ipairs(ids) do
      local score = {}
      for other, weight in pairs(adj[id]) do
        score[label[other]] = (score[label[other]] or 0) + weight
      end
      local best, best_score = label[id], score[label[id]] or 0
      for candidate, value in pairs(score) do
        if value > best_score or (value == best_score and candidate < best) then
          best, best_score = candidate, value
        end
      end
      if best ~= label[id] then
        label[id], changed = best, true
      end
    end
    if not changed then
      break
    end
  end
  return label
end

local function top(counts, n)
  local list = vim.tbl_keys(counts)
  table.sort(list, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  return vim.list_slice(list, 1, n)
end

function M.compute(graph)
  local nodes, adj, out, into = adjacency(graph)
  local label = propagate(nodes, adj)
  local groups = {}
  for id, l in pairs(label) do
    groups[l] = groups[l] or {}
    table.insert(groups[l], id)
  end
  local communities = {}
  for _, members in pairs(groups) do
    table.sort(members)
    local packages, types = {}, {}
    for _, id in ipairs(members) do
      local p, ty = package_of(id), type_of(id)
      packages[p] = (packages[p] or 0) + 1
      types[ty] = (types[ty] or 0) + 1
    end
    communities[#communities + 1] = { members = members, packages = top(packages, 3), types = top(types, 5) }
  end
  table.sort(communities, function(a, b)
    if #a.members ~= #b.members then return #a.members > #b.members end
    return a.members[1] < b.members[1]
  end)
  local of = {}
  for i, c in ipairs(communities) do
    c.id = "c" .. i
    c.name = (c.packages[1] ~= "" and c.packages[1] or "(default)") .. " · " .. c.types[1]
    c.size = #c.members
    for _, id in ipairs(c.members) do
      of[id] = c.id
    end
  end
  -- hubs: symbols with the most distinct call/inheritance neighbours
  local hubs = {}
  for id in pairs(nodes) do
    local callers, callees = 0, 0
    for _ in pairs(into[id]) do callers = callers + 1 end
    for _ in pairs(out[id]) do callees = callees + 1 end
    if callers + callees > 0 then
      hubs[#hubs + 1] = { id = id, label = nodes[id].label, callers = callers, callees = callees,
        degree = callers + callees, community = of[id], file = nodes[id].source_file }
    end
  end
  table.sort(hubs, function(a, b)
    if a.degree ~= b.degree then return a.degree > b.degree end
    return a.id < b.id
  end)
  -- links that cross a community boundary, grouped by the pair
  local pairs_, crossings = {}, {}
  for _, e in ipairs(graph.links) do
    if e.relation == "calls" and of[e.source] and of[e.target] and of[e.source] ~= of[e.target] then
      local key = of[e.source] .. ">" .. of[e.target]
      local entry = pairs_[key]
      if not entry then
        entry = { from = of[e.source], to = of[e.target], count = 0, sample = {} }
        pairs_[key] = entry
        crossings[#crossings + 1] = entry
      end
      entry.count = entry.count + 1
      if #entry.sample < 3 then
        entry.sample[#entry.sample + 1] = { e.source, e.target }
      end
    end
  end
  table.sort(crossings, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return (a.from .. a.to) < (b.from .. b.to)
  end)
  local summary = {}
  for _, c in ipairs(communities) do
    summary[#summary + 1] = { id = c.id, name = c.name, size = c.size, packages = c.packages, types = c.types,
      members = c.members }
  end
  return { communities = summary, hubs = hubs, crossings = crossings, community_of = of }
end

-- Callers and callees of one symbol, with how each link was resolved.
function M.neighbors(graph, symbol)
  local exact, partial = {}, {}
  for _, node in ipairs(graph.nodes) do
    if node.id == symbol or node.label == symbol then
      exact[#exact + 1] = node
    elseif node.id:find(symbol, 1, true) then
      partial[#partial + 1] = node
    end
  end
  local function by_id(a, b) return a.id < b.id end
  table.sort(exact, by_id)
  table.sort(partial, by_id)
  local matches = vim.list_extend(exact, partial)
  if #matches == 0 then
    return nil, "no symbol matches " .. symbol
  end
  local node = matches[1]
  local callers, callees = {}, {}
  for _, e in ipairs(graph.links) do
    if e.relation == "calls" then
      local item = { confidence = e.confidence, via = e.via, file = e.source_file, at = e.source_location, text = e.callsite }
      if e.source == node.id then
        callees[#callees + 1] = vim.tbl_extend("force", item, { symbol = e.target })
      elseif e.target == node.id then
        callers[#callers + 1] = vim.tbl_extend("force", item, { symbol = e.source })
      end
    end
  end
  return { symbol = node.id, label = node.label, signature = node.signature, file = node.source_file,
    at = node.source_location, metrics = node.metrics, callers = callers, callees = callees,
    other_matches = #matches > 1 and vim.tbl_map(function(m) return m.id end, vim.list_slice(matches, 2, 6)) or nil }
end

return M
