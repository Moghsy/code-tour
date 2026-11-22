-- Region selection (SPEC-ast-graph §7): a symbol's statement tree becomes the regions
-- that carry explanation boxes. Deterministic; computed from the coarsest detail to the
-- finest, each finer level only adding boundaries inside the regions of the coarser one.
--
-- A region:
--   { address, kind, origin, range = byte range (token to token), span = {first, last}
--     (1-based lines; siblings tile their parent), children, facts, sites = {ids},
--     list, i, j (the statement list and the indices it covers) }
local M = {}

M.levels = { "overview", "normal", "detailed", "exhaustive" }
M.params = {
  overview = nil, -- one box per snippet
  normal = { min = 3, target = 8, max = 15, short = 6 },
  detailed = { min = 3, target = 6, max = 12, short = 5 },
  exhaustive = { min = 2, target = 5, max = 10, short = 4, split_arms = true },
}

local compound_kind = {
  if_statement = "branch",
  for_statement = "loop",
  enhanced_for_statement = "loop",
  while_statement = "loop",
  do_statement = "loop",
  try_statement = "try",
  try_with_resources_statement = "try",
  switch_statement = "switch",
  switch_expression = "switch",
}
local compound = {
  synchronized_statement = true,
  labeled_statement = true,
  block = true,
}
for k in pairs(compound_kind) do
  compound[k] = true
end
local multi_arm = { if_statement = true, try_statement = true, try_with_resources_statement = true,
  switch_statement = true, switch_expression = true }

