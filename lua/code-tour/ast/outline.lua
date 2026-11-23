-- The derived tour (SPEC-ast-graph §3.6) and its outline (§9.2), for `code-tour ast
-- --dry-run`: snippets with their regions and sites, the route, gaps, sinks and forks.
-- Nothing is opened and no notes exist yet (phases 3 and 4), so every box is "to write".
local regions = require("code-tour.ast.regions")
local route = require("code-tour.ast.route")

local M = {}

-- Rank likely entry points without choosing one on the reader's behalf (§8.1).
function M.auto_entries(idx)
  idx:scan()
  local incoming, fanout = {}, {}
  for _, file in ipairs(idx.files) do
    if idx.loaded[file] then
      for _, edge in ipairs(idx.resolver:edges(file)) do
        if edge.relation == "calls" then
          incoming[edge.target] = (incoming[edge.target] or 0) + 1
          fanout[edge.source] = (fanout[edge.source] or 0) + 1
        end
      end
    end
  end
  local fanouts = vim.tbl_values(fanout)
  table.sort(fanouts, function(a, b) return a > b end)
  local top_tenth = fanouts[math.max(1, math.ceil(#fanouts * 0.1))]
  local entry_annotations = { SpringBootApplication = true, RestController = true, Controller = true,
    GetMapping = true, PostMapping = true, PutMapping = true, PatchMapping = true, DeleteMapping = true,
    RequestMapping = true, Command = true }
  local candidates = {}
  for _, sym in pairs(idx.symbols) do
    if sym.kind == "method" or sym.kind == "constructor" or sym.kind == "function" then
      local name = sym.name or ""
      local path = sym.file or ""
      local is_test = sym.test == true or path:match("^tests?/") ~= nil or path:match("/tests?/") ~= nil
        or path:match("Test[^/]*%.java$") ~= nil or name:match("^test_") ~= nil
      if not is_test then
      local score = 0
      local public_entry = false
      if sym.entry and not sym.test then public_entry = true end
      if name == "main" and (sym.id:find("String%[%]") or (sym.label or ""):find("String", 1, true)) then
        public_entry = true
      end
      local filebase = vim.fs.basename(path)
      if filebase == "Application.java" or filebase == "Main.java" or filebase:match("Controller%.java$")
          or filebase:match("Handler%.java$") or filebase:match("Command%.java$") then public_entry = true end
      if public_entry then score = score + 3 end
      local framework_entry = false
      for _, annotation in ipairs(sym.annotations or {}) do
        local simple = annotation:match("([%w_]+)$")
        if simple ~= "Test" and entry_annotations[simple] then
          framework_entry = true
          break
        end
      end
      local owner = sym.owner and idx:symbol(sym.owner)
      for _, annotation in ipairs(owner and owner.annotations or {}) do
        local simple = annotation:match("([%w_]+)$")
        if simple ~= "Test" and entry_annotations[simple] then
          framework_entry = true
          break
        end
      end
      if framework_entry then score = score + 3 end
      if not incoming[sym.id] then score = score + 1 end
      if top_tenth and (fanout[sym.id] or 0) >= top_tenth then score = score + 1 end
      local source_relative = path:match("src/main/java/(.+)$") or path:match("src/(.+)$") or path
      local depth = select(2, source_relative:gsub("/", ""))
      if depth <= 2 then score = score + 1 end
      if score > 0 then
        candidates[#candidates + 1] = { symbol = sym.id, label = sym.label, file = sym.file,
          score = score, callers = incoming[sym.id] or 0, project_sites = fanout[sym.id] or 0 }
      end
      end
    end
  end
  table.sort(candidates, function(a, b)
    return a.score > b.score or (a.score == b.score and a.symbol < b.symbol)
  end)
  while #candidates > 10 do table.remove(candidates) end
  return candidates
end

local function lines_of(range)
  local first, last = range.start[1] + 1, range["end"][1] + 1
  if range["end"][2] == 0 and last > first then
    last = last - 1
  end
  return first, last
end

local function lines_text(a, b)
  return a == b and tostring(a) or (a .. "-" .. b)
end

-- The detail-independent part of a tour: entries, the main flow and the rated tree
-- (§8.2–8.3). Any detail is a projection of it (§8.6), so a live tour keeps it and
-- changing detail never re-rates. opts: { through = {specs}, options = route options }.
-- Returns prep, or nil and an error.
function M.prepare(idx, specs, opts)
  opts = opts or {}
  specs = specs or {}
  local rt = route.new(idx, opts.options)
  local entries = {}
  for _, spec in ipairs(specs) do
    local ids, err = rt:resolve_entry(spec)
    if not ids then
      return nil, err
    end
    for _, id in ipairs(ids) do
      local sym = idx:symbol(id)
      if sym and sym.error then return nil, "parse error in " .. sym.label end
    end
    vim.list_extend(entries, ids)
  end
  -- the agent's route shapes the first projection too, so its short ids (n1.s2, n1.r6) match
  -- the ones the agent saw; the full apply below repeats it and reports any problems
  require("code-tour.ast.overrides").route(rt, opts.overrides, {})
  local only_adds = opts.overrides and #opts.overrides > 0
  if only_adds then
    for _, op in ipairs(opts.overrides) do
      if op.kind ~= "add" then only_adds = false; break end
    end
  end
  if #entries == 0 and not only_adds then return nil, "no entry" end
  local through = {}
  for _, spec in ipairs(opts.through or {}) do
    local ids, err = rt:resolve_entry(spec)
    if not ids then
      return nil, "--through: " .. err
    end
    vim.list_extend(through, ids)
  end
  local marks, warnings = rt:through_marks(entries, through)
  local flow = rt:main_flow(entries, marks)
  vim.list_extend(warnings, flow.warnings)
  local tree = rt:tree(entries, flow)
  local prep = { idx = idx, rt = rt, entries = entries, through = through, flow = flow, tree = tree, warnings = warnings }
  if opts.overrides and #opts.overrides > 0 then
    -- Short site and region ids belong to the first derived projection. Normalize
    -- them once into structural addresses before changing the route.
    local first = M.assemble(prep, opts.detail or "normal")
    local normalized, normalize_err = require("code-tour.ast.overrides").normalize(rt, first.snippets,
      opts.overrides, opts.detail or "normal")
    if not normalized then
      return nil, normalize_err
    end
    prep.overrides = normalized
    local added = require("code-tour.ast.overrides").apply(rt, normalized, entries, warnings)
    prep.region_overrides = added
    local marks, more = rt:through_marks(entries, through)
    vim.list_extend(warnings, more)
    flow = rt:main_flow(entries, marks)
    vim.list_extend(warnings, flow.warnings)
    tree = rt:tree(entries, flow)
    prep.entries, prep.flow, prep.tree = entries, flow, tree
  end
  return prep
end

-- One snippet (§3.6) of a projected node at a detail: its regions (§7), its sites with
-- their modes, and its sinks, gaps and forks. `n` is its short id.
function M.snippet(prep, node, n, mode, detail)
  local idx, rt, flow = prep.idx, prep.rt, prep.flow
  do
    local sym, body = node.sym, node.body
    local mnode = node.main and flow.nodes[node.symbol] or nil
    local main_ids = {}
    for sid, ms in pairs(mnode and mnode.main_sites or {}) do
      if not ms.ref and not ms.capped then
        main_ids[sid] = true
      end
    end
    local root = regions.select(sym, body, detail, {
      walked = main_ids,
      main = main_ids,
      effect = function(id)
        local s = body and route.site_of(body, id)
        return s and rt:site_effect(body, s) or false
      end,
    })
    local flat = regions.flatten(root)
    local a, b = root.span[1], root.span[2]
    local snippet = {
      n = n,
      symbol = node.symbol,
      label = sym.label,
      file = sym.file,
      lines = { a, b },
      main = node.main,
      depth = node.depth,
      regions = {},
      sites = {},
      sinks = {},
      gaps = {},
      forks = {},
      _root = root,
      _node = node,
      _detail = detail,
    }
    for _, r in ipairs(flat) do
      snippet.regions[#snippet.regions + 1] = { id = r.id, address = r.address, kind = r.kind, origin = r.origin,
        lines = { r.span[1], r.span[2] }, facts = r.facts, parent = nil, _region = r, _range = r.range }
    end
    local by_region = {}
    for _, r in ipairs(snippet.regions) do
      by_region[r._region] = r.id
    end
    for _, r in ipairs(snippet.regions) do
      for _, c in ipairs(r._region.children) do
        snippet.regions[tonumber(by_region[c]:sub(2))].parent = r.id
      end
    end
    local function region_id(pos)
      local r = regions.deepest(root, pos)
      return by_region[r] or "overview"
    end
    for _, e in ipairs(node.edges) do
      local m = mode[e] or { mode = e.label or "lazy", why = e.lazy or e.why }
      local s = e.site
      local entry = {
        site = s.id,
        text = s.text,
        kind = s.kind,
        region = region_id(s.at),
        mode = m.mode,
        why = m.why,
        to = m.to,
        target = e.target,
        target_label = e.target and idx:symbol(e.target) and idx:symbol(e.target).label or nil,
        rating = e.rating,
        effective = e.eff,
        main = e.main or nil,
        confidence = e.confidence,
        via = e.via,
        candidates = e.candidates,
        built = e.built,
        unresolved = s.unresolved,
        receiver_type = s.receiver_type,
        line = s.at[1] + 1,
        _range = s.range,
        _edge = e,
      }
      snippet.sites[#snippet.sites + 1] = entry
    end
    if mnode then
      local function at(sid)
        local s = route.site_of(body, sid)
        return s
      end
      for _, g in ipairs(mnode.gaps) do
        local s = at(g.site)
        local item = { n = n, site = g.site, text = s.text, reason = g.reason, region = region_id(s.at),
          line = s.at[1] + 1 }
        item._range = s.range
        snippet.gaps[#snippet.gaps + 1] = item
      end
      for _, k in ipairs(mnode.sinks) do
        local s = at(k.site)
        snippet.sinks[#snippet.sinks + 1] = { site = k.site, text = s.text, entry = k.entry,
          region = region_id(s.at), receiver_type = s.receiver_type }
      end
      for _, f in ipairs(mnode.forks) do
        snippet.forks[#snippet.forks + 1] = { kind = f.kind, condition = f.condition, success = f.success, by = f.by,
          cases = f.cases, region = region_id(f.at), line = f.at[1] + 1 }
      end
    end
    snippet.tier = require("code-tour.ast.tiers").classify(rt, node, snippet.sites)
    return snippet
  end
end

-- Project a prepared tour onto a detail (§8.6). Returns the tour (§3.6).
function M.assemble(prep, detail)
  local proj = prep.rt:project(prep.tree, detail)
  local tour = { detail = detail, entries = prep.entries, through = prep.through, snippets = {}, route = {},
    gaps = {}, warnings = prep.warnings }
  for _, node in ipairs(proj.snippets) do
    local sn = M.snippet(prep, node, proj.n[node], proj.mode, detail)
    for _, override in ipairs(prep.region_overrides and prep.region_overrides[sn.symbol] or {}) do
      if not override.detail or override.detail == detail then
        local ok, err = require("code-tour.ast.expand").override(sn, override)
        if not ok then error(err, 0) end
      end
    end
    tour.snippets[#tour.snippets + 1] = sn
    M.collect(tour, sn)
  end
  return tour
end

-- Add a snippet's routed edges and gaps to the tour-wide lists.
function M.collect(tour, sn)
  for _, e in ipairs(sn.sites) do
    if e.target and e.mode ~= "accessor" and e.mode ~= "unresolved" then
      tour.route[#tour.route + 1] = { from = { n = sn.n, site = e.site }, to = e.to, target = e.target,
        rating = e.effective, main = e.main or nil, mode = e.mode, why = e.why }
    end
  end
  vim.list_extend(tour.gaps, sn.gaps)
end

-- Build the tour. opts: { detail, through = {specs}, options = route options }.
-- Returns tour, or nil and an error.
function M.build(idx, specs, opts)
  opts = opts or {}
  local detail = opts.detail or "normal"
  if not route.new(idx, opts.options).opts.cutoffs[detail] then
    return nil, "unknown detail " .. detail .. " (overview, normal, detailed, exhaustive)"
  end
  local prep, err = M.prepare(idx, specs, opts)
  if not prep then
    return nil, err
  end
  return M.assemble(prep, detail)
end

-- JSON-safe copy (private fields dropped).
function M.data(tour)
  local function clean(v)
    if type(v) ~= "table" then
      return v
    end
    local out = {}
    for k, x in pairs(v) do
      if type(k) ~= "string" or k:sub(1, 1) ~= "_" then
        out[k] = clean(x)
      end
    end
    return out
  end
  return clean(tour)
end

local function simple(q)
  return q and (q:match("([^.]+)$") or q)
end

local function site_item(s, owners)
  local text = s.site .. " " .. s.text
  if s.mode == "walk" or s.mode == "optional" then
    local tail = s.mode == "walk" and (s.rating .. "★") or tostring(s.effective)
    text = text .. " → " .. (s.to or "?") .. " [" .. tail .. "]"
  elseif s.mode == "ref" then
    text = text .. " → " .. (s.to or "?") .. " [" .. (s.why or "ref") .. "]"
  elseif s.mode == "lazy" then
    local parts = {}
    if s.effective then
      parts[#parts + 1] = tostring(s.effective)
    end
    if s.why then
      parts[#parts + 1] = s.why
    end
    text = text .. " [" .. table.concat(parts, " ") .. "]"
  elseif s.mode == "unresolved" then
    local reason = s.unresolved or "implicit constructor"
    text = text .. " (" .. reason .. (s.receiver_type and (": " .. simple(s.receiver_type)) or "") .. ")"
  end
  local notes = {}
  if s.candidates then
    notes[#notes + 1] = (#owners == s.candidates and (s.candidates .. " impls: ") or ("of " .. s.candidates .. ": "))
      .. table.concat(owners, ", ")
  elseif s.built and s.target_label then
    notes[#notes + 1] = "constructed: " .. s.target_label
  end
  if s.via == "boundary" then
    notes[#notes + 1] = "via configured boundary"
  elseif s.via == "through" then
    notes[#notes + 1] = "--through"
  end
  if #notes > 0 then
    text = text .. " (" .. table.concat(notes, "; ") .. ")"
  end
  return text
end

local group_order = { "walk", "optional", "lazy", "ref", "accessor", "unresolved" }

local function facts_text(f)
  if not f then
    return ""
  end
  local parts = {}
  if f.guards and #f.guards > 0 then
    parts[#parts + 1] = (#f.guards == 1 and "guard: " or (#f.guards .. " guards: ")) .. table.concat(f.guards, ", ")
  end
  if f.subject then
    parts[#parts + 1] = "over: " .. f.subject
  end
  if f.branch then
    parts[#parts + 1] = "if: " .. f.branch
  end
  if f.locals and #f.locals > 0 then
    parts[#parts + 1] = "locals: " .. table.concat(f.locals, ", ")
  end
  if f.fields and #f.fields > 0 then
    parts[#parts + 1] = "writes: " .. table.concat(f.fields, ", ")
  end
  return table.concat(parts, " · ")
end

local function pad(s, width)
  return s .. string.rep(" ", math.max(1, width - vim.fn.strdisplaywidth(s)))
end

-- The default status of a snippet line: every box to write (the dry run has no notes).
local function write_all(sn)
  local write = "overview"
  if #sn.regions > 0 then
    write = write .. " r1" .. (#sn.regions > 1 and ("-r" .. #sn.regions) or "")
  end
  return "write: " .. write
end

-- The outline lines of one snippet (§9.2). status(sn) gives the tail of the snippet line
-- ("write: …" or "fresh").
function M.snippet_lines(sn, status)
  local out = {}
  do
    out[#out + 1] = pad(sn.n .. " " .. sn.label, 40) .. pad(vim.fs.basename(sn.file) .. ":" .. lines_text(sn.lines[1],
      sn.lines[2]), 26) .. pad(sn.tier or "standard", 10) .. (status or write_all)(sn)
    local function emit(region_id, indent)
      local groups, merged = {}, {}
      for _, s in ipairs(sn.sites) do
        if s.region == region_id then
          local key = (s.confidence == "AMBIGUOUS") and "ambiguous" or s.mode
          -- the candidates of one site in one mode read as one item
          local mkey = s.candidates and table.concat({ s.site, s.mode, s.why or "", tostring(s.to) }, "|")
          local owner = s.target_label and s.target_label:match("^([^.(]+)") or s.target
          if mkey and merged[mkey] then
            table.insert(merged[mkey].owners, owner)
          else
            groups[key] = groups[key] or {}
            local item = { s = s, owners = { owner } }
            table.insert(groups[key], item)
            if mkey then
              merged[mkey] = item
            end
          end
        end
      end
      for key, list in pairs(groups) do
        groups[key] = vim.tbl_map(function(item)
          return site_item(item.s, item.owners)
        end, list)
      end
      local order = vim.list_extend(vim.deepcopy(group_order), { "ambiguous" })
      for _, key in ipairs(order) do
        if groups[key] then
          out[#out + 1] = indent .. key .. ": " .. table.concat(groups[key], ", ")
        end
      end
      for _, k in ipairs(sn.sinks) do
        if k.region == region_id then
          out[#out + 1] = indent .. "sink: " .. k.site .. " " .. k.text .. " (" .. simple(k.receiver_type) .. ")"
        end
      end
      for _, g in ipairs(sn.gaps) do
        if g.region == region_id then
          out[#out + 1] = indent .. "gap: " .. g.site .. " " .. g.text .. " — " .. g.reason
        end
      end
      for _, f in ipairs(sn.forks) do
        if f.region == region_id then
          local what = f.by == "condition" and ("success path: " .. f.success .. " (by the condition's name)")
            or (f.kind == "switch" and (f.cases .. " cases tie; all kept") or "no rule decides; both arms kept")
          out[#out + 1] = indent .. "fork: " .. f.kind .. " (" .. (f.condition or "") .. ") line " .. f.line .. " — "
            .. what
        end
      end
    end
    emit("overview", "   ")
    for _, r in ipairs(sn.regions) do
      local depth = 0
      local p = r.parent
      while p do
        depth = depth + 1
        local parent
        for _, rr in ipairs(sn.regions) do
          if rr.id == p then
            parent = rr
          end
        end
        p = parent and parent.parent
      end
      local indent = "   " .. string.rep("  ", depth)
      out[#out + 1] = pad(indent .. r.id .. " " .. lines_text(r.lines[1], r.lines[2]), 15 + 2 * depth) .. pad(r.kind, 10)
        .. facts_text(r.facts)
      emit(r.id, string.rep(" ", 22 + 2 * depth))
    end
  end
  return out
end

-- The outline as plain text (§9.2). opts: { header = first line, status = fn(sn) }.
function M.text(tour, opts)
  opts = opts or {}
  local out = {}
  local gaps = #tour.gaps
  out[#out + 1] = opts.header or ("tour (dry run) · %s · %d snippets · %d to write · %d gap%s"):format(tour.detail,
    #tour.snippets, #tour.snippets, gaps, gaps == 1 and "" or "s")
  local models = require("code-tour.ast.tiers").header(require("code-tour.ast").options.models, opts.ctx)
  if models then out[#out + 1] = models end
  for _, line in ipairs(opts.extra or {}) do
    out[#out + 1] = line
  end
  for _, w in ipairs(tour.warnings or {}) do
    out[#out + 1] = "warning: " .. w
  end
  out[#out + 1] = ""
  for _, sn in ipairs(tour.snippets) do
    vim.list_extend(out, M.snippet_lines(sn, opts.status))
  end
  return table.concat(out, "\n")
end

M.lines_of = lines_of
return M
