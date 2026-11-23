-- Python Tree-sitter backend. Symbols are scoped by module and lexical owner.
local M = { name = "python", parser = "python", extensions = { ".py" }, version = 2 }

local function set(items)
  local out = {}
  for _, name in ipairs(items) do
    out[name] = true
  end
  return out
end

M.types = {
  type = { "class_definition" },
  method = { "function_definition" },
  import = { "import_statement", "import_from_statement" },
  call = { "call" },
  statement = { "assert_statement", "break_statement", "continue_statement", "delete_statement",
    "expression_statement", "global_statement", "nonlocal_statement", "pass_statement", "raise_statement",
    "return_statement" },
  compound = { "if_statement", "for_statement", "while_statement", "try_statement", "with_statement", "match_statement" },
}
M.builtins = set({ "abs", "all", "any", "bool", "bytes", "dict", "enumerate", "Exception", "filter", "float",
  "frozenset", "getattr", "hasattr", "int", "isinstance", "issubclass", "iter", "len", "list", "map", "max", "min",
  "next", "object", "open", "print", "range", "repr", "reversed", "set", "setattr", "sorted", "str", "sum", "super",
  "tuple", "type", "ValueError", "zip" })
M.sinks = { "requests#get", "requests#post", "requests#put", "requests#delete", "httpx#get", "httpx#post",
  "pathlib.Path#write_text", "pathlib.Path#write_bytes" }
M.handoffs = { "asyncio#create_task", "asyncio#ensure_future", "concurrent.futures.Executor#submit" }

function M.module_name(file)
  local module = file:gsub("^src/", ""):gsub("%.py$", ""):gsub("/__init__$", ""):gsub("/", ".")
  return module
end

-- Symbol IDs and relative imports depend on the path as well as the source.
function M.cache_identity(file)
  return file
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

local function range(node)
  local sr, sc, er, ec = node:range()
  return { start = { sr, sc }, ["end"] = { er, ec } }
end

local function text(node, src)
  return node and vim.treesitter.get_node_text(node, src) or ""
end

local function type_ref(node, src)
  local name = vim.trim(text(node, src)):gsub("^(['\"])(.-)%1$", "%2")
  if name:match("^[%w_.]+$") then
    return { name = name, spelled = name }
  end
end

