local M = {}

function M.capture(state, range)
  range = range or {}
  local win = vim.api.nvim_get_current_win()
  local buf = range.buf or vim.api.nvim_win_get_buf(win)
  local mode = vim.api.nvim_get_mode().mode
  local visual = mode == "v" or mode == "V" or mode == "\22"
  if not range.buf and not visual and vim.bo[buf].buftype ~= "" and state.win then
    win, buf = state.win, vim.api.nvim_win_get_buf(state.win)
  end
  assert(vim.bo[buf].buftype == "", "Select code in a source buffer")
  local path =
    assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)), "Save the source file before requesting an explanation")
  local first, last, text = range.start, range["end"], range.text
  local byte_range
  if not first and visual then
    local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
    first, last = math.min(a[2], b[2]), math.max(a[2], b[2])
    text = table.concat(vim.fn.getregion(a, b, { type = mode, exclusive = vim.o.selection == "exclusive" }), "\n")
    local positions = vim.fn.getregionpos(a, b, { type = mode, exclusive = vim.o.selection == "exclusive" })
    if #positions > 0 then
      first, last = positions[1][1][2], positions[#positions][2][2]
    end
  elseif not first then
    local line = vim.api.nvim_win_get_cursor(win)[1]
    local stop = state.stops[state.stop]
    local box = stop and (state.box == 1 and stop or stop.parts[state.box - 1])
    if box and stop.buf == buf and line >= box.start and line <= box["end"] then
      first, last = box.start, box["end"]
      if box.byte_range then
        byte_range = box.byte_range
        text = require("code-tour.source").text(buf, byte_range)
      end
    else
      first, last = line, line
    end
  end
  first, last = math.min(first, last or first), math.max(first, last or first)
  assert(first >= 1 and last <= vim.api.nvim_buf_line_count(buf), "Selection is outside the source buffer")
  local source = require("code-tour.source")
  local capture = source.capture(buf, byte_range or source.line_range(buf, first, last))
  local selected_text = text or table.concat(vim.api.nvim_buf_get_lines(buf, first - 1, last, false), "\n")
  return {
    buf = buf,
    path = path,
    file = vim.fs.relpath(state.root, path) or path,
    start = first,
    ["end"] = last,
    text = selected_text,
    byte_range = byte_range,
    source_capture = capture and capture.text == selected_text and capture or nil,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    tour = state.id,
  }
end

function M.placement(state, selection)
  local parent, anchor
  for _, stop in ipairs(state.stops) do
    if
      not stop.placeholder and not stop.lazy
      and stop.path == selection.path
      and stop.start <= selection.start
      and stop["end"] >= selection["end"]
      and (
        not parent
        or stop["end"] - stop.start < parent["end"] - parent.start
        or (stop["end"] - stop.start == parent["end"] - parent.start and stop == state.stops[state.stop])
      )
    then
      parent = stop
    end
  end
  if parent then
    anchor = parent
    for _, part in ipairs(parent.parts) do
      if
        part.start <= selection.start
        and part["end"] >= selection["end"]
        and (part["end"] - part.start <= anchor["end"] - anchor.start)
      then
        anchor = part
      end
    end
    if anchor == parent then
      for _, part in ipairs(parent.parts) do
        if part.start <= selection.start then
          anchor = part
        end
      end
    end
    return parent, anchor
  end
  local before, after
  for i, stop in ipairs(state.stops) do
    if not stop.placeholder and not stop.lazy and stop.path == selection.path then
      if stop.start > selection.start and (not before or stop.start < state.stops[before].start) then
        before = i
      end
      if stop.start <= selection.start and (not after or stop.start >= state.stops[after].start) then
        after = i
      end
    end
  end
  return nil, nil, before or (after and after + 1) or state.stop + 1
end

return M
