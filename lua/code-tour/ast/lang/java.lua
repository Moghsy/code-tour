-- Java backend (SPEC-ast-graph §4.1–4.2). Two passes over one file:
--   declarations: package, imports, types, fields, methods (bodies remembered, not entered)
--   bodies:       scoped locals with definitions and uses, sites with receiver
--                 descriptors, statement trees, metrics
-- Everything returned is plain data (no Tree-sitter nodes), so it can be cached
-- by blob SHA and handed to the resolver.
local M = {
  name = "java",
  extensions = { ".java" },
  parser = "java",
  version = 7, -- bump when the shape of extracted facts changes (invalidates the cache)
}

M.types = {
  type = { "class_declaration", "interface_declaration", "enum_declaration",
    "record_declaration", "annotation_type_declaration" },
  method = { "method_declaration", "constructor_declaration", "compact_constructor_declaration" },
  import = { "import_declaration" },
  call = { "method_invocation", "object_creation_expression",
    "explicit_constructor_invocation", "method_reference" },
  statement = { "expression_statement", "local_variable_declaration", "return_statement",
    "throw_statement", "break_statement", "continue_statement", "yield_statement",
    "assert_statement", "empty_statement", "labeled_statement", "explicit_constructor_invocation",
    "local_class_declaration", "class_declaration", "record_declaration", "interface_declaration",
    "enum_declaration", "block" },
  compound = { "if_statement", "for_statement", "enhanced_for_statement", "while_statement",
    "do_statement", "try_statement", "try_with_resources_statement", "switch_expression",
    "switch_statement", "synchronized_statement" },
}

local function set(list)
  local out = {}
  for _, v in ipairs(list) do
    out[v] = true
  end
  return out
end

-- Type names that resolve to the platform, never to the project (§5.3). Java only.
M.builtins = set({
  "Object", "String", "System", "Math", "StrictMath", "Integer", "Long", "Double", "Float",
  "Short", "Byte", "Character", "Boolean", "Number", "Void", "Class", "Enum", "Record",
  "Thread", "Runnable", "Iterable", "Comparable", "CharSequence", "StringBuilder",
  "StringBuffer", "Throwable", "Exception", "RuntimeException", "Error",
  "IllegalArgumentException", "IllegalStateException", "NullPointerException",
  "UnsupportedOperationException", "IndexOutOfBoundsException", "ArithmeticException",
  "ClassCastException", "InterruptedException", "CloneNotSupportedException",
  "AutoCloseable", "Override", "Deprecated", "SuppressWarnings", "FunctionalInterface",
  "SafeVarargs", "Optional", "List", "ArrayList", "LinkedList", "Map", "HashMap",
  "LinkedHashMap", "TreeMap", "Set", "HashSet", "LinkedHashSet", "TreeSet", "Collection",
  "Collections", "Arrays", "Objects", "Iterator", "Stream", "IntStream", "LongStream",
  "Collectors", "Function", "BiFunction", "Supplier", "Consumer", "BiConsumer", "Predicate",
  "BigDecimal", "BigInteger", "UUID", "Instant", "Duration", "LocalDate", "LocalDateTime",
})

-- Members every class inherits from Object: calls to them are built-in, not unresolved.
M.object_methods = set({ "toString", "equals", "hashCode", "getClass", "notify", "notifyAll",
  "wait", "clone", "finalize" })

-- Library calls where the main flow ends (§8.3) and that hand control on invisibly.
-- Used from phase 2; listed here because they are per-backend facts.
M.sinks = {
  "java.sql.Statement#execute", "java.sql.Statement#executeUpdate", "java.sql.PreparedStatement#executeUpdate",
  "jakarta.persistence.EntityManager#persist", "jakarta.persistence.EntityManager#merge",
  "java.io.OutputStream#write", "java.io.Writer#write", "java.nio.file.Files#write",
  "java.net.http.HttpClient#send", "java.net.http.HttpClient#sendAsync",
}
M.handoffs = {
  "java.util.concurrent.Executor#execute", "java.util.concurrent.ExecutorService#submit",
  "java.util.concurrent.CompletableFuture#supplyAsync", "java.util.concurrent.CompletableFuture#runAsync",
  "org.springframework.context.ApplicationEventPublisher#publishEvent",
}

-- Qualified names that belong to the platform: an import of a built-in name from here
-- is still a built-in (java.util.List), not a library type.
function M.platform(qualified)
  return qualified:match("^java%.") ~= nil or qualified:match("^javax%.") ~= nil
end

local primitives = set({ "int", "long", "short", "byte", "char", "boolean", "float", "double", "void" })
M.primitives = primitives

local type_kinds = {
  class_declaration = "class",
  interface_declaration = "interface",
  enum_declaration = "enum",
  record_declaration = "record",
  annotation_type_declaration = "annotation",
}
local method_kinds = {
  method_declaration = "method",
  constructor_declaration = "constructor",
  compact_constructor_declaration = "constructor",
}
local compound = set(M.types.compound)
local terminal = set({ "return_statement", "throw_statement", "break_statement", "continue_statement" })
local loops = set({ "for_statement", "enhanced_for_statement", "while_statement", "do_statement" })

local function range(n)
  local a, b, c, d = n:range()
  return { start = { a, b }, ["end"] = { c, d } }
end

local function field(n, name)
  return n:field(name)[1]
end

local function child_of_type(n, t)
  for c in n:iter_children() do
    if c:type() == t then
      return c
    end
  end
end

