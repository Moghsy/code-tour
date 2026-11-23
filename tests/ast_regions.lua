-- SPEC-ast-graph §7: region selection per detail level; exact coverage; addresses; guard
-- runs; beats; arm recursion; runts; nesting across levels; selection mapping.
--   nvim --clean --headless -l tests/ast_regions.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

local function le(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end
local function within(inner, outer)
  return le(outer.start, inner.start) and le(inner["end"], outer["end"])
end

t.finish("ast regions", function()
  if not t.parser() then
    return
  end
  local root = t.project()
  local idx = t.index(root)
  local regions = require("code-tour.ast.regions")
  local outline = require("code-tour.ast.outline")

  local function tour(spec, detail)
    return assert(outline.build(idx, { spec }, { detail = detail, overrides = spec == "OrderService#checkout" and t.route() or nil }))
  end
  local function shape(snippet)
    return vim.tbl_map(function(r)
      return { r.id, r.lines[1], r.lines[2], r.kind, (r.address:gsub("^.-/body", "/body")) }
    end, snippet.regions)
  end

  -- selection per detail ---------------------------------------------------------
  local checkout = tour("OrderService#checkout", "normal").snippets[1]
  eq(shape(checkout), {
    { "r1", 21, 28, "guard", "/body/stmts[1..2]" },
    { "r2", 29, 29, "setup", "/body/stmts[3]" },
    { "r3", 30, 30, "setup", "/body/stmts[4]" },
    { "r4", 31, 31, "delegate", "/body/stmts[5]" },
    { "r5", 32, 34, "guard", "/body/stmts[6]" },
    { "r6", 35, 39, "mixed", "/body/stmts[7..10]" },
  }, "checkout at normal: guard run, one beat per walked call, the charge as a delegate")
  eq(#tour("OrderService#checkout", "overview").snippets[1].regions, 0, "overview: one box per snippet")
  local exhaustive = tour("OrderService#checkout", "exhaustive").snippets[1]
  eq(#exhaustive.regions, 7, "exhaustive splits the tail further")
  eq({ exhaustive.regions[6].kind, exhaustive.regions[6].address:match("/body/.*") },
    { "work", "/body/stmts[7..8]" }, "markPaid and processed++ are work (effects)")

  -- addresses and origins
  eq(checkout.regions[1].address, "java:shop.order.OrderService#checkout(Order)/body/stmts[1..2]",
    "a run of statements is addressed from the symbol id")
  eq({ checkout.regions[1].origin, checkout.regions[2].origin }, { "synthetic", "syntactic" }, "origins")

  -- guard runs (rule 3): the declaration that only computes what the guards test joins them
  local build = tour("Report#build", "normal").snippets[1]
  eq(shape(build)[1], { "r1", 10, 18, "guard", "/body/stmts[1..3]" }, "count, then two guards: one guard region")
  eq(build.regions[1].facts.guards, { "count == 0", "limit <= 0" }, "guard conditions are facts")
  -- a leading comment opens a region (rule 1), which starts at the comment
  eq({ build.regions[2].lines[1], build.regions[2].address:match("/body/.*") }, { 19, "/body/stmts[4..7]" },
    "a commented statement starts a region at its comment")

  -- arm recursion (rule 5): the loop is longer than max, so its body is split
  eq(shape(build)[3], { "r3", 25, 43, "loop", "/body/stmts[8]" }, "a long loop is its own region")
  eq(build.regions[3].facts.subject, "items", "loop subject")
  eq(vim.tbl_map(function(r)
    return r.parent and r.address:match("/body/stmts%[8%](.*)")
  end, { build.regions[4], build.regions[5], build.regions[6], build.regions[7] }),
    { "/body/stmts[1]", "/body/stmts[2..6]", "/body/stmts[7]", "/body/stmts[8..10]" },
    "one-arm loop: its body's statements are the children")
  eq(build.regions[4].kind, "guard", "the loop's early break is a guard")
  local ex = tour("Report#build", "exhaustive").snippets[1]
  local arms = {}
  for _, r in ipairs(ex.regions) do
    local arm = r.address:match("/stmts%[7%]/(%a+)$")
    if arm then
      arms[#arms + 1] = { arm, r.lines[1], r.lines[2] }
    end
  end
  eq(arms, { { "then", 34, 35 }, { "else", 36, 38 } }, "exhaustive: every multi-arm if is split; `} else {` opens else")

  -- runts (rule 6): shown++ and total++ (2 lines) merge at normal, stand alone at exhaustive (min 2)
  eq(build.regions[5].address:match("/body/stmts%[8%]/body/(.*)"), "stmts[2..6]", "runt merged into its neighbor")
  eq({ ex.regions[6].address:match("/body/stmts%[8%]/body/(.*)"), ex.regions[7].address:match("/body/stmts%[8%]/body/(.*)") },
    { "stmts[2..4]", "stmts[5..6]" }, "not a runt at exhaustive")

  -- short symbols get no children
  local markpaid = idx:symbol("java:shop.order.Order#markPaid()")
  local body = idx.resolver:resolve_file(markpaid.file).bodies[markpaid.id]
  for _, d in ipairs(regions.levels) do
    eq(#regions.select(markpaid, body, d).children, 0, "a three-line method has no children at " .. d)
  end

  -- beats (rule 4): without walked calls the setup statements group together
  local csym = idx:symbol("java:shop.order.OrderService#checkout(Order)")
  local cbody = idx.resolver:resolve_file(csym.file).bodies[csym.id]
  local plain = regions.flatten(regions.select(csym, cbody, "normal", {}))
  local same = false
  for _, r in ipairs(plain) do
    same = same or r.address:match("/body/stmts%[3%.%.4%]$") ~= nil
  end
  check(same, "without a walk, total and discounted form one setup region")

  -- coverage and nesting -----------------------------------------------------------
  local function covers(region)
    local kids = region.children
    if #kids == 0 then
      return
    end
    eq(kids[1].span[1], region.span[1], region.address .. ": first child starts with its parent")
    eq(kids[#kids].span[2], region.span[2], region.address .. ": last child ends with its parent")
    for k, c in ipairs(kids) do
      check(within(c.range, region.range), c.address .. " lies inside its parent")
      check(c.span[1] <= c.range.start[1] + 1 and c.range["end"][1] + 1 <= c.span[2] + (k < #kids and 1 or 0),
        c.address .. ": the span holds the region's tokens")
      if kids[k + 1] then
        eq(kids[k + 1].span[1], c.span[2] + 1, c.address .. ": siblings tile without gaps")
      end
      covers(c)
    end
  end
  local symbols = {
    "java:shop.order.OrderService#checkout(Order)", "java:shop.route.Report#build(List,int)",
    "java:shop.route.Pipeline#run(String)", "java:shop.route.Pipeline#pick(int,String)",
    "java:shop.route.Pipeline#guarded(Path,String)", "java:shop.payment.CardGateway#charge(Money)",
  }
  for _, id in ipairs(symbols) do
    idx:type(id:sub(6):match("^([^#]+)"))
    local sym = assert(idx:symbol(id), id)
    local b = idx.resolver:resolve_file(sym.file).bodies[id]
    local levels = {}
    for _, d in ipairs({ "normal", "detailed", "exhaustive" }) do
      local r = regions.select(sym, b, d, {})
      covers(r)
      levels[#levels + 1] = regions.flatten(r)
    end
    -- every finer region lies inside exactly one region of each coarser level, and a
    -- region the finer level does not split keeps its address
    for k = 1, #levels - 1 do
      local coarse, fine = levels[k], levels[k + 1]
      for _, f in ipairs(fine) do
        local inside_one = #coarse == 0
        for _, c in ipairs(coarse) do
          local disjoint = le(c.range["end"], f.range.start) or le(f.range["end"], c.range.start)
          check(disjoint or within(f.range, c.range) or within(c.range, f.range),
            id .. ": " .. f.address .. " does not straddle " .. c.address)
          inside_one = inside_one or within(f.range, c.range)
        end
        check(inside_one, id .. ": " .. f.address .. " lies inside a coarser region")
        for _, c in ipairs(coarse) do
          if vim.deep_equal(c.range, f.range) then
            eq(f.address, c.address, id .. ": unsplit region keeps its address")
          end
        end
      end
    end
  end

  -- selection mapping ----------------------------------------------------------------
  local walk = { s5 = true, s6 = true, s7 = true }
  local croot = regions.select(csym, cbody, "normal", { walked = walk, main = walk })
  regions.flatten(croot)
  local tail = croot.children[6] -- stmts[7..10]
  eq(regions.at(croot, tail.range), tail, "a selection of a whole region maps to it")
  local markpaid_stmt = cbody.stmts[7]
  local pick = regions.at(croot, markpaid_stmt.range)
  eq({ pick.synthetic, pick.address:match("/body/.*") }, { true, "/body/stmts[7]" },
    "a selection of part of a region becomes a synthetic child for the statements it touches")
  local guard_cond = { start = cbody.stmts[1].range.start, ["end"] = cbody.stmts[2].range["end"] }
  eq(regions.at(croot, guard_cond), croot.children[1], "both guards: the guard region")
  local whole = regions.at(croot, csym.range)
  eq(whole, croot, "the whole method maps to the root")
end)
