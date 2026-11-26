-- A request deadline. A busy editor cannot receive "stop" over RPC, so the work checks the
-- clock itself and gives up once the caller has.
local M = {}
local limit, seconds
local hooks = {}

-- `fn` runs once for every request that overruns, to drop half-built state.
function M.on_expire(fn)
  hooks[#hooks + 1] = fn
end

function M.expired()
  return limit ~= nil and vim.uv.hrtime() >= limit
end

function M.check()
  if M.expired() then
    error(("code-tour: the request took longer than %ds and was stopped"):format(seconds), 0)
  end
end

-- Milliseconds left (at least 1), or nil without a deadline: a timeout for subprocesses.
function M.remaining()
  if limit then
    return math.max(1, math.ceil((limit - vim.uv.hrtime()) / 1e6))
  end
end

-- The result is about to be committed (shown): finish the job rather than stop half way.
function M.finish()
  limit = nil
end

-- Run `fn` until `at` (hrtime), a part of an allowance of `secs` seconds.
function M.run_until(at, secs, fn, ...)
  local outer_limit, outer_seconds = limit, seconds
  limit, seconds = at, math.floor(secs)
  local result = { pcall(fn, ...) }
  local overran = M.expired()
  limit, seconds = outer_limit, outer_seconds
  if overran then
    for _, hook in ipairs(hooks) do
      hook()
    end
  end
  if not result[1] then
    error(result[2], 0)
  end
  return unpack(result, 2, table.maxn(result))
end

function M.run(secs, fn, ...)
  return M.run_until(vim.uv.hrtime() + secs * 1e9, secs, fn, ...)
end

return M
