-- Resolution (SPEC-ast-graph §5): types of names, receivers and members; overloads;
-- dispatch to implementations; the symbol graph's edges.
--
-- Confidence (§3.4): EXTRACTED when every step followed the language's scoping rules from
-- declared types, in this file or another; INFERRED when any step was heuristic (a unique
-- project name, dispatch); AMBIGUOUS when several candidates are kept. A call is never bound
-- by its bare name: without a receiver type it stays unresolved.
local M = {}

local STOPLIST = {}
for _, name in ipairs({ "get", "set", "add", "put", "apply", "run", "call", "accept", "test", "of",
  "map", "size", "equals", "hashCode", "toString", "close", "remove", "contains", "isEmpty", "build" }) do
  STOPLIST[name] = true
end
M.stoplist = STOPLIST

local boxes = { int = "Integer", long = "Long", double = "Double", float = "Float", short = "Short",
  byte = "Byte", char = "Character", boolean = "Boolean" }
local widening = {
  byte = { short = 1, int = 1, long = 1, float = 1, double = 1 },
  short = { int = 1, long = 1, float = 1, double = 1 },
  char = { int = 1, long = 1, float = 1, double = 1 },
  int = { long = 1, float = 1, double = 1 },
  long = { float = 1, double = 1 },
  float = { double = 1 },
}

local R = {}
R.__index = R

-- "a.b.c" for a receiver made only of names (no calls, no locals), else nil.
function M.dotted(desc)
  if desc.k == "id" then
    return not desc["local"] and desc.name or nil
  elseif desc.k == "field" then
    local head = M.dotted(desc.object)
    return head and (head .. "." .. desc.name) or nil
  end
end

function M.new(idx)
  return setmetatable({ idx = idx, type_cache = {}, super_cache = {}, subtype_cache = {},
    resolved_files = {}, named_cache = {} }, R)
end

local function backend_of(self, facts)
  for _, b in ipairs(self.idx.backends) do
    if b.name == facts.lang then
      return b
    end
  end
end

-- Type names ------------------------------------------------------------------

-- A resolved type: { kind = project|generic|builtin|library|primitive|array|unknown,
--   sym?, name, via?, heuristic? }
local function project(sym, via, heuristic)
  return { kind = "project", sym = sym, name = sym.name, via = via, heuristic = heuristic or nil }
end

