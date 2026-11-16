local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, callback) callback(true) end
local tour, view = require("tour"), require("code-tour.tour-view")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local source = {
  "function dispatch(type, event) {",
  "  const result = receiver.handle(type, event);",
  "  return this.bubbleEvent(type, event);",
  "}",
  "function sample(tag) {",
  "  switch (tag) {",
  '    case "false": return false;',
  '    case "zero": return 0;',
  '    case "empty": return "";',
  '    case "null": return null;',
  "    default: return undefined;",
  "  }",
  "}",
}
vim.fn.writefile(source, root .. "/source.js")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function annotations()
  local s, found = tour.state(), {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.stops[s.stop].buf,
    vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      if chunk[2] == "CodeTourExample" then found[mark[2] + 1] = chunk[1] end
    end
  end
  return found
end
local function trace_rules(prompt)
  check(prompt:find("Example context:", 1, true), "Existing examples carry through generation without being requested again")
end
local function test()
  tour.setup({ smooth_scroll = false })
  tour.show({ { file = "source.js", start = 1, ["end"] = 4, note = "Dispatch and return the nested result.",
    example = { input = 'type="keydown", event.key="f"', output = "false", values = {
      [2] = "result = false", [3] = 'bubbleEvent("keydown", event) → false; returns false',
    } }, parts = {
      { start = 1, ["end"] = 2, note = "Invoke the handler and capture its result." },
      { start = 3, ["end"] = 4, note = "Forward the nested dispatcher result to the caller." },
    } } }, { root = root })
  local values = annotations()
  check(values[3] and values[3]:find("returns false", 1, true), "A returned call displays its false output without changing the input")
  check(not values[1] and not values[4], "Function scaffolding has no output annotation")
  check(view.state().text == "Dispatch and return the nested result.", "Examples stay outside general explanation boxes")
  tour.next_explanation(2)
  check(annotations()[3]:find("returns false", 1, true), "The return output remains visible in its subpart")
  local s = tour.state()
  local selection = require("code-tour.selection").capture(s, { start = 3, ["end"] = 3 })
  local id, prompt = tour.explain_range(selection)
  trace_rules(prompt)
  tour.fill(id, { { file = "source.js", start = 3, ["end"] = 3, note = "Forward the nested return value.",
    example = { input = 'type="keydown", event.key="f"', output = "false", values = { [3] = "returns false" } } } })
  check(annotations()[3]:find("returns false", 1, true), "Return output survives a selected-code refinement")
  local _, definition_prompt = tour.explain_location({ uri = vim.uri_from_fname(root .. "/source.js"),
    range = { start = { line = 2, character = 0 }, ["end"] = { line = 2, character = 1 } } })
  trace_rules(definition_prompt)
  s = tour.state()
  vim.api.nvim_win_set_cursor(s.win, { 3, 14 })
  local current = s.stops[s.stop]
  local context = require("code-tour.definition").capture(s, current,
    require("code-tour.stops").boxes(current)[s.box])
  local _, symbol_prompt = tour.explain_symbol(context, "Test definition lookup failure")
  trace_rules(symbol_prompt)

  local expected = { [7] = "false", [8] = "0", [9] = '""', [10] = "null", [11] = "undefined" }
  tour.show({ { file = "source.js", start = 5, ["end"] = 13, note = "Return the selected literal.",
    example = { input = "One branch example per tag", values = expected } } }, { root = root })
  values = annotations()
  for line, value in pairs(expected) do
    check(values[line] == "  ⇒ " .. value, "Falsy/empty result still displays at return line " .. line)
  end
  check(not values[5] and not values[6] and not values[12] and not values[13], "Nonproductive scaffolding remains unannotated")
  check(vim.deep_equal(vim.api.nvim_buf_get_lines(tour.state().stops[1].buf, 0, -1, false), source), "Output annotations preserve source text")
  tour.stop()
  print("PASS: " .. checks .. " computed-output and example-continuation assertions")
end
local ok, err = xpcall(test, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
