-- Convert outline addresses to recipe addresses before applying edits.
local M = {}

local function snippet(snippets, id)
  for _, sn in ipairs(snippets) do
    if sn.n == id then
      return sn
    end
  end
end

local function site(sn, id)
  local occurrence = {}
  for _, s in ipairs(sn._node.body and sn._node.body.sites or {}) do
    occurrence[s.text] = (occurrence[s.text] or 0) + 1
    if s.id == id then
      return s.text, occurrence[s.text]
    end
  end
end

local function region(sn, id)
  if id == "overview" then
    return sn._root
  end
  for _, r in ipairs(sn.regions) do
    if r.id == id then
      return r._region
    end
  end
end

function M.normalize(rt, snippets, ops, detail)
  local result = {}
  for _, op in ipairs(ops or {}) do
    if op.value == nil then
      result[#result + 1] = op
    else
      local kind, value = op.kind, op.value
      local n, sid, raw
      if kind == "rate" then
        n, sid, raw = value:match("^(n%d+)%.(s%d+)=([0-9])$")
      elseif kind == "edge" then
        n, sid, raw = value:match("^(n%d+)%.(s%d+)%s*%-%>%s*(.+)$")
      elseif kind == "add" then
        local ok, spec = pcall(vim.json.decode, value)
        if not ok or type(spec) ~= "table" then
          return nil, "--add expects a JSON object"
        end
        raw = spec
        if spec.site then
          n, sid = tostring(spec.site):match("^(n%d+)%.(s%d+)$")
          if not n then
            return nil, "--add requires a site like n1.s2"
          end
        end
      end
      local rec
      if kind == "rate" or kind == "edge" or kind == "add" then
        if not raw or (kind ~= "add" and not n) then
          return nil, "invalid --" .. kind .. " " .. value
        end
        rec = { kind = kind }
        if n then
          local sn = snippet(snippets, n)
          local name, occurrence
          if sn then
            name, occurrence = site(sn, sid)
          end
          if not name then
            return nil, "no site " .. n .. "." .. sid
          end
          rec.symbol, rec.text, rec.occurrence = sn.symbol, name, occurrence
        end
        if kind == "rate" then
          rec.rating = tonumber(raw)
        elseif kind == "edge" then
          local ids, err = rt:resolve_entry(raw)
          if not ids or #ids ~= 1 then
            return nil, err or "--edge requires one target"
          end
          rec.target = ids[1]
        else
          local spec, err = require("code-tour.ast.fallback").normalize(rt.idx, raw)
          if not spec then
            return nil, err
          end
          rec.spec, rec.target = spec, spec.id
          rec.rating = n and 0 or nil
        end
      elseif kind == "split" or kind == "merge" then
        local a, b, second_n
        if kind == "split" then
          n, a, raw = value:match("^(n%d+)%.([%w]+)@stmt(%d+)$")
        else
          n, a, second_n, b = value:match("^(n%d+)%.(r%d+),%s*(n%d+)%.(r%d+)$")
        end
        local sn = n and snippet(snippets, n)
        local left = sn and region(sn, a)
        local right = sn and b and region(sn, b)
        if not left or (kind == "merge" and (second_n ~= n or not right)) then
          return nil, "invalid --" .. kind .. " " .. value
        end
        rec = { kind = kind, symbol = sn.symbol, address = left.address,
          second = right and right.address or nil, detail = detail }
        if raw then
          rec.statement = (left.i or 1) + tonumber(raw) - 1
        end
        local ok, err = require("code-tour.ast.expand").override(vim.deepcopy(sn), rec)
        if not ok then
          return nil, err
        end
      else
        return nil, "unknown override " .. tostring(kind)
      end
      result[#result + 1] = rec
    end
  end
  return result
end

-- The agent's route: { kind = "route", from, to, level }. Both ends are symbol specs resolved
-- here, so a route survives a rebuild; an end that no longer resolves is a warning.
local function route_edges(rt, ops, warnings)
  rt.route, rt.routed_bodies = {}, nil
  local edges = {}
  for _, op in ipairs(ops or {}) do
    if op.kind == "route" then
      local from, from_err = rt:resolve_entry(op.from)
      local to, to_err = rt:resolve_entry(op.to)
      if not from or #from ~= 1 then
        warnings[#warnings + 1] = ("route %s -> %s: %s"):format(op.from, op.to, from_err or "the caller must name one symbol")
      elseif not to or #to ~= 1 then
        warnings[#warnings + 1] = ("route %s -> %s: %s"):format(op.from, op.to, to_err or "the callee must name one symbol")
      else
        local level = tonumber(op.level) or 0
        local named = rt.route[from[1]] or {}
        local list = named[to[1]] or {}
        -- the last edge named wins for the same call, so an adjustment can demote one
        local replaced = false
        for _, entry in ipairs(list) do
          if entry.site == op.site then
            entry.level, replaced = level, true
          end
        end
        if not replaced then
          list[#list + 1] = { level = level, site = op.site }
        end
        named[to[1]] = list
        rt.route[from[1]] = named
        edges[#edges + 1] = { op = op, from = from[1], to = to[1] }
      end
    end
  end
  return edges
end

M.route = route_edges

-- Verified last, once every site edit is in place, so the checked bodies are the final ones.
local function check_route(rt, edges, warnings)
  for _, edge in ipairs(edges) do
    local body = rt:body(edge.from)
    local found = false
    for _, site in ipairs(body and body.sites or {}) do
      for _, t in ipairs(site.targets or {}) do
        found = found or t.symbol == edge.to
      end
      found = found or (site.declared and site.declared.symbol == edge.to) or false
    end
    if not found then
      warnings[#warnings + 1] = ("route %s -> %s: no resolved call from the caller to the callee"):format(edge.op.from, edge.op.to)
    end
  end
end

function M.apply(rt, ops, entries, warnings)
  rt.site_overrides = {}
  local edges = route_edges(rt, ops, warnings)
  local regions = {}
  for _, op in ipairs(ops) do
    if op.kind == "add" then
      local ok, err = require("code-tour.ast.fallback").register(rt, op.spec)
      if not ok then
        warnings[#warnings + 1] = err
      elseif not op.symbol then
        entries[#entries + 1] = op.target
      end
    end
    if op.kind == "split" or op.kind == "merge" then
      regions[op.symbol] = regions[op.symbol] or {}
      table.insert(regions[op.symbol], op)
    elseif op.symbol and op.text then
      local symbols = rt.site_overrides
      symbols[op.symbol] = symbols[op.symbol] or {}
      local sites = symbols[op.symbol]
      sites[op.text] = sites[op.text] or {}
      local edits = sites[op.text]
      local change = edits[op.occurrence] or {}
      change.rating = op.rating or change.rating
      change.target = op.target or change.target
      edits[op.occurrence] = change
    end
  end
  check_route(rt, edges, warnings)
  return regions
end

return M
