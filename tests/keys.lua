vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local tour = require("code-tour")
tour.setup({ keys = { next = "<C-j>", prev = "<C-k>", ask = false, page_next = false }, agent = "clipboard" })
local function mapped(lhs, mode) return vim.fn.maparg(lhs, mode or "n", false, true).desc or "" end
assert(mapped("<C-j>") == "CodeTour next", mapped("<C-j>"))
assert(mapped("<leader>aj") == nil or mapped("<leader>aj") == "", "old default still mapped")
assert(mapped("<leader>ar") == "" and mapped("<leader>ar", "x") == "", "disabled key still mapped")
assert(mapped("<leader>ae", "x") == "CodeTour explain (selection)")
local keys = require("code-tour.keys")
assert(keys.pair("next", "prev") == "<C-j>/<C-k>")
assert(keys.label("ask") == nil and keys.label("text_view") == "af")
local rows = require("code-tour.view").hints(120, 1, 2)
local text = vim.inspect(rows)
assert(text:find("<C%-j>/<C%-k>") and not text:find("ar ask"), text)
-- keys = false clears everything
tour.setup({ keys = false })
assert(mapped("<C-j>") == "" and mapped("<leader>aj") == "", "keys=false left maps")
assert(keys.label("next") == nil)
assert(not pcall(tour.setup, { keys = { bogus = "x" } }))
assert(not pcall(tour.setup, { agent = "tmux" }))
-- custom backend receives the prompt
local got
tour.setup({ agent = { send = function(text, action, done) got = { text, action }; done(true) end } })
local c = require("code-tour.conversation")
local result
c.deliver(nil, "/tmp", "hello", "stay", function(ok, err) result = { ok, err } end, function() end, { send = function(t, a, d) got = { t, a }; d(true) end })
vim.wait(500, function() return result ~= nil end)
assert(got[1] == "hello" and got[2] == "stay" and result[1] == true)
-- clipboard backend copies text
local copied
c.deliver(nil, "/tmp", "pasteme", "stay", function(ok, err) copied = { ok, err } end, function() end, "clipboard")
assert(copied[1] and vim.fn.getreg('"') == "pasteme" and copied[2]:find("paste"))
print("keys+agent OK")
