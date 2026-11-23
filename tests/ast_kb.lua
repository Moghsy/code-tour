-- The knowledge base view: one status per symbol joined from graph, notes, Q&A and concepts.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast kb", function()
  if not t.parser() then
    return
  end
  local ast = require("code-tour.ast")
  local root = t.project()
  local opts = { root = root, cache_dir = t.cache }
  local function kb(extra)
    return ast.analyze(vim.tbl_extend("force", opts, { view = "kb" }, extra or {}))
  end
  local live = assert(require("code-tour.ast.live").new({ root = root, entries = { "OrderService#checkout" },
    overrides = t.route(), cache_dir = t.cache }))
  local entry, callee = live.snippets.n1, live.snippets.n2

  local empty = kb()
  eq({ empty.counts.fresh, empty.counts.stale, #empty.regenerate }, { 0, 0, 0 }, "nothing is written yet")
  check(empty.missing_total > 0, "undocumented symbols are counted from the graph")

  live:fill("n1", "## overview\nCharge the order.\n\nCalculate and charge.")
  live:fill("n2", "## overview\nSum the lines.\n\nSum.")
  live:remember()
  local fresh = kb()
  eq({ fresh.counts.fresh, fresh.counts.stale }, { 2, 0 }, "written notes are fresh")
  eq(fresh.missing_total, empty.missing_total - 2, "documented symbols leave the missing list")

  check(#fresh.coverage > 0, "coverage is reported per community")
  local explained, total = 0, 0
  for _, row in ipairs(kb({ limit = 1000 }).coverage) do
    explained, total = explained + row.explained, total + row.symbols
    check(row.fresh <= row.explained and row.explained <= row.symbols, "coverage counts are consistent")
  end
  eq(explained, 2, "the two written symbols are counted as explained")
  check(total > explained, "and the others as not yet explained")

  local path = root .. "/src/main/java/shop/order/Order.java"
  local lines = vim.fn.readfile(path)
  for i, line in ipairs(lines) do lines[i] = line:gsub("return sum;", "return sum + 0;") end
  vim.fn.writefile(lines, path)
  local after = kb()
  eq({ after.counts.fresh, after.counts.stale }, { 0, 2 }, "the edited symbol and its caller are both stale")
  local by = {}
  for _, row in ipairs(after.stale) do by[row.symbol] = row end
  eq(by[callee.symbol].reason, "code changed", "the edited symbol says why")
  eq(by[entry.symbol].reason, "callee changed", "the caller is stale through its callee")
  eq(by[entry.symbol].changed, { callee.symbol }, "and names the callee that changed")
  eq(after.regenerate, { callee.symbol, entry.symbol }, "regenerate callee first")

  -- the regenerate list is a valid entry list: a tour over it holds exactly the stale symbols, unwritten
  local again = assert(require("code-tour.ast.live").new({ root = root, entries = after.regenerate, cache_dir = t.cache }))
  local seen = {}
  for _, sn in ipairs(again:all()) do seen[sn.symbol] = true end
  check(seen[callee.symbol] and seen[entry.symbol], "a tour over the regenerate list holds the stale symbols")
  check(again:status(again.snippets.n1) ~= "fresh", "and the stale note is not reused as fresh")
end)
