-- Let Snacks own source scrolling, including duration, folds and repeated motions.
local M = {}
local job

function M.active()
  return job ~= nil
end
function M.cancel()
  job = nil
end
function M.finish()
  local current = job
  job = nil
  if current and current.done then
    current.done()
  end
end

function M.move(win, jump, done, animate)
  M.cancel()
  local snacks = rawget(_G, "Snacks")
  local native = animate ~= false and snacks and snacks.scroll and snacks.scroll.enabled
  if native then
    snacks.scroll.check(win)
  end
  jump()
  if not native then
    if done then
      done()
    end
    return
  end
  local target = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  snacks.scroll.check(win)
  local current = { win = win, done = done, started = vim.uv.hrtime() }
  job = current
  local function settled()
    if job ~= current then
      return
    end
    if not vim.api.nvim_win_is_valid(win) then
      M.cancel()
      return
    end
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    if
      (view.topline == target.topline and view.topfill == target.topfill)
      or (vim.uv.hrtime() - current.started) / 1e6 > 2000
    then
      job = nil
      if done then
        done()
      end
    else
      vim.defer_fn(settled, 16)
    end
  end
  vim.defer_fn(settled, 16)
end

return M
