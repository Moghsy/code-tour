-- Match the multiline composer used by config.herdr-ai (<leader>ac).
local M = {}
local popup
local draft = ""

function M.close(save)
  if not popup then return end
  local current = popup
  popup = nil
  if save ~= false and vim.api.nvim_buf_is_valid(current.buf) then
    draft = table.concat(vim.api.nvim_buf_get_lines(current.buf, 0, -1, false), "\n")
  end
  if vim.api.nvim_win_is_valid(current.win) then vim.api.nvim_win_close(current.win, true) end
  if current.origin and vim.api.nvim_win_is_valid(current.origin) then vim.api.nvim_set_current_win(current.origin) end
end

function M.open(config)
  if popup and vim.api.nvim_win_is_valid(popup.win) then
    vim.api.nvim_set_current_win(popup.win)
    return
  end
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(draft, "\n", { plain = true }))
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  local width = math.max(1, math.min(100, vim.o.columns - 4))
  local height = math.max(1, math.min(20, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", style = "minimal", border = "rounded",
    width = width, height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    title = " " .. config.title .. " ", title_pos = "center",
    footer = " ^S ask · ^B save draft · ^F ask + focus · Esc normal · q close ", footer_pos = "center",
  })
  vim.wo[win].wrap = true
  popup = { buf = buf, win = win, origin = origin }
  local function submit(focus)
    if not popup then return end
    local question = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    if not question:find("%S") then
      vim.notify("Enter a question first.", vim.log.levels.WARN, { title = "Code walkthrough" })
      return
    end
    vim.cmd("stopinsert")
    M.close(false)
    draft = ""
    config.submit(question, focus)
  end
  for key, callback in pairs({
    ["<C-s>"] = function() submit(false) end,
    ["<C-f>"] = function() submit(true) end,
    ["<C-b>"] = function() vim.cmd("stopinsert"); M.close(true) end,
  }) do
    vim.keymap.set({ "i", "n" }, key, callback, { buffer = buf, desc = "Walkthrough question" })
  end
  vim.keymap.set("n", "q", function() M.close(true) end, { buffer = buf, desc = "Close walkthrough question" })
  vim.cmd("startinsert")
end

function M.clear()
  M.close(false)
  draft = ""
end

function M.state() return popup end
return M
