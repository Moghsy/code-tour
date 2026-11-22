-- SPEC-ast-graph §6, §8.1, §9.6 and §14: hints, entry candidates, overrides and
-- agent-supplied snippets in the deterministic outline.
--   nvim --clean --headless -l tests/ast_enrichment.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast enrichment", function()
  if not t.parser() then return end
  local root = t.project()
  vim.fn.mkdir(root .. "/.ua", "p")
  vim.fn.writefile({ ".ua/" }, root .. "/.gitignore")
  t.run({ "git", "add", ".gitignore" }, root)
  t.run({ "git", "-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-qm", "ignore hints" }, root)
  local commit = vim.trim(t.run({ "git", "rev-parse", "HEAD" }, root))
  local checkout = "java:shop.order.OrderService#checkout(Order)"
  vim.fn.writefile({ vim.json.encode({ project = { gitCommitHash = commit }, nodes = {
    { id = checkout, filePath = "src/main/java/shop/order/OrderService.java", name = "checkout",
      type = "method", lineRange = { 21, 39 }, summary = "Hint summary", complexity = "complex" },
  } }) }, root .. "/.ua/knowledge-graph.json")
  local idx = t.index(root)
  local outline = require("code-tour.ast.outline")
  local prep = assert(outline.prepare(idx, { "OrderService#checkout" }))
  check(prep.rt.hints.symbols[checkout].complex, "fresh Understand Anything hints reach the route")
  eq(prep.rt.hints.symbols[checkout].summary, "Hint summary", "fresh graph summaries are retained")
  local source = root .. "/src/main/java/shop/order/OrderService.java"
  local original = vim.fn.readfile(source)
  vim.fn.writefile(vim.list_extend(vim.deepcopy(original), { "// working change" }), source)
  local stale_hints = require("code-tour.ast.hints").load(idx)
  check(not stale_hints.symbols[checkout].complex, "hints are ignored while indexed code is dirty")
  check(stale_hints.warnings[1]:find("does not match", 1, true) ~= nil, "ignored hint source is reported")
  t.run({ "git", "checkout", "--", "src/main/java/shop/order/OrderService.java" }, root)
  -- Graphify metadata uses the other supported commit key and may identify
  -- a hub by its report label instead of a node attribute.
  local total = "java:shop.order.Order#total()"
  vim.fn.mkdir(root .. "/graphify-out", "p")
  vim.fn.writefile({ vim.json.encode({ built_at_commit = commit, nodes = {
    { id = checkout, community = 4, source_file = "src/main/java/shop/order/OrderService.java" },
    { id = total, label = "Order total", community = 4, source_file = "src/main/java/shop/order/Order.java" },
  } }) }, root .. "/graphify-out/graph.json")
  vim.fn.writefile({ "## God Nodes", "", "1. `Order total`" }, root .. "/graphify-out/GRAPH_REPORT.md")
  local graphify = assert(outline.prepare(t.index(root), { checkout }))
  eq(graphify.rt.hints.symbols[checkout].community, 4, "Graphify community is read from a fresh graph")
  check(graphify.rt.hints.symbols[total].god, "Graphify report labels identify hubs")
  check(not graphify.flow.nodes[total], "A hub is off the automatic main flow")
  local promoted = assert(outline.prepare(t.index(root), { checkout }, {
    overrides = { { kind = "rate", value = "n1.s5=0" } },
  }))
  check(promoted.flow.nodes[total], "An explicit rating can walk a hub")

  -- A modified buffer is a different project state even with a clean Git worktree.
  local buf = vim.fn.bufadd(source)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "// unsaved change" })
  local dirty = require("code-tour.ast.hints").load(t.index(root))
  eq(#dirty.warnings, 2, "Both hint sources report a modified project buffer")
  vim.api.nvim_buf_delete(buf, { force = true })

  local hints_off = assert(outline.prepare(t.index(root), { checkout }, { hints = false }))
  check(not hints_off.rt.hints and hints_off.flow.nodes[total], "Explicitly disabling hints restores the default walk")
  vim.fn.delete(root .. "/graphify-out", "rf")
  local candidates = outline.auto_entries(idx)
  check(#candidates > 0, "auto lists likely project entries")
  check(candidates[1].score >= candidates[#candidates].score, "auto candidates are ranked")
  check(candidates[1].symbol ~= nil, "auto candidate is a resolvable symbol")
  for _, candidate in ipairs(candidates) do
    check(not candidate.file:match("/tests?/") and not candidate.label:match("^test_"),
      "auto excludes test code")
  end

  local entry = "OrderService#checkout"
  local baseline = assert(outline.build(idx, { entry }, { detail = "normal" }))
  local rate = assert(outline.build(idx, { entry }, { detail = "normal", overrides = {
    { kind = "rate", value = "n1.s1=4" },
  } }))
  eq(rate.snippets[1].sites[1].effective, 4, "rate override is applied by stable outline address")
  eq(rate.warnings, baseline.warnings, "a rate override does not add warnings")
  local split = assert(outline.build(idx, { entry }, { detail = "normal", overrides = {
    { kind = "split", value = "n1.r6@stmt2" },
  } }))
  check(#split.snippets[1].regions > #baseline.snippets[1].regions,
    "split override refines the selected region")

  local live = assert(require("code-tour.ast.live").new({ root = root, entries = { entry },
    detail = "normal", overrides = {
      { kind = "rate", value = "n1.s5=2" },
      { kind = "merge", value = "n1.r2,n1.r3" },
    },
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

  local fallback = assert(outline.build(idx, { entry }, { detail = "normal", overrides = {
    { kind = "add", value = vim.json.encode({ file = "src/main/java/shop/catalog/Catalog.java",
      start = 1, ["end"] = 4, label = "AgentCatalog" }) },
  } }))
  check(#fallback.snippets > #baseline.snippets, "--add appends an agent-backed snippet")
  local found = false
  for _, sn in ipairs(fallback.snippets) do
    found = found or (sn.label == "AgentCatalog" and sn._node.sym.source == "agent")
  end
  check(found, "fallback snippet keeps its agent source")
end)
