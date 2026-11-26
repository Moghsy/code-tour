-- Synthetic members: code that exists at run time but not in the source text (Lombok,
-- Python dataclasses, Kotlin data classes, annotation processors, …). A synthesizer is a
-- function(type, api) -> specs, registered per language and keyed by the annotation or
-- decorator that triggers it. The backend declares what comes back as implicit symbols
-- (no body to walk, `implicit = true`, `synthetic = <rule name>`), so the resolver binds
-- calls through the generated API by receiver type instead of guessing by name.
--
--   type = { name, qname, kind, annotations = {names}, args = {name -> "(…)" source text},
--            fields = { {name, type = {name, spelled}, static?, final?, annotations = {names},
--                        args = {…}} } }
--   spec = { kind = "method"|"constructor"|"field"|"type", name, params = { {name, type} },
--            returns = spelled, static?, members? (for kind = "type"), type? (for a field),
--            field? (the field an accessor is for: the member points at it in the source) }
--
-- Rules are keyed by the annotation's simple name and see the whole type, so a class-level
-- and a field-level annotation (`@Getter` on either) are handled by the same rule. Users
-- add rules with setup({ synthesizers = { java = { MyAnnotation = function(type, api) … end } } }).
local M = {}

local function cap(name)
  return name:sub(1, 1):upper() .. name:sub(2)
end

local function has(list, name)
  for _, item in ipairs(list or {}) do
    if item:match("([^.]+)$") == name then
      return true
    end
  end
  return false
end

local function flag(args, key)
  return args and args:match(key .. "%s*=%s*true") ~= nil
end

local function is_bool(f)
  return f.type and f.type.spelled == "boolean"
end

-- @Accessors(fluent = true, chain = true) on the type: getters and setters named after the field.
local function accessors(type)
  local args = type.args and type.args.Accessors
  return { fluent = flag(args, "fluent"), chain = flag(args, "chain") or flag(args, "fluent") }
end

