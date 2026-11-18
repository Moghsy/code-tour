-- Terminal view of a tour's state machine (see SPEC-state-machine.md): states as headed
-- blocks, steps and transitions under them, loops and jumps as brackets in the left margin.
-- `layout` is pure text. `open` shows it in a float, a tab or a split; it never changes the
-- tour itself, it asks the controller (on_goto) to move.
local machine_lib = require("code-tour.machine")
local M = {}

local view -- { win, buf, tab?, mode, args } while open

local function width(text)
  return vim.fn.strdisplaywidth(text)
end

-- Builds a line from segments { text, group } and returns text and byte spans.
local function compose(segments)
  local text, spans = "", {}
  for _, segment in ipairs(segments) do
    if segment[2] and #segment[1] > 0 then
      spans[#spans + 1] = { #text, #text + #segment[1], segment[2] }
    end
    text = text .. segment[1]
  end
  return text, spans
end

local function arrow(edge)
  if edge.exit then return "⇥", "CodeTourMachineJump" end
  if edge.loop then return "↻", "CodeTourMachineLoop" end
  if edge.happy then return "→", "CodeTourMachineNext" end
  return "→", "CodeTourMachineDim"
end

local function executor(step)
  if step.kind == "computer" then return "computer" end
  local text = step.model or "agent"
  if step.effort then text = text .. " " .. step.effort:upper() end
  return text
end

-- Pure layout. `current` is the id of the box the tour is on (a stop id or a part id).
-- Returns lines, rows (line -> item), spans { line0, from, to (-1 = whole line), group },
-- and the line to put the cursor on.
function M.layout(machine, current)
  local body, rows, headers, targets = {}, {}, {}, {}
  local function add(segments, row)
    local text, spans = compose(segments)
    body[#body + 1] = { text = text, spans = spans, row = row }
    return #body
  end
  local current_line
  local function mark_current(line)
    current_line = current_line or line
    local item = body[line]
    item.spans[#item.spans + 1] = { 0, -1, "CodeTourMachineCurrent" }
  end

  if #machine.path > 0 then
    add({ { table.concat(machine.path, " › "), "CodeTourMachineDim" } }, { kind = "path" })
  end
  local heads, label_width = {}, 0
  for _, item in ipairs(machine.catch) do
    heads[#heads + 1] = { "catch " .. item.error, item.to, "catch" }
  end
  if machine.on_abort then heads[#heads + 1] = { "on abort", machine.on_abort, "abort" } end
  for _, head in ipairs(heads) do label_width = math.max(label_width, width(head[1])) end
  for _, head in ipairs(heads) do
    add({
      { head[1] .. string.rep(" ", label_width - width(head[1]) + 2), "CodeTourMachineDim" },
      { "⇥ ", "CodeTourMachineJump" }, { head[2], "CodeTourMachineState" },
    }, { kind = head[3], state = head[2], to = head[2] })
  end
  if #heads > 0 or #machine.path > 0 then add({}, nil) end

  local name_width = 8
  for _, state in ipairs(machine.states) do
    for _, step in ipairs(state.steps) do name_width = math.max(name_width, width(step.name)) end
  end

  for i, state in ipairs(machine.states) do
    if i > 1 then add({}, nil) end
    if state.only_on_catch and #state.only_on_catch > 0 then
      add({ { "only on catch " .. table.concat(state.only_on_catch, ", "), "CodeTourMachineGuard" } }, { kind = "note", state = state.id })
    end
    local segments = {}
    if state.id == machine.start then segments[#segments + 1] = { "▶ ", "CodeTourMachineNext" } end
    segments[#segments + 1] = { state.id, "CodeTourMachineState" }
    if state.id == machine.start then segments[#segments + 1] = { " · start", "CodeTourMachineDim" } end
    if state.exit then segments[#segments + 1] = { " · exit", "CodeTourMachineDim" } end
    local header = add(segments, { kind = "state", state = state.id, id = state.stop })
    headers[state.id] = header
    if state.stop and current == state.stop then mark_current(header) end
    for k, step in ipairs(state.steps) do
      local here = step.part ~= nil and step.part == current
      local line = add({
        { here and " ● " or "   ", "CodeTourMachineNext" },
        { step.name .. string.rep(" ", name_width - width(step.name) + 2), step.kind == "agent" and "CodeTourMachineAgent" or "CodeTourMachineStep" },
        { executor(step), "CodeTourMachineDim" },
        { step.status and ("  ■ " .. step.status) or "", "CodeTourMachineChip" },
        { step.feedback and "  as feedback" or "", "CodeTourMachineDim" },
      }, { kind = "step", state = state.id, step = k, id = step.part, prompt = step.prompt })
      if here then mark_current(line) end
    end
    if state["end"] then
      add({ { "   end: ", "CodeTourMachineDim" }, { state["end"], "CodeTourMachineState" } }, { kind = "end", state = state.id })
    end
    local function transition(prefix, edge, text)
      local glyph, group = arrow(edge)
      local segments2 = { { prefix, "CodeTourMachineDim" } }
      if text then segments2[#segments2 + 1] = { text .. " ", edge.kind == "guard" and "CodeTourMachineGuard" or "CodeTourMachineDim" } end
      segments2[#segments2 + 1] = { glyph .. " ", group }
      segments2[#segments2 + 1] = { edge.target, "CodeTourMachineState" }
      local line = add(segments2, { kind = "edge", state = state.id, to = edge.target, edge = edge })
      if edge.to and not edge.exit then
        targets[#targets + 1] = { line = line, state = edge.target, from = state.id }
      end
    end
    local edges = machine_lib.edges(machine, state)
    if state.next then
      transition("   ", edges[1])
    elseif state.on then
      add({ { "   on " .. state.on.name, "CodeTourMachineDim" } }, { kind = "on", state = state.id })
      local count = #state.on.outcomes
      local cursor = 1
      for n, outcome in ipairs(state.on.outcomes) do
        local last = n == count
        local stem = last and "└ " or "├ "
        if outcome.when then
          add({ { "   " .. stem .. outcome.id .. " when", "CodeTourMachineDim" } }, { kind = "outcome", state = state.id })
          local total = #outcome.when + 1
          for g = 1, total do
            local edge = edges[cursor]
            cursor = cursor + 1
            local sub = "   " .. (last and "  " or "│ ") .. (g == total and "└ " or "├ ")
            transition(sub, edge, g == total and "otherwise" or edge.guard)
          end
        else
          local edge = edges[cursor]
          cursor = cursor + 1
          transition("   " .. stem, edge, outcome.id)
        end
      end
    end
  end

  -- Margin brackets: loops and forward jumps that skip a state, longest outermost.
  local brackets = {}
  for _, target in ipairs(targets) do
    local to = headers[target.state]
    local gap = machine.order[target.state] - machine.order[target.from]
    if to and gap ~= 1 then
      brackets[#brackets + 1] = { from = target.line, to = to, top = math.min(target.line, to), bottom = math.max(target.line, to) }
    end
  end
  table.sort(brackets, function(a, b)
    if (a.bottom - a.top) ~= (b.bottom - b.top) then return (a.bottom - a.top) > (b.bottom - b.top) end
    return a.top < b.top
  end)
  local columns = {}
  for _, bracket in ipairs(brackets) do
    local placed
    for c, used in ipairs(columns) do
      local free = true
      for _, other in ipairs(used) do
        if not (bracket.bottom < other.top or bracket.top > other.bottom) then free = false break end
      end
      if free then placed = c break end
    end
    if not placed then columns[#columns + 1] = {} placed = #columns end
    table.insert(columns[placed], bracket)
    bracket.column = placed
  end
  local ncols = #columns
  local lines, out_rows, spans = {}, {}, {}
  for i, item in ipairs(body) do
    local cells = {}
    for c = 1, ncols * 2 do cells[c] = " " end
    for _, bracket in ipairs(brackets) do
      local base = (bracket.column - 1) * 2
      if i >= bracket.top and i <= bracket.bottom then
        if i == bracket.top then cells[base + 1] = "╭" elseif i == bracket.bottom then cells[base + 1] = "╰" else cells[base + 1] = "│" end
        if i == bracket.to then cells[base + 2] = "▸" elseif i == bracket.from then cells[base + 2] = "─" end
      end
    end
    local margin = table.concat(cells)
    lines[i] = (margin:find("%S") or item.text ~= "") and (margin .. item.text) or ""
    out_rows[i] = item.row
    if #margin > 0 and margin:find("%S") then
      spans[#spans + 1] = { i - 1, 0, #margin, "CodeTourMachineBracket" }
    end
    for _, span in ipairs(item.spans) do
      local whole = span[2] < 0
      spans[#spans + 1] = { i - 1, whole and 0 or span[1] + #margin, whole and -1 or span[2] + #margin, span[3] }
    end
  end
  if #lines == 0 then lines[1] = "(empty machine)" end
  return lines, out_rows, spans, current_line
end

local function valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

function M.is_open()
  return view ~= nil and valid(view.win)
end

function M.close()
  local old = view
  view = nil
  if not old then return end
  if old.tab and vim.api.nvim_tabpage_is_valid(old.tab) and #vim.api.nvim_list_tabpages() > 1 then
    vim.cmd(vim.api.nvim_tabpage_get_number(old.tab) .. "tabclose")
  elseif valid(old.win) then
    pcall(vim.api.nvim_win_close, old.win, true)
  end
end

local function highlights()
  for name, link in pairs({
    CodeTourMachineState = "Title", CodeTourMachineStep = "Normal", CodeTourMachineAgent = "Function",
    CodeTourMachineDim = "Comment", CodeTourMachineNext = "DiagnosticWarn", CodeTourMachineJump = "DiagnosticError",
    CodeTourMachineLoop = "DiagnosticWarn", CodeTourMachineGuard = "DiagnosticWarn", CodeTourMachineChip = "DiagnosticHint",
    CodeTourMachineBracket = "Comment", CodeTourMachineCurrent = "CursorLine",
  }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

-- Where a row leads in the tour: { id = <stop or part id> }, or nil when it has no code.
function M.target(machine, row)
  if not row then return nil end
  if row.kind == "step" and row.id then return row.id end
  if row.kind == "state" or row.kind == "note" or row.kind == "end" or row.kind == "on" or row.kind == "outcome" then
    local state = machine.by_id[row.state]
    return state and state.stop
  end
  if row.to then
    local state = machine.by_id[row.to]
    return state and state.stop
  end
end

local function paint(win_buf, lines, spans)
  local ns = vim.api.nvim_create_namespace("code-tour-machine")
  vim.bo[win_buf].modifiable = true
  vim.api.nvim_buf_set_lines(win_buf, 0, -1, false, lines)
  vim.bo[win_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(win_buf, ns, 0, -1)
  for _, span in ipairs(spans) do
    local whole = span[3] < 0
    vim.api.nvim_buf_set_extmark(win_buf, ns, span[1], whole and 0 or span[2], {
      end_col = not whole and span[3] or nil, end_row = whole and span[1] + 1 or nil,
      hl_group = span[4], hl_eol = whole, priority = whole and 5 or 10,
    })
  end
end

-- args: { machine, current = function() -> box id, goto = function(id), ask = function(id) }
-- Opening it again closes it.
function M.open(mode, args)
  assert(mode == "float" or mode == "tab" or mode == "split", "machine view must be 'float', 'tab' or 'split'")
  if M.is_open() then
    M.close()
    return
  end
  highlights()
  local lines, rows, spans, current_line = M.layout(args.machine, args.current())
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden, vim.bo[buf].filetype, vim.bo[buf].swapfile = "wipe", "code-tour-machine", false
  vim.b[buf].snacks_scroll = false
  local widest = 24
  for _, line in ipairs(lines) do widest = math.max(widest, width(line)) end
  local win
  if mode == "tab" then
    vim.cmd("tabnew")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    view = { win = win, buf = buf, tab = vim.api.nvim_get_current_tabpage() }
  elseif mode == "split" then
    vim.cmd("topleft vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_width(win, math.min(widest + 2, math.max(30, math.floor(vim.o.columns / 2))))
    vim.wo[win].winfixwidth = true
    view = { win = win, buf = buf }
  else
    local w = math.min(widest + 2, vim.o.columns - 8)
    local h = math.max(1, math.min(vim.o.lines - 6, #lines))
    win = vim.api.nvim_open_win(buf, true, {
      relative = "editor", style = "minimal", border = "rounded", title = " State machine ",
      footer = " <CR> go · q close ", footer_pos = "center", width = w, height = h,
      row = math.max(0, math.floor((vim.o.lines - h - 2) / 2)), col = math.max(0, math.floor((vim.o.columns - w - 2) / 2)),
    })
    view = { win = win, buf = buf }
  end
  view.args, view.rows = args, rows
  vim.wo[win].wrap, vim.wo[win].cursorline, vim.wo[win].number, vim.wo[win].signcolumn = false, true, false, "no"
  paint(buf, lines, spans)
  vim.api.nvim_win_set_cursor(win, { current_line or 1, 0 })
  local function row_here()
    return view and view.rows[vim.api.nvim_win_get_cursor(view.win)[1]]
  end
  local function go(prompt)
    local row = row_here()
    local id = prompt and row and row.prompt or (not prompt and M.target(args.machine, row)) or nil
    if not id then
      vim.notify("Nothing to open here", vim.log.levels.INFO)
      return nil
    end
    if mode ~= "split" then M.close() end
    args.goto_id(id)
    return id
  end
  local function map(keys, fn)
    for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
      if key then vim.keymap.set("n", key, fn, { buffer = buf, nowait = true }) end
    end
  end
  map({ "<CR>", "gd" }, function() go(false) end)
  map("p", function() go(true) end)
  map(args.ask_key or false, function()
    local id = M.target(args.machine, row_here())
    if id then
      if mode ~= "split" then M.close() end
      args.ask(id)
    end
  end)
  map("R", M.refresh)
  map({ "q", "<Esc>" }, M.close)
  local function state_line(delta)
    local here, target = vim.api.nvim_win_get_cursor(view.win)[1], nil
    local count = vim.api.nvim_buf_line_count(buf)
    for i = here + delta, delta > 0 and count or 1, delta do
      if view.rows[i] and view.rows[i].kind == "state" then target = i break end
    end
    if target then vim.api.nvim_win_set_cursor(view.win, { target, 0 }) end
  end
  map("}", function() state_line(1) end)
  map("{", function() state_line(-1) end)
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() view = nil end })
end

-- Redraws from the tour and moves the marker (and the cursor) to the box it is on.
function M.refresh()
  if not M.is_open() then return end
  local args = view.args
  local lines, rows, spans, current_line = M.layout(args.machine, args.current())
  view.rows = rows
  paint(view.buf, lines, spans)
  if current_line and vim.api.nvim_get_current_win() ~= view.win then
    pcall(vim.api.nvim_win_set_cursor, view.win, { math.min(current_line, #lines), 0 })
  end
end

return M
