local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

t.finish("AST writing tiers", function()
  local tiers = require("code-tour.ast.tiers")
  local rt = { score = function() return 1 end, idx = { symbol = function() end } }
  local checks = { statements = 2, branches = 0, field_writes = 0, project_sites = 1 }
  local node = { symbol = "example", sym = {}, body = { metrics = checks, stmts = {}, sites = {}, field_writes = {} } }
  t.eq(tiers.classify(rt, node, {}), "light", "Small straight-line snippet")
  checks.statements = 6
  t.eq(tiers.classify(rt, node, {}), "standard", "Longer straight-line snippet")
  t.eq(tiers.classify(rt, node, { { mode = "walk", via = "dispatch" } }), "deep", "Walked dispatch")
  t.eq(tiers.classify(rt, node, { { mode = "lazy", via = "dispatch" } }), "standard", "Lazy dispatch")
  t.eq(tiers.classify(rt, node, { { mode = "walk", via = "agent" } }), "deep", "Walked agent edge")
  checks.field_writes, checks.branches = 1, 1
  t.eq(tiers.classify(rt, node, {}), "deep", "Writes with branches")
  checks.field_writes, checks.branches = 0, 0
  node.body.stmts = { { arms = { { name = "finally", stmts = {} } } } }
  t.eq(tiers.classify(rt, node, {}), "deep", "Finally arm")
  node.body.stmts = { { arms = { { name = "catch", stmts = { { kind = "throw_statement" } } } } } }
  t.eq(tiers.classify(rt, node, {}), "deep", "Catch with throw")

  if not t.parser() then return end
  local root = t.project()
  local ast = require("code-tour.ast")
  ast.setup({ models = { light = "quick", standard = "regular", deep = "thorough" } })
  local live = assert(require("code-tour.ast.live").new({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache }))
  live:fill("n1", "## overview\nValidate and charge the order.\n\nThe checkout flow starts with validation.", { model = "quick" })
  local saved = live:lookup(live.snippets.n1)
  t.eq(saved.model, "quick", "A fill records the writer model")
  local ctx = { cli = "code-tour", servername = "/tmp/test-code-tour", token = "token" }
  local outline = live:outline(ctx)
  t.check(outline:find("light=quick", 1, true) and outline:find(" brief ", 1, true), "Outline includes configured models and brief command")
  local result = require("code-tour.ast.brief").build(live, "n1", ctx)
  t.check(result.brief:find("Validate and charge the order.", 1, true), "Brief includes the fresh entry gist")
  t.check(result.brief:find("Callee:", 1, true), "Brief includes callee interfaces")
  t.check(result.brief:find("begin r1", 1, true), "Brief marks source boundaries")
  t.check(result.brief:find("--model", 1, true), "Brief includes the model flag")
  local snippet = live.snippets.n1
  local buf = live:buf(snippet.file)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line:find("processed++", 1, true) then
      vim.api.nvim_buf_set_lines(buf, i - 1, i, false, { (line:gsub("processed%+%+", "processed += 2")) })
      break
    end
  end
  local reopened = assert(require("code-tour.ast.live").new({
    entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache,
  }))
  t.check(not reopened:lookup(reopened.snippets.n1), "The reader cannot see the stale gist")
  local prior = require("code-tour.ast.brief").build(reopened, "n1", ctx)
  t.check(prior.brief:find("Previous note for overview (describes older code)", 1, true), "Brief labels stale text")
  t.check(prior.brief:find("Validate and charge the order.", 1, true), "Writer receives stale text")
end)
