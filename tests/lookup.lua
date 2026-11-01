local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
local tour = require("tour")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = { "local function run(event)", "  local result = handlerStack.bubbleEvent(event)", "  return result", "end" }
vim.fn.writefile(lines, root .. "/caller.lua")
vim.fn.writefile({ "local function bubbleEvent(event)", "  return event", "end" }, root .. "/method.lua")
local subclass = { "class NormalMode extends KeyHandlerMode {", "  init() { this.setKeyMapping({}); }", "}" }
vim.fn.writefile(subclass, root .. "/subclass.js")
vim.fn.writefile({ "class KeyHandlerMode {", "  setKeyMapping(mapping) { this.mapping = mapping; }", "}" }, root .. "/base.js")
for _, name in ipairs({ "caller.lua", "method.lua" }) do vim.fn.bufload(vim.fn.bufadd(root .. "/" .. name)) end
local sent, clients, delivery_failed, notices = {}, {}, false, {}
local original_clients, original_parser, original_notify = vim.lsp.get_clients, vim.treesitter.get_parser, vim.notify
vim.lsp.get_clients = function() return clients end
vim.treesitter.get_parser = function() error("No local parser") end
vim.notify = function(text) notices[#notices + 1] = text end
require("code-tour.conversation").send = function(origin, prompt, action, callback)
  sent[#sent + 1] = { origin = origin, prompt = prompt, action = action }
  callback(not delivery_failed, delivery_failed and "Delivery failed" or nil)
end
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function state() return tour.state() end
local function show()
  clients, delivery_failed = {}, false
  tour.show({ { file = "caller.lua", start = 1, ["end"] = 4, title = "Run handler", note = "Run event handler",
    parts = { { start = 1, ["end"] = 2, note = "Dispatch the event" },
      { start = 3, ["end"] = 4, note = "Return the result" } },
  } }, { root = root, origin = { session = "test-session", pane_id = "agent-pane", agent = "codex", process_ids = { 123 } } })
  tour.next_explanation(1)
  vim.api.nvim_win_set_cursor(state().win, { 2, lines[2]:find("bubbleEvent", 1, true) - 1 })
end
local function pending()
  check(vim.wait(1000, function() return next(state().pending) ~= nil end, 1), "Agent lookup request became pending")
  return next(state().pending)
end
local function flush()
  local done = false
  vim.schedule(function() done = true end)
  assert(vim.wait(1000, function() return done end, 1))
end
local function reply()
  return { { file = "method.lua", start = 1, ["end"] = 3, title = "bubbleEvent", note = "Pass the event to the handler" } }
end
local function badges()
  local count, s = 0, state()
  local ns = vim.api.nvim_get_namespaces().CodeTourSource
  local buf = s.stops[s.stop].buf
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == "CodeTourCall" then count = count + 1 end
  end
  return count
end
local function test()
  tour.setup({ smooth_scroll = false })
  show()
  local before = #sent
  local id, prompt = tour.expand_call()
  check(id and state().pending[id].lookup and #sent == before + 1, "No provider/parser falls back to the agent")
  check(prompt:find("Symbol under cursor: bubbleEvent", 1, true)
    and prompt:find("Call expression: handlerStack.bubbleEvent", 1, true), "Prompt identifies the symbol and receiver")
  check(prompt:find(root .. "/caller.lua:2", 1, true) and prompt:find(lines[2], 1, true), "Prompt contains exact call-site path, line and arguments")
  check(prompt:find("Dispatch the event", 1, true) and prompt:find("Project root: " .. root, 1, true), "Prompt includes explanation and project context")
  check(prompt:find("--fill " .. id, 1, true) and prompt:find("--tour " .. state().id, 1, true), "Prompt carries the exact fill request and tour identity")
  check(sent[#sent].origin.pane_id == "agent-pane" and sent[#sent].action == "stay", "Fallback goes to the original agent without focus changes")
  check(state().stop == 1 and state().box == 2 and badges() == 0, "Unresolved call leaves the caller selected and unbadged")
  check(tour.expand_call() == id and #sent == before + 1, "Repeated ad reuses the pending lookup")
  local filled = tour.fill(id, reply())
  check(filled.navigate and state().stops[state().stop].file == "method.lua", "Agent can resolve a definition in another file")
  tour.return_to_caller()
  check(state().stop == 1 and state().box == 2 and badges() == 1, "Return restores the original caller and the now-ready badge")

  local cases = {
    { name = "empty LSP result", request = function(_, _, _, cb) cb(nil, {}); return true end },
    { name = "LSP error", request = function(_, _, _, cb) cb({ message = "LSP failed" }, nil); return true end },
    { name = "unsent request", request = function() return false end },
    { name = "throwing provider", request = function() error("Provider crashed") end },
    { name = "invalid definition file", request = function(_, _, _, cb)
      cb(nil, {{ uri = vim.uri_from_fname(root .. "/missing.lua"),
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 1 } } }})
      return true
    end },
  }
  for _, case in ipairs(cases) do
    show()
    clients = {{ offset_encoding = "utf-16", request = case.request }}
    before = #sent
    tour.expand_call()
    id = pending()
    check(#sent == before + 1 and state().pending[id].lookup, case.name .. " sends exactly one agent request")
  end

  show()
  local receive
  clients = {{ offset_encoding = "utf-16", request = function(_, _, _, cb) receive = cb; return true end }}
  before = #sent
  tour.expand_call()
  tour.next_explanation(1)
  tour.next_explanation(-1)
  receive(nil, {})
  flush()
  check(#sent == before and not next(state().pending), "Navigation away and back cancels the old LSP fallback intent")

  show()
  clients = {{ offset_encoding = "utf-16", request = function(_, _, _, cb) receive = cb; return true end }}
  tour.expand_call()
  tour.cancel()
  before = #sent
  receive({ message = "late error" }, nil)
  flush()
  check(#sent == before and not next(state().pending), "Cancelled tour does not dispatch a late fallback")

  show()
  id = tour.expand_call()
  tour.next_explanation(1)
  filled = tour.fill(id, reply())
  check(not filled.navigate and state().stop == 1 and state().box == 3, "Late agent reply does not move a reader who continued")

  show()
  id = tour.expand_call()
  filled = tour.fill(id, { unresolved = "Implementation is supplied dynamically and cannot be located" })
  check(filled.unresolved and not filled.navigate and not state().pending[id] and badges() == 0, "Unresolved reply never invents a definition or badge")
  before = #sent
  local retry = tour.expand_call()
  check(retry and retry ~= id and #sent == before + 1 and state().pending[retry].lookup, "Unresolved symbol retries the agent, not the call-site source as a fake definition")

  show()
  delivery_failed = true
  id = tour.expand_call()
  check(not state().pending[id] and badges() == 0, "Failed agent delivery leaves no fake ready explanation")
  delivery_failed = false
  retry = tour.expand_call()
  check(retry and retry ~= id and state().pending[retry].lookup, "Failed delivery is retryable")

  show()
  id = tour.expand_call()
  local buf = state().stops[1].buf
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { lines[2] .. " -- changed" })
  check(not pcall(tour.fill, id, reply()), "Changed caller source rejects a stale resolution")
  retry = tour.expand_call()
  check(retry ~= id and not state().pending[id] and state().pending[retry].lookup, "ad refreshes a stale pending lookup with current context")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  check(vim.deep_equal(vim.fn.readfile(root .. "/caller.lua"), lines), "Resolution never edits source on disk")

  -- A superclass reference has no call parentheses. It must not fall back to
  -- the only attached method and explain that unrelated method instead.
  local function show_class(lazy)
    clients = {}
    tour.show({ { file = "subclass.js", start = 1, ["end"] = 3, title = "NormalMode", note = "Subclass the key handler.",
      calls = { { file = "base.js", start = 2, ["end"] = 2, title = "setKeyMapping", lazy = lazy,
        note = not lazy and "Install the mapping." or nil, callsite = { start = 2, symbol = "this.setKeyMapping" } } },
    } }, { root = root, origin = { session = "test-session", pane_id = "agent-pane", agent = "codex", process_ids = { 123 } } })
    vim.api.nvim_win_set_cursor(state().win, { 1, subclass[1]:find("KeyHandlerMode", 1, true) - 1 })
  end
  show_class(false)
  before = #sent
  id, prompt = tour.expand_call()
  check(id and state().pending[id] and state().pending[id].lookup.expression == "KeyHandlerMode",
    "ad on a superclass resolves the class rather than the only prepared method")
  check(#sent == before + 1 and state().stop == 1 and prompt:find("Symbol under cursor: KeyHandlerMode", 1, true),
    "The class request uses the originating conversation and preserves the caller")
  tour.fill(id, { { file = "base.js", start = 1, ["end"] = 3, title = "KeyHandlerMode", note = "Provide shared key handling." } })
  tour.return_to_caller()
  local class_badge
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state().stops[1].buf,
    vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })) do
    if mark[2] == 0 and mark[4].hl_group == "CodeTourCall" then class_badge = mark end
  end
  check(class_badge and class_badge[4].virt_text[1][1] == "KeyHandlerMode" and badges() == 2,
    "A generated superclass explanation badges the exact class name while retaining the method badge")
  before = #sent
  vim.api.nvim_win_set_cursor(state().win, { 1, subclass[1]:find("KeyHandlerMode", 1, true) - 1 })
  tour.expand_call()
  check(state().stops[state().stop].title == "KeyHandlerMode" and #sent == before,
    "ad on the red class name reuses the prepared explanation")
  show_class(true)
  id = tour.expand_call()
  check(id and state().pending[id].lookup and state().pending[id].lookup.expression == "KeyHandlerMode",
    "An unrelated lazy method cannot steal a class inspection either")
  tour.stop()
  print("PASS: " .. checks .. " agent definition-fallback assertions")
end
local ok, err = xpcall(test, debug.traceback)
vim.lsp.get_clients, vim.treesitter.get_parser, vim.notify = original_clients, original_parser, original_notify
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
