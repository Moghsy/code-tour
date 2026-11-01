local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
local sent = 0
require("code-tour.conversation").send = function(_, _, _, callback)
  sent = sent + 1
  callback(true)
end
local tour = require("tour")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local source = { "local function entry(value)", "  local input = value", "  local result = service.process(input); optional(result)",
  "  return result", "end", "return entry(1)" }
vim.fn.writefile(source, root .. "/entry.lua")
vim.fn.writefile({ "local function process(value)", "  local result = inner(value)", "  return result", "end" }, root .. "/process.lua")
vim.fn.writefile({ "local function inner(value)", "  return value * 2", "end" }, root .. "/inner.lua")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function state() return tour.state() end
local function here() return state().stops[state().stop].title .. ":" .. state().box end
local function optional()
  return { file = "inner.lua", start = 1, ["end"] = 3, title = "Optional", note = "Inspect optionally.",
    callsite = { start = 3, symbol = "optional" } }
end
local function process()
  return { file = "process.lua", start = 1, ["end"] = 4, title = "Process", note = "Process the input.", next = true,
    callsite = { start = 3, symbol = "service.process" }, parts = {
      { start = 1, ["end"] = 2, note = "Call inner.", calls = {
        { file = "inner.lua", start = 1, ["end"] = 3, title = "Inner", note = "Double the value.", next = true,
          callsite = { start = 2, symbol = "inner" } },
      } },
      { start = 3, ["end"] = 4, note = "Return the result." },
    } }
end
local function show(call, parts, additional)
  tour.show({
    { file = "entry.lua", start = 1, ["end"] = 5, title = "Entry", note = "Handle input.",
      parts = parts or {
        { start = 1, ["end"] = 2, note = "Read input." },
        { start = 3, ["end"] = 3, note = "Process input." },
        { start = 4, ["end"] = 5, note = "Return result." },
      }, calls = { call or process(), optional(), additional },
      example = { values = { [3] = "result = 2" } } },
    { file = "entry.lua", start = 6, ["end"] = 6, title = "Tail", note = "Start the entry point." },
  }, { root = root })
end
local function marks()
  local buf = state().stops[state().stop].buf
  return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })
