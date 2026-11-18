local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
local conversation = require("code-tour.agents.herdr")
local original = vim.system
local origin = {
  session = "session",
  pane_id = "pane",
  tab_id = "tab",
  agent = "codex",
  agent_session = "thread",
  process_ids = { 10 },
}
local calls, blocked, changed, focus_fail = {}, false, false, false
vim.system = function(argv, _, callback)
  calls[#calls + 1] = argv
  local result, output = {}, nil
  if argv[4] == "agent" and argv[5] == "list" then
    result = {
      agents = {
        {
          pane_id = "pane",
          agent = "codex",
          agent_session = { value = changed and "other" or "thread" },
          agent_status = blocked and "blocked" or "idle",
        },
      },
    }
  elseif argv[4] == "pane" and argv[5] == "process-info" then
    result = { process_info = { foreground_processes = { { pid = 10 } } } }
  elseif argv[4] == "pane" and argv[5] == "send-text" then
    output = ""
  elseif focus_fail and argv[5] == "focus" then
    callback({ code = 1, stdout = "", stderr = "focus failed" })
    return {}
  end
  callback({ code = 0, stdout = output or vim.json.encode({ result = result }), stderr = "" })
  return {}
end
local function send(action)
  local result
  conversation.send(origin, "Box prompt\nSecond line", action, function(ok, err)
    result = { ok = ok, err = err }
  end)
  assert(
    vim.wait(1000, function()
      return result ~= nil
    end, 5),
    "Transport did not complete"
  )
  return result
end
local function test()
  assert(send("stay").ok)
  assert(calls[#calls][5] == "prompt" and calls[#calls][7] == "Box prompt\nSecond line")
  assert(send("follow").ok and calls[#calls][5] == "focus")
  local count = #calls
  assert(send("add").ok)
  assert(calls[count + 3][4] == "pane" and calls[count + 3][5] == "send-text")
  assert(calls[count + 3][7] == "\27[200~Box prompt\nSecond line\27[201~", "Add must paste without submitting")
  blocked = true
  count = #calls
  assert(not send("stay").ok and #calls == count + 1, "Blocked agent must not receive input")
  blocked, changed = false, true
  count = #calls
  assert(not send("stay").ok and #calls == count + 1, "Replaced conversation must not receive input")
  changed, focus_fail = false, true
  local result = send("follow")
  assert(result.ok and result.err:find("Prompt delivered", 1, true), "Focus failure must not resend a delivered prompt")
  print("PASS: stay, follow, draft paste, blocked/changed origin, focus failure")
end
local ok, err = xpcall(test, debug.traceback)
vim.system = original
if ok then
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
