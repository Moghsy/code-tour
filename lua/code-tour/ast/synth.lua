-- Synthetic members: code that exists at run time but not in the source text (Lombok,
-- Python dataclasses, Kotlin data classes, annotation processors, …). A synthesizer is a
-- function(type, api) -> specs, registered per language and keyed by the annotation or
-- decorator that triggers it. The backend declares what comes back as implicit symbols
-- (no body to walk, `implicit = true`, `synthetic = <rule name>`), so the resolver binds
-- calls through the generated API by receiver type instead of guessing by name.
--
--   type = { name, qname, kind, annotations = {names}, fields = { {name, type = {spelled}, static?, final?} } }
--   spec = { kind = "method"|"constructor"|"type", name, params = { {name, type} }, returns = spelled,
--            static?, members? (for kind = "type") }
--
-- Users add rules with setup({ synthesizers = { java = { MyAnnotation = function(type, api) … end } } }).
local M = {}

local function cap(name)
  return name:sub(1, 1):upper() .. name:sub(2)
end

local function is_bool(f)
  return f.type and f.type.spelled == "boolean"
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

local function getters(type)
  local specs = {}
  for _, f in ipairs(instance(type)) do
    specs[#specs + 1] = { kind = "method", name = (is_bool(f) and "is" or "get") .. cap(f.name), params = {},
      returns = f.type and f.type.spelled }
  end
  return specs
end

local function setters(type)
  local specs = {}
  for _, f in ipairs(instance(type)) do
    if not f.final then
      specs[#specs + 1] = { kind = "method", name = "set" .. cap(f.name), returns = "void",
        params = { { name = f.name, type = f.type } } }
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

local function builder(type)
  local members = { { kind = "method", name = "build", params = {}, returns = type.qname } }
  for _, f in ipairs(instance(type)) do
    members[#members + 1] = { kind = "method", name = f.name, returns = type.name .. "Builder",
      params = { { name = f.name, type = f.type } } }
  end
  return {
    { kind = "type", name = type.name .. "Builder", members = members },
    { kind = "method", name = "builder", static = true, params = {}, returns = type.name .. "Builder" },
  }
end

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    vim.list_extend(out, list)
  end
  return out
end


M.builtin = {
  java = {
    Getter = getters,
    Setter = setters,
    Data = function(type)
      return concat(getters(type), setters(type), { constructor(type, function(f) return f.final end) })
    end,
    Value = function(type)
      return concat(getters(type), { constructor(type) })
    end,
    Builder = builder,
    AllArgsConstructor = function(type) return { constructor(type) } end,
    NoArgsConstructor = function(type) return { constructor(type, function() return false end) } end,
    RequiredArgsConstructor = function(type) return { constructor(type, function(f) return f.final end) } end,
  },
}

-- Rules for a language: the built-ins, then the user's (which win on a name clash).
function M.rules(language)
  local user = require("code-tour.ast").options.synthesizers or {}
  return vim.tbl_extend("force", M.builtin[language] or {}, user[language] or {})
end

-- Specs for every triggering annotation of `type`, in annotation order. A rule that
-- errors contributes nothing: a broken user rule must not break indexing.
function M.specs(language, owner)
  local rules = M.rules(language)
  local out = {}
  for _, name in ipairs(owner.annotations or {}) do
    local rule = rules[name:match("([^.]+)$")]
    if rule then
      local ok, specs = pcall(rule, owner, { cap = cap })
      if ok and type(specs) == "table" then
        for _, spec in ipairs(specs) do
          spec.rule = name
          out[#out + 1] = spec
        end
      end
    end
  end
  return out
end

return M
