-- Reopening a saved tour from the editor: stored notes are reused, and the agent is sent a
-- "write" request for exactly the boxes that are missing or stale (and nothing for fresh ones).
--   nvim --clean --headless -l tests/ast_reopen.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

vim.o.lines, vim.o.columns = 50, 140
require("code-tour.instance").register = function() end
local sent = {}
require("code-tour.conversation").deliver = function(_, _, prompt, _, cb)
  sent[#sent + 1] = prompt
  if cb then cb(true) end
end
vim.notify = function() end

t.finish("ast reopen", function()
  if not t.parser() then
    return
  end
  local tour = require("tour")
  tour.setup({ keys = false, smooth_scroll = false })
  local root = t.project()
  local live = assert(require("code-tour.ast.live").new({ root = root, entries = { "OrderService#checkout" },
    overrides = t.route(), cache_dir = t.cache, detail = "overview" }))
  live:fill("n1", "## overview\nCharge the order.\n\nBody.")
  live:fill("n2", "## overview\nSum the lines.\n\nSum.")
  local id = live:remember()
  local recipe = assert(live.store:recipe(id))

  local function reopen()
    sent = {}
    tour.ast_tour({ root = root, recipe = recipe, send = true, cache_dir = t.cache })
    return table.concat(sent, "\n---\n")
  end
  local function lines_with(text, pattern)
    local found = {}
    for line in text:gmatch("[^\n]+") do
      if line:match("^n%d+ ") and line:find(pattern, 1, true) then found[#found + 1] = line end
    end
    return found
  end

  local first = reopen()
  eq(#sent, 1, "one request goes to the agent")
  check(first:find("[code-tour ast] write", 1, true), "it is a write request")
  eq(#lines_with(first, "OrderService.checkout"), 0, "a fresh note is not requested")
  eq(#lines_with(first, "Order.total"), 0, "nor is the other fresh one")
  check(#lines_with(first, "Line.subtotal") == 1, "a symbol never explained is requested")

  local path = root .. "/src/main/java/shop/order/Order.java"
  local lines = vim.fn.readfile(path)
  for i, line in ipairs(lines) do lines[i] = line:gsub("return sum;", "return sum + 0;") end
  vim.fn.writefile(lines, path)
  local after = reopen()
  eq(#lines_with(after, "Order.total"), 1, "an edited symbol is requested again")
  eq(#lines_with(after, "OrderService.checkout"), 1, "and so is its caller")
  check(#lines_with(after, "Line.subtotal") == 1, "missing ones are still requested")
end)
