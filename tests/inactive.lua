local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 45, 110
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, cb) cb(true) end
local tour, view = require("tour"), require("code-tour.tour-view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 100 do lines[i] = "local value = " .. i end
vim.fn.writefile(lines, root .. "/one.lua")
vim.fn.writefile(lines, root .. "/two.lua")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function state() return tour.state() end
local ns = vim.api.nvim_create_namespace("CodeTourSource")
local function drawn(buf)
  local text, groups, anchors, highlights = {}, {}, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].line_hl_group then
      local line = mark[2] + 1
      local previous = highlights[line]
      if not previous or mark[4].priority >= previous.priority then
        highlights[line] = { group = mark[4].line_hl_group, priority = mark[4].priority }
      end
    end
    if mark[4].virt_lines then
      anchors[mark[2] + 1] = (anchors[mark[2] + 1] or 0) + 1
      for _, row in ipairs(mark[4].virt_lines) do
        for _, chunk in ipairs(row) do
          text[#text + 1] = chunk[1]
          groups[chunk[2]] = true
        end
      end
    end
  end
  return table.concat(text, "\n"), groups, anchors, highlights
end
local function test()
  tour.setup({ smooth_scroll = false })
  local long = {}
  for i = 1, 50 do long[i] = "Later explanation line " .. i end
  tour.show({
    { file = "one.lua", start = 10, ["end"] = 19, title = "First", note = "Overview of first snippet",
      parts = {
        { start = 10, ["end"] = 14, note = "First part text" },
        { start = 15, ["end"] = 19, note = "Second part text" },
      } },
    { file = "one.lua", start = 50, ["end"] = 55, title = "Later", note = table.concat(long, "\n") },
    { file = "two.lua", start = 5, ["end"] = 8, title = "Other file", note = "Other-file explanation" },
  }, { root = root })
  local buf = state().stops[1].buf
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local text, groups, anchors, highlights = drawn(buf)
  check(text:find("Overview of first snippet", 1, true) and not text:find("First part text", 1, true)
    and not text:find("Second part text", 1, true) and not text:find("Later explanation line 1", 1, true),
    "Only the focused explanation has a visible box")
  check(not text:find("Other-file explanation", 1, true), "Other files are excluded")
  check(highlights[10].group == "CodeTourFocus" and highlights[50].group == "CodeTourStop"
    and highlights[55].group == "CodeTourStop", "Other snippets retain their dim code highlights")
  check(anchors[10] == 1 and not anchors[15] and not anchors[50],
    "Inactive explanations create no virtual rows")
  check(view.state().text:find("Overview of first snippet", 1, true)
    and not view.state().text:find("Later explanation", 1, true), "Active text view stays scoped to current box")
  check(state().note_pages == 1, "Long inactive explanation does not change active pagination")
  tour.next_explanation(1)
  text, groups, anchors, highlights = drawn(buf)
  check(not text:find("Overview of first snippet", 1, true) and not text:find("Second part text", 1, true)
    and highlights[15].group == "CodeTourStop" and highlights[50].group == "CodeTourStop",
    "Changing focus replaces the box while preserving inactive code highlights")
  check(view.state().text == "First part text", "Selection updates active content only")
  tour.ask("First part question", "stay")
  tour.answer("First part answer", "1.2")
  tour.focus()
  local popup = vim.api.nvim_get_current_win()
  local popup_buf = vim.api.nvim_win_get_buf(popup)
  local plain = table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), "\n")
  check(plain:find("First part answer", 1, true) and not plain:find("Second part text", 1, true),
    "Copy view shows selected explanation and its Q&A only")
  tour.next_explanation(1)
  plain = table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), "\n")
  check(plain == "Second part text", "Copy view follows only the focused explanation")
  text = drawn(buf)
  check(not text:find("First part answer", 1, true), "Inactive Q&A stays collapsed")
  tour.focus()
  tour.next_snippet(1)
  check(state().stop == 2 and state().note_pages > 1, "Previously hidden note appears and becomes pageable when focused")
  text, groups, anchors, highlights = drawn(buf)
  check(highlights[10].group == "CodeTourStop" and highlights[50].group == "CodeTourFocus"
    and not anchors[10] and anchors[50] == 1, "Selecting another snippet swaps focus without hiding dim code")
  tour.next_snippet(1)
  local other_buf = state().stops[3].buf
  text, groups = drawn(other_buf)
  check(text:find("Other-file explanation", 1, true), "Switching files displays that file's focused explanation")
  check(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0, "Previous file's decorations are cleared")
  tour.next_snippet(-2)
  text, groups, anchors, highlights = drawn(buf)
  check(not text:find("Later explanation line 1", 1, true) and highlights[50].group == "CodeTourStop",
    "Returning restores inactive code highlights without their boxes")
  check(vim.api.nvim_buf_get_changedtick(buf) == tick and vim.deep_equal(vim.fn.readfile(root .. "/one.lua"), lines),
    "Persistent code highlights preserve source and changedtick")
  check(vim.fn.maparg("<leader>au", "n") == "" and vim.fn.maparg("<leader>ao", "n") ~= "",
    "ao is the sole return key")
  tour.hide()
  check(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0, "Hide clears active and inactive frames")
  tour.stop()
  print("PASS: " .. checks .. " inactive snippet highlight assertions")
end
local ok, err = xpcall(test, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
