local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
vim.g.mapleader = " "
-- These checks exercise selection/UI/fill behavior without opening an RPC socket.
require("code-tour.instance").register = function() end
local sent = {}
require("code-tour.conversation").deliver = function(_, _root, prompt, action, callback)
  sent[#sent + 1] = { prompt = prompt, action = action }
  callback(true)
end
local tour = require("tour")
local composer = require("code-tour.prompt")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 40 do
  lines[i] = "local value = " .. i
end
vim.fn.writefile(lines, root .. "/code.lua")
vim.fn.writefile(lines, root .. "/other.lua")
local checks = 0
local function check(value, message)
  assert(value, message)
  checks = checks + 1
end
local function stop(a, b, parts)
  return { file = "code.lua", start = a, ["end"] = b, note = "Explain " .. a, parts = parts }
end
local function part(a, b)
  return { start = a, ["end"] = b, note = "Part " .. a }
end
local function setup()
  tour.show({ stop(1, 10, { part(1, 5), part(6, 10) }), stop(20, 25) }, { root = root })
  return tour.state().stops[1].buf
end
local function state()
  return tour.state()
end
local function range(a, b, buf)
  return { buf = buf or state().stops[1].buf, start = a, ["end"] = b }
end
local function submit_context(text)
  local popup = assert(composer.state())
  vim.api.nvim_buf_set_lines(popup.buf, 0, -1, false, vim.split(text, "\n"))
  vim.fn.maparg("<C-s>", "i", false, true).callback()
end
local function test()
  tour.setup({ smooth_scroll = false })
  local buf = setup()
  local id, prompt = tour.explain(range(2, 3))
  check(
    #state().stops == 2 and state().pending[id].into == state().stops[1].parts[1],
    "Selection should attach to its containing box"
  )
  check(not prompt:find("Example context:", 1, true) and prompt:find("tour: ", 1, true),
    "Ordinary requests carry no example and cite the tour file")
  check(
    prompt:find("code.lua:2-3", 1, true) and prompt:find("local value = 2", 1, true),
    "Request must contain selected code"
  )
  check(not pcall(tour.fill, id, { stop(1, 5) }), "Response must not expand beyond selection")
  tour.fill(id, { stop(2, 3) })
  check(
    state().stop == 1 and state().box == 3 and state().stops[1].parts[2].start == 2,
    "Fill should add the selected range after its parent box"
  )
  check(
    state().stops[1].parts[1].start == 1 and state().stops[1].parts[3].start == 6,
    "Existing explanations must survive"
  )

  local count = #sent
  tour.explain_with_context(range(6, 7))
  check(composer.state() and #sent == count, "aE opens a composer without sending")
  submit_context("Please show an example for input value = 6\nand trace how it changes.")
  check(not composer.state() and #sent == count + 1, "Submitting context sends exactly one request")
  local selection_id
  for key, request in pairs(state().pending) do
    if request.selection then
      selection_id = key
    end
  end
  check(
    sent[#sent].prompt:find("Please show an example for input value = 6\nand trace how it changes.", 1, true),
    "Extra context must reach the request"
  )
  check(sent[#sent].prompt:find("Reply: ", 1, true), "Example requests keep their reply command")
  local example = stop(6, 7, { part(6, 6), part(7, 7) })
  example.example = { input = "value = 6", output = "value = 7", values = { [8] = "outside selection" } }
  check(not pcall(tour.fill, selection_id, { example }), "Example annotations must still stay inside the snippet")
  example.example.values[8] = nil
  example.example.values[7] = { value = "value = 7", detail = "Reassigned" }
  tour.fill(selection_id, { example })
  local added = state().stops[1].parts[state().box - 1]
  check(
    added.example.input == "value = 6" and not next(added.example.values),
    "Sparse examples allow parts without any annotated values while preserving input context"
  )
  tour.next_explanation(1)
  local next_part = state().stops[1].parts[state().box - 1]
  check(
    next_part.example.values["7"].value == "value = 7" and not next_part.example.values["6"],
    "Each part gets its own line data flow"
  )
  local marks =
    vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })
  local output
  for _, mark in ipairs(marks) do
    if mark[4].virt_text then
      output = mark[4].virt_text[1][1]
    end
  end
  check(output and output:find("value = 7", 1, true), "The active example must render output at the line end")

  -- Selection placement uses source ranges, even when it precedes the current stop.
  tour.show({ stop(10, 15), stop(20, 25) }, { root = root })
  local reading = state().stops[1]
  local before = tour.explain(range(2, 4))
  check(
    state().stops[1].placeholder == before and state().stops[state().stop] == reading,
    "A preceding selection inserts before the snippet without moving the reader"
  )
  local between = tour.explain(range(16, 18))
  tour.fill(between, { stop(16, 18) })
  tour.fill(before, { stop(2, 4) })
  check(
    state().stops[1].start == 2 and state().stops[3].start == 16 and state().stops[4].start == 20,
    "Concurrent fills retain source order"
  )

  -- A selection in another source file remains visible while the request is sent.
  local other = vim.fn.bufadd(root .. "/other.lua")
  vim.fn.bufload(other)
  vim.api.nvim_win_set_buf(state().win, other)
  local elsewhere = tour.explain(range(3, 4, other))
  check(vim.api.nvim_win_get_buf(state().win) == other, "Requesting another file must not replace its source buffer")
  tour.fill(elsewhere, { { file = "other.lua", start = 3, ["end"] = 4, note = "Other file" } })
  check(state().stops[state().stop].path == root .. "/other.lua", "Other-file explanation opens in its inserted stop")

  -- Exercise actual forward and reversed visual selections, including exact text.
  setup()
  vim.cmd("normal! ggVj")
  local visual = tour.explain()
  check(
    state().pending[visual].selection.start == 1 and state().pending[visual].selection["end"] == 2,
    "Linewise selection should be captured"
  )
  vim.api.nvim_win_set_cursor(state().win, { 3, 0 })
  vim.cmd("normal! Vk")
  local reverse = tour.explain()
  check(
    state().pending[reverse].selection.start == 2 and state().pending[reverse].selection["end"] == 3,
    "Reversed visual selection should be captured"
  )
  vim.cmd("normal! gg0v2l")
  local chars = tour.explain()
  check(state().pending[chars].selection.text == "loc", "Character selection should preserve exact text")
  vim.cmd("normal! gg0\22j2l")
  local block = tour.explain()
  check(state().pending[block].selection.text == "loc\nloc", "Block selection should preserve exact text")

  tour.explain_with_context(range(8, 9))
  submit_context("")
  check(not sent[#sent].prompt:find("Extra context:", 1, true), "Extra context may be blank")
  local stale = tour.explain(range(8, 9))
  vim.api.nvim_buf_set_lines(buf, 7, 8, false, { "local changed = true" })
  check(not pcall(tour.fill, stale, { stop(8, 9) }), "Changed source must not receive an explanation for stale code")
  for _, mode in ipairs({ "n", "x" }) do
    check(
      type(vim.fn.maparg(" ae", mode, false, true).callback) == "function",
      "ae must work in normal and visual mode"
    )
    check(
      type(vim.fn.maparg(" aE", mode, false, true).callback) == "function",
      "aE must work in normal and visual mode"
    )
  end
  tour.stop()
  print("PASS: " .. checks .. " selection, context and example assertions")
end
local ok, err = xpcall(test, debug.traceback)
if ok then
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