-- The fields a rule applies to: every instance field when `name` is on the type, else the
-- fields that carry it themselves.
local function targets(type, name)
  local out = {}
  local whole = has(type.annotations, name)
  for _, f in ipairs(type.fields) do
    if not f.static and (whole or has(f.annotations, name)) then
      out[#out + 1] = f
    end
  end
  return out
end

local function instance(type)
  local out = {}
  for _, f in ipairs(type.fields) do
    if not f.static then
      out[#out + 1] = f
    end
  end
  return out
end

local function getter(type, f)
  local acc = accessors(type)
  return { kind = "method", name = acc.fluent and f.name or ((is_bool(f) and "is" or "get") .. cap(f.name)),
    params = {}, returns = f.type and f.type.spelled, field = f.name }
end

local function setter(type, f)
  local acc = accessors(type)
  return { kind = "method", name = acc.fluent and f.name or ("set" .. cap(f.name)),
    returns = acc.chain and type.name or "void", params = { { name = f.name, type = f.type } }, field = f.name }
end

local function getters(type)
  return vim.tbl_map(function(f) return getter(type, f) end, targets(type, "Getter"))
end

local function setters(type, name)
  local specs = {}
  for _, f in ipairs(targets(type, name or "Setter")) do
    if not f.final then
      specs[#specs + 1] = setter(type, f)
    end
  end
  return specs
end

local function constructor(type, only)
  local params = {}
  for _, f in ipairs(instance(type)) do
    if not only or only(f) then
      params[#params + 1] = { name = f.name, type = f.type }
    end
  end
  return { kind = "constructor", name = type.name, params = params }
end

-- `List<String>` -> `String`: the element type a @Singular method takes.
local function element(f)
  local inner = f.type and f.type.spelled and f.type.spelled:match("<(.+)>$")
  if not inner then
    return nil -- the extractor keeps no type arguments: an untyped parameter binds by arity
  end
  inner = inner:match("^([^,]+)") -- a Map's key; its value rides on the same call
  return { name = inner:match("([^.<]+)$"), spelled = inner }
end

local function singular(f)
  local given = f.args and f.args.Singular and f.args.Singular:match('"([^"]+)"')
  if given then
    return given
  end
  return (f.name:gsub("ies$", "y"):gsub("s$", ""))
end

local function builder(type)
  local builder_name = type.name .. "Builder"
  -- @SuperBuilder's fluent methods return the self type `B`, so a subclass builder keeps its
  -- own type through calls inherited from a superclass builder
  local fluent = has(type.annotations, "SuperBuilder") and "@self" or builder_name
  local members = { { kind = "method", name = "build", params = {}, returns = type.qname } }
  for _, f in ipairs(instance(type)) do
    if has(f.annotations, "Singular") then
      members[#members + 1] = { kind = "method", name = singular(f), returns = fluent,
        params = { { name = singular(f), type = element(f) } } }
      members[#members + 1] = { kind = "method", name = f.name, returns = fluent,
        params = { { name = f.name, type = f.type } } }
      members[#members + 1] = { kind = "method", name = "clear" .. cap(f.name), returns = fluent, params = {} }
    else
      members[#members + 1] = { kind = "method", name = f.name, returns = fluent,
        params = { { name = f.name, type = f.type } } }
    end
  end
  -- @SuperBuilder: the builder of a subclass extends its superclass's builder, so inherited
  -- fields chain too (`Child.builder().parentField(x).childField(y).build()`)
  local super
  if has(type.annotations, "SuperBuilder") and type.superclass then
    super = type.superclass .. "Builder"
  end
  local specs = {
    { kind = "type", name = builder_name, members = members, extends = super and (type.superclass .. "." .. super) or nil },
    { kind = "method", name = "builder", static = true, params = {}, returns = builder_name },
  }
  if flag(type.args and type.args.Builder, "toBuilder") then
    specs[#specs + 1] = { kind = "method", name = "toBuilder", params = {}, returns = builder_name }
  end
  return specs
end

local function with(type)
  local specs = {}
  for _, f in ipairs(targets(type, "With")) do
    if not f.final or has(type.annotations, "With") or has(f.annotations, "With") then
      specs[#specs + 1] = { kind = "method", name = "with" .. cap(f.name), returns = type.name,
        params = { { name = f.name, type = f.type } }, field = f.name }
    end
  end
  return specs
end

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    vim.list_extend(out, list)
  end
  return out
end

-- A logger field: the annotation names the field `log` and its library type.
local function logger(spelled)
  return function()
    return { { kind = "field", name = "log", static = true, type = { name = spelled:match("([^.]+)$"), spelled = spelled } } }
  end
end

M.builtin = {
  java = {
    Getter = getters,
    Setter = function(type) return setters(type, "Setter") end,
    With = with,
    Data = function(type)
      -- @Data is @Getter + @Setter + a required-args constructor on every field
      local all = vim.tbl_extend("force", {}, type, { annotations = vim.list_extend({ "Getter", "Setter" }, type.annotations) })
      return concat(getters(all), setters(all), { constructor(type, function(f) return f.final end) })
    end,
    Value = function(type)
      local all = vim.tbl_extend("force", {}, type, { annotations = vim.list_extend({ "Getter" }, type.annotations) })
      return concat(getters(all), { constructor(type) })
    end,
    Builder = builder,
    SuperBuilder = builder,
    AllArgsConstructor = function(type) return { constructor(type) } end,
    NoArgsConstructor = function(type) return { constructor(type, function() return false end) } end,
    RequiredArgsConstructor = function(type) return { constructor(type, function(f) return f.final end) } end,
    Slf4j = logger("org.slf4j.Logger"),
    Log4j2 = logger("org.apache.logging.log4j.Logger"),
    Log4j = logger("org.apache.log4j.Logger"),
    Log = logger("java.util.logging.Logger"),
    CommonsLog = logger("org.apache.commons.logging.Log"),
    JBossLog = logger("org.jboss.logging.Logger"),
    Flogger = logger("com.google.common.flogger.FluentLogger"),
  },
}

-- Python: the decorator is the trigger and class-level annotated names are the fields.
-- `field(default=…)` and plain defaults make a parameter optional; ClassVar and init=False
-- fields are not parameters.
M.builtin.python = {
  dataclass = function(type)
    if type.args and type.args.dataclass and type.args.dataclass:match("init%s*=%s*False") then
      return {} -- @dataclass(init=False): the class writes (or inherits) its own constructor
    end
    local params = {}
    for _, f in ipairs(type.fields) do
      if not f.static_var and not f.init_false then
        params[#params + 1] = { name = f.name, type = f.type, optional = f.default or nil }
      end
    end
    return { { kind = "constructor", name = "__init__", params = params } }
  end,
}

-- Rules for a language: the built-ins, then the user's (which win on a name clash).
function M.rules(language)
  local user = require("code-tour.ast").options.synthesizers or {}
  return vim.tbl_extend("force", M.builtin[language] or {}, user[language] or {})
end

-- The annotations that can trigger a rule: the type's own and its fields'. A rule runs once
-- per annotation name, whichever of them carries it.
function M.specs(language, owner)
  local rules = M.rules(language)
  local names, seen = {}, {}
  local function note(list)
    for _, name in ipairs(list or {}) do
      local simple = name:match("([^.]+)$")
      if rules[simple] and not seen[simple] then
        seen[simple] = true
        names[#names + 1] = simple
      end
    end
  end
  note(owner.annotations)
  for _, f in ipairs(owner.fields) do
    note(f.annotations)
  end
  local out = {}
  for _, simple in ipairs(names) do
    local ok, specs = pcall(rules[simple], owner, { cap = cap })
    if ok and type(specs) == "table" then
      for _, spec in ipairs(specs) do
        spec.rule = simple
        out[#out + 1] = spec
      end
    end
  end
  return out
end

return M
