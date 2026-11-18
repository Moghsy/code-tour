-- Route prompts from the editor to the agent that authored the tour. The channel is
-- pluggable: `agent` in setup() is "auto", "herdr", "clipboard", or `{ send = fn }`.
local M = {}

local function backend(choice)
  if type(choice) == "table" and type(choice.send) == "function" then
    return require("code-tour.agents.custom").wrap(choice)
  end
  if choice == nil or choice == "auto" then
    choice = vim.env.HERDR_SESSION and "herdr" or "clipboard"
  end
  assert(choice == "herdr" or choice == "clipboard",
    'code-tour agent must be "auto", "herdr", "clipboard" or { send = function(text, action, done) end }')
  return require("code-tour.agents." .. choice)
end

-- Deliver to the agent. An authoring origin recorded by the CLI means Herdr, so an
-- origin always takes the Herdr route in "auto" mode.
function M.deliver(origin, root, text, action, callback, set_origin, choice)
  local selected = (choice == nil or choice == "auto") and origin and "herdr" or choice
  return backend(selected).deliver(origin, root, text, action, callback, set_origin)
end

return M
