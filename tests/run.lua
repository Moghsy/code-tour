local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 100
vim.env.HERDR_ENV, vim.env.HERDR_SESSION, vim.env.HERDR_PANE_ID = nil, nil, nil
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 100 do
  lines[i] = "local value" .. i .. " = " .. i
end
vim.fn.writefile(lines, root .. "/source.lua")
vim.fn.writefile(lines, root .. "/definition.lua")
local tour = require("tour")
local model = require("code-tour.stops")
local captured = {}
require("code-tour.conversation").send = function(_, prompt, action, callback)
  captured[#captured + 1] = { prompt = prompt, action = action }
  callback(true)
end
local function stop(first, last, parts)
  return { file = "source.lua", start = first, ["end"] = last, note = "Explain " .. first, parts = parts }
end
local function part(first, last)
  return { start = first, ["end"] = last, note = "Part " .. first }
end
local function show(data, opts)
  tour.show(data, vim.tbl_extend("force", { root = root }, opts or {}))
end
local function state()
  return tour.state()
end
local function location(file, line)
  return {
    uri = vim.uri_from_fname(root .. "/" .. file),
    range = { start = { line = line - 1, character = 0 }, ["end"] = { line = line - 1, character = 4 } },
  }
end
local checks = 0
local function check(value, msg)
  assert(value, msg)
  checks = checks + 1
end
local function rejects(fn)
  check(not pcall(fn), "Expected validation to reject invalid input")
end
local function test()
  tour.setup({ smooth_scroll = false })
  rejects(function()
    show({ stop(1, 10, { part(2, 10) }) })
  end)
  rejects(function()
    show({ stop(1, 10, { part(1, 4), part(6, 10) }) })
  end)
  rejects(function()
    show({ stop(1, 10, { part(1, 9) }) })
  end)
  rejects(function()
    show({ stop(1, 10, { part(1, 11) }) })
  end)
  local first = stop(1, 10, { part(1, 5), part(6, 10) })
  first.example = { input = "value = 2", output = "4", values = { [2] = { value = "4", detail = "Doubled" } } }
  local original = vim.api.nvim_get_current_tabpage()
  show({ first, stop(20, 25) }, { append = true })
  check(state().id ~= nil, "Append can start a new tour")
  check(state().tab ~= original, "Tour should own a separate tab")
  check(not vim.wo[state().win].diff, "Tour should not enable diff")
  check(
    vim.deep_equal(vim.api.nvim__ns_get(vim.api.nvim_get_namespaces().CodeTourSource).wins, { state().win }),
    "Source decorations must be window scoped"
  )
  check(vim.b[state().stops[1].buf].snacks_scroll ~= false, "Native Snacks scroll must remain available")
  tour.next_explanation(1)
  check(state().box == 2, "Part follows overview")
  tour.ask("What is doubled?", "stay", { 2, 3 })
  check(captured[#captured].prompt:find("source.lua:2-3", 1, true), "Question includes selected source")
  check(not captured[#captured].prompt:find("Doubled", 1, true), "Question omits context the agent already has")
  check(not captured[#captured].prompt:find("```", 1, true), "Question omits source code")
  tour.answer("It doubles the value.", "1.2")
  check(state().stops[1].parts[1].thread[1].answer == "It doubles the value.", "Answer belongs to the part")
  tour.next_explanation(1)
  check(#state().stops[1].parts[2].thread == 0, "Other boxes have separate threads")
  tour.ask("Follow this", "follow")
  check(captured[#captured].action == "follow", "Follow action reaches transport")
  tour.answer("Follow answer")
  tour.ask("Draft this", "add")
  check(captured[#captured].action == "add", "Draft action reaches transport")
  tour.answer("Draft answer", "1.3")
  tour.next_explanation(1)
  check(state().stop == 2 and state().box == 1, "Next box crosses snippet boundary")
  tour.next_explanation(-1)
  check(state().stop == 1 and state().box == 3, "Previous box crosses snippet boundary")
  tour.hide()
  check(not state().visible, "Hide works")
  tour.toggle()
  check(state().visible, "Toggle restores state")
  local pending_box = state().stops[1].parts[2]
  tour.ask("Answer after insertion", "stay")
  local id = tour.explain_location(location("definition.lua", 30))
  check(state().stops[2].placeholder == id, "External definition inserts a placeholder")
  local second_id = tour.explain_location(location("definition.lua", 40))
  check(state().stops[2].placeholder == second_id, "Concurrent explain inserts independently")
  -- The first request's stop 2 was its placeholder, even after the second insert.
  tour.fill(id, { stop(50, 55) }, { after = 2 })
  check(state().stops[3].start == 50, "--after resolves the saved outline")
  check(not state().pending[id] and state().pending[second_id], "Only completed request is consumed")
  tour.answer("Still the original box", "1.3")
  check(pending_box.thread[#pending_box.thread].answer == "Still the original box", "Replies survive insertion")
  tour.fill(second_id, { stop(60, 65) })
  check(state().stops[2].start == 60, "Default fill replaces its own placeholder")
  rejects(function()
    tour.fill(second_id, { stop(60, 65) })
  end)
  tour.next_snippet(1 - state().stop)
  tour.next_explanation(2)
  local refine = tour.explain_location(location("source.lua", 2))
  check(not state().pending[refine].placeholder, "Internal definitions refine a box")
  rejects(function()
    tour.fill(refine, { stop(1, 4) })
  end)
  tour.fill(refine, { stop(1, 5, { part(1, 2), part(3, 5) }) })
  check(state().box == 3 and state().stops[1].parts[2].start == 1, "Refinement follows the definition's box")
  local into = tour.explain_location(location("definition.lua", 70))
  tour.fill(into, { stop(6, 10) }, { into = "1.5" })
  check(state().stops[1].parts[5].start == 6, "--into uses the request's saved box outline")
  local before = state().stops[state().stop]
  local async = tour.explain_location(location("definition.lua", 80))
  local mode = vim.api.nvim_get_mode
  vim.api.nvim_get_mode = function()
    return { mode = "i" }
  end
  tour.fill(async, { stop(85, 90) })
  vim.api.nvim_get_mode = mode
  check(state().stops[state().stop] == before and state().arrival, "Incoming fills preserve typing location")
  -- old is a snippet replacement, even when the snippet starts at line one.
  local review = stop(1, 2)
  review.old = "old first\nold second"
  show({ review }, { review = true })
  check(
    state().stops[1].added[1] and state().stops[1].added[2] and not state().stops[1].added[3],
    "Review old compares only the snippet"
  )
  check(#state().stops[1].removed[1].lines == 2, "Removed lines remain virtual data")
  check(vim.deep_equal(vim.fn.readfile(root .. "/source.lua"), lines), "Rendering leaves source unchanged")
  local old = {
    version = 1,
    snippets = { { file = "source.lua", start_line = 1, end_line = 3, overview = "Legacy", sections = {} } },
  }
  show(old)
  check(state().stops[1].note == "Legacy", "Former file format still loads")
  -- Exercise a real installed Tree-sitter parser, without an LSP server.
  vim.opt.rtp:append(vim.fn.expand("~/.local/share/nvim/site"))
  vim.fn.writefile(
    { "local function double(x)", "  return x * 2", "end", "", "local value = double(2)", "return value" },
    root .. "/symbols.lua"
  )
  show({ { file = "symbols.lua", start = 5, ["end"] = 6, note = "Call double" } })
  vim.bo[state().stops[1].buf].filetype = "lua"
  vim.api.nvim_win_set_cursor(state().win, { 5, 15 })
  tour.explain_definition()
  check(
    state().stops[2] and state().stops[2].placeholder and state().stops[2].start == 1,
    "Tree-sitter finds the same-file definition"
  )
  -- LSP LocationLink result uses targetSelectionRange and retains the call site.
  show({ stop(1, 5) })
  local get_clients = vim.lsp.get_clients
  vim.lsp.get_clients = function()
    return {
      {
        offset_encoding = "utf-16",
        request = function(_, method, params, callback)
          check(method == "textDocument/definition" and params.position ~= nil, "LSP gets definition position")
          callback(nil, {
            {
              targetUri = vim.uri_from_fname(root .. "/definition.lua"),
              targetSelectionRange = { start = { line = 9, character = 0 }, ["end"] = { line = 9, character = 5 } },
            },
          })
        end,
      },
    }
  end
  tour.explain_definition()
  vim.lsp.get_clients = get_clients
  check(
    vim.wait(1000, function()
      return state().stops[2] and state().stops[2].start == 10
    end, 10),
    "LSP LocationLink creates definition placeholder"
  )
  tour.stop()
  check(not state().visible and not next(state().pending), "Quit clears UI and pending requests")
  local stale = model.normalize({ stop(1, 2) }, root)
  check(stale[1].uid ~= nil, "Stops have stable identities")
  print("PASS: " .. checks .. " tour assertions")
end
local ok, err = xpcall(test, debug.traceback)
require("code-tour.instance").unregister()
if not ok then
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
else
  vim.cmd("qa!")
end
