-- Terminal view of the tour graph: an indented outline of the snippets and the calls
-- between them, in a floating window or a tab of its own. It reads the graph from
-- graph.lua and never changes the tour; <CR> asks the controller to jump to a snippet.
local M = {}

local ICON = { next = "▶", optional = "○" }
local view -- { win, buf, tab? } while open

-- Pure part: graph -> lines, line -> node, highlight spans, line of the current node.
function M.outline(graph, current)
  local nodes, calls, called = {}, {}, {}
  for _, node in ipairs(graph.nodes) do
    nodes[node.id] = node
  end
  for _, link in ipairs(graph.links) do
    if link.via == "call" and nodes[link.source] and nodes[link.target] then
      calls[link.source] = calls[link.source] or {}
      table.insert(calls[link.source], link)
      called[link.target] = true
    end
  end
  local lines, rows, spans, current_line = {}, {}, {}, nil
  local seen = {}
  local function add(text, node, spec)
    lines[#lines + 1] = text
    rows[#lines] = node
    local row = #lines - 1
    for _, span in ipairs(spec or {}) do
      spans[#spans + 1] = { row, span[1], span[2], span[3] }
    end
    if node and node.id == current and not current_line then
      current_line = #lines
      spans[#spans + 1] = { row, 0, -1, "CodeTourTreeCurrent" }
    end
  end
  local function where(node)
    return ("%s:%d-%d"):format(vim.fn.fnamemodify(node.source_file, ":~:."), node.start, node["end"])
  end
  local function visit(node, prefix, label, via, last)
    local ref = seen[node.id]
    seen[node.id] = true
    local branch = via and (prefix .. (last and "└─" or "├─")) or prefix
    local mark = node.id == current and "●" or (via and ICON[via.relation] or " ")
    if node.lazy and not node.pending then mark = "…" end
    local left = ("%s%s %s"):format(branch, mark, label)
    local extra = ref and " ↺" or ""
    local parts = 0
    for _, box in ipairs(node.boxes) do
      if box.role == "part" then parts = parts + 1 end
    end
    if parts > 0 then extra = extra .. ("  (%d parts)"):format(parts) end
    local loc = where(node)
    local text = left .. extra .. "  " .. loc
    local group = via and (via.relation == "next" and "CodeTourTreeNext" or "CodeTourTreeOptional") or "CodeTourTreeTitle"
    add(text, node, {
      { #branch, #branch + #mark, group },
      { #text - #loc, #text, "CodeTourTreeLocation" },
    })
    if ref then return end
    local children = calls[node.id] or {}
    local child_prefix = via and (prefix .. (last and "   " or "│  ")) or prefix .. "   "
    for k, link in ipairs(children) do
      local child = nodes[link.target]
      visit(child, child_prefix, child.label, link, k == #children)
    end
  end
  local n = 0
  for _, node in ipairs(graph.nodes) do
    if node.root or (node.root == nil and not called[node.id]) then
      n = n + 1
      visit(node, "", ("%d. %s"):format(n, node.label))
    end
  end
  if #lines == 0 then lines[1] = "(empty tour)" end
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
    CodeTourTreeOptional = "DiagnosticError", CodeTourTreeLocation = "Comment",
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
  local lines, rows, spans, current_line = M.outline(graph, current)
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
  if current_line then vim.api.nvim_win_set_cursor(win, { current_line, 0 }) end
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
