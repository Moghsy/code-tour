-- A toy work-item fixer written as a state machine. Used by examples/fixer/tour.json.
local M = {}

M.machine = {
  start = "claim",
  catch = { Drained = "drained", ItemFailed = "errored" },
  abort = "released",
}

-- claim: take the item and mark it as being fixed.
function M.claim(item)
  item.status = "fixing"
  return "fix"
end

-- fix: try a change, check it, then commit it or try again (at most ten times).
function M.fix(item)
  item.tries = (item.tries or 0) + 1
  local change = agent("fix", item)
  local ok = check(change)
  if ok then
    return "commit"
  end
  if item.tries < 10 then
    return "fix"
  end
  return "gave-up"
end

-- commit: record the change on the item.
function M.commit(item)
  item.status = "fixed"
  return "done"
end

-- gave-up: stop after too many failed tries.
function M.gave_up(item)
  item.status = "out of tries"
  return nil
end

return M
