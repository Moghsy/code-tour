-- The route (SPEC-ast-graph §8): entries, the agent's flow, labels and ratings, and the
-- projection of one rated tree onto a detail level (cutoffs, budget, modes).
--
-- The plugin never decides what matters: the agent supplies the route as edges
-- (caller -> callee, level; 0 is the main walk, higher levels are optional branches) and
-- every call it did not name is lazy. Two passes from the entries, depth-first in
-- evaluation order:
--   main_flow  the agent's level-0 edges followed from the entries, with the facts about
--              them: sinks, hand-offs and gaps where the code cannot be followed (§8.3)
--   tree       every site labelled or rated (§8.2); targets rated within the widest
--              cutoff are expanded, so any detail is a projection of the same tree and
--              changing detail never re-rates (§8.6)
local regions = require("code-tour.ast.regions")
local parser_available = require("code-tour.ast.index").parser_available

local M = {}
local R = {}
R.__index = R

M.defaults = {
  cutoffs = {
    overview = { offer = 1, budget = 8 },
    normal = { offer = 3, budget = 15 },
    detailed = { offer = 4, budget = 30 },
    exhaustive = { offer = 5, budget = 80 },
  },
  main_cap = 40,
  max_depth = 8,
  through_depth = 12,
}

function M.new(idx, opts)
  local o = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return setmetatable({ idx = idx, r = idx.resolver, opts = o,
    memo = { success = {}, carriers = {}, effect = {} } }, R)
end

local inside = regions.inside

local function site_of(body, id)
  return id and body.sites[tonumber(id:sub(2))]
end
M.site_of = site_of

