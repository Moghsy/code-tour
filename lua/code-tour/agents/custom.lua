-- Wrap a user-supplied `agent = { send = function(text, action, done) ... end }`.
local M = {}

function M.wrap(spec)
  return {
    deliver = function(origin, root, text, action, callback)
      local finished = false
      local function done(ok, err)
        if finished then return end
        finished = true
        vim.schedule(function() callback(ok ~= false, err) end)
      end
      local ok, err = pcall(spec.send, text, action, done, { origin = origin, root = root })
      if not ok then done(false, tostring(err)) end
    end,
  }
end

return M
