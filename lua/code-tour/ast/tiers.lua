-- Mechanical writing tiers (§9.7).
local M = {}
M.order = { "light", "standard", "deep" }

local function complicated(stmts, in_catch)
  for _, stmt in ipairs(stmts) do
    if stmt.kind == "synchronized_statement" or (in_catch and stmt.kind == "throw_statement") then
      return true
    end
    for _, arm in ipairs(stmt.arms or {}) do
      if arm.name == "finally" or complicated(arm.stmts, in_catch or arm.name == "catch") then
        return true
      end
    end
  end
  return false
end

local uncertain = { dispatch = true, ["name-only"] = true, agent = true }

function M.classify(rt, node, sites)
  local body, sym = node.body, node.sym
  if not body then return "light" end
  local metrics = body.metrics
  if rt:score(node.symbol) >= 12 or (metrics.field_writes > 0 and metrics.branches > 0)
      or (sym.modifiers or {}).synchronized or complicated(body.stmts) then
    return "deep"
  end
  for _, site in ipairs(sites) do
    if site.mode == "walk" and uncertain[site.via] then return "deep" end
  end
  for _, site in ipairs(body.sites) do
    local receiver = (site.receiver_type or ""):match("[^.]+$")
    if receiver and (receiver == "Thread" or receiver == "Executors" or receiver:match("Executor")
        or receiver:match("ThreadPool")) then
      return "deep"
    end
  end
  local owner = sym.owner and rt.idx:symbol(sym.owner)
  for _, write in ipairs(body.field_writes) do
    if owner and owner.fields and (write.object == "this" or write.object == owner.name) then
      local field = rt.idx:symbol(owner.fields[write.name])
      if field and field.volatile then return "deep" end
    end
  end
  if metrics.statements <= 5 and metrics.branches == 0 and metrics.project_sites <= 1 then return "light" end
  return "standard"
end

function M.writer(sn, previous)
  local models = require("code-tour.ast").options.models
  local desired = 1
  for i, tier in ipairs(M.order) do
    if tier == sn.tier then desired = math.max(desired, i) end
    if previous and models[tier] == previous then desired = math.max(desired, math.min(i + 1, #M.order)) end
  end
  local tier = M.order[desired]
  return tier, models[tier]
end

function M.header(models, ctx)
  local parts = {}
  for _, tier in ipairs(M.order) do
    if models and models[tier] then parts[#parts + 1] = tier .. "=" .. models[tier] end
  end
  if #parts == 0 then return end
  local line = "models: " .. table.concat(parts, " ")
  if ctx then
    line = line .. " · brief: " .. vim.fn.shellescape(ctx.cli) .. " brief <n> --pane "
      .. vim.fn.shellescape(ctx.servername) .. " --tour " .. ctx.token
  end
  return line
end

return M
