local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local t = dofile(here .. "/ast_common.lua")
if not require("code-tour.ast.index").parser_available("python") then
  print("MISSING PARSER: python (verification gap; install it to run the Python AST tests)")
  return
end
local ast = require("code-tour.ast")
ast.setup({ languages = { "java", "python" } })
local route = require("code-tour.ast.route")
local prefix, rel = "python:checkout.pipeline.", "src/checkout/pipeline.py"
local function test()
  local root = vim.fn.tempname() .. "-python"
  vim.fn.mkdir(root, "p")
  t.run({ "cp", "-r", here .. "/fixtures/python/.", root })
  t.run({ "git", "init", "-q" }, root)
  local idx = t.index(root)
  local facts = assert(idx.resolver:resolve_file(rel))
  t.eq(facts.module, "checkout.pipeline", "src layout has module-qualified IDs")
  local body = facts.bodies[prefix .. "handle"]
  local normalize = t.site(body, "normalize")
  t.eq(t.targets(normalize), { "python:checkout.words.clean" }, "relative alias resolves through package re-export")
  t.eq(normalize.targets[1].confidence, "EXTRACTED", "explicit import is extracted")
  local new = t.site(body, "Output")
  t.eq({ new.kind, new.references }, { "new", prefix .. "Output" }, "class invocation is a construction")
  t.eq(t.targets(new), { prefix .. "Output.__init__" }, "constructor is followed")
  t.eq(t.targets(t.site(body, "output.format_payload")), { prefix .. "Output.format_payload" }, "constructor gives receiver type")
  local fallback = t.site(body, "fallback")
  t.eq(t.targets(fallback), { prefix .. "handle.fallback" }, "nested function is resolved in lexical scope")
  local rt = route.new(idx)
  t.eq(rt:success(body).off[1].why, "catch", "except arm is off the success path")
  t.eq(t.targets(t.site(facts.bodies[prefix .. "Output.format_payload"], "decorate")),
    { prefix .. "Base.decorate" }, "super dispatch uses the base order")
  local duck = t.site(facts.bodies[prefix .. "dynamic"], "value.format_payload")
  t.eq(duck.targets[1], { symbol = prefix .. "Output.format_payload", confidence = "INFERRED", via = "name-only" },
    "unknown receiver keeps the inferred confidence")
  t.eq(t.site(facts.bodies[prefix .. "shadow"], "normalize").unresolved, "dynamic", "parameter shadows imported name")
  t.check(route.library_call(t.site(facts.bodies[prefix .. "job"], "client.post"),
    require("code-tour.ast.lang.python").sinks), "HTTP call recognized through import alias")
  t.check(route.library_call(t.site(facts.bodies[prefix .. "report"], "send"),
    require("code-tour.ast.lang.python").sinks), "HTTP call recognized through a direct function alias")
  t.check(route.library_call(t.site(facts.bodies[prefix .. "schedule"], "background.create_task"),
    require("code-tour.ast.lang.python").handoffs), "asyncio handoff recognized through import alias")
  t.check(facts.symbols[prefix .. "$main"].entry and facts.symbols[prefix .. "view"].entry, "main guard and decorator are entries")
  local candidates = require("code-tour.ast.outline").auto_entries(idx)
  t.eq({ candidates[1].symbol, candidates[2].symbol }, { prefix .. "$main", prefix .. "view" },
    "entry-free tours rank Python entry markers")
  t.eq(rt:resolve_entry("checkout.pipeline.handle"), { prefix .. "handle" }, "qualified name is an entry")
  local line = facts.symbols[prefix .. "handle"].range.start[1] + 1
  t.eq(rt:resolve_entry(rel .. ":" .. line), { prefix .. "handle" }, "Python path and line name the enclosing function")
  t.eq(rt:resolve_entry(prefix .. "Output.format_payload"), { prefix .. "Output.format_payload" }, "symbol ID is an entry")
  t.eq(rt:resolve_entry(rel .. ":22"), { prefix .. "handle" }, "line maps to the enclosing function")
  local result = ast.outline({ prefix .. "handle" }, { root = root, cache_dir = t.cache })
  t.eq(result.tour.snippets[1].symbol, prefix .. "handle", "Python routes project into the shared outline")
  t.check(result.tour.snippets[1].main, "entry is on the main flow")
  t.check(ast.available(root .. "/" .. rel, prefix .. "handle"), "Python backend is enabled by default")

  local graph = require("code-tour.ast.codegraph").build(idx)
  local calls, contains, imports = false, false, false
  for _, e in ipairs(graph.links) do
    calls = calls or (e.source == prefix .. "handle" and e.target == "python:checkout.words.clean" and e.relation == "calls")
    contains = contains or (e.source == "file:" .. rel and e.target == prefix .. "handle" and e.relation == "contains")
    imports = imports or (e.source == "file:" .. rel and e.target == "python:checkout.words.clean" and e.relation == "imports")
  end
  t.check(calls and contains and imports, "symbol graph includes Python calls, imports and containment")
  vim.fn.writefile({ "def work():", "    return 1" }, root .. "/first.py")
  vim.fn.writefile({ "def work():", "    return 1" }, root .. "/second.py")
  for _ = 1, 2 do
    local fresh = t.index(root)
    t.eq(fresh:qualified_symbol("python", "first.work").id, "python:first.work", "identical content respects first module ID")
    t.eq(fresh:qualified_symbol("python", "second.work").id, "python:second.work", "identical content respects second module ID")
  end
end

t.finish("Python AST backend", test)
