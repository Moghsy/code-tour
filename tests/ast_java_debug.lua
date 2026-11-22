-- Opt-in integration test for a local JDK, Mason jdtls/Java Debug/Java Test, and
-- nvim-dap and nvim-jdtls. The JVMs and Neovim use local loopback sockets.
-- Run with CODE_TOUR_REAL_JAVA=1 nvim --clean --headless -l tests/ast_java_debug.lua.
if vim.env.CODE_TOUR_REAL_JAVA ~= "1" then
  print("SKIP: real Java debugger integration (set CODE_TOUR_REAL_JAVA=1)")
  vim.cmd("qa!")
  return
end

local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

t.finish("real Java recordings", function()
  t.check(t.parser(), "Java Tree-sitter parser is installed")
  local plugins = vim.env.CODE_TOUR_JAVA_NVIM_PLUGINS or vim.fn.stdpath("data") .. "/lazy"
  local mason = vim.env.CODE_TOUR_JAVA_MASON or vim.fn.stdpath("data") .. "/mason/packages"
  for _, name in ipairs({ "nvim-dap", "nvim-jdtls" }) do
    vim.opt.rtp:append(plugins .. "/" .. name)
  end
  local function jars(pattern)
    return vim.fn.glob(mason .. "/" .. pattern, true, true)
  end
  local bundles = jars("java-debug-adapter/extension/server/com.microsoft.java.debug.plugin-*.jar")
  t.eq(#bundles, 1, "Mason Java Debug bundle is installed")
  local test_bundles = jars("java-test/extension/server/*.jar")
  t.check(#test_bundles > 0, "Mason Java Test bundles are installed")
  for _, jar in ipairs(test_bundles) do
    if not jar:match("jar%-with%-dependencies") and not jar:match("/jacocoagent%.jar$") then
      bundles[#bundles + 1] = jar
    end
  end
  local junit = {}
  for _, prefix in ipairs({ "junit-jupiter-api_5.", "junit-jupiter-engine_5.", "junit-platform-commons_1.",
      "junit-platform-engine_1.", "junit-platform-launcher_1.", "org.apiguardian.api_", "org.opentest4j_" }) do
    local matches = jars("java-test/extension/server/" .. prefix .. "*.jar")
    junit[#junit + 1] = assert(matches[#matches], "missing JUnit jar: " .. prefix)
  end
  local work = vim.fn.tempname()
  local root = work .. "/fixture"
  local src, tests = "src/demo/Calculator.java", "test/demo/CalculatorTest.java"
  vim.fn.mkdir(root .. "/src/demo", "p")
  vim.fn.mkdir(root .. "/test/demo", "p")
  vim.fn.writefile({
    "<projectDescription><name>code-tour-fixture</name><natures>",
    "<nature>org.eclipse.jdt.core.javanature</nature></natures><buildSpec><buildCommand>",
    "<name>org.eclipse.jdt.core.javabuilder</name></buildCommand></buildSpec></projectDescription>",
  }, root .. "/.project")
  local classpath = {
    "<classpath>",
    '<classpathentry kind="con" path="org.eclipse.jdt.launching.JRE_CONTAINER"/>',
    '<classpathentry kind="src" path="src"/>',
    '<classpathentry kind="src" path="test"><attributes><attribute name="test" value="true"/></attributes></classpathentry>',
    '<classpathentry kind="output" path="bin"/>',
  }
  for _, jar in ipairs(junit) do
    classpath[#classpath + 1] = '<classpathentry kind="lib" path="' .. jar .. '"/>'
  end
  classpath[#classpath + 1] = "</classpath>"
  vim.fn.writefile(classpath, root .. "/.classpath")
  vim.fn.writefile({
    "package demo;",
    "public class Calculator {",
    "  public static int compute(int total, String text, Label label) {",
    "    return total * 2;",
    "  }",
    "  public static class Label {",
    "    public String toString() { return \"label-\" + \"a\".repeat(100); }",
    "  }",
    "}",
  }, root .. "/" .. src)
  vim.fn.writefile({
    "package demo;",
    "import org.junit.jupiter.api.Test;",
    "import static org.junit.jupiter.api.Assertions.assertEquals;",
    "class CalculatorTest {",
    "  @Test void doubles() {",
    "    assertEquals(84, Calculator.compute(42, \"b\".repeat(100), new Calculator.Label()));",
    "  }",
    "  @Test void fails() {",
    "    assertEquals(0, Calculator.compute(99, \"failure\", new Calculator.Label()));",
    "  }",
    "}",
  }, root .. "/" .. tests)
  t.run({ "git", "init", "-q" }, root)
  t.run({ "javac", "-g", "-classpath", table.concat(junit, vim.fn.has("win32") == 1 and ";" or ":"), "-d", "bin", src, tests }, root)

  vim.env.XDG_CACHE_HOME = work .. "/cache"
  vim.env.XDG_STATE_HOME = work .. "/state"
  vim.env.NVIM_LOG_FILE = work .. "/nvim.log"
  local main_buf, test_buf = vim.fn.bufadd(root .. "/" .. src), vim.fn.bufadd(root .. "/" .. tests)
  vim.fn.bufload(main_buf)
  vim.fn.bufload(test_buf)
  vim.api.nvim_set_current_buf(test_buf)
  local status
  local jdtls = require("jdtls")
  jdtls.start_or_attach({
    cmd = { mason .. "/jdtls/bin/jdtls", "--jvm-arg=-Duser.home=" .. work, "-data", work .. "/jdtls" },
    root_dir = root,
    init_options = { bundles = bundles },
    handlers = { ["language/status"] = function(_, result)
      status = result.type
    end },
    settings = { java = { configuration = { updateBuildConfiguration = "automatic" } } },
    on_exit = function(code) status = "Exited " .. code end,
  })
  t.check(vim.wait(30000, function() return status == "ServiceReady" or status and status:match("^Exited") end) and status == "ServiceReady",
    "jdtls initialized the fixture: " .. tostring(status))
  local client = assert(vim.lsp.get_clients({ name = "jdtls" })[1])
  vim.lsp.buf_attach_client(main_buf, client.id)
  jdtls.setup_dap()
  local tour = require("code-tour.tour")
  tour.setup({ smooth_scroll = false, ast = { examples = { record = true }, record_timeout_ms = 15000 } })
  require("code-tour.conversation").deliver = function(_, _, _, _, done) done(true) end
  tour.ast_tour({ root = root, cache_dir = work .. "/ast", entries = { "Calculator#compute" } })
  local state = tour.state()
  local live = state.ast
  local method = "java:demo.Calculator#compute(int,String,Label)"
  local matches = require("code-tour.ast.examples").tests(live.idx, { method })
  t.eq(vim.tbl_map(function(candidate) return candidate.label end, matches),
    { "CalculatorTest.doubles()", "CalculatorTest.fails()" }, "offers the two JUnit methods in order")
  local passing, failed = matches[1], matches[2]
  local recordings = require("code-tour.ast.recordings")
  local dap = require("dap")
  local breakpoints = require("dap.breakpoints")
  breakpoints.set({}, main_buf, 8)

  local function wait_for_close()
    t.check(vim.wait(3000, function() return not dap.session() end), "DAP session closed")
    local remaining = breakpoints.get(main_buf)[main_buf]
    t.eq(vim.tbl_map(function(point) return point.line end, remaining), { 8 }, "restores existing breakpoints")
  end

  local function record(target, opts)
    local complete, value, failure
    recordings.start(live, target, opts or {}, function(result, err)
      complete, value, failure = true, result, err
    end)
    t.check(vim.wait(20000, function() return complete end), "recording completed")
    wait_for_close()
    return value, failure
  end
  local source_win = state.win
  local tab = vim.api.nvim_get_current_tabpage()
  vim.cmd.CodeTourRecord()
  t.check(vim.wait(20000, function() return live.recorded ~= nil end), "CodeTourRecord captured real JUnit values")
  wait_for_close()
  local test_result = live.recorded
  t.eq(test_result.source, "recorded", "JUnit sets recorded provenance")
  local locals = assert(test_result.values[method])
  t.check(locals:find("total = 42", 1, true), "captures primitive input")
  t.check(locals:find(string.rep("b", 100), 1, true), "captures a long string input")
  local label = '"label-' .. string.rep("a", 73)
  t.check(locals:find("label = " .. label, 1, true) and not locals:find(label .. "a", 1, true),
    "uses and truncates the object toString value to 80 characters")
  t.eq(recordings.lookup(live, passing), test_result, "reads the persisted JUnit recording")
  t.eq(state.stops[1].recorded_example.values["4"], locals, "shows captured locals on the Java source line")
  t.eq({ vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win() }, { tab, source_win },
    "recording leaves the reader in the tour window")
  local failed_result, failed_error = record(failed)
  t.eq(failed_result, nil, "failed JUnit test yields no recording")
  t.eq(failed_error, "The selected test failed", "reports a real JUnit assertion failure")
  local scenario = [[
import demo.Calculator;
public class CodeTourScenario {
  public static void main(String[] args) {
    Calculator.compute(7, "scenario", new Calculator.Label());
  }
}
]]
  tour.ask("What happens when the total is seven?")
  tour.ast_scenario({ box = "n1", source = scenario })
  local turn = state.stops[1].thread[1]
  t.check(vim.wait(20000, function() return turn.answer or turn.error end) and turn.answer,
    turn.error or "scratch scenario answered the tour question")
  wait_for_close()
  t.eq(turn.source, "executed", "scratch run sets executed provenance")
  t.check(turn.answer:find("total = 7", 1, true), "scratch run records its own input")
  t.check(turn.answer:find("label = " .. label, 1, true), "scratch run evaluates toString in the project")
  t.check(turn.answer:find(vim.trim(scenario), 1, true), "scratch answer includes the executed code")

  local crash, crash_error = record({ id = method, file = src }, { source = [[
import demo.Calculator;
public class CodeTourScenario {
  public static void main(String[] args) {
    Calculator.compute(7, "scenario", new Calculator.Label());
    throw new IllegalStateException("scenario failed after a capture");
  }
}
]] })
  t.eq(crash, nil, "failed scenario yields no recording")
  t.eq(crash_error, "The scenario failed", "reports a real nonzero debuggee exit")
  local invalid, compilation_error = record({ id = method, file = src }, { source = "invalid Java" })
  t.eq(invalid, nil, "scratch compilation errors yield no result")
  t.check(compilation_error and compilation_error:find("Scenario compilation failed", 1, true),
    "scratch compilation errors reach the caller")
  t.eq(#vim.fn.glob(live.store.path .. "/recordings/*.json", true, true), 1,
    "only the successful selected JUnit test is persisted as a recording")
  tour.stop()
  require("code-tour.instance").unregister()
  client:stop()
  vim.wait(3000, function() return client:is_stopped() end)
end)
