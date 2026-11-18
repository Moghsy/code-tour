-- A stationary, selectable explanation window. Only the source viewport scrolls.
local M = {}
local dock
local ns = vim.api.nvim_create_namespace("CodeTourSelectable")

local function valid(win) return win and vim.api.nvim_win_is_valid(win) end

local function cells(chunks)
  local count = 0
  for _, chunk in ipairs(chunks) do count = count + vim.fn.strdisplaywidth(chunk[1]) end
  return count
end

function M.hints(width, _, count)
  local rows, row = {}, {}
  local keys = require("code-tour.keys")
  local function item(label, text) return label and (text and (label .. " " .. text) or label) or nil end
  local items = {
    keys.pair("next", "prev"), keys.pair("next_snippet", "prev_snippet"),
    item(keys.label("list"), "list"), item(keys.label("ask"), "ask"),
    item(keys.label("text_view"), "select"), item(keys.label("stop"), "stop"),
  }
  items = vim.tbl_filter(function(x) return x end, items)
  if count and count > 1 and keys.pair("page_prev", "page_next") then
    table.insert(items, math.min(3, #items + 1), keys.pair("page_prev", "page_next") .. " pages")
  end
  for _, item in ipairs(items) do
    local chunks = { { item, "CodeTourMeta" } }
    if #row > 0 and cells(row) + 3 + cells(chunks) > width then rows[#rows + 1] = row; row = {} end
    if #row > 0 then row[#row + 1] = { " · ", "CodeTourMeta" } end
    vim.list_extend(row, chunks)
  end
  if #row > 0 then rows[#rows + 1] = row end
  return rows
end

function M.focused()
  return dock and valid(dock.win) and vim.api.nvim_get_current_win() == dock.win
end

function M.blur()
  if dock and vim.api.nvim_win_is_valid(dock.origin) then vim.api.nvim_set_current_win(dock.origin) end
end

function M.close()
  local old = dock
  dock = nil
  if old and valid(old.win) then vim.api.nvim_win_close(old.win, true) end
  if old then
    if vim.api.nvim_buf_is_valid(old.buf) then vim.api.nvim_buf_delete(old.buf, { force = true }) end
    if old.source and vim.api.nvim_buf_is_valid(old.source.buf) then
      vim.b[old.source.buf].snacks_scroll = old.source.snacks_scroll
    end
  end
  if old and vim.api.nvim_win_is_valid(old.origin) then
    vim.wo[old.origin].scrolloff = old.scrolloff
    vim.api.nvim_set_current_win(old.origin)
  end
end

function M.ensure(state, opts, source_buf)
  if dock and (not valid(dock.win) or dock.origin ~= state.codewin) then M.close() end
  local width = math.max(4, vim.api.nvim_win_get_width(state.codewin) - 4)
  local total = vim.api.nvim_win_get_height(state.codewin)
  if dock then total = total + vim.api.nvim_win_get_height(dock.win) + 1 end
  local hints = #M.hints(width, 1, 2)
  local minimum_code = math.max(3, math.min(12, math.floor(total / 2)))
  local height = math.max(5, math.min(opts.page_lines + 3 + hints, total - minimum_code - 1))
  if not dock then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "markdown"
    vim.b[buf].snacks_scroll = false
    local win = vim.api.nvim_open_win(buf, false, { split = "above", win = state.codewin, height = 1 })
    dock = { buf = buf, win = win, origin = state.codewin, scrolloff = vim.wo[state.codewin].scrolloff }
    for key, value in pairs({ number = false, relativenumber = false, wrap = false, conceallevel = 0,
      signcolumn = "no", foldcolumn = "0", scrolloff = 0, sidescrolloff = 0, winfixheight = true,
      winfixbuf = true, winbar = "", statuscolumn = "",
      winhighlight = "Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat" }) do
      vim.wo[win][key] = value
    end
    for _, key in ipairs({ "q", "<Esc>" }) do vim.keymap.set("n", key, M.blur, { buffer = buf, desc = "Return to source" }) end
    vim.keymap.set("n", "]p", function() require("code-tour").page(1) end, { buffer = buf, desc = "Next explanation page" })
    vim.keymap.set("n", "[p", function() require("code-tour").page(-1) end, { buffer = buf, desc = "Previous explanation page" })
  end
  -- Keep ownership across redraws and arrival, when WinScrolled is delivered.
  -- Re-enabling another animator at the end of each move can replay that move
  -- and restore its old scrolloff, pulling the selected section off the top.
  local snippet = state.data and state.data.snippets[state.snippet]
  source_buf = source_buf or (snippet and snippet.buf) or vim.api.nvim_win_get_buf(state.codewin)
  if not dock.source or dock.source.buf ~= source_buf then
    if dock.source and vim.api.nvim_buf_is_valid(dock.source.buf) then
      vim.b[dock.source.buf].snacks_scroll = dock.source.snacks_scroll
    end
    dock.source = { buf = source_buf, snacks_scroll = vim.b[source_buf].snacks_scroll }
  end
  vim.b[source_buf].snacks_scroll = false
  vim.wo[state.codewin].scrolloff = 0
  state.page_capacity = math.max(1, height - 3 - hints)
  return width, state.page_capacity
end

function M.motion(label)
  if not dock or not vim.api.nvim_buf_is_valid(dock.buf) then return end
  local width = math.max(1, vim.api.nvim_win_get_width(dock.origin) - 4)
  if dock.motion then pcall(vim.api.nvim_buf_del_extmark, dock.buf, ns, dock.motion); dock.motion = nil end
  if not label then return end
  label = label .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(label)))
  dock.motion = vim.api.nvim_buf_set_extmark(dock.buf, ns, vim.api.nvim_buf_line_count(dock.buf) - 1, 0, {
    virt_text = { { label, "CodeTourMeta" } }, virt_text_win_col = 2, priority = 250,
  })
