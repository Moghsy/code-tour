-- `ad` on lazy sites and selections on a live AST tour (SPEC-ast-graph §7, §9.5, §3.7).
--
--   lazy(live, anchor)          -> sn, stop_input, needs_writing
--   rebuild(live, sn)           -> sn (an expanded snippet re-selected at live.detail)
--   selection(live, n, range)   -> { sn, boxes, synthetic, stop? }
--   reapply(live, sn, list)     re-applies recorded synthetic splits after assemble()
--
-- Lazy sites (§9.5). The plugin builds the target's regions and its own sites, all
-- `lazy`, and inserts the snippet in place of the lazy call. The target gets a route-like
-- node of its own (route.R:tree's node shape), rated like the tree rates (labels,
-- then the agent's route) so the outline reads the same, but nothing below it is expanded:
-- every rated edge is lazy, why "not in the route" or "detail". Edges to a symbol the tour
-- already shows are `ref` (§8.2: "target on the current path, or already visited"), so
-- expanding them never builds a second snippet with the same id.
--
-- Selections (§7). A selection maps to the smallest region containing it; a few
-- statements inside a large leaf region split that leaf into synthetic children (the
-- selected statements and the runs before and after them). The split is recorded in
-- live.synthetic[n] and re-applied whenever the snippet is rebuilt.
local outline = require("code-tour.ast.outline")
local regions = require("code-tour.ast.regions")
local project = require("code-tour.ast.project")

local M = {}

-- Lazy sites ----------------------------------------------------------------------------

-- Symbols the tour currently shows, by symbol id -> n.
local function shown(live)
  local out = {}
  for _, sn in ipairs(live:all()) do
    out[sn.symbol] = sn.n
  end
  return out
end

-- The route-like node of a lazily expanded target (route.R:tree's node shape). in_eff
-- is the effective rating of the lazy edge that reached it (§8.2), 9 when unrated.
function M.node(live, target, depth, in_eff)
  local rt = live.prep.rt
  local body, sym = rt:body(target)
  assert(sym and sym.file and sym.range and sym.source ~= "library", "No project source for " .. tostring(target))
  local node = { symbol = target, sym = sym, body = body, depth = depth, eff = in_eff, main = false, edges = {},
    parent = nil }
  for _, s in ipairs(body and body.sites or {}) do
    local ts, built = rt:targets(s, body, sym)
    if #ts == 0 or s.kind == "accessor" then
      node.edges[#node.edges + 1] = { site = s, label = s.kind == "accessor" and "accessor" or "unresolved" }
    else
      for _, t in ipairs(ts) do
        local e = { site = s, target = t.symbol, confidence = t.confidence, via = t.via, choice = #ts > 1 or nil,
          candidates = #ts > 1 and #ts or nil, built = built }
        -- a lazily opened callee offers only what the agent's route names; the rest stays lazy
        if s.rating_override ~= nil then
          e.rating = s.rating_override
        else
          e.rating, e.why = 9, "not in the route"
        end
        e.s = 0
        e.eff = math.max(e.rating, in_eff)
        node.edges[#node.edges + 1] = e
      end
    end
  end
  return node
end

-- Modes for an expanded node's edges: labels as labelled, `ref` to snippets already
-- shown (and to the node itself), every other edge lazy (§9.5: "its own sites (all lazy)").
local function modes(live, node, n)
  local seen = shown(live)
  seen[node.symbol] = n
  local mode = {}
  for _, e in ipairs(node.edges) do
    if e.label then
      mode[e] = { mode = e.label }
    elseif seen[e.target] then
      mode[e] = { mode = "ref", why = "already shown", to = seen[e.target] }
    else
      mode[e] = { mode = "lazy", why = e.why or "detail" }
    end
  end
  return mode
end

local function parse_key(anchor)
  local parent, site, target = tostring(anchor):match("^(n%d+)%.(s%d+)>(.+)$")
  return parent, site, target
end

-- Build (or rebuild) the snippet for an expansion key at live.detail.
local function build(live, key, node, n)
  local sn = outline.snippet(live.prep, node, n, modes(live, node, n), live.detail)
  sn._key = key
  sn._parent_n = (parse_key(key))
  live.expanded[key] = sn
  live.snippets[n] = sn
  local list = live.synthetic[n]
  if list and #list > 0 then
    M.reapply(live, sn, list)
  end
  live:fingerprint(sn)
  return sn
end

-- §9.5 `ad` on a lazy site. anchor = "nK.sJ>target". Returns sn, the stop input
-- (project.snippet) and whether any of its boxes still needs writing.
function M.lazy(live, anchor)
  local sn = live.expanded[anchor]
  if not sn then
    local pn, sid, target = parse_key(anchor)
    assert(pn, "Not a lazy call anchor: " .. tostring(anchor))
    local parent = assert(live.snippets[pn], "No snippet " .. pn)
    local site
    for _, x in ipairs(parent.sites) do
      if x.site == sid and x.target == target then
        site = x
      end
    end
    assert(site, ("No site %s → %s in %s"):format(sid, target, pn))
    assert(site.mode == "lazy", ("%s.%s is not lazy (%s)"):format(pn, sid, tostring(site.mode)))
    local n = live:id_for(target)
    -- the same target opened from another lazy site: one snippet per symbol, so it is
    -- shared (its notes, keyed by region address, are the same either way)
    for key, ex in pairs(live.expanded) do
      if ex.symbol == target and key ~= anchor then
        sn = ex
      end
    end
    if sn then
      live.expanded[anchor] = sn
    else
      local node = M.node(live, target, (parent.depth or 0) + 1, site.effective or 9)
      sn = build(live, anchor, node, n)
    end
  end
  return sn, project.snippet(live, sn), #live:to_write(sn) > 0
end

-- Re-select an expanded snippet's regions at live.detail (after a detail change, §8.6):
-- same n, same key, same node (no re-rating); synthetic splits re-applied.
function M.rebuild(live, sn)
  local key = assert(sn._key, "Not an expanded snippet: " .. tostring(sn.n))
  local new = build(live, key, sn._node, sn.n)
  -- other keys sharing this snippet follow it
  for k, ex in pairs(live.expanded) do
    if ex == sn then
      live.expanded[k] = new
    end
  end
  return new
end

-- Selections --------------------------------------------------------------------------

local function le(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end

-- First position of a statement, counting a leading comment (regions.lua `lead`).
local function lead(st)
  return st.comment_before and st.comment_start or st.range.start
end

-- Shrink a byte range to the code it covers: a line-wise selection starts at column 0
-- and ends at the end of the line, while regions start and end at tokens (§3.2).
local function trim(buf, range)
  local s, e = { range.start[1], range.start[2] }, { range["end"][1], range["end"][2] }
  local top = s[1]
  local lines = vim.api.nvim_buf_get_lines(buf, top, e[1] + 1, false)
  local function line(row)
    return lines[row - top + 1] or ""
  end
  while le(s, e) do
    local text = line(s[1])
    local col = text:find("%S", s[2] + 1)
    if col and (s[1] < e[1] or col - 1 < e[2]) then
      s[2] = col - 1
      break
    end
    if s[1] >= e[1] then
      return range
    end
    s = { s[1] + 1, 0 }
  end
  while le(s, e) do
    local text = line(e[1]):sub(1, e[2])
    local last = text:match("^.*()%S")
    if last and (e[1] > s[1] or last > s[2]) then
      e[2] = last
      break
    end
    if e[1] <= s[1] then
      return range
    end
    e = { e[1] - 1, #line(e[1] - 1) }
  end
  return { start = s, ["end"] = e }
end

-- Mechanical facts of statements list[i..j] (a subset of regions.lua `facts_of`).
local function facts_of(list, i, j)
  local facts = { locals = {}, fields = {}, guards = {} }
  local seen = {}
  for k = i, j do
    local st = list[k]
    vim.list_extend(facts.locals, st.locals or {})
    for _, w in ipairs(st.field_writes or {}) do
      local key = (w.object == "this" and "" or (w.object .. ".")) .. w.name
      if not seen[key] then
        seen[key] = true
        facts.fields[#facts.fields + 1] = key
      end
    end
    if st.guard and st.condition then
      facts.guards[#facts.guards + 1] = st.condition
    end
  end
  return facts
end

-- The address prefix the statements of a leaf region are addressed under (as
-- regions.at builds it): an arm's own address, a statement run's container, or the
-- root's body.
local function base_of(leaf)
  if leaf.arm then
    return leaf.address
  elseif leaf.kind == "root" then
    return leaf.address .. "/body"
  end
  return (leaf.address:gsub("/stmts%[[%d.]+%]$", ""))
end

-- Split a leaf region into synthetic children for statements i..j and the runs before
-- and after them. Returns the selected child, or nil when the split does not apply.
local function split(leaf, i, j)
  local list = leaf.list
  local a, b = leaf.i or 1, leaf.j or #(list or {})
  if not list or #leaf.children > 0 or i < a or j > b or i > j or (i == a and j == b) then
    return nil
  end
  local base = base_of(leaf)
  -- a subset of a region's statements shares their role; a root's pieces are mixed
  local kind = leaf.kind == "root" and "mixed" or leaf.kind
  local selected
  local function piece(x, y)
    local r = {
      address = base .. "/stmts[" .. x .. (y > x and (".." .. y) or "") .. "]",
      kind = kind,
      origin = "synthetic",
      range = { start = lead(list[x]), ["end"] = list[y].range["end"] },
      list = list,
      i = x,
      j = y,
      facts = facts_of(list, x, y),
      children = {},
    }
    leaf.children[#leaf.children + 1] = r
    return r
  end
  if i > a then
    piece(a, i - 1)
  end
  selected = piece(i, j)
  if j < b then
    piece(j + 1, b)
  end
  -- tile the spans like regions.select: children cover the parent's lines exactly, the
  -- lines between statements going to the preceding child
  local kids = leaf.children
  for k, c in ipairs(kids) do
    local first = k == 1 and leaf.span[1] or (c.range.start[1] + 1)
    local last = kids[k + 1] and kids[k + 1].range.start[1] or leaf.span[2]
    c.span = { first, last }
  end
  return selected
end

local function find(root, address)
  if root.address == address then
    return root
  end
  for _, c in ipairs(root.children) do
    local r = find(c, address)
    if r then
      return r
    end
  end
end

-- Rebuild a snippet's flat lists from its region tree (as outline.snippet does): regions
-- in preorder with parent ids, and the region of every site, gap, sink and fork.
-- Regions that already had an id keep it and new (synthetic) regions take the next free
-- numbers, so a box id handed out in an outline or fill command keeps naming the same
-- box after a selection splits a region (the list stays in preorder; ids need not be).
local function reflatten(sn)
  local root = sn._root
  local old, top = {}, 0
  for _, r in ipairs(sn.regions or {}) do
    old[r.address] = r.id
    top = math.max(top, tonumber(r.id:sub(2)) or 0)
  end
  local flat = regions.flatten(root)
  for _, r in ipairs(flat) do
    if old[r.address] then
      r.id = old[r.address]
    end
  end
  for _, r in ipairs(flat) do
    if not old[r.address] then
      top = top + 1
      r.id = "r" .. top
    end
  end
  local by_region, by_id = {}, {}
  sn.regions = {}
  for _, r in ipairs(flat) do
    local entry = { id = r.id, address = r.address, kind = r.kind, origin = r.origin,
      lines = { r.span[1], r.span[2] }, facts = r.facts, parent = nil, _region = r, _range = r.range }
    sn.regions[#sn.regions + 1] = entry
    by_region[r] = r.id
    by_id[r.id] = entry
  end
  for _, r in ipairs(sn.regions) do
    for _, c in ipairs(r._region.children) do
      by_id[by_region[c]].parent = r.id
    end
  end
  local function region_id(pos)
    return by_region[regions.deepest(root, pos)] or "overview"
  end
  local of_site = {}
  for _, s in ipairs(sn.sites) do
    local at = s._edge and s._edge.site and s._edge.site.at or s._range.start
    s.region = region_id(at)
    of_site[s.site] = s.region
  end
  for _, g in ipairs(sn.gaps or {}) do
    g.region = of_site[g.site] or region_id(g._range.start)
  end
  for _, k in ipairs(sn.sinks or {}) do
    k.region = of_site[k.site] or k.region
  end
  for _, f in ipairs(sn.forks or {}) do
    -- forks carry a line only: the deepest region whose lines hold it
    local best = "overview"
    for _, r in ipairs(sn.regions) do
      if r.lines[1] <= f.line and r.lines[2] >= f.line then
        best = r.id
      end
    end
    f.region = best
  end
end

local function region_id(sn, region)
  for _, r in ipairs(sn.regions) do
    if r._region == region then
      return r.id
    end
  end
  return "overview"
end

-- §7 selections. n: the snippet id (or a stop anchor "nK"); range: a byte range
-- {start = {row0, col}, ["end"] = {row0, col}}. Returns { sn, boxes = {id, …},
-- synthetic, stop? }: boxes[1] is the box the selection maps to; with a synthetic
-- split, the others are the new runs around it, and stop is the re-projected snippet.
function M.selection(live, n, range)
  n = tostring(n):match("^(n%d+)") or n
  local sn = assert(live.snippets[n], "No snippet " .. tostring(n))
  range = trim(live:buf(sn.file), range)
  local r = regions.at(sn._root, range)
  -- regions.at marks a region it creates (not yet in the tree) with `synthetic`
  if not r.synthetic then
    return { sn = sn, boxes = { region_id(sn, r) }, synthetic = false }
  end
  local leaf = r.parent
  if #leaf.children > 0 then
    -- the selection spans several child boxes (or parts of them): it maps to their
    -- parent box, which already explains them together; no structural change
    return { sn = sn, boxes = { region_id(sn, leaf) }, synthetic = false }
  end
  local selected = assert(split(leaf, r.i, r.j), "Selection does not split " .. leaf.address)
  live.synthetic[n] = live.synthetic[n] or {}
  table.insert(live.synthetic[n], { parent = leaf.address, i = r.i, j = r.j })
  reflatten(sn)
  live:fingerprint(sn)
  local boxes = { region_id(sn, selected) }
  for _, c in ipairs(leaf.children) do
    if c ~= selected then
      boxes[#boxes + 1] = region_id(sn, c)
    end
  end
  return { sn = sn, boxes = boxes, synthetic = true, stop = project.snippet(live, sn) }
end

-- Re-apply recorded synthetic splits to a freshly selected snippet (live:assemble and
-- rebuild). A split whose parent is no longer a leaf at this detail (a finer level split
-- it itself) or no longer exists is skipped, and kept for a later detail.
function M.reapply(live, sn, list)
  local changed = false
  for _, rec in ipairs(list) do
    local leaf = find(sn._root, rec.parent)
    if leaf and #leaf.children == 0 and split(leaf, rec.i, rec.j) then
      changed = true
    end
  end
  if changed then
    reflatten(sn)
  end
  return sn
end

local function siblings(root, left, right)
  for i, child in ipairs(root.children) do
    if child.address == left and root.children[i + 1] and root.children[i + 1].address == right then
      return root, i
    end
    local parent, index = siblings(child, left, right)
    if parent then
      return parent, index
    end
  end
end

local function statement_range(address)
  local base, first, last = address:match("^(.*)/stmts%[(%d+)%.%.(%d+)%]$")
  if not base then base, first = address:match("^(.*)/stmts%[(%d+)%]$") end
  return base, tonumber(first), tonumber(last or first)
end

-- Rerating can put the two adjacent regions into one group on its own.
local function already_merged(root, left, right)
  local base, first, last = statement_range(left)
  local other, start, finish = statement_range(right)
  if not base or base ~= other then return false end
  if finish + 1 == first then
    first, finish = start, last
  elseif last + 1 ~= start then
    return false
  end
  local region = find(root, ("%s/stmts[%d..%d]"):format(base, first, finish))
  return region ~= nil and #region.children == 0
end

function M.override(sn, op)
  if op.kind == "split" then
    local leaf = find(sn._root, op.address)
    if not leaf or not split(leaf, leaf.i or 1, op.statement - 1) then
      return nil, "split must be between statements of one region"
    end
  elseif op.kind == "merge" then
    local parent, i = siblings(sn._root, op.address, op.second)
    if not parent then
      parent, i = siblings(sn._root, op.second, op.address)
    end
    if not parent then
      if already_merged(sn._root, op.address, op.second) then return true end
      return nil, "merge requires adjacent regions under the same parent"
    end
    local a, b = parent.children[i], parent.children[i + 1]
    if not a.list or a.list ~= b.list or not a.j or not b.i or a.j + 1 ~= b.i
        or #a.children > 0 or #b.children > 0 then
      return nil, "merge requires consecutive leaf regions in one statement list"
    end
    parent.children[i] = {
      address = base_of(a) .. "/stmts[" .. a.i .. ".." .. b.j .. "]",
      kind = a.kind == b.kind and a.kind or "mixed",
      origin = "synthetic",
      range = { start = a.range.start, ["end"] = b.range["end"] },
      span = { a.span[1], b.span[2] },
      list = a.list,
      i = a.i,
      j = b.j,
      facts = facts_of(a.list, a.i, b.j),
      children = {},
    }
    table.remove(parent.children, i + 1)
  end
  reflatten(sn)
  return true
end

M._trim = trim
return M
