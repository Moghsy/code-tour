local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").send = function(_, _, _, callback) callback(true) end
local tour = require("tour")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {
  "function caller(input) {", "  const a = input.value;", "  // Prepare the call.",
  "  const value = a + 1;", "  return target.run(value);", "}", "", "// BOXTAIL_MARKER",
  "function run(value) {", "  return value * 2;", "}",
}
vim.fn.writefile(lines, root .. "/source.js")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function show(extra)
  local items = { { file = "source.js", start = 1, ["end"] = 8, title = "Caller", note = "Call the target.",
    parts = { { start = 1, ["end"] = 4, note = "Prepare the input." }, { start = 5, ["end"] = 8, note = "Return the computed result." } },
    example = { input = "input.value = 1", output = "4", values = {
      [1] = "OUTPUT_NOISE_BEFORE", [3] = "a = 1", [4] = "value = 2", [5] = "returns 4", [8] = "OUTPUT_NOISE_AFTER",
    } },
  } }
  for _ = 1, extra or 0 do
    items[#items + 1] = { file = "source.js", start = 9, ["end"] = 11, title = "UNRELATED_SNIPPET",
      note = ("UNRELATED_EXPLANATION "):rep(50) }
  end
  tour.show(items, { root = root })
  tour.next_explanation(2)
  vim.api.nvim_win_set_cursor(tour.state().win, { 5, lines[5]:find("target.run", 1, true) - 1 })
end
local function selection()
  return require("code-tour.selection").capture(tour.state(), { start = 5, ["end"] = 5 })
end
local function contains_once(text, value)
  local first, last = text:find(value, 1, true)
  return first and not text:find(value, last + 1, true)
end
local function compact(prompt)
  check(not prompt:find("UNRELATED", 1, true) and not prompt:find("Numbered outline", 1, true), "Unrelated tour notes and full outline stay local")
  check(not prompt:find("OUTPUT_NOISE_BEFORE", 1, true) and not prompt:find("OUTPUT_NOISE_AFTER", 1, true), "Only the relevant example values accompany this request")
  check(contains_once(prompt, lines[5]), "The selected call source is sent once")
  check(prompt:find("--fill ", 1, true) and prompt:find("--pane ", 1, true)
    and prompt:find("--tour " .. tour.state().id, 1, true), "Compact prompts retain their exact delivery identity")
  check(#prompt < 2200, "A simple explanation request stays below 2.2 KB: " .. #prompt)
end
local function test()
  tour.setup({ smooth_scroll = false })
  show(0)
  local _, small = tour.explain_range(selection())
  show(100)
  local id, prompt = tour.explain_range(selection())
  compact(prompt)
  check(math.abs(#prompt - #small) < 30, "Request size does not grow with the main tour")
  check(#tour.state().pending[id].snapshot == 101, "The complete placement snapshot is still retained locally")
  tour.fill(id, { { file = "source.js", start = 5, ["end"] = 5, note = "Forward the computed result." } })
  check(tour.state().stops[1].parts[tour.state().box - 1].note == "Forward the computed result.", "Compact requests retain their exact fill placement")

  show(100)
  local context = require("code-tour.definition").capture(tour.state(), tour.state().stops[1], tour.state().stops[1].parts[2])
  id, prompt = tour.explain_symbol(context, "Test lookup failure")
  compact(prompt)
  check(not prompt:find("BOXTAIL_MARKER", 1, true) and not prompt:find("Containing box source", 1, true), "Symbol lookup sends nearby source rather than the whole box again")
  check(prompt:find('"4":"value = 2"', 1, true), "The nearest computed caller values accompany a callee request")

  show(100)
  id, prompt = tour.explain_location({ uri = vim.uri_from_fname(root .. "/source.js"),
    range = { start = { line = 8, character = 0 }, ["end"] = { line = 11, character = 0 } } }, nil, true)
  compact(prompt)
  check(not prompt:find("BOXTAIL_MARKER", 1, true), "Definition requests send the call neighborhood rather than the whole caller box")
  check(prompt:find(root .. "/source.js:9", 1, true), "The definition location is retained for reading source on demand")
  tour.stop()
  print("PASS: " .. checks .. " compact request context assertions")
end
local ok, err = xpcall(test, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
