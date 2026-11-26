-- Index reuse, remembered lookup misses, per-language greps, deadlines and path spelling.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

t.finish("AST cache", function()
  if not t.parser() then return end
  local ast = require("code-tour.ast")
  local deadline = require("code-tour.ast.deadline")
  local root = t.project()
  local opts = { root = root, cache_dir = t.cache }

  local idx = ast.cached_index(opts)
  t.eq(ast.cached_index(opts), idx, "An unchanged project reuses its index")

  -- every git grep, as { argument... }
  local greps, system = {}, vim.system
  vim.system = function(cmd, ...)
    if cmd[4] == "grep" then greps[#greps + 1] = cmd end
    return system(cmd, ...)
  end
  t.eq(idx:type("shop.order.SdkException"), nil, "An unknown type is not found")
  t.eq(#greps, 1, "It is searched once")
  t.eq(greps[1][#greps[1]], "*.java", "The search is limited to the language's files")
  idx:type("shop.order.SdkException")
  idx:declarations_named("SdkException", "java")
  t.eq(#greps, 1, "A name that was not found is not searched again")
  vim.system = system

  local path = root .. "/" .. t.java .. "shop/order/Order.java"
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "// unsaved" })
  local unsaved = ast.cached_index(opts)
  t.check(unsaved ~= idx, "An unsaved edit builds a new index")
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  local saved = ast.cached_index(opts)
  t.check(saved ~= unsaved, "A changed file builds a new index")
  vim.fn.writefile({ "package shop.order;", "class SdkException {}" }, root .. "/" .. t.java .. "shop/order/SdkException.java")
  t.check(ast.cached_index(opts):type("shop.order.SdkException"), "A new file is seen, past remembered misses")

  local current = ast.cached_index(opts)
  current:facts(t.java .. "shop/order/Order.java")
  local ok, why = pcall(deadline.run, 0, function() current:facts(t.java .. "shop/order/Order.java") end)
  t.check(not ok and why:find("was stopped", 1, true), "Work past its deadline stops")
  t.eq(next(current.loaded), nil, "A stopped request leaves no half-resolved facts")
  t.check(ast.cached_index(opts) ~= current, "and its index is not reused")
  t.check(current:facts(t.java .. "shop/order/Order.java"), "The index still works without a deadline")

  local link = vim.fn.tempname() .. "-link"
  vim.uv.fs_symlink(root, link)
  local linked = ast.index({ root = link, cache_dir = t.cache })
  local rel = t.java .. "shop/order/Order.java"
  t.eq(linked.root, idx.root, "A symlinked root is the same root")
  for _, spelled in ipairs({ link .. "/" .. rel, root .. "/" .. rel, root .. "/./src/../" .. rel }) do
    t.eq(linked:rel(spelled), rel, "One project path for " .. spelled)
  end
  linked.cwd = root .. "/" .. t.java .. "shop"
  local rt = require("code-tour.ast.route").new(linked)
  t.check(rt:resolve_entry("order/Order.java:10"), "path:line resolves against the caller's directory")
end)
