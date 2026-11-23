-- SPEC-ast-graph §5: every resolution rule with its confidence and `via`, and the
-- symbol graph's edges (§3.4).
--   nvim --clean --headless -l tests/ast_resolve.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

local P = "java:shop."

-- {symbol, confidence, via} of every target, with the common prefix dropped
local function bound(s)
  local out = {}
  for _, x in ipairs(s.targets or {}) do
    out[#out + 1] = { x.symbol:gsub("^java:shop%.", ""), x.confidence, x.via }
  end
  return out
end

t.finish("ast resolve", function()
  if not t.parser() then
    return
  end
  local root = t.project()
  local idx = t.index(root)
  local r = idx.resolver
  local svc = "shop/order/OrderService.java"
  local checkout = t.body(idx, svc, P .. "order.OrderService#checkout(Order)")
  local audit = t.body(idx, svc, P .. "order.OrderService#audit(List)")

  -- §5.1 in-file binding: EXTRACTED
  eq(bound(t.site(checkout, "failed")), { { "order.OrderService#failed(String)", "EXTRACTED", "this" } },
    "bare call binds to the enclosing type")
  eq(bound(t.site(audit, "this::log")), { { "order.OrderService#log(Order)", "EXTRACTED", "this" } },
    "method reference on this")
  local stats = t.body(idx, "shop/util/Stats.java", P .. "util.Stats#factorial(int)")
  eq(bound(t.site(stats, "factorial")), { { "util.Stats#factorial(int)", "EXTRACTED", "this" } }, "recursion")
  local summary = t.body(idx, svc, P .. "order.OrderService.Receipt#summary()")
  eq(bound(t.site(summary, "processed")), { { "order.OrderService#processed()", "EXTRACTED", "this" } },
    "Outer.this gives the outer type")
  local failed = t.body(idx, svc, P .. "order.OrderService#failed(String)")
  eq(bound(t.site(failed, "new Receipt")), { { "order.OrderService.Receipt#Receipt(String,Money)", "EXTRACTED",
    "package" } }, "nested type of the enclosing type; new resolves to the constructor")

  -- §5.2 receivers, across files: still EXTRACTED when declared types prove them (§3.4)
  eq(bound(t.site(checkout, "order.total")), { { "order.Order#total()", "EXTRACTED", "param" } }, "parameter receiver")
  eq(bound(t.site(checkout, "discounts.apply")), { { "discount.DiscountPolicy#apply(Order,Money)", "EXTRACTED",
    "field" } }, "field receiver, type from a single-type import")
  local total = t.body(idx, "shop/order/Order.java", P .. "order.Order#total()")
  eq(bound(t.site(total, "sum.plus")), { { "money.Money#plus(Money)", "EXTRACTED", "local" } }, "local receiver")
  eq(bound(t.site(total, "line.subtotal")), { { "order.Line#subtotal()", "EXTRACTED", "local" } },
    "for-each variable typed by its declaration")
  eq(bound(t.site(total, "Money.zero")), { { "money.Money#zero()", "EXTRACTED", "static" } }, "type name: a static call")
  local osum = t.body(idx, "shop/order/Order.java", P .. "order.Order#summary()")
  eq(bound(t.site(osum, "format")), { { "money.Money#format()", "EXTRACTED", "chain" } },
    "call receiver: the callee's declared return type")
  eq(bound(t.site(audit, "copy.total")), { { "order.Order#total()", "EXTRACTED", "local" } }, "var typed by new")
  eq(bound(t.site(audit, "first.markPaid")), { { "order.Order#markPaid()", "EXTRACTED", "local" } }, "cast")
  local card = t.body(idx, "shop/payment/CardGateway.java", P .. "payment.CardGateway#label()")
  eq(bound(t.site(card, "super.name")), { { "payment.BaseGateway#name()", "EXTRACTED", "super" } }, "super")
  local apply = t.body(idx, "shop/discount/DiscountPolicy.java", P .. "discount.DiscountPolicy#apply(Order,Money)")
  eq(bound(t.site(apply, "max")), { { "util.Stats#max(int,int)", "EXTRACTED", "static" } },
    "static single import; a project method named max keeps its caller")
  eq(t.site(apply, "Math.max").unresolved, "builtin", "Math.max is the platform's")
  eq(t.site(apply, "size").unresolved, "builtin", "imported java.util type counts as built-in")

  -- type-name rules
  local ctx = { facts = t.facts(idx, svc), type = idx:symbol(P .. "order.OrderService") }
  local function ty(name, c)
    local x = r:type_name(name, c or ctx)
    return { x.kind, x.sym and x.sym.qname or x.name, x.via, x.heuristic }
  end
  eq(ty("Receipt"), { "project", "shop.order.OrderService.Receipt", "package" }, "rule 2: nested type")
  eq(ty("DiscountPolicy"), { "project", "shop.discount.DiscountPolicy", "import" }, "rule 3: single-type import")
  eq(ty("Order"), { "project", "shop.order.Order", "package" }, "rule 4: same package")
  eq(ty("CardGateway"), { "project", "shop.payment.CardGateway", "import" }, "rule 5: wildcard import")
  eq(ty("String"), { "builtin", "String" }, "rule 6: built-in")
  eq(ty("List"), { "builtin", "List" }, "imported platform type is built-in")
  eq(ty("Stats"), { "project", "shop.util.Stats", "package", true }, "rule 7: unique project name, heuristic")
  eq(ty("Nowhere"), { "library", "Nowhere" }, "rule 8: unknown name is a library type")
  local larger = idx:symbol(P .. "util.Stats#larger(T,T)")
  local sctx = { facts = t.facts(idx, "shop/util/Stats.java"), type = idx:symbol(P .. "util.Stats"), method = larger }
  eq(ty("T", sctx)[1], "generic", "rule 1: type parameter")
  local catalog = t.facts(idx, "shop/catalog/Catalog.java")
  local cctx = { facts = catalog, type = idx:symbol(P .. "catalog.Catalog") }
  eq(ty("Money", cctx), { "library", "com.vendor.Money" },
    "package check: an import binds only to a type declared in that package")
  local combos = catalog.bodies[P .. "catalog.Catalog#combos(int)"]
  eq(bound(t.site(combos, "Stats.factorial")), { { "util.Stats#factorial(int)", "INFERRED", "static" } },
    "unique-name type binds, INFERRED")
  local price = catalog.bodies[P .. "catalog.Catalog#price(Money)"]
  eq(t.site(price, "price.render").unresolved, "library", "library receiver stays unresolved")

  -- members: class wins, overloads, varargs, constructors, accessors
  local charge = t.body(idx, "shop/payment/CardGateway.java", P .. "payment.CardGateway#charge(Money)")
  eq(bound(t.site(charge, "this.log")), { { "payment.BaseGateway#log(String)", "EXTRACTED", "this" } },
    "superclass chain beats the interface default")
  eq(bound(t.site(apply, "formatter.format", 1)), { { "util.Formatter#format(Money)", "EXTRACTED", "field" } },
    "overload chosen by a typed argument")
  eq(t.targets(t.site(apply, "formatter.format", 2)), { P .. "util.Formatter#format(String)" }, "string literal")
  eq(t.targets(t.site(apply, "formatter.format", 3)), { P .. "util.Formatter#format(int)" }, "int local")
  eq(t.targets(t.site(apply, "formatter.format", 4)), { P .. "util.Formatter#format(String)" },
    "argument typed by its call's return type")
  local tie = t.body(idx, "shop/util/Formatter.java", P .. "util.Formatter#tie(Object)")
  local amb = t.site(tie, "format")
  eq(#amb.targets, 3, "unknown argument type keeps every overload")
  check(vim.iter(amb.targets):all(function(x) return x.confidence == "AMBIGUOUS" end), "tie is AMBIGUOUS")
  eq(t.targets(t.site(price, "formatter.join")), { P .. "util.Formatter#join(String...)" }, "varargs arity")
  local ctor = t.body(idx, "shop/payment/CardGateway.java", P .. "payment.CardGateway#CardGateway()")
  eq(bound(t.site(ctor, "this")), { { "payment.CardGateway#CardGateway(HttpClient)", "EXTRACTED", "this" } }, "this(...)")
  local ctor2 = t.body(idx, "shop/payment/CardGateway.java", P .. "payment.CardGateway#CardGateway(HttpClient)")
  local sup = t.site(ctor2, "super")
  check(#sup.targets == 0 and sup.references == P .. "payment.BaseGateway",
    "super() on a class without constructors: a reference, not a call")
  local made = t.site(charge, "new ChargeResult")
  check(#made.targets == 0 and made.references == P .. "payment.ChargeResult", "new without a declared constructor")
  local ok = t.site(checkout, "result.ok")
  eq({ ok.kind, ok.references, #ok.targets }, { "accessor", P .. "payment.ChargeResult#ok", 0 },
    "record accessor is a component read")
  eq(bound(t.site(checkout, "result.message")), { { "payment.ChargeResult#message()", "EXTRACTED", "local" } },
    "explicitly declared accessor is an ordinary method")
  local describe = t.body(idx, "shop/order/Line.java", P .. "order.Line#describe()")
  eq(t.site(describe, "item").kind, "accessor", "bare accessor inside the record")

  -- §5.3 built-ins and fallbacks
  eq(bound(t.site(audit, "line.describe")), {}, "untyped lambda parameter: never bound by bare name")
  eq(t.site(audit, "line.describe").unresolved, "dynamic", "untyped lambda parameter stays unresolved")
  eq(t.site(audit, "line.size").unresolved, "dynamic", "stoplisted name stays unresolved")
  local email = t.body(idx, "shop/notify/EmailNotifier.java", P .. "notify.EmailNotifier#send(String,String)")
  eq(t.site(email, "System.out.println").unresolved, "builtin", "System.out is built-in")
  local larger_body = t.body(idx, "shop/util/Stats.java", P .. "util.Stats#larger(T,T)")
  eq(t.site(larger_body, "a.compareTo").unresolved, "generic", "generic receiver")

  -- §5.4 dispatch
  local gw = t.site(checkout, "gateway.charge")
  eq(bound(gw), { { "payment.CardGateway#charge(Money)", "INFERRED", "dispatch" } }, "one implementation")
  eq(gw.declared.symbol, P .. "payment.PaymentGateway#charge(Money)", "declared target kept")
  eq(bound(t.site(checkout, "notifier.send")), {
    { "notify.EmailNotifier#send(String,String)", "INFERRED", "dispatch" },
    { "notify.SmsNotifier#send(String,String)", "INFERRED", "dispatch" },
  }, "two implementations")

  -- §3.4 edges
  local function edges(rel)
    return r:edges(t.java .. rel)
  end
  local function has(list, source, target, relation, context)
    for _, e in ipairs(list) do
      if e.source == source and e.target == target and e.relation == relation
          and (context == nil or e.context == context) then
        return e
      end
    end
  end
  local cg = edges("shop/payment/CardGateway.java")
  check(has(cg, P .. "payment.CardGateway", P .. "payment.BaseGateway", "inherits"), "inherits")
  check(has(cg, P .. "payment.CardGateway", P .. "payment.PaymentGateway", "implements"), "implements")
  check(has(cg, P .. "payment.CardGateway#charge(Money)", P .. "payment.PaymentGateway#charge(Money)", "overrides"),
    "overrides")
  check(has(cg, "file:" .. t.java .. "shop/payment/CardGateway.java", P .. "payment.CardGateway", "contains"), "contains")
  check(has(cg, P .. "payment.CardGateway", P .. "payment.CardGateway#charge(Money)", "method"), "method")
  check(has(cg, P .. "payment.CardGateway", P .. "payment.CardGateway#http", "field"), "field")
  check(has(cg, P .. "payment.CardGateway#charge(Money)", P .. "payment.ChargeResult", "references", "new"),
    "references: new")
  local se = edges("shop/order/OrderService.java")
  check(has(se, "file:" .. t.java .. svc, P .. "discount.DiscountPolicy", "imports"), "imports")
  check(has(se, P .. "order.OrderService#checkout(Order)", P .. "order.Order", "references", "param"), "param")
  check(has(se, P .. "order.OrderService#checkout(Order)", P .. "order.OrderService.Receipt", "references", "return"),
    "return")
  check(has(se, P .. "order.OrderService#checkout(Order)", P .. "payment.ChargeResult", "references", "local"), "local")
  check(has(se, P .. "order.OrderService", P .. "payment.PaymentGateway", "references", "field"), "field type")
  check(has(se, P .. "order.OrderService#audit(List)", P .. "order.Order", "references", "cast"), "cast")
  check(has(se, P .. "order.OrderService#checkout(Order)", P .. "payment.ChargeResult#ok", "references", "accessor"),
    "accessor")
  check(has(edges("shop/order/Order.java"), P .. "order.Order#total()", P .. "money.Money", "references", "static"),
    "static")
  local calls = vim.tbl_filter(function(e)
    return e.relation == "calls" and e.source == P .. "order.OrderService#checkout(Order)"
  end, se)
  local getters = vim.tbl_filter(function(e) return e.target == P .. "order.Order#getCustomer()" end, calls)
  eq(#getters, 1, "each site is its own calls edge")
  local keys = {}
  for _, e in ipairs(calls) do
    keys[e.key] = (keys[e.key] or 0) + 1
  end
  eq(keys.s13, 3, "a dispatched site: one calls edge per implementation and one to the declared method")
  local rcpt = t.body(idx, svc, P .. "order.OrderService#receipt(Order,Money)")
  local repeat_calls = vim.tbl_filter(function(e)
    return e.relation == "calls" and e.target == P .. "order.Order#getCustomer()"
  end, se)
  check(#repeat_calls >= 3 and rcpt, "repeated calls to one target stay separate edges")

  -- Regressions found in review: a second, inline project ---------------------
  local edge = vim.fn.tempname() .. "-edge"
  local files = {
    ["com/acme/util/Util.java"] = {
      "package com.acme.util;",
      "public class Util {",
      "  public static int compute(int x) { return x; }",
      "  public static void log() { }",
      "}",
    },
    ["app/Handler.java"] = { "package app;", "public interface Handler<T> { void handle(T item); }" },
    ["app/Item.java"] = { "package app;", "public class Item { public int size() { return 1; } }" },
    ["app/ItemHandler.java"] = {
      "package app;",
      "public class ItemHandler implements Handler<Item> { public void handle(Item item) { item.size(); } }",
    },
    ["app/Base.java"] = { "package app;", "public class Base { public void m() { } }" },
    ["app/Shape.java"] = { "package app;", "public interface Shape { double area(); default String hi() { return \"\"; } }" },
    ["app/Circle.java"] = { "package app;", "public class Circle implements Shape { public double area() { return 1; } }" },
    ["app/Sq.java"] = { "package app;", "public class Sq implements Shape { public double area() { return 2; } public int s() { return 1; } }" },
    ["app/Failure.java"] = { "package app;", "public class Failure extends RuntimeException { void own() { } }" },
    ["app/Pair.java"] = { "package app;", "public record Pair(int left, int right) { }" },
    ["app/Op.java"] = {
      "package app;",
      "public enum Op {",
      "  ADD { int apply(int a) { return twice(a); } };",
      "  abstract int apply(int a);",
      "  int twice(int a) { return a * 2; }",
      "}",
    },
    ["app/Repo.java"] = { "package app;", "public interface Repo { Item find(int id); }" },
    ["app/Jobs.java"] = {
      "package app;",
      "import java.util.List;",
      "public class Jobs {",
      "  Repo repo;",
      "  void go(List<Item> items, Item seed) {",
      "    Runnable r = new Runnable() { public void run() { helper(); seed.size(); } void helper() { } };",
      "    Shape s = new Shape() { public double area() { return 3; } };",
      "    class Counter { int count(Item i) { return i.size(); } }",
      "    new Counter().count(seed);",
      "    items.forEach(i -> i.size());",
      "    Runnable later = () -> seed.size();",
      "    s.area();",
      "    Op.ADD.apply(1);",
      "    repo.find(1);",
      "  }",
      "}",
    },
    ["app/App.java"] = {
      "package app;",
      "import java.util.List;",
      "public class App extends Base implements Shape {",
      "  public double area() { return 0; }",
      "  public void m() { }",
      "  void run(Handler<Item> h, Item item, Shape any, Object o, int k, String... names) {",
      "    h.handle(item);",
      "    com.acme.util.Util.compute(1);",
      "    com.acme.util.Util.log();",
      "    Object list = new java.util.ArrayList<String>();",
      "    this.<String>pick(\"a\");",
      "    class L { void g(Sq any) { any.s(); } }",
      "    double d = switch (o) { case Circle c -> c.area(); case Sq q when q.s() > 1 -> 1; default -> 0; };",
      "    switch (k) { case 1: Sq w = new Sq(); break; case 2: w = null; w.s(); break; default: }",
      "    names.clone();",
      "    log();",
      "    new Failure().getMessage();",
      "  }",
      "  class Inner { void up() { App.super.m(); Shape.super.hi(); } }",
      "  <T> T pick(T t) { return t; }",
      "  <T> void each(T t) { t.uniqueThing(); }",
      "  void log() { }",
      "  void log(String... xs) { }",
      "}",
      "class Other { void uniqueThing() { } }",
    },
    ["app/Lombok.java"] = {
      "package app;",
      "import lombok.Builder; import lombok.Getter; import lombok.val;",
      "@Builder @Getter",
      "public class Person {",
      "  private String name; private boolean active;",
      "  public static void use() { Person p = Person.builder().name(\"x\").active(true).build(); p.getName(); p.isActive(); }",
      "  public static void viaVal() { val p = Person.builder().build(); p.getName(); var q = Person.builder().build(); q.isActive(); }",
      "  public String name(String other) { return other; }",
      "}",
    },
  }
  for rel, lines in pairs(files) do
    local path = edge .. "/src/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(lines, path)
  end
  t.run({ "git", "init", "-q" }, edge)
  t.run({ "git", "add", "-A" }, edge)
  local e = t.index(edge)
  local run = assert(e.resolver:resolve_file("src/app/App.java")).bodies["java:app.App#run(Handler,Item,Shape,Object,int,String...)"]
  eq(bound(t.site(run, "h.handle")), { { "java:app.ItemHandler#handle(Item)", "INFERRED", "dispatch" } },
    "dispatch through a generic interface parameter")
  check(has(e.resolver:edges("src/app/ItemHandler.java"), "java:app.ItemHandler#handle(Item)", "java:app.Handler#handle(T)",
    "overrides"), "overrides through a type variable")
  eq(t.targets(t.site(run, "compute")), { "java:com.acme.util.Util#compute(int)" }, "fully qualified static call")
  eq(t.site(run, "compute").targets[1].via, "static", "qualified call is static")
  eq(t.targets(t.site(run, "log", 1)), { "java:com.acme.util.Util#log()" }, "fully qualified void call")
  local made = t.site(run, "new java.util.ArrayList")
  eq(made.range, { start = { 9, 18 }, ["end"] = { 9, 41 } }, "new badge text matches its range")
  eq(made.unresolved, "builtin", "fully qualified platform type is built-in")
  eq(t.site(run, "pick").range, { start = { 10, 17 }, ["end"] = { 10, 21 } }, "explicit type arguments: name only")
  local appf = e.resolver:resolve_file("src/app/App.java")
  local local_g = appf.bodies["java:app.App$1L#g(Sq)"]
  check(local_g, "a local class is a symbol Outer$1Name with its own bodies")
  eq(t.targets(t.site(local_g, "any.s")), { "java:app.Sq#s()" }, "local class parameter shadows the method's")
  eq(appf.symbols["java:app.App$1L"].enclosing_body, run.symbol, "local class records its enclosing body")
  eq(t.targets(t.site(run, "c.area")), { "java:app.Circle#area()" }, "switch pattern variable is typed")
  eq(t.targets(t.site(run, "q.s")), { "java:app.Sq#s()" }, "switch guard is visited")
  eq(t.targets(t.site(run, "w.s")), { "java:app.Sq#s()" }, "statement groups of one switch share a scope")
  eq(t.site(run, "names.clone").unresolved, "builtin", "varargs parameter is an array")
  eq(t.targets(t.site(run, "log", 2)), { "java:app.App#log()" }, "fixed arity beats varargs")
  eq(t.site(run, "getMessage").unresolved, "builtin", "member of a platform superclass is built-in")
  local inner = e.resolver:resolve_file("src/app/App.java").bodies["java:app.App.Inner#up()"]
  local outer_super = t.site(inner, "App.super.m")
  eq(bound(outer_super), { { "java:app.Base#m()", "EXTRACTED", "super" } }, "Outer.super.m() reaches the superclass")
  eq(outer_super.range, { start = { 18, 28 }, ["end"] = { 18, 39 } }, "Outer.super badge range")
  eq(t.targets(t.site(inner, "Shape.super.hi")), { "java:app.Shape#hi()" }, "Interface.super.m()")
  local each = e.resolver:resolve_file("src/app/App.java").bodies["java:app.App#each(T)"]
  eq(bound(t.site(each, "t.uniqueThing")), {}, "generic receiver is not bound by bare name")
  eq(t.site(each, "t.uniqueThing").unresolved, "generic", "generic receiver stays unresolved")
  -- generated members (ast/synth.lua): resolved by receiver type, never by bare name
  local person = e.resolver:resolve_file("src/app/Lombok.java")
  local use = person.bodies["java:app.Person#use()"]
  eq(t.targets(t.site(use, "Person.builder")), { "java:app.Person#builder()" }, "@Builder gives a static builder()")
  eq(t.targets(t.site(use, "name")), { "java:app.Person.PersonBuilder#name(String)" },
    "a builder setter binds to the builder, not the unrelated Person#name(String)")
  eq(t.targets(t.site(use, "active")), { "java:app.Person.PersonBuilder#active(boolean)" }, "chained builder setter")
  eq(t.targets(t.site(use, "build")), { "java:app.Person.PersonBuilder#build()" }, "build() binds on the builder")
  eq(t.targets(t.site(use, "p.getName")), { "java:app.Person#getName()" }, "@Getter accessor")
  eq(t.targets(t.site(use, "p.isActive")), { "java:app.Person#isActive()" }, "@Getter boolean accessor")
  local via_val = person.bodies["java:app.Person#viaVal()"]
  eq(t.targets(t.site(via_val, "p.getName")), { "java:app.Person#getName()" }, "val takes its type from the initializer")
  eq(t.targets(t.site(via_val, "q.isActive")), { "java:app.Person#isActive()" }, "var takes its type from the initializer")
  check(person.symbols["java:app.Person#getName()"].synthetic == "Getter", "generated members are marked synthetic")
  -- configured boundary: a call the language cannot follow continues at a project symbol
  local ast_options = require("code-tour.ast").options
  ast_options.boundaries = { { call = "Other.nothing", to = "java:app.Other#uniqueThing()" } }
  local fresh = t.index(edge)
  local not_matched = fresh.resolver:resolve_file("src/app/App.java").bodies["java:app.App#each(T)"]
  eq(t.site(not_matched, "t.uniqueThing").unresolved, "generic", "a rule for another call does not claim this one")
  ast_options.boundaries = { { call = "uniqueThing", to = "java:app.Other#uniqueThing()" } }
  local hopped = t.index(edge).resolver:resolve_file("src/app/App.java").bodies["java:app.App#each(T)"]
  eq(bound(t.site(hopped, "t.uniqueThing")), { { "java:app.Other#uniqueThing()", "INFERRED", "boundary" } },
    "a configured boundary binds an otherwise unresolved call")
  ast_options.boundaries = {}
  local pair = e:facts("src/app/Pair.java")
  local acc = pair.symbols["java:app.Pair#left()"]
  check(acc and acc.implicit and acc.accessor == "java:app.Pair#left", "implicit accessor symbol for a component")
  -- decision 6: local and anonymous classes are symbols; lambdas name their call
  local jobs = e.resolver:resolve_file("src/app/Jobs.java")
  local go = jobs.bodies["java:app.Jobs#go(List,Item)"]
  local runnable = t.site(go, "new Runnable")
  eq(runnable.anonymous, "java:app.Jobs$1", "anonymous class is the symbol Outer$1")
  local run_body = jobs.bodies["java:app.Jobs$1#run()"]
  eq(bound(t.site(run_body, "helper")), { { "java:app.Jobs$1#helper()", "EXTRACTED", "this" } },
    "bare call inside an anonymous class binds to its own member")
  eq(bound(t.site(run_body, "seed.size")), { { "java:app.Item#size()", "EXTRACTED", "param" } },
    "captured parameter of the enclosing method")
  eq(t.site(run_body, "seed.size").receiver.local_body, go.symbol, "captured local names its body")
  check(not pcall(t.site, go, "helper"), "the anonymous class's sites are not the enclosing method's")
  local shape_impls = t.targets(t.site(go, "s.area"))
  check(vim.tbl_contains(shape_impls, "java:app.Jobs$2#area()"), "an anonymous class implements its interface")
  eq(bound(t.site(go, "count")), { { "java:app.Jobs$1Counter#count(Item)", "EXTRACTED", "chain" } },
    "a local class is in scope in its block")
  eq(t.targets(t.site(go, "Op.ADD.apply")), { "java:app.Op$1#apply(int)" }, "enum constant body overrides")
  local op = e.resolver:resolve_file("src/app/Op.java")
  eq(op.symbols["java:app.Op#ADD"].body_type, "java:app.Op$1", "enum constant names its body class")
  eq(bound(t.site(op.bodies["java:app.Op$1#apply(int)"], "twice")), { { "java:app.Op#twice(int)", "EXTRACTED", "this" } },
    "enum constant body inherits the enum's members")
  local each_call = t.site(go, "items.forEach")
  eq(t.site(go, "i.size").deferred, { kind = "lambda", call = each_call.id, arg = 1 },
    "a lambda's sites name the call it is passed to")
  eq(t.site(go, "seed.size").deferred, { kind = "lambda" }, "a stored lambda's sites name no call")
  -- decision 4: an interface method with no implementation in the project
  local find = t.site(go, "repo.find")
  eq({ #find.targets, find.unresolved, find.declared.symbol }, { 0, "abstract", "java:app.Repo#find(int)" },
    "no implementation: no target, unresolved abstract, declared kept")
  local declared_edge = has(e.resolver:edges("src/app/Jobs.java"), go.symbol, "java:app.Repo#find(int)", "calls")
  eq(declared_edge and declared_edge.via, "declared", "the export still links the call to the declared method")

  -- a file git is told not to watch: its changes must not be cached under the old SHA
  t.run({ "git", "-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-qm", "edge" }, edge)
  t.run({ "git", "update-index", "--assume-unchanged", "src/app/Item.java" }, edge)
  vim.fn.writefile({ "package app;", "public class Item { public int size() { return 1; } void extra() { } }" },
    edge .. "/src/app/Item.java")
  local watched = t.index(edge)
  check(watched:facts("src/app/Item.java").symbols["java:app.Item#extra()"], "assume-unchanged file is re-hashed")
end)
