local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
local sent, fail = {}, false
require("code-tour.conversation").deliver = function(_, _root, prompt, _, callback)
  sent[#sent + 1] = prompt
  callback(not fail, fail and "Test delivery failure" or nil)
end
local tour, view = require("tour"), require("code-tour.tour-view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local source = { "local function entry(input)", "  local data = input", "  local first = prepare(data)",
  "  local result = handlerstack.bubble(first); unknown(result)", "  return finish(result)", "end" }
vim.fn.writefile(source, root .. "/entry.lua")
vim.fn.writefile({ "local function bubble(value)", "  local result = inner(value)", "  return result", "end" }, root .. "/bubble.lua")
vim.fn.writefile({ "local function inner(value)", "  return value * 2", "end" }, root .. "/inner.lua")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function state() return tour.state() end
local function label()
  local s = state()
  return s.stops[s.stop].title .. ":" .. s.box
end
local function bubble(lazy)
  return { file = "bubble.lua", start = 1, ["end"] = 4, title = "Bubble", lazy = lazy,
    note = not lazy and "Sort the supplied value." or nil,
    callsite = { start = 4, symbol = "bubble" },
    parts = not lazy and {
      { start = 1, ["end"] = 2, note = "Call inner.", calls = {
        { file = "inner.lua", start = 1, ["end"] = 3, title = "Inner", note = "Double the value.",
          callsite = { start = 2, symbol = "inner" } },
      } },
      { start = 3, ["end"] = 4, note = "Return the inner result." },
    } or nil }
end
local function show(call, extra)
  tour.show({ { file = "entry.lua", start = 1, ["end"] = 6, title = "Entry", note = "Process input.",
    parts = {
      { start = 1, ["end"] = 3, note = "Prepare the input." },
      { start = 4, ["end"] = 4, note = "Use bubble to sort the prepared input." },
      { start = 5, ["end"] = 6, note = "Finish and return." },
    }, calls = { call, extra } } }, { root = root })
end
local function badge_marks()
  local stop = state().stops[state().stop]
  local marks = {}
  local ns = vim.api.nvim_get_namespaces().CodeTourSource
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(stop.buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == "CodeTourCall" then marks[#marks + 1] = mark end
  end
  return marks
end
local function hover(line, symbol)
  local stop = state().stops[state().stop]
  local text = vim.api.nvim_buf_get_lines(stop.buf, line - 1, line, false)[1]
  vim.api.nvim_win_set_cursor(state().win, { line, text:find(symbol, 1, true) - 1 })
end
local function test()
  tour.setup({ smooth_scroll = false, walk = false })
  show(bubble(false))
  check(#badge_marks() == 1, "Overview already shows its ready call as a red badge")
  local expected = { "Entry:1", "Entry:2", "Entry:3", "Entry:4" }
  for n, item in ipairs(expected) do
    check(label() == item, "Forward explanations have no call-site stops at " .. n)
    tour.next_explanation(1)
  end
  for n = #expected, 1, -1 do
    check(label() == expected[n], "Backward explanations have no call-site stops at " .. n)
    tour.next_explanation(-1)
  end
  check(#sent == 0, "Reading explanations generates no requests")
  tour.next_explanation(2)
  local caller = state().stops[1]
  check(state().stops[2]._parent_box == caller.parts[2], "Call keeps its containing part")
  local marks = badge_marks()
  local col = source[4]:find("handlerstack.bubble", 1, true) - 1
  check(#marks == 1 and marks[1][2] == 3 and marks[1][3] == col
    and marks[1][4].end_col == col + #"handlerstack.bubble", "Ready receiver and method are badged within the subpart")
  check(view.state().text:find("Use bubble", 1, true) and not view.state().text:find("Follow call", 1, true),
    "Caller explanation remains visible without a call-site explanation")
  hover(4, "handlerstack")
  tour.expand_call()
  check(label() == "Bubble:1", "ad on the receiver enters the prepared method")
  tour.next_explanation(1)
  check(label() == "Bubble:2" and #badge_marks() == 1, "Nested ready call is badged in its own explanation")
  hover(2, "inner")
  tour.expand_call()
  check(label() == "Inner:1" and #state().frames == 2, "ad explicitly enters a nested method")
  tour.next_explanation(1)
  check(label() == "Bubble:2", "Finishing nested method returns to the same caller explanation")
  local back = vim.fn.maparg("<leader>ao", "n", false, true)
  check(type(back.callback) == "function", "ao is bound to leave an inspected method")
  back.callback()
  check(label() == "Entry:3" and #state().frames == 0, "ao restores the same saved caller box at each level")
  check(#badge_marks() == 1, "Returned caller explanation retains its visitable badges")
  hover(4, "bubble")
  tour.expand_call()
  tour.next_explanation(-1)
  check(label() == "Entry:3", "ak at method start returns to the saved caller explanation")
  check(#caller.parts == 3 and #state().stops == 3, "Badges add no explanation parts or snippets")

  -- Every ready call in this part is visible at once and the source cursor,
  -- rather than traversal order, chooses which one ad opens.
  local other = { file = "inner.lua", start = 1, ["end"] = 3, title = "Other", note = "Other method",
    callsite = { start = 4, ["end"] = 4, symbol = "unknown" } }
  show(bubble(false), other)
  tour.next_explanation(1)
  check(#badge_marks() == 2, "Calls in other subparts stay badged")
  tour.next_explanation(1)
  check(#badge_marks() == 2, "All ready calls in one subpart are badged together")
  hover(4, "unknown")
  tour.expand_call()
  check(label() == "Other:1", "ad enters the badge under the cursor without a picker")
  tour.next_explanation(1)
  check(label() == "Entry:3", "Chosen sibling returns to the same caller part")
  tour.next_explanation(1)
  check(label() == "Entry:4", "aj advances only after the user returns and chooses to continue")

  -- Entering from the overview should return to the overview, not jump to
  -- the author's part-2 anchor. The frame stores the actual reading position.
  show(bubble(false))
  hover(4, "bubble")
  tour.expand_call()
  tour.return_to_caller()
  check(label() == "Entry:1", "Return restores the exact overview the reader entered from")

  local inferred = bubble(false)
  inferred.callsite = nil
  show(inferred)
  check(state().stops[2].callsite.symbol == "handlerstack.bubble" and #badge_marks() == 1,
    "Older payloads can infer a full receiver.method badge")

  show(bubble(true))
  tour.next_explanation(2)
  check(#badge_marks() == 0, "Unexplained call is ordinary source text")
  tour.ask("Keep caller Q&A", "stay")
  caller = state().stops[1]
  hover(4, "bubble")
  local request = tour.expand_call()
  check(request and label() == "Entry:3" and #badge_marks() == 0, "Generation stays in caller without a badge")
  local count = #sent
  check(tour.expand_call() == request and #sent == count, "Repeated inspect does not duplicate generation")
  local answer = bubble(false)
  answer.callsite = nil
  local filled = tour.fill(request, { answer })
  check(filled.navigate and label() == "Bubble:1", "Inspect enters once a missing explanation is ready")
  tour.answer("Caller answer", "1.3")
  check(caller.parts[2].thread[1].answer == "Caller answer", "Caller Q&A survives lazy fill")
  tour.return_to_caller()
  check(label() == "Entry:3" and #badge_marks() == 1, "Generated explanation now has a source badge")
  count = #sent
  hover(4, "bubble")
  tour.expand_call()
  check(label() == "Bubble:1" and #sent == count, "Existing explanation is reused")

  show(bubble(true))
  tour.next_explanation(2)
  request = tour.expand_call()
  tour.next_explanation(1)
  filled = tour.fill(request, { answer })
  check(not filled.navigate and label() == "Entry:4", "Late generation does not move a reader who continued")
  tour.next_explanation(-1)
  check(label() == "Entry:3" and #badge_marks() == 1, "Late ready explanation becomes directly visitable")

  show(bubble(true))
  tour.next_explanation(2)
  request = tour.expand_call()
  tour.next_explanation(1)
  tour.next_explanation(-1)
  filled = tour.fill(request, { answer })
  check(not filled.navigate and label() == "Entry:3", "Returning to the same box does not restore cancelled entry intent")

  show(bubble(true))
  tour.next_explanation(2)
  request = tour.expand_call()
  tour.cancel()
  check(not pcall(tour.fill, request, { answer }), "Cancelled inspection rejects a late reply")
  check(tour.expand_call() ~= request, "Cancelled call can be inspected again")

  show(bubble(true))
  tour.next_explanation(2)
  fail = true
  local notify = vim.notify
  vim.notify = function() end
  request = tour.expand_call()
  vim.notify = notify
  fail = false
  check(label() == "Entry:3" and not state().pending[request] and #badge_marks() == 0, "Failed generation creates no badge")
  check(tour.expand_call() ~= request, "Failed inspection can be retried")

  show(bubble(false))
  tour.next_explanation(2)
  hover(4, "unknown")
  local clients = vim.lsp.get_clients
  vim.lsp.get_clients = function()
    return {{ offset_encoding = "utf-16", request = function(_, _, _, callback)
      callback(nil, {{ uri = vim.uri_from_fname(root .. "/entry.lua"),
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 2, character = 1 } } }})
    end }}
  end
  tour.expand_call()
  vim.lsp.get_clients = clients
  check(vim.wait(1000, function() return next(state().pending) ~= nil end, 10),
    "ad on an unbadged method resolves it even when another method is already prepared")
  request = next(state().pending)
  check(state().pending[request].placeholder and not state().pending[request].into,
    "Same-file cursor lookup creates a method branch rather than refining caller text")
  check(#badge_marks() == 1, "Only the existing prepared call stays badged during generation")
  check(vim.fn.maparg("<leader>ai", "n") == "" and vim.fn.maparg("<leader>aU", "n") == ""
    and vim.fn.maparg("<leader>au", "n") == "", "Only ad enters and ao exits, with no redundant mappings")
  check(vim.deep_equal(vim.fn.readfile(root .. "/entry.lua"), source), "Call navigation leaves source untouched")
  tour.stop()
  print("PASS: " .. checks .. " source-badge navigation assertions")
end
local ok, err = xpcall(test, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
