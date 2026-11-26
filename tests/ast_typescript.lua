local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local t = dofile(here .. "/ast_common.lua")
local index = require("code-tour.ast.index")
if not (index.parser_available("typescript") and index.parser_available("tsx")) then
  print("MISSING PARSER: typescript/tsx (verification gap; install them to run the TypeScript AST tests)")
  return
end
local ast = require("code-tour.ast")
ast.setup({ languages = { "typescript" } })

local function test()
  local root = vim.fn.tempname() .. "-typescript"
  vim.fn.mkdir(root, "p")
  t.run({ "cp", "-r", here .. "/fixtures/typescript/.", root })
  t.run({ "git", "init", "-q" }, root)
  local idx = t.index(root)
  local function body(file, symbol)
    local facts = idx.resolver:resolve_file(file)
    t.check(facts and not facts.error, file .. " parses")
    return facts.bodies["typescript:" .. symbol]
  end

  local place = body("src/orders/service.ts", "src.orders.service.OrderService.place")
  t.eq(t.targets(t.site(place, "this.validate")), { "typescript:src.orders.service.OrderService.validate" },
    "this.member binds an arrow class field")
  t.eq(t.targets(t.site(place, "this.repository.save")),
    { "typescript:src.orders.repository.MemoryRepository.save" },
    "a constructor parameter property types the receiver, and the interface dispatches")
  t.eq(t.targets(t.site(place, "record")), { "typescript:src.lib.audit.audit" },
    "a tsconfig path alias reaches a JavaScript file")
  t.eq(t.targets(t.site(place, "format.receipt")), { "typescript:src.lib.format.receipt" }, "a namespace import")
  t.eq(t.site(place, "axios.post").unresolved, "library", "a package call is a library call")
  t.eq(t.site(place, "axios.post").receiver_type, "axios", "and names the package")

  local audit = body("src/lib/audit.js", "src.lib.audit.audit")
  t.eq(t.targets(t.site(audit, "local.write")), { "typescript:src.lib.audit.Log.write" },
    "a JavaScript local takes its type from new")

  local create = body("src/server.tsx", "src.server.create")
  t.eq(t.targets(t.site(create, "service.place")), { "typescript:src.orders.service.OrderService.place" },
    "a method on a constructed instance")
  t.eq(t.targets(t.site(create, "trace")), { "typescript:src.lib.audit.audit" }, "a renamed re-export")
  t.eq(t.targets(t.site(create, "receipt")), { "typescript:src.lib.format.receipt" }, "an export * barrel")
  t.eq(t.targets(t.site(create, "legacy.notify")), { "typescript:src.legacy.notify" }, "require with module.exports")
  t.eq(idx:symbol("typescript:src.server.create").entry, true, "an Express handler is an entry")
  local main = body("src/server.tsx", "src.server.$main")
  t.eq(#main.stmts, 3, "top-level code: the app, the route and listen")

  local outline = ast.outline({ "typescript:src.server.create" }, { root = root, cache_dir = vim.fn.tempname() })
  t.check(outline.outline and outline.outline:find("place", 1, true), "an AST tour outlines the flow")
  local by_line = ast.outline({ "src/orders/service.ts:10" }, { root = root, cache_dir = vim.fn.tempname() })
  t.check(by_line.outline ~= nil, "a source position starts a tour")

  local graph = ast.code_graph({ root = root, out = vim.fn.tempname(), cache_dir = vim.fn.tempname() })
  t.check(graph.nodes > 0 and graph.links > 0, "the project graph builds")
end

-- Scoping, imports, globals and typing cases, each a small project of its own.
local function resolution()
  local root = vim.fn.tempname() .. "-cases"
  local function write(rel, lines)
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. rel), "p")
    vim.fn.writefile(lines, root .. "/" .. rel)
  end
  -- `vector/index.ts` exports `vector`, and `vector/vector.ts` is a module of that dotted name
  write("src/vector/index.ts", { 'export * from "./vector";' })
  write("src/vector/vector.ts", { "export function vector() {}" })
  write("src/m.ts", {
    "export class Repo { scene: Repo; save() {} make(): Repo { return this; } }",
    "export const shared = new Repo();",
    "export function helper() {}",
    "export default function main() {}",
    'export type App = { repo: Repo };',
  })
  write("src/use.ts", {
    'import { vector } from "./vector";',
    'import * as m from "./m";',
    'import { Repo, helper, App } from "./m";',
    "export function a() { vector(); m.shared.save(); }",
    "export function b(items: any[]) {",
    "  helper();",
    "  for (const helper of items) { helper(); }",
    "  items.forEach((x) => { const r = new Repo(); r.save(); });",
    "}",
    'export function c({ repo }: App, other: App["repo"]) { repo.save(); other.save(); }',
    "export class S {",
    "  r: Repo;",
    "  go() { const { r } = this; r.save(); const { scene } = r; scene.save(); }",
    "}",
  })
  write("globals/lib.js", {
    "class Stack {",
    "  push() {}",
    "}",
    "const Hints = {",
    "  activate() { this.show(); },",
    "  show() { stack.push(); },",
    "};",
    "globalThis.stack = new Stack();",
    "Hints.activate();",
  })
  write("globals/main.js", { "function run() { Hints.activate(); globalThis.stack.push(); }" })
  t.run({ "git", "init", "-q" }, root)
  local idx = t.index(root)
  local function site(file, id, text, nth)
    local facts = idx.resolver:resolve_file(file)
    return t.site(facts.bodies["typescript:" .. id], text, nth)
  end
  local function binds(file, id, text, target, message, nth)
    t.eq(t.targets(site(file, id, text, nth)), target and { "typescript:" .. target } or {}, message)
  end
  binds("src/use.ts", "src.use.a", "vector", "src.vector.vector.vector", "a member is not the module of that name")
  binds("src/use.ts", "src.use.a", "m.shared.save", "src.m.Repo.save", "a namespace import of a module with a default")
  binds("src/use.ts", "src.use.b", "helper", "src.m.helper", "a block's const does not shadow outside it", 1)
  binds("src/use.ts", "src.use.b", "helper", nil, "and does shadow inside it", 2)
  binds("src/use.ts", "src.use.b", "r.save", "src.m.Repo.save", "a callback's own local is typed")
  binds("src/use.ts", "src.use.c", "repo.save", "src.m.Repo.save", "a destructured parameter is typed")
  binds("src/use.ts", "src.use.c", "other.save", "src.m.Repo.save", "an indexed access type")
  binds("src/use.ts", "src.use.S.go", "r.save", "src.m.Repo.save", "destructuring from this")
  binds("src/use.ts", "src.use.S.go", "scene.save", "src.m.Repo.save", "destructuring from a typed value")
  binds("globals/lib.js", "globals.lib.Hints.activate", "this.show", "globals.lib.Hints.show", "this in an object")
  binds("globals/lib.js", "globals.lib.Hints.show", "stack.push", "globals.lib.Stack.push", "a globalThis instance")
  binds("globals/main.js", "globals.main.run", "Hints.activate", "globals.lib.Hints.activate", "a script global")
  binds("globals/main.js", "globals.main.run", "globalThis.stack.push", "globals.lib.Stack.push", "through globalThis")
  local script = idx.resolver:resolve_file("globals/lib.js").bodies["typescript:globals.lib.$main"]
  t.eq(vim.tbl_map(function(s) return s.text end, script.sites), { "Stack", "Hints.activate" },
    "an object's methods are not also top-level code")
  local outline = ast.outline({ "Hints.activate" }, { root = root, cache_dir = vim.fn.tempname() })
  t.check(outline.outline and outline.outline:find("activate", 1, true), "Object.method names an entry")