end
local function test()
  tour.setup({ smooth_scroll = false })
  show()
  local buf = state().stops[1].buf
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local expected = { "Entry:1", "Entry:2", "Entry:3", "Process:1", "Process:2", "Inner:1", "Process:3", "Entry:4", "Tail:1" }
  for i, label in ipairs(expected) do
    check(here() == label, "Gold route follows calls and returns to the following part at " .. i .. ": " .. here())
    if i < #expected then tour.next_explanation(1) end
  end
  check(#state().frames == 0, "Completing gold calls removes their return frames")
  for i = #expected, 1, -1 do
    check(here() == expected[i], "ak retraces the gold route at " .. i .. ": " .. here())
    tour.next_explanation(-1)
  end
  check(sent == 0, "Gold navigation never starts lazy generation")
  tour.next_explanation(2)
  local gold, red, label, example = 0, 0, 0, 0
  for _, mark in ipairs(marks()) do
    local details = mark[4]
    if details.hl_group == "CodeTourNextCall" then
      gold = gold + 1
      check(mark[2] == 2 and mark[3] == source[3]:find("service.process", 1, true) - 1,
        "Gold badge covers the invoked receiver and method")
      check(details.virt_text[1][1] == "service.process" and details.hl_mode == "replace", "Gold glyphs keep source text")
    elseif details.hl_group == "CodeTourCall" then red = red + 1 end
    for _, chunk in ipairs(details.virt_text or {}) do
      if chunk[1]:find("<- next snippet", 1, true) then
        label = label + 1
        check(details.virt_text_pos == "eol" and chunk[2] == "CodeTourNextLabel", "Transition label is gold and at line end")
      end
      if chunk[1]:find("result = 2", 1, true) then example = example + 1 end
    end
  end
  check(gold == 1 and red == 1 and label == 1 and example == 1, "Gold and red calls coexist with the label and example")
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  check(vim.api.nvim_get_hl(0, { name = "CodeTourNextCall" }).bg == tonumber("e5b94f", 16), "Colorscheme changes restore gold")

  local calls = require("code-tour.stops").calls_in(state().stops, state().stops[1], state().stops[1].parts[2])
  tour.expand_call(calls[2])
  check(here() == "Optional:1", "Red calls still enter with ad")
  tour.next_explanation(1)
  check(here() == "Entry:3", "Completing a red call restores the same caller box")
  tour.next_explanation(1)
  check(here() == "Process:1", "aj then follows the gold call")
  tour.return_to_caller()
  check(here() == "Entry:3" and #state().frames == 0, "ao exits a gold call early to its caller")
  tour.next_explanation(3)
  check(here() == "Inner:1" and #state().frames == 2, "Nested gold calls keep separate return frames")
  tour.return_to_caller()
  check(here() == "Process:2" and #state().frames == 1, "ao exits only the innermost gold call")
  tour.next_explanation(3)
  check(here() == "Entry:4" and #state().frames == 0, "Continuing the nested call resumes each following part")

  show()
  tour.expand_call(state().stops[2])
  tour.next_explanation(-1)
  check(here() == "Entry:1", "ak after manual entry from an overview restores that overview")
  tour.expand_call(state().stops[2])
  tour.next_explanation(4)
  check(here() == "Entry:4", "A manually inspected gold call also finishes at the following authored part")

  -- An optional outer branch must retain its scope even when its route includes gold calls.
  local outer = process()
  outer.next = false
  show(outer)
  tour.next_explanation(2)
  tour.expand_call(state().stops[2])
  tour.next_explanation(4)
  check(here() == "Entry:3" and #state().frames == 0, "Finishing an optional branch with gold descendants returns to its exact caller")

  -- Several gold calls in one box run in authored order; red siblings are skipped.
  local sibling = optional()
  sibling.title, sibling.next = "Second", true
  local first = process()
  first.parts = nil
  show(first, nil, sibling)
  tour.next_explanation(3)
  check(here() == "Process:1", "First gold sibling starts after its caller box")
  tour.next_explanation(1)
  check(here() == "Second:1", "Next gold sibling follows without revisiting the caller")
  tour.next_explanation(1)
  check(here() == "Entry:4", "Final gold sibling returns to the following caller part")

  -- A tail call has no remaining caller parts, so it continues to the next main snippet.
  show(first, { { start = 1, ["end"] = 2, note = "Prepare" }, { start = 3, ["end"] = 5, note = "Last part" } })
  tour.next_explanation(4)
  check(here() == "Tail:1", "Gold calls in the final part continue to the following main snippet")
  show(first, {})
  tour.next_explanation(1)
  check(here() == "Process:1", "Snippets without parts follow overview gold calls")
  tour.next_explanation(1)
  check(here() == "Tail:1", "Overview gold call completion continues to the next main snippet")

  show()
  tour.next_explanation(3)
  tour.next_snippet(1)
  check(here() == "Tail:1" and #state().frames == 0, "Main snippet navigation still skips method branches")
  local invalid = process()
  invalid.lazy, invalid.parts, invalid.note = true, nil, nil
  local id = state().id
  check(not pcall(show, invalid) and state().id == id, "Lazy gold calls are rejected without replacing the tour")
  invalid = process()
  invalid.next = "yes"
  check(not pcall(show, invalid), "Gold routing flags must be booleans")
  check(vim.api.nvim_buf_get_changedtick(buf) == tick and not vim.bo[buf].modified
    and vim.deep_equal(vim.fn.readfile(root .. "/entry.lua"), source), "Badges and navigation leave source and changedtick untouched")
  tour.stop()
  print("PASS: " .. checks .. " gold next-snippet assertions")
end
local ok, err = xpcall(test, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