-- The sites in walk order: evaluation order, with jumps (§8.3.1) placed at their anchors.
-- Ids stay array indexes, so jumps are numbered after the calls and only `order` moves them.
local function ordered(body)
  if not body.order then
    return body.sites
  end
  local out = {}
  for _, i in ipairs(body.order) do
    out[#out + 1] = body.sites[i]
  end
  return out
end
M.ordered = ordered

local function file_lines(idx, file)
  local buf = require("code-tour.ast.index").buffer(idx:abs(file))
  local loaded = buf ~= nil
  if loaded and vim.bo[buf].modified then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  if vim.fn.filereadable(idx:abs(file)) == 1 then
    return vim.fn.readfile(idx:abs(file))
  end
  return loaded and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or {}
end

-- Where a jump hangs inside the symbol it leaves from: its `at` text (first occurrence, on
-- `line` when given), else the symbol's name on its first line, else that line's first word.
-- Returns { row, col, len } (0-based row and byte column) or nil and a reason.
function R:jump_anchor(id, jump)
  local sym = self.idx:symbol(id)
  if not (sym and sym.range and sym.file) then
    return nil, "no source for " .. tostring(id)
  end
  local lines = file_lines(self.idx, sym.file)
  local a, b = sym.range.start[1], sym.range["end"][1]
  if jump.line then
    local row = tonumber(jump.line) - 1
    if row < a or row > b then
      return nil, ("line %s is outside %s"):format(jump.line, sym.label or id)
    end
    a, b = row, row
  end
  for row = a, b do
    local line = lines[row + 1] or ""
    local from = row == sym.range.start[1] and sym.range.start[2] + 1 or 1
    if jump.at then
      local col = line:find(jump.at, from, true)
      if col then
        return { row = row, col = col - 1, len = #jump.at }
      end
    else
      local col = sym.name and line:find(sym.name, from, true)
      if col then
        return { row = row, col = col - 1, len = #sym.name }
      end
      local first, last = line:match("()%S+()", from)
      if first then
        return { row = row, col = first - 1, len = last - first }
      end
    end
  end
  if jump.at then
    return nil, ("no %q in %s"):format(jump.at, sym.label or id)
  end
  return nil, "nothing to hang the jump from in " .. (sym.label or id)
end

local function before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

-- A body with the symbol's jumps as sites of their own (kind "jump", via "jump").
function R:with_jumps(id, body)
  local jumps = self.jumps and self.jumps[id]
  if not (body and jumps and #jumps > 0) then
    return body
  end
  self.jump_bodies = self.jump_bodies or {}
  local hit = self.jump_bodies[id]
  if hit and hit.base == body then
    return hit.body
  end
  local out = vim.tbl_extend("force", body, { sites = vim.list_extend({}, body.sites) })
  local order = {}
  for i in ipairs(body.sites) do
    order[i] = i
  end
  if body.order then
    order = vim.list_extend({}, body.order)
  end
  for _, j in ipairs(jumps) do
    if j.anchor then
      local at = { j.anchor.row, j.anchor.col }
      local text = j.at or j.label
      local i = #out.sites + 1
      out.sites[i] = { id = "s" .. i, name = text, text = text, kind = "jump", jump = true, at = at,
        range = { start = at, ["end"] = { j.anchor.row, j.anchor.col + j.anchor.len } },
        targets = { { symbol = j.to, confidence = "INFERRED", source = "agent", via = "jump" } },
        rating_override = j.level }
      -- walked before the first call written after the anchor
      local k = #order + 1
      for pos, idx in ipairs(order) do
        local site = out.sites[idx]
        if site.at and before(at, site.at) then
          k = pos
          break
        end
      end
      table.insert(order, k, i)
    end
  end
  out.order = order
  self.jump_bodies[id] = { base = body, body = out }
  return out
end

-- A lambda that is stored or returned runs later, not during this method.
local function stored(s)
  return s.deferred ~= nil and s.deferred.call == nil
end

-- The level the agent's route gives one call site for a callee: an edge that names the site's
-- text beats one that names only the callee.
local function level_for(entries, site)
  local general
  for _, entry in ipairs(entries or {}) do
    if entry.site == nil then
      general = entry.level
    elseif entry.site == site.text then
      return entry.level
    end
  end
  return general
end

function R:body(id)
  local sym = self.idx:symbol(id)
  if not sym then
    return nil
  end
  local agent = self.agent_bodies and self.agent_bodies[id]
  local facts = not agent and self.r:resolve_file(sym.file) or nil
  local body = agent or (facts and facts.bodies[id])
  local edits = self.site_overrides and self.site_overrides[id]
  if body and edits then
    local original = body
    self.edited_bodies = self.edited_bodies or {}
    body = self.edited_bodies[id]
    if not body then
      body = vim.tbl_extend("force", original, { sites = {} })
      local occurrences = {}
      for i, site in ipairs(original.sites) do
        occurrences[site.text] = (occurrences[site.text] or 0) + 1
        local change = edits[site.text] and edits[site.text][occurrences[site.text]]
        if change then
          site = vim.tbl_extend("force", site, { rating_override = change.rating })
          if change.target and self.idx:symbol(change.target) then
            site.targets = { { symbol = change.target, confidence = "INFERRED", source = "agent", via = "agent" } }
            site.unresolved = nil
            if site.kind == "accessor" then
              site.kind = "call"
            end
          end
        end
        body.sites[i] = site
      end
      self.edited_bodies[id] = body
    end
  end
  body = self:with_jumps(id, body)
  local named = body and self.route and self.route[id]
  if named then
    -- the agent's route (caller -> callee, level): rate the sites that call a named callee
    self.routed_bodies = self.routed_bodies or {}
    local routed = self.routed_bodies[id]
    if not routed then
      routed = vim.tbl_extend("force", body, { sites = {} })
      for i, site in ipairs(body.sites) do
        local level
        for _, t in ipairs(not site.jump and site.targets or {}) do
          local l = level_for(named[t.symbol], site)
          if l then
            level = level == nil and l or math.min(level, l)
          end
        end
        if level == nil and site.declared then
          level = level_for(named[site.declared.symbol], site)
        end
        if level ~= nil and site.rating_override == nil then
          site = vim.tbl_extend("force", site, { rating_override = level })
        end
        routed.sites[i] = site
      end
      self.routed_bodies[id] = routed
    end
    body = routed
  end
  return body, sym, facts
end

function R:backend(sym)
  return self.idx:backend(sym.file) or {}
end

-- A library call listed by the backend (`sinks`, `handoffs`): "pkg.Type#method".
local function library_call(site, list)
  if site.unresolved ~= "library" or not site.receiver_type then
    return nil
  end
  local rt = site.receiver_type
  for _, entry in ipairs(list or {}) do
    local q, m = entry:match("^(.*)#(.*)$")
    if m == (site.library_name or site.name) then
      local simple = q:match("([^.]+)$")
      if rt == q or rt == simple or rt:sub(-#simple - 1) == "." .. simple then
        return entry
      end
    end
  end
end
M.library_call = library_call

-- Entries (§8.1) -------------------------------------------------------------------

function R:find_type(name)
  if name:find(".", 1, true) then
    local t = self.idx:type(name)
    if t then
      return t
    end
  end
  local simple = name:match("([^.]+)$")
  local found = {}
  for _, t in ipairs(self.idx:declarations_named(simple)) do
    if t.qname == name or t.qname:sub(-#name - 1) == "." .. name then
      found[#found + 1] = t
    end
  end
  if #found > 1 then
    local ids = vim.tbl_map(function(t)
      return t.id
    end, found)
    return nil, "ambiguous type " .. name .. ": " .. table.concat(ids, ", ")
  end
  return found[1]
end

local function type_entry(self, t)
  for _, id in ipairs(t.methods) do
    local m = self.idx:symbol(id)
    if m.name == "main" and m.static and #m.params == 1 and m.params[1].type
        and (m.params[1].type.name == "String[]" or m.params[1].varargs) then
      return { id }
    end
  end
  local out = {}
  for _, id in ipairs(t.methods) do
    local m = self.idx:symbol(id)
    if m.kind == "method" and m.modifiers and m.modifiers.public and not m.implicit then
      out[#out + 1] = id
    end
  end
  if #out == 0 then
    return nil, t.label .. " has no main and no public methods"
  end
  return out
end

-- An entry: a symbol id, `Type#m`, `Type#m(Params)`, `Type.m`, `path:line`, or a type.
-- Returns a list of symbol ids, or nil and a reason.
function R:resolve_entry(spec)
  spec = vim.trim(spec)
  local idx = self.idx
  if self.agent_bodies and self.agent_bodies[spec] then
    return { spec }
  end
  local language, qualified = spec:match("^(%a[%w_]*):(.+)$")
  if language == "java" then
    local backend = idx:backend("source.java")
    if not backend then return nil, "no backend for java" end
    if not parser_available(backend.parser) then return nil, "no parser for java" end
    local qname = qualified:match("^([^#]+)")
    if idx:type(qname) and idx:symbol(spec) then
      return { spec }
    end
    return nil, "no symbol " .. spec
  end
  for _, backend in ipairs(idx.backends) do
    if backend.module_name and (not language or language == backend.name) then
      if language and not parser_available(backend.parser) then
        return nil, "no parser for " .. backend.parser
      end
      local sym = idx:qualified_symbol(backend.name, qualified or spec)
      if sym then
        if sym.methods then
          if language then return { sym.id } end
          return type_entry(self, sym)
        end
        return { sym.id }
      elseif language then
        return nil, "no symbol " .. spec
      end
    end
  end
  local path, line = spec:match("^(.+):(%d+)$")
  if path and not path:find("#", 1, true) then
    -- Resolve relative paths against the project root, then the working directory.
    local absolute = path:sub(1, 1) == "/" and path or idx:abs(path)
    local rel = idx:rel(absolute)
    -- the caller's working directory (`idx.cwd`: the CLI's, which the editor does not share)
    local here = path:sub(1, 1) ~= "/" and idx.cwd and (idx.cwd .. "/" .. path) or path
    if not idx.file_set[rel] and idx.file_set[idx:rel(here)] then rel = idx:rel(here) end
    if not idx.file_set[rel] then
      if rel:sub(1, 1) ~= "/" and vim.uv.fs_stat(idx:abs(rel)) and not idx:backend(rel) then
        return nil, "no backend for " .. rel
      end
      return nil, "not a project file: " .. path
    end
    local facts, err = idx:facts(rel)
    if not facts then
      return nil, err
    end
    local row = tonumber(line) - 1
    local best, best_type
    for _, sym in pairs(facts.symbols) do
      local r = sym.range
      if r and r.start[1] <= row and row <= r["end"][1] then
        local size = r["end"][1] - r.start[1]
        if (sym.kind == "method" or sym.kind == "constructor" or sym.kind == "function") and not sym.implicit then
          if not best or size < best.size then
            best = { id = sym.id, size = size }
          end
        elseif sym.methods and sym.qname and (not best_type or size < best_type.size) then
          best_type = { sym = sym, size = size }
        end
      end
    end
    if best then
      return { best.id }
    end
    if best_type then
      return type_entry(self, best_type.sym)
    end
    if facts.error then return nil, "parse error in " .. rel end
    return nil, "no symbol at " .. spec
  end
  if language then return nil, "no backend for " .. language end
  local head, params = spec:match("^([^(]*)(%b())$")
  head = head or spec
  local type_part, member = head:match("^([^#]+)#(.+)$")
  if not type_part then
    if not params then
      local t, err = self:find_type(head)
      if err then
        return nil, err
      end
      if t then
        return type_entry(self, t)
      end
    end
    type_part, member = head:match("^(.+)%.([^.]+)$")
    if not type_part then
      return nil, "no type " .. spec
    end
  end
  local t, err = self:find_type(type_part)
  if not t then
    return nil, err or ("no type " .. type_part)
  end
  local key = params and (member .. params:gsub("%s", "")) or nil
  local found = {}
  for _, id in ipairs(t.methods) do
    local m = idx:symbol(id)
    if m.name == member and (not key or id:match("#(.*)$") == key) then
      found[#found + 1] = id
    end
  end
  if #found == 0 then
    return nil, "no method " .. member .. (params or "") .. " in " .. t.label
  elseif #found > 1 then
    return nil, "ambiguous entry " .. spec .. ": " .. table.concat(found, ", ")
  end
  return found
end

-- Success path (§8.3) ------------------------------------------------------------------

local failure_words = { "fail", "error", "invalid", "denied" }
local function signals_failure(cond)
  if not cond then
    return false
  end
  if cond:match("^!") or cond:find("== null", 1, true) or cond:find("isEmpty", 1, true) then
    return true
  end
  local lower = cond:lower()
  for _, w in ipairs(failure_words) do
    if lower:find(w, 1, true) then
      return true
    end
  end
  return false
end
M.signals_failure = signals_failure

local function ends_throw(arm)
  local last = arm.stmts[#arm.stmts]
  return last ~= nil and last.kind == "throw_statement"
end

local function arm_terminates(arm)
  local last = arm.stmts[#arm.stmts]
  if not last then
    return false
  end
  if last.kind == "return_statement" or last.kind == "throw_statement" then
    return true
  end
  if (last.kind == "if_statement" and #last.arms == 2) or last.kind == "block" then
    return regions.arms_terminate(last)
  end
  return false
end

local function project_count(body, stmts)
  local n = 0
  for _, st in ipairs(stmts) do
    for _, id in ipairs(st.sites) do
      local s = site_of(body, id)
      if s and #(s.targets or {}) > 0 then
        n = n + 1
      end
    end
  end
  return n
end

-- { off = {{range, why}}, forks = {{at, condition, kind, success, by}}, on = fn(pos) }
function R:success(body)
  local hit = self.memo.success[body]
  if hit then
    return hit
  end
  local off, forks = {}, {}
  local function drop(arm, why)
    off[#off + 1] = { range = arm.range, why = why }
  end
  local walk
  function walk(list)
    for _, st in ipairs(list) do
      local arms = st.arms
      if st.guard then
        drop(arms[1], "guard")
      elseif st.kind == "if_statement" and #arms == 2 then
        local a, b = arms[1], arms[2]
        local loser
        if not ends_throw(a) and not ends_throw(b) and arm_terminates(a) and arm_terminates(b) then
          local pa, pb = project_count(body, a.stmts), project_count(body, b.stmts)
          if pa ~= pb then
            loser = pa < pb and a or b
          elseif signals_failure(st.condition) then
            loser = a
            forks[#forks + 1] = { at = st.range.start, condition = st.condition, kind = "if", success = "else",
              by = "condition" }
          else
            -- no rule decides: both arms stay on the success path until the agent settles it
            forks[#forks + 1] = { at = st.range.start, condition = st.condition, kind = "if", by = "undecided" }
          end
        end
        for _, arm in ipairs(arms) do
          if ends_throw(arm) then
            drop(arm, "throw")
          elseif arm == loser then
            drop(arm, "fewer project sites")
          else
            walk(arm.stmts)
          end
        end
      elseif st.kind == "try_statement" or st.kind == "try_with_resources_statement" then
        for _, arm in ipairs(arms) do
          if arm.name == "catch" then
            drop(arm, "catch")
          elseif ends_throw(arm) then
            drop(arm, "throw")
          else
            walk(arm.stmts)
          end
        end
      elseif st.kind == "switch_statement" or st.kind == "switch_expression" then
        local best, counts = -1, {}
        for k, arm in ipairs(arms) do
          counts[k] = project_count(body, arm.stmts)
          if not ends_throw(arm) then
            best = math.max(best, counts[k])
          end
        end
        local tied = 0
        for k, arm in ipairs(arms) do
          if not ends_throw(arm) and counts[k] == best then
            tied = tied + 1
          end
        end
        if tied > 1 then
          forks[#forks + 1] = { at = st.range.start, condition = st.condition, kind = "switch", by = "undecided",
            cases = tied }
        end
        for k, arm in ipairs(arms) do
          if ends_throw(arm) then
            drop(arm, "throw")
          elseif counts[k] < best then
            drop(arm, "fewer project sites")
          else
            walk(arm.stmts)
          end
        end
      else
        for _, arm in ipairs(arms) do
          if ends_throw(arm) then
            drop(arm, "throw")
          else
            walk(arm.stmts)
          end
        end
      end
    end
  end
  walk(body.stmts)
  local result = { off = off, forks = forks }
  function result.on(pos)
    for _, o in ipairs(off) do
      if inside(pos, o.range) then
        return false
      end
    end
    return true
  end
  self.memo.success[body] = result
  return result
end

-- Carriers (§8.3 rule 1): sites whose value reaches the method's result, followed
-- through locals within the method. Returns a set of site ids.
function R:carriers(body)
  local hit = self.memo.carriers[body]
  if hit then
    return hit
  end
  local on = self:success(body).on
  local C = {}
  local function add(id)
    local s = site_of(body, id)
    if s and not C[id] and not stored(s) and on(s.at) then
      C[id] = true
      return true
    end
    return false
  end
  local function returns(list)
    for _, st in ipairs(list) do
      if st.kind == "return_statement" and on(st.range.start) then
        for _, id in ipairs(st.sites) do
          add(id)
        end
      end
      for _, arm in ipairs(st.arms) do
        returns(arm.stmts)
      end
    end
  end
  returns(body.stmts)
  local reach = {}
  local changed = true
  while changed do
    changed = false
    for i, l in ipairs(body.locals) do
      if not reach[i] then
        for _, u in ipairs(l.uses) do
          -- a value reaches the result when it is returned, or passed to (or is the
          -- receiver of) a carrier
          if not u.body and on(u.at) and (u.returned or (u.site and C[u.site] and (u.arg or u.receiver))) then
            reach[i] = true
            changed = true
            break
          end
        end
      end
    end
    for i in pairs(reach) do
      for _, def in ipairs(body.locals[i].definitions) do
        if on(def.range.start) then
          for _, id in ipairs(def.sites) do
            changed = add(id) or changed
          end
        end
      end
    end
  end
  self.memo.carriers[body] = C
  return C
end

-- Effects (§8.3 rule 2): writes a field of this or of a parameter, contains a sink, or
-- contains a success-path site whose target has an effect. Bottom-up, memoized, with a
-- cycle guard. A constructor's writes to `this` initialise the object it returns, so they
-- are not effects.
function R:has_effect(id)
  local memo = self.memo.effect
  if memo[id] ~= nil then
    return memo[id]
  end
  memo[id] = false
  local body, sym = self:body(id)
  if not body then
    return false
  end
  local result = false
  for _, w in ipairs(body.field_writes) do
    if (w.object == "this" and sym.kind ~= "constructor") or w.param then
      result = true
    end
  end
  local backend = self:backend(sym)
  for _, s in ipairs(body.sites) do
    if not result and library_call(s, backend.sinks) then
      result = true
    end
  end
  if not result then
    local on = self:success(body).on
    for _, s in ipairs(body.sites) do
      if on(s.at) and not stored(s) and not s.jump then -- a jump is an aside, not code that runs
        for _, t in ipairs(s.targets or {}) do
          if self:has_effect(t.symbol) then
            result = true
            break
          end
        end
      end
      if result then
        break
      end
    end
  end
  memo[id] = result
  return result
end

-- A site's value or effect matters: a sink, or a target with an effect.
function R:site_effect(body, s)
  local sym = self.idx:symbol(body.symbol)
  if sym and library_call(s, self:backend(sym).sinks) then
    return true
  end
  for _, t in ipairs(s.targets or {}) do
    if self:has_effect(t.symbol) then
      return true
    end
  end
  return false
end

-- Trivial targets (§8.2) ---------------------------------------------------------------

local function catches(stmts)
  local n = 0
  for _, st in ipairs(stmts) do
    for _, arm in ipairs(st.arms) do
      if arm.name == "catch" then
        n = n + 1
      end
      n = n + catches(arm.stmts)
    end
  end
  return n
end

local quiet = { log = true, debug = true, trace = true, toString = true, equals = true, hashCode = true }

function R:score(id, site)
  local body, sym = self:body(id)
  local m = body and body.metrics
  if not m then
    local r = sym and sym.range
    m = { lines = r and (r["end"][1] - r.start[1] + 1) or 1, branches = 0, loops = 0, project_sites = 0,
      field_writes = 0, throws = 0 }
  end
  local score = math.min(m.lines, 40) / 5 + 2 * m.branches + 1.5 * m.loops + 1.5 * m.project_sites
    + 2 * m.field_writes
  if m.throws > 0 or (body and catches(body.stmts) > 0) then
    score = score + 1
  end
  local name = sym and sym.name or ""
  if quiet[name] or name:match("^print") then
    score = score - 2
  end
  return score
end

-- Dispatch on the route (§8.5) ---------------------------------------------------------

local function same_end(a, b)
  return a["end"][1] == b["end"][1] and a["end"][2] == b["end"][2]
end

-- The type constructed for a receiver, tracked through locals, the caller's argument
-- (for a parameter), and a field's initializer and constructor assignments.
function R:constructed(site, body, sym, incoming)
  local idx = self.idx
  local function from_new(b, id)
    local s = site_of(b, id)
    if not s or s.kind ~= "new" then
      return nil
    end
    local t = s.targets and s.targets[1]
    if t then
      local ctor = idx:symbol(t.symbol)
      return ctor and ctor.owner
    end
    return s.references
  end
  local from_desc
  function from_desc(b, owner_sym, d, inc, depth)
    if not d or depth > 4 then
      return nil
    end
    if d.k == "new" then
      return d.site and from_new(b, d.site)
    end
    if d.k == "id" and d["local"] then
      local l = b.locals[d["local"]]
      if not l then
        return nil
      end
      if l.kind == "param" then
        if inc and inc.site.args and inc.site.args[l.param] then
          local caller = idx:symbol(inc.body.symbol)
          return from_desc(inc.body, caller, inc.site.args[l.param], inc.incoming, depth + 1)
        end
        return nil
      end
      local found
      for _, def in ipairs(l.definitions) do
        local last = def.sites[#def.sites]
        local s = site_of(b, last)
        if not (s and s.kind == "new" and same_end(s.node_range, def.range)) then
          return nil
        end
        local t = from_new(b, last)
        if not t or (found and found ~= t) then
          return nil
        end
        found = t
      end
      return found
    end
    local fname = (d.k == "id" and not d["local"] and d.name)
      or (d.k == "field" and d.object and d.object.k == "this" and d.name)
    if fname and owner_sym then
      local tsym = owner_sym.kind == "method" or owner_sym.kind == "constructor"
      tsym = tsym and idx:symbol(owner_sym.owner) or owner_sym
      if not (tsym and tsym.fields and tsym.fields[fname]) then
        return nil
      end
      local found, any = nil, false
      local function agree(t)
        any = true
        if not t or (found and found ~= t) then
          found = false
        elseif found ~= false then
          found = t
        end
      end
      local tbody = self:body(tsym.id)
      if tbody and tbody.inits and tbody.inits[fname] then
        agree(from_desc(tbody, tsym, tbody.inits[fname], nil, depth + 1))
      end
      for _, mid in ipairs(tsym.methods) do
        local mb, m = self:body(mid)
        for _, w in ipairs(mb and mb.field_writes or {}) do
          if w.object == "this" and w.name == fname then
            if m.kind ~= "constructor" then
              return nil -- reassigned after construction
            end
            agree(from_desc(mb, m, w.value, nil, depth + 1))
          end
        end
      end
      return any and found or nil
    end
    return nil
  end
  return from_desc(body, sym, site.receiver, incoming, 0)
end

-- A site's targets on the route: one implementation when its construction is known.
function R:targets(site, body, sym, incoming)
  local ts = site.targets or {}
  if #ts > 1 and site.declared then
    local built = self:constructed(site, body, sym, incoming)
    if built then
      local only = vim.tbl_filter(function(t)
        local m = self.idx:symbol(t.symbol)
        return m and m.owner == built
      end, ts)
      if #only == 1 then
        return only, built
      end
    end
  end
  -- a named implementation settles a dispatch that construction tracking could not
  local named = #ts > 1 and sym and self.route and self.route[sym.id]
  if named then
    local picked = vim.tbl_filter(function(t)
      return level_for(named[t.symbol], site) ~= nil
    end, ts)
    if #picked > 0 then
      return picked
    end
  end
  return ts
end

-- --through (§8.1): every site on the shortest call paths from an entry to a symbol.
-- Returns marks[symbol][site id] = {target = true}, and warnings.
function R:through_marks(entries, throughs)
  local marks, warnings = {}, {}
  for _, target in ipairs(throughs or {}) do
    local reached = false
    for _, entry in ipairs(entries) do
      local dist, parents, queue, head = { [entry] = 0 }, {}, { entry }, 1
      while head <= #queue do
        local id = queue[head]
        head = head + 1
        if dist[target] and dist[id] >= dist[target] then
          break
        end
        if id ~= target and dist[id] < self.opts.through_depth then
          local body = self:body(id)
          for _, s in ipairs(body and body.sites or {}) do
            for _, t in ipairs(s.targets or {}) do
              local d = dist[t.symbol]
              if d == nil then
                dist[t.symbol] = dist[id] + 1
                queue[#queue + 1] = t.symbol
                parents[t.symbol] = { { id, s.id } }
              elseif d == dist[id] + 1 then
                table.insert(parents[t.symbol], { id, s.id })
              end
            end
          end
        end
      end
      if dist[target] and target ~= entry then
        reached = true
        local seen = {}
        local function back(id)
          if seen[id] then
            return
          end
          seen[id] = true
          for _, p in ipairs(parents[id] or {}) do
            marks[p[1]] = marks[p[1]] or {}
            marks[p[1]][p[2]] = marks[p[1]][p[2]] or {}
            marks[p[1]][p[2]][id] = true
            back(p[1])
          end
        end
        back(target)
      end
    end
    if not reached then
      warnings[#warnings + 1] = "--through " .. target .. ": no call path from the entry"
    end
  end
  return marks, warnings
end

-- The main flow (§8.3) -------------------------------------------------------------------

local gap_reasons = { generic = "generic receiver", dynamic = "target unknown", ["no backend"] = "no backend" }

-- Returns { nodes = {id -> node}, order = {ids}, warnings }. A node:
--   { id, depth, main_sites = {site id -> {target, ref?, capped?, built?}},
--     gaps = {{site, reason}}, sinks = {{site, entry}}, forks }
-- Only sites the agent routed at level 0 (or --through forced) are followed; everything else
-- about the node is a fact: sinks and hand-offs are listed wherever they occur, and a routed
-- site the code cannot follow is a gap.
function R:main_flow(entries, marks)
  marks = marks or {}
  local flow = { nodes = {}, order = {}, warnings = {} }
  local cap = self.opts.main_cap
  local capped = false
  local function visit(id, incoming, depth)
    local node = { id = id, depth = depth, main_sites = {}, gaps = {}, sinks = {}, forks = {}, incoming = incoming }
    flow.nodes[id] = node
    flow.order[#flow.order + 1] = id
    local body, sym = self:body(id)
    if not body then
      return node
    end
    local backend = self:backend(sym)
    node.forks = self:success(body).forks
    local function gap(s, reason)
      node.gaps[#node.gaps + 1] = { site = s.id, reason = reason }
    end
    for _, s in ipairs(ordered(body)) do
      local sink = library_call(s, backend.sinks)
      if sink then
        node.sinks[#node.sinks + 1] = { site = s.id, entry = sink }
      elseif library_call(s, backend.handoffs) then
        gap(s, "hand-off")
      end
      local forced = marks[id] and marks[id][s.id]
      if (s.rating_override == 0 or forced) and s.kind ~= "accessor" then
        local ts, built = self:targets(s, body, sym, incoming)
        if forced then
          ts = vim.tbl_filter(function(t)
            return forced[t.symbol]
          end, s.targets or {})
        end
        if #ts == 0 then
          if s.unresolved == "abstract" then
            gap(s, "no implementation in the project")
          elseif not sink then
            gap(s, gap_reasons[s.unresolved or ""] or s.unresolved or "target unknown")
          end
        elseif #ts > 1 then
          gap(s, s.declared and (#ts .. " implementations; name one in the route")
            or (#ts .. " candidates (ambiguous)"))
        else
          local t = ts[1].symbol
          if flow.nodes[t] then
            node.main_sites[s.id] = { target = t, ref = true }
          elseif #flow.order >= cap then
            node.main_sites[s.id] = { target = t, capped = true }
            if not capped then
              capped = true
              flow.warnings[#flow.warnings + 1] = ("main flow capped at %d snippets (ast.main_cap)"):format(cap)
            end
          else
            node.main_sites[s.id] = { target = t, built = built, forced = forced and true or nil }
            visit(t, { body = body, site = s, incoming = incoming }, depth + 1)
          end
        end
      end
    end
    return node
  end
  for _, e in ipairs(entries) do
    if not flow.nodes[e] then
      visit(e, nil, 0)
    end
  end
  return flow
end

-- The rated tree (§8.2) ------------------------------------------------------------------

-- Node: { symbol, sym, body, depth, eff, main, edges, parent }
-- Edge: { site, target?, label? (unresolved/accessor/ref), rating?, eff?, s?, main?, why?,
--         choice? (one of several candidates), to? (child node), lazy? (fixed reason) }
function R:tree(entries, flow)
  local widest = 0
  for _, c in pairs(self.opts.cutoffs) do
    widest = math.max(widest, c.offer)
  end
  local visited = {}
  local roots = {}
  local build
  function build(id, depth, in_eff, path, incoming, via)
    local node = { symbol = id, depth = depth, eff = in_eff, edges = {}, parent = via,
      main = flow.nodes[id] ~= nil and (via == nil or via.main == true) }
    visited[id] = node
    path[id] = true
    local body, sym = self:body(id)
    node.sym, node.body = sym, body
    local mnode = node.main and flow.nodes[id] or nil
    if body then
      local reached = {}
      for _, s in ipairs(ordered(body)) do
        local ts, built = self:targets(s, body, sym, incoming)
        local ms = mnode and mnode.main_sites[s.id]
        if ms and ms.forced then
          ts = { { symbol = ms.target, confidence = "EXTRACTED", via = "through" } }
        end
        if #ts == 0 or (s.kind == "accessor" and s.rating_override == nil) then
          node.edges[#node.edges + 1] = { site = s, label = s.kind == "accessor" and "accessor" or "unresolved" }
        else
          for _, t in ipairs(ts) do
            local e = { site = s, target = t.symbol, confidence = t.confidence, via = t.via, source = t.source,
              choice = #ts > 1 or nil,
              candidates = #ts > 1 and #ts or nil, built = built }
            local target = t.symbol
            if ms and ms.target == target and not ms.ref and not ms.capped then
              e.main, e.rating, e.eff = true, 0, 0
            elseif path[target] or visited[target] then
              e.label, e.why = "ref", "already shown"
            elseif flow.nodes[target] and not (ms and ms.capped) then
              e.label, e.why = "ref", "on the main flow"
            elseif reached[target] then
              e.label, e.why = "ref", "already reached from here"
              e.first = reached[target]
            else
              if s.rating_override ~= nil then
                e.rating = s.rating_override
              else
                e.rating, e.why = 9, "not in the route"
              end
              e.s = 0
              if ms and ms.capped then
                e.lazy = "main cap"
              end
              e.eff = math.max(e.rating, in_eff)
            end
            reached[target] = reached[target] or e
            node.edges[#node.edges + 1] = e
            local inc = { body = body, site = s, incoming = incoming }
            if e.main then
              e.to = build(target, depth + 1, 0, path, inc, e)
            elseif e.rating and not e.lazy and e.eff <= widest then
              e.to = build(target, depth + 1, e.eff, path, inc, e)
            end
          end
        end
      end
    end
    path[id] = nil
    return node
  end
  for _, e in ipairs(entries) do
    if not visited[e] then
      roots[#roots + 1] = build(e, 0, 0, { _entry = e }, nil, nil)
    end
  end
  return { roots = roots, visited = visited, flow = flow }
end

-- Projection onto a detail (§8.6) ----------------------------------------------------------

-- Returns { detail, snippets = {node...} in walk order, n = {node -> "nK"},
--           mode = {edge -> {mode, why}} }
function R:project(tree, detail)
  local cut = assert(self.opts.cutoffs[detail], "unknown detail " .. tostring(detail))
  local kept, order = {}, 0
  local frontier = {}
  local offered = {}
  local function keep(node)
    kept[node] = true
    for _, e in ipairs(node.edges) do
      if e.to then
        order = order + 1
        e._order = e._order or order
        if e.main then
          keep(e.to)
        elseif e.eff <= cut.offer then
          frontier[#frontier + 1] = e
        end
      end
    end
  end
  for _, root in ipairs(tree.roots) do
    keep(root)
  end
  -- the budget counts extras only: best effective rating first, then highest s′
  local count = 0
  while #frontier > 0 and count < cut.budget do
    local best = 1
    for k = 2, #frontier do
      local a, b = frontier[k], frontier[best]
      local community_a, community_b = a.same_community == true, b.same_community == true
      if a.eff < b.eff or (a.eff == b.eff and ((community_a and not community_b)
          or (community_a == community_b and ((a.s or 0) > (b.s or 0)
          or ((a.s or 0) == (b.s or 0) and a._order < b._order))))) then
        best = k
      end
    end
    local e = table.remove(frontier, best)
    offered[e] = true
    count = count + 1
    keep(e.to)
  end
  local cut_by_budget = {}
  for _, e in ipairs(frontier) do
    cut_by_budget[e] = true
  end
  -- walk order: depth-first over kept nodes, sites in evaluation order
  local snippets, n = {}, {}
  local function number(node)
    snippets[#snippets + 1] = node
    n[node] = "n" .. #snippets
    for _, e in ipairs(node.edges) do
      if e.to and (e.main or offered[e]) then
        number(e.to)
      end
    end
  end
  for _, root in ipairs(tree.roots) do
    number(root)
  end
  local mode = {}
  for _, node in ipairs(snippets) do
    for _, e in ipairs(node.edges) do
      local m
      if e.label == "ref" then
        local target = tree.visited[e.target]
        if target and n[target] then
          m = { mode = "ref", why = e.why, to = n[target] }
        elseif e.first and mode[e.first] then
          m = vim.deepcopy(mode[e.first]) -- a repeated call reads like the first one
        else
          m = { mode = "lazy", why = "detail" }
        end
      elseif e.label then
        m = { mode = e.label }
      elseif e.main then
        m = { mode = "walk", to = n[e.to] }
      elseif offered[e] then
        m = { mode = "optional", to = n[e.to] }
      elseif e.lazy then
        m = { mode = "lazy", why = e.lazy }
      elseif cut_by_budget[e] then
        m = { mode = "lazy", why = "budget" }
      elseif e.eff > cut.offer then
        m = { mode = "lazy", why = e.why or "detail" }
      else
        m = { mode = "lazy", why = e.why or "detail" }
      end
      if e.choice and m.mode == "walk" then
        m.mode = "optional"
      end
      mode[e] = m
    end
  end
  return { detail = detail, snippets = snippets, n = n, mode = mode, kept = kept }
end

return M