-- Enclosing type chain, innermost first.
function R:enclosing(type_sym)
  local chain = {}
  local t = type_sym
  while t do
    chain[#chain + 1] = t
    t = t.outer and self.idx:symbol(t.outer)
  end
  return chain
end

-- ctx: { facts, type = enclosing type symbol or nil, method = method symbol or nil }
function R:type_name(spelled, ctx)
  if not spelled or spelled == "" then
    return { kind = "unknown" }
  end
  local key = table.concat({ ctx.facts.file, ctx.type and ctx.type.id or "", ctx.method and ctx.method.id or "",
    ctx.body and ctx.body.symbol or "", spelled }, "\0")
  local hit = self.type_cache[key]
  if hit then
    return hit
  end
  local result = self:type_name_uncached(spelled, ctx)
  self.type_cache[key] = result
  return result
end

function R:type_name_uncached(spelled, ctx)
  local backend = backend_of(self, ctx.facts)
  if backend.resolve_type then
    return backend.resolve_type(self, spelled, ctx)
  end
  spelled = spelled:gsub("%.%.%.$", "[]")
  local element = spelled:match("^(.-)%[%]")
  if element then
    return { kind = "array", name = spelled, element = self:type_name(element, ctx) }
  end
  if backend.primitives[spelled] then
    return { kind = "primitive", name = spelled }
  end
  if spelled == "var" then
    return { kind = "unknown" }
  end
  -- qualified: Outer.Inner from scope, or a fully qualified name
  if spelled:find(".", 1, true) then
    local first, rest = spelled:match("^([^.]+)%.(.+)$")
    local head = self:type_name(first, ctx)
    if head.kind == "project" then
      local t = head.sym
      for part in rest:gmatch("[^.]+") do
        local nested = t and self:member_type(t, part)
        t = nested
      end
      if t then
        return project(t, head.via, head.heuristic)
      end
    end
    local sym = self.idx:type(spelled)
    if sym then
      return project(sym, "import")
    end
    if backend.platform and backend.platform(spelled) then
      return { kind = "builtin", name = spelled }
    end
    return { kind = "library", name = spelled }
  end
  -- 1. type parameters in scope
  if ctx.method then
    for _, tp in ipairs(ctx.method.type_params or {}) do
      if tp == spelled then
        return { kind = "generic", name = spelled }
      end
    end
  end
  for _, t in ipairs(ctx.type and self:enclosing(ctx.type) or {}) do
    for _, tp in ipairs(t.type_params or {}) do
      if tp == spelled then
        return { kind = "generic", name = spelled }
      end
    end
  end
  -- local classes declared in this body, or in the bodies enclosing a local/anonymous class
  local function local_type(b)
    local id = b and b.local_types and b.local_types[spelled]
    return id and self.idx:symbol(id)
  end
  local found_local = local_type(ctx.body)
  for _, t in ipairs(ctx.type and self:enclosing(ctx.type) or {}) do
    if found_local then
      break
    end
    if t.enclosing_body then
      local facts = self.idx:facts(t.file)
      found_local = local_type(facts and facts.bodies[t.enclosing_body])
    end
  end
  if found_local then
    return project(found_local, "local")
  end
  -- 2. nested types of C, of each enclosing type, including inherited member types
  for _, t in ipairs(ctx.type and self:enclosing(ctx.type) or {}) do
    if t.name == spelled then
      return project(t, "package")
    end
    local nested = self:member_type(t, spelled)
    if nested then
      return project(nested, "package")
    end
  end
  local imports = ctx.facts.imports
  -- 3. single-type imports (bound only to a project type declared in that package)
  local single = imports.single[spelled]
  if single then
    local sym = self.idx:type(single)
    if sym then
      return project(sym, "import")
    end
    -- an imported platform type (java.util.List) is a built-in, not a library type
    if backend.builtins[spelled] and backend.platform and backend.platform(single) then
      return { kind = "builtin", name = spelled, qualified = single }
    end
    return { kind = "library", name = single }
  end
  -- 4. the file's package (top-level types of this file included)
  local pkg = ctx.facts.package
  local sym = self.idx:type(pkg ~= "" and (pkg .. "." .. spelled) or spelled)
  if sym then
    return project(sym, "package")
  end
  -- 5. wildcard imports
  for _, path in ipairs(imports.wildcard) do
    sym = self.idx:type(path .. "." .. spelled)
    if sym then
      return project(sym, "import")
    end
  end
  -- 6. the language's built-ins
  if backend.builtins[spelled] then
    return { kind = "builtin", name = spelled }
  end
  -- 7. a unique project type with that name
  local named = self.idx:declarations_named(spelled, ctx.facts.lang)
  if #named == 1 then
    return project(named[1], "package", true)
  end
  -- 8. a library type (no library sources in phase 1, §4.4)
  return { kind = "library", name = spelled, candidates = #named > 1 and #named or nil }
end

-- A member type `name` of type `t`, looked up in t and its supertypes.
function R:member_type(t, name, seen)
  seen = seen or {}
  if seen[t.id] then
    return nil
  end
  seen[t.id] = true
  local id = t.nested and t.nested[name]
  if id then
    return self.idx:symbol(id)
  end
  local supers = self:supertypes(t)
  for _, s in ipairs(supers.all) do
    if s.kind == "project" then
      local found = self:member_type(s.sym, name, seen)
      if found then
        return found
      end
    end
  end
end

function R:facts_of(sym)
  return self.idx:facts(sym.file)
end

-- Context for a type's own declarations (its extends clause, field types, ...).
function R:type_ctx(t)
  return { facts = self:facts_of(t), type = t }
end

-- { superclass = resolved|nil, interfaces = {resolved...}, all = {...} }
function R:supertypes(t)
  local hit = self.super_cache[t.id]
  if hit then
    return hit
  end
  local out = { interfaces = {}, all = {} }
  self.super_cache[t.id] = out -- cycle guard
  local facts = self:facts_of(t)
  local ctx = { facts = facts, type = t.outer and self.idx:symbol(t.outer) or nil,
    body = t.enclosing_body and facts.bodies[t.enclosing_body] or nil }
  local backend = backend_of(self, facts)
  if backend.supertypes then
    backend.supertypes(self, t, ctx, out)
    return out
  end
  -- the extends clause is resolved in the scope enclosing the type, plus the type's own params
  ctx.method = { type_params = t.type_params }
  if t.anonymous then
    -- new T() { … }: T is the superclass, or the one interface implemented
    local r = t.extends[1] and self:type_name(t.extends[1].spelled, ctx)
    if r and r.kind == "project" and r.sym.kind == "interface" then
      out.interfaces[1] = r
    elseif r then
      out.superclass = r
    end
    if r then
      out.all[1] = r
    end
  elseif t.kind == "interface" then
    for _, ref in ipairs(t.extends) do
      local r = self:type_name(ref.spelled, ctx)
      out.interfaces[#out.interfaces + 1] = r
      out.all[#out.all + 1] = r
    end
  else
    if t.extends[1] then
      out.superclass = self:type_name(t.extends[1].spelled, ctx)
      out.all[#out.all + 1] = out.superclass
    end
    for _, ref in ipairs(t.implements) do
      local r = self:type_name(ref.spelled, ctx)
      out.interfaces[#out.interfaces + 1] = r
      out.all[#out.all + 1] = r
    end
  end
  return out
end

-- Lookup levels (§5.2 "class wins"): the type, then each superclass in turn, then
-- interfaces breadth-first, level by level. Each level is a list of type symbols.
-- Also reports whether the hierarchy reaches library code.
function R:levels(t)
  local levels, seen, library = {}, {}, false
  local chain = {}
  local c = t
  while c and not seen[c.id] do
    seen[c.id] = true
    chain[#chain + 1] = c
    levels[#levels + 1] = { c }
    local supers = self:supertypes(c)
    local sc = supers.superclass
    if sc and sc.kind ~= "project" then
      -- "library" when a supertype is library code, "builtin" when it is the platform's
      if sc.kind == "builtin" then
        library = library or (sc.name ~= "Object" and "builtin")
      else
        library = "library"
      end
    end
    c = sc and sc.kind == "project" and sc.sym or nil
  end
  local frontier = {}
  for _, k in ipairs(chain) do
    for _, i in ipairs(self:supertypes(k).interfaces) do
      if i.kind == "project" then
        frontier[#frontier + 1] = i.sym
      else
        library = (i.kind == "builtin" and (library or "builtin")) or "library"
      end
    end
  end
  while #frontier > 0 do
    local level, next_frontier = {}, {}
    for _, i in ipairs(frontier) do
      if not seen[i.id] then
        seen[i.id] = true
        level[#level + 1] = i
        for _, s in ipairs(self:supertypes(i).interfaces) do
          if s.kind == "project" then
            next_frontier[#next_frontier + 1] = s.sym
          else
            library = (s.kind == "builtin" and (library or "builtin")) or "library"
          end
        end
      end
    end
    if #level > 0 then
      levels[#levels + 1] = level
    end
    frontier = next_frontier
  end
  return levels, library
end

local function arity_ok(m, arity)
  if arity < 0 then
    return true -- method reference: any arity
  end
  local n = #m.params
  if m.varargs then
    return arity >= n - 1
  end
  return arity == n
end

-- Methods (or constructors) named `name` with a matching arity, at the first level that has any.
function R:members(t, name, arity, kind)
  local levels, library = self:levels(t)
  if kind == "constructor" then
    levels = { { t } }
  end
  for _, level in ipairs(levels) do
    local found = {}
    for _, ty in ipairs(level) do
      for _, id in ipairs(ty.methods or {}) do
        local m = self.idx:symbol(id)
        if m and m.name == name and ((kind == "constructor") == (m.kind == "constructor")) and arity_ok(m, arity) then
          found[#found + 1] = m
        end
      end
    end
    if #found > 0 then
      return found
    end
  end
  return {}, library
end

function R:field_of(t, name)
  local levels, library = self:levels(t)
  for _, level in ipairs(levels) do
    for _, ty in ipairs(level) do
      local id = ty.fields and ty.fields[name]
      if id then
        return self.idx:symbol(id), ty
      end
    end
  end
  return nil, library
end

-- Receivers ---------------------------------------------------------------------

-- The declared type of a variable or field, resolved where it was declared.
function R:declared(spelled, ctx)
  if not spelled then
    return { kind = "unknown" }
  end
  return self:type_name(spelled, ctx)
end

-- Type of a field symbol, resolved in its own declaring context.
function R:field_type(f)
  local owner = self.idx:symbol(f.owner)
  return self:declared(f.type and f.type.spelled, { facts = self:facts_of(f), type = owner })
end

-- The resolved return type of a method symbol, in the callee's file.
function R:returns(m)
  if not m.returns_spelled then
    if m.kind == "constructor" then
      return project(self.idx:symbol(m.owner), "chain")
    end
    return { kind = "unknown" }
  end
  return self:declared(m.returns_spelled, { facts = self:facts_of(m), type = self.idx:symbol(m.owner), method = m })
end

-- A name used as an expression: a local, a parameter, a field (own, inherited, enclosing),
-- or a type (a static call). Returns resolved type, via, and the symbol it binds to.
function R:name_type(name, local_index, ctx, local_body)
  if local_index then
    -- a captured local belongs to the body of the enclosing method
    local lctx = ctx
    if local_body and local_body ~= ctx.body.symbol then
      local owner_body = ctx.facts.bodies[local_body]
      local sym = self.idx:symbol(local_body)
      lctx = { facts = ctx.facts, body = owner_body,
        method = sym and (sym.kind == "method" or sym.kind == "constructor") and sym or nil,
        type = sym and (sym.owner and self.idx:symbol(sym.owner) or sym) or ctx.type }
    end
    local l = lctx.body.locals[local_index]
    local via = l.kind == "param" and "param" or "local"
    if l.spelled then
      return self:declared(l.spelled, lctx), via, l
    end
    if l.infer then
      local t = self:receiver_type(l.infer, lctx)
      return t, via, l
    end
    return { kind = "unknown", why = l.kind == "lambda" and "untyped lambda parameter" or "untyped" }, via, l
  end
  for _, t in ipairs(ctx.type and self:enclosing(ctx.type) or {}) do
    local f = self:field_of(t, name)
    if f then
      return self:field_type(f), "field", f
    end
  end
  local ty = self:type_name(name, ctx)
  if ty.kind ~= "library" or ctx.facts.imports.single[name] or name:match("^%u") then
    return ty, "static", nil, true
  end
  return { kind = "unknown", why = "unknown name" }, "static", nil, true
end

-- Resolved type of a receiver descriptor (§4.2) and how it was found.
function R:receiver_type(desc, ctx)
  local k = desc.k
  if k == "id" then
    local t, via, bound, static = self:name_type(desc.name, desc["local"], ctx, desc.local_body)
    return t, via, bound, static
  elseif k == "super" and desc.outer then
    -- Outer.super.m(): the superclass of that enclosing type; Iface.super.m(): that interface
    for _, e in ipairs(self:enclosing(ctx.type)) do
      if e.name == desc.outer or e.qname == desc.outer then
        local sc = self:supertypes(e).superclass
        return sc or { kind = "builtin", name = "Object" }, "super"
      end
    end
    local named = self:type_name(desc.outer, ctx)
    if named.kind == "project" then
      return project(named.sym, "super", named.heuristic), "super"
    end
    return named, "super"
  elseif k == "this" or k == "super" then
    local t = ctx.type
    if desc.outer then
      t = nil
      for _, e in ipairs(self:enclosing(ctx.type)) do
        if e.name == desc.outer or e.qname == desc.outer then
          t = e
        end
      end
      if not t then
        return { kind = "unknown" }, k
      end
    end
    if k == "super" then
      local sc = self:supertypes(t).superclass
      return sc or { kind = "builtin", name = "Object" }, "super"
    end
    return project(t, "this"), "this"
  elseif k == "field" then
    -- a qualified type name spelled as a field chain: com.acme.util.Util
    local dotted = M.dotted(desc)
    if dotted and not (desc.object.k == "id" and desc.object["local"]) then
      local head = dotted:match("^[^.]+")
      local shadowed = false
      for _, t in ipairs(ctx.type and self:enclosing(ctx.type) or {}) do
        shadowed = shadowed or self:field_of(t, head) ~= nil
      end
      if not shadowed and head:match("^%l") then
        local sym = self.idx:type(dotted)
        if sym then
          return project(sym, "static"), "static", nil, true
        end
        local backend = backend_of(self, ctx.facts)
        if backend.platform and backend.platform(dotted) then
          return { kind = "builtin", name = dotted }, "static", nil, true
        end
      end
    end
    local object, via, bound, static = self:receiver_type(desc.object, ctx)
    if object.kind == "project" then
      local f = self:field_of(object.sym, desc.name)
      if f then
        local t = self:field_type(f)
        t.heuristic = t.heuristic or object.heuristic
        return t, "field", f
      end
      local nested = self:member_type(object.sym, desc.name)
      if nested and static then
        return project(nested, "static"), "static", nil, true
      end
      return { kind = "unknown" }, "field"
    elseif object.kind == "unknown" and desc.object.k == "id" and not desc.object["local"] then
      local qualified = desc.object.name .. "." .. desc.name
      local sym = self.idx:type(qualified)
      if sym then
        return project(sym, "static"), "static", nil, true
      end
    end
    if object.kind == "builtin" then
      return { kind = "builtin" }, "field" -- System.out: the platform's own field
    elseif object.kind == "library" then
      return { kind = "library" }, "field"
    end
    return { kind = object.kind == "generic" and "generic" or "unknown" }, "field"
  elseif k == "call" or (k == "new" and desc.site) then
    local s = desc.site and ctx.body.sites[tonumber(desc.site:sub(2))]
    if k == "new" then
      return self:type_name(desc.type, ctx), "chain"
    end
    if s and s.kind == "accessor" and s.references then
      local f = self.idx:symbol(s.references)
      return f and self:field_type(f) or { kind = "unknown" }, "chain"
    end
    local target = s and (s.declared or (s.targets and #s.targets == 1 and s.targets[1]) or nil)
    if target then
      local m = self.idx:symbol(target.symbol)
      local t = m and self:returns(m) or { kind = "unknown" }
      if target.confidence ~= "EXTRACTED" then
        t = vim.tbl_extend("force", t, { heuristic = t.heuristic or (target.via == "name-only") })
      end
      return t, "chain"
    end
    if s and (s.unresolved == "library" or s.unresolved == "builtin") then
      return { kind = "library" }, "chain" -- a library call: its return type is not known
    end
    return { kind = "unknown" }, "chain"
  elseif k == "new" or k == "cast" then
    local t = self:type_name(desc.type, ctx)
    return t, t.via or "package"
  elseif k == "type" then
    return self:type_name(desc.type, ctx), "static", nil, true
  elseif k == "lit" then
    if desc.type == "null" then
      return { kind = "unknown" }, "local"
    end
    local backend = backend_of(self, ctx.facts)
    return backend.primitives[desc.type] and { kind = "primitive", name = desc.type }
      or { kind = "builtin", name = desc.type }, "local"
  end
  return { kind = "unknown" }, "local"
end

-- Overloads -------------------------------------------------------------------

function R:arg_name(desc, ctx)
  if desc.k == "lit" then
    return desc.type
  end
  local ok, t = pcall(self.receiver_type, self, desc, ctx)
  if not ok or not t then
    return nil
  end
  if t.kind == "project" then
    return t.name, t.sym
  elseif t.kind == "builtin" or t.kind == "primitive" or t.kind == "array" then
    return t.name
  elseif t.kind == "library" then
    return t.name and t.name:match("([^.]+)$")
  end
end

function R:compat(arg, sym, param)
  if not arg or not param then
    return 0
  end
  param = param:gsub("%.%.%.$", "")
  if arg == "null" then
    return boxes[param] and nil or 0
  end
  if arg == param then
    return 3
  end
  if boxes[arg] == param or boxes[param] == arg then
    return 2
  end
  if widening[arg] and widening[arg][param] then
    return 1
  end
  if param == "Object" then
    return 1
  end
  local arg_prim, param_prim = boxes[arg] ~= nil, boxes[param] ~= nil
  if arg_prim or param_prim then
    return nil
  end
  if sym then
    for _, level in ipairs((self:levels(sym))) do
      for _, ty in ipairs(level) do
        if ty.name == param then
          return 2
        end
      end
    end
    return nil -- a project type's hierarchy is known
  end
  if arg == "String" then
    return (param == "CharSequence" or param == "Comparable") and 2 or nil
  end
  return 0
end

-- Score same-arity candidates by inferable argument types; returns the best (or tied) set.
function R:overload(candidates, site, ctx)
  if #candidates < 2 then
    return candidates, false
  end
  -- Java tries fixed-arity methods before variable-arity ones
  local fixed = vim.tbl_filter(function(m)
    return not m.varargs and (site.arity < 0 or #m.params == site.arity)
  end, candidates)
  if #fixed > 0 and #fixed < #candidates then
    candidates = fixed
    if #candidates == 1 then
      return candidates, false
    end
  end
  local args = {}
  for i, a in ipairs(site.args or {}) do
    local name, sym = self:arg_name(a, ctx)
    args[i] = { name = name, sym = sym }
  end
  local best, best_score = {}, nil
  for _, m in ipairs(candidates) do
    local score = 0
    for i, a in ipairs(args) do
      local p = m.params[math.min(i, #m.params)]
      local c = self:compat(a.name, a.sym, p and p.type and p.type.name)
      if c == nil then
        score = nil
        break
      end
      score = score + c
    end
    if score then
      if not best_score or score > best_score then
        best, best_score = { m }, score
      elseif score == best_score then
        best[#best + 1] = m
      end
    end
  end
  if #best == 0 then
    return candidates, true
  end
  return best, #best > 1
end

-- Dispatch ----------------------------------------------------------------------

-- Direct and transitive project subtypes of a type.
function R:subtypes(t)
  local hit = self.subtype_cache[t.id]
  if hit then
    return hit
  end
  local out, seen = {}, { [t.id] = true }
  self.subtype_cache[t.id] = out
  local queue = { t }
  while #queue > 0 do
    local cur = table.remove(queue, 1)
    self.idx:mentioning(cur.name)
    local ids = vim.tbl_keys(self.idx.symbols)
    table.sort(ids)
    for _, id in ipairs(ids) do
      local s = self.idx.symbols[id]
      if s.extends and not seen[s.id] then
        for _, sup in ipairs(self:supertypes(s).all) do
          if sup.kind == "project" and sup.sym.id == cur.id then
            seen[s.id] = true
            out[#out + 1] = s
            queue[#queue + 1] = s
            break
          end
        end
      end
    end
  end
  return out
end

local function method_key(m)
  return m.id:match("#(.*)$")
end

-- Type variables a method's parameters may use: its own and its owner's (and outer types').
function R:type_vars(m)
  local vars = {}
  for _, v in ipairs(m.type_params or {}) do
    vars[v] = true
  end
  local owner = self.idx:symbol(m.owner)
  for _, t in ipairs(owner and self:enclosing(owner) or {}) do
    for _, v in ipairs(t.type_params or {}) do
      vars[v] = true
    end
  end
  return vars
end

-- Does `sub` override `sup`? Same name and arity, and each parameter spelled the same
-- or a type variable of `sup` (Handler<T>.handle(T) is implemented by handle(Order)).
function R:same_signature(sub, sup)
  if sub.name ~= sup.name or #sub.params ~= #sup.params or sub.kind ~= sup.kind then
    return false
  end
  if method_key(sub) == method_key(sup) then
    return true
  end
  local vars = self:type_vars(sup)
  for i, p in ipairs(sup.params) do
    local a = p.type and p.type.name or "?"
    local b = sub.params[i].type and sub.params[i].type.name or "?"
    local base = a:gsub("%[%]", ""):gsub("%.%.%.$", "")
    if a ~= b and not vars[base] then
      return false
    end
  end
  return true
end

function R:implementations(m)
  local owner = self.idx:symbol(m.owner)
  local out = {}
  for _, sub in ipairs(self:subtypes(owner)) do
    for _, id in ipairs(sub.methods) do
      local cand = self.idx:symbol(id)
      if cand and not cand.abstract and self:same_signature(cand, m) then
        out[#out + 1] = cand
      end
    end
  end
  return out
end

-- Sites -------------------------------------------------------------------------

local function confidence(_, _, heuristic)
  return heuristic and "INFERRED" or "EXTRACTED"
end

function R:bind(site, ctx, methods, via, heuristic, ambiguous)
  site.targets = {}
  for _, m in ipairs(methods) do
    local conf = ambiguous and "AMBIGUOUS" or confidence(ctx.facts.file, m, heuristic)
    site.targets[#site.targets + 1] = { symbol = m.id, confidence = conf, via = via }
  end
  -- dispatch: an abstract target lists the implementations (§5.4)
  site.unresolved = nil
  if #methods == 1 and methods[1].abstract and methods[1].kind == "method" and not methods[1].static then
    -- the declared method has no code to walk: its implementations are the targets, and
    -- without any (a framework may supply one at run time) the site is unresolved
    local impls = self:implementations(methods[1])
    site.declared = site.targets[1]
    site.targets = {}
    for _, impl in ipairs(impls) do
      site.targets[#site.targets + 1] = { symbol = impl.id, confidence = "INFERRED", via = "dispatch" }
    end
    if #impls == 0 then
      site.unresolved = "abstract"
    end
  end
end

local function unresolved_reason(t, library)
  if t.kind == "generic" then
    return "generic"
  elseif t.kind == "builtin" or t.kind == "primitive" or t.kind == "array" then
    return "builtin"
  elseif t.kind == "library" or library then
    return "library"
  end
  return "dynamic"
end

function R:resolve_on_type(site, ctx, t, via, heuristic, static)
  local name, arity = site.name, site.arity
  if t.kind ~= "project" then
    if (t.kind == "builtin" or t.kind == "unknown") and backend_of(self, ctx.facts).object_methods[name] then
      site.unresolved = "builtin"
      return
    end
    site.unresolved = unresolved_reason(t)
    site.receiver_type = t.name
    return
  end
  local sym = t.sym
  site.receiver_type = sym.qname
  if site.kind == "new" or (site.kind == "method_ref" and name == "new") then
    local ctors = self:members(sym, sym.name, site.kind == "new" and arity or -1, "constructor")
    if #ctors == 0 then
      site.targets = {}
      site.references = sym.id
      site.reference_confidence = confidence(ctx.facts.file, sym, heuristic)
      site.unresolved = nil
      return
    end
    local best, ambiguous = self:overload(ctors, site, ctx)
    return self:bind(site, ctx, best, via, heuristic, ambiguous)
  end
  -- record accessor (§5.3): a component read, not a call
  if sym.kind == "record" and arity == 0 and site.kind == "call" and sym.fields[name] then
    local declared = false
    for _, id in ipairs(sym.methods) do
      local m = self.idx:symbol(id)
      if m.name == name and #m.params == 0 and not m.implicit then
        declared = true
      end
    end
    if not declared then
      for _, comp in ipairs(sym.components) do
        if comp.name == name then
          site.kind = "accessor"
          site.targets = {}
          site.references = comp.field
          site.reference_confidence = confidence(ctx.facts.file, sym, heuristic)
          site.unresolved = nil
          return
        end
      end
    end
  end
  local found, library = self:members(sym, name, arity)
  if #found == 0 then
    if backend_of(self, ctx.facts).object_methods[name] then
      site.unresolved = "builtin"
    else
      site.unresolved = type(library) == "string" and library or (library and "library" or "dynamic")
    end
    return
  end
  local best, ambiguous = self:overload(found, site, ctx)
  self:bind(site, ctx, best, via, heuristic, ambiguous)
  site.static = static or nil
end

function R:resolve_site(site, ctx)
  local backend = backend_of(self, ctx.facts)
  if backend.resolve_site then
    return backend.resolve_site(self, site, ctx)
  end
  local k = site.receiver and site.receiver.k
  if site.kind == "this()" or site.kind == "super()" then
    local t = ctx.type
    local via = "this"
    if site.kind == "super()" then
      local sc = self:supertypes(t).superclass
      if not sc or sc.kind ~= "project" then
        site.unresolved = sc and unresolved_reason(sc) or "builtin"
        return
      end
      t, via = sc.sym, "super"
    end
    local ctors = self:members(t, t.name, site.arity, "constructor")
    if #ctors == 0 then
      site.targets, site.references, site.unresolved = {}, t.id, nil
      return
    end
    local best, ambiguous = self:overload(ctors, site, ctx)
    return self:bind(site, ctx, best, via, false, ambiguous)
  end
  if site.kind == "new" then
    local t = self:type_name(site.type, ctx)
    return self:resolve_on_type(site, ctx, t, t.via or "package", t.heuristic)
  end
  if k == "implicit" then
    -- bare call: members of the enclosing type and its supertypes, then enclosing types,
    -- then static imports
    local library = false
    for _, t in ipairs(ctx.type and self:enclosing(ctx.type) or {}) do
      if t.kind == "record" and site.arity == 0 and t.fields[site.name] then
        local before = site.kind
        self:resolve_on_type(site, ctx, project(t, "this"), "this", false)
        if site.kind == "accessor" or site.kind ~= before or #(site.targets or {}) > 0 then
          return
        end
      end
      local found, lib = self:members(t, site.name, site.arity)
      library = library or lib
      if #found > 0 then
        local best, ambiguous = self:overload(found, site, ctx)
        site.receiver_type = t.qname
        return self:bind(site, ctx, best, "this", false, ambiguous)
      end
    end
    local imports = ctx.facts.imports
    for _, owner in ipairs(imports.static_single[site.name] or {}) do
      local t = self.idx:type(owner)
      if t then
        local found = self:members(t, site.name, site.arity)
        if #found > 0 then
          local best, ambiguous = self:overload(found, site, ctx)
          site.receiver_type = t.qname
          return self:bind(site, ctx, best, "static", false, ambiguous)
        end
      else
        site.unresolved = "library"
        return
      end
    end
    for _, owner in ipairs(imports.static_wildcard) do
      local t = self.idx:type(owner)
      if t then
        local found = self:members(t, site.name, site.arity)
        if #found > 0 then
          local best, ambiguous = self:overload(found, site, ctx)
          site.receiver_type = t.qname
          return self:bind(site, ctx, best, "static", false, ambiguous)
        end
      else
        library = true
      end
    end
    site.unresolved = type(library) == "string" and library or (library and "library" or "dynamic")
    return
  end
  local t, via, _, static = self:receiver_type(site.receiver, ctx)
  return self:resolve_on_type(site, ctx, t, via, t.heuristic, static)
end

-- Configured cross-boundary edges (ast.boundaries): a call the language cannot follow
-- (a Lambda invoke, a queue publish, an HTTP client) continues at a project symbol. Each rule is
-- { call = "Type.method" | "method", to = "Type#method" | {specs}, note? }; `Type` must match the
-- end of the receiver's type, so `AWSLambda.invoke` never claims an unrelated `invoke`. Only
-- sites that no project method already resolved are rewritten.
function R:boundary(site)
  local rules = require("code-tour.ast").options.boundaries
  if not rules or #rules == 0 or (site.targets and #site.targets > 0) or not site.name then
    return
  end
  for _, rule in ipairs(rules) do
    local owner, method = rule.call:match("^(.*)%.([^.]+)$")
    method = method or rule.call
    local received = site.receiver_type or site.library_name
    local type_ok = not owner or (received and (received == owner or received:sub(-#owner - 1) == "." .. owner))
    if method == site.name and type_ok then
      self.boundary_cache = self.boundary_cache or {}
      local key = vim.inspect(rule.to)
      local ids = self.boundary_cache[key]
      if ids == nil then
        ids = {}
        local rt = require("code-tour.ast.route").new(self.idx)
        for _, spec in ipairs(type(rule.to) == "table" and rule.to or { rule.to }) do
          local found = rt:resolve_entry(spec)
          vim.list_extend(ids, found or {})
        end
        self.boundary_cache[key] = ids
      end
      if #ids > 0 then
        site.targets = {}
        for _, id in ipairs(ids) do
          site.targets[#site.targets + 1] = { symbol = id, confidence = "INFERRED", via = "boundary", note = rule.note }
        end
        site.unresolved, site.boundary = nil, rule.call
        return
      end
    end
  end
end

-- Resolve every site in a file (in evaluation order, so chains see their inner calls).
function R:resolve_file(rel)
  if self.resolved_files[rel] then
    return self.idx:facts(rel)
  end
  self.resolved_files[rel] = true
  local facts = self.idx:facts(rel)
  if not facts then
    return nil
  end
  local ids = vim.tbl_keys(facts.bodies)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local body = facts.bodies[id]
    local sym = facts.symbols[id]
    local ctx = { facts = facts, body = body }
    if sym.kind == "method" or sym.kind == "constructor" then
      ctx.method, ctx.type = sym, self.idx:symbol(sym.owner)
    else
      ctx.type = sym
    end
    local project_sites = 0
    for _, site in ipairs(body.sites) do
      local ok, err = pcall(self.resolve_site, self, site, ctx)
      if not ok then
        site.unresolved, site.error = "dynamic", tostring(err)
      end
      site.targets = site.targets or {}
      self:boundary(site)
      if #site.targets > 0 then
        project_sites = project_sites + 1
      end
    end
    body.metrics.project_sites = project_sites
  end
  return facts
end

-- Edges -------------------------------------------------------------------------

local function edge(list, source, target, relation, file, at, extra)
  local e = vim.tbl_extend("force", { source = source, target = target, relation = relation, file = file,
    line = at and (at[1] + 1) or nil, confidence = "EXTRACTED", source_kind = "ast" }, extra or {})
  list[#list + 1] = e
  return e
end

local function type_confidence(_, t)
  return t.heuristic and "INFERRED" or "EXTRACTED"
end

-- The symbol graph's edges for one resolved file (§3.4). Calls are site → target edges.
function R:edges(rel)
  local facts = self:resolve_file(rel)
  local list = {}
  if not facts then
    return list
  end
  local file_id = "file:" .. rel
  local backend = backend_of(self, facts)
  local seen = {}
  local function once(source, target, relation, context, at, extra)
    local key = table.concat({ source, target, relation, context or "" }, "\0")
    if seen[key] then
      return
    end
    seen[key] = true
    return edge(list, source, target, relation, rel, at, vim.tbl_extend("force", { context = context }, extra or {}))
  end
  local function ref(source, t, context, at)
    if t and t.kind == "array" then
      t = t.element
    end
    if t and t.kind == "project" then
      once(source, t.sym.id, "references", context, at, { confidence = type_confidence(rel, t), via = t.via })
    end
  end
  -- imports
  for _, imp in ipairs(facts.imports.list) do
    local path = imp.static and not imp.wildcard and imp.path:match("^(.*)%.[^.]+$") or imp.path
    local sym = backend.import_symbol and backend.import_symbol(self, path) or self.idx:type(path, facts.lang)
    if sym then
      once(file_id, sym.id, "imports", imp.static and "static" or "import", imp.range.start, { via = "import" })
    end
  end
  for _, tid in ipairs(facts.type_order) do
    local t = facts.symbols[tid]
    local ctx = { facts = facts, type = t }
    once(t.outer or file_id, t.id, "contains", nil, t.range.start)
    local supers = self:supertypes(t)
    for i, s in ipairs(supers.all) do
      if s.kind == "project" then
        local relation = (backend.supertypes or (t.kind ~= "interface" and s == supers.superclass)) and "inherits"
          or (t.kind == "interface" and "inherits" or "implements")
        once(t.id, s.sym.id, relation, nil, t.range.start, { confidence = type_confidence(rel, s), via = s.via })
      end
      local _ = i
    end
    for _, fid in pairs(t.fields) do
      local f = facts.symbols[fid]
      once(t.id, fid, "field", nil, f.range.start)
      ref(t.id, self:field_type(f), "field", f.range.start)
    end
    for _, mid in ipairs(t.methods) do
      local m = facts.symbols[mid]
      once(t.id, mid, "method", nil, m.range.start)
      local mctx = { facts = facts, type = t, method = m }
      for _, p in ipairs(m.params) do
        ref(mid, p.type and self:type_name(p.type.spelled, mctx), "param", m.range.start)
      end
      if m.returns_spelled then
        ref(mid, self:type_name(m.returns_spelled, mctx), "return", m.range.start)
      end
      -- overrides: the same signature in a supertype
      if m.kind == "method" and not m.static then
        local levels = self:levels(t)
        for li = 2, #levels do
          for _, st in ipairs(levels[li]) do
            for _, sid in ipairs(st.methods) do
              local sm = self.idx:symbol(sid)
              if sm and sm.kind == "method" and self:same_signature(m, sm) then
                once(mid, sid, "overrides", nil, m.range.start,
                  { confidence = "EXTRACTED" })
              end
            end
          end
        end
      end
    end
    local _ = ctx
  end
  -- references from bodies and the call sites themselves
  local ids = vim.tbl_keys(facts.bodies)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local body = facts.bodies[id]
    local sym = facts.symbols[id]
    local ctx = { facts = facts, body = body }
    if sym.kind == "method" or sym.kind == "constructor" then
      ctx.method, ctx.type = sym, self.idx:symbol(sym.owner)
      if ctx.type and not ctx.type.methods then
        once(sym.owner, id, "contains", nil, sym.range.start)
        for _, p in ipairs(sym.params) do
          ref(id, p.type and self:type_name(p.type.spelled, ctx), "param", sym.range.start)
        end
        ref(id, self:type_name(sym.returns_spelled, ctx), "return", sym.range.start)
      end
    else
      ctx.type = sym
    end
    for _, l in ipairs(body.locals) do
      if l.kind ~= "param" and l.spelled then
        ref(id, self:type_name(l.spelled, ctx), "local", l.declared_at)
      end
    end
    for _, cast in ipairs(body.casts or {}) do
      ref(id, self:type_name(cast.type, ctx), "cast", cast.at)
    end
    for _, site in ipairs(body.sites) do
      if site.static and site.receiver_type then
        local t = self.idx:type(site.receiver_type)
        if t then
          local first = site.declared or (site.targets or {})[1]
          once(id, t.id, "references", "static", site.at, {
            confidence = first and first.confidence == "INFERRED" and "INFERRED" or "EXTRACTED", via = "static" })
        end
      end
      if site.references then
        once(id, site.references, "references", site.kind == "accessor" and "accessor" or "new", site.at,
          { confidence = site.reference_confidence or "EXTRACTED" })
      end
      for _, target in ipairs(site.targets or {}) do
        edge(list, id, target.symbol, "calls", rel, site.at, { key = site.id, callsite = site.text,
          range = site.range, confidence = target.confidence, via = target.via, kind = site.kind })
      end
      -- the method the call names, so callers of an interface method can be found
      if site.declared then
        edge(list, id, site.declared.symbol, "calls", rel, site.at, { key = site.id, callsite = site.text,
          range = site.range, confidence = site.declared.confidence, via = "declared", kind = site.kind })
      end
    end
  end
  return list
end

return M
