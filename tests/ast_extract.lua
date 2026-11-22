-- SPEC-ast-graph §4: both extraction passes, and the project index (§4.3).
--   nvim --clean --headless -l tests/ast_extract.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast extract", function()
  if not t.parser() then
    return
  end
  local java = require("code-tour.ast.lang.java")
  local ast = require("code-tour.ast")
  local root = t.project()
  local idx = t.index(root)
  local svc = t.java .. "shop/order/OrderService.java"

  -- Pass 1: declarations ------------------------------------------------------
  local facts = assert(idx:facts(svc))
  eq(facts.package, "shop.order", "package")
  eq(facts.imports.single.DiscountPolicy, "shop.discount.DiscountPolicy", "single import")
  eq(facts.imports.wildcard, { "shop.payment" }, "wildcard import")
  local dp = idx:facts(t.java .. "shop/discount/DiscountPolicy.java")
  eq(dp.imports.static_single.max, { "shop.util.Stats" }, "static single import")
  local service = facts.symbols["java:shop.order.OrderService"]
  eq(service.kind, "class", "class kind")
  check(facts.symbols["file:" .. svc].kind == "file", "file symbol")
  local inner = facts.symbols["java:shop.order.OrderService.Receipt"]
  eq(inner.outer, service.id, "nested type id and outer")
  eq(service.nested.Receipt, inner.id, "nested type table")
  eq(facts.names.Receipt, { inner.id, "java:shop.order.OrderService.Receipt#Receipt(String,Money)" },
    "declaration table holds every name declared in the file")
  local gateway = facts.symbols["java:shop.order.OrderService#gateway"]
  eq({ gateway.kind, gateway.type.name }, { "field", "PaymentGateway" }, "field with declared type")
  local checkout = facts.symbols["java:shop.order.OrderService#checkout(Order)"]
  eq({ checkout.kind, checkout.returns, checkout.label }, { "method", "Receipt", "OrderService.checkout(Order)" },
    "method symbol")
  eq(checkout.signature, "public Receipt checkout(Order order)", "signature up to the body")
  check(facts.symbols["java:shop.order.OrderService#audit(List)"], "parameter ids drop generics")
  check(facts.symbols["java:shop.order.OrderService#OrderService(PaymentGateway,DiscountPolicy,Notifier)"],
    "constructor id")
  local fmt = idx:facts(t.java .. "shop/util/Formatter.java")
  local join = fmt.symbols["java:shop.util.Formatter#join(String...)"]
  check(join and join.varargs, "varargs spelled with ...")
  local pg = idx:facts(t.java .. "shop/payment/PaymentGateway.java")
  eq(pg.symbols["java:shop.payment.PaymentGateway"].kind, "interface", "interface kind")
  check(pg.symbols["java:shop.payment.PaymentGateway#charge(Money)"].abstract, "interface method without body is abstract")
  check(not pg.symbols["java:shop.payment.PaymentGateway#log(String)"].abstract, "default method has a body")
  local line = idx:facts(t.java .. "shop/order/Line.java")
  local rec = line.symbols["java:shop.order.Line"]
  eq(rec.kind, "record", "record kind")
  eq(vim.tbl_map(function(c) return c.name end, rec.components), { "item", "quantity", "price" }, "record components")
  eq(line.symbols["java:shop.order.Line#price"].type.name, "Money", "component is a typed field")
  local card = idx:facts(t.java .. "shop/payment/CardGateway.java").symbols["java:shop.payment.CardGateway"]
  eq({ card.extends[1].name, card.implements[1].name }, { "BaseGateway", "PaymentGateway" }, "extends and implements names")
  local stats = idx:facts(t.java .. "shop/util/Stats.java")
  eq(stats.symbols["java:shop.util.Stats#larger(T,T)"].type_params, { "T" }, "method type parameters")

  -- Pass 2: scoped locals -----------------------------------------------------
  local body = facts.bodies[checkout.id]
  local function find_local(b, name, nth)
    nth = nth or 1
    for _, l in ipairs(b.locals) do
      if l.name == name then
        nth = nth - 1
        if nth == 0 then
          return l
        end
      end
    end
  end
  local order = find_local(body, "order")
  eq({ order.kind, order.type }, { "param", "Order" }, "parameter is a scoped name")
  local discounted = find_local(body, "discounted")
  eq({ discounted.kind, discounted.type }, { "local", "Money" }, "typed local")
  eq(#discounted.definitions, 1, "local definition from its initializer")
  eq(discounted.definitions[1].sites, { "s6" }, "definition records the sites in its expression")
  local charge = t.site(body, "gateway.charge")
  local use_in_charge, use_in_receipt
  for _, u in ipairs(discounted.uses) do
    if u.site == charge.id then
      use_in_charge = u
    elseif u.site == t.site(body, "receipt").id then
      use_in_receipt = u
    end
  end
  eq(use_in_charge and use_in_charge.arg, 1, "use passed as first argument")
  check(use_in_receipt and use_in_receipt.arg == 2 and use_in_receipt.returned, "use passed to a returned call")
  local total_body = idx:facts(t.java .. "shop/order/Order.java").bodies["java:shop.order.Order#total()"]
  local sum = find_local(total_body, "sum")
  eq(#sum.definitions, 2, "initializer and later assignment are both definitions")
  local loop_var = find_local(total_body, "line")
  eq({ loop_var.kind, loop_var.type, loop_var.subject }, { "for", "Line", "lines" }, "for-each variable typed and scoped")
  local loop_site = t.site(total_body, "line.subtotal")
  eq(loop_site.receiver["local"], loop_var.index, "site inside the loop binds the loop variable")
  local returned = false
  for _, u in ipairs(sum.uses) do
    returned = returned or u.returned == true
  end
  check(returned, "use in a return statement")
  local audit = facts.bodies["java:shop.order.OrderService#audit(List)"]
  local first_line, second_line = find_local(audit, "line", 1), find_local(audit, "line", 2)
  check(first_line and second_line and first_line.index ~= second_line.index, "two lambdas declare separate locals")
  eq({ first_line.kind, first_line.type }, { "lambda", nil }, "untyped lambda parameter")
  eq(t.site(audit, "line.size").receiver["local"], second_line.index, "innermost declaration in scope wins")
  local copy = find_local(audit, "copy")
  check(copy.var and copy.infer and copy.infer.k == "new" and copy.infer.type == "Order", "var takes its initializer")

  -- Pass 2: sites -------------------------------------------------------------
  eq(charge.range, { start = { 30, 30 }, ["end"] = { 30, 44 } }, "badge range covers receiver and name")
  eq(charge.receiver, { k = "id", name = "gateway" }, "id receiver descriptor (a field, not a local)")
  local message, failed = t.site(body, "result.message"), t.site(body, "failed")
  check(message.order < failed.order, "evaluation order: argument before call")
  check(t.site(body, "order.getCustomer").order < t.site(body, "notifier.send").order, "f(g(x)): g first")
  local empty = t.site(body, "isEmpty")
  eq(empty.receiver, { k = "call", site = t.site(body, "order.getLines").id, name = "getLines", arity = 0 },
    "chained receiver names its inner site")
  eq(t.site(body, "new IllegalStateException").kind, "new", "constructor call site")
  local ref = t.site(audit, "this::log")
  eq({ ref.kind, ref.receiver.k, ref.name }, { "method_ref", "this", "log" }, "method reference")
  check(t.site(audit, "line.describe").deferred, "sites in a lambda are marked deferred")
  check(not charge.deferred, "ordinary sites are not deferred")
  local cg = idx:facts(t.java .. "shop/payment/CardGateway.java")
  local ctor = cg.bodies["java:shop.payment.CardGateway#CardGateway()"]
  eq(t.site(ctor, "this").kind, "this()", "this(...) site")
  eq(t.site(cg.bodies["java:shop.payment.CardGateway#CardGateway(HttpClient)"], "super").kind, "super()", "super(...) site")
  local summary = facts.bodies["java:shop.order.OrderService.Receipt#summary()"]
  eq(t.site(summary, "processed").receiver, { k = "this", outer = "OrderService" }, "Outer.this receiver")
  local inits = facts.bodies["java:shop.order.Order"]
  check(inits == nil, "Order's field initializer lives in Order.java")
  local order_facts = idx:facts(t.java .. "shop/order/Order.java")
  check(order_facts.bodies["java:shop.order.Order"].sites[1].initializer, "field initializer sites belong to the type")
  eq(t.site(stats.bodies["java:shop.util.Stats#factorial(int)"], "factorial").receiver, { k = "implicit" },
    "bare call")

  -- Pass 2: statement trees and metrics ---------------------------------------
  local kinds = vim.tbl_map(function(s) return s.kind end, body.stmts)
  eq(kinds, { "if_statement", "if_statement", "local_variable_declaration", "local_variable_declaration",
    "local_variable_declaration", "if_statement", "expression_statement", "expression_statement",
    "expression_statement", "return_statement" }, "top-level statements of checkout")
  check(body.stmts[1].guard and body.stmts[2].guard, "if whose consequence only throws/returns is a guard")
  check(body.stmts[3].blank_before and not body.stmts[4].blank_before, "blank line before a statement")
  eq(body.stmts[3].locals, { "total" }, "statement records the locals it declares")
  eq(body.stmts[1].arms[1].name, "then", "if arm")
  eq(body.stmts[8].field_writes, { { object = "this", name = "processed" } }, "field write by update")
  eq(body.stmts[2].sites, { "s3", "s4" }, "statement sites")
  eq(body.metrics, { lines = 19, statements = 13, branches = 3, loops = 0, sites = 14, project_sites = 0,
    field_writes = 1, throws = 1 }, "metrics from pass 2")
  idx.resolver:resolve_file(svc)
  -- every site but new IllegalStateException, isEmpty (built-ins) and result.ok (an accessor)
  eq(body.metrics.project_sites, 11, "project_sites filled by resolution")

  local src = table.concat({
    "class T {",
    "  int run(java.util.List<String> xs, int k) {",
    "    // read the first",
    "    try (var in = open()) {",
    "      in.read();",
    "    } catch (IllegalStateException e) {",
    "      e.printStackTrace();",
    "      throw e;",
    "    } finally {",
    "      done();",
    "    }",
    "    switch (k) {",
    "      case 1 -> one();",
    "      default -> { two(); }",
    "    }",
    "    for (String x : xs) { if (x.isEmpty()) continue; use(x); }",
    "    if (k > 0) { return 1; } else { return 2; }",
    "  }",
    "}",
  }, "\n")
  local tf = java.extract("T.java", src)
  local tb = tf.bodies["java:T#run(List,int)"]
  local try = tb.stmts[1]
  check(try.comment_before, "leading comment recorded")
  eq(vim.tbl_map(function(a) return a.name end, try.arms), { "body", "catch", "finally" }, "try arms")
  eq(try.arms[2].range.start, { 5, 6 }, "catch arm starts at its header")
  eq(find_local(tb, "e").type, "IllegalStateException", "catch parameter typed")
  eq(find_local(tb, "e").scope.start, { 5, 38 }, "catch parameter scoped to its clause body")
  eq(find_local(tb, "in").kind, "resource", "try resource is a local")
  local switch = tb.stmts[2]
  eq(vim.tbl_map(function(a) return a.name .. a.index end, switch.arms), { "case0", "case1" }, "switch arms")
  local loop = tb.stmts[3]
  eq(loop.arms[1].name, "body", "loop body arm")
  check(loop.arms[1].stmts[1].guard, "if … continue inside a loop is a guard")
  local branch = tb.stmts[4]
  check(not branch.guard and #branch.arms == 2 and branch.arms[2].name == "else", "if/else is not a guard")
  eq(tb.metrics.loops, 1, "loop counted")
  eq(tb.metrics.throws, 1, "throw counted")

  -- The index (§4.3) ----------------------------------------------------------
  vim.fn.writefile({ "package shop.extra;", "public class Extra { void go() { } }" },
    root .. "/" .. t.java .. "shop/Extra.java")
  vim.fn.writefile({ "class Ignored { }" }, root .. "/Ignored.java")
  vim.fn.writefile({ "Ignored.java", "build/" }, root .. "/.gitignore")
  vim.fn.mkdir(root .. "/build", "p")
  vim.fn.writefile({ "class Out { }" }, root .. "/build/Out.java")
  local fresh = t.index(root, { ignore = { "src/main/java/shop/notify" } })
  check(fresh.file_set[t.java .. "shop/Extra.java"], "untracked, unignored file is listed")
  check(not fresh.file_set["Ignored.java"] and not fresh.file_set["build/Out.java"], ".gitignore honoured")
  check(not fresh.file_set[t.java .. "shop/notify/Notifier.java"], "ast.ignore removes paths")
  check(fresh:type("shop.order.Order") ~= nil, "package path finds a type on demand")
  eq(fresh.stats.parsed + fresh.stats.cached, 1, "only the declaring file is parsed")
  check(fresh:type("shop.extra.Extra") ~= nil, "declaration grep finds a type off its package path")
  check(fresh:type("shop.order.Nope") == nil, "missing type")
  local again = t.index(root)
  again:facts(svc)
  eq({ again.stats.parsed, again.stats.cached }, { 0, 1 }, "facts are cached by blob SHA")
  local buf = vim.fn.bufadd(root .. "/" .. svc)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, 20, 20, false, { "    public void added() { }" })
  local edited = t.index(root)
  check(edited:facts(svc).symbols["java:shop.order.OrderService#added()"], "a modified buffer is read, not the file")
  eq(edited.stats.buffers, 1, "buffer facts keyed by changedtick")
  vim.api.nvim_buf_delete(buf, { force = true })
  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside .. "/target", "p")
  vim.fn.writefile({ "class A { }" }, outside .. "/A.java")
  vim.fn.writefile({ "class B { }" }, outside .. "/target/B.java")
  local plain = t.index(outside)
  check(not plain.git and plain.file_set["A.java"] and not plain.file_set["target/B.java"],
    "outside git, the fallback walk skips build directories")

  -- ast.available (§4.1) ------------------------------------------------------
  check(ast.available(root .. "/" .. svc), "java file is available")
  check(ast.available(root .. "/" .. svc, checkout.id), "symbol is available")
  check(not ast.available(root .. "/README.kt"), "no backend for .kt")
  vim.fn.writefile({ "class Broken {", "  void ok() { }", "  void bad() { int x = ; }", "}" }, root .. "/Broken.java")
  local ok_good = ast.available(root .. "/Broken.java", "java:Broken#ok()")
  local ok_bad, why = ast.available(root .. "/Broken.java", "java:Broken#bad()")
  check(ok_good and not ok_bad and why == "parse error in symbol", "ERROR inside the symbol makes it unavailable")
end)
