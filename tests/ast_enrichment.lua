-- SPEC-ast-graph §6, §8.1, §9.6 and §14: entry candidates, overrides and
-- agent-supplied snippets in the deterministic outline.
--   nvim --clean --headless -l tests/ast_enrichment.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast enrichment", function()
  if not t.parser() then return end
  local root = t.project()
  local idx = t.index(root)
  local outline = require("code-tour.ast.outline")
  local candidates = outline.auto_entries(idx)
  check(#candidates > 0, "auto lists likely project entries")
  check(candidates[1].score >= candidates[#candidates].score, "auto candidates are ranked")
  check(candidates[1].symbol ~= nil, "auto candidate is a resolvable symbol")
  for _, candidate in ipairs(candidates) do
    check(not candidate.file:match("/tests?/") and not candidate.label:match("^test_"),
      "auto excludes test code")
  end

  local entry = "OrderService#checkout"
  local function with(ops)
    return vim.list_extend(t.route(), ops)
  end
  local baseline = assert(outline.build(idx, { entry }, { detail = "normal", overrides = t.route() }))
  local rate = assert(outline.build(idx, { entry }, { detail = "normal", overrides = with({
    { kind = "rate", value = "n1.s1=4" },
  }) }))
  eq(rate.snippets[1].sites[1].effective, 4, "rate override is applied by stable outline address")
  eq(rate.warnings, baseline.warnings, "a rate override does not add warnings")
  local split = assert(outline.build(idx, { entry }, { detail = "normal", overrides = with({
    { kind = "split", value = "n1.r6@stmt2" },
  }) }))
  check(#split.snippets[1].regions > #baseline.snippets[1].regions,
    "split override refines the selected region")

  local live = assert(require("code-tour.ast.live").new({ root = root, entries = { entry },
    detail = "normal", overrides = with({
      { kind = "rate", value = "n1.s5=2" },
      { kind = "merge", value = "n1.r2,n1.r3" },
    }),
  }))
  local function has_merge()
    for _, region in ipairs(live.snippets.n1.regions) do
      if vim.deep_equal(region.lines, { 29, 30 }) then return true end
    end
    return false
  end
  check(has_merge(), "An already-satisfied merge composes with a rating change")
  live:set_detail("overview")
  eq(#live.snippets.n1.regions, 0, "A normal-detail merge does not force boxes into overview")
  live:set_detail("normal")
  check(has_merge(), "The merge reappears at its authored detail")

  local fallback = assert(outline.build(idx, { entry }, { detail = "normal", overrides = with({
    { kind = "add", value = vim.json.encode({ file = "src/main/java/shop/catalog/Catalog.java",
      start = 1, ["end"] = 4, label = "AgentCatalog" }) },
  }) }))
  check(#fallback.snippets > #baseline.snippets, "--add appends an agent-backed snippet")
  local found = false
  for _, sn in ipairs(fallback.snippets) do
    found = found or (sn.label == "AgentCatalog" and sn._node.sym.source == "agent")
  end
  check(found, "fallback snippet keeps its agent source")
end)
