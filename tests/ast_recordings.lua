local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

t.finish("AST recordings", function()
  local recordings = require("code-tour.ast.recordings")
  local ast = require("code-tour.ast")
  ast.setup({ examples = { record = true }, record_timeout_ms = 200 })

  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local rel = "Example.java"
  local path = root .. "/" .. rel
  local source = { "class Example {", "  int value() {", "    return 1;", "  }", "}" }
  vim.fn.writefile(source, path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  local id = "java:Example#value()"
  local sym = { id = id, file = rel, range = { start = { 1, 2 }, ["end"] = { 3, 3 } } }
  local snippet = { main = true, file = rel, symbol = id, regions = {},
    _root = { list = { { range = { start = { 2, 4 }, ["end"] = { 2, 13 } } } } }, _fps = { [id] = "root" } }
  local changed = false
  local live = { root = root, store = { path = root .. "/store" },
    idx = {
      symbol = function(_, target) if target == id then return sym end end,
      abs = function(_, file) return root .. "/" .. file end,
      rel = function(_, file) return file:sub(#root + 2) end,
    },
    buf = function() return buf end,
    all = function() return { snippet } end,
    changed = function() return changed end,
  }
  local selected = { id = id, file = rel, lines = { 2, 4 } }

  local function event_map()
    return setmetatable({}, { __index = function(self, key)
      local listeners = {}
      self[key] = listeners
      return listeners
    end })
  end
  local active_session
  local dap = { adapters = { java = {} }, defaults = { java = {} },
    listeners = { before = event_map(), after = event_map(), on_session = {} },
    session = function() return active_session end, sessions = function() return active_session and { active_session } or {} end }
  local function emit(listeners, ...)
    for _, callback in pairs(listeners) do callback(...) end
  end
  local breakpoints = { [2] = true }
  package.loaded.dap = dap
  package.loaded["dap.breakpoints"] = {
    get = function()
      local items = {}
      for line in pairs(breakpoints) do items[#items + 1] = { line = line } end
      return { [buf] = items }
    end,
    set = function(_, _, line) breakpoints[line] = true end,
    remove = function(_, line) breakpoints[line] = nil end,
  }

  local stopped, disconnected, saved_cb, completion
  local function run(_, config, _, opts)
    saved_cb = opts.after_test
    stopped, disconnected = 0, false
    local session = { config = config, stopped_thread_id = 1, on_close = {},
      request = function(_, command, _, callback)
        local response = ({
          stackTrace = { stackFrames = { { id = 2, line = 3, source = { path = path } } } },
          scopes = { scopes = { { name = "Local", variablesReference = 3 } } },
          variables = { variables = { { name = "total", type = "int", value = "42", variablesReference = 0 } } },
        })[command]
        callback(nil, response)
      end,
      _step = function(_, command)
        t.eq(command, "continue", "recording resumes the debuggee after reading locals")
        stopped = stopped + 1
      end,
      disconnect = function(_, opts)
        disconnected = opts.terminateDebuggee
      end,
    }
    active_session = session
    emit(dap.listeners.on_session, nil, session)
    emit(dap.listeners.before.event_initialized, session)
    emit(dap.listeners.after.event_stopped, session, { threadId = 1 })
    if completion then
      emit(dap.listeners.before.event_exited, session, { exitCode = 0 })
      emit(dap.listeners.before.event_terminated, session)
      session.closed = true
      emit(session.on_close)
      active_session = nil
      emit(dap.listeners.on_session, session, nil)
      opts.after_test({}, { { failed = false } })
    end
  end

  package.loaded["jdtls.dap"] = { experimental = {
    make_context = function() return {} end,
    fetch_lenses = function(_, fn) fn({ { testLevel = 6, location = { range = { start = { line = 1 } } } } }) end,
    fetch_launch_args = function(_, _, fn) fn({}) end,
    make_config = function(_, _, config) return config end,
    run = run,
  } }
  local original = vim.lsp.get_clients
  vim.lsp.get_clients = function()
    return { { name = "jdtls", server_capabilities = { executeCommandProvider = {
      commands = { "vscode.java.test.search.codelens", "vscode.java.test.junit.argument" },
    } } } }
  end

  local record, err, done
  local function finish(value, message)
    record, err, done = value, message, true
  end
  completion = true
  recordings.start(live, selected, {}, finish)
  t.check(vim.wait(500, function() return done end), "recording completion reaches the caller")
  t.eq(err, nil, "completed test records without errors")
  t.eq(stopped, 1, "the region stop is continued once")
  t.eq(record.values[id], "total = 42", "recording stores step locals by region address")
  t.eq(recordings.values(snippet, record).values, { ["3"] = "total = 42" }, "locals project onto their source line")
  t.eq(recordings.lookup(live, selected), record, "completed recording is reused for matching fingerprints")
  t.eq(breakpoints, { [2] = true }, "recording cleans up only the breakpoint it added")
  changed = true
  t.check(not recordings.lookup(live, selected) and not recordings.valid(live, record), "stale source hides recordings")
  changed = false

  ast.setup({ examples = { record = true }, record_timeout_ms = 20 })
  completion, record, done, err = false, nil, false, nil
  recordings.start(live, selected, {}, finish)
  t.check(vim.wait(500, function() return done end), "timeout reaches the caller")
  t.check(err and err:match("timed out") and disconnected and not record, "timeout terminates the recording debugger")
  t.eq(breakpoints, { [2] = true }, "timeout also restores the breakpoint set")
  saved_cb({}, { { failed = false } })
  t.check(not record, "late test completion after timeout is ignored")
  vim.lsp.get_clients = original
end)
