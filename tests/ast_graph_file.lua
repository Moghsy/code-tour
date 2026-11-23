-- The persisted project graph: .code-tour/graph.json is written once, reused while nothing
-- changed, and rebuilt (incrementally) when a source file or the resolution config changes.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast graph file", function()
  if not t.parser() then
    return
  end
  local ast = require("code-tour.ast")
  local root = t.project()
  local opts = { root = root, cache_dir = t.cache }
  local first = ast.code_graph(opts)
  eq(first.path, vim.uv.fs_realpath(root) .. "/.code-tour/graph.json", "the graph persists beside the notes store")
  eq(first.reused, false, "first build")
  check(first.nodes > 0 and first.links > 0, "graph has nodes and links")
  local decoded = vim.json.decode(table.concat(vim.fn.readfile(first.path), "\n"))
  check(decoded.graph.manifest.files["src/main/java/shop/order/OrderService.java"], "manifest records each file's hash")

  eq(ast.code_graph(opts).reused, true, "unchanged project reuses the graph")
  eq(ast.code_graph(vim.tbl_extend("force", opts, { rebuild = true })).reused, false, "--rebuild forces a build")

  local file = root .. "/src/main/java/shop/order/OrderService.java"
  local lines = vim.fn.readfile(file)
  lines[#lines + 1] = "// touched"
  vim.fn.writefile(lines, file)
  eq(ast.code_graph(opts).reused, false, "a changed file rebuilds")
  eq(ast.code_graph(opts).reused, true, "and the rebuilt graph is reused")

  -- an unsaved edit is part of the identity: the graph is rebuilt, and rebuilt again once it is saved away
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "// unsaved" })
  eq(ast.code_graph(opts).reused, false, "an unsaved buffer rebuilds the graph")
  eq(ast.code_graph(opts).reused, true, "and the same unsaved state reuses it")
  vim.bo[buf].modified = false
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(ast.code_graph(opts).reused, false, "discarding the unsaved edit rebuilds it again")

  ast.options.boundaries = { { call = "x.y", to = "OrderService#checkout" } }
  eq(ast.code_graph(opts).reused, false, "a changed resolution config rebuilds")
  ast.options.boundaries = {}
end)
