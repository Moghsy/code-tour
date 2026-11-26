-- Long work run as a coroutine in short slices, so the editor stays usable meanwhile.
-- The work calls `point()` wherever it may be interrupted; `atomic()` marks a stretch that
-- leaves shared caches half filled and so must finish before anything else runs.
local M = {
  budget = 10e6, -- nanoseconds per slice
}
local current -- the coroutine being resumed
local slice_end, held = 0, 0

function M.point()
  if current and held == 0 and coroutine.running() == current and vim.uv.hrtime() >= slice_end then
    coroutine.yield()
  end
end

function M.atomic(fn, ...)
  held = held + 1
  local result = { pcall(fn, ...) }
  held = held - 1
  if not result[1] then
    error(result[2], 0)
  end
  return unpack(result, 2, table.maxn(result))
end

-- opts: { alive() -> false drops the work, done(ok, result, extra), around?(resume) wraps each slice }
function M.run(fn, opts)
  local co = coroutine.create(fn)
  local function resume()
    return { coroutine.resume(co) }
  end
  local function step()
    if not opts.alive() then
      return
    end
    local outer = current
    current, slice_end = co, vim.uv.hrtime() + M.budget
    local result = opts.around and opts.around(resume) or resume()
    current = outer
    if not result[1] then
      opts.done(false, result[2])
    elseif coroutine.status(co) == "dead" then
      opts.done(true, result[2], result[3])
    else
      vim.defer_fn(step, 5)
    end
  end
  vim.defer_fn(step, 5)
end

return M