local function before(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end

-- Context for one file: source text and helpers bound to it.
local function context(file, src)
  local ctx = { file = file, src = src }
  function ctx.text(n)
    return vim.treesitter.get_node_text(n, src)
  end
  return ctx
end

-- A type node to {name = simple name without generics (arrays kept), spelled = as written
-- without generics, e.g. "java.util.List" or "Map.Entry"}.
local function type_ref(ctx, n)
  if not n then
    return nil
  end
  local t = n:type()
  if t == "generic_type" then
    return type_ref(ctx, n:named_child(0))
  elseif t == "array_type" then
    local inner = type_ref(ctx, field(n, "element"))
    local dims = ctx.text(field(n, "dimensions") or n):gsub("%s", "")
    return inner and { name = inner.name .. dims, spelled = inner.spelled .. dims, array = true, element = inner }
  elseif t == "scoped_type_identifier" then
    local parts = {}
    for c in n:iter_children() do
      if c:named() then
        local sub = type_ref(ctx, c)
        if sub then
          parts[#parts + 1] = sub.spelled
        end
      end
    end
    local spelled = table.concat(parts, ".")
    return { name = parts[#parts], spelled = spelled }
  elseif t == "annotated_type" then
    for c in n:iter_children() do
      if c:named() and c:type() ~= "marker_annotation" and c:type() ~= "annotation" then
        return type_ref(ctx, c)
      end
    end
  end
  local text = ctx.text(n):gsub("<.*>", ""):gsub("%s", "")
  return { name = text:match("([^.]+)$") or text, spelled = text }
end
M.type_ref = function(n, src)
  return type_ref(context(nil, src), n)
end

local function modifiers(ctx, n)
  local mods, annotations = {}, {}
  local m = child_of_type(n, "modifiers")
  if m then
    for c in m:iter_children() do
      local t = c:type()
      if t == "marker_annotation" or t == "annotation" then
        local name = field(c, "name")
        annotations[#annotations + 1] = name and ctx.text(name) or ctx.text(c)
      elseif not c:named() then
        mods[ctx.text(c)] = true
      end
    end
  end
  return mods, annotations
end

local function type_parameters(ctx, n)
  local out = {}
  local tp = field(n, "type_parameters")
  if tp then
    for c in tp:iter_children() do
      if c:type() == "type_parameter" then
        local id = child_of_type(c, "type_identifier") or child_of_type(c, "identifier")
        if id then
          out[#out + 1] = ctx.text(id)
        end
      end
    end
  end
  return out
end

local function parameters(ctx, list)
  local params = {}
  if not list then
    return params, false
  end
  local varargs = false
  for c in list:iter_children() do
    local t = c:type()
    if t == "formal_parameter" then
      local ty = type_ref(ctx, field(c, "type"))
      local dims = field(c, "dimensions")
      if dims and ty then
        local d = ctx.text(dims):gsub("%s", "")
        ty = { name = ty.name .. d, spelled = ty.spelled .. d, array = true, element = ty }
      end
      local name = field(c, "name")
      params[#params + 1] = { name = name and ctx.text(name), type = ty, range = range(c),
        name_range = name and range(name) }
    elseif t == "spread_parameter" then
      local ty
      for s in c:iter_children() do
        if s:named() and s:type() ~= "variable_declarator" and s:type() ~= "modifiers" and not ty then
          ty = type_ref(ctx, s)
        end
      end
      local decl = child_of_type(c, "variable_declarator")
      local name = decl and field(decl, "name")
      params[#params + 1] = { name = name and ctx.text(name), type = ty, varargs = true, range = range(c),
        name_range = name and range(name) }
      varargs = true
    end
  end
  return params, varargs
end

local function param_key(p)
  local name = p.type and p.type.name or "?"
  return p.varargs and (name .. "...") or name
end

-- Pass 1 ----------------------------------------------------------------------

-- Returns FileFacts plus a private list of bodies (Tree-sitter nodes) for pass 2.
function M.declarations(file, root, src)
  local ctx = context(file, src)
  local facts = {
    file = file,
    lang = M.name,
    package = "",
    imports = { single = {}, wildcard = {}, static_single = {}, static_wildcard = {}, list = {} },
    types = {},
    type_order = {},
    symbols = {},
    names = {},
    bodies = {},
    error = root:has_error(),
  }
  local pending = {}
  local file_id = "file:" .. file
  facts.symbols[file_id] = { id = file_id, kind = "file", label = vim.fs.basename(file), file = file,
    range = range(root), source = "ast" }

  local function declare(sym)
    facts.symbols[sym.id] = sym
    local simple = sym.name
    if simple then
      facts.names[simple] = facts.names[simple] or {}
      table.insert(facts.names[simple], sym.id)
    end
  end

  local walk_type

  local function add_method(n, owner)
    local kind = method_kinds[n:type()]
    local name_node = field(n, "name")
    local name = name_node and ctx.text(name_node) or owner.name
    local params, varargs
    if n:type() == "compact_constructor_declaration" then
      params, varargs = {}, false
      for _, comp in ipairs(owner.components) do
        params[#params + 1] = { name = comp.name, type = comp.type, range = comp.range }
      end
    else
      params, varargs = parameters(ctx, field(n, "parameters"))
    end
    local keys = {}
    for i, p in ipairs(params) do
      keys[i] = param_key(p)
    end
    local id = owner.id .. "#" .. name .. "(" .. table.concat(keys, ",") .. ")"
    local mods, annotations = modifiers(ctx, n)
    local body = field(n, "body")
    local abstract = body == nil
    local signature
    if body then
      local sr, sc = n:start()
      local br, bc = body:start()
      local lines = vim.split(src, "\n", { plain = true })
      local parts = {}
      for r = sr, br do
        local line = lines[r + 1] or ""
        local from = r == sr and sc + 1 or 1
        local to = r == br and bc or #line
        parts[#parts + 1] = line:sub(from, to)
      end
      signature = vim.trim(table.concat(parts, "\n"):gsub("%s+", " "))
    else
      signature = vim.trim(ctx.text(n):gsub("%s+", " "))
    end
    local ret = kind == "method" and type_ref(ctx, field(n, "type")) or nil
    local sym = {
      id = id,
      kind = kind,
      name = name,
      label = owner.name .. "." .. name .. "(" .. table.concat(keys, ", ") .. ")",
      file = file,
      range = range(n),
      owner = owner.id,
      params = params,
      varargs = varargs,
      returns = ret and ret.name,
      returns_spelled = ret and ret.spelled,
      modifiers = mods,
      annotations = annotations,
      static = mods.static == true,
      abstract = abstract,
      signature = signature,
      type_params = type_parameters(ctx, n),
      error = n:has_error(),
      source = "ast",
    }
    if facts.symbols[id] then
      sym.duplicate = true -- same name and parameter types twice: keep the first
      return
    end
    declare(sym)
    table.insert(owner.methods, id)
    if body then
      pending[#pending + 1] = { id = id, node = body, method = n, owner = owner }
    end
  end

  local function add_field(n, owner)
    local ty = type_ref(ctx, field(n, "type"))
    local mods = modifiers(ctx, n)
    for decl in n:iter_children() do
      if decl:type() == "variable_declarator" then
        local name_node = field(decl, "name")
        local name = ctx.text(name_node)
        local fty = ty
        local dims = field(decl, "dimensions")
        if dims and ty then
          local d = ctx.text(dims):gsub("%s", "")
          fty = { name = ty.name .. d, spelled = ty.spelled .. d, array = true, element = ty }
        end
        local id = owner.id .. "#" .. name
        local sym = { id = id, kind = "field", name = name, label = owner.name .. "." .. name, file = file,
          range = range(decl), owner = owner.id, type = fty, static = mods.static == true
            or owner.kind == "interface", volatile = mods.volatile == true, source = "ast" }
        declare(sym)
        owner.fields[name] = id
        local value = field(decl, "value")
        if value then
          pending[#pending + 1] = { id = owner.id, node = value, owner = owner, initializer = true, field = name }
        end
      end
    end
  end

  local anonymous -- forward: enum constants with bodies are anonymous subclasses
  -- javac's numbering of anonymous ($1) and local ($1Name) classes, per enclosing class
  local counters = {}
  local function counter(outer)
    counters[outer.id] = counters[outer.id] or { anon = 0, named = {} }
    return counters[outer.id]
  end

  local function body_members(body, owner)
    for c in body:iter_children() do
      local t = c:type()
      if method_kinds[t] then
        add_method(c, owner)
      elseif t == "field_declaration" or t == "constant_declaration" then
        add_field(c, owner)
      elseif type_kinds[t] then
        walk_type(c, owner)
      elseif t == "enum_constant" then
        local name = ctx.text(field(c, "name"))
        local id = owner.id .. "#" .. name
        declare({ id = id, kind = "field", name = name, label = owner.name .. "." .. name, file = file,
          range = range(c), owner = owner.id, type = { name = owner.name, spelled = owner.name },
          static = true, enum_constant = true, source = "ast" })
        owner.fields[name] = id
        local args = field(c, "arguments")
        if args then
          pending[#pending + 1] = { id = owner.id, node = args, owner = owner, initializer = true }
        end
        local cbody = field(c, "body") or child_of_type(c, "class_body")
        if cbody then
          local sub = anonymous(cbody, owner, { name = owner.name, spelled = owner.name }, c)
          facts.symbols[id].body_type = sub.id
        end
      elseif t == "enum_body_declarations" then
        body_members(c, owner)
      elseif t == "static_initializer" or t == "block" then
        pending[#pending + 1] = { id = owner.id, node = c, owner = owner, initializer = true }
      end
    end
  end

  -- opts.local_index: a local class (Outer$1Name), declared in body opts.enclosing_body
  function walk_type(n, outer, opts)
    opts = opts or {}
    local name = ctx.text(field(n, "name"))
    local qname = outer and (outer.qname .. "." .. name)
      or (facts.package ~= "" and (facts.package .. "." .. name) or name)
    if opts.local_index then
      qname = outer.qname .. "$" .. opts.local_index .. name
    end
    local kind = type_kinds[n:type()]
    local mods, annotations = modifiers(ctx, n)
    local sym = {
      id = "java:" .. qname,
      kind = kind,
      name = name,
      qname = qname,
      label = name,
      file = file,
      range = range(n),
      outer = outer and outer.id or nil,
      extends = {},
      implements = {},
      type_params = type_parameters(ctx, n),
      fields = {},
      methods = {},
      nested = {},
      components = {},
      modifiers = mods,
      annotations = annotations,
      abstract = mods.abstract == true or kind == "interface",
      error = n:has_error(),
      ["local"] = opts.local_index and true or nil,
      enclosing_body = opts.enclosing_body,
      source = "ast",
    }
    declare(sym)
    if outer and not opts.local_index then
      outer.nested[name] = sym.id
    end
    facts.types[qname] = sym.id
    facts.type_order[#facts.type_order + 1] = sym.id
    local super = field(n, "superclass")
    if super then
      for c in super:iter_children() do
        if c:named() then
          sym.extends[#sym.extends + 1] = type_ref(ctx, c)
        end
      end
    end
    local function type_list(holder, into)
      local list = holder and child_of_type(holder, "type_list")
      if list then
        for c in list:iter_children() do
          if c:named() then
            into[#into + 1] = type_ref(ctx, c)
          end
        end
      end
    end
    if kind == "interface" then
      type_list(child_of_type(n, "extends_interfaces"), sym.extends)
    else
      type_list(field(n, "interfaces"), sym.implements)
    end
    if kind == "record" then
      local params = parameters(ctx, field(n, "parameters"))
      for _, p in ipairs(params) do
        local id = sym.id .. "#" .. p.name
        declare({ id = id, kind = "field", name = p.name, label = name .. "." .. p.name, file = file,
          range = p.range, owner = sym.id, type = p.type, component = true, source = "ast" })
        sym.fields[p.name] = id
        sym.components[#sym.components + 1] = { name = p.name, type = p.type, range = p.range, field = id }
      end
    end
    local body = field(n, "body")
    if body then
      body_members(body, sym)
    end
    -- §4.2: record components also give implicit accessors, unless declared explicitly
    for _, comp in ipairs(sym.components) do
      local id = sym.id .. "#" .. comp.name .. "()"
      if not facts.symbols[id] then
        declare({ id = id, kind = "method", name = comp.name, label = name .. "." .. comp.name .. "()", file = file,
          range = comp.range, owner = sym.id, params = {}, varargs = false, returns = comp.type and comp.type.name,
          returns_spelled = comp.type and comp.type.spelled, modifiers = {}, annotations = {}, static = false,
          abstract = false, implicit = true, accessor = comp.field, signature = (comp.type and comp.type.spelled or "?")
            .. " " .. comp.name .. "()", type_params = {}, source = "ast" })
        table.insert(sym.methods, id)
      end
    end
    return sym
  end

  -- An anonymous class body (`new T() { … }`, or an enum constant's body): a class
  -- Outer$N whose supertype is T, a class or an interface (the resolver decides).
  function anonymous(cb, outer, super, node, enclosing_body)
    local c = counter(outer)
    c.anon = c.anon + 1
    local qname = outer.qname .. "$" .. c.anon
    local sym = {
      id = "java:" .. qname,
      kind = "class",
      name = outer.name .. "$" .. c.anon,
      qname = qname,
      label = outer.name .. "$" .. c.anon,
      file = file,
      range = range(node or cb),
      outer = outer.id,
      extends = super and { super } or {},
      implements = {},
      type_params = {},
      fields = {},
      methods = {},
      nested = {},
      components = {},
      modifiers = {},
      annotations = {},
      abstract = false,
      anonymous = true,
      enclosing_body = enclosing_body,
      error = cb:has_error(),
      source = "ast",
    }
    declare(sym)
    facts.types[qname] = sym.id
    facts.type_order[#facts.type_order + 1] = sym.id
    body_members(cb, sym)
    return sym
  end

  local declarer = {
    walk_type = walk_type,
    anonymous = anonymous,
    local_index = function(outer, name)
      local c = counter(outer)
      c.named[name] = (c.named[name] or 0) + 1
      return c.named[name]
    end,
  }

  for c in root:iter_children() do
    local t = c:type()
    if t == "package_declaration" then
      for p in c:iter_children() do
        if p:type() == "scoped_identifier" or p:type() == "identifier" then
          facts.package = ctx.text(p)
        end
      end
    elseif t == "import_declaration" then
      local text = ctx.text(c):gsub("^import%s+", ""):gsub("%s*;%s*$", ""):gsub("%s", "")
      local static = false
      if text:match("^static") and child_of_type(c, "static") then
        static, text = true, text:gsub("^static", "")
      end
      local wildcard = child_of_type(c, "asterisk") ~= nil
      local path = wildcard and text:gsub("%.%*$", "") or text
      local entry = { path = path, static = static, wildcard = wildcard, range = range(c) }
      facts.imports.list[#facts.imports.list + 1] = entry
      if static and wildcard then
        table.insert(facts.imports.static_wildcard, path)
      elseif static then
        local owner, member = path:match("^(.*)%.([^.]+)$")
        facts.imports.static_single[member] = facts.imports.static_single[member] or {}
        table.insert(facts.imports.static_single[member], owner)
      elseif wildcard then
        table.insert(facts.imports.wildcard, path)
      else
        facts.imports.single[path:match("([^.]+)$")] = path
      end
    elseif type_kinds[t] then
      walk_type(c, nil)
    end
  end
  pending.declarer = declarer
  return facts, pending
end

-- Pass 2 ----------------------------------------------------------------------

local literal_types = {
  string_literal = "String",
  text_block = "String",
  character_literal = "char",
  ["true"] = "boolean",
  ["false"] = "boolean",
  null_literal = "null",
  decimal_floating_point_literal = "double",
  hex_floating_point_literal = "double",
}
local integer_literals = set({ "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal",
  "binary_integer_literal" })

local function literal_type(ctx, n)
  local t = n:type()
  if integer_literals[t] then
    return ctx.text(n):match("[lL]$") and "long" or "int"
  end
  if t == "decimal_floating_point_literal" and ctx.text(n):match("[fF]$") then
    return "float"
  end
  return literal_types[t]
end

local function is_statement(n)
  local t = n:type()
  return compound[t] or t:match("_statement$") ~= nil or t == "local_variable_declaration"
    or t == "explicit_constructor_invocation" or t == "class_declaration" or t == "record_declaration"
    or t == "interface_declaration" or t == "enum_declaration" or t == "block"
end
M.is_statement = is_statement

local function is_comment(n)
  return n:type() == "line_comment" or n:type() == "block_comment"
end

local function only_terminal(n)
  if not n then
    return false
  end
  if terminal[n:type()] then
    return true
  end
  if n:type() == "block" then
    local count, last = 0, nil
    for c in n:iter_children() do
      if c:named() and not is_comment(c) then
        count, last = count + 1, c
      end
    end
    return count == 1 and terminal[last:type()] == true
  end
  return false
end

-- Pass 2 for one file: fills facts.bodies[symbol id] for every remembered body.
function M.bodies(file, src, facts, pending)
  local ctx = context(file, src)
  local lines = vim.split(src, "\n", { plain = true })

  local function blank_between(prev_end_row, start_row)
    for r = prev_end_row + 1, start_row - 1 do
      if vim.trim(lines[r + 1] or "") == "" then
        return true
      end
    end
    return false
  end

  local declarer = pending.declarer
  local function new_body(id)
    local b = { symbol = id, locals = {}, sites = {}, stmts = {}, field_writes = {}, casts = {},
      metrics = { lines = 0, statements = 0, branches = 0, loops = 0, sites = 0, project_sites = 0,
        field_writes = 0, throws = 0 } }
    facts.bodies[id] = b
    return b
  end

  -- One walker per file. `body` (the symbol whose sites are being recorded) and `owner`
  -- (its type) switch when a local or anonymous class's members are walked in place, so
  -- those members see the enclosing method's names (captured locals) yet own their sites.
  local body, owner
  local site_of_node = {} -- node id -> site
  local pending_uses = {} -- uses waiting for the site id of their call
  local pending_calls = {} -- lambdas and method references waiting for their call's site id
  local stmt_stack = {}
  local scopes = {}
  local lambda_stack = {} -- innermost lambda: { call_node, arg }

  local function push_scope()
    scopes[#scopes + 1] = {}
  end
  local function pop_scope()
    scopes[#scopes] = nil
  end
  local function lookup(name)
    for i = #scopes, 1, -1 do
      local l = scopes[i][name]
      if l then
        return l
      end
    end
  end
  local function declare(name_node, ty, kind, scope_node, extra)
    local name = ctx.text(name_node)
    local r = range(scope_node)
    local loc = vim.tbl_extend("force", {
      name = name,
      type = ty and ty.name ~= "var" and ty.name or nil,
      spelled = ty and ty.name ~= "var" and ty.spelled or nil,
      var = ty and ty.name == "var" or nil,
      kind = kind,
      declared_at = range(name_node).start,
      scope = { start = range(name_node).start, ["end"] = r["end"] },
      definitions = {},
      uses = {},
    }, extra or {})
    if kind == "param" or kind == "lambda" or kind == "for" or kind == "catch" then
      loc.scope.start = r.start
    end
    body.locals[#body.locals + 1] = loc
    loc.index = #body.locals
    loc.body = body.symbol
    scopes[#scopes][name] = loc
    return loc
  end

  -- The call (and argument position) that a lambda or method reference is passed to.
  local function passed_to(n)
    local parent = n:parent()
    if parent and parent:type() == "argument_list" then
      local index = 0
      for c in parent:iter_children() do
        if c:named() and not is_comment(c) then
          index = index + 1
          if c:id() == n:id() then
            break
          end
        end
      end
      return { call_node = parent:parent():id(), arg = index }
    end
  end

  local new_site, visit, statement_list, run_inline

  -- Receiver descriptor (§4.2) for an expression in receiver or argument position.
  local function describe(n)
    if not n then
      return { k = "implicit" }
    end
    local t = n:type()
    if t == "parenthesized_expression" then
      return describe(n:named_child(0))
    elseif t == "identifier" then
      local l = lookup(ctx.text(n))
      return { k = "id", name = ctx.text(n), ["local"] = l and l.index or nil,
        local_body = l and l.body ~= body.symbol and l.body or nil }
    elseif t == "this" then
      return { k = "this" }
    elseif t == "super" then
      return { k = "super" }
    elseif t == "field_access" then
      local f = field(n, "field")
      local object = field(n, "object")
      if f:type() == "this" then
        return { k = "this", outer = ctx.text(object):gsub("%s", "") }
      elseif f:type() == "super" then
        return { k = "super", outer = ctx.text(object):gsub("%s", "") }
      end
      return { k = "field", object = describe(object), name = ctx.text(f) }
    elseif t == "method_invocation" then
      local s = site_of_node[n:id()]
      local args = field(n, "arguments")
      return { k = "call", site = s and s.id, name = ctx.text(field(n, "name")),
        arity = args and args:named_child_count() or 0 }
    elseif t == "object_creation_expression" then
      local s = site_of_node[n:id()]
      local ty = type_ref(ctx, field(n, "type"))
      return { k = "new", type = ty and ty.spelled, site = s and s.id }
    elseif t == "cast_expression" then
      local ty = type_ref(ctx, field(n, "type"))
      return { k = "cast", type = ty and ty.spelled }
    elseif t == "array_creation_expression" then
      return { k = "lit", type = "array" }
    elseif t == "binary_expression" then
      -- String concatenation is the one binary expression whose type matters for overloads.
      local l, r = describe(field(n, "left")), describe(field(n, "right"))
      local op = n:child(1) and ctx.text(n:child(1))
      if op == "+" and ((l.k == "lit" and l.type == "String") or (r.k == "lit" and r.type == "String")) then
        return { k = "lit", type = "String", expr = true }
      end
      return { k = "other" }
    end
    local lit = literal_type(ctx, n)
    if lit then
      return { k = "lit", type = lit }
    end
    return { k = "other" }
  end

  -- Where an identifier use sits: argument of a call, receiver of a call, returned.
  local function record_use(n, loc)
    local use = { at = range(n).start, body = loc.body ~= body.symbol and body.symbol or nil }
    local stmt = stmt_stack[#stmt_stack]
    use.stmt = stmt and stmt.range or nil
    local child, parent = n, n:parent()
    while parent do
      local pt = parent:type()
      if pt == "argument_list" then
        local call = parent:parent()
        local index = 0
        for c in parent:iter_children() do
          if c:named() and not is_comment(c) then
            index = index + 1
            if c:id() == child:id() then
              break
            end
          end
        end
        use.arg = index
        use.call_node = call:id()
        break
      elseif (pt == "method_invocation" and field(parent, "object") and field(parent, "object"):id() == child:id()) then
        use.receiver = true
        use.call_node = parent:id()
        break
      elseif pt == "return_statement" then
        use.returned = true
        break
      elseif pt == "lambda_expression" or is_statement(parent) then
        break
      end
      child, parent = parent, parent:parent()
    end
    -- a use inside a return expression is also returned when it is an argument there
    local p = n:parent()
    while p and not is_statement(p) do
      p = p:parent()
    end
    if p and p:type() == "return_statement" then
      use.returned = true
    end
    loc.uses[#loc.uses + 1] = use
    if use.call_node then
      pending_uses[#pending_uses + 1] = use
    end
  end

  local function sites_in(fn)
    local first = #body.sites + 1
    fn()
    local ids = {}
    for i = first, #body.sites do
      ids[#ids + 1] = body.sites[i].id
    end
    return ids
  end

  local function field_write(target)
    local t = target:type()
    local w
    if t == "field_access" then
      local object, f = field(target, "object"), field(target, "field")
      if object:type() == "this" then
        w = { object = "this", name = ctx.text(f) }
      elseif object:type() == "field_access" and field(object, "field"):type() == "this" then
        w = { object = "this", outer = ctx.text(field(object, "object")), name = ctx.text(f) }
      elseif object:type() == "identifier" then
        local l = lookup(ctx.text(object))
        if l then
          w = { object = l.name, name = ctx.text(f), param = l.kind == "param" and l.param or nil,
            ["local"] = l.kind ~= "param" or nil }
        else
          w = { object = ctx.text(object), name = ctx.text(f), static = true }
        end
      end
    elseif t == "identifier" then
      local l = lookup(ctx.text(target))
      if not l then
        w = { object = "this", name = ctx.text(target), implicit = true }
      end
      return w, l
    end
    return w
  end

  local function assignment(n, left, right)
    local w, l = field_write(left)
    if w then
      w.at = range(n).start
      body.field_writes[#body.field_writes + 1] = w
      for _, s in ipairs(stmt_stack) do
        s.field_writes[#s.field_writes + 1] = { object = w.object, name = w.name }
      end
    end
    local ids = sites_in(function()
      if left:type() ~= "identifier" then
        visit(left)
      end
      if right then
        visit(right)
      end
    end)
    if w and right then
      w.value = describe(right) -- what is stored: construction tracking (§8.5)
    end
    if l then
      l.definitions[#l.definitions + 1] = { range = range(n), sites = ids,
        op = n:type() == "update_expression" and "update" or (n:child(1) and ctx.text(n:child(1))) }
      if n:type() == "update_expression" or (n:child(1) and ctx.text(n:child(1)) ~= "=") then
        record_use(left, l)
      end
    end
  end

  -- Badge text and range (§3.3).
  local function badge(n, object, name_node)
    local function span(a, b)
      local ra, rb = range(a), range(b)
      return { start = ra.start, ["end"] = rb["end"] }
    end
    if object and name_node then
      local ot = object:type()
      local same_line = range(object).start[1] == range(name_node).start[1]
      if same_line and (ot == "identifier" or ot == "this" or ot == "super") then
        local r = span(object, name_node)
        return ctx.text(object) .. "." .. ctx.text(name_node), r
      elseif same_line and ot == "field_access" then
        local inner, f = field(object, "object"), field(object, "field")
        if inner:type() == "this" and f:type() == "identifier" then
          return ctx.text(f) .. "." .. ctx.text(name_node), span(f, name_node)
        elseif inner:type() == "identifier" and f:type() == "identifier" then
          return ctx.text(inner) .. "." .. ctx.text(f) .. "." .. ctx.text(name_node), span(inner, name_node)
        end
      end
    end
    if name_node then
      return ctx.text(name_node), range(name_node)
    end
    return ctx.text(n), range(n)
  end

  function new_site(n, kind, data)
    local s = vim.tbl_extend("force", {
      id = "s" .. (#body.sites + 1),
      order = #body.sites + 1,
      kind = kind,
      at = range(n).start,
      node_range = range(n),
    }, data)
    local lambda = lambda_stack[#lambda_stack]
    if lambda then
      -- runs when the lambda runs: during the call it is passed to (call = that site), or
      -- later, when it is stored or returned (no call)
      s.deferred = { kind = "lambda", call_node = lambda.call_node, arg = lambda.arg }
      if lambda.call_node then
        pending_calls[#pending_calls + 1] = { ref = s.deferred }
      end
    end
    body.sites[#body.sites + 1] = s
    site_of_node[n:id()] = s
    for _, st in ipairs(stmt_stack) do
      st.sites[#st.sites + 1] = s.id
    end
    return s
  end

  local function args_of(list)
    local out = {}
    if list then
      for c in list:iter_children() do
        if c:named() and not is_comment(c) then
          out[#out + 1] = describe(c)
          out[#out].at = range(c).start
        end
      end
    end
    return out
  end

  local class_members

  local function visit_children(n)
    for c in n:iter_children() do
      if c:named() then
        visit(c)
      end
    end
  end

  local function local_declaration(n, scope_node)
    local ty = type_ref(ctx, field(n, "type"))
    for decl in n:iter_children() do
      if decl:type() == "variable_declarator" then
        local value = field(decl, "value")
        local ids = {}
        if value then
          ids = sites_in(function()
            visit(value)
          end)
        end
        local dims = field(decl, "dimensions")
        local dty = ty
        if dims and ty then
          local d = ctx.text(dims):gsub("%s", "")
          dty = { name = ty.name .. d, spelled = ty.spelled .. d }
        end
        local loc = declare(field(decl, "name"), dty, "local", scope_node)
        if value then
          loc.definitions[#loc.definitions + 1] = { range = range(value), sites = ids, init = true }
          if loc.var then
            loc.infer = describe(value)
          end
        end
      end
    end
  end

  -- Scope that a declaration statement opens: from the declaration to the end of its block.
  local function enclosing_block(n)
    local p = n:parent()
    while p and not (p:type() == "block" or p:type() == "constructor_body" or p:type() == "switch_block_statement_group"
        or p:type() == "switch_rule" or p:type() == "lambda_expression") do
      p = p:parent()
    end
    return p or n
  end

  function visit(n)
    local t = n:type()
    if t == "method_invocation" then
      local object, name_node = field(n, "object"), field(n, "name")
      if object then
        visit(object)
      end
      local args = field(n, "arguments")
      if args then
        visit(args)
      end
      local receiver = describe(object)
      local qualified_super = child_of_type(n, "super")
      if qualified_super and object and qualified_super:id() == object:id() then
        qualified_super = nil -- plain super.m(): the object is the keyword itself
      end
      local text, r
      if qualified_super and object then
        receiver = { k = "super", outer = ctx.text(object):gsub("%s", "") }
        text = receiver.outer .. ".super." .. ctx.text(name_node)
        r = { start = range(object).start, ["end"] = range(name_node)["end"] }
        if r.start[1] ~= r["end"][1] then
          text, r = ctx.text(name_node), range(name_node)
        end
      elseif field(n, "type_arguments") then
        text, r = ctx.text(name_node), range(name_node) -- this.<T>m(): the name alone
      else
        text, r = badge(n, object, name_node)
      end
      new_site(n, "call", { name = ctx.text(name_node), text = text, range = r, receiver = receiver,
        args = args_of(args), arity = args and args:named_child_count() or 0 })
    elseif t == "object_creation_expression" then
      local outer = n:named_child(0)
      if outer and outer:type() ~= "type_identifier" and outer:type() ~= "generic_type"
          and outer:type() ~= "scoped_type_identifier" and field(n, "type") and outer:id() ~= field(n, "type"):id() then
        visit(outer) -- qualified creation: outer.new Inner()
      end
      local args = field(n, "arguments")
      if args then
        visit(args)
      end
      local tnode = field(n, "type")
      local ty = type_ref(ctx, tnode)
      -- the badge spans `new` and the type as spelled, without type arguments
      local type_end = tnode:type() == "generic_type" and tnode:named_child(0) or tnode
      local r = { start = range(n).start, ["end"] = range(type_end)["end"] }
      local text = "new " .. ty.spelled
      if r.start[1] ~= r["end"][1] then
        text = "new " .. ty.name
      end
      local s = new_site(n, "new", { name = ty.name, type = ty.spelled, text = text, range = r,
        receiver = { k = "new", type = ty.spelled }, args = args_of(args),
        arity = args and args:named_child_count() or 0 })
      local cb = child_of_type(n, "class_body")
      if cb then
        s.anonymous = class_members(cb, { anonymous = true, super = ty, node = n })
      end
    elseif t == "explicit_constructor_invocation" then
      local ctor = field(n, "constructor")
      local args = field(n, "arguments")
      if args then
        visit(args)
      end
      local kind = ctx.text(ctor) == "super" and "super()" or "this()"
      new_site(n, kind, { name = ctx.text(ctor), text = ctx.text(ctor), range = range(ctor),
        receiver = { k = ctx.text(ctor) }, args = args_of(args), arity = args and args:named_child_count() or 0 })
    elseif t == "method_reference" then
      local left = n:named_child(0)
      local right = n:named_child(n:named_child_count() - 1)
      local name = (right and right:id() ~= left:id()) and ctx.text(right) or "new"
      if n:named_child_count() == 1 then
        name = "new"
      end
      local lt = left:type()
      local receiver
      if lt == "type_identifier" or lt == "scoped_type_identifier" or lt == "generic_type" or lt == "array_type" then
        receiver = { k = "type", type = type_ref(ctx, left).spelled }
      else
        if lt ~= "identifier" and lt ~= "this" and lt ~= "super" then
          visit(left)
        end
        receiver = describe(left)
        if receiver.k == "id" and not receiver["local"] then
          receiver.maybe_type = true
        end
      end
      local ref = new_site(n, "method_ref", { name = name, text = vim.trim(ctx.text(n):gsub("%s", "")),
        range = range(n), receiver = receiver, args = {}, arity = -1 })
      local passed = passed_to(n)
      if passed then
        ref.passed = passed
        pending_calls[#pending_calls + 1] = { ref = passed }
      end
    elseif t == "lambda_expression" then
      lambda_stack[#lambda_stack + 1] = passed_to(n) or {}
      push_scope()
      local params = field(n, "parameters")
      local bodyn = field(n, "body")
      if params then
        if params:type() == "identifier" then
          declare(params, nil, "lambda", n)
        elseif params:type() == "inferred_parameters" then
          for c in params:iter_children() do
            if c:type() == "identifier" then
              declare(c, nil, "lambda", n)
            end
          end
        else
          local list = parameters(ctx, params)
          local i = 0
          for c in params:iter_children() do
            if c:type() == "formal_parameter" or c:type() == "spread_parameter" then
              i = i + 1
              local nm = field(c, "name")
              if nm then
                declare(nm, list[i].type, "lambda", n)
              end
            end
          end
        end
      end
      if bodyn then
        if bodyn:type() == "block" then
          statement_list(bodyn, {})
        else
          visit(bodyn)
        end
      end
      pop_scope()
      lambda_stack[#lambda_stack] = nil
    elseif t == "local_variable_declaration" then
      local_declaration(n, enclosing_block(n))
    elseif t == "assignment_expression" then
      assignment(n, field(n, "left"), field(n, "right"))
    elseif t == "update_expression" then
      local target = n:named_child(0)
      assignment(n, target, nil)
    elseif t == "identifier" then
      local l = lookup(ctx.text(n))
      if l then
        record_use(n, l)
      end
    elseif t == "field_access" then
      visit(field(n, "object"))
    elseif t == "cast_expression" then
      local ty = type_ref(ctx, field(n, "type"))
      if ty then
        body.casts[#body.casts + 1] = { type = ty.spelled, at = range(n).start }
      end
      visit(field(n, "value"))
    elseif t == "instanceof_expression" then
      visit(field(n, "left"))
      local name = field(n, "name")
      if name then
        declare(name, type_ref(ctx, field(n, "right")), "pattern", enclosing_block(n))
      end
      local pattern = field(n, "pattern") or child_of_type(n, "record_pattern") or child_of_type(n, "type_pattern")
      if pattern then
        local function patterns(p)
          for c in p:iter_children() do
            if c:type() == "type_pattern" then
              local ty, nm
              for x in c:iter_children() do
                if x:type() == "identifier" then
                  nm = x
                elseif x:named() then
                  ty = type_ref(ctx, x)
                end
              end
              if nm then
                declare(nm, ty, "pattern", enclosing_block(n))
              end
            elseif c:named() then
              patterns(c)
            end
          end
        end
        patterns(n)
      end
    elseif t == "class_declaration" or t == "record_declaration" or t == "interface_declaration"
        or t == "enum_declaration" then
      class_members(n, {})
    elseif t == "block" or t == "constructor_body" then
      statement_list(n, {})
    elseif is_statement(n) then
      statement_list(nil, {}, n)
    else
      visit_children(n)
    end
  end

  -- A local or anonymous class (§4.2 never enters bodies, so pass 1 cannot see it): it
  -- becomes a type symbol (javac's Outer$1, Outer$1Name), declared now, and its members'
  -- bodies are walked in place, so they capture the enclosing method's names.
  -- info: { anonymous = true, super = type ref, node = creation expression } or {}.
  function class_members(n, info)
    local first = #pending + 1
    local sym
    if info.anonymous then
      sym = declarer.anonymous(n, owner, info.super, info.node, body.symbol)
    else
      local name = ctx.text(field(n, "name"))
      sym = declarer.walk_type(n, owner, { local_index = declarer.local_index(owner, name),
        enclosing_body = body.symbol })
      body.local_types = body.local_types or {}
      body.local_types[name] = sym.id
    end
    run_inline(first)
    return sym.id
  end

  -- A switch label: pattern variables are declared for the arm, and a guard is evaluated
  -- before it (review #3).
  local function switch_label(lbl, scope_node)
    for x in lbl:iter_children() do
      if x:type() == "pattern" or x:type() == "type_pattern" or x:type() == "record_pattern" then
        local function patterns(p)
          if p:type() == "type_pattern" then
            local ty, nm
            for y in p:iter_children() do
              if y:type() == "identifier" then
                nm = y
              elseif y:named() then
                ty = type_ref(ctx, y)
              end
            end
            if nm then
              declare(nm, ty, "pattern", scope_node)
            end
          else
            for y in p:iter_children() do
              if y:named() then
                patterns(y)
              end
            end
          end
        end
        patterns(x)
      elseif x:type() == "guard" then
        visit_children(x)
      end
    end
  end

  -- Arms of a compound statement, each {name, index, range, header, stmts}.
  local function arms_of(n, rec)
    local t = n:type()
    local function arm(name, index, header_node, content, scope_fn)
      if not content then
        return
      end
      local a = { name = name, index = index, range = { start = range(header_node).start,
        ["end"] = range(content)["end"] }, stmts = {} }
      rec.arms[#rec.arms + 1] = a
      push_scope()
      if scope_fn then
        scope_fn()
      end
      if content:type() == "block" or content:type() == "switch_block_statement_group" then
        statement_list(content, a.stmts)
      else
        statement_list(nil, a.stmts, content)
      end
      pop_scope()
      return a
    end
    if t == "if_statement" then
      visit(field(n, "condition"))
      local cons, alt = field(n, "consequence"), field(n, "alternative")
      arm("then", nil, cons, cons)
      if alt then
        local kw
        for c in n:iter_children() do
          if not c:named() and ctx.text(c) == "else" then
            kw = c
          end
        end
        arm("else", nil, kw or alt, alt)
      end
    elseif t == "for_statement" then
      push_scope()
      for c, f in n:iter_children() do
        if c:named() and f ~= "body" then
          if c:type() == "local_variable_declaration" then
            local_declaration(c, n)
          else
            visit(c)
          end
        end
      end
      arm("body", nil, field(n, "body"), field(n, "body"))
      pop_scope()
    elseif t == "enhanced_for_statement" then
      visit(field(n, "value"))
      local bodyn = field(n, "body")
      arm("body", nil, bodyn, bodyn, function()
        local nm = field(n, "name")
        declare(nm, type_ref(ctx, field(n, "type")), "for", bodyn, { subject = ctx.text(field(n, "value")) })
      end)
    elseif t == "while_statement" or t == "do_statement" then
      if t == "while_statement" then
        visit(field(n, "condition"))
      end
      arm("body", nil, field(n, "body"), field(n, "body"))
      if t == "do_statement" then
        visit(field(n, "condition"))
      end
    elseif t == "synchronized_statement" then
      for c in n:iter_children() do
        if c:type() == "parenthesized_expression" then
          visit(c)
        end
      end
      arm("body", nil, field(n, "body"), field(n, "body"))
    elseif t == "labeled_statement" then
      for c in n:iter_children() do
        if c:named() and c:type() ~= "identifier" then
          arm("body", nil, c, c)
        end
      end
    elseif t == "try_statement" or t == "try_with_resources_statement" then
      push_scope()
      local res = field(n, "resources")
      if res then
        for r in res:iter_children() do
          if r:type() == "resource" then
            local value = field(r, "value")
            local ids = {}
            if value then
              ids = sites_in(function()
                visit(value)
              end)
            end
            local nm = field(r, "name")
            if nm then
              local loc = declare(nm, type_ref(ctx, field(r, "type")), "resource", n)
              if value then
                loc.definitions[#loc.definitions + 1] = { range = range(value), sites = ids, init = true }
                if loc.var then
                  loc.infer = describe(value)
                end
              end
            else
              visit(r)
            end
          end
        end
      end
      arm("body", nil, field(n, "body"), field(n, "body"))
      local ci = 0
      for c in n:iter_children() do
        if c:type() == "catch_clause" then
          local bodyn = field(c, "body")
          arm("catch", ci, c, bodyn, function()
            local p = child_of_type(c, "catch_formal_parameter")
            local nm = p and field(p, "name")
            if nm then
              local ct = child_of_type(p, "catch_type")
              local first = ct and ct:named_child(0)
              local ty = first and type_ref(ctx, first)
              if ct and ct:named_child_count() > 1 then
                ty = nil -- multi-catch: a union type
              end
              declare(nm, ty, "catch", bodyn)
            end
          end)
          ci = ci + 1
        elseif c:type() == "finally_clause" then
          arm("finally", nil, c, child_of_type(c, "block"))
        end
      end
      pop_scope()
    elseif t == "switch_expression" or t == "switch_statement" then
      visit(field(n, "condition"))
      local block = field(n, "body")
      local ci = 0
      if block then
        push_scope() -- statement groups of one switch block share their declarations
        for c in block:iter_children() do
          if c:type() == "switch_rule" then
            local content
            for x in c:iter_children() do
              if x:named() and x:type() ~= "switch_label" then
                content = x
              end
            end
            if content then
              local a = { name = "case", index = ci, range = range(c), stmts = {} }
              rec.arms[#rec.arms + 1] = a
              push_scope()
              for x in c:iter_children() do
                if x:type() == "switch_label" then
                  switch_label(x, c)
                end
              end
              if content:type() == "block" then
                statement_list(content, a.stmts)
              elseif is_statement(content) then
                statement_list(nil, a.stmts, content)
              else
                visit(content)
              end
              pop_scope()
            end
            ci = ci + 1
          elseif c:type() == "switch_block_statement_group" then
            local a = { name = "case", index = ci, range = range(c), stmts = {} }
            rec.arms[#rec.arms + 1] = a
            statement_list(c, a.stmts, nil, true)
            ci = ci + 1
          end
        end
        pop_scope()
      end
      body.metrics.branches = body.metrics.branches + math.max(ci - 1, 0)
    end
  end

  -- Visit a list of statements (the named children of `container`, or the single `only`),
  -- recording a statement tree into `into`.
  function statement_list(container, into, only, shared)
    local items = {}
    if only then
      items = { only }
    else
      for c in container:iter_children() do
        if c:named() then
          items[#items + 1] = c
        end
      end
      if not shared then
        push_scope()
      end
    end
    local prev_end, comment, comment_start = nil, false, nil
    if container then
      local sr = range(container).start[1]
      prev_end = sr
      if container:type() == "switch_block_statement_group" then
        prev_end = nil
      end
    end
    for _, c in ipairs(items) do
      local t = c:type()
      if is_comment(c) then
        if not comment then
          comment_start = range(c).start
        end
        comment = true
        prev_end = range(c)["end"][1]
      elseif t == "switch_label" then
        switch_label(c, container)
        prev_end = range(c)["end"][1]
      elseif is_statement(c) then
        local r = range(c)
        local rec = {
          kind = t,
          range = r,
          sites = {},
          field_writes = {},
          arms = {},
          blank_before = prev_end ~= nil and blank_between(prev_end, r.start[1]) or false,
          comment_before = comment,
          comment_start = comment and comment_start or nil,
        }
        comment, comment_start = false, nil
        local cond = field(c, "condition")
        if cond and (t == "if_statement" or t == "while_statement" or t == "do_statement"
            or t == "switch_statement" or t == "switch_expression") then
          rec.condition = vim.trim(ctx.text(cond):gsub("%s+", " "):gsub("^%((.*)%)$", "%1"))
        end
        if t == "if_statement" then
          rec.guard = field(c, "alternative") == nil and only_terminal(field(c, "consequence"))
          body.metrics.branches = body.metrics.branches + 1
        elseif loops[t] then
          body.metrics.loops = body.metrics.loops + 1
        elseif t == "throw_statement" then
          body.metrics.throws = body.metrics.throws + 1
        end
        rec.terminal = terminal[t] or nil
        body.metrics.statements = body.metrics.statements + 1
        into[#into + 1] = rec
        stmt_stack[#stmt_stack + 1] = rec
        local before_locals = #body.locals
        if compound[t] or t == "labeled_statement" then
          arms_of(c, rec)
        elseif t == "block" then
          local a = { name = "block", range = r, stmts = {} }
          rec.arms[1] = a
          statement_list(c, a.stmts)
        elseif t == "local_variable_declaration" then
          local_declaration(c, enclosing_block(c))
        elseif t == "class_declaration" or t == "record_declaration" or t == "interface_declaration"
            or t == "enum_declaration" or t == "local_class_declaration" then
          class_members(c, {})
        elseif t == "explicit_constructor_invocation" then
          visit(c)
        else
          visit_children(c)
          -- the shape of a return value or an expression statement (trivial targets, §8.2)
          local expr = (t == "return_statement" or t == "expression_statement") and c:named_child(0)
          if expr and is_comment(expr) then
            expr = nil
          end
          if expr then
            local et = expr:type()
            if et == "assignment_expression" then
              local w = field_write(field(expr, "left"))
              rec.value = { k = "assign", field = w ~= nil or nil, value = describe(field(expr, "right")) }
            elseif et == "update_expression" then
              rec.value = { k = "update" }
            else
              rec.value = describe(expr)
            end
          end
        end
        if #body.locals > before_locals then
          rec.locals = {}
          for i = before_locals + 1, #body.locals do
            if body.locals[i].kind == "local" then
              rec.locals[#rec.locals + 1] = body.locals[i].name
            end
          end
        end
        stmt_stack[#stmt_stack] = nil
        prev_end = r["end"][1]
      else
        visit(c) -- an expression (switch rule body, enum argument, initializer)
      end
    end
    if not only and not shared then
      pop_scope()
    end
  end

  -- Walk one remembered body. Called for each pending item, and in place for the members
  -- of a local or anonymous class (then `scopes` still holds the enclosing names).
  local function process(item)
    local saved = { body, owner, stmt_stack, lambda_stack }
    body = facts.bodies[item.id] or new_body(item.id)
    owner, stmt_stack, lambda_stack = item.owner, {}, {}
    item.done = true
    if item.method then
      local method = facts.symbols[item.id]
      local r = range(item.method)
      body.metrics.lines = r["end"][1] - r.start[1] + 1
      push_scope()
      local params = item.method:type() ~= "compact_constructor_declaration" and field(item.method, "parameters")
      if params then
        local i = 0
        for c in params:iter_children() do
          if c:type() == "formal_parameter" or c:type() == "spread_parameter" then
            i = i + 1
            local name = field(c, "name")
            if not name then
              local decl = child_of_type(c, "variable_declarator")
              name = decl and field(decl, "name")
            end
            if name then
              local pty = method.params[i].type
              if method.params[i].varargs and pty then
                pty = { name = pty.name .. "[]", spelled = pty.spelled .. "[]", array = true, element = pty }
              end
              declare(name, pty, "param", item.node, { param = i })
            end
          end
        end
      else
        for i, p in ipairs(method.params) do
          body.locals[#body.locals + 1] = { name = p.name, type = p.type and p.type.name, spelled = p.type
            and p.type.spelled, kind = "param", param = i, declared_at = range(item.node).start,
            scope = range(item.node), definitions = {}, uses = {}, index = #body.locals + 1, body = body.symbol }
          scopes[#scopes][p.name] = body.locals[#body.locals]
        end
      end
    else
      push_scope()
    end

    if item.initializer and not is_statement(item.node) and item.node:type() ~= "static_initializer" then
      local ids = sites_in(function()
        visit(item.node)
      end)
      if item.field then
        body.inits = body.inits or {}
        body.inits[item.field] = describe(item.node)
      end
      for _, id in ipairs(ids) do
        body.sites[tonumber(id:sub(2))].initializer = true
      end
    elseif item.node:type() == "static_initializer" then
      local b = child_of_type(item.node, "block")
      if b then
        statement_list(b, body.stmts)
      end
    else
      statement_list(item.node, body.stmts)
    end
    pop_scope()
    body.metrics.sites = #body.sites
    body.metrics.field_writes = #body.field_writes
    body, owner, stmt_stack, lambda_stack = saved[1], saved[2], saved[3], saved[4]
  end
  run_inline = function(first)
    for i = first, #pending do
      if not pending[i].done then
        process(pending[i])
      end
    end
  end

  for _, item in ipairs(pending) do
    if not item.done then
      scopes = {}
      process(item)
    end
  end
  for _, use in ipairs(pending_uses) do
    local s = site_of_node[use.call_node]
    use.site = s and s.id or nil
    use.call_node = nil
  end
  for _, entry in ipairs(pending_calls) do
    local s = site_of_node[entry.ref.call_node]
    entry.ref.call = s and s.id or nil
    entry.ref.call_node = nil
  end
  return facts
end

-- Both passes over a source string. Returns pure-data FileFacts with `bodies` filled.
function M.extract(file, src)
  local parser = vim.treesitter.get_string_parser(src, M.parser)
  local root = parser:parse()[1]:root()
  local facts, pending = M.declarations(file, root, src)
  return M.bodies(file, src, facts, pending)
end

return M