end

-- A live tour: fill, keep, and withhold notes as the source changes.
local function live()
  vim.o.lines, vim.o.columns = 50, 140
  require("code-tour.instance").register = function() end
  require("code-tour.conversation").deliver = function(_, _, _, _, callback)
    if callback then callback(true) end
  end
  vim.notify = function() end
  local tour = require("tour")
  tour.setup({ keys = false, smooth_scroll = false, ast = { languages = { "typescript" } } })
  local root = vim.fn.tempname() .. "-live"
  vim.fn.mkdir(root, "p")
  t.run({ "cp", "-r", here .. "/fixtures/typescript/.", root })
  t.run({ "git", "init", "-q" }, root)
  local cache = vim.fn.tempname()
  local entry = "typescript:src.server.create"
  local function open()
    vim.cmd("silent! %bwipeout!")
    tour.ast_tour({ entries = { entry }, root = root, cache_dir = cache, overrides = {
      { kind = "route", from = entry, to = "typescript:src.orders.service.OrderService.place", level = 0 } } })
  end
  local function find(anchor)
    for _, stop in ipairs(tour.state().stops) do
      if stop.anchor == anchor then
        return stop
      end
    end
  end
  local function noted()
    return (find("n2").note or ""):find("Body two", 1, true) ~= nil
  end
  open()
  tour.fill("n2", "## overview\nPlaces it.\n\nBody two.")
  open()
  t.check(noted(), "a TypeScript note persists")
  local file = root .. "/src/orders/service.ts"
  local source = vim.fn.readfile(file)
  local function edit(from, to)
    vim.fn.writefile(vim.tbl_map(function(l) return (l:gsub(from, to)) end, source), file)
    open()
  end
  edit("this%.validate%(order%);", "this.validate( order ); // check")
  t.check(noted(), "formatting and comments keep it")
  edit('"empty order"', '"no order"')
  t.check(not noted(), "a code change makes it stale")
  vim.fn.writefile(source, file)
  open()
  t.check(noted(), "reverting restores it")
end

t.finish("TypeScript AST backend", function()
  test()
  resolution()
  live()
end)
