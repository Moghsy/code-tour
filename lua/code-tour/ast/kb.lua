-- The knowledge base is one logical view over three stores that share a key, the symbol id:
-- the graph (graph.json: what exists and who calls whom), the notes (what was written about it,
-- with the evidence it was written against) and the concepts. Nothing is copied: a symbol's
-- status is computed by joining them, so a fresh note is reused and only stale or missing
-- ones are reported for regeneration.
local M = {}

local function is_test(node)
  local file = node.source_file or ""
  return file:match("[Tt]est") ~= nil or file:match("/tests?/") ~= nil
end

local DOCUMENTED = { method = true, constructor = true, ["function"] = true, class = true, interface = true,
  enum = true, record = true }

-- Newest version of each note region, as { region, symbol, file, version }.
local function newest(store)
  local out = {}
  for _, path in ipairs(store:paths()) do
    local doc = store:document(path)
    for region, versions in pairs(doc.notes or {}) do
      local version
      for _, candidate in ipairs(versions) do
        if candidate.gist then
          version = candidate
          break
        end
      end
      if version then
        out[#out + 1] = { region = region, symbol = version.symbol or region:match("^(.-)/body/") or region,
          file = version.file, version = version }
      end
    end
  end
  table.sort(out, function(a, b) return a.region < b.region end)
  return out
end

-- Callee-first order over the stale symbols (a callee's note is rewritten before its callers').
local function callee_first(symbols, graph)
  local wanted, calls = {}, {}
  for _, id in ipairs(symbols) do wanted[id] = true end
  for _, link in ipairs(graph and graph.links or {}) do
    if link.relation == "calls" and wanted[link.source] and wanted[link.target] and link.source ~= link.target then
      calls[link.source] = calls[link.source] or {}
      calls[link.source][#calls[link.source] + 1] = link.target
    end
  end
  local order, state = {}, {}
  local function visit(id)
    if state[id] then return end
    state[id] = true -- also breaks cycles
    local targets = calls[id] or {}
    table.sort(targets)
    for _, target in ipairs(targets) do visit(target) end
    order[#order + 1] = id
  end
  local sorted = vim.deepcopy(symbols)
  table.sort(sorted)
  for _, id in ipairs(sorted) do visit(id) end
  return order
end

-- opts.limit caps the missing list; opts.tests includes test code among the missing.
function M.report(idx, store, graph, opts)
  opts = opts or {}
  local symbols, stale_symbols, fresh_count = {}, {}, 0
  for _, entry in ipairs(newest(store)) do
    local version = entry.version
    local symbol = entry.symbol
    local row = symbols[symbol]
    if not row then
      row = { symbol = symbol, file = entry.file, status = "fresh", regions = 0, details = {} }
      symbols[symbol] = row
    end
    row.regions = row.regions + 1
    for detail in pairs(version.bodies or {}) do row.details[detail] = true end
    local fresh, reason = store:is_fresh(version)
    if not fresh then
      row.status = reason == "symbol missing" and "orphaned" or "stale"
      row.reason = row.reason or reason
      if reason == "callee changed" then
        local changed = row.changed or {}
        for id, fp in pairs(version.evidence.callees or {}) do
          if store:region_fingerprint(id) ~= fp then changed[#changed + 1] = id end
        end
        table.sort(changed)
        row.changed = changed
      end
    end
  end
  local rows, counts = {}, { fresh = 0, stale = 0, orphaned = 0, missing = 0 }
  local ids = vim.tbl_keys(symbols)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local row = symbols[id]
    row.details = vim.tbl_keys(row.details)
    table.sort(row.details)
    counts[row.status] = counts[row.status] + 1
    if row.status == "stale" then stale_symbols[#stale_symbols + 1] = id end
    rows[#rows + 1] = row
  end
  local order = callee_first(stale_symbols, graph)
  local missing = {}
  for _, node in ipairs(graph and graph.nodes or {}) do
    if DOCUMENTED[node.kind] and not symbols[node.id] and (opts.tests or not is_test(node)) then
      missing[#missing + 1] = node.id
    end
  end
  table.sort(missing)
  local missing_set = {}
  for _, id in ipairs(missing) do missing_set[id] = true end
  counts.missing = #missing
  local limit = tonumber(opts.limit) or 15
  -- Coverage per community: how much of each cluster of related symbols has been explained.
  -- A fact about the project, in the communities' own order; the agent decides where to go next.
  local coverage = {}
  for _, community in ipairs(opts.communities or {}) do
    local total, written, fresh = 0, 0, 0
    for _, id in ipairs(community.members) do
      local row = symbols[id]
      if row or missing_set[id] then
        total = total + 1
        if row then
          written = written + 1
          if row.status == "fresh" then fresh = fresh + 1 end
        end
      end
    end
    if total > 0 then
      coverage[#coverage + 1] = { community = community.id, name = community.name, symbols = total,
        explained = written, fresh = fresh }
    end
  end
  local concepts = {}
  for _, concept in ipairs(require("code-tour.ast.concepts").list(idx, store)) do
    if concept.stale then concepts[#concepts + 1] = concept.id end
  end
  return {
    counts = counts,
    -- rewrite these, in this order; every fresh note is reused as it is
    regenerate = order,
    stale = vim.tbl_filter(function(row) return row.status ~= "fresh" end, rows),
    missing = vim.list_slice(missing, 1, limit),
    missing_total = #missing,
    coverage = vim.list_slice(coverage, 1, limit),
    stale_concepts = concepts,
  }
end

return M
