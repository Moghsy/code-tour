local M = {}

function M.command(provider)
  if provider == "claude" then
    return { "claude", "-p", "--output-format", "json", "--tools", "", "--no-session-persistence" }
  elseif provider == "codex" then
    return { "codex", "exec", "--sandbox", "read-only", "--ephemeral", "--skip-git-repo-check", "--json", "-" }
  end
  error("Unknown tour provider: " .. tostring(provider))
end

function M.decode(provider, output)
  if provider == "claude" then
    local data = vim.json.decode(output)
    if data.is_error then error(data.result or "Claude request failed") end
    assert(type(data.result) == "string" and data.result ~= "", "Claude returned no response")
    return data.result
  end
  local answer = {}
  for line in output:gmatch("[^\n]+") do
    local ok, event = pcall(vim.json.decode, line)
    if ok then
      if event.type == "turn.failed" or event.type == "error" then
        error(vim.inspect(event.error or event.message or event))
      end
      if event.type == "item.completed" and event.item and event.item.type == "agent_message" then
        answer[#answer + 1] = event.item.text
      end
    end
  end
  assert(#answer > 0, "Codex returned no response")
  return table.concat(answer, "\n\n")
end

function M.run(provider, prompt, root, timeout, callback)
  local cmd = M.command(provider)
  if vim.fn.executable(cmd[1]) ~= 1 then
    callback(false, cmd[1] .. " is not installed or is missing from PATH")
    return
  end
  return vim.system(cmd, { cwd = root, stdin = prompt, text = true, timeout = timeout }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local decoded, data = pcall(vim.json.decode, result.stdout or "")
        if decoded and type(data) == "table" and type(data.result) == "string" and data.result ~= "" then
          callback(false, data.result)
          return
        end
        callback(false, (result.stderr or "") .. "\n" .. (result.stdout or ""))
        return
      end
      local ok, answer = pcall(M.decode, provider, result.stdout)
      callback(ok, answer)
    end)
  end)
end

return M
