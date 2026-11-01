-- Inline frames are virtual rows in the source buffer, scoped by the controller.
local M = {}
local model = require("code-tour.model")
local stops = require("code-tour.stops")
local layout
local copy_view
local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function copy_text(enter)
  local width = math.max(1, math.min(100, vim.o.columns - 8))
  local lines = model.wrap(layout.text, width)
  local height = math.max(1, math.min(vim.o.lines - 6, #lines))
  local config = {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    title = " Explanation ",
  }
  if copy_view and not valid(copy_view.win) then
    copy_view = nil
  end
  local buf = copy_view and copy_view.buf or vim.api.nvim_create_buf(false, true)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype, vim.bo[buf].modifiable = "wipe", "markdown", false
  vim.b[buf].snacks_scroll = false
  if copy_view then
    vim.api.nvim_win_set_config(copy_view.win, config)
    copy_view.source = layout.source
  else
    copy_view = { win = vim.api.nvim_open_win(buf, enter, config), buf = buf, source = layout.source }
    for _, key in ipairs({ "q", "<Esc>", "<leader>af" }) do
      vim.keymap.set("n", key, M.focus, { buffer = buf })
    end
  end
end

function M.close()
  local old = copy_view
  copy_view, layout = nil, nil
  if old and valid(old.win) then
    vim.api.nvim_win_close(old.win, true)
  end
end

-- An explicit copy view is optional; the tour itself never opens a box window.
function M.focus()
  if copy_view then
    local old = copy_view
    copy_view = nil
    if valid(old.win) then
      vim.api.nvim_win_close(old.win, true)
    end
    if valid(old.source) then
      vim.api.nvim_set_current_win(old.source)
    end
    return
  end
  if not layout or layout.text == "" then
    return
  end
  copy_text(true)
end

local function frame(rows, lines, title, width, indent, footer)
  local border, meta, body = "FloatBorder", "CodeTourMeta", "Normal"
  title = model.wrap(title, width - 6)[1]
  rows[#rows + 1] = {
    { string.rep(" ", indent) .. "╭─ ", border },
    { title, meta },
    { " " .. string.rep("─", math.max(0, width - vim.fn.strdisplaywidth(title) - 5)) .. "╮", border },
  }
  for _, line in ipairs(lines) do
    rows[#rows + 1] = {
      { string.rep(" ", indent) .. "│ ", border },
      { line .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(line) - 4)), body },
      { " │", border },
    }
  end
  if footer then
    rows[#rows + 1] = {
      { string.rep(" ", indent) .. "╰─ ", border },
      { footer, meta },
      { " " .. string.rep("─", math.max(0, width - vim.fn.strdisplaywidth(footer) - 5)) .. "╯", border },
    }
  else
    rows[#rows + 1] =
      { { string.rep(" ", indent) .. "╰" .. string.rep("─", math.max(0, width - 2)) .. "╯", border } }
  end
end

local function footer_hint(width, branch, nested)
  local choices = nested and {
    "ad inspect call · ao back · aj/ak next/prev box · af text view · a[/a] prev/next page",
    "ad inspect call · ao back · af text view · ar ask",
    "ad inspect · ao back · af view",
    "ad inspect · af text view",
  } or branch and {
    "ad inspect call · aj/ak next/prev box · af text view · ar ask · a[/a] prev/next page",
    "ad inspect call · af text view · ar ask",
    "ad inspect · af text view",
  } or {
    "ae explain · aE explain+context · af text view · ar ask · az recenter · a[/a] prev/next page",
    "ae explain · aE explain+context · af text view · ar ask",
    "ae explain · af text view · ar ask",
    "ae explain · af text view",
  }
  vim.list_extend(choices, { "af text view · ar ask", "af text view", "af view" })
  for _, text in ipairs(choices) do
    if vim.fn.strdisplaywidth(text) <= width - 6 then
      return text
    end
  end
end

local function thread_lines(box)
  local thread = {}
  for _, turn in ipairs(box.thread) do
    thread[#thread + 1] = "Q: " .. turn.question
    thread[#thread + 1] = turn.answer and ("A: " .. turn.answer)
      or (turn.error and ("Delivery: " .. turn.error) or "Waiting for answer…")
  end
  return thread
end

function M.build(state, stop, box)
  local info = vim.fn.getwininfo(state.win)[1]
  local available = math.max(4, vim.api.nvim_win_get_width(state.win) - info.textoff)
  local first = math.min(box.start, vim.api.nvim_buf_line_count(stop.buf))
  local code_indent = vim.api.nvim_win_call(state.win, function()
    return vim.fn.indent(first)
  end)
  local indent = math.min(code_indent, math.max(0, available - 40))
  local width = math.min(100, available - indent)
  local height = vim.api.nvim_win_get_height(state.win)
  local minimum_code = math.min(box["end"] - box.start + 1, math.max(3, math.floor(height / 3)))
  local has_qa = #box.thread > 0
  local calls = stops.calls_in(state.stops, stop, box)
  local hints = footer_hint(width, #calls > 0, stop._parent_stop)
  local overhead = 4 + (has_qa and 2 or 0)
  local budget = math.max(1, math.min(state.opts.page_lines or 18, height - minimum_code - overhead))
  local note_capacity = has_qa and math.max(1, math.floor(budget / 2)) or budget
  local note = box.note
  local notes = model.pages(note, width - 4, note_capacity)
  state.note_page = math.max(1, math.min(state.note_page or 1, #notes))
  local thread = thread_lines(box)
  local qa = has_qa
      and model.pages(table.concat(thread, "\n\n"), width - 4, math.max(1, budget - #notes[state.note_page]))
    or nil
  state.page = qa and math.max(1, math.min(state.page or 1, #qa)) or 1
  state.note_pages, state.qa_pages = #notes, qa and #qa or 1
  local rows = { { { "", "Normal" } } }
  local name = (stop.title or "Snippet"):gsub("^%s*%d+[.)]%s+", "", 1)
  local snippet, total = stops.snippet_position(state.stops, stop)
  local counter = ("Snippet %s/%d"):format(snippet or "…", total)
  if state.box > 1 then
    counter = counter .. (" · Part %d/%d"):format(state.box - 1, #stop.parts)
  end
  local page = #notes > 1 and (" · Page %d/%d"):format(state.note_page, #notes) or ""
  local name_width = width - 6 - vim.fn.strdisplaywidth(counter .. " · " .. page)
  local title = counter .. page
  if name_width > 0 then title = counter .. " · " .. model.wrap(name, name_width)[1] .. page end
  frame(rows, notes[state.note_page], title, width, indent, not qa and hints or nil)
  if qa then
    local qa_title = #qa > 1 and ("Q&A · Page %d/%d"):format(state.page, #qa) or "Q&A"
    frame(rows, qa[state.page], qa_title, width, indent, hints)
  end
  rows[#rows + 1] = { { "", "Normal" } }
  local result = {
    source = state.win,
    buf = stop.buf,
    anchor = first,
    first = first,
    above = true,
    rows = rows,
    width = width,
    indent = indent,
    text = note .. (has_qa and ("\n\nQ&A\n" .. table.concat(thread, "\n\n")) or ""),
  }
  layout = result
  if copy_view then
    copy_text(false)
  end
  return layout
end

function M.target(win, first, last, virtual_count, above)
  local height = vim.api.nvim_win_get_height(win)
  local span = last - first + 1 + virtual_count
  local top = span <= height and math.max(1, first - math.floor((height - span) / 2)) or first
  return { lnum = first, col = 0, topline = top,
    topfill = above ~= false and top == first and virtual_count or 0, skipcol = 0 }
end

function M.state()
  return layout
end
return M
