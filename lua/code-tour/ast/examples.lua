-- Test discovery and deterministic example selection (§12).
local route = require("code-tour.ast.route")
local M = {}

local function is_test(sym, owner)
  if sym.kind ~= "method" and sym.kind ~= "function" then return false end
  if sym.test then return true end
  for _, annotation in ipairs(sym.annotations or {}) do
    local name = annotation:match("[^.]+$")
    if name == "Test" or name == "ParameterizedTest" or name == "RepeatedTest" then return true end
  end
  return sym.file:match("^tests?/") or sym.file:match("/tests?/")
    or (owner and (owner.name:match("Tests?$")))
    or (sym.id:match("^python:") and sym.name:match("^test_"))
end

local function catalog(idx)
  if idx.example_catalog then return idx.example_catalog end
  local candidates = {}
  for _, file in ipairs(idx:grep("@.*(Test|ParameterizedTest|RepeatedTest)|class[[:space:]]+[[:alnum:]_]+Tests?")) do
    candidates[file] = true
  end
  local count = 0
  for _, file in ipairs(idx.files) do
    local base = vim.fs.basename(file)
    if candidates[file] or file:match("^tests?/") or file:match("/tests?/")
        or base:match("Tests?%.java$") or base:match("^test_.*%.py$") or base:match("_test%.py$") then
      idx:facts(file)
      count = count + 1
      if count >= idx.max_files then break end
    end
  end
  local rt = route.new(idx)
  local tests, main_paths = {}, {}
  local function main_path(id)
    if not main_paths[id] then main_paths[id] = rt:main_flow({ id }).nodes end
    return main_paths[id]
  end
  local ids = vim.tbl_keys(idx.symbols)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local sym = idx.symbols[id]
    if is_test(sym, sym.owner and idx:symbol(sym.owner)) then
      local body = rt:body(id)
      if body then
        local targets, assertions = {}, 0
        for _, site in ipairs(body.sites) do
          if (site.name or site.text):match("^assert") then assertions = assertions + 1 end
          for _, target in ipairs(site.targets or {}) do targets[target.symbol] = 1 end
          if site.declared then targets[site.declared.symbol] = 1 end
        end
        local direct = vim.tbl_keys(targets)
        local function extend(entry, initial_depth)
          for target, node in pairs(main_path(entry)) do
            if target ~= id then targets[target] = math.min(targets[target] or math.huge, initial_depth + node.depth) end
          end
        end
        extend(id, 0)
        for _, target in ipairs(direct) do extend(target, 1) end
        local first, last = require("code-tour.ast.outline").lines_of(sym.range)
        tests[#tests + 1] = { id = id, label = sym.label, file = sym.file, lines = { first, last },
          assertions = assertions, targets = targets }
      end
    end
  end
  idx.example_catalog = tests
  return tests
end

function M.tests(idx, targets, max_depth)
  local out = {}
  for _, test in ipairs(catalog(idx)) do
    local distance = math.huge
    for _, target in ipairs(targets) do distance = math.min(distance, test.targets[target] or math.huge) end
    if distance < math.huge and (not max_depth or distance <= max_depth) then
      out[#out + 1] = { id = test.id, label = test.label, file = test.file, lines = test.lines,
        distance = distance, assertions = test.assertions }
    end
  end
  table.sort(out, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    if a.assertions ~= b.assertions then return a.assertions > b.assertions end
    return a.id < b.id
  end)
  return out
end

function M.snippet(test)
  return { kind = "example", title = test.label, file = test.file, start = test.lines[1], ["end"] = test.lines[2],
    why = "example: test", note = "Test example · " .. test.label, example = { source = "test", test = test.id } }
end

return M
