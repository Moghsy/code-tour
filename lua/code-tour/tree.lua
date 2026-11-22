-- Terminal view of the tour graph: a diagram of snippet boxes with their calls branching
-- off them, in a floating window or a tab of its own. It reads the graph from
-- graph.lua and never changes the tour; <CR> asks the controller to jump to a snippet.
local M = {}

local view -- { win, buf, tab? } while open
local MAX_TITLE = 56
local GIST_LINES = 3

-- A gist folded onto at most GIST_LINES rows of MAX_TITLE cells, on word boundaries; the
-- last row ends in "…" when the gist runs longer.
local function wrap(text)
  local rows, row = {}, ""
  for word in text:gsub("%s+", " "):gmatch("%S+") do
    local candidate = row == "" and word or row .. " " .. word
    if vim.fn.strdisplaywidth(candidate) <= MAX_TITLE then
      row = candidate
    else
      if row ~= "" then rows[#rows + 1] = row end
      row = word
      if #rows == GIST_LINES then break end
    end
  end
  if #rows < GIST_LINES and row ~= "" then
    rows[#rows + 1], row = row, ""
  end
  for i, r in ipairs(rows) do
    if vim.fn.strdisplaywidth(r) > MAX_TITLE then rows[i] = vim.fn.strcharpart(r, 0, MAX_TITLE - 1) .. "…" end
  end
  if row ~= "" then
    local last = rows[#rows]
    if vim.fn.strdisplaywidth(last) > MAX_TITLE - 1 then last = vim.fn.strcharpart(last, 0, MAX_TITLE - 1) end
    rows[#rows] = last .. "…"
  end
  return rows
end

local function width(text)
  return vim.fn.strdisplaywidth(text)
end

local function where(node)
  return ("%s:%d-%d"):format(vim.fn.fnamemodify(node.source_file, ":~:."), node.start, node["end"])
end

-- A line of a block: text, the node it belongs to (for <CR>), and highlight spans
-- { byte_from, byte_to, group } relative to the start of the line.
local function line(text, node, spans)
  return { text = text, node = node, spans = spans or {} }
end

local function indent(item, prefix, spans)
  local shift = #prefix
  local out = line(prefix .. item.text, item.node, {})
  for _, span in ipairs(spans or {}) do
    out.spans[#out.spans + 1] = span
  end
  for _, span in ipairs(item.spans) do
    out.spans[#out.spans + 1] = { span[1] + shift, span[2] < 0 and -1 or span[2] + shift, span[3] }
  end
  return out
end

-- One snippet as a rounded box: title, the snippet's gist when one is written (AST tours,
-- SPEC-ast-graph §10), then its location. The bottom edge gets a tee when branches hang
-- below it.
local function box(node, title, mark, current, has_children)
  title = (mark ~= "" and mark .. " " or "") .. title
  if width(title) > MAX_TITLE then
    title = vim.fn.strcharpart(title, 0, MAX_TITLE - 1) .. "…"
  end
  local parts = 0
  for _, b in ipairs(node.boxes) do
    if b.role == "part" then parts = parts + 1 end
  end
  local meta = where(node) .. (parts > 0 and ("  ·  %d parts"):format(parts) or "")
  local gist = node.gist and node.gist:find("%S") and wrap(node.gist) or {}
  local inner = math.max(width(title), width(meta), 6) + 2
  for _, text in ipairs(gist) do inner = math.max(inner, width(text) + 2) end
  local edge = current and "CodeTourTreeCurrent" or "CodeTourTreeBorder"
  local function row(text, group)
    local pad = string.rep(" ", inner - 1 - width(text))
    local left = "│ "
    local result = line(left .. text .. pad .. "│", node, { { 0, #left, edge }, { #left + #text + #pad, -1, edge } })
    result.spans[#result.spans + 1] = { #left, #left + #text, group }
    return result
  end
  local bottom = "╰" .. string.rep("─", inner) .. "╯"
  if has_children then
    bottom = "╰─┬" .. string.rep("─", inner - 2) .. "╯"
  end
  local out = {
    line("╭" .. string.rep("─", inner) .. "╮", node, { { 0, -1, edge } }),
    row(title, current and "CodeTourTreeCurrent" or "CodeTourTreeTitle"),
  }
  for _, text in ipairs(gist) do out[#out + 1] = row(text, "CodeTourTreeGist") end
  out[#out + 1] = row(meta, "CodeTourTreeLocation")
  out[#out + 1] = line(bottom, node, { { 0, -1, edge } })
  return out
end

-- Pure part: graph -> lines, line -> node, highlight spans, line of the current node.
-- Top-level snippets run down the left, joined by arrows; each snippet's calls hang
-- off it as indented boxes (▶ on the gold route, ○ optional).
function M.layout(graph, current)
  local nodes, calls = {}, {}
  for _, node in ipairs(graph.nodes) do
    nodes[node.id] = node
  end
  for _, link in ipairs(graph.links) do
    if link.via == "call" and nodes[link.source] and nodes[link.target] then
      calls[link.source] = calls[link.source] or {}
      table.insert(calls[link.source], link)
    end
  end
  local seen = {}
  local function block(node, label, via)
    local reference = seen[node.id]
    seen[node.id] = true
    local mark = node.id == current and "●" or ""
    if node.lazy and not node.pending and mark == "" then mark = "…" end
    local title = label .. (reference and "  ↺" or "")
    local children = (not reference) and calls[node.id] or {}
    local lines = box(node, title, mark, node.id == current, #children > 0)
    for k, link in ipairs(children) do
      local child = nodes[link.target]
      local last = k == #children
      local group = link.relation == "next" and "CodeTourTreeNext" or "CodeTourTreeOptional"
      local arrow = link.relation == "next" and "─▶ " or "┄○ "
      local sub = block(child, child.label, link)
      for i, item in ipairs(sub) do
        if i == 2 then
          local lead = "  " .. (last and "└" or "├")
          lines[#lines + 1] = indent(item, lead .. arrow, { { 2, #lead + #arrow - 1, group } })
        else
          lines[#lines + 1] = indent(item, "  " .. ((last and i > 2) and " " or "│") .. "   ", { { 2, 2 + #"│", group } })
        end
      end
    end
    return lines
  end
  local out, n, previous_had_children = {}, 0, false
  for _, node in ipairs(graph.nodes) do
    if node.root or (node.root == nil and not (function()
      for _, link in ipairs(graph.links) do
        if link.via == "call" and link.target == node.id then return true end
      end
    end)()) then
      n = n + 1
      if n > 1 then
        if previous_had_children then out[#out + 1] = line("", nil) end
        out[#out + 1] = line("  │", nil, { { 2, -1, "CodeTourTreeNext" } })
        out[#out + 1] = line("  ▼", nil, { { 2, -1, "CodeTourTreeNext" } })
      end
      local lines = block(node, ("%d. %s"):format(n, node.label))
      previous_had_children = #(calls[node.id] or {}) > 0
      for _, item in ipairs(lines) do out[#out + 1] = item end
    end
  end
  if #out == 0 then out[1] = line("(empty tour)", nil) end
  local lines, rows, spans, current_line = {}, {}, {}, nil
  for i, item in ipairs(out) do
    lines[i], rows[i] = item.text, item.node
    for _, span in ipairs(item.spans) do
      spans[#spans + 1] = { i - 1, span[1], span[2], span[3] }
    end
    if item.node and item.node.id == current and not current_line and (not out[i - 1] or out[i - 1].node ~= item.node) then
      current_line = i + 1
    end
  end
  return lines, rows, spans, current_line
end

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.close()
  local old = view
  view = nil
  if not old then return end
  if old.tab and vim.api.nvim_tabpage_is_valid(old.tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd(vim.api.nvim_tabpage_get_number(old.tab) .. "tabclose")
  elseif valid(old.win) then
    vim.api.nvim_win_close(old.win, true)
  end
end

function M.is_open()
  return view ~= nil and valid(view.win)
end

local function highlights()
  for name, link in pairs({
    CodeTourTreeCurrent = "CursorLine", CodeTourTreeTitle = "Title", CodeTourTreeNext = "DiagnosticWarn",
    CodeTourTreeOptional = "DiagnosticError", CodeTourTreeLocation = "Comment", CodeTourTreeBorder = "FloatBorder",
    CodeTourTreeGist = "Normal",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

-- mode: "float" | "tab". Opening it again closes it. on_select(node) jumps to a snippet.
function M.open(mode, graph, current, on_select)
  assert(mode == "float" or mode == "tab", "tree view must be 'float' or 'tab'")
  if M.is_open() then
    M.close()
    return
  end
  highlights()
  local lines, rows, spans, current_line = M.layout(graph, current)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local ns = vim.api.nvim_create_namespace("code-tour-tree")
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, span[1], span[2], {
      end_col = span[3] >= 0 and span[3] or nil, end_row = span[3] < 0 and span[1] + 1 or nil,
      hl_group = span[4], hl_eol = span[3] < 0,
    })
  end
  vim.bo[buf].modifiable, vim.bo[buf].bufhidden, vim.bo[buf].filetype = false, "wipe", "code-tour-tree"
  vim.b[buf].snacks_scroll = false
  local win
  if mode == "tab" then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    view = { win = win, buf = buf, tab = vim.api.nvim_get_current_tabpage() }
  else
    local width = 20
    for _, line in ipairs(lines) do width = math.max(width, vim.fn.strdisplaywidth(line)) end
    width = math.min(width + 2, vim.o.columns - 8)
    local height = math.max(1, math.min(vim.o.lines - 6, #lines))
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", style = "minimal", border = "rounded", title = " Code tour ",
      footer = " <CR> go · q close ", footer_pos = "center", width = width, height = height,
      row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    })
    view = { win = win, buf = buf }
  end
  vim.wo[win].wrap, vim.wo[win].cursorline, vim.wo[win].number = false, true, false
  -- The box under the cursor is shaded.
  local mark = vim.api.nvim_create_namespace("code-tour-tree-box")
  local function shade()
    vim.api.nvim_buf_clear_namespace(buf, mark, 0, -1)
    local node = rows[vim.api.nvim_win_get_cursor(win)[1]]
    for i = 1, #lines do
      if node and rows[i] == node then
        vim.api.nvim_buf_set_extmark(buf, mark, i - 1, 0, { line_hl_group = "CursorLine", priority = 10 })
      end
    end
  end
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = shade })
  vim.api.nvim_win_set_cursor(win, { current_line or 1, 0 })
  shade()
  vim.keymap.set("n", "<CR>", function()
    local node = rows[vim.api.nvim_win_get_cursor(win)[1]]
    if not node then return end
    M.close()
    on_select(node)
  end, { buffer = buf, nowait = true })
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, M.close, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() view = nil end })
end

return M
