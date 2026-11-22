-- Run a selected test or scratch scenario and collect locals at region boundaries.
local notes = require("code-tour.ast.notes")
local M = {}
local running = false

local function fingerprint(live, id)
  local sym = live.idx:symbol(id)
  return sym and notes.fingerprint(live:buf(sym.file), sym.range)
end

local function boundaries(live)
  local points, evidence = {}, {}
  for _, sn in ipairs(live:all()) do
    if sn.main then
      if live:changed(sn) or vim.bo[live:buf(sn.file)].modified then
        return nil, "Save the main-flow source and rebuild the tour before recording"
      end
      local function add(address, region)
        local stmt = region and region.list and region.list[region.i or 1]
        if not stmt then return end
        local line = stmt.range.start[1] + 1
        local file = live.idx:abs(sn.file)
        points[file] = points[file] or {}
        points[file][line] = points[file][line] or {}
        table.insert(points[file][line], address)
        evidence[address] = sn._fps[address]
      end
      add(sn.symbol, sn._root)
      for _, r in ipairs(sn.regions) do add(r.address, r._region) end
    end
  end
  return points, evidence
end

local function recording_path(live, test, fp, evidence)
  if not live.store.path then return end
  local identity = { test.id, fp }
  local addresses = vim.tbl_keys(evidence)
  table.sort(addresses)
  for _, address in ipairs(addresses) do
    identity[#identity + 1] = address
    identity[#identity + 1] = evidence[address]
  end
  return live.store.path .. "/recordings/" .. vim.fn.sha256(vim.json.encode(identity)) .. ".json"
end

function M.lookup(live, test)
  local points, evidence = boundaries(live)
  if not points then return end
  local fp = fingerprint(live, test.id)
  local path = fp and recording_path(live, test, fp, evidence)
  if not path or vim.fn.filereadable(path) ~= 1 then return end
  local ok, record = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if ok and type(record) == "table" and type(record.values) == "table" then
    return record
  end
end

local function save(live, test, fp, evidence, record)
  local path = recording_path(live, test, fp, evidence)
  if not path then return end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = path .. "." .. vim.uv.os_getpid() .. ".tmp"
  vim.fn.writefile({ vim.json.encode(record) }, tmp)
  assert(vim.uv.fs_rename(tmp, path))
end

function M.consent(store, setting, done)
  if setting == false then return done(false) end
  if setting == true then return done(true) end
  local allowed = store.meta and store:meta().recording_consent
  if allowed ~= nil then return done(allowed == true) end
  vim.ui.select({ "Allow", "Decline" }, {
    prompt = "Run project tests and scratch scenarios? They can access real resources such as databases and the network.",
  }, function(choice)
    if choice and store.set_meta then store:set_meta("recording_consent", choice == "Allow") end
    done(choice == "Allow")
  end)
end

local function java_test(live, test, label, active, finish)
  local dap = require("jdtls.dap").experimental
  local buf = live:buf(test.file)
  local context = dap.make_context(buf)
  local function find(lenses)
    for _, lens in pairs(lenses) do
      local loc = lens.location and lens.location.range or lens.range
      if (lens.level == 4 or lens.testLevel == 6) and loc and loc.start.line + 1 >= test.lines[1]
          and loc.start.line + 1 <= test.lines[2] then
        return lens
      end
      local child = lens.children and find(lens.children)
      if child then return child end
    end
  end
  dap.fetch_lenses(context, function(lenses)
    if not active() then return end
    local lens = find(lenses)
    if not lens then return finish("jdtls did not find the selected test") end
    dap.fetch_launch_args(lens, context, function(args)
      if active() then
        dap.run(lens, dap.make_config(lens, args, { name = label, noDebug = false }), context, {
          after_test = function(items, tests)
            vim.schedule(function()
              local failed = items and #items > 0
              for _, test_result in ipairs(tests or {}) do
                if test_result.traces and #test_result.traces > 0 then failed = true end
              end
              finish(failed and "The selected test failed" or nil, tests and #tests > 0)
            end)
          end,
        })
      end
    end)
  end)
end

local function java_project_position(live, target, buf)
  local sym = live.idx:symbol(target.id)
  if not sym then return end
  local node = vim.treesitter.get_node({ bufnr = buf, pos = sym.range.start, lang = "java" })
  while node do
    local name = node:field("name")[1]
    if name and vim.treesitter.get_node_text(name, buf) == sym.name then
      local row, col = name:start()
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
      return row, vim.str_utfindex(line, "utf-16", col, false)
    end
    node = node:parent()
  end
end

local function java_scenario(live, target, opts, label, timeout, active, finish)
  local buf = live:buf(target.file)
  local client = vim.lsp.get_clients({ name = "jdtls", bufnr = buf })[1]
  if not client then return finish("No jdtls client for the scenario") end
  local javac = vim.fn.exepath("javac")
  if javac == "" then return finish("A Java compiler is unavailable") end
  local windows = vim.fn.has("win32") == 1
  local java = vim.fs.dirname(vim.uv.fs_realpath(javac) or javac) .. (windows and "/java.exe" or "/java")
  local separator = windows and ";" or ":"
  local cwd = client.root_dir or client.config.root_dir or live.root
  local uri = vim.uri_from_bufnr(buf)
  local process

  local function compile(paths, project)
    local parent = vim.fn.stdpath("cache") .. "/code-tour/scenarios"
    vim.fn.mkdir(parent, "p")
    local dir, err = vim.uv.fs_mkdtemp(parent .. "/scenario-XXXXXX")
    if not dir then return finish("Cannot create a scenario directory: " .. tostring(err)) end
    local file = dir .. "/CodeTourScenario.java"
    vim.fn.writefile(vim.split(opts.source, "\n", { plain = true }), file)
    local classpaths = paths.classpaths
    local modulepaths = paths.modulepaths or {}
    local module_args = #modulepaths > 0
      and { "--module-path", table.concat(modulepaths, separator), "--add-modules", "ALL-MODULE-PATH" } or {}
    local command = { javac, "-g", "-proc:none", "-classpath", table.concat(classpaths, separator),
      "-sourcepath", dir, "-d", dir }
    vim.list_extend(command, module_args)
    command[#command + 1] = file
    process = vim.system(command, { cwd = dir, timeout = timeout, text = true }, vim.schedule_wrap(function(compiled)
      process = nil
      if not active() then return end
      if compiled.code ~= 0 then return finish("Scenario compilation failed: " .. (compiled.stderr or "")) end

      -- Java Debug's internal launcher can report exit code zero for a failed JVM.
      -- Own the process so the recording can use its actual exit status.
      local runtime_paths = vim.list_extend({ dir }, classpaths)
      local launch = { java, "-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:0",
        "-classpath", table.concat(runtime_paths, separator) }
      vim.list_extend(launch, module_args)
      launch[#launch + 1] = "CodeTourScenario"
      local port, startup = nil, ""
      local function output(_, chunk)
        if port or not chunk or #startup > 4096 then return end
        startup = startup .. chunk
        port = tonumber(startup:match("Listening for transport dt_socket at address: (%d+)%s"))
        if port then
          vim.schedule(function()
            if not active() then return end
            require("dap").run({ name = label, type = "java", request = "attach", cwd = cwd,
              hostName = "127.0.0.1", port = port, projectName = project, mainClass = "CodeTourScenario",
              javaExec = java, classPaths = runtime_paths, modulePaths = modulepaths }, { new = true })
          end)
        end
      end
      process = vim.system(launch, { cwd = cwd, timeout = timeout, text = true, stdout = output },
        vim.schedule_wrap(function(result)
          process = nil
          if not active() then return end
          if result.code ~= 0 then return finish("The scenario failed") end
          finish()
        end))
    end))
  end

  local accepted = client:request("workspace/executeCommand", { command = "java.project.getClasspaths",
    arguments = { uri, vim.json.encode({ scope = "test" }) } }, function(err, paths)
    if not active() then return end
    if err or not paths or not paths.classpaths then return finish("Cannot determine the Java test classpath") end
    local row, col = java_project_position(live, target, buf)
    if not row then return compile(paths, "") end
    local resolving = client:request("workspace/executeCommand", { command = "vscode.java.resolveElementAtSelection",
      arguments = { uri, row, col } }, function(element_err, element)
      if active() then compile(paths, not element_err and element and element.projectName or "") end
    end, buf)
    if not resolving then compile(paths, "") end
  end, buf)
  if not accepted then finish("Cannot request the Java test classpath") end
  return function()
    if process then pcall(process.kill, process, "sigterm") end
  end
end

local primitives = { byte = true, short = true, int = true, long = true, float = true, double = true,
  boolean = true, char = true, String = true, ["java.lang.String"] = true }

local function capture(session, stopped, points, values)
  local thread = stopped.threadId
  if not thread then return end
  local function next_stop()
    if session.stopped_thread_id == thread then session:_step("continue")
    else session:request("continue", { threadId = thread }, function() end) end
  end
  session:request("stackTrace", { threadId = thread, levels = 1 }, function(err, trace)
    local frame = not err and trace and trace.stackFrames and trace.stackFrames[1]
    local path = frame and frame.source and frame.source.path
    local file = path and points[vim.fs.normalize(path)]
    local addresses = file and file[frame.line]
    if not addresses then return next_stop() end
    session:request("scopes", { frameId = frame.id }, function(scope_err, response)
      if scope_err or not response then return next_stop() end
      local locals
      for _, scope in ipairs(response.scopes or {}) do
        if scope.presentationHint == "locals" or scope.name:lower() == "local" or scope.name:lower() == "locals" then
          locals = scope
          break
        end
      end
      if not locals then return next_stop() end
      session:request("variables", { variablesReference = locals.variablesReference }, function(var_err, vars)
        local parts = {}
        local variables = not var_err and vars and vars.variables or {}
        local function collect(i)
          local var = variables[i]
          if not var then
            if #parts > 0 then
              for _, address in ipairs(addresses) do values[address] = table.concat(parts, ", ") end
            end
            return next_stop()
          end
          local function add(value, object)
            local text = tostring(value)
            if object then text = vim.fn.strcharpart(text, 0, 80) end
            parts[#parts + 1] = var.name .. " = " .. text
            collect(i + 1)
          end
          local object = not primitives[var.type] and (var.variablesReference or 0) > 0
          if object and var.evaluateName then
            session:request("evaluate", { frameId = frame.id, context = "watch",
              expression = "(" .. var.evaluateName .. ").toString()" }, function(eval_err, evaluated)
              add(not eval_err and evaluated and evaluated.result or var.value, true)
            end)
          else
            add(var.value, object)
          end
        end
        collect(1)
      end)
    end)
  end)
end

-- opts.source, when present, is the contents of a standalone CodeTourScenario.java.
function M.start(live, target, opts, done)
  local config = require("code-tour.ast").options
  local ok, dap = pcall(require, "dap")
  local ok_java, jdt = pcall(require, "jdtls.dap")
  if not ok or not ok_java or not jdt.experimental or not dap.adapters.java or not target.id:match("^java:") then
    return done(nil, "Java test debugging is unavailable")
  end
  if running or dap.session() then return done(nil, "A debugger session is already active") end
  if vim.bo[live:buf(target.file)].modified then return done(nil, "Save the test source before recording") end
  local points, evidence = boundaries(live)
  if not points then return done(nil, evidence) end
  if not next(points) then return done(nil, "No executable main-flow region boundaries") end
  local target_fp = fingerprint(live, target.id)
  M.consent(live.store, config.examples.record, function(allowed)
    if not allowed then return done(nil, "Recording consent was declined") end
    if running or dap.session() then return done(nil, "A debugger session is already active") end
    running = true
    local bp = require("dap.breakpoints")
    local marker = "CodeTour " .. tostring(vim.uv.hrtime())
    local added, values = {}, {}
    local session, finished, exit_code, cancel_scenario
    local java_defaults = dap.defaults.java
    local previous_switch = rawget(java_defaults, "switchbuf")
    local function stay() end
    local function active() return not finished end
    local function finish(error_text, test_completed)
      if finished then return end
      finished, running = true, false
      dap.listeners.on_session[marker] = nil
      dap.listeners.before.event_initialized[marker] = nil
      dap.listeners.after.event_stopped[marker] = nil
      dap.listeners.before.event_exited[marker] = nil
      for _, point in ipairs(added) do bp.remove(point[1], point[2]) end
      if rawget(java_defaults, "switchbuf") == stay then java_defaults.switchbuf = previous_switch end
      if not error_text and not opts.source and not test_completed and exit_code ~= 0 then
        error_text = "The test run did not report completion"
      end
      if error_text then
        if cancel_scenario then cancel_scenario() end
        if session and not session.closed then session:disconnect({ terminateDebuggee = true }) end
        return done(nil, error_text)
      end
      local _, current = boundaries(live)
      if not vim.deep_equal(current, evidence) or fingerprint(live, target.id) ~= target_fp then
        return done(nil, "Source changed while recording")
      end
      if not next(values) then return done(nil, "No region locals were captured") end
      local record = { source = opts.source and "executed" or "recorded", values = values, test = target.id,
        test_fingerprint = target_fp, evidence = evidence }
      if not opts.source then save(live, target, target_fp, evidence, record) end
      done(record)
    end
    for path, lines in pairs(points) do
      local buf = live:buf(live.idx:rel(path))
      local existing = {}
      for _, breakpoint in ipairs(bp.get(buf)[buf] or {}) do existing[breakpoint.line] = true end
      for line in pairs(lines) do
        if not existing[line] then
          bp.set({}, buf, line)
          added[#added + 1] = { buf, line }
        end
      end
    end
    local function own(current)
      if not current or current == session or current.config.name ~= marker then return end
      session = current
      java_defaults.switchbuf = stay
    end
    dap.listeners.on_session[marker] = function(_, current) own(current) end
    dap.listeners.before.event_initialized[marker] = own
    dap.listeners.after.event_stopped[marker] = function(current, stopped)
      if current == session then capture(current, stopped, points, values) end
    end
    dap.listeners.before.event_exited[marker] = function(current, event)
      if current == session then exit_code = event.exitCode end
    end
    vim.defer_fn(function() finish("Example recording timed out") end, config.record_timeout_ms)
    local success, err = pcall(function()
      if opts.source then
        cancel_scenario = java_scenario(live, target, opts, marker, config.record_timeout_ms, active, finish)
      else
        java_test(live, target, marker, active, finish)
      end
    end)
    if not success then finish(tostring(err)) end
  end)
end

function M.valid(live, record)
  local _, current = boundaries(live)
  return vim.deep_equal(current, record.evidence) and fingerprint(live, record.test) == record.test_fingerprint
end

function M.values(sn, record)
  local values = {}
  local function add(address, region)
    local stmt = region and region.list and region.list[region.i or 1]
    local val = record.values[address]
    if val and stmt then values[tostring(stmt.range.start[1] + 1)] = val end
  end
  add(sn.symbol, sn._root)
  for _, region in ipairs(sn.regions) do add(region.address, region._region) end
  if next(values) then return { values = values, source = record.source, test = record.test } end
end

return M
