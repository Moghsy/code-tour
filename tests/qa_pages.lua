-- Q&A pages: one question per page (long answers span pages), the newest question is shown,
-- and a box above line 1 keeps all its rows after the thread grows.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 150
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _, _, _, cb) cb(true) end
local tour = require("tour")
local view = require("code-tour.tour-view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 60 do lines[i] = "local value = " .. i end
vim.fn.writefile(lines, root .. "/source.lua")
local buf = vim.fn.bufadd(root .. "/source.lua")
vim.fn.bufload(buf)
vim.api.nvim_win_set_buf(0, buf)
local n = 0
local function check(v, m) assert(v, m); n = n + 1 end
local function text() 
  local out = {}
  for _, row in ipairs(view.state().rows) do
    local c = {}
    for _, chunk in ipairs(row) do c[#c + 1] = chunk[1] end
    out[#out + 1] = table.concat(c)
  end
  return table.concat(out, "\n")
end
local function count_of(s, needle)
  local k, from = 0, 1
  while true do
    local a, b = s:find(needle, from, true)
    if not a then return k end
    k, from = k + 1, b + 1
  end
end
local function test()
  tour.setup({ smooth_scroll = false })
  tour.show({ { file = "source.lua", start = 1, ["end"] = 3, title = "Top", note = "Top box." } }, { root = root })
  tour.ask("first question?", "stay")
  tour.answer("first answer", nil)
  tour.ask("second question?", "stay")
  tour.answer("second answer", nil)
  tour.render(false)
  local shown = text()
  check(shown:find("second question?", 1, true) and shown:find("second answer", 1, true), "newest question is on the page")
  check(not shown:find("first question?", 1, true), "never two questions on one page")
  tour.page(-1)
  shown = text()
  check(shown:find("first question?", 1, true) and not shown:find("second question?", 1, true), "previous page is the first question only")
  check(count_of(shown, "Q&A") >= 1, "Q&A frame titled")

  -- a long answer spans pages of its own, never borrowing the next question
  local long = {}
  for i = 1, 60 do long[i] = "line " .. i .. " of a long answer" end
  tour.ask("third question?", "stay")
  tour.answer(table.concat(long, "\n\n"), nil)
  tour.render(false)
  local first = text()
  check(first:find("third question?", 1, true) and not first:find("second question?", 1, true), "long answer page starts at its question")
  local guard = 0
  repeat
    tour.page(-1); guard = guard + 1
    shown = text()
  until shown:find("second question?", 1, true) or guard > 20
  check(shown:find("second answer", 1, true) and not shown:find("third question?", 1, true) and not shown:find("long answer", 1, true), "pages never mix turns")

  -- box above line 1 keeps its rows after the thread grows
  tour.render(true)
  local layout = view.state()
  local info = vim.fn.winsaveview()
  check(info.topline == 1 and info.topfill == #layout.rows, "box at line 1 shows every row (topfill " .. info.topfill .. " vs " .. #layout.rows .. ")")
  tour.ask("fourth question?", "stay")
  info = vim.fn.winsaveview()
  layout = view.state()
  check(info.topline == 1 and info.topfill == #layout.rows, "topfill follows the box when it changes size (" .. info.topfill .. " vs " .. #layout.rows .. ")")
  tour.answer("a short fourth answer", nil)
  info = vim.fn.winsaveview()
  layout = view.state()
  check(info.topfill == #layout.rows, "topfill follows after an answer arrives")
  print("PASS: " .. n .. " Q&A page assertions")
end
local ok, err = xpcall(test, debug.traceback)
if ok then vim.cmd("qa!") else io.stderr:write(err .. "\n"); vim.cmd("cquit 1") end
