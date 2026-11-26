-- TypeScript and JavaScript Tree-sitter backend. One backend serves both, because a
-- project imports across them. Symbols are scoped by module (the path) and lexical owner;
-- imports are resolved to module names while extracting. `.ts` files use the typescript
-- grammar, everything else the tsx grammar (a superset of JavaScript and JSX).
local M = { name = "typescript", parser = "typescript", version = 4,
  extensions = { ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs" } }

local function set(items)
  local out = {}
  for _, name in ipairs(items) do
    out[name] = true
  end
  return out
end

function M.parser_for(file)
  return (file:match("%.[mc]?ts$")) and "typescript" or "tsx"
end

M.types = {
  type = { "class_declaration", "abstract_class_declaration", "interface_declaration" },
  method = { "function_declaration", "generator_function_declaration", "method_definition", "arrow_function",
    "function_expression" },
  import = { "import_statement" },
  call = { "call_expression", "new_expression" },
  statement = { "expression_statement", "lexical_declaration", "variable_declaration", "return_statement",
    "throw_statement", "break_statement", "continue_statement" },
  compound = { "if_statement", "for_statement", "for_in_statement", "while_statement", "do_statement",
    "try_statement", "switch_statement" },
}
M.builtins = set({ "Array", "ArrayBuffer", "BigInt", "Boolean", "Buffer", "Date", "Error", "Function", "JSON", "Map",
  "Math", "Number", "Object", "Promise", "Proxy", "Reflect", "RegExp", "Set", "String", "Symbol", "TypeError",
  "RangeError", "URL", "URLSearchParams", "WeakMap", "WeakSet", "AbortController", "console", "process",
  "document", "window", "globalThis", "fetch", "setTimeout", "setInterval", "setImmediate", "clearTimeout",
  "clearInterval", "queueMicrotask", "structuredClone", "parseInt", "parseFloat", "isNaN", "isFinite",
  "encodeURIComponent", "decodeURIComponent", "require",
  "string", "number", "boolean", "bigint", "symbol", "void", "never", "unknown", "any", "object", "undefined",
  "null", "Record", "Partial", "Readonly", "Required", "Pick", "Omit" })
M.sinks = { "axios#get", "axios#post", "axios#put", "axios#patch", "axios#delete", "fs#writeFile",
  "fs#writeFileSync", "fs#appendFile", "fs/promises#writeFile", "node:fs#writeFile", "node:fs#writeFileSync",
  "node:fs/promises#writeFile" }
M.handoffs = { "worker_threads#Worker", "node:worker_threads#Worker", "child_process#spawn",
  "node:child_process#spawn" }

local suffixes = { "%.[mc]?[tj]s$", "%.[tj]sx$" }

local function strip_extension(path)
  for _, suffix in ipairs(suffixes) do
    local out, n = path:gsub(suffix, "")
    if n > 0 then
      return out
    end
  end
  return path
end

function M.module_name(file)
  local module = strip_extension(file):gsub("/index$", ""):gsub("/", ".")
  return module
end

-- Path aliases of the nearest tsconfig.json / jsconfig.json, read from the working directory
-- of the index. Set by the index before extraction (see `configure`).
local aliases = {}

local function strip_json_comments(raw)
  local out, i, n, quoted = {}, 1, #raw, false
  while i <= n do
    local c, two = raw:sub(i, i), raw:sub(i, i + 1)
    if quoted then
      if c == "\\" then
        out[#out + 1] = two
        i = i + 2
      else
        quoted = c ~= '"'
        out[#out + 1] = c
        i = i + 1
      end
    elseif two == "//" then
      i = raw:find("\n", i, true) or n + 1
    elseif two == "/*" then
      local close = raw:find("*/", i + 2, true)
      i = close and close + 2 or n + 1
    else
      quoted = c == '"'
      out[#out + 1] = c
      i = i + 1
    end
  end
  return (table.concat(out):gsub(",(%s*[}%]])", "%1"))
end

-- `compilerOptions.paths` and `baseUrl` of the project root's config.
function M.configure(root)
  aliases = { paths = {}, digest = "" }
  for _, name in ipairs({ "tsconfig.json", "tsconfig.base.json", "jsconfig.json" }) do
    local fd = io.open(root .. "/" .. name, "r")
    if fd then
      local raw = fd:read("*a")
      fd:close()
      local ok, config = pcall(vim.json.decode, strip_json_comments(raw), { luanil = { object = true, array = true } })
      local options = ok and type(config) == "table" and config.compilerOptions
      if options and (options.paths or options.baseUrl) then
        local base = vim.fs.normalize(options.baseUrl or "."):gsub("^%./", "")
        base = base == "." and "" or (base:gsub("/$", "") .. "/")
        aliases.base = options.baseUrl and base or nil
        for pattern, targets in pairs(options.paths or {}) do
          local target = type(targets) == "table" and targets[1]
          if target then
            aliases.paths[#aliases.paths + 1] = { pattern = pattern, target = base .. target:gsub("^%./", "") }
          end
        end
        table.sort(aliases.paths, function(a, b) return #a.pattern > #b.pattern end)
        aliases.digest = vim.fn.sha256(raw)
        return
      end
    end
  end
end

-- Symbol IDs and relative imports depend on the path (and path aliases) as well as the source.
function M.cache_identity(file)
  return file .. "\0" .. (aliases.digest or "")
end

-- An import specifier as a module name; a package outside the project is marked with `~`.
local function specifier(file, spec)
  local target
  if spec:match("^%.%.?/") or spec == "." or spec == ".." then
    local dir = file:match("^(.*)/[^/]*$") or ""
    local parts = vim.split(dir, "/", { plain = true, trimempty = true })
    for _, part in ipairs(vim.split(spec, "/", { plain = true, trimempty = true })) do
      if part == ".." then
        table.remove(parts)
      elseif part ~= "." then
        parts[#parts + 1] = part
      end
    end
    target = table.concat(parts, "/")
    if target == "" then
      target = "index"
    end
  else
    for _, alias in ipairs(aliases.paths or {}) do
      local prefix, suffix = alias.pattern:match("^(.-)%*(.*)$")
      if prefix then
        if spec:sub(1, #prefix) == prefix and (suffix == "" or spec:sub(-#suffix) == suffix) then
          local star = spec:sub(#prefix + 1, #spec - #suffix)
          target = alias.target:gsub("%*", function() return star end)
          break
        end
      elseif spec == alias.pattern then
        target = alias.target
        break
      end
    end
    if not target and aliases.base and not spec:match("^@") then
      local candidate = aliases.base .. spec
      for _, ext in ipairs(M.extensions) do
        if vim.uv.fs_stat(aliases.root .. "/" .. candidate .. ext)
            or vim.uv.fs_stat(aliases.root .. "/" .. candidate .. "/index" .. ext) then
          target = candidate
          break
        end
      end
    end
    if not target then
      return "~" .. spec, true
    end
  end
  return M.module_name(target)
end

local configure = M.configure
function M.configure(root)
  configure(root)
  aliases.root = root
end

local function field(node, name)
  return node and node:field(name)[1]
end

local function children(node, kind)
  local out = {}
  if node then
    for child in node:iter_children() do
      if child:named() and (not kind or child:type() == kind) then
        out[#out + 1] = child
      end
    end
  end
  return out
end

-- an unnamed child such as `static`, `abstract`, `default` or `*`
local function token(node, kind)
  if node then
    for child in node:iter_children() do
      if child:type() == kind then
        return true
      end
    end
  end
  return false
end

local function range(node)
  local sr, sc, er, ec = node:range()
  return { start = { sr, sc }, ["end"] = { er, ec } }
end

local function text(node, src)
  return node and vim.treesitter.get_node_text(node, src) or ""
end

local function unquote(s)
  return (s:gsub("^['\"`]", ""):gsub("['\"`]$", ""))
end

-- A type annotation reduced to one named type: generics are dropped, `T | null` is T,
-- `Promise<T>` is T (values are awaited), arrays are Array.
local function type_ref(node, src)
  if not node then
    return
  end
  local kind = node:type()
  if kind == "type_annotation" or kind == "parenthesized_type" or kind == "readonly_type" then
    return type_ref(node:named_child(0), src)
  elseif kind == "type_identifier" or kind == "identifier" or kind == "nested_type_identifier"
      or kind == "member_expression" or kind == "predefined_type" then
    local name = text(node, src)
    if name:match("^[%w_$.]+$") then
      return { name = name, spelled = name }
    end
  elseif kind == "lookup_type" then
    local owner = type_ref(node:named_child(0), src)
    local key = unquote(text(node:named_child(1), src))
    if owner and key:match("^[%w_$]+$") then
      return { name = owner.name .. "@" .. key, spelled = owner.spelled .. "@" .. key }
    end
  elseif kind == "generic_type" then
    local name = field(node, "name")
    if text(name, src) == "Promise" then
      return type_ref(children(field(node, "type_arguments"))[1], src)
    end
    return type_ref(name, src)
  elseif kind == "array_type" or kind == "tuple_type" then
    return { name = "Array", spelled = "Array" }
  elseif kind == "union_type" then
    local found
    for _, part in ipairs(children(node)) do
      local t = text(part, src)
      if t ~= "null" and t ~= "undefined" then
        if found then
          return
        end
        found = part
      end
    end
    return type_ref(found, src)
  end
end

local function is_function(node)
  local kind = node and node:type()
  return kind == "arrow_function" or kind == "function_expression" or kind == "function"
    or kind == "generator_function"
end

local function unwrap(node)
  while node do
    local kind = node:type()
    if kind == "parenthesized_expression" or kind == "await_expression" or kind == "as_expression"
        or kind == "non_null_expression" or kind == "satisfies_expression" or kind == "type_assertion" then
      node = node:named_child(kind == "type_assertion" and 1 or 0)
    else
      return node
    end
  end
end

-- `require("x")` -> "x"
local function required(node, src)
  node = unwrap(node)
  if node and node:type() == "call_expression" and text(field(node, "function"), src) == "require" then
    local arg = children(field(node, "arguments"))[1]
    if arg and arg:type() == "string" then
      return unquote(text(arg, src))
    end
  end
end

local function member_path(module, external, name)
  -- the default or namespace binding of a package is the package itself
  if external and name == "default" then
    return module
  end
  -- `#` keeps a module's member apart from a module of the same dotted name
  return module .. (external and "." or "#") .. name
end

-- The names an import_statement or a `require` declarator binds: { name, path, bound, range }
local function imports(node, file, src)
  local out = {}
  local function push(name, module, bound)
    out[#out + 1] = { name = name, path = bound or module, bound = bound or module, range = range(node) }
  end
  if node:type() == "import_statement" then
    local source = field(node, "source")
    local required_clause = children(node, "import_require_clause")[1]
    if required_clause then
      local module = specifier(file, unquote(text(field(required_clause, "source"), src)))
      push(text(children(required_clause, "identifier")[1], src), module, module .. "#default")
      return out
    end
    if not source then
      return out
    end
    local module, external = specifier(file, unquote(text(source, src)))
    local clause = children(node, "import_clause")[1]
    for _, part in ipairs(children(clause)) do
      if part:type() == "identifier" then
        push(text(part, src), module, member_path(module, external, "default"))
      elseif part:type() == "namespace_import" then
        push(text(part:named_child(0), src), module)
      elseif part:type() == "named_imports" then
        for _, item in ipairs(children(part, "import_specifier")) do
          local name = text(field(item, "name"), src)
          local alias = field(item, "alias")
          push(alias and text(alias, src) or name, module, member_path(module, external, name))
        end
      end
    end
    if #out == 0 then
      out[1] = { path = module, range = range(node) } -- `import "./side-effect"`
    end
    return out
  end
  -- const x = require("m"), const { a, b: c } = require("m"), const x = require("m").y
  local value = unwrap(field(node, "value"))
  local suffix
  if value and value:type() == "member_expression" then
    suffix = text(field(value, "property"), src)
    value = field(value, "object")
  end
  local spec = required(value, src)
  local target = field(node, "name")
  if not spec or not target then
    return out
  end
  local module, external = specifier(file, spec)
  local base = suffix and member_path(module, external, suffix) or module
  local function of(key)
    return suffix and (base .. "." .. key) or member_path(module, external, key)
  end
  if target:type() == "identifier" then
    -- `require` of a module that assigns `module.exports` is that value, as a default import is
    push(text(target, src), module, suffix and base or member_path(module, external, "default"))
  elseif target:type() == "object_pattern" then
    for _, item in ipairs(children(target)) do
      if item:type() == "shorthand_property_identifier_pattern" then
        push(text(item, src), module, of(text(item, src)))
      elseif item:type() == "pair_pattern" then
        push(text(field(item, "value"), src), module, of(text(field(item, "key"), src)))
      end
    end
  end
  return out
end

-- The names a destructuring pattern binds, with the property each one reads.
local function pattern_bindings(pattern, annotation, src)
  local out = {}
  local ty = annotation and annotation:named_child(0)
  local members = {}
  if ty and ty:type() == "object_type" then
    for _, member in ipairs(children(ty, "property_signature")) do
      members[text(field(member, "name"), src)] = type_ref(field(member, "type"), src)
    end
  end
  local named = ty and ty:type() ~= "object_type" and type_ref(ty, src)
  local function add(node, key)
    local name = text(node, src)
    out[#out + 1] = { name = name, range = range(node), type = key and members[key],
      member_of = key and named and { type = named.spelled, key = key } or nil }
  end
  local function walk(node, top)
    local kind = node:type()
    if kind == "identifier" or kind == "shorthand_property_identifier_pattern" then
      add(node, top and kind ~= "identifier" and text(node, src) or nil)
    elseif kind == "pair_pattern" then
      local value = field(node, "value")
      if value and value:type() == "identifier" then
        add(value, top and text(field(node, "key"), src) or nil)
      elseif value then
        walk(value)
      end
    elseif kind == "object_assignment_pattern" then
      walk(field(node, "left"), top)
    elseif kind == "assignment_pattern" then
      walk(field(node, "left"))
    elseif kind == "object_pattern" or kind == "array_pattern" or kind == "rest_pattern" then
      for _, child in ipairs(children(node)) do
        walk(child, top and kind == "object_pattern")
      end
    end
  end
  walk(pattern, true)
  return out
end

local function parameters(node, src)
  local out = {}
  if not node then
    return out
  end
  if node:type() == "identifier" then -- x => …
    return { { name = text(node, src), range = range(node) } }
  end
  for _, param in ipairs(children(node)) do
    local kind = param:type()
    if kind ~= "comment" then
      local pattern = field(param, "pattern") or (kind == "assignment_pattern" and field(param, "left")) or param
      local splat
      if pattern:type() == "rest_pattern" then
        splat, pattern = "list", pattern:named_child(0)
      end
      local name = pattern:type() == "identifier" and text(pattern, src) or nil
      if pattern:type() ~= "this" then
        local property = children(param, "accessibility_modifier")[1] ~= nil or token(param, "readonly")
        out[#out + 1] = { name = name or ("$" .. (#out + 1)), type = type_ref(field(param, "type"), src),
          bindings = not name and pattern_bindings(pattern, field(param, "type"), src) or nil,
          range = range(pattern), splat = splat, property = property or nil,
          optional = (kind == "optional_parameter" or kind == "assignment_pattern" or field(param, "value") ~= nil)
            or nil }
      end
    end
  end
  return out
end

local function decorator_names(nodes, src)
  local annotations = {}
  for _, decorator in ipairs(nodes) do
    local expression = decorator:named_child(0)
    local name = text(field(expression, "function") or expression, src)
    if name ~= "" then
      annotations[#annotations + 1] = name
    end
  end
  return annotations
end

local entry_annotations = set({ "Get", "Post", "Put", "Patch", "Delete", "MessagePattern", "EventPattern", "Cron" })
local route_methods = set({ "get", "post", "put", "patch", "delete", "use", "all" })
local route_owners = set({ "app", "router", "server", "fastify" })

function M.declarations(file, root, src)
  local module = M.module_name(file)
  local facts = { file = file, lang = M.name, module = module, package = module, names = {}, types = {},
    type_order = {}, bodies = {}, symbols = {}, imports = { single = {}, wildcard = {}, list = {} },
    bindings = {}, vars = {}, globals = {}, error = root:has_error() }
  local file_id = "file:" .. file
  facts.symbols[file_id] = { id = file_id, kind = "file", label = vim.fs.basename(file), file = file,
    range = range(root), source = "ast", bindings = facts.bindings }
  local pending, routed, exported = {}, {}, {}
  local own = {} -- nodes that are symbols of their own, by node id

  local function add(sym, scope)
    sym.file, sym.source = file, "ast"
    facts.symbols[sym.id] = sym
    facts.names[sym.name] = facts.names[sym.name] or {}
    if not vim.tbl_contains(facts.names[sym.name], sym.id) then
      table.insert(facts.names[sym.name], sym.id)
    end
    local bindings = scope and scope.bindings or facts.bindings
    bindings[sym.name] = sym.id
  end

  local function add_import(import, name_only)
    if import.name then
      facts.imports.single[import.name] = import.bound
    end
    if not name_only then
      facts.imports.list[#facts.imports.list + 1] = import
    end
  end

  local walk, declare_function, declare_type, declare_object

  local function signature(node, body)
    local _, _, start_byte = node:start()
    local _, _, body_byte = (body or node):start()
    local head = src:sub(start_byte + 1, body and body_byte or select(3, node:end_()))
    return vim.trim(head:gsub("%s+", " "):gsub("%s*=>%s*$", ""))
  end

  -- `fn` is the node with parameters and body; `outer` the whole declaration
  function declare_function(name, fn, outer, scope, extra)
    local in_type = scope and scope.methods ~= nil
    local constructor = in_type and name == "constructor"
    local qname = (scope and scope.qname or module) .. "." .. name
    local body = field(fn, "body")
    local ret = type_ref(field(fn, "return_type"), src)
    local sym = { id = "typescript:" .. qname, kind = constructor and "constructor" or "method", name = name,
      qname = qname, label = scope and (scope.name .. "." .. name) or name, owner = scope and scope.id or file_id,
      range = range(outer), error = outer:has_error(), annotations = {}, modifiers = {}, bindings = {},
      params = parameters(field(fn, "parameters") or field(fn, "parameter"), src),
      returns_spelled = ret and ret.spelled, returns = ret and ret.name, static = false,
      signature = signature(outer, body) }
    for key, value in pairs(extra or {}) do
      sym[key] = value
    end
    sym.modifiers.public = sym.modifiers.public ~= false and name:sub(1, 1) ~= "#" and name:sub(1, 1) ~= "_"
    for _, annotation in ipairs(sym.annotations) do
      if entry_annotations[annotation:match("[^.]+$")] then
        sym.entry = true
      end
    end
    local existed = facts.symbols[sym.id] ~= nil
    add(sym, scope)
    own[fn:id()] = true
    if in_type and not existed then
      scope.methods[#scope.methods + 1] = sym.id
    end
    if body then
      pending[sym.id] = { node = outer, body = body, fn = fn:id() }
      if body:type() == "statement_block" then
        walk(body, sym)
      end
    end
    return sym
  end

  local function add_field(owner, name, node, ty, static)
    local id = owner.id .. "#" .. name
    owner.fields[name] = id
    local existing = facts.symbols[id]
    facts.symbols[id] = { id = id, kind = "field", name = name, label = owner.name .. "." .. name, file = file,
      owner = owner.id, range = range(node), source = "ast", static = static or nil,
      type = ty or (existing and existing.type) }
  end

  local function new_type(name, kind, node, scope)
    local qname = (scope and scope.qname or module) .. "." .. name
    local sym = { id = "typescript:" .. qname, kind = kind, name = name, qname = qname,
      label = scope and (scope.name .. "." .. name) or name, owner = scope and scope.id or file_id,
      outer = scope and scope.id or nil, range = range(node), error = node:has_error(), annotations = {},
      modifiers = { public = true }, bindings = {}, extends = {}, implements = {}, methods = {}, fields = {},
      nested = {}, type_params = {}, components = {} }
    local existed = facts.symbols[sym.id] ~= nil
    add(sym, scope)
    facts.types[qname] = sym.id
    if not existed then
      facts.type_order[#facts.type_order + 1] = sym.id
    end
    if scope and scope.nested then
      scope.nested[name] = sym.id
    end
    return sym
  end

  local function bases(list, node)
    local ref = type_ref(node, src)
    if ref then
      list[#list + 1] = ref
    end
  end

  function declare_type(name, node, scope, decorators)
    local alias = node:type() == "type_alias_declaration"
    local interface = alias or node:type() == "interface_declaration"
    local sym = new_type(name, interface and "interface" or "class", node, scope)
    own[node:id()] = true
    sym.annotations = decorator_names(vim.list_extend(vim.list_extend({}, decorators or {}),
      children(node, "decorator")), src)
    sym.abstract = interface or node:type() == "abstract_class_declaration" or nil
    for _, param in ipairs(children(field(node, "type_parameters"), "type_parameter")) do
      sym.type_params[#sym.type_params + 1] = text(field(param, "name"), src)
    end
    for _, child in ipairs(children(node)) do
      local kind = child:type()
      if kind == "class_heritage" then
        for _, clause in ipairs(children(child)) do
          if clause:type() == "extends_clause" then
            bases(sym.extends, field(clause, "value"))
          elseif clause:type() == "implements_clause" then
            for _, base in ipairs(children(clause)) do
              bases(sym.implements, base)
            end
          else
            bases(sym.extends, clause) -- the JavaScript shape: the expression itself
          end
        end
      elseif kind == "extends_type_clause" then
        for _, base in ipairs(children(child)) do
          bases(sym.extends, base)
        end
      end
    end
    local pending_decorators = {}
    for _, member in ipairs(children(field(node, alias and "value" or "body"))) do
      local kind = member:type()
      local static = token(member, "static") or nil
      local member_name = field(member, "name") or field(member, "property")
      local n = member_name and text(member_name, src)
      if kind == "decorator" then
        pending_decorators[#pending_decorators + 1] = member
      else
        local annotations = decorator_names(vim.list_extend(vim.list_extend({}, pending_decorators),
          children(member, "decorator")), src)
        pending_decorators = {}
        local access = text(children(member, "accessibility_modifier")[1], src)
        local extra = { static = static or false, annotations = annotations,
          modifiers = { public = access ~= "private" and access ~= "protected" } }
        if n and (kind == "method_definition" or kind == "method_signature" or kind == "abstract_method_signature") then
          if kind ~= "method_definition" then
            extra.abstract = true
          end
          local method = declare_function(n, member, member, sym, extra)
          if method.kind == "constructor" then
            for _, p in ipairs(method.params) do
              if p.property then
                add_field(sym, p.name, member, p.type)
              end
            end
          end
        elseif n and (kind == "public_field_definition" or kind == "field_definition") then
          local value = field(member, "value")
          if is_function(value) then
            declare_function(n, value, member, sym, extra)
          else
            local ty = type_ref(field(member, "type"), src)
            local built = unwrap(value)
            if not ty and built and built:type() == "new_expression" then
              ty = type_ref(field(built, "constructor"), src)
            end
            add_field(sym, n, member, ty, static)
          end
        elseif n and kind == "property_signature" then
          add_field(sym, n, member, type_ref(field(member, "type"), src))
        end
      end
    end
    return sym
  end

  -- An object literal with function members is a namespace of methods (`const api = { get() {} }`).
  function declare_object(name, object, outer, scope)
    local members = {}
    for _, member in ipairs(children(object)) do
      if member:type() == "method_definition" then
        members[#members + 1] = { text(field(member, "name"), src), member, member }
      elseif member:type() == "pair" and is_function(field(member, "value")) then
        members[#members + 1] = { unquote(text(field(member, "key"), src)), field(member, "value"), member }
      end
    end
    local shorthand = children(object, "shorthand_property_identifier")
    if #members == 0 and #shorthand == 0 then
      return
    end
    local sym = new_type(name, "class", outer, scope)
    sym.object = true
    own[object:id()] = true
    for _, member in ipairs(members) do
      declare_function(member[1], member[2], member[3], sym, { static = true })
    end
    for _, item in ipairs(shorthand) do
      local n = text(item, src)
      sym.aliases = sym.aliases or {}
      sym.aliases[n] = n
    end
    return sym
  end

  local function declare_variables(node, scope)
    for _, declarator in ipairs(children(node, "variable_declarator")) do
      local target, value = field(declarator, "name"), field(declarator, "value")
      local found = imports(declarator, file, src)
      if #found > 0 then
        if not scope then
          for _, import in ipairs(found) do
            add_import(import)
          end
        end
      elseif target and target:type() == "identifier" and value then
        local name = text(target, src)
        if is_function(value) then
          declare_function(name, value, node, scope)
        elseif not scope then
          local inner = unwrap(value)
          local ty = type_ref(field(declarator, "type"), src)
          if not ty and inner and inner:type() == "new_expression" then
            ty = type_ref(field(inner, "constructor"), src)
          end
          facts.vars[name] = ty and ty.spelled or nil
          if inner and inner:type() == "object" then
            declare_object(name, inner, node, scope)
          elseif inner and inner:type() == "class" then
            declare_type(name, inner, scope)
          end
        end
      end
    end
  end

  -- `module.exports = …` and `exports.name = …`
  local function commonjs(node)
    local left, right = field(node, "left"), field(node, "right")
    local target = text(left, src)
    local name = target:match("^module%.exports%.([%w_$]+)$") or target:match("^exports%.([%w_$]+)$")
    if name then
      if is_function(right) then
        declare_function(name, right, node, nil)
      elseif right:type() == "identifier" then
        exported[#exported + 1] = { name, text(right, src) }
      end
    elseif target == "module.exports" then
      if right:type() == "identifier" then
        exported[#exported + 1] = { "default", text(right, src) }
        exported.commonjs = text(right, src)
      elseif is_function(right) then
        declare_function("default", right, node, nil)
      elseif right:type() == "object" then
        for _, item in ipairs(children(right)) do
          if item:type() == "pair" then
            local key, value = unquote(text(field(item, "key"), src)), field(item, "value")
            if is_function(value) then
              declare_function(key, value, item, nil)
            elseif value:type() == "identifier" then
              exported[#exported + 1] = { key, text(value, src) }
            end
          elseif item:type() == "method_definition" then
            declare_function(text(field(item, "name"), src), item, item, nil)
          end
        end
      elseif right:type() == "class" then
        declare_type("default", right, nil)
      end
    end
  end

  -- `app.get("/path", handler)` marks the handler as an entry
  local function route_registration(node)
    local callee = field(node, "function")
    if callee and callee:type() == "member_expression" and route_owners[text(field(callee, "object"), src)]
        and route_methods[text(field(callee, "property"), src)] then
      local args = children(field(node, "arguments"))
      if #args >= 2 and args[1]:type() == "string" then
        for i = 2, #args do
          if args[i]:type() == "identifier" then
            routed[#routed + 1] = text(args[i], src)
          end
        end
      end
    end
  end

  local function export(node, scope)
    local declaration = field(node, "declaration")
    local source = field(node, "source")
    local default = token(node, "default")
    if source then
      local module_path, external = specifier(file, unquote(text(source, src)))
      local clause = children(node, "export_clause")[1]
      local namespace = children(node, "namespace_export")[1]
      if clause then
        for _, item in ipairs(children(clause, "export_specifier")) do
          local name = text(field(item, "name"), src)
          local alias = field(item, "alias")
          add_import({ name = alias and text(alias, src) or name, bound = member_path(module_path, external, name),
            path = module_path, range = range(node) })
        end
      elseif namespace then
        add_import({ name = text(namespace:named_child(0), src), bound = module_path, path = module_path,
          range = range(node) })
      else
        table.insert(facts.imports.wildcard, module_path)
        facts.imports.list[#facts.imports.list + 1] = { path = module_path, wildcard = true, range = range(node) }
      end
      return
    end
    if declaration then
      local found = walk(node, scope, declaration, children(node, "decorator"))
      if default and found then
        exported[#exported + 1] = { "default", found.name }
      end
      return
    end
    local value = field(node, "value")
    if value then -- export default <expression>
      if value:type() == "identifier" then
        exported[#exported + 1] = { "default", text(value, src) }
      elseif is_function(value) then
        declare_function("default", value, node, scope)
      elseif value:type() == "object" then
        declare_object("default", value, node, scope)
      elseif value:type() == "class" then
        declare_type("default", value, scope)
      end
      return
    end
    for _, item in ipairs(children(children(node, "export_clause")[1], "export_specifier")) do
      local alias = field(item, "alias")
      if alias then
        exported[#exported + 1] = { text(alias, src), text(field(item, "name"), src) }
      end
    end
  end

  -- Declarations in `container`; `only` restricts to one node (an exported declaration).
  function walk(container, scope, only, decorators)
    local found
    for _, node in ipairs(only and { only } or children(container)) do
      local kind = node:type()
      if kind == "export_statement" then
        export(node, scope)
      elseif kind == "import_statement" then
        for _, import in ipairs(imports(node, file, src)) do
          add_import(import)
        end
      elseif kind == "function_declaration" or kind == "generator_function_declaration"
          or kind == "function_expression" then
        local name = field(node, "name")
        found = declare_function(name and text(name, src) or "default", node, node, scope)
      elseif kind == "class_declaration" or kind == "abstract_class_declaration" or kind == "class"
          or kind == "interface_declaration" then
        local name = field(node, "name")
        found = declare_type(name and text(name, src) or "default", node, scope, decorators)
      elseif kind == "type_alias_declaration" then
        local value = field(node, "value")
        if value and value:type() == "object_type" and not scope then
          found = declare_type(text(field(node, "name"), src), node, scope)
        end
      elseif kind == "lexical_declaration" or kind == "variable_declaration" then
        declare_variables(node, scope)
      elseif kind == "expression_statement" and not scope then
        local expression = node:named_child(0)
        if expression and expression:type() == "assignment_expression" then
          commonjs(expression)
        elseif expression and expression:type() == "call_expression" then
          route_registration(expression)
        end
      elseif kind == "statement_block" or kind == "if_statement" or kind == "else_clause"
          or kind == "try_statement" then
        if scope then
          walk(node, scope)
        end
      end
    end
    return found
  end

  walk(root)

  -- A file with no import or export is a script: its top-level names are global. Any file
  -- may also publish names with `globalThis.X = …` or `Object.assign(globalThis, { X })`.
  local globals = { globalThis = true, window = true, self = true }
  facts.script = true
  for _, node in ipairs(children(root)) do
    local kind = node:type()
    if kind == "import_statement" or kind == "export_statement" then
      facts.script = nil
    end
    local expression = kind == "expression_statement" and node:named_child(0)
    if expression and expression:type() == "assignment_expression" then
      local left, right = field(expression, "left"), field(expression, "right")
      local owner = text(field(left, "object"), src)
      if owner == "module" or owner == "exports" or text(left, src):match("^module%.exports") then
        facts.script = nil
      elseif globals[owner] and right:type() == "identifier" then
        facts.globals[text(field(left, "property"), src)] = text(right, src)
      elseif globals[owner] and right:type() == "new_expression" then
        local name, ty = text(field(left, "property"), src), type_ref(field(right, "constructor"), src)
        facts.globals[name], facts.vars[name] = name, ty and ty.spelled
      end
    elseif expression and expression:type() == "call_expression"
        and text(field(expression, "function"), src) == "Object.assign" then
      local args = children(field(expression, "arguments"))
      if args[1] and globals[text(args[1], src)] and args[2] and args[2]:type() == "object" then
        for _, item in ipairs(children(args[2])) do
          if item:type() == "shorthand_property_identifier" then
            facts.globals[text(item, src)] = text(item, src)
          elseif item:type() == "pair" and field(item, "value"):type() == "identifier" then
            facts.globals[unquote(text(field(item, "key"), src))] = text(field(item, "value"), src)
          end
        end
      end
    end
  end

  for _, pair in ipairs(exported) do
    local id = facts.bindings[pair[2]]
    if id then
      facts.bindings[pair[1]] = facts.bindings[pair[1]] or id
    elseif facts.imports.single[pair[2]] then
      facts.imports.single[pair[1]] = facts.imports.single[pair[1]] or facts.imports.single[pair[2]]
    end
  end
  for _, name in ipairs(routed) do
    local sym = facts.symbols[facts.bindings[name]]
    if sym then
      sym.entry = true
    end
  end

  -- Top-level calls are the script's own flow (`main()`, server start-up).
  for _, node in ipairs(children(root)) do
    local expression = node:type() == "expression_statement" and unwrap(node:named_child(0))
    if expression and expression:type() == "call_expression" and not required(expression, src) then
      local sym = { id = "typescript:" .. module .. ".$main", kind = "method", name = "$main",
        qname = module .. ".$main", label = "top-level code", owner = file_id, range = range(root),
        error = root:has_error(), annotations = {}, modifiers = {}, bindings = {}, params = {}, static = false,
        signature = "top-level code of " .. file, entry = true }
      add(sym)
      pending[sym.id] = { node = root, body = root, script = true }
      break
    end
  end
  pending.own = own
  return facts, pending
end

local terminal = set({ "return_statement", "throw_statement", "break_statement", "continue_statement" })
local statement_kinds = { for_in_statement = "enhanced_for_statement", lexical_declaration = "local_variable_declaration",
  variable_declaration = "local_variable_declaration", statement_block = "block" }
local declarations_skipped = set({ "function_declaration", "generator_function_declaration", "class_declaration",
  "abstract_class_declaration", "interface_declaration", "type_alias_declaration", "enum_declaration",
  "import_statement", "export_statement", "ambient_declaration", "empty_statement" })
local literal_types = { string = "String", template_string = "String", number = "Number", ["true"] = "Boolean",
  ["false"] = "Boolean", array = "Array", object = "Object", regex = "RegExp" }

local scope_kinds = set({ "statement_block", "for_statement", "for_in_statement", "catch_clause", "switch_body" })

local function earlier(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

local function each_binding(node, fn)
  if not node then
    return
  end
  local kind = node:type()
  if kind == "identifier" or kind == "shorthand_property_identifier_pattern" then
    fn(node)
  elseif kind == "pair_pattern" then
    each_binding(field(node, "value"), fn)
  elseif kind == "assignment_pattern" or kind == "object_assignment_pattern" then
    each_binding(field(node, "left"), fn)
  elseif kind == "object_pattern" or kind == "array_pattern" or kind == "rest_pattern" then
    for _, child in ipairs(children(node)) do
      each_binding(child, fn)
    end
  end
end

function M.bodies(_, src, facts, pending)
  local own = pending.own
  pending.own = nil
  local lines = vim.split(src, "\n", { plain = true })
  local parsed = {}
  local function build(id)
    if parsed[id] then
      return parsed[id]
    end
    local entry, sym = pending[id], facts.symbols[id]
    if not entry then
      return
    end
    local root = entry.body
    local r = range(entry.node)
    local body = { symbol = id, locals = {}, sites = {}, stmts = {}, field_writes = {}, casts = {},
      inits = {}, metrics = { lines = r["end"][1] - r.start[1] + 1, statements = 0, branches = 0, loops = 0,
        sites = 0, project_sites = 0, field_writes = 0, throws = 0 } }
    parsed[id], facts.bodies[id] = body, body
    local ancestor = facts.symbols[sym.owner]
    while ancestor and ancestor.methods do
      ancestor = facts.symbols[ancestor.owner]
    end
    local outer = ancestor and build(ancestor.id)
    local local_names, site_of_node, stack = {}, {}, {}
    local lambdas = {}
    body.local_names = local_names
    -- one local per name and block: `let`/`const` shadow only inside their block
    local function declare(name, at, kind, block)
      block = block or r
      local list = local_names[name] or {}
      local_names[name] = list
      for _, loc in ipairs(list) do
        if vim.deep_equal(loc.scope, block) then
          return loc
        end
      end
      local loc = { name = name, kind = kind or "local", body = id, index = #body.locals + 1,
        declared_at = at, scope = block, definitions = {}, uses = {} }
      body.locals[#body.locals + 1] = loc
      list[#list + 1] = loc
      return loc
    end
    local function declare_params(params, kind, block)
      for i, param in ipairs(params) do
        if param.bindings then
          for _, binding in ipairs(param.bindings) do
            local loc = declare(binding.name, binding.range.start, kind or "binding", block)
            loc.spelled = binding.type and binding.type.spelled
            loc.member_of = binding.member_of
          end
        else
          local loc = declare(param.name, param.range.start, kind or "param", block)
          loc.param = not kind and i or nil
          loc.spelled = param.type and param.type.spelled
        end
      end
    end
    declare_params(sym.params or {})

    -- `block` is the innermost scope; `callback` is true inside an anonymous function
    local function collect(node, block, callback)
      local kind = node:type()
      if own[node:id()] and node:id() ~= entry.fn or declarations_skipped[kind] and kind ~= "export_statement" then
        return
      end
      if kind == "arrow_function" or kind == "function_expression" then
        block, callback = range(node), true
        declare_params(parameters(field(node, "parameters") or field(node, "parameter"), src), "lambda", block)
      elseif scope_kinds[kind] then
        block = range(node)
      end
      -- the top level of a script binds module names, which resolve through facts
      local module_level = entry.script and not callback and vim.deep_equal(block, r)
      if kind == "variable_declarator" then
        local value = field(node, "value")
        if value and own[unwrap(value):id()] then
          return -- its own symbol
        end
        if not required(value, src) and not module_level then
          local var = node:parent():type() == "variable_declaration"
          each_binding(field(node, "name"), function(n)
            declare(text(n, src), range(n).start, nil, var and r or block)
          end)
        end
      elseif kind == "for_in_statement" and field(node, "kind") then
        each_binding(field(node, "left"), function(n)
          declare(text(n, src), range(n).start, "for", block)
        end)
      elseif kind == "catch_clause" then
        each_binding(field(node, "parameter"), function(n)
          declare(text(n, src), range(n).start, nil, block)
        end)
      end
      for _, child in ipairs(children(node)) do
        collect(child, block, callback)
      end
    end
    if root:type() == "statement_block" or root:type() == "program" then
      for _, child in ipairs(children(root)) do
        collect(child, r, false)
      end
    else
      collect(root, r, false)
    end

    local function innermost(list, at)
      local best
      for _, loc in ipairs(list or {}) do
        local from, to = loc.scope.start, loc.scope["end"]
        if not earlier(at, from) and not earlier(to, at)
            and (not best or earlier(best.scope.start, from)) then
          best = loc
        end
      end
      return best
    end

    local function lookup(name, at)
      local found = innermost(local_names[name], at)
      if found then
        return found
      end
      local b = outer
      while b do
        found = innermost(b.local_names[name], at)
        if found then
          return found
        end
        local parent = facts.symbols[facts.symbols[b.symbol].owner]
        while parent and parent.methods do
          parent = facts.symbols[parent.owner]
        end
        b = parent and facts.bodies[parent.id]
      end
    end

    local function describe(node)
      node = unwrap(node)
      if not node then
        return { k = "other" }
      end
      local kind = node:type()
      if kind == "identifier" or kind == "shorthand_property_identifier" then
        local name = text(node, src)
        local loc = lookup(name, range(node).start)
        return { k = "id", name = name, ["local"] = loc and loc.index,
          local_body = loc and loc.body ~= id and loc.body or nil }
      elseif kind == "this" then
        return { k = "this" }
      elseif kind == "super" then
        return { k = "super" }
      elseif kind == "member_expression" then
        return { k = "field", object = describe(field(node, "object")), name = text(field(node, "property"), src) }
      elseif kind == "call_expression" or kind == "new_expression" then
        local site = site_of_node[node:id()]
        return site and { k = "call", site = site.id, name = site.name, arity = site.arity } or { k = "other" }
      elseif literal_types[kind] then
        return { k = "lit", type = literal_types[kind] }
      end
      return { k = "other" }
    end

    local function in_sites(first)
      local ids = {}
      for i = first, #body.sites do
        ids[#ids + 1] = body.sites[i].id
      end
      return ids
    end

    local function passed_to(node)
      local child, parent = node, node:parent()
      while parent and parent:type() ~= "statement_block" and parent:type() ~= "program" do
        local kind = parent:type()
        local grand = parent:parent()
        if kind == "arguments" and grand and (grand:type() == "call_expression" or grand:type() == "new_expression") then
          local i = 0
          for _, a in ipairs(children(parent)) do
            if a:type() ~= "comment" then
              i = i + 1
              if a:id() == child:id() then
                return grand:id(), i
              end
            end
          end
        elseif kind == "call_expression" then
          return parent:id(), nil, true
        elseif kind == "arrow_function" or kind == "function_expression" then
          return
        end
        child, parent = parent, grand
      end
    end

    local deferred_uses = {}
    local function use(node)
      local loc = lookup(text(node, src), range(node).start)
      if not loc then
        return
      end
      local call, arg, receiver = passed_to(node)
      local st = stack[#stack]
      local u = { at = range(node).start, stmt = st and st.range, returned = st and st.kind == "return_statement" or nil,
        arg = arg, receiver = receiver, body = loc.body ~= id and id or nil }
      loc.uses[#loc.uses + 1] = u
      if call then
        deferred_uses[#deferred_uses + 1] = { use = u, call = call }
      end
    end

    local function write(target, value)
      local object = describe(field(target, "object"))
      local loc = object["local"] and not object.local_body and body.locals[object["local"]]
      local name = text(field(target, "property"), src)
      local w = { name = name, object = object.k == "this" and "this" or text(field(target, "object"), src),
        param = (object.k == "id" and loc and loc.kind == "param") or nil,
        at = range(target).start, range = range(target), value = value }
      body.field_writes[#body.field_writes + 1] = w
      for _, st in ipairs(stack) do
        st.field_writes[#st.field_writes + 1] = w
      end
      -- JavaScript classes declare fields by assigning them
      local owner = facts.symbols[sym.owner]
      if object.k == "this" and owner and owner.fields and not owner.object then
        local fid = owner.fields[name] or (owner.id .. "#" .. name)
        owner.fields[name] = fid
        local f = facts.symbols[fid] or { id = fid, kind = "field", name = name, label = owner.name .. "." .. name,
          file = sym.file, source = "ast", owner = owner.id, range = w.range }
        facts.symbols[fid] = f
        if not f.type and value.k == "id" and loc and loc.spelled then
          f.type = { name = loc.spelled, spelled = loc.spelled }
        elseif not f.type and value.k == "call" then
          local s = body.sites[tonumber(value.site:sub(2))]
          if s and s.kind == "new" then
            f.type = { name = s.type, spelled = s.type }
          end
        end
      end
    end

    local visit, statement, statement_list

    local function call_site(node)
      local constructed = node:type() == "new_expression"
      local callee = field(node, constructed and "constructor" or "function")
      local arguments = field(node, "arguments")
      local name = field(callee, "property") or callee
      visit(callee)
      local args = {}
      for _, a in ipairs(arguments and arguments:type() == "arguments" and children(arguments) or {}) do
        if a:type() ~= "comment" then
          visit(a)
          local d = describe(a)
          d.at = range(a).start
          if a:type() == "spread_element" then
            d.splat = true
          end
          args[#args + 1] = d
        end
      end
      if not name or name:type() == "import" then
        return
      end
      local descriptor = describe(callee)
      local badge = callee:type() == "member_expression" and text(callee, src):find("[^%w_$.#]") and name or callee
      local s = { id = "s" .. (#body.sites + 1), order = #body.sites + 1, kind = constructed and "new" or "call",
        at = range(node).start, name_at = range(name).start, node_range = range(node), range = range(badge),
        name = text(name, src), text = text(badge, src), arity = #args, args = args, callee = descriptor,
        receiver = descriptor.k == "field" and descriptor.object or { k = "implicit" } }
      if constructed then
        s.type = text(callee, src)
      elseif callee:type() == "super" then
        s.kind = "super()"
      end
      local lambda = lambdas[#lambdas]
      if lambda then
        s.deferred = { kind = "lambda", arg = lambda.arg }
        if lambda.node then
          deferred_uses[#deferred_uses + 1] = { deferred = s.deferred, call = lambda.node }
        end
      end
      body.sites[#body.sites + 1] = s
      site_of_node[node:id()] = s
      for _, st in ipairs(stack) do
        st.sites[#st.sites + 1] = s.id
      end
    end

    local function assign(names, value_node, spelled)
      local first_site = #body.sites + 1
      visit(value_node)
      local value = describe(value_node)
      each_binding(names, function(n)
        local loc = lookup(text(n, src), range(n).start)
        if loc and loc.body == id then
          loc.spelled = spelled or loc.spelled
          if value_node then
            loc.definitions[#loc.definitions + 1] = { range = range(value_node), sites = in_sites(first_site),
              value = names:type() == "identifier" and value or { k = "other" }, at = range(names).start }
          end
        end
      end)
      return value
    end

    -- `const { a, b: c } = value` types a and c from value's members
    local function destructured(target, value_node)
      if not target or target:type() ~= "object_pattern" or not value_node then
        return
      end
      local value = describe(value_node)
      for _, item in ipairs(children(target)) do
        local bound, key = item, nil
        if item:type() == "shorthand_property_identifier_pattern" then
          key = text(item, src)
        elseif item:type() == "pair_pattern" then
          bound, key = field(item, "value"), text(field(item, "key"), src)
        end
        local loc = key and bound:type() ~= "object_pattern" and lookup(text(bound, src), range(bound).start)
        if loc and loc.body == id then
          loc.definitions = { { range = range(value_node), sites = {}, at = range(bound).start,
            value = { k = "field", object = value, name = key } } }
        end
      end
    end

    function visit(node)
      if not node then
        return
      end
      local kind = node:type()
      if own[node:id()] and node:id() ~= entry.fn then
        return
      end
      if kind == "identifier" or kind == "shorthand_property_identifier" then
        use(node)
      elseif kind == "call_expression" or kind == "new_expression" then
        call_site(node)
      elseif kind == "member_expression" then
        visit(field(node, "object"))
      elseif kind == "arrow_function" or kind == "function_expression" then
        local call, arg = passed_to(node)
        local index = #lambdas + 1
        lambdas[index] = { node = call, arg = arg }
        local content = field(node, "body")
        if content and content:type() == "statement_block" then
          for _, child in ipairs(children(content)) do
            visit(child)
          end
        else
          visit(content)
        end
        lambdas[index] = nil
      elseif kind == "variable_declarator" then
        local value = field(node, "value")
        if not (value and own[unwrap(value):id()]) then
          local ty = type_ref(field(node, "type"), src)
          local target = field(node, "name")
          assign(target, value, ty and ty.spelled)
          destructured(target, value)
        end
      elseif kind == "assignment_expression" or kind == "augmented_assignment_expression" then
        local left, right = field(node, "left"), field(node, "right")
        if kind == "augmented_assignment_expression" then
          visit(left)
        end
        if left:type() == "member_expression" then
          visit(right)
          visit(field(left, "object"))
          write(left, describe(right))
        elseif left:type() == "subscript_expression" then
          visit(right)
          visit(left)
        else
          assign(left, right)
        end
      elseif kind == "as_expression" then
        local ty = type_ref(node:named_child(1), src)
        if ty then
          body.casts[#body.casts + 1] = { type = ty.spelled, at = range(node).start }
        end
        visit(node:named_child(0))
      elseif not declarations_skipped[kind] and kind ~= "type_annotation" and kind ~= "type_arguments" then
        for _, child in ipairs(children(node)) do
          visit(child)
        end
      end
    end

    local function blank_between(first, last)
      for row = first + 1, last - 1 do
        if vim.trim(lines[row + 1] or "") == "" then
          return true
        end
      end
      return false
    end

    -- a declaration that only introduces functions or imports is its own symbol, not a step
    local function declaration_only(node)
      local kind = node:type()
      if declarations_skipped[kind] then
        return true
      end
      if kind == "lexical_declaration" or kind == "variable_declaration" then
        for _, d in ipairs(children(node, "variable_declarator")) do
          local value = field(d, "value")
          if not (value and own[unwrap(value):id()]) and not required(value, src) then
            return false
          end
        end
        return true
      end
      return false
    end

    function statement_list(list, out)
      local prev_end, comment_start
      for _, child in ipairs(list) do
        local cr = range(child)
        if child:type() == "comment" then
          comment_start = comment_start or cr.start
        elseif declaration_only(child) then
          comment_start = nil
        else
          local st = statement(child)
          st.blank_before = prev_end ~= nil and blank_between(prev_end, cr.start[1])
          st.comment_before, st.comment_start = comment_start ~= nil, comment_start
          out[#out + 1] = st
          comment_start = nil
        end
        prev_end = cr["end"][1]
      end
    end

    function statement(node)
      local kind = node:type()
      local st = { kind = statement_kinds[kind] or kind, range = range(node), arms = {}, sites = {},
        field_writes = {}, terminal = terminal[kind] or nil }
      local metrics = body.metrics
      metrics.statements = metrics.statements + 1
      stack[#stack + 1] = st
      local function arm(name, content, header, index)
        if content then
          local a = { name = name, index = index, range = { start = range(header or content).start,
            ["end"] = range(content)["end"] }, stmts = {} }
          st.arms[#st.arms + 1] = a
          local list = content:type() == "statement_block" and children(content) or { content }
          statement_list(list, a.stmts)
          return a
        end
      end
      local condition = field(node, "condition")
      if condition then
        st.condition = text(condition, src):gsub("^%((.*)%)$", "%1")
      end
      if kind == "if_statement" then
        metrics.branches = metrics.branches + 1
        visit(condition)
        local a = arm("then", field(node, "consequence"))
        local alt = field(node, "alternative")
        if alt then
          arm("else", alt:named_child(0), alt)
        elseif a and #a.stmts == 1 then
          st.guard = a.stmts[1].terminal or nil
        end
      elseif kind == "for_statement" or kind == "for_in_statement" or kind == "while_statement"
          or kind == "do_statement" then
        metrics.loops = metrics.loops + 1
        local subject = field(node, "right")
        for _, part in ipairs({ field(node, "initializer"), condition, field(node, "increment"), subject }) do
          visit(part)
        end
        each_binding(field(node, "left"), function(n)
          local l = lookup(text(n, src), range(n).start)
          if l then
            l.subject = text(subject, src)
          end
        end)
        arm("body", field(node, "body"))
      elseif kind == "try_statement" then
        arm("try", field(node, "body"))
        local handler, finalizer = field(node, "handler"), field(node, "finalizer")
        if handler then
          arm("catch", field(handler, "body"), handler, 1)
        end
        if finalizer then
          arm("finally", field(finalizer, "body"), finalizer)
        end
      elseif kind == "switch_statement" then
        local subject = field(node, "value")
        st.condition = text(subject, src):gsub("^%((.*)%)$", "%1")
        visit(subject)
        local index = 0
        for _, case in ipairs(children(field(node, "body"))) do
          local value = field(case, "value")
          local content = case:field("body")
          index = index + 1
          visit(value)
          local a = { name = "case", index = index, range = range(case), stmts = {} }
          st.arms[#st.arms + 1] = a
          statement_list(content, a.stmts)
        end
      elseif kind == "statement_block" then
        statement_list(children(node), (function()
          local a = { name = "body", range = range(node), stmts = {} }
          st.arms[1] = a
          return a.stmts
        end)())
      else
        visit(node)
        local expression = node:named_child(0)
        if kind == "return_statement" then
          st.value = describe(expression)
        elseif kind == "expression_statement" then
          local inner = unwrap(expression)
          local left = inner and field(inner, "left")
          if left then
            st.value = { k = "assign", field = left:type() == "member_expression" or nil,
              value = describe(field(inner, "right")) }
          else
            st.value = describe(expression)
          end
        elseif kind == "lexical_declaration" or kind == "variable_declaration" then
          local names = {}
          for _, d in ipairs(children(node, "variable_declarator")) do
            each_binding(field(d, "name"), function(n)
              names[#names + 1] = text(n, src)
            end)
            st.value = { k = "assign", value = describe(field(d, "value")) }
          end
          st.locals = names
        elseif kind == "throw_statement" then
          metrics.throws = metrics.throws + 1
        end
      end
      stack[#stack] = nil
      return st
    end

    if root:type() == "statement_block" then
      statement_list(children(root), body.stmts)
    elseif entry.script then
      local list = {}
      for _, child in ipairs(children(root)) do
        local expression = child:type() == "expression_statement" and child:named_child(0)
        local target = expression and text(field(expression, "left"), src) or ""
        -- CommonJS exports declare; they are not steps of the script
        if child:type() == "comment" or not declaration_only(child)
            and not (target:match("^module%.exports") or target:match("^exports%.")) then
          list[#list + 1] = child
        end
      end
      statement_list(list, body.stmts)
    else
      -- an expression-bodied arrow function returns its expression
      local st = { kind = "return_statement", range = range(root), arms = {}, sites = {}, field_writes = {},
        terminal = true }
      body.metrics.statements = 1
      stack[#stack + 1] = st
      visit(root)
      st.value = describe(root)
      stack[#stack] = nil
      body.stmts[1] = st
    end
    for _, link in ipairs(deferred_uses) do
      local target = site_of_node[link.call]
      if target then
        if link.use then
          link.use.site = target.id
        else
          link.deferred.call = target.id
        end
      end
    end
    body.metrics.sites, body.metrics.field_writes = #body.sites, #body.field_writes
    return body
  end
  local ids = vim.tbl_keys(pending)
  table.sort(ids)
  for _, id in ipairs(ids) do
    build(id)
  end
  for _, body in pairs(facts.bodies) do
    body.local_names = nil -- only needed while the nested bodies were built
  end
  return facts
end

function M.extract(file, src)
  local root = vim.treesitter.get_string_parser(src, M.parser_for(file)):parse()[1]:root()
  local facts, pending = M.declarations(file, root, src)
  return M.bodies(file, src, facts, pending)
end

-- Resolution ------------------------------------------------------------------

local unknown = { kind = "unknown" }

local function project(sym, via, instance, heuristic)
  return { kind = sym.methods and "project" or "function", sym = sym, name = sym.qname, via = via,
    instance = instance, heuristic = heuristic }
end

local function external(path)
  return { kind = "library", name = (path:gsub("^~", ""):gsub("#", ".")) }
end

-- A module-level `const x = new T()` (or annotated value) is an instance of T.
local function module_value(r, facts, name)
  local t = r:type_name(facts.vars[name], { facts = facts })
  return vim.tbl_extend("force", t, { instance = true, via = "module" })
end

-- Which files may make each name global, found by reading every file once: the top-level
-- declarations of scripts, and the files that publish on globalThis.
local function global_candidates(r)
  local names, publishers = {}, {}
  local function note(name, file)
    names[name] = names[name] or {}
    names[name][file] = true
  end
  for _, file in ipairs(r.idx.files) do
    local backend = r.idx:backend(file)
    local fd = backend and backend.name == M.name and io.open(r.idx:abs(file), "r")
    if fd then
      local src = "\n" .. fd:read("*a")
      fd:close()
      if src:find("globalThis%.[%w_]+%s*=") or src:find("window%.[%w_]+%s*=")
          or src:find("Object%.assign%(%s*globalThis") then
        publishers[#publishers + 1] = file
      end
      if not (src:find("\nimport[%s{]") or src:find("\nexport[%s{]")) then
        for _, keyword in ipairs({ "class", "function", "async function", "const", "let", "var" }) do
          for name in src:gmatch("\n" .. keyword .. "%s+([%a_][%w_]*)") do
            note(name, file)
          end
        end
      end
    end
  end
  for _, file in ipairs(publishers) do
    local facts = r.idx:facts(file)
    for name in pairs(facts and facts.globals or {}) do
      note(name, file)
    end
  end
  return names
end

-- The one project file that makes `name` global. Several such files are ambiguous.
local function global(r, name, from)
  r.global_names = r.global_names or global_candidates(r)
  local found = {}
  for file in pairs(r.global_names[name] or {}) do
    local facts = r.idx:facts(file)
    local own = facts and (facts.globals[name] or facts.script and name)
    if own and (facts.bindings[own] or facts.vars[own]) then
      found[#found + 1] = { facts = facts, name = own }
    end
  end
  local hit = #found == 1 and found[1]
  if not hit or hit.facts.file == from.file then
    return
  end
  local sym = hit.facts.symbols[hit.facts.bindings[hit.name]]
  if sym then
    return project(sym, "global", nil, true)
  end
  return module_value(r, hit.facts, hit.name)
end

local member

-- What a module (`dir.file`) or one of its exports (`dir.file#Name.member`) names,
-- following re-exports.
local function qualified(r, path, seen)
  seen = seen or {}
  if seen[path] then
    return unknown
  end
  seen[path] = true
  if path:sub(1, 1) == "~" then
    return external(path)
  end
  local name, chain = path:match("^([^#]*)#(.*)$")
  local module = r.idx:module(M.name, name or path)
  if not module then
    return unknown
  end
  local whole = { kind = "module", name = name or path, facts = module, via = "import" }
  if not name then
    return whole
  end
  local export, rest = chain:match("^([^.]+)%.?(.*)$")
  local found = unknown
  local sym = module.symbols[module.bindings[export]]
  if sym then
    found = project(sym, "import")
  elseif module.vars[export] then
    found = module_value(r, module, export)
  elseif module.imports.single[export] then
    found = qualified(r, module.imports.single[export], seen)
  else
    for _, wildcard in ipairs(module.imports.wildcard) do
      local again = qualified(r, wildcard .. "#" .. export, seen)
      if again.kind ~= "unknown" then
        found = again
        break
      end
    end
    -- `require("./x")` is the module's default export; `import x from` a CommonJS module too
    if found.kind == "unknown" and export == "default" then
      found = whole
    end
  end
  for part in rest:gmatch("[^.]+") do
    found = member(r, found, part)
  end
  return found
end

function M.import_symbol(r, path)
  local target = qualified(r, path)
  return target.sym or (target.facts and target.facts.symbols["file:" .. target.facts.file])
end

local function lexical(r, name, ctx)
  local scope = ctx.method or ctx.type
  while scope do
    -- class and object members need a receiver; only function scopes bind bare names
    if not scope.methods then
      local sym = scope.bindings and ctx.facts.symbols[scope.bindings[name]]
      if sym then
        return project(sym, "scope")
      end
    end
    scope = scope.owner and r.idx:symbol(scope.owner)
  end
  local sym = ctx.facts.symbols[ctx.facts.bindings[name]]
  if sym then
    return project(sym, "scope")
  end
  if ctx.facts.vars[name] then
    return module_value(r, ctx.facts, name)
  end
  local alias = ctx.facts.imports.single[name]
  if alias then
    return qualified(r, alias)
  end
  if M.builtins[name] then
    return { kind = "builtin", name = name }
  end
  return global(r, name, ctx.facts) or unknown
end

function M.resolve_type(r, name, ctx)
  local owner, key = name:match("^(.*)@([^@]+)$")
  if owner then
    return member(r, M.resolve_type(r, owner, ctx), key)
  end
  local head, tail = name:match("^([^.]+)%.(.+)$")
  local t = lexical(r, head or name, ctx)
  if tail then
    for part in tail:gmatch("[^.]+") do
      t = member(r, t, part)
    end
  end
  return t.kind == "function" and unknown or t
end

function M.supertypes(r, t, ctx, out)
  if ctx.type and not ctx.type.methods then
    ctx.method, ctx.type = ctx.type, nil
  end
  for _, base in ipairs(t.extends) do
    local found = r:type_name(base.spelled, ctx)
    out.all[#out.all + 1] = found
    if not out.superclass and t.kind ~= "interface" then
      out.superclass = found
    else
      out.interfaces[#out.interfaces + 1] = found
    end
  end
  for _, base in ipairs(t.implements or {}) do
    local found = r:type_name(base.spelled, ctx)
    out.all[#out.all + 1] = found
    out.interfaces[#out.interfaces + 1] = found
  end
end

-- The member `name` of a class: own, then superclasses, then interfaces.
local function class_member(r, t, name)
  local queue, seen, library = { t.sym }, {}, nil
  if t.super then
    local base = r:supertypes(t.sym).superclass
    queue = { base and base.sym }
    library = base and base.kind == "library" and base.name or nil
  end
  local i = 1
  while queue[i] do
    local cls = queue[i]
    i = i + 1
    if not seen[cls.id] then
      seen[cls.id] = true
      local sym = r.idx:symbol(cls.bindings[name])
      if sym then
        return project(sym, t.super and "super" or t.via, nil, t.heuristic)
      end
      local alias = cls.aliases and cls.aliases[name]
      if alias then
        local found = lexical(r, alias, { facts = r:facts_of(cls) })
        return found
      end
      local f = r.idx:symbol(cls.fields[name])
      if f then
        if not f.type then
          return unknown
        end
        local typed = r:type_name(f.type.spelled, r:type_ctx(cls))
        return vim.tbl_extend("force", typed, { instance = true, via = "field" })
      end
      for _, base in ipairs(r:supertypes(cls).all) do
        if base.sym then
          queue[#queue + 1] = base.sym
        elseif base.kind == "library" then
          library = library or base.name
        end
      end
    end
  end
  return library and external(library .. "." .. name) or unknown
end

function member(r, t, name)
  if t.kind == "module" then
    return qualified(r, t.name .. "#" .. name)
  elseif t.kind == "library" then
    return external(t.name .. "." .. name)
  elseif t.kind == "project" then
    return class_member(r, t, name)
  elseif t.kind == "builtin" then
    return { kind = "builtin", name = t.name }
  end
  return unknown
end

local function resolved_value(r, s, ctx)
  if not s then
    return unknown
  end
  if s.kind == "new" then
    -- the site was resolved first (evaluation order), so `references` is the class
    local sym = s.references and r.idx:symbol(s.references)
    if sym then
      return project(sym, "constructor", true)
    end
  end
  if s.unresolved == "builtin" then
    return { kind = "builtin", name = s.name }
  elseif s.unresolved == "library" then
    local full = s.receiver_type and s.library_name and (s.receiver_type .. "." .. s.library_name) or s.name
    return { kind = "library", name = full }
  end
  local targets = s.targets or {}
  local sym = #targets >= 1 and r.idx:symbol(s.declared and s.declared.symbol or targets[1].symbol)
  if sym and sym.returns_spelled then
    local t = r:type_name(sym.returns_spelled, { facts = r:facts_of(sym), method = sym, type = r.idx:symbol(sym.owner) })
    return vim.tbl_extend("force", t, { instance = true, heuristic = true, via = "return" })
  end
  return unknown
end

local describe
local function local_value(r, d, ctx, depth)
  local b = d.local_body and ctx.facts.bodies[d.local_body] or ctx.body
  local l = b and b.locals[d["local"]]
  if not l then
    return unknown
  end
  local lookup = ctx
  if b ~= ctx.body then
    local sym = ctx.facts.symbols[b.symbol]
    lookup = { facts = ctx.facts, body = b, method = sym, type = r.idx:symbol(sym.owner) }
  end
  if l.spelled then
    local t = r:type_name(l.spelled, lookup)
    return vim.tbl_extend("force", t, { instance = true, via = l.kind == "param" and "param" or "local" })
  end
  if depth > 12 then
    return unknown
  end
  if l.member_of then
    local owner = r:type_name(l.member_of.type, lookup)
    if owner.kind == "project" then
      return member(r, owner, l.member_of.key)
    end
    return unknown
  end
  if l.kind == "for" then
    return unknown
  end
  local result
  for _, def in ipairs(l.definitions) do
    local resolved = describe(r, def.value, lookup, depth + 1)
    if result and (result.kind ~= resolved.kind or result.name ~= resolved.name) then
      return unknown
    end
    result = resolved
  end
  return result or unknown
end

function describe(r, d, ctx, depth)
  if not d or depth > 12 then
    return unknown
  elseif (d.k == "this" or d.k == "super") then
    -- an arrow function nested in a method keeps the method's `this`
    local owner = ctx.type
    local scope = ctx.method
    while not (owner and owner.methods) and scope and scope.owner do
      owner = r.idx:symbol(scope.owner)
      scope = owner
    end
    if owner and owner.methods then
      return { kind = "project", sym = owner, name = owner.qname, via = d.k, instance = true,
        super = d.k == "super" or nil }
    end
    return unknown
  elseif d.k == "id" then
    return d["local"] and local_value(r, d, ctx, depth) or lexical(r, d.name, ctx)
  elseif d.k == "field" then
    if d.object.k == "id" and not d.object["local"] and (d.object.name == "globalThis" or d.object.name == "window") then
      local found = lexical(r, d.name, ctx)
      if found.kind ~= "unknown" then
        return found
      end
    end
    return member(r, describe(r, d.object, ctx, depth + 1), d.name)
  elseif d.k == "call" then
    return resolved_value(r, ctx.body.sites[tonumber(d.site:sub(2))], ctx)
  elseif d.k == "lit" then
    return { kind = "builtin", name = d.type }
  end
  return unknown
end

local function bind(site, sym, target)
  site.targets = { { symbol = sym.id, confidence = target.heuristic and "INFERRED" or "EXTRACTED",
    via = target.via or "scope" } }
  site.unresolved = nil
end

-- A signature with no code (interface or abstract method): the implementations are walked.
local function dispatch(r, site, sym)
  site.declared = { symbol = sym.id, confidence = "EXTRACTED", via = "declared" }
  site.targets = {}
  for _, sub in ipairs(r:subtypes(r.idx:symbol(sym.owner))) do
    local impl = r.idx:symbol(sub.bindings and sub.bindings[sym.name])
    if impl and impl.params and not impl.abstract then
      site.targets[#site.targets + 1] = { symbol = impl.id, confidence = "INFERRED", via = "dispatch" }
    end
  end
  site.unresolved = #site.targets == 0 and "abstract" or nil
end

local function construct(r, site, t)
  if t.kind == "project" then
    site.type, site.receiver_type, site.references = t.sym.qname, t.sym.qname, t.sym.id
    site.reference_confidence = t.heuristic and "INFERRED" or "EXTRACTED"
    local ctor = r.idx:symbol(t.sym.bindings.constructor)
    if ctor then
      bind(site, ctor, t)
    end
  else
    site.unresolved = t.kind == "library" and "library" or t.kind == "builtin" and "builtin" or "dynamic"
  end
end

function M.resolve_site(r, site, ctx)
  if site.kind == "new" then
    return construct(r, site, describe(r, site.callee, ctx, 0))
  end
  if site.kind == "super()" then
    local owner = describe(r, { k = "this" }, ctx, 0)
    local base = owner.sym and r:supertypes(owner.sym).superclass
    return construct(r, site, base or unknown)
  end
  local target = describe(r, site.callee, ctx, 0)
  if target.kind == "function" then
    site.receiver_type = r.idx:symbol(target.sym.owner) and r.idx:symbol(target.sym.owner).qname or nil
    if target.sym.abstract then
      return dispatch(r, site, target.sym)
    end
    bind(site, target.sym, target)
  elseif target.kind == "library" then
    site.receiver_type, site.library_name = target.name:match("^(.*)%.([^.]+)$")
    site.unresolved = "library"
  elseif target.kind == "builtin" then
    site.unresolved = "builtin"
  else
    site.unresolved = "dynamic"
  end
end

return M
