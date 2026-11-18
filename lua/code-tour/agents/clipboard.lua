-- Fallback backend: no agent channel. The prompt is copied so the reader can paste it
-- into whichever agent authored the tour; its reply still arrives through the CLI.
local M = {}

function M.deliver(_, _, text, _, callback)
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
  callback(true, "Prompt copied to the clipboard; paste it into your agent to continue")
end

return M
