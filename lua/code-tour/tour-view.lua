-- Inline frames are virtual rows in the source buffer, scoped by the controller.
local M = {}
local model = require("code-tour.model")
local stops = require("code-tour.stops")
local markdown = require("code-tour.markdown")
local layout
local copy_view
local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function copy_text(enter)
  if not layout then return end
  if layout.current_text then layout.text = layout.current_text() end
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
  pcall(vim.treesitter.start, buf, "markdown")
  if copy_view then
    vim.api.nvim_win_set_config(copy_view.win, config)
    copy_view.source = layout.source
  else
    copy_view = { win = vim.api.nvim_open_win(buf, enter, config), buf = buf, source = layout.source }
    vim.wo[copy_view.win].conceallevel = 2
    for _, key in ipairs({ "q", "<Esc>", require("code-tour.keys").lhs("text_view") }) do
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
  if layout.guard and not layout.guard() then
    require("code-tour.tour").render(false)
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
    local row, used = { { string.rep(" ", indent) .. "│ ", border } }, 0
    for _, chunk in ipairs(line) do
      row[#row + 1] = chunk
      used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    row[#row + 1] = { string.rep(" ", math.max(0, width - used - 4)), body }
    row[#row + 1] = { " │", border }
    rows[#rows + 1] = row
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
  local keys = require("code-tour.keys")
  -- Each entry is "{action} text" or "{a/b} text"; entries whose keys are unmapped drop out.
  local function build(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
      local spec, text = entry[1], entry[2]
      local first, second = spec:match("^(.-)/(.+)$")
      local label = second and keys.pair(first, second) or keys.label(spec)
      if label then parts[#parts + 1] = label .. " " .. text end
    end
    return table.concat(parts, " · ")
  end
  local choices = nested and {
    build({ { "inspect", "inspect call" }, { "back", "back" }, { "next/prev", "next/prev box" }, { "text_view", "text view" }, { "page_prev/page_next", "prev/next page" } }),
    build({ { "inspect", "inspect call" }, { "back", "back" }, { "text_view", "text view" }, { "ask", "ask" } }),
    build({ { "inspect", "inspect" }, { "back", "back" }, { "text_view", "view" } }),
    build({ { "inspect", "inspect" }, { "text_view", "text view" } }),
  } or branch and {
    build({ { "inspect", "inspect call" }, { "next/prev", "next/prev box" }, { "text_view", "text view" }, { "ask", "ask" }, { "page_prev/page_next", "prev/next page" } }),
    build({ { "inspect", "inspect call" }, { "text_view", "text view" }, { "ask", "ask" } }),
    build({ { "inspect", "inspect" }, { "text_view", "text view" } }),
  } or {
    build({ { "explain", "explain" }, { "explain_context", "explain+context" }, { "text_view", "text view" }, { "ask", "ask" }, { "recenter", "recenter" }, { "page_prev/page_next", "prev/next page" } }),
    build({ { "explain", "explain" }, { "explain_context", "explain+context" }, { "text_view", "text view" }, { "ask", "ask" } }),
    build({ { "explain", "explain" }, { "text_view", "text view" }, { "ask", "ask" } }),
    build({ { "explain", "explain" }, { "text_view", "text view" } }),
  }
  vim.list_extend(choices, {
    build({ { "text_view", "text view" }, { "ask", "ask" } }),
    build({ { "text_view", "text view" } }),
    build({ { "text_view", "view" } }),
  })
  for _, text in ipairs(choices) do
    if text ~= "" and vim.fn.strdisplaywidth(text) <= width - 6 then
      return text
    end
  end
end

local function thread_lines(box)
  local thread = {}
  if box._saved and box._saved.status ~= "ready" then return thread end
  for _, turn in ipairs(box.thread) do
    thread[#thread + 1] = "**Q:** " .. turn.question
    if turn.answer then
      -- Block-level answers (headings, lists, code) start below the label.
      local block = turn.answer:match("^%s*[#>|`~]") or turn.answer:match("^%s*[-*+] ") or turn.answer:match("^%s*%d+[.)] ")
      thread[#thread + 1] = (block and "**A:**\n" or "**A:** ") .. turn.answer
    else
      thread[#thread + 1] = turn.error and ("*Delivery:* " .. turn.error) or "*Waiting for answer…*"
    end
  end
  return thread
end

function M.build(state, stop, box)
  local note, ready = stops.note(box)
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
  local has_qa = ready and #box.thread > 0
  local calls = stops.calls_in(state.stops, stop, box)
  local hints = footer_hint(width, #calls > 0, stop._parent_stop)
  local overhead = 4 + (has_qa and 2 or 0)
  local budget = math.max(1, math.min(state.opts.page_lines or 18, height - minimum_code - overhead))
  local note_capacity = has_qa and math.max(1, math.floor(budget / 2)) or budget
  local notes = markdown.pages(note, width - 4, note_capacity)
  state.note_page = math.max(1, math.min(state.note_page or 1, #notes))
  local thread = thread_lines(box)
  local qa = has_qa
      and markdown.pages(table.concat(thread, "\n\n"), width - 4, math.max(1, budget - #notes[state.note_page]))
    or nil
  state.page = qa and math.max(1, math.min(state.page or 1, #qa)) or 1
  state.note_pages, state.qa_pages = #notes, qa and #qa or 1
  local rows = { { { "", "Normal" } } }
  local name = (stop.title or "Snippet"):gsub("^%s*%d+[.)]%s+", "", 1)
  local snippet, total = stops.snippet_position(state.stops, stop)
  local counter = ("Snippet %s/%d"):format(snippet or "…", total)
  -- Walk mode numbers every walked snippet in reading order; branches off the walk are optional.
  local numbers = state.snippet_numbers and state.snippet_numbers()
  if numbers then
    local index
    for i, item in ipairs(state.stops) do
      if item == stop then index = i end
    end
    local own, owner = index and numbers.by_stop[index], index and numbers.owner[index]
    if own then
      counter = ("Snippet %s/%d"):format(stop.stream and stop.placeholder and "…" or tostring(own), #numbers.order)
    elseif owner then
      counter = ("Snippet %d/%d · optional"):format(owner, #numbers.order)
    else
      counter = "Optional snippet"
    end
    if (numbers.folded or 0) > 0 then
      counter = counter .. (" · +%d folded"):format(numbers.folded)
    end
  end
  if state.box > 1 then
    if stops.nested(stop) then
      -- A tree of parts: show where this one sits in it, and its position in reading order.
      counter = counter .. (" · Part %s (%d/%d)"):format(stops.path(stop, box), state.box - 1, #stop.parts)
    else
      counter = counter .. (" · Part %d/%d"):format(state.box - 1, #stop.parts)
    end
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
    guard = function() return stops.note(box) == note end,
    current_text = function()
      local current_note, available_note = stops.note(box)
      local current_thread = available_note and thread_lines(box) or {}
      return current_note .. (#current_thread > 0 and ("\n\nQ&A\n" .. table.concat(current_thread, "\n\n")) or "")
    end,
    cursor_col = box.byte_range and box.byte_range.start[2] or nil,
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
