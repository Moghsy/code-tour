-- Concepts: agent-authored groups of symbols with per-member freshness.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast concepts", function()
  if not t.parser() then
    return
  end
  local ast = require("code-tour.ast")
  local root = t.project()
  local opts = { root = root, cache_dir = t.cache }
  local function call(extra)
    return ast.concepts(vim.tbl_extend("force", opts, extra))
  end
  eq(call({ action = "list" }).concepts, {}, "no concepts until the agent writes one")
  local added = call({ action = "add", name = "Order totalling", summary = "Sums lines and applies discounts.",
    members = { "Order#total", "DiscountPolicy#apply" } })
  eq({ added.id, added.members, added.replaced }, { "order-totalling", 2, false }, "a concept is recorded")
  local listed = call({ action = "list" }).concepts
  eq(#listed, 1, "one concept")
  eq(vim.tbl_map(function(m) return m.status end, listed[1].members), { "fresh", "fresh" }, "members start fresh")
  check(not listed[1].stale, "a fresh concept is not stale")
  eq(call({ action = "add", name = "Order totalling", members = { "Order#total" } }).replaced, true,
    "the same name replaces the concept")

  local near = ast.analyze(vim.tbl_extend("force", opts, { view = "neighbors", symbol = "Order#total" }))
  eq(vim.tbl_map(function(c) return c.id end, near.concepts), { "order-totalling" }, "neighbors lists the concepts of a symbol")
  eq(#ast.analyze(vim.tbl_extend("force", opts, { view = "concepts" })).concepts, 1, "analyze concepts lists them")

  local path = root .. "/src/main/java/shop/order/Order.java"
  local lines = vim.fn.readfile(path)
  for i, line in ipairs(lines) do
    lines[i] = line:gsub("return sum;", "return sum + 0;")
  end
  vim.fn.writefile(lines, path)
  local after = call({ action = "list" }).concepts[1]
  check(after.stale, "changing a member's code makes the concept stale")
  eq(after.members[1].status, "stale", "and says which member")

  check(not pcall(call, { action = "add", name = "Nothing", members = { "NoSuchType#nothing" } }), "unknown members are refused")
  eq(call({ action = "remove", id = "order-totalling" }).removed, true, "a concept can be removed")
  eq(call({ action = "list" }).concepts, {}, "and is gone")
end)
