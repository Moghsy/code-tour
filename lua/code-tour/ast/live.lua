-- A live AST-backed tour (SPEC-ast-graph §3.6, §9, §10): the L3 state behind the stops
-- the editor shows. It keeps the rated tree (so detail changes never re-rate, §8.6), the
-- tour at the current detail, stable snippet ids, region fingerprints and the note store
-- interface, and turns them into stops (project.lua) and outline text.
--
-- tour.lua owns the editor side (showing, splicing stops, delivering requests); this
-- module never touches windows or s.stops.
--
-- Snippet ids. §3.6 numbers snippets n1, n2… in walk order. A live tour keeps a
-- snippet's id for its lifetime (keyed by symbol), so a fill command handed out before a
-- detail change or an `ad` still names the same snippet; snippets that enter later take
-- the next free number. The first projection is therefore in walk order, and later ones
-- may not be (raised as a gap in the phase-3 report).
local outline = require("code-tour.ast.outline")
local regions = require("code-tour.ast.regions")
local notes = require("code-tour.ast.notes")
local project = require("code-tour.ast.project")

local M = {}
local L = {}
L.__index = L

M.details = { overview = true, normal = true, detailed = true, exhaustive = true }

local function buf_for(idx, file, refresh)
  local buf = vim.fn.bufadd(idx:abs(file))
  if refresh and vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
    vim.cmd("silent checktime " .. buf)
  end
  vim.fn.bufload(buf)
  return buf
end

local function relocation(idx, sym)
  return notes.fingerprint(buf_for(idx, sym.file, true), sym.range, sym.name)
end

local function old_symbol(idx, evidence)
  local function matching(symbols)
    local found
    for id, sym in pairs(symbols) do
      if sym.kind == evidence.kind and sym.range and not sym.implicit and not sym.error
          and relocation(idx, sym) == evidence.fingerprint then
        if found then return nil end
        found = id
      end
    end
    return found
  end
  local facts = idx.file_set[evidence.file] and idx:facts(evidence.file)
  local found = facts and matching(facts.symbols)
  if found then return found end
  if not idx.scanned then idx:scan() end
  return matching(idx.symbols)
end