local function le(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end
local function inside(pos, r)
  return le(r.start, pos) and not le(r["end"], pos)
end
M.inside = inside

-- First row of a statement, counting a leading comment.
local function lead(st)
  return st.comment_before and st.comment_start or st.range.start
end
local function rows(first, last)
  return last[1] - first[1] + 1
end
local function stmt_lines(st)
  return rows(st.range.start, st.range["end"])
end
local function group_lines(list, i, j)
  return rows(lead(list[i]), list[j].range["end"])
end

-- A boundary between two statements needs a line between them, since boxes are lines.
local function separable(prev, st)
  return lead(st)[1] > prev.range["end"][1]
end

local function arms_terminate(st)
  if #st.arms == 0 then
    return false
  end
  local function ends(stmts)
    local last = stmts[#stmts]
    if not last then
      return false
    end
    if last.kind == "return_statement" or last.kind == "throw_statement" then
      return true
    end
    if (last.kind == "if_statement" and #last.arms == 2) or last.kind == "block" then
      return arms_terminate(last)
    end
    return false
  end
  for _, a in ipairs(st.arms) do
    if not ends(a.stmts) then
      return false
    end
  end
  return st.kind ~= "if_statement" or #st.arms == 2
end
M.arms_terminate = arms_terminate

-- The locals a declaration statement introduces (body.locals entries).
local function declared(body, st)
  local out = {}
  for _, l in ipairs(body.locals) do
    if l.kind == "local" and inside(l.declared_at, st.range) then
      out[#out + 1] = l
    end
  end
  return out
end

local function uses_within(body, st, ranges)
  local locals = declared(body, st)
  if #locals == 0 then
    return false
  end
  for _, l in ipairs(locals) do
    if #l.uses == 0 then
      return false
    end
    for _, u in ipairs(l.uses) do
      local ok = false
      for _, r in ipairs(ranges) do
        ok = ok or inside(u.at, r)
      end
      if not ok then
        return false
      end
    end
  end
  return true
end

local function is_decl(st)
  return st.kind == "local_variable_declaration"
end

-- §7 roles, by the first test that matches. info.main: site ids on the main flow;
-- info.effect(site id): its target has an effect.
function M.roles(body, list, info)
  info = info or {}
  local main, effect = info.main or {}, info.effect or function()
    return false
  end
  local roles = {}
  local n = #list
  -- guards, and the declarations that only compute what a guard run tests (rule 3)
  for i, st in ipairs(list) do
    if st.guard then
      roles[i] = "guard"
    end
  end
  local function has_main(st)
    for _, id in ipairs(st.sites) do
      if main[id] then
        return true
      end
    end
    return false
  end
  for i = n, 1, -1 do
    -- a declaration holding a main-flow call is the flow itself, not a guard's computation
    if not roles[i] and is_decl(list[i]) and not has_main(list[i]) then
      local ranges, k = {}, i + 1
      while k <= n and (list[k].guard or is_decl(list[k])) do
        if list[k].guard then
          ranges[#ranges + 1] = list[k].range
        end
        k = k + 1
      end
      if #ranges > 0 and uses_within(body, list[i], ranges) then
        roles[i] = "guard"
      end
    end
  end
  -- the trailing result run
  local last = list[n]
  if last and not roles[n] and (last.kind == "return_statement"
      or ((last.kind == "if_statement" or last.kind:match("^switch")) and arms_terminate(last))) then
    roles[n] = "result"
    local ranges = { last.range }
    for i = n - 1, 1, -1 do
      if roles[i] or not is_decl(list[i]) or not uses_within(body, list[i], ranges) then
        break
      end
      roles[i] = "result"
      ranges[#ranges + 1] = list[i].range
    end
  end
  for i, st in ipairs(list) do
    if not roles[i] then
      local mains, effects = {}, false
      for _, id in ipairs(st.sites) do
        if main[id] then
          mains[#mains + 1] = id
        end
        effects = effects or effect(id)
      end
      local local_write = st.value and ((st.value.k == "assign" and not st.value.field) or st.value.k == "update")
      if (st.kind == "expression_statement" or is_decl(st)) and #mains == 1 and effect(mains[1]) then
        roles[i] = "delegate"
      elseif #st.field_writes > 0 or effects or compound[st.kind] then
        roles[i] = "work"
      elseif is_decl(st) or local_write then
        roles[i] = "setup"
      else
        roles[i] = "mixed"
      end
    end
  end
  return roles
end

local function walked_in(st, walked)
  for _, id in ipairs(st.sites) do
    if walked[id] then
      return true
    end
  end
  return false
end

-- Rules 1–4 and 6 over list[a..b]: groups of statement indices {i, j}.
local function group(list, a, b, p, roles, walked)
  local groups, cur = {}, nil
  local function big(st)
    return compound[st.kind] and stmt_lines(st) > 3
  end
  for i = a, b do
    local st = list[i]
    if cur then
      local prev = list[i - 1]
      local close = false
      local in_guard_run = roles[i] == "guard" and roles[i - 1] == "guard"
      if st.comment_before then
        close = true -- a leading comment opens the new region
      elseif walked_in(prev, walked) then
        close = true -- rule 4: a walked call ends a beat
      elseif (roles[i] == "guard") ~= (roles[i - 1] == "guard") then
        close = true -- rule 3: a guard run is one region
      elseif not in_guard_run and (big(st) or cur.big) then
        close = true -- rule 1: a long compound statement is its own region
      elseif not in_guard_run and group_lines(list, cur.i, cur.j) >= p.min then
        close = st.blank_before or group_lines(list, cur.i, i) > p.target or roles[i] ~= roles[i - 1]
      end
      if close and separable(prev, st) then
        groups[#groups + 1] = cur
        cur = nil
      end
    end
    if cur then
      cur.j = i
      cur.big = cur.big or big(st)
    else
      cur = { i = i, j = i, big = big(st) }
    end
  end
  if cur then
    groups[#groups + 1] = cur
  end
  -- rule 6: runts merge into their smaller neighbor
  local function guard_run(g)
    for k = g.i, g.j do
      if roles[k] ~= "guard" then
        return false
      end
    end
    return true
  end
  local function has_walked(g)
    for k = g.i, g.j do
      if walked_in(list[k], walked) then
        return true
      end
    end
    return false
  end
  local changed = true
  while changed do
    changed = false
    for k, g in ipairs(groups) do
      local size = group_lines(list, g.i, g.j)
      if size < p.min and not guard_run(g) and not has_walked(g) then
        local prev, nxt = groups[k - 1], groups[k + 1]
        if prev and (guard_run(prev) or walked_in(list[prev.j], walked)) then
          prev = nil -- merging would put code after a walked call, or spoil a guard run
        end
        if nxt and guard_run(nxt) then
          nxt = nil
        end
        local into
        if prev and nxt then
          into = group_lines(list, prev.i, prev.j) <= group_lines(list, nxt.i, nxt.j) and prev or nxt
        else
          into = prev or nxt
        end
        if into then
          into.i, into.j = math.min(into.i, g.i), math.max(into.j, g.j)
          into.big = into.big or g.big
          table.remove(groups, k)
          changed = true
          break
        end
      end
    end
  end
  return groups
end

local function arm_name(a)
  return a.index and (a.name .. "[" .. a.index .. "]") or a.name
end

local function facts_of(body, list, i, j)
  local facts = { locals = {}, fields = {}, guards = {} }
  local seen = {}
  for k = i, j do
    local st = list[k]
    for _, name in ipairs(st.locals or {}) do
      facts.locals[#facts.locals + 1] = name
    end
    for _, w in ipairs(st.field_writes) do
      local key = (w.object == "this" and "" or (w.object .. ".")) .. w.name
      if not seen[key] then
        seen[key] = true
        facts.fields[#facts.fields + 1] = key
      end
    end
    if st.guard and st.condition then
      facts.guards[#facts.guards + 1] = st.condition
    end
    if st.kind == "enhanced_for_statement" then
      for _, l in ipairs(body.locals) do
        if l.kind == "for" and l.subject and inside(l.declared_at, st.range) and not facts.subject then
          facts.subject = l.subject
        end
      end
    elseif compound_kind[st.kind] == "loop" and st.condition then
      facts.subject = facts.subject or st.condition
    end
    if (st.kind == "if_statement" and not st.guard) or st.kind:match("^switch") then
      facts.branch = facts.branch or st.condition
    end
  end
  return facts
end

local function kind_of(list, i, j, roles)
  local role = roles[i]
  local all_guard = true
  for k = i, j do
    all_guard = all_guard and roles[k] == "guard"
  end
  if all_guard then
    return "guard"
  end
  if i == j and compound_kind[list[i].kind] then
    return compound_kind[list[i].kind]
  end
  for k = i + 1, j do
    if roles[k] ~= role then
      return "mixed"
    end
  end
  return role
end

local select_list

-- Child regions of one region that is a single compound statement (rule 5).
local function arm_children(ctx, st, address, p, coarse)
  local arms = st.arms
  if #arms == 0 then
    return nil
  end
  for k = 2, #arms do
    if arms[k].range.start[1] <= arms[k - 1].range.start[1] then
      return nil -- arms sharing a line cannot be separate boxes
    end
  end
  if #arms == 1 then
    -- one arm (a loop body, a lone then): its statements are the children
    local path = address .. "/" .. arm_name(arms[1])
    return select_list(ctx, arms[1].stmts, path, rows(arms[1].range.start, arms[1].range["end"]), p,
      coarse and coarse.children)
  end
  local out = {}
  for k, a in ipairs(arms) do
    local path = address .. "/" .. arm_name(a)
    local coarse_arm = coarse and coarse.children and coarse.children[k]
    local roles = M.roles(ctx.body, a.stmts, ctx.info)
    local kind = #a.stmts > 0 and kind_of(a.stmts, 1, #a.stmts, roles) or "mixed"
    if a.name == "catch" or a.name == "finally" then
      kind = kind == "mixed" and "try" or kind
    end
    out[#out + 1] = {
      address = path,
      kind = kind,
      origin = "syntactic",
      range = a.range,
      list = a.stmts,
      i = 1,
      j = #a.stmts,
      arm = a,
      facts = #a.stmts > 0 and facts_of(ctx.body, a.stmts, 1, #a.stmts) or {},
      children = select_list(ctx, a.stmts, path, rows(a.range.start, a.range["end"]), p,
        coarse_arm and coarse_arm.children) or {},
    }
  end
  return out
end

-- Regions for a statement list: nil when it gets no children (too short, or one group).
-- `coarse` is the coarser level's children of the same container, whose boundaries are kept.
function select_list(ctx, list, path, lines, p, coarse)
  if coarse and #coarse == 0 then
    coarse = nil
  end
  if #list == 0 or (not coarse and lines <= p.short) then
    return nil
  end
  local roles = M.roles(ctx.body, list, ctx.info)
  local segments = {}
  if coarse and #coarse > 0 and coarse[1].list == list then
    for _, c in ipairs(coarse) do
      segments[#segments + 1] = { c.i, c.j, c }
    end
  else
    segments[1] = { 1, #list }
  end
  local groups = {}
  for _, seg in ipairs(segments) do
    for _, g in ipairs(group(list, seg[1], seg[2], p, roles, ctx.walked)) do
      g.coarse = seg[3]
      groups[#groups + 1] = g
    end
  end
  if #groups < 2 then
    return nil
  end
  local out = {}
  for _, g in ipairs(groups) do
    local first, last = list[g.i], list[g.j]
    local address = path .. "/stmts[" .. g.i .. (g.j > g.i and (".." .. g.j) or "") .. "]"
    local region = {
      address = address,
      kind = kind_of(list, g.i, g.j, roles),
      origin = g.i == g.j and "syntactic" or "synthetic",
      range = { start = lead(first), ["end"] = last.range["end"] },
      list = list,
      i = g.i,
      j = g.j,
      facts = facts_of(ctx.body, list, g.i, g.j),
      children = {},
    }
    -- rule 5: a single compound statement longer than max (or, at exhaustive, every
    -- multi-arm statement) is split along its arms
    local coarse_same = g.coarse and g.coarse.i == g.i and g.coarse.j == g.j and g.coarse or nil
    if g.i == g.j and compound[first.kind] then
      local long = stmt_lines(first) > p.max or (p.split_arms and multi_arm[first.kind] and #first.arms > 1)
      if long or (coarse_same and #coarse_same.children > 0) then
        region.children = arm_children(ctx, first, address, p, coarse_same) or {}
      end
    end
    out[#out + 1] = region
  end
  return out
end

-- Tile spans: children cover their parent's lines exactly; gaps go to the preceding child.
local function tile(region)
  local kids = region.children
  for k, c in ipairs(kids) do
    local first = k == 1 and region.span[1] or (c.range.start[1] + 1)
    local last = kids[k + 1] and kids[k + 1].range.start[1] or region.span[2]
    c.span = { first, last }
    tile(c)
  end
end

-- Regions of one symbol at one detail. info: { walked = {site id = true}, main, effect }.
-- Returns the root region, whose descendants (preorder) are the boxes r1, r2, …
function M.select(sym, body, detail, info)
  info = info or {}
  local root = {
    address = sym.id,
    kind = "root",
    origin = "syntactic",
    range = sym.range,
    span = { sym.range.start[1] + 1, sym.range["end"][1] + 1 },
    list = body and body.stmts or {},
    i = 1,
    j = body and #body.stmts or 0,
    facts = body and #body.stmts > 0 and facts_of(body, body.stmts, 1, #body.stmts) or {},
    children = {},
  }
  if sym.source == "agent" then
    root.source, root.origin = "agent", "agent"
    for _, region in ipairs(sym.agent_regions) do
      root.children[#root.children + 1] = {
        address = region.address,
        kind = "mixed",
        source = "agent",
        origin = "agent",
        range = region.range,
        span = { region.range.start[1] + 1, region.range["end"][1] + 1 },
        facts = {},
        children = {},
      }
    end
    return root
  end
  if not body or detail == "overview" then
    return root
  end
  local ctx = { body = body, info = info, walked = info.walked or {} }
  local lines = root.span[2] - root.span[1] + 1
  -- coarsest first: each finer level refines the one below it (nesting across levels)
  local coarse
  for _, level in ipairs(M.levels) do
    local p = M.params[level]
    if p then
      coarse = select_list(ctx, body.stmts, sym.id .. "/body", lines, p, coarse) or coarse
      if level == detail then
        break
      end
    end
  end
  root.children = coarse or {}
  tile(root)
  return root
end

-- Resolve the syntax named by a saved address independently of a tour's grouping.
function M.range_at(sym, body, address)
  if address == sym.id then
    return sym.range
  end
  local prefix = sym.id .. "/body/"
  if not body or address:sub(1, #prefix) ~= prefix then
    return nil
  end
  local list, stmt, range = body.stmts
  for part in address:sub(#prefix + 1):gmatch("[^/]+") do
    if list then
      local first, last = part:match("^stmts%[(%d+)%.%.(%d+)%]$")
      first = tonumber(first or part:match("^stmts%[(%d+)%]$"))
      last = tonumber(last) or first
      if not first or not list[first] or not list[last] or first > last then
        return nil
      end
      range = { start = lead(list[first]), ["end"] = list[last].range["end"] }
      stmt, list = first == last and list[first] or nil, nil
    else
      for _, arm in ipairs(stmt and stmt.arms or {}) do
        if arm_name(arm) == part then
          list, range = arm.stmts, arm.range
          break
        end
      end
      if not list then
        return nil
      end
    end
  end
  return range
end

-- Preorder list of the boxes below the root, numbered r1, r2, …
function M.flatten(root)
  local out = {}
  local function walk(r)
    for _, c in ipairs(r.children) do
      out[#out + 1] = c
      c.id = "r" .. #out
      walk(c)
    end
  end
  walk(root)
  return out
end

-- The deepest region containing a byte position.
function M.deepest(root, pos)
  local best = root
  local function walk(r)
    for _, c in ipairs(r.children) do
      if inside(pos, c.range) then
        best = c
        walk(c)
        return
      end
    end
  end
  walk(root)
  return best
end

-- §7 selections: the smallest region containing `range` when the selection touches all
-- of its statements; otherwise a synthetic child for the statements it touches.
function M.at(root, range)
  local function contains(r)
    return le(r.start, range.start) and le(range["end"], r["end"])
  end
  local best = root
  local function walk(r)
    for _, c in ipairs(r.children) do
      if contains(c.range) then
        best = c
        walk(c)
        return
      end
    end
  end
  walk(root)
  local list = best.list or {}
  local first, last
  for k = best.i or 1, best.j or #list do
    local st = list[k]
    local r = st and { start = lead(st), ["end"] = st.range["end"] }
    if r and le(range.start, r["end"]) and le(r.start, range["end"]) and not le(r["end"], range.start) then
      first, last = first or k, k
    end
  end
  if not first or (first == (best.i or 1) and last == (best.j or #list)) then
    return best
  end
  local base = best.address
  if best.arm then
    -- an arm region: its statements are addressed below it
  elseif best.kind ~= "root" then
    base = best.address:gsub("/stmts%[[%d.]+%]$", "")
  else
    base = best.address .. "/body"
  end
  return {
    address = base .. "/stmts[" .. first .. (last > first and (".." .. last) or "") .. "]",
    kind = "mixed",
    origin = "synthetic",
    range = { start = lead(list[first]), ["end"] = list[last].range["end"] },
    list = list,
    i = first,
    j = last,
    parent = best,
    children = {},
    synthetic = true,
  }
end

return M