end

function M.resize(height)
  if not dock or not valid(dock.win) or not valid(dock.origin) then return false end
  if vim.api.nvim_win_get_height(dock.win) == height then return false end
  local saved = vim.api.nvim_win_call(dock.origin, vim.fn.winsaveview)
  vim.api.nvim_win_set_height(dock.win, height)
  vim.api.nvim_win_call(dock.origin, function() vim.fn.winrestview(saved) end)
  return true
end

function M.transition(height)
  local current = dock
  local from = vim.api.nvim_win_get_height(current.win)
  return function(progress)
    if dock ~= current then return false end
    return M.resize(math.floor(from + (height - from) * progress + 0.5))
  end
end

function M.update(state)
  if not dock then return end
  M.resize(state.box_height)
  local buf, width = dock.buf, vim.api.nvim_win_get_width(dock.origin)
  local cursor = valid(dock.win) and vim.api.nvim_win_get_cursor(dock.win) or { 1, 0 }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, state.box_lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  dock.motion = nil
  for line, text in ipairs(state.box_lines) do
    local row = line - 1
    if state.line_styles[line] ~= "NormalFloat" then
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { end_col = #text, hl_group = state.line_styles[line], priority = 150 })
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { "│ ", "FloatBorder" } }, virt_text_pos = "inline" })
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = { { " │", "FloatBorder" } }, virt_text_win_col = width - 2 })
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = { state.virtual_lines[1] }, virt_lines_above = true, virt_lines_leftcol = true })
  vim.api.nvim_buf_set_extmark(buf, ns, #state.box_lines - 1, 0, {
    virt_lines = { state.virtual_lines[#state.virtual_lines] }, virt_lines_above = false, virt_lines_leftcol = true })
  if valid(dock.win) then
    vim.api.nvim_win_call(dock.win, function()
      vim.fn.winrestview({ topline = 1, topfill = 1, lnum = math.min(cursor[1], #state.box_lines), col = 0 })
    end)
  end
  M.motion(state.motion_label)
end

function M.open()
  if dock and valid(dock.win) then vim.api.nvim_set_current_win(dock.win) end
end

function M.refocus() M.open() end
function M.state() return dock end
return M
