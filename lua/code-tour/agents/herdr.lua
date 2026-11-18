-- Herdr backend: delivers prompts to the agent pane that authored the tour, and can start one.
local M = {}
local validate

local function request(origin, args, callback)
  local command = { vim.env.HERDR_BIN_PATH or "herdr", "--session", origin.session }
  vim.list_extend(command, args)
  return vim.system(
    command,
    { text = true, timeout = 10000 },
    vim.schedule_wrap(function(result)
      local ok, response = pcall(vim.json.decode, result.stdout or "")
      if result.code == 0 and args[1] == "pane" and args[2] == "send-text" and not (result.stdout or ""):find("%S") then
        callback({})
        return
      end
      if not ok then
        ok, response = pcall(vim.json.decode, result.stderr or "")
      end
      if result.code ~= 0 or not ok or type(response) ~= "table" or response.error then
        local err = ok and type(response) == "table" and response.error and response.error.message
        callback(nil, err or result.stderr or "Herdr request failed")
      else
        callback(response.result)
      end
    end)
  )
end

-- Start one agent in a single new Herdr tab (no split panes) when none is connected.
function M.connect(root, callback, kind)
  local session = vim.env.HERDR_SESSION
  if not session then
    callback(nil, "No agent is connected and Herdr is not available to start one.")
    return
  end
  kind = kind or "claude"
  local base = { session = session }
  request(base, { "tab", "create", "--cwd", root, "--label", "Code tour agent", "--no-focus" }, function(created, err)
    local pane = created and created.root_pane and created.root_pane.pane_id
    if not pane then
      callback(nil, err or "Could not create a Herdr tab for the agent")
      return
    end
    request(base, { "agent", "start", "code-tour", "--kind", kind, "--pane", pane }, function(started, start_err)
      if not started then
        callback(nil, start_err or "Could not start the agent")
        return
      end
      request(base, { "agent", "list" }, function(list, list_err)
        local agent
        for _, item in ipairs(list and list.agents or {}) do
          if item.pane_id == pane then
            agent = item
          end
        end
        if not agent then
          callback(nil, list_err or "The new agent was not detected")
          return
        end
        request(base, { "pane", "process-info", "--pane", pane }, function(info, info_err)
          local pids = {}
          for _, process in ipairs(info and (info.process_info or {}).foreground_processes or {}) do
            pids[#pids + 1] = process.pid
          end
          if #pids == 0 then
            callback(nil, info_err or "The new agent process is missing")
            return
          end
          callback({
            session = session,
            pane_id = pane,
            tab_id = agent.tab_id,
            agent = agent.agent,
            process_ids = pids,
            agent_session = (agent.agent_session or {}).value,
          })
        end)
      end)
    end)
  end)
end

-- Deliver to the connected agent, connecting a fresh one first when it is missing or gone.
function M.deliver(origin, root, text, action, callback, set_origin)
  local function connect()
    M.connect(root, function(new, err)
      if not new then
        callback(false, err)
        return
      end
      set_origin(new)
      M.send(new, text, action, callback)
    end)
  end
  if not origin then
    connect()
    return
  end
  validate(origin, function(ok, err, gone)
    if ok then
      M.send(origin, text, action, callback, true)
    elseif gone then
      connect()
    else
      callback(false, err)
    end
  end)
end

-- RPC tours return answers directly to a box, so no request/response files are needed.
function M.send(origin, text, action, callback, validated)
  if not origin then
    callback(false, "No originating conversation recorded; start the tour from Claude or Codex.")
    return
  end
  local function deliver(ok, err)
    if not ok then
      callback(false, err)
      return
    end
    local args = action == "add" and { "pane", "send-text", origin.pane_id, "\27[200~" .. text .. "\27[201~" }
      or { "agent", "prompt", origin.pane_id, text }
    request(origin, args, function(result, send_err)
      if not result then
        callback(false, send_err)
        return
      end
      if action == "follow" or action == "add" then
        request(origin, { "agent", "focus", origin.pane_id }, function(focused, focus_err)
          if focused then
            callback(true)
          else
            callback(true, "Prompt delivered; focus failed: " .. tostring(focus_err))
          end
        end)
      else
        callback(true)
      end
    end)
  end
  if validated then
    deliver(true)
  else
    validate(origin, deliver)
  end
end

validate = function(origin, callback)
  request(origin, { "agent", "list" }, function(result, err)
    if not result then
      callback(false, err)
      return
    end
    local live
    for _, agent in ipairs(result.agents or {}) do
      if agent.pane_id == origin.pane_id and agent.agent == origin.agent then
        live = agent
        break
      end
    end
    if not live or (origin.agent_session and (live.agent_session or {}).value ~= origin.agent_session) then
      callback(
        false,
        "The originating conversation has closed or changed. Start a new tour from the intended conversation.",
        true
      )
      return
    end
    if live.agent_status == "blocked" then
      callback(
        false,
        "The originating agent is waiting for input or approval. Resolve it in its Herdr tab, then ask again."
      )
      return
    end
    request(origin, { "pane", "process-info", "--pane", origin.pane_id }, function(info, process_err)
      if not info then
        callback(false, process_err)
        return
      end
      local same = false
      for _, process in ipairs((info.process_info or {}).foreground_processes or {}) do
        for _, pid in ipairs(origin.process_ids or {}) do
          if process.pid == pid then
            same = true
          end
        end
      end
      callback(
        same,
        same and nil or "The originating agent process changed. Start a new tour from that conversation.",
        not same
      )
    end)
  end)
end

return M
