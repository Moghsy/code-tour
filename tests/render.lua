local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 150
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, cb)
  cb(true)
end
local tour = require("tour")
local view = require("code-tour.tour-view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 100 do
  lines[i] = string.rep(" ", i == 24 and 60 or 4) .. "local value = " .. i
end
vim.fn.writefile(lines, root .. "/source.lua")
local buf = vim.fn.bufadd(root .. "/source.lua")
vim.fn.bufload(buf)
vim.api.nvim_win_set_buf(0, buf)
local initial_tick = vim.api.nvim_buf_get_changedtick(buf)
local initial_windows = #vim.api.nvim_list_wins()
local count = 0
local function check(value, message)
  assert(value, message)
  count = count + 1
end
local function rows_text(rows)
  local result = {}
  for _, row in ipairs(rows) do
    local chunks = {}
    for _, chunk in ipairs(row) do
      chunks[#chunks + 1] = chunk[1]
    end
    result[#result + 1] = table.concat(chunks)
  end
  return result
end
local function test()
  tour.setup({ smooth_scroll = false })
  tour.show({
    {
      file = "source.lua",
      start = 20,
      ["end"] = 24,
      title = "1. Data flow",
      note = "Explain the local assignments.",
      parts = {
        { start = 20, ["end"] = 21, note = "First two assignments.", example = {
          input = "part-only-input", output = "part-only-output", values = { [20] = "unchanged", [21] = "value = 21" },
        } },
        { start = 22, ["end"] = 23, note = "Next assignments." },
        { start = 24, ["end"] = 24, note = "Indented assignment." },
      },
      example = { input = "value = 0", output = "value = 24", values = {
        [20] = "value = 20", [21] = " unchanged. ", [22] = { value = "UNCHANGED" }, [23] = "", [24] = "value = 24",
      } },
    },
  }, { root = root })
  local state = tour.state()
  local ns = vim.api.nvim_get_namespaces().CodeTourSource
  check(
    #vim.api.nvim_list_wins() == initial_windows + 1 and #vim.api.nvim_tabpage_list_wins(state.tab) == 1,
    "Tour must have one source window and no explanation split"
  )
  check(view.state().buf == buf and view.state().anchor == 20, "Frame must belong to the focused source line")
  check(view.state().width == 100 and view.state().indent == 4, "Frame should follow indentation with a 100-column cap")
  local text = rows_text(view.state().rows)
  check(
    text[2]:find("Snippet 1/1 · Data flow", 1, true)
      and not text[2]:find("· 1.", 1, true)
      and not text[2]:find("Page", 1, true),
    "Title must use Snippet current/total without duplicated numbering or a single-page counter"
  )
  check(text[1] == "" and text[#text] == "", "Frame needs blank rows above and below")
  check(not table.concat(text, "\n"):find("Q&A", 1, true), "Q&A stays hidden until asked")
  local note_at, input_at, output_at
  for row, line in ipairs(text) do
    if line:find("Explain the local assignments", 1, true) then
      note_at = row
    end
    if line:find("input: value = 0", 1, true) then
      input_at = row
    end
    if line:find("output: value = 24", 1, true) then
      output_at = row
    end
    check(
      vim.fn.strdisplaywidth(line) <= view.state().indent + view.state().width,
      "Virtual rows must fit the frame width"
    )
  end
  check(
    note_at and not input_at and not output_at and not table.concat(text, "\n"):find("Example", 1, true)
      and view.state().text == "Explain the local assignments.",
    "Overview contains only the general explanation, without example input/output"
  )
  local annotated = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      if chunk[2] == "CodeTourExample" then annotated[#annotated + 1] = mark[2] + 1 end
    end
  end
  check(vim.deep_equal(annotated, { 20, 24 }), "Only meaningful values render; blank and legacy unchanged annotations stay hidden")
  local footer
  for index, line in ipairs(text) do
    if line:find("ae explain", 1, true) then
      footer = index
    end
  end
  check(
    footer == #text - 1 and text[footer]:find("╰─ ", 1, true) and text[footer]:find("╯", 1, true),
    "Shortcut hints must sit directly in the original bottom border with no extra footer row"
  )
  check(vim.deep_equal(vim.api.nvim__ns_get(ns).wins, { state.win }), "Decorations must be scoped to the tour window")
  tour.next_explanation(1)
  check(view.state().text == "First two assignments.", "Subpart examples also stay outside explanation boxes")
  local other = vim.api.nvim_create_buf(false, true)
  local other_tick = vim.api.nvim_buf_get_changedtick(other)
  vim.api.nvim_buf_set_extmark(other, ns, 0, 0, { virt_text = { { "old tour", "Comment" } } })
  state.stops[1].removed = { { line = 20, above = true, lines = { "removed assignment" } } }
  tour.render(false)
  check(
    #vim.api.nvim_buf_get_extmarks(other, ns, 0, -1, {}) == 0 and vim.api.nvim_buf_get_changedtick(other) == other_tick,
    "Clearing decorations from every buffer must not change text or changedtick"
  )
  local frames, groups = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].virt_lines then
      frames[#frames + 1] = mark
    end
    if mark[4].line_hl_group then
      groups[mark[2] + 1] = mark[4].line_hl_group
    end
  end
  check(
    #frames == 1 and frames[1][2] == 19 and frames[1][4].virt_lines_above,
    "Only the focused explanation box is drawn above its code"
  )
  local merged = rows_text(frames[1][4].virt_lines)
  check(
    merged[#merged]:find("removed assignment", 1, true),
    "Removed text at the anchor follows the box in the same decoration"
  )
  check(
    groups[20] == "CodeTourFocus"
      and groups[21] == "CodeTourFocus"
      and groups[22] == "CodeTourStop"
      and groups[24] == "CodeTourStop",
    "Every snippet line needs the focus or stop background"
  )
  tour.ask("Why two values?", "stay")
  check(
    table.concat(rows_text(view.state().rows), "\n"):find("Q&A", 1, true),
    "Question adds a Q&A frame as virtual rows"
  )
  check(#vim.api.nvim_list_wins() == initial_windows + 1, "Q&A must not open a window")
  tour.focus()
  local popup = vim.api.nvim_get_current_win()
  local config = vim.api.nvim_win_get_config(popup)
  local plain = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup), 0, -1, false), "\n")
  check(
    plain:find("First two assignments.", 1, true)
      and plain:find("Why two values?", 1, true)
      and not plain:find("╭", 1, true)
      and not plain:find("│", 1, true)
      and not plain:find("ae explain", 1, true)
      and not plain:find("part-only-input", 1, true)
      and not plain:find("part-only-output", 1, true),
    "Focus view contains only explanation and Q&A text, without examples, drawn frames or key hints"
  )
  check(
    (type(config.row) == "table" and config.row[false] or config.row)
        == math.floor((vim.o.lines - config.height - 2) / 2)
      and (type(config.col) == "table" and config.col[false] or config.col)
        == math.floor((vim.o.columns - config.width - 2) / 2),
    "Focus view must be centered"
  )
  tour.next_explanation(1)
  plain = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(popup), 0, -1, false), "\n")
  check(
    plain:find("Next assignments.", 1, true) and not plain:find("Why two values?", 1, true),
    "Focus text must track the current explanation box"
  )
  tour.focus()
  check(
    vim.api.nvim_get_current_win() == state.win and not vim.api.nvim_win_is_valid(popup),
    "Closing focus returns to source"
  )
  tour.next_explanation(-1)
  check(
    vim.api.nvim_buf_get_changedtick(buf) == initial_tick and not vim.bo[buf].modified,
    "Rendering and questions must not change source text or changedtick"
  )

  local height = vim.api.nvim_win_get_height(state.win)
  local centered = view.target(state.win, 20, 21, 10)
  check(
    centered.topline == math.max(1, 20 - math.floor((height - 12) / 2)),
    "Fit positioning should center code plus virtual rows"
  )
  local overflowing = view.target(state.win, 20, 100, 10)
  check(
    overflowing.topline == 20 and overflowing.topfill == 10,
    "Overflow positioning must start at the focused line with full topfill"
  )
  local beginning = view.target(state.win, 1, 2, 10)
  check(beginning.topline == 1 and beginning.topfill == 10, "Frames at file start need topfill")

  local neighbor =
    vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = "right", win = state.win, width = 50 })
  vim.api.nvim_win_set_width(state.win, 48)
  tour.next_explanation(2)
  check(
    view.state().width >= 40 and view.state().indent < 60,
    "Deep indentation must leave at least 40 columns for text"
  )
  for _, line in ipairs(rows_text(view.state().rows)) do
    check(vim.fn.strdisplaywidth(line) <= view.state().indent + view.state().width, "Narrow frame must wrap all rows")
  end
  local paragraphs = {}
  for i = 1, 40 do
    paragraphs[i] = "Explanation line " .. i
  end
  state.stops[1].parts[state.box - 1].note = table.concat(paragraphs, "\n")
  tour.render(false)
  check(
    state.note_pages > 1 and table.concat(rows_text(view.state().rows), "\n"):find("Page 1/", 1, true),
    "A paginated explanation should retain a clear page counter"
  )
  vim.api.nvim_win_close(neighbor, true)
  tour.hide()
  check(#vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0, "Hide must remove virtual frames and highlights")
  check(
    vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines),
    "All rendering must preserve source lines"
  )
  tour.stop()
  print("PASS: " .. count .. " inline frame, scoping and positioning assertions")
end
local ok, err = xpcall(test, debug.traceback)
if ok then
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
