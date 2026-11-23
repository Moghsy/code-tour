-- Lazy graph analysis: communities, hubs, crossings and neighbors over graph.json.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast analysis", function()
  if not t.parser() then
    return
  end
  local ast = require("code-tour.ast")
  local root = t.project()
  local opts = { root = root, cache_dir = t.cache }
  local function view(name, extra)
    return ast.analyze(vim.tbl_extend("force", opts, { view = name }, extra or {}))
  end
  local first = view("communities", { members = true })
  eq(first.cached, false, "first request computes")
  check(first.total >= 2 and #first.communities >= 2, "the fixture splits into several communities")
  local seen, size = {}, 0
  for _, c in ipairs(first.communities) do
    for _, id in ipairs(c.members) do
      check(not seen[id], "a symbol belongs to one community: " .. id)
      seen[id] = true
    end
    size = size + c.size
  end
  eq(size, vim.tbl_count(seen), "sizes add up to the members")
  eq(view("communities").cached, true, "second request reads the cache")
  local again = view("communities", { members = true })
  eq(again.communities, first.communities, "clustering is deterministic")

  local gods = view("gods", { limit = 3 })
  eq(#gods.hubs, 3, "limit applies")
  check(gods.hubs[1].degree >= gods.hubs[2].degree, "hubs are ordered by degree")
  check(view("crossings").crossings, "crossings listed")

  local near = view("neighbors", { symbol = "OrderService#checkout" })
  check(near.symbol:find("OrderService#checkout", 1, true), "neighbors resolves a partial id: " .. near.symbol)
  check(#near.callees > 0 and near.callees[1].confidence, "callees carry their confidence")
  check(not pcall(view, "neighbors", { symbol = "NoSuchThing" }), "an unknown symbol is an error")

  local path = root .. "/src/main/java/shop/order/OrderService.java"
  local lines = vim.fn.readfile(path)
  lines[#lines + 1] = "// touched"
  vim.fn.writefile(lines, path)
  eq(view("communities").cached, false, "a changed source invalidates the cache")
end)
