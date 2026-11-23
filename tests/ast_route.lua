-- SPEC-ast-graph §8: the agent's route (success path facts, forks, carriers, effects, sinks,
-- gaps, hand-offs, --through, the cap, completeness at every detail); labels; effective
-- rating; only the main flow walked; offer cutoffs; budget order; changing detail without
-- re-rating; dispatch with construction tracking. The plugin never rates a call itself:
-- unnamed calls are lazy.
--   nvim --clean --headless -l tests/ast_route.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

local P = "java:shop."

t.finish("ast route", function()
  if not t.parser() then
    return
  end
  local root = t.project()
  local idx = t.index(root)
  local route = require("code-tour.ast.route")
  local outline = require("code-tour.ast.outline")
  local rt = route.new(idx)

  local function body(id)
    idx:type(id:sub(6):match("^([^#]+)"))
    local b = rt:body(id)
    return assert(b, "no body " .. id)
  end
  local function sorted(set)
    local out = vim.tbl_keys(set)
    table.sort(out, function(a, b)
      return tonumber(a:sub(2)) < tonumber(b:sub(2))
    end)
    return out
  end
  local function tour(specs, opts)
    opts = vim.deepcopy(opts or {})
    local spec = type(specs) == "string" and specs or specs[1]
    opts.overrides = opts.overrides or t.route(spec:match("^Pipeline") and "pipeline" or "checkout")
    return assert(outline.build(idx, type(specs) == "string" and { specs } or specs, opts))
  end
  local function snippet(tr, label)
    for _, sn in ipairs(tr.snippets) do
      if sn.label == label then
        return sn
      end
    end
  end
  local function sites(sn, text)
    return vim.tbl_filter(function(s)
      return s.text == text
    end, sn.sites)
  end
  local function main_labels(tr)
    local out = {}
    for _, sn in ipairs(tr.snippets) do
      if sn.main then
        out[#out + 1] = sn.label
      end
    end
    return out
  end

  -- entries (§8.1) ---------------------------------------------------------------------
  local checkout = P .. "order.OrderService#checkout(Order)"
  for _, spec in ipairs({ "OrderService#checkout", "shop.order.OrderService#checkout(Order)", "OrderService.checkout",
    checkout, "src/main/java/shop/order/OrderService.java:30" }) do
    eq(rt:resolve_entry(spec), { checkout }, "entry " .. spec)
  end
  local ids = rt:resolve_entry("Pipeline")
  eq(ids[1], P .. "route.Pipeline#run(String)", "a type without main: its public methods, in order")
  check(not vim.tbl_contains(ids, P .. "route.Pipeline#normalize(String)"), "private methods are not entries")
  local _, err = rt:resolve_entry("Formatter#format")
  check(err and err:match("ambiguous"), "an overloaded name without parameters is ambiguous")
  eq(rt:resolve_entry("Formatter#format(Money)"), { P .. "util.Formatter#format(Money)" }, "parameters pick an overload")

  -- success path ------------------------------------------------------------------------
  local cbody = body(checkout)
  local succ = rt:success(cbody)
  eq(vim.tbl_map(function(o)
    return o.why
  end, succ.off), { "guard", "guard", "guard" }, "guard consequences are off the success path")
  local decide = body(P .. "route.Pipeline#decide(int,String)")
  local dsucc = rt:success(decide)
  eq(dsucc.off[1].why, "fewer project sites", "two terminating arms, a tie broken by name: then is dropped")
  eq({ dsucc.forks[1].by, dsucc.forks[1].success }, { "condition", "else" }, "the name tie-break is listed as a fork")
  check(not dsucc.on(route.site_of(decide, "s2").at) and dsucc.on(route.site_of(decide, "s3").at),
    "reject is off the path, accept on it")
  local guarded = body(P .. "route.Pipeline#guarded(Path,String)")
  eq(vim.tbl_map(function(o)
    return o.why
  end, rt:success(guarded).off), { "catch" }, "a catch clause is off the success path")
  local pick = body(P .. "route.Pipeline#pick(int,String)")
  eq(#rt:success(pick).off, 2, "a switch keeps only the case with the most project sites")
  check(rt:success(pick).on(route.site_of(pick, "s2").at), "case 1 (accept(normalize(...))) stays")
  check(route.signals_failure("!ok") and route.signals_failure("x == null") and route.signals_failure("isDenied(u)")
    and not route.signals_failure("n > 0"), "failure-signalling conditions")

  -- carriers and effects -------------------------------------------------------------------
  eq(sorted(rt:carriers(cbody)), { "s5", "s6", "s14" },
    "carriers: total feeds apply through a local, apply feeds receipt, receipt is returned")
  local total = body(P .. "order.Order#total()")
  eq(sorted(rt:carriers(total)), { "s1", "s2", "s3" }, "carriers through a reassigned local and an argument")
  check(rt:has_effect(P .. "order.Order#markPaid()"), "a field write of this is an effect")
  check(rt:has_effect(P .. "payment.CardGateway#charge(Money)"), "a sink is an effect")
  check(rt:has_effect(checkout), "effects propagate from callees")
  check(not rt:has_effect(P .. "order.Order#total()"), "a pure computation has no effect")
  check(not rt:has_effect(P .. "order.OrderService.Receipt#Receipt(String,Money)"),
    "a constructor initialising its own fields has no effect")
  check(rt:has_effect(P .. "route.Pipeline#write(Path,String)"), "Files.write is a sink")

  -- complexity (used only to pick the model that writes a box) --------------------------------------------------------------------
  eq(rt:score(P .. "order.Order#total()"), 7 / 5 + 1.5 + 1.5 * 3, "score: lines, a loop, three project sites")

  -- the main flow -------------------------------------------------------------------------
  local ct = tour("OrderService#checkout")
  eq(main_labels(ct), { "OrderService.checkout(Order)", "Order.total()", "Line.subtotal()",
    "DiscountPolicy.apply(Order, Money)", "Stats.max(int, int)", "CardGateway.charge(Money)" },
    "main flow: carriers (total, apply, max) and an effect (charge, which sends)")
  local n1 = ct.snippets[1]
  eq({ sites(n1, "order.total")[1].mode, sites(n1, "discounts.apply")[1].mode, sites(n1, "gateway.charge")[1].mode },
    { "walk", "walk", "walk" }, "main sites are walked")
  local mark = sites(n1, "order.markPaid")[1]
  eq({ mark.mode, mark.rating, mark.why }, { "lazy", 9, "not in the route" }, "a call the route does not name is lazy")
  eq(sites(n1, "failed")[1].mode, "lazy", "a guard's consequence is not on the main flow")
  eq(sites(n1, "result.ok")[1].mode, "accessor", "record accessor label")
  eq(sites(n1, "new IllegalStateException")[1].mode, "unresolved", "built-in label")
  local charge = snippet(ct, "CardGateway.charge(Money)")
  eq(charge.sinks[1].entry, "java.net.http.HttpClient#send", "the flow ends at a sink")
  eq(charge.depth, 1, "depth along the main flow")

  -- gaps, hand-offs, forks
  local pt = tour("Pipeline")
  local reasons = {}
  for _, g in ipairs(pt.gaps) do
    reasons[#reasons + 1] = g.text .. ": " .. g.reason
  end
  eq(reasons, { "executor.execute: hand-off", "store.save: no implementation in the project" }, "gaps")
  local named = tour("Pipeline#shapeBoth", { overrides = { { kind = "route", level = 0,
    from = "Pipeline#shapeBoth", to = "Step#apply" } } })
  eq(named.gaps[1] and named.gaps[1].reason, "2 implementations; name one in the route",
    "a route to the interface leaves the choice of implementation as a gap")
  eq(snippet(pt, "Pipeline.decide(int, String)").forks[1].success, "else", "fork listed on its snippet")

  -- dispatch with construction tracking (§8.5)
  local run = snippet(pt, "Pipeline.run(String)")
  local step = sites(run, "step.apply")[1]
  eq({ step.mode, step.target, step.built }, { "walk", P .. "route.Upper#apply(String)", P .. "route.Upper" },
    "a local assigned `new Upper()`: the one implementation walked")
  local both = snippet(pt, "Pipeline.shapeBoth(String)")
  eq({ sites(both, "shaper.apply")[1].mode, sites(both, "shaper.apply")[1].target },
    { "walk", P .. "route.Trim#apply(String)" }, "a field initialised with `new Trim()`")
  local vt = tour("Pipeline#viaParam")
  eq(sites(vt.snippets[2], "with.apply")[1].target, P .. "route.Upper#apply(String)",
    "a parameter: the construction passed by the caller")

  -- labels
  local picked = snippet(pt, "Pipeline.pick(int, String)")
  eq({ sites(picked, "accept")[1].mode, sites(picked, "accept")[1].why }, { "ref", "already shown" },
    "a target already visited is a ref")
  local apply = snippet(ct, "DiscountPolicy.apply(Order, Money)")
  local fmt = vim.tbl_filter(function(s)
    return s.target == P .. "util.Formatter#format(String)"
  end, apply.sites)
  eq({ fmt[1].mode, fmt[2].mode, fmt[2].why }, { "lazy", "lazy", fmt[1].why },
    "a repeated call to the same target reads like the first")

  -- --through and the cap
  local without_audit = vim.tbl_filter(function(op)
    return op.to ~= "shop.route.Pipeline#audit(String)"
  end, t.route("pipeline"))
  local through = tour("Pipeline#run", { through = { "Pipeline#audit" }, overrides = without_audit })
  local audit = sites(through.snippets[1], "audit")[1]
  eq({ audit.mode, audit.main }, { "walk", true }, "--through puts a helper on the main flow")
  eq(sites(tour("Pipeline#run", { overrides = without_audit }).snippets[1], "audit")[1].mode, "lazy",
    "without it the unnamed helper is lazy")
  eq(sites(tour("Pipeline#run").snippets[1], "audit")[1].mode, "optional", "a branch the route names is an extra")
  local capped = tour("OrderService#checkout", { options = { main_cap = 2 } })
  eq(#main_labels(capped), 2, "ast.main_cap bounds the main flow")
  check(capped.warnings[1]:match("capped"), "the cap warns")
  local why = {}
  for _, s in ipairs(capped.snippets[1].sites) do
    if s.why == "main cap" then
      why[#why + 1] = s.text
    end
  end
  eq(why, { "discounts.apply", "gateway.charge" }, "main sites past the cap are lazy, why \"main cap\"")

  -- details: completeness, walk, cutoffs, budget, no re-rating ----------------------------
  local by_detail = {}
  for _, d in ipairs({ "overview", "normal", "detailed", "exhaustive" }) do
    local tr = tour("Pipeline", { detail = d })
    by_detail[d] = tr
    eq(main_labels(tr), main_labels(pt), "the main flow is the same at " .. d)
    for _, r in ipairs(tr.route) do
      if r.mode == "walk" then
        check(r.main and r.rating == 0, d .. ": only the main flow is walked")
      elseif r.main then
        error("FAILED: a main edge that is not walked at " .. d)
      end
      check(r.mode ~= "optional" or r.rating <= rt.opts.cutoffs[d].offer, d .. ": optional within the cutoff")
    end
  end
  eq(sites(by_detail.overview.snippets[1], "audit")[1].mode, "lazy", "audit (rated 3) is lazy at overview")
  eq(sites(by_detail.overview.snippets[1], "audit")[1].why, "detail", "… because of the detail")
  eq(sites(by_detail.normal.snippets[1], "audit")[1].mode, "optional", "… and offered at normal")
  local function ratings(tr)
    local out = {}
    for _, r in ipairs(tr.route) do
      local from = tr.snippets[tonumber(r.from.n:sub(2))].symbol
      out[from .. "|" .. r.from.site .. "|" .. r.target] = r.rating
    end
    return out
  end
  local rn, rx = ratings(by_detail.normal), ratings(by_detail.exhaustive)
  for key, rating in pairs(rn) do
    if rx[key] then
      eq(rx[key], rating, "changing detail does not re-rate " .. key)
    end
  end
  local tight = tour("Pipeline", { options = { cutoffs = { normal = { offer = 3, budget = 0 } } } })
  for _, sn in ipairs(tight.snippets) do
    check(sn.main, "a zero budget leaves only the main flow")
  end
  eq(sites(tight.snippets[1], "audit")[1].why, "budget", "extras past the budget are lazy, why \"budget\"")

  -- effective rating over the rated tree: never above the edge that reached the symbol
  require("code-tour.ast.overrides").route(rt, t.route(), {})
  local flow = rt:main_flow({ checkout }, {})
  local tree = rt:tree({ checkout }, flow)
  local visited = 0
  local function walk_tree(node)
    for _, e in ipairs(node.edges) do
      if e.rating then
        eq(e.eff, math.max(e.rating, node.eff), "effective rating = max(own, incoming)")
        if e.main then
          eq(e.eff, 0, "main edges are rated 0")
        end
        visited = visited + 1
      end
      if e.to then
        walk_tree(e.to)
      end
    end
  end
  for _, r in ipairs(tree.roots) do
    walk_tree(r)
  end
  check(visited > 10, "the tree was rated")
end)