-- Rebuild known entries and through markers after branch switches. Keep the original
-- recipe so entries can return when their symbols resolve again.
local function reopen(idx, saved, entries, through, overrides)
  local rt = require("code-tour.ast.route").new(idx)
  local warnings, remapped = {}, {}
  local function current(list)
    local out = {}
    for _, spec in ipairs(list) do
      local ids = rt:resolve_entry(spec)
      if ids then
        vim.list_extend(out, ids)
      else
        local evidence = (saved.symbols or {})[spec]
        local found = evidence and old_symbol(idx, evidence)
        if found then
          out[#out + 1], remapped[spec] = found, found
        else
          warnings[#warnings + 1] = "symbol missing: " .. spec
        end
      end
    end
    return out
  end
  local current_entries = current(entries)
  local current_through = current(through)
  local ops = vim.deepcopy(overrides)
  for _, op in ipairs(ops) do
    -- a route edge follows a renamed symbol the way an entry does: by the fingerprint saved with the recipe
    if op.kind == "route" then
      for _, key in ipairs({ "from", "to" }) do
        if not rt:resolve_entry(op[key]) then
          local evidence = (saved.symbols or {})[op[key]]
          op[key] = evidence and old_symbol(idx, evidence) or op[key]
        end
      end
    end
    local replacement = remapped[op.symbol]
    if replacement then
      for _, key in ipairs({ "address", "second" }) do
        if op[key] and vim.startswith(op[key], op.symbol) then
          op[key] = replacement .. op[key]:sub(#op.symbol + 1)
        end
      end
      op.symbol = replacement
    end
    op.target = remapped[op.target] or op.target
  end
  return current_entries, current_through, ops, warnings
end

-- Build a live tour. request: { entries, root?, detail?, through?, cache_dir?, store? }.
-- Returns live, or nil and an error.
function M.new(request)
  local ast = require("code-tour.ast")
  local saved = request.recipe or {}
  local detail = request.detail or saved.detail or ast.options.detail
  if not M.details[detail] then
    return nil, "unknown detail " .. tostring(detail) .. " (overview, normal, detailed, exhaustive)"
  end
  local entries = request.entries or saved.entries or {}
  local auto = request.auto or saved.auto
  local overrides = request.overrides or saved.overrides or {}
  local through = request.through or saved.through or {}
  if type(entries) == "string" then
    entries = { entries }
  end
  if #entries == 0 and not auto and #overrides == 0 then
    return nil, "no entry"
  end
  local idx = ast.index({ root = request.root, cache_dir = request.cache_dir })
  local current_entries, current_through, ops, missing = entries, through, overrides, {}
  if request.recipe then
    current_entries, current_through, ops, missing = reopen(idx, saved, entries, through, overrides)
  end
  local prep, err = outline.prepare(idx, current_entries, {
    detail = detail,
    through = current_through,
    overrides = ops,
    auto = auto,
    options = { cutoffs = ast.options.cutoffs, main_cap = ast.options.main_cap },
  })
  if not prep then
    return nil, #missing > 0 and (table.concat(missing, ", ") .. " (" .. err .. ")") or err
  end
  vim.list_extend(prep.warnings, missing)
  local recipe_entries = request.recipe and vim.deepcopy(saved.entries or {}) or vim.tbl_filter(function(id)
    return not (prep.rt.agent_bodies and prep.rt.agent_bodies[id])
  end, prep.entries)
  local recipe_overrides = vim.deepcopy(prep.overrides or {})
  if request.recipe then
    for i, op in ipairs(overrides) do
      if not op.value then recipe_overrides[i] = vim.deepcopy(op) end
    end
  end
  local self = setmetatable({
    idx = idx,
    root = idx.root,
    prep = prep,
    detail = detail,
    recipe = { id = saved.id, entries = recipe_entries, detail = detail, symbols = vim.deepcopy(saved.symbols or {}),
      through = vim.deepcopy(saved.through or prep.through or {}), overrides = recipe_overrides, auto = auto or nil },
    store = request.store or require("code-tour.ast.store").new(idx, ast.options),
    ids = {}, -- symbol -> "nK", stable for the tour's lifetime
    next_n = 0,
    snippets = {}, -- "nK" -> snippet (tour snippets and expanded ones)
    expanded = {}, -- "n1.s13>target" -> snippet built by `ad` on a lazy site
    synthetic = {}, -- "nK" -> { region… } added by selections (§7), re-applied on projection
    fps = {}, -- region address -> fingerprint at projection
    built = {}, -- "nK" -> root fingerprint when its skeleton was built (stale fill refusal)
  }, L)
  self:assemble()
  return self
end

-- The buffer of a repository file, loaded.
function L:buf(file)
  return buf_for(self.idx, file)
end

function L:id_for(symbol)
  local n = self.ids[symbol]
  if not n then
    self.next_n = self.next_n + 1
    n = "n" .. self.next_n
    self.ids[symbol] = n
  end
  return n
end

-- Give the snippets of a freshly assembled tour their stable ids, rewriting every
-- reference (`to`, gaps, route).
function L:renumber(tour)
  local map = {}
  for _, sn in ipairs(tour.snippets) do
    map[sn.n] = self:id_for(sn.symbol)
  end
  for _, sn in ipairs(tour.snippets) do
    sn.n = map[sn.n]
    for _, site in ipairs(sn.sites) do
      site.to = site.to and map[site.to] or site.to
    end
    for _, g in ipairs(sn.gaps) do
      g.n = sn.n
    end
  end
  for _, r in ipairs(tour.route) do
    r.from.n = map[r.from.n] or r.from.n
    r.to = r.to and map[r.to] or r.to
  end
end

-- Fingerprint every box of a snippet (root and regions) against current code.
function L:fingerprint(sn)
  local buf = buf_for(self.idx, sn.file, true)
  local sym = self.idx:symbol(sn.symbol)
  sn._fps = {}
  local root_fp = notes.fingerprint(buf, sym.range)
  sn._fps[sn.symbol] = root_fp
  self.fps[sn.symbol] = root_fp
  sn._relocation_fingerprint = notes.fingerprint(buf, sym.range, sym.name)
  for _, r in ipairs(sn.regions) do
    local fp = notes.fingerprint(buf, r._range)
    sn._fps[r.address] = fp
    self.fps[r.address] = fp
  end
  if not self.built[sn.n] then
    self.built[sn.n] = root_fp
  end
  local state = self.store.file_state and self.store:file_state(sn.file)
  sn._build_signature = state and state.signature
  sn._checked_signature = sn._build_signature
  sn._checked_tick, sn._changed = vim.api.nvim_buf_get_changedtick(buf), self.built[sn.n] ~= root_fp
end

-- Synthetic regions from selections (§7) are re-applied when their parent region still
-- exists at this detail: the parent is split into the selection and the runs around it.
function L:apply_synthetic(sn)
  local list = self.synthetic[sn.n]
  if not list or #list == 0 then
    return
  end
  require("code-tour.ast.expand").reapply(self, sn, list)
end

-- (Re)build the tour at self.detail from the rated tree.
function L:assemble()
  local tour = outline.assemble(self.prep, self.detail)
  self:renumber(tour)
  self.tour = tour
  for _, sn in ipairs(tour.snippets) do
    self.snippets[sn.n] = sn
    self:apply_synthetic(sn)
    self:fingerprint(sn)
  end
  for _, sn in pairs(self.expanded) do
    self.snippets[sn.n] = sn
  end
  self:apply_edge_notes()
  return tour
end

-- Every snippet currently projected, in walk order: tour snippets, with snippets
-- expanded by `ad` after the snippet they hang off.
function L:all()
  local out, seen = {}, {}
  local keys = vim.tbl_keys(self.expanded)
  -- site order (evaluation order), then target
  table.sort(keys, function(a, b)
    local sa, sb = tonumber(a:match("%.s(%d+)>")) or 0, tonumber(b:match("%.s(%d+)>")) or 0
    if sa ~= sb then
      return sa < sb
    end
    return a < b
  end)
  local function add(sn)
    if seen[sn] then
      return -- a snippet opened from two lazy sites is listed once
    end
    seen[sn] = true
    out[#out + 1] = sn
    -- expanded snippets hang off their parent, nested ones off the expanded snippet
    for _, key in ipairs(keys) do
      if key:match("^([^.]+)%.") == sn.n then
        add(self.expanded[key])
      end
    end
  end
  for _, sn in ipairs(self.tour.snippets) do
    add(sn)
  end
  return out
end

-- The address of a box: the symbol id for the overview, else the region's address.
function M.address(sn, region)
  return region and region.address or sn.symbol
end

function L:box_context(sn, region)
  return { file = sn.file, symbol = sn.symbol, relocation_fingerprint = not region and sn._relocation_fingerprint or nil }
end

function L:root_fingerprint(symbol)
  if self.store.region_fingerprint then
    return (self.store:region_fingerprint(symbol))
  end
  local sym = self.idx:symbol(symbol)
  if sym and sym.file and sym.range and sym.source ~= "library" then
    return notes.fingerprint(self:buf(sym.file), sym.range)
  end
end

-- The overview describes the whole flow. A smaller box records the walked calls
-- within its boundaries, including calls in projected child boxes.
function L:callees(sn, region)
  local out = {}
  for _, site in ipairs(sn.sites) do
    if site.target and (site.mode == "walk" or self.expanded[sn.n .. "." .. site.site .. ">" .. site.target])
        and (not region or regions.inside(site._range.start, region._range)) then
      out[site.target] = self.built[self.ids[site.target]] or self:root_fingerprint(site.target)
    end
  end
  return out
end

function L:edge_context(sn, site)
  local _, region = self:resolve_anchor(sn.n .. "." .. site.region)
  local address = M.address(sn, region)
  local occurrence = 0
  for _, other in ipairs(sn.sites) do
    if other.target == site.target and other.region == site.region then
      occurrence = occurrence + 1
    end
    if other == site then
      break
    end
  end
  return address, occurrence, sn._fps[address]
end

function L:apply_edge_notes()
  local route = {}
  for _, edge in ipairs(self.tour.route) do
    local from = edge.from.n .. "." .. edge.from.site
    route[from] = route[from] or {}
    route[from][#route[from] + 1] = edge
  end
  for _, sn in ipairs(self:all()) do
    for _, site in ipairs(sn.sites) do
      if site.target then
        if not site._edge_checked then
          site._why, site._edge_checked = site.why, true
        end
        local address, occurrence, caller = self:edge_context(sn, site)
        local why = not self:changed(sn) and self.store:edge(address, site.target, occurrence, caller, function()
          return self:root_fingerprint(site.target)
        end, sn.file)
        site.why = why or site._why
        for _, edge in ipairs(route[sn.n .. "." .. site.site] or {}) do
          if edge.to == site.to and edge.target == site.target then
            edge.why = site.why
          end
        end
      end
    end
  end
end

-- The notes lookup for one box (nil when missing or stale).
function L:lookup(sn, region)
  if sn._checked_tick and self:changed(sn) then
    return nil, "stale", "code changed"
  end
  local address = M.address(sn, region)
  local fp = sn._fps and sn._fps[address] or self.fps[address]
  return self.store:lookup(address, fp, self.detail, self:box_context(sn, region))
end

function L:status(sn, region)
  local found, status, reason = self:lookup(sn, region)
  if found then
    return found.exact and "fresh" or (found.body and "near" or "gist")
  end
  return status, reason
end

-- Whether a snippet's source changed since its skeleton was built, decided once per
-- buffer changedtick. Its regions, sites and fingerprints describe the old code, so its
-- notes are withheld (§3.5: stale text is never displayed) and structural operations are
-- refused until the tour is rebuilt.
function L:changed(sn)
  local buf = self:buf(sn.file)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local state = self.store.file_state and self.store:file_state(sn.file)
  local signature = state and state.signature
  if sn._checked_tick ~= tick or sn._checked_signature ~= signature then
    sn._checked_tick = tick
    sn._checked_signature = signature
    sn._changed = self.built[sn.n] ~= nil and self:source_changed(sn)
  end
  return sn._changed
end

-- Snippets whose source changed, in walk order.
function L:changed_snippets()
  local out = {}
  for _, sn in ipairs(self:all()) do
    if self:changed(sn) then
      out[#out + 1] = sn
    end
  end
  return out
end

M.changed_note = "Source changed since this tour was built; rebuild it with code-tour ast."

-- Box presentation for project.lua.
function L:presentation(sn, region)
  if sn._checked_tick and self:changed(sn) then
    return { note = M.changed_note, changed = true }
  end
  local found = self:lookup(sn, region)
  local view = project.box_note(found)
  local example = found and found.note and found.note.example
  if self.detail ~= "overview" and example then
    view.example = example
    view.note = view.note .. ("\n\n**Example (%s)**\n\n%s"):format(example.source, example.text)
  end
  return view
end

-- The Q&A thread of a box (kept with the region's note, §3.5); hidden with the note when
-- the snippet's source changed.
function L:thread(sn, region)
  if sn._checked_tick and self:changed(sn) then
    return {}
  end
  local address = M.address(sn, region)
  return self.store:thread(address, sn._fps[address], self:box_context(sn, region))
end

function L:save_turn(sn, region, turn)
  if self:changed(sn) then
    return
  end
  local address = M.address(sn, region)
  local ctx = self:box_context(sn, region)
  ctx.callees = self:callees(sn, region)
  turn.id = turn.id or (tostring(vim.uv.os_getpid()) .. "-" .. tostring(vim.uv.hrtime()))
  return self.store:save_turn(address, sn._fps[address], turn, ctx)
end

function L:previous(sn, region)
  if self:status(sn, region) == "stale" then
    local address = M.address(sn, region)
    return self.store:previous(address, sn._fps[address], self:box_context(sn, region))
  end
end

function L:remember()
  local recipe = self.recipe
  for _, id in ipairs(vim.list_extend(vim.deepcopy(recipe.entries), recipe.through)) do
    local sym = self.idx:symbol(id)
    local sn = self.snippets[self.ids[id]]
    if sym and (not sn or not self:changed(sn)) then
      recipe.symbols[id] = { fingerprint = relocation(self.idx, sym), kind = sym.kind, file = sym.file }
    end
  end
  -- route endpoints keep the same evidence, so a rebuild after a rename can find them again
  local resolver = require("code-tour.ast.route").new(self.idx)
  for _, op in ipairs(recipe.overrides or {}) do
    if op.kind == "route" then
      for _, key in ipairs({ "from", "to" }) do
        local ids = resolver:resolve_entry(op[key])
        local sym = ids and #ids == 1 and self.idx:symbol(ids[1])
        if sym and sym.range and not sym.implicit then
          recipe.symbols[op[key]] = { fingerprint = relocation(self.idx, sym), kind = sym.kind, file = sym.file }
        end
      end
    end
  end
  recipe.id = recipe.id or vim.fn.sha256(vim.json.encode({ recipe.entries, recipe.through, recipe.auto or false })):sub(1, 16)
  recipe.last_opened = os.time()
  self.store:remember(recipe)
  return recipe.id
end

-- The stops of the whole tour (§3.7).
function L:stops()
  self:apply_edge_notes()
  return project.stops(self)
end

-- The stop of one snippet, without call-only fields.
function L:snippet_stop(n)
  return project.snippet(self, assert(self.snippets[n], "no snippet " .. tostring(n)))
end

-- Parse "n1", "n1.r2", "n1.s13>target" into snippet and region (nil for the overview).
function L:resolve_anchor(anchor)
  local n, rest = anchor:match("^(n%d+)%.?(.*)$")
  local sn = n and self.snippets[n]
  if not sn then
    return nil
  end
  if rest == "" or rest == "overview" then
    return sn, nil
  end
  for _, r in ipairs(sn.regions) do
    if r.id == rest then
      return sn, r
    end
  end
  return sn, nil, rest
end

-- The boxes of a snippet that still need writing at this detail, with reasons (§9.2):
-- { {id = "overview"|"rK", reason?} }. A root whose child needs writing is `linked`.
function L:to_write(sn)
  local out = {}
  local child = false
  local function reason(st, why)
    if st == "stale" then
      return why or "code changed"
    elseif st == "gist" or st == "near" then
      return "level missing"
    end
  end
  for _, r in ipairs(sn.regions) do
    local st, why = self:status(sn, r)
    if st == "stale" then
      child = true
    end
    if st ~= "fresh" then
      out[#out + 1] = { id = r.id, reason = reason(st, why), stale = st == "stale" or nil }
    end
  end
  -- the root's fingerprint covers its children, so a code change inside the method makes
  -- the overview stale too; it is listed as `linked` when only a child is the cause
  local st, stale_reason = self:status(sn, nil)
  if st ~= "fresh" then
    local why = reason(st, stale_reason)
    if st == "stale" and child then
      why = "linked"
    end
    table.insert(out, 1, { id = "overview", reason = why, stale = st == "stale" or nil, stale_reason = stale_reason })
  end
  return out
end

function L:stale()
  local out = {}
  for _, sn in ipairs(self:all()) do
    for _, box in ipairs(self:to_write(sn)) do
      if box.stale then
        out[#out + 1] = { n = sn.n, box = box.id, reason = box.stale_reason or box.reason, label = sn.label }
      end
    end
  end
  return out
end

function L:write_status(sn)
  local list = self:to_write(sn)
  if #list == 0 then
    return "fresh"
  end
  -- "overview r1-r4", with reasons in parentheses after the boxes they apply to (§9.2)
  local items = {}
  local k = 1
  while k <= #list do
    local b = list[k]
    local num = b.id:match("^r(%d+)$")
    local j = k
    if num and not b.reason then
      while list[j + 1] and not list[j + 1].reason and list[j + 1].id == ("r" .. (tonumber(list[j].id:sub(2)) + 1)) do
        j = j + 1
      end
    end
    items[#items + 1] = (j > k and (b.id .. "-" .. list[j].id) or b.id) .. (b.reason and (" (" .. b.reason .. ")") or "")
    k = j + 1
  end
  return "write: " .. table.concat(items, " ")
end

-- Snippets with boxes to write, in walk order.
function L:pending()
  local out = {}
  for _, sn in ipairs(self:all()) do
    if #self:to_write(sn) > 0 then
      out[#out + 1] = sn
    end
  end
  return out
end

-- The fill command for snippet ids (§9.3); `<n>` when n is nil.
function L:fill_command(cli, servername, token, n)
  return ("%s --fill %s --pane %s --tour %s --detail %s"):format(vim.fn.shellescape(cli), n or "<n>",
    vim.fn.shellescape(servername), token, self.detail)
end

-- The outline (§9.2) with real statuses. ctx: { token, cli, servername }.
function L:outline(ctx)
  local all = self:all()
  local writing = #self:pending()
  local gaps = #self.tour.gaps
  local header = ("tour %s · %s · %d snippets · %d to write · %d gap%s · fill: %s"):format(ctx.token, self.detail,
    #all, writing, gaps, gaps == 1 and "" or "s", self:fill_command(ctx.cli, ctx.servername, ctx.token))
  local view = { detail = self.detail, snippets = all, gaps = self.tour.gaps, warnings = self.tour.warnings }
  return outline.text(view, {
    header = header,
    ctx = ctx,
    status = function(sn)
      return self:write_status(sn)
    end,
  })
end

-- The outline lines of some snippets only (requests carry only what they concern, §9.5).
function L:snippet_outline(list)
  local out = {}
  for _, sn in ipairs(list) do
    vim.list_extend(out, outline.snippet_lines(sn, function(x)
      return self:write_status(x)
    end))
  end
  return table.concat(out, "\n")
end

-- §9.4: a fill is refused for a snippet whose source changed since its skeleton was built.
function L:source_changed(sn)
  local buf = self:buf(sn.file)
  local sym = self.idx:symbol(sn.symbol)
  local state = self.store.file_state and self.store:file_state(sn.file)
  local signature = state and state.signature
  if signature ~= sn._build_signature and self:root_fingerprint(sn.symbol) ~= self.built[sn.n] then
    return true
  end
  return notes.fingerprint(buf, sym.range) ~= self.built[sn.n]
end

-- Agent pieces. Each is implemented in its own module and documented there.
-- fill.lua:   L:fill(n, payload, opts) -> result, updates
-- expand.lua: L:expand(anchor) -> sn, stop, needs_writing ; L:select(n, range) -> …
-- detail.lua: L:set_detail(detail) -> …
function L:fill(n, payload, opts)
  return require("code-tour.ast.fill").apply(self, n, payload, opts)
end

function L:expand(anchor)
  return require("code-tour.ast.expand").lazy(self, anchor)
end

function L:select(n, range)
  return require("code-tour.ast.expand").selection(self, n, range)
end

function L:set_detail(detail)
  return require("code-tour.ast.detail").change(self, detail)
end

-- A box's current presentation by anchor, for re-rendering in place after a fill.
function L:box(anchor)
  local sn, region = self:resolve_anchor(anchor)
  if not sn then
    return nil
  end
  return self:presentation(sn, region)
end

M.L = L
return M
