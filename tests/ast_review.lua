-- `code-tour ast --review` (SPEC-ast-graph §9.1): changed symbols become the entries,
-- changes outside them are warnings, the editor shows the diff and the store is untouched.
--   nvim --clean --headless -l tests/ast_review.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

vim.o.lines, vim.o.columns = 50, 140
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _, _, _, cb)
  if cb then
    cb(true)
  end
end
vim.notify = function() end

t.finish("ast review", function()
  if not t.parser() then
    return
  end
  local tour = require("tour")
  tour.setup({ keys = false, smooth_scroll = false })
  local root = t.project()
  local file = t.java .. "shop/order/OrderService.java"
  local path = root .. "/" .. file
  local function changes()
    return require("code-tour.ast.changes").collect(t.index(root), "HEAD")
  end
  local function outline(opts)
    return require("code-tour.ast").outline(nil,
      vim.tbl_extend("force", { root = root, cache_dir = t.cache, review = true }, opts or {}))
  end

  eq(changes().files, 0, "a clean tree has no changes")
  check(not pcall(outline), "reviewing a clean tree is an error")
  check(not pcall(outline, { base = "missing-ref" }), "an invalid base is an error")

  vim.fn.writefile({ "notes" }, root .. "/NOTES.txt")
  local only = outline()
  check(only.fallback and only.reason:find("NOTES.txt", 1, true), "no covered symbol falls back, naming the files")

  local lines = vim.fn.readfile(path)
  local first
  for i, line in ipairs(lines) do
    if line:find("checkout(", 1, true) then
      first = i
      break
    end
  end
  assert(first, "fixture has checkout")
  table.insert(lines, first + 1, "    int reviewed = 1;")
  table.insert(lines, 2, "import java.util.UUID;")
  vim.fn.writefile(lines, path)

  local found = changes()
  eq(#found.entries, 1, "one changed method")
  check(found.entries[1]:find("OrderService#checkout", 1, true), "the changed method is the entry")
  check(table.concat(found.uncovered, "; "):find(file .. ":2", 1, true), "the import is reported as uncovered")
  local dry = outline()
  check(dry.outline:find("changed outside any symbol: " .. file .. ":2", 1, true), "the outline warns")

  local result = tour.ast_tour({ review = true, root = root, cache_dir = t.cache })
  check(result.outline:find("review against HEAD", 1, true), "the outline says it is a review")
  local s = tour.state()
  eq({ s.review, s.base }, { true, "HEAD" }, "the editor is in review mode")
  check(next(s.stops[1].added) ~= nil, "added lines are marked")
  tour.fill("n1", "## overview\nReview gist.\n", { tour = s.id })
  eq(vim.fn.glob(root .. "/.code-tour/notes/*"), "", "review notes are not stored")
  tour.ast_adjust({ detail = "detailed" })
  check(tour.state().ast.review_base == "HEAD", "a detail change keeps the review")
end)
