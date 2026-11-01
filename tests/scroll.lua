local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:prepend(vim.fn.expand("~/.local/share/nvim/lazy/snacks.nvim"))
local scroll = require("code-tour.scroll")
local ok, err = xpcall(function()
  _G.Snacks = require("snacks")
  Snacks.setup({ scroll = { enabled = true, animate = { duration = { total = 60 } } } })
  local lines = {}
  for i = 1, 200 do
    lines[i] = tostring(i)
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  local win = vim.api.nvim_get_current_win()
  local native_calls = 0
  local original = Snacks.scroll.check
  Snacks.scroll.check = function(...)
    native_calls = native_calls + 1
    return original(...)
  end
  local done = false
  scroll.move(win, function()
    vim.api.nvim_win_set_cursor(win, { 100, 0 })
    vim.cmd("normal! zt")
  end, function()
    done = true
  end)
  assert(
    vim.wait(1000, function()
      return done
    end, 10),
    "Native scroll did not settle"
  )
  assert(native_calls >= 2, "Must delegate to Snacks.scroll")
  assert(vim.fn.line("w0") == 100, "Native scroll must land on the target")
  assert(vim.b.snacks_scroll ~= false, "Must not disable Snacks on the source")
  scroll.move(win, function()
    vim.api.nvim_win_set_cursor(win, { 150, 0 })
    vim.cmd("normal! zt")
  end)
  scroll.move(win, function()
    vim.api.nvim_win_set_cursor(win, { 50, 0 })
    vim.cmd("normal! zt")
  end, function()
    done = "repeat"
  end)
  assert(
    vim.wait(1000, function()
      return done == "repeat"
    end, 10),
    "Repeated navigation did not settle"
  )
  assert(vim.fn.line("w0") == 50, "Repeated navigation must reach the newest target")
  Snacks.scroll.disable()
  scroll.move(win, function()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.cmd("normal! zt")
  end, function()
    done = "disabled"
  end)
  assert(done == "disabled", "Disabled Snacks must use immediate positioning")
  Snacks.scroll.enable()
  require("code-tour.instance").register = function() end
  local tour = require("tour")
  tour.setup()
  local file = vim.fn.tempname()
  vim.fn.writefile(lines, file)
  tour.show({
    {
      file = file,
      start = 10,
      ["end"] = 100,
      note = "A long overview",
      parts = {
        { start = 10, ["end"] = 20, note = "First part" },
        { start = 21, ["end"] = 60, note = "Middle part" },
        { start = 61, ["end"] = 100, note = "Last part" },
      },
    },
  })
  assert(
    vim.wait(2000, function()
      return not scroll.active()
    end, 10),
    "Inline overview did not settle"
  )
  local state = tour.state()
  local tick = vim.api.nvim_buf_get_changedtick(state.stops[1].buf)
  tour.next_explanation(3)
  assert(
    vim.wait(2000, function()
      return not scroll.active()
    end, 10),
    "Inline part did not settle"
  )
  local layout = require("code-tour.tour-view").state()
  local target = require("code-tour.tour-view").target(state.win, 61, 100, #layout.rows)
  local arrived = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
  assert(
    arrived.topline == target.topline and arrived.topfill == target.topfill,
    "Snacks must land with the inline frame above the focused code"
  )
  tour.next_explanation(-1)
  assert(
    vim.wait(2000, function()
      return not scroll.active()
    end, 10),
    "Backward inline navigation did not settle"
  )
  assert(vim.api.nvim_win_get_cursor(state.win)[1] == 21, "Backward inline navigation must select the new part")
  assert(vim.api.nvim_buf_get_changedtick(state.stops[1].buf) == tick, "Inline scrolling must not alter source")
  tour.stop()
  print("PASS: native Snacks scrolling, repeated navigation, disabled fallback, inline frame positioning")
end, debug.traceback)
if ok then
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