local function imports(node, facts, src)
  local base = field(node, "module_name")
  local module = text(base, src)
  local dots, tail = module:match("^(%.+)(.*)$")
  if dots then
    local package = facts.package
    for _ = 2, #dots do
      package = package:match("^(.*)%.[^.]+$") or ""
    end
    module = package .. (package ~= "" and tail ~= "" and "." or "") .. tail
  end
  local out = {}
  for _, name in ipairs(node:field("name")) do
    local path = text(field(name, "name") or name, src)
    local alias = text(field(name, "alias"), src)
    local full = module ~= "" and (module .. "." .. path) or path
    local bound = full
    if alias == "" then
      alias = path:match("^[^.]+")
      bound = base and full or alias
    end
    out[#out + 1] = { name = alias, path = full, bound = bound, range = range(node) }
  end
  if #children(node, "wildcard_import") > 0 then
    out[#out + 1] = { path = module, wildcard = true, range = range(node) }
  end
  return out
end

local function parameters(node, src)
  local out, keyword_only = {}, false
  for _, param in ipairs(children(node)) do
    local kind = param:type()
    if kind == "positional_separator" then
      for _, p in ipairs(out) do
        p.positional_only = true
      end
    elseif kind == "keyword_separator" then
      keyword_only = true
    elseif kind ~= "comment" then
      local name = field(param, "name") or (kind == "identifier" and param) or param:named_child(0)
      local splat = (name and name:type():match("^(%a+)_splat")) or kind:match("^(%a+)_splat")
      if name and name:type() ~= "identifier" and splat then
        name = name:named_child(0)
      end
      if name and name:type() == "identifier" then
        out[#out + 1] = { name = text(name, src), type = type_ref(field(param, "type"), src),
          range = range(name), optional = field(param, "value") ~= nil, splat = splat,
          keyword_only = keyword_only or nil }
        keyword_only = keyword_only or splat == "list"
      end
    end
  end
  return out
end

local function decorators(node, src)
  local annotations, mods = {}, {}
  for _, decorator in ipairs(children(node, "decorator")) do
    local expression = decorator:named_child(0)
    local name = text(field(expression, "function") or expression, src)
    local short = name:match("([%w_]+)$")
    if short then
      annotations[#annotations + 1] = name
      mods[short] = true
    end
  end
  return annotations, mods
end

local function entry_decorator(annotations)
  for _, annotation in ipairs(annotations) do
    local owner, name = annotation:match("([%w_]+)%.([%w_]+)$")
    if name == "route" or name == "command" or name == "websocket"
        or ((owner == "app" or owner == "router" or owner == "blueprint")
          and ({ get = true, post = true, put = true, delete = true, patch = true })[name]) then
      return true
    end
  end
end

local function main_guard(node, src)
  local condition = field(node, "condition")
  if not condition or condition:type() ~= "comparison_operator" or condition:named_child_count() ~= 2 then
    return false
  end
  local function matches(a, b)
    return text(a, src) == "__name__" and text(b, src):match("^(['\"])__main__%1$") ~= nil
  end
  local lhs, rhs = condition:named_child(0), condition:named_child(1)
  local operator = condition:child(1)
  return operator and operator:type() == "==" and (matches(lhs, rhs) or matches(rhs, lhs))
end

function M.declarations(file, root, src)
  local module = M.module_name(file)
  local package = file:match("/__init__%.py$") and module or module:match("^(.*)%.[^.]+$") or ""
  local facts = { file = file, lang = M.name, module = module, package = package, names = {}, types = {},
    type_order = {}, bodies = {}, symbols = {}, imports = { single = {}, wildcard = {}, list = {} },
    bindings = {}, error = root:has_error() }
  local file_id = "file:" .. file
  facts.symbols[file_id] = { id = file_id, kind = "file", label = vim.fs.basename(file), file = file,
    range = range(root), source = "ast", bindings = facts.bindings }
  local pending = {}

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

  -- Generated members (dataclasses): implicit symbols from ast/synth.lua rules. A class that
  -- writes its own __init__ keeps it.
  local function synthesize(class, scope)
    local fields = {}
    for name, id in pairs(class.fields) do
      local f = facts.symbols[id]
      if f and f.annotated and not f.class_var then
        fields[#fields + 1] = { name = name, type = f.type, default = f.default, line = f.range.start[1],
          annotations = {}, args = {} }
      end
    end
    table.sort(fields, function(a, b) return a.line < b.line end)
    local specs = require("code-tour.ast.synth").specs(M.name, { name = class.name, qname = class.qname,
      kind = "class", annotations = class.annotations, args = {}, fields = fields })
    for _, spec in ipairs(specs) do
      local id = class.id .. "." .. spec.name
      if spec.kind == "constructor" and not facts.symbols[id] then
        local params = { { name = "self", range = class.range } }
        for _, p in ipairs(spec.params) do
          params[#params + 1] = { name = p.name, type = p.type, range = class.range, optional = p.optional }
        end
        local ctor = { id = id, kind = "constructor", name = spec.name, qname = class.qname .. "." .. spec.name,
          label = class.name .. "." .. spec.name, owner = class.id, range = class.range, params = params,
          returns_spelled = class.name, modifiers = { public = true }, annotations = {}, static = false,
          implicit = true, synthetic = spec.rule, signature = spec.name .. "(" .. #spec.params .. " fields)" }
        add(ctor, class)
        class.methods[#class.methods + 1] = id
      end
    end
  end

  local function walk(container, scope)
    for _, child in ipairs(children(container)) do
      local node = field(child, "definition") or child
      local kind = node:type()
      if kind == "import_statement" or kind == "import_from_statement" then
        if not scope then
          for _, import in ipairs(imports(node, facts, src)) do
            if import.wildcard then
              table.insert(facts.imports.wildcard, import.path)
            else
              facts.imports.single[import.name] = import.bound
            end
            facts.imports.list[#facts.imports.list + 1] = import
          end
        end
      elseif kind == "class_definition" or kind == "function_definition" or (not scope and main_guard(node, src)) then
        local class = kind == "class_definition"
        local name = kind == "if_statement" and "$main" or text(field(node, "name"), src)
        local qname = (scope and scope.qname or module) .. "." .. name
        local annotations, modifiers = decorators(child, src)
        local body = field(node, "body") or field(node, "consequence")
        local sym = { id = "python:" .. qname, kind = class and "class"
          or (name == "__init__" and scope and scope.kind == "class" and "constructor" or "method"),
          name = name, qname = qname, label = scope and (scope.name .. "." .. name) or name,
          owner = scope and scope.id or file_id, range = range(child), error = node:has_error(),
          annotations = annotations, modifiers = modifiers, bindings = {} }
        if name == "$main" then
          sym.label = "__main__ guard"
        end
        modifiers.public = name:sub(1, 1) ~= "_"
        local existed = facts.symbols[sym.id] ~= nil
        add(sym, scope)
        if class then
          sym.outer = scope and scope.id or nil
          sym.extends, sym.implements, sym.methods, sym.fields, sym.nested = {}, {}, {}, {}, {}
          sym.type_params, sym.components = {}, {}
          for _, base in ipairs(children(field(node, "superclasses"))) do
            local ref = type_ref(base, src)
            if ref then
              table.insert(sym.extends, ref)
            end
          end
          facts.types[qname] = sym.id
          if not existed then
            facts.type_order[#facts.type_order + 1] = sym.id
          end
          if scope and scope.kind == "class" then
            scope.nested[name] = sym.id
          end
        else
          local ret = type_ref(field(node, "return_type"), src)
          sym.params, sym.returns_spelled, sym.returns = parameters(field(node, "parameters"), src),
            ret and ret.spelled, ret and ret.name
          sym.static = modifiers.staticmethod or false
          sym.entry = name == "$main" or entry_decorator(annotations)
          sym.test = name:match("^test_") ~= nil and (not scope or (scope.kind == "class" and scope.name:match("^Test")))
          local _, _, start_byte = node:start()
          local _, _, body_byte = (body or node):start()
          sym.signature = vim.trim(src:sub(start_byte + 1, body_byte):gsub("%s+", " "):gsub(":%s*$", ""))
          if scope and scope.kind == "class" and not existed then
            scope.methods[#scope.methods + 1] = sym.id
          end
        end
        if body then
          pending[sym.id] = body
          walk(body, sym)
        end
        if class then
          synthesize(sym, scope)
        end
      elseif scope and kind == "expression_statement" and scope.kind == "class" then
        local assignment = node:named_child(0)
        local left = field(assignment, "left")
        if left and left:type() == "identifier" then
          local name = text(left, src)
          local id = scope.id .. "#" .. name
          scope.fields[name] = id
          local annotated = field(assignment, "type")
          local spelled = annotated and vim.trim(text(annotated, src))
          facts.symbols[id] = { id = id, kind = "field", name = name, label = scope.name .. "." .. name,
            file = file, owner = scope.id, range = range(assignment), source = "ast", static = true,
            type = type_ref(annotated, src), annotated = annotated ~= nil or nil,
            default = field(assignment, "right") ~= nil or nil,
            class_var = spelled and (spelled:match("^ClassVar") or spelled:match("%.ClassVar")) and true or nil }
        end
      end
    end
  end

  walk(root)
  return facts, pending
end

local terminal = set({ "return_statement", "raise_statement", "break_statement", "continue_statement" })
local compound = {
  for_statement = "enhanced_for_statement",
  match_statement = "switch_statement",
  with_statement = "synchronized_statement",
  raise_statement = "throw_statement",
  elif_clause = "if_statement",
}

local function each_binding(node, fn)
  if not node then
    return
  end
  local kind = node:type()
  if kind == "identifier" then
    fn(node)
  elseif kind == "pattern_list" or kind == "list_pattern" or kind == "tuple_pattern"
      or kind == "list_splat_pattern" or kind == "as_pattern_target" then
    for _, child in ipairs(children(node)) do
      each_binding(child, fn)
    end
  end
end

local function function_local(node)
  local kind = node:type()
  return kind == "assignment" or kind == "augmented_assignment" or kind == "named_expression" or kind == "for_statement"
end

function M.bodies(_, src, facts, pending)
  local lines = vim.split(src, "\n", { plain = true })
  local parsed = {}
  local function build(id)
    if parsed[id] then
      return parsed[id]
    end
    local root, sym = pending[id], facts.symbols[id]
    if not root then
      return
    end
    local r = range(root)
    local body = { symbol = id, locals = {}, sites = {}, stmts = {}, field_writes = {}, casts = {},
      inits = {}, metrics = { lines = r["end"][1] - r.start[1] + 1, statements = 0, branches = 0, loops = 0,
        sites = 0, project_sites = 0, field_writes = 0, throws = 0 } }
    parsed[id], facts.bodies[id] = body, body
    if sym.kind == "class" then
      body.initializer = true
    end
    local ancestor = facts.symbols[sym.owner]
    while ancestor and ancestor.kind == "class" do
      ancestor = facts.symbols[ancestor.owner]
    end
    local outer = ancestor and build(ancestor.id)
    local local_names, excluded, site_of_node, stack = {}, {}, {}, {}
    local lambdas, lambda_names = {}, {}
    body.local_names = local_names
    local owner = facts.symbols[sym.owner]
    local first = sym.params and sym.params[1]
    local instance = owner and owner.kind == "class" and not sym.static and first and first.name or nil
    local function declare(name, at, kind)
      local loc = local_names[name]
      if not loc then
        loc = { name = name, kind = kind or "local", body = id, index = #body.locals + 1,
          declared_at = at, scope = r, definitions = {}, uses = {} }
        body.locals[#body.locals + 1] = loc
        local_names[name] = loc
      end
      return loc
    end
    for i, param in ipairs(sym.params or {}) do
      local loc = declare(param.name, param.range.start, "param")
      loc.param = instance and i - 1 or i
      loc.spelled = param.type and param.type.spelled
    end

    local function scope_declarations(node)
      local kind = node:type()
      if kind == "global_statement" or kind == "nonlocal_statement" then
        for _, n in ipairs(children(node, "identifier")) do
          excluded[text(n, src)] = kind
        end
      elseif kind ~= "function_definition" and kind ~= "class_definition" and kind ~= "decorated_definition"
          and kind ~= "lambda" then
        for _, child in ipairs(children(node)) do
          scope_declarations(child)
        end
      end
    end
    scope_declarations(root)

    local function local_at(node, kind)
      local name = text(node, src)
      if not excluded[name] then
        return declare(name, range(node).start, kind)
      end
    end

    local function collect(node)
      local kind = node:type()
      if kind == "decorated_definition" or kind == "function_definition" or kind == "class_definition" then
        return
      end
      if kind == "lambda" then
        return
      elseif function_local(node) then
        each_binding(field(node, "left") or field(node, "name"), function(n)
          local_at(n, kind == "for_statement" and "for" or nil)
        end)
      elseif kind == "import_statement" or kind == "import_from_statement" then
        for _, import in ipairs(imports(node, facts, src)) do
          if import.name and not excluded[import.name] then
            declare(import.name, range(node).start, "import")
          end
        end
      elseif kind == "except_clause" or kind == "with_item" then
        local alias = field(field(node, "value"), "alias")
        each_binding(alias, local_at)
      end
      for _, child in ipairs(children(node)) do
        collect(child)
      end
    end
    if sym.kind ~= "class" and sym.name ~= "$main" then
      collect(root)
    end

    local function lookup(name)
      for i = #lambda_names, 1, -1 do
        if lambda_names[i][name] then
          return lambda_names[i][name]
        end
      end
      if local_names[name] then
        return local_names[name]
      end
      if excluded[name] == "global_statement" then
        return nil
      end
      local b = outer
      while b do
        if b.local_names[name] then
          return b.local_names[name]
        end
        local parent = facts.symbols[facts.symbols[b.symbol].owner]
        while parent and parent.kind == "class" do
          parent = facts.symbols[parent.owner]
        end
        b = parent and facts.bodies[parent.id]
      end
    end

    local function describe(node)
      if not node then
        return { k = "other" }
      end
      local kind = node:type()
      if kind == "identifier" then
        local name = text(node, src)
        local loc = lookup(name)
        if instance == name and loc and loc.kind == "param" and loc.param == 0 and loc.body == id then
          return { k = "this" }
        end
        return { k = "id", name = name, ["local"] = loc and loc.index,
          local_body = loc and loc.body ~= id and loc.body or nil, global = excluded[name] == "global_statement" or nil }
      elseif kind == "attribute" then
        return { k = "field", object = describe(field(node, "object")), name = text(field(node, "attribute"), src) }
      elseif kind == "call" then
        local site = site_of_node[node:id()]
        return site and { k = "call", site = site.id, name = site.name, arity = site.arity } or { k = "other" }
      elseif kind == "parenthesized_expression" or kind == "await" or kind == "keyword_argument" then
        return describe(field(node, "value") or node:named_child(0))
      elseif kind == "string" or kind == "integer" or kind == "float" or kind == "true" or kind == "false" then
        local literal = { string = "str", integer = "int", float = "float", ["true"] = "bool", ["false"] = "bool" }
        return { k = "lit", type = literal[kind] }
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
      while parent and parent:type() ~= "block" do
        if parent:type() == "argument_list" and parent:parent():type() == "call" then
          local i = 0
          for _, a in ipairs(children(parent)) do
            if a:type() ~= "comment" then
              i = i + 1
              if a:id() == child:id() then
                return parent:parent():id(), i
              end
            end
          end
        elseif parent:type() == "call" then
          return parent:id(), nil, true
        elseif parent:type() == "lambda" then
          return
        end
        child, parent = parent, parent:parent()
      end
    end

    local deferred_uses = {}
    local function use(node)
      local loc = lookup(text(node, src))
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

    local function write(target, value, ty)
      if target:type() ~= "attribute" then
        return
      end
      local object = describe(field(target, "object"))
      local loc = object["local"] and body.locals[object["local"]]
      local name = text(field(target, "attribute"), src)
      local w = { name = name, object = object.k == "this" and "this" or text(field(target, "object"), src),
        param = (object.k == "id" and not object.local_body and loc and loc.kind == "param") or nil,
        at = range(target).start, range = range(target), value = value }
      body.field_writes[#body.field_writes + 1] = w
      for _, st in ipairs(stack) do
        st.field_writes[#st.field_writes + 1] = w
      end
      if object.k == "this" then
        local fid = owner.fields[name] or (owner.id .. "#" .. name)
        owner.fields[name] = fid
        local f = facts.symbols[fid] or { id = fid, kind = "field", name = name, label = owner.name .. "." .. name,
          file = sym.file, source = "ast", owner = owner.id, range = w.range }
        facts.symbols[fid] = f
        f.type = ty or f.type
      end
      return true
    end

    local visit
    function visit(node)
      if not node then
        return
      end
      local kind = node:type()
      if kind == "identifier" then
        use(node)
      elseif kind == "call" then
        local callee, arguments = field(node, "function"), field(node, "arguments")
        local name = field(callee, "attribute") or callee
        visit(callee)
        local args = {}
        for _, a in ipairs(children(arguments)) do
          if a:type() ~= "comment" then
            visit(a)
            local d = describe(a)
            d.at = range(a).start
            local kw = field(a, "name")
            if a:type() == "keyword_argument" and kw then
              d.keyword = text(kw, src)
            elseif a:type() == "list_splat" or a:type() == "dictionary_splat" then
              d.splat = true
            end
            args[#args + 1] = d
          end
        end
        if not name then
          return
        end
        local descriptor = describe(callee)
        local badge = callee:type() == "attribute" and text(callee, src):find("[^%w_.]") and name or callee
        local pos = range(name).start
        local s = { id = "s" .. (#body.sites + 1), order = #body.sites + 1, kind = "call",
          at = range(node).start, name_at = pos, node_range = range(node), range = range(badge),
          name = text(name, src), text = text(badge, src), arity = #args, args = args, callee = descriptor,
          receiver = descriptor.k == "field" and descriptor.object or { k = "implicit" } }
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
      elseif kind == "attribute" then
        visit(field(node, "object"))
      elseif kind == "keyword_argument" then
        visit(field(node, "value"))
      elseif kind == "lambda" then
        local call, arg = passed_to(node)
        local names = {}
        local index = #lambda_names + 1
        for _, param in ipairs(parameters(field(node, "parameters"), src)) do
          local loc = { name = param.name, kind = "lambda", body = id, index = #body.locals + 1,
            declared_at = param.range.start, scope = range(node), definitions = {}, uses = {} }
          body.locals[#body.locals + 1] = loc
          names[param.name] = loc
        end
        lambda_names[index], lambdas[index] = names, { node = call, arg = arg }
        visit(field(node, "body"))
        lambda_names[index], lambdas[index] = nil, nil
      elseif kind == "assignment" or kind == "augmented_assignment" or kind == "named_expression" then
        local left, right = field(node, "left") or field(node, "name"), field(node, "right") or field(node, "value")
        local first_site = #body.sites + 1
        if kind == "augmented_assignment" then
          visit(left)
        end
        visit(right)
        local ty = type_ref(field(node, "type"), src)
        local value = describe(right)
        each_binding(left, function(n)
          local loc = lookup(text(n, src))
          if loc and loc.body == id then
            loc.spelled = (ty and ty.spelled) or loc.spelled
            if right then
              loc.definitions[#loc.definitions + 1] = { range = range(right), sites = in_sites(first_site),
                value = left:type() == "identifier" and value or { k = "other" }, at = range(node).start }
            end
          end
        end)
        if left and left:type() == "attribute" then
          visit(field(left, "object"))
          write(left, value, ty)
        elseif left and left:type() == "subscript" then
          visit(left)
        elseif body.initializer and left and left:type() == "identifier" and right then
          body.inits[text(left, src)] = value
        end
      elseif kind == "import_statement" or kind == "import_from_statement" then
        for _, import in ipairs(imports(node, facts, src)) do
          local loc = import.name and local_names[import.name]
          if loc then
            loc.definitions[#loc.definitions + 1] = { range = range(node), sites = {}, import_path = import.bound }
          end
        end
      elseif kind ~= "function_definition" and kind ~= "class_definition" and kind ~= "decorated_definition"
          and kind ~= "global_statement" and kind ~= "nonlocal_statement" then
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

    local statement, statement_list
    function statement_list(container, out)
      local prev_end, comment_start
      for _, child in ipairs(children(container)) do
        local cr = range(child)
        if child:type() == "comment" then
          comment_start = comment_start or cr.start
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

    function statement(node, alternatives)
      local kind = node:type()
      local st = { kind = compound[kind] or kind, range = range(node), arms = {}, sites = {}, field_writes = {},
        terminal = terminal[kind] or nil }
      local metrics = body.metrics
      metrics.statements = metrics.statements + 1
      stack[#stack + 1] = st
      local function arm(name, content, header, index)
        if content then
          local a = { name = name, index = index, range = { start = range(header or content).start,
            ["end"] = range(content)["end"] }, stmts = {} }
          st.arms[#st.arms + 1] = a
          statement_list(content, a.stmts)
          return a
        end
      end
      local condition = field(node, "condition")
      if condition then
        st.condition = text(condition, src)
      end
      if st.kind == "if_statement" then
        metrics.branches = metrics.branches + 1
        visit(condition)
        local a = arm("then", field(node, "consequence"))
        alternatives = alternatives or node:field("alternative")
        local alt = alternatives[1]
        if alt and alt:type() == "elif_clause" then
          local rest = vim.list_slice(alternatives, 2)
          local nested = statement(alt, rest)
          local last = alternatives[#alternatives]
          nested.range["end"] = range(last)["end"]
          st.arms[2] = { name = "else", range = { start = range(alt).start, ["end"] = range(last)["end"] },
            stmts = { nested } }
        elseif alt then
          arm("else", field(alt, "body"), alt)
        elseif a and #a.stmts == 1 then
          st.guard = a.stmts[1].terminal or nil
        end
      elseif kind == "for_statement" or kind == "while_statement" or kind == "with_statement" then
        if kind ~= "with_statement" then
          metrics.loops = metrics.loops + 1
        end
        local subject = field(node, "right")
        visit(subject or condition)
        each_binding(field(node, "left"), function(n)
          local l = local_names[text(n, src)]
          if l then
            l.subject = text(subject, src)
          end
        end)
        if kind == "with_statement" then
          for _, clause in ipairs(children(node, "with_clause")) do
            visit(clause)
          end
        end
        arm("body", field(node, "body"))
        local alt = field(node, "alternative")
        arm("else", field(alt, "body"), alt)
      elseif kind == "try_statement" then
        arm("try", field(node, "body"))
        local catch = 0
        for _, clause in ipairs(children(node)) do
          local t = clause:type()
          local content = field(clause, "body") or children(clause, "block")[1]
          if t == "except_clause" or t == "except_group_clause" then
            catch = catch + 1
            arm("catch", content, clause, catch)
          elseif t == "else_clause" then
            arm("else", content, clause)
          elseif t == "finally_clause" then
            arm("finally", content, clause)
          end
        end
      elseif kind == "match_statement" then
        local subject = field(node, "subject")
        st.condition = text(subject, src)
        visit(subject)
        for i, case in ipairs(children(field(node, "body"), "case_clause")) do
          visit(field(case, "guard"))
          arm("case", field(case, "consequence"), case, i)
        end
      else
        visit(node)
        if kind == "return_statement" or kind == "expression_statement" then
          local expr = node:named_child(0)
          local left = field(expr, "left")
          if left then
            st.value = { k = "assign", field = left:type() == "attribute" or nil,
              value = describe(field(expr, "right")) }
            local loc = left:type() == "identifier" and local_names[text(left, src)]
            if loc and vim.deep_equal(loc.declared_at, range(left).start) then
              st.kind, st.locals = "local_variable_declaration", { loc.name }
            end
          else
            st.value = describe(expr)
          end
        elseif kind == "raise_statement" then
          metrics.throws = metrics.throws + 1
        end
      end
      stack[#stack] = nil
      return st
    end

    statement_list(root, body.stmts)
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
  return facts
end

function M.extract(file, src)
  local root = vim.treesitter.get_string_parser(src, M.parser):parse()[1]:root()
  local facts, pending = M.declarations(file, root, src)
  return M.bodies(file, src, facts, pending)
end

local unknown = { kind = "unknown" }

local function project(sym, via, instance, heuristic)
  return { kind = sym.methods and "project" or "function", sym = sym, name = sym.qname, via = via,
    instance = instance, heuristic = heuristic }
end

local function external(path)
  return { kind = "library", name = path }
end

local function earlier(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

-- Imports may re-export names through package initializers.
local function qualified(r, path, seen)
  local idx = r.idx
  local module = idx:module(M.name, path)
  if module then
    return { kind = "module", name = path, facts = module, via = "import" }
  end
  local sym = idx:qualified_symbol(M.name, path)
  if sym then
    return project(sym, "import")
  end
  local owner, member = path:match("^(.*)%.([^.]+)$")
  module = owner and idx:module(M.name, owner)
  local alias = module and module.imports.single[member]
  if alias and alias ~= path then
    seen = seen or {}
    if not seen[path] then
      seen[path] = true
      return qualified(r, alias, seen)
    end
  end
  return module and unknown or external(path)
end

function M.import_symbol(r, path)
  local target = qualified(r, path)
  return target.sym or (target.facts and target.facts.symbols["file:" .. target.facts.file])
end

local function lexical(r, name, ctx, at, global)
  if not global then
    local scope = ctx.method or ctx.type
    -- An unqualified name in a method never searches its enclosing class.
    while scope do
      if scope.kind ~= "class" or scope == ctx.type and ctx.method == nil then
        local sym = scope.bindings and ctx.facts.symbols[scope.bindings[name]]
        if sym and (not at or scope.id ~= ctx.body.symbol or earlier(sym.range.start, at)) then
          return project(sym, "scope")
        end
      end
      scope = scope.owner and r.idx:symbol(scope.owner)
    end
  end
  local sym = ctx.facts.symbols[ctx.facts.bindings[name]]
  if sym then
    return project(sym, "scope")
  end
  local alias = ctx.facts.imports.single[name]
  if alias then
    return qualified(r, alias)
  end
  for _, wildcard in ipairs(ctx.facts.imports.wildcard) do
    local found = qualified(r, wildcard .. "." .. name)
    if found.sym then
      found.heuristic = true
      return found
    end
  end
  if M.builtins[name] then
    return { kind = "builtin", name = name }
  end
  return unknown
end

local function annotation(r, name, ctx)
  local head, tail = name:match("^([^.]+)%.(.+)$")
  local t = lexical(r, head or name, ctx)
  if tail then
    if t.kind == "module" or t.kind == "library" or t.kind == "project" then
      return qualified(r, t.name .. "." .. tail)
    end
    return unknown
  end
  return t
end

function M.resolve_type(r, name, ctx)
  local t = annotation(r, name, ctx)
  return t.kind == "function" and unknown or t
end

function M.supertypes(r, t, ctx, out)
  -- The containing function's bindings are visible in a local class's base list.
  if ctx.type and not ctx.type.methods then
    ctx.method, ctx.type = ctx.type, nil
  end
  for i, base in ipairs(t.extends) do
    local found = r:type_name(base.spelled, ctx)
    out.all[#out.all + 1] = found
    if i == 1 then
      out.superclass = found
    else
      out.interfaces[#out.interfaces + 1] = found
    end
  end
end

local function arity_ok(m, site, bound)
  local params = m.params
  local skip = bound and not m.static and 1 or 0
  local by_name, positional, varargs, kwargs = {}, {}, false, false
  for i = skip + 1, #params do
    local p = params[i]
    if p.splat == "list" then
      varargs = true
    elseif p.splat == "dictionary" then
      kwargs = true
    else
      if not p.positional_only then
        by_name[p.name] = p
      end
      if not p.keyword_only then
        positional[#positional + 1] = p
      end
    end
  end
  local bound_params, position = {}, 1
  for _, arg in ipairs(site.args) do
    if arg.splat then
      return true
    end
    local param = arg.keyword and by_name[arg.keyword] or (not arg.keyword and positional[position])
    if param and bound_params[param] then
      return false
    elseif not param and ((arg.keyword and not kwargs) or (not arg.keyword and not varargs)) then
      return false
    elseif param then
      bound_params[param] = true
    end
    if not arg.keyword then
      position = position + 1
    end
  end
  for i = skip + 1, #params do
    local p = params[i]
    if not p.splat and not p.optional and not bound_params[p] then
      return false
    end
  end
  return true
end

-- Python's C3 merge preserves the declared base order and skips repeated ancestors.
local function mro(r, sym, active)
  active = active or {}
  if active[sym.id] then
    return
  end
  active[sym.id] = true
  local lists, bases = {}, {}
  for _, base in ipairs(r:supertypes(sym).all) do
    if base.sym then
      local linear = mro(r, base.sym, active)
      if not linear then
        active[sym.id] = nil
        return
      end
      lists[#lists + 1] = linear
      bases[#bases + 1] = base.sym
    elseif base.kind == "library" then
      -- Keep external classes in the order. They may define an apparent inherited method.
      local stub = { id = "library:" .. base.name, library = base.name }
      lists[#lists + 1] = { stub }
      bases[#bases + 1] = stub
    elseif base.kind == "unknown" then
      active[sym.id] = nil
      return
    end
  end
  lists[#lists + 1] = bases
  local ordered, any = { sym }, true
  while any do
    local candidate
    any = false
    for _, list in ipairs(lists) do
      if list[1] then
        any = true
        local head, available = list[1], true
        for _, other in ipairs(lists) do
          for i = 2, #other do
            if other[i].id == head.id then
              available = false
            end
          end
        end
        if available then
          candidate = head
          break
        end
      end
    end
    if any then
      if not candidate then
        active[sym.id] = nil
        return
      end
      ordered[#ordered + 1] = candidate
      for _, list in ipairs(lists) do
        if list[1] and list[1].id == candidate.id then
          table.remove(list, 1)
        end
      end
    end
  end
  active[sym.id] = nil
  return ordered
end

local function class_member(r, t, name)
  local order = mro(r, t.sym)
  if not order then
    -- A direct declaration wins even if a base is outside the project.
    order = { t.sym }
  end
  for i = t.super and 2 or 1, #order do
    local cls = order[i]
    if cls.library then
      return external(cls.library .. "." .. name)
    end
    local sym = r.idx:symbol(cls.bindings[name])
    if sym then
      local out = project(sym, t.super and "super" or t.via, nil, t.heuristic)
      out.bound = t.instance or sym.modifiers.classmethod
      return out
    end
    local f = r.idx:symbol(cls.fields[name])
    if f then
      if f.type then
        local typed = r:type_name(f.type.spelled, r:type_ctx(cls))
        return vim.tbl_extend("force", typed, { instance = true, heuristic = true, via = "field" })
      end
      return unknown
    end
  end
  return unknown
end

local function member(r, t, name)
  if t.kind == "module" or t.kind == "library" then
    return qualified(r, t.name .. "." .. name)
  elseif t.kind == "project" then
    return class_member(r, t, name)
  elseif t.kind == "builtin" then
    return t
  end
  return unknown
end

local function resolved_value(r, s, ctx)
  if not s then
    return unknown
  end
  if s.kind == "new" and s.references then
    local sym = r.idx:symbol(s.references)
    if sym then
      return project(sym, "constructor", true)
    end
  elseif s.name == "super" and s.unresolved == "builtin" and s.arity == 0 and ctx.type and ctx.type.methods then
    return { kind = "project", sym = ctx.type, name = ctx.type.qname, via = "super", instance = true, super = true }
  end
  local targets = s.targets or {}
  local sym = #targets == 1 and r.idx:symbol(targets[1].symbol)
  if sym and sym.returns_spelled then
    local t = r:type_name(sym.returns_spelled, { facts = r:facts_of(sym), method = sym, type = r.idx:symbol(sym.owner) })
    return vim.tbl_extend("force", t, { instance = true, heuristic = true, via = "return" })
  end
  return unknown
end

local describe
local function local_value(r, d, ctx, at, depth)
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
  if l.kind == "for" then
    return unknown
  end
  local result
  for _, def in ipairs(l.definitions) do
    if b ~= ctx.body or earlier(def.range["end"], at) then
      local resolved = def.import_path and qualified(r, def.import_path)
        or describe(r, def.value, lookup, def.range.start, depth + 1)
      if result and (result.kind ~= resolved.kind or result.name ~= resolved.name or result.instance ~= resolved.instance) then
        return unknown
      end
      result = resolved
    end
  end
  if result and result.kind ~= "unknown" then
    return result
  end
  if l.spelled then
    local t = r:type_name(l.spelled, lookup)
    return vim.tbl_extend("force", t, { instance = true, heuristic = true, via = "local" })
  end
  return unknown
end

function describe(r, d, ctx, at, depth)
  if not d or depth > 12 then
    return unknown
  elseif d.k == "this" and ctx.type and ctx.type.methods then
    return project(ctx.type, "this", true)
  elseif d.k == "id" then
    return d["local"] and local_value(r, d, ctx, at, depth) or lexical(r, d.name, ctx, at, d.global)
  elseif d.k == "field" then
    return member(r, describe(r, d.object, ctx, at, depth + 1), d.name)
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
end

function M.resolve_site(r, site, ctx)
  local target = describe(r, site.callee, ctx, site.at, 0)
  if target.kind == "project" and not target.instance then
    local sym = target.sym
    site.kind, site.type, site.receiver_type, site.references = "new", sym.qname, sym.qname, sym.id
    site.reference_confidence = target.heuristic and "INFERRED" or "EXTRACTED"
    local ctor = class_member(r, target, "__init__")
    if ctor.kind == "function" and arity_ok(ctor.sym, site, true) then
      bind(site, ctor.sym, target)
    end
  elseif target.kind == "function" then
    if arity_ok(target.sym, site, target.bound) then
      bind(site, target.sym, target)
    else
      site.unresolved = "dynamic"
    end
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
