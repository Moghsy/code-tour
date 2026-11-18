-- The state-machine layer of a tour (see SPEC-state-machine.md). A machine is authored data
-- that names stops and parts of the tour by `id`: a state is a top-level stop, a step is a
-- part of that stop. Nothing here runs a program; it validates the data and derives edges.
local stops = require("code-tour.stops")
local M = {}

local ID = "^[%w][%w._-]*$"
local KINDS = { computer = true, agent = true }

local function fail(where, message)
  error(("machine %s: %s"):format(where, message), 0)
end

local function text(value, where, what)
  if type(value) ~= "string" or not value:find("%S") then
    fail(where, what .. " must be text")
  end
  return value
end

-- id -> { stop = stop, box = box } for every stop and part that has an `id`.
function M.index(list)
  local index = {}
  for _, stop in ipairs(list) do
    for _, box in ipairs(stops.boxes(stop)) do
      if box.id ~= nil then
        assert(type(box.id) == "string" and box.id:match(ID), "id must match [A-Za-z0-9][A-Za-z0-9._-]*: " .. tostring(box.id))
        assert(not index[box.id], "Duplicate id: " .. box.id)
        index[box.id] = { stop = stop, box = box }
      end
    end
  end
  return index
end

local function copy_list(value, where, what)
  if value == nil then return {} end
  if type(value) ~= "table" or not vim.islist(value) then fail(where, what .. " must be a list") end
  return value
end

-- Validates `input` against the normalized stops and returns the machine in canonical form:
-- { path, start, catch, on_abort, states, by_id, order }. Every problem names its entry.
function M.normalize(input, list)
  if type(input) ~= "table" or vim.islist(input) then
    fail("machine", "must be an object")
  end
  local index = M.index(list)
  local states, by_id, order = {}, {}, {}
  local raw_states = copy_list(input.states, "machine", "states")
  if #raw_states == 0 then fail("machine", "needs at least one state") end
  -- First pass: identities, so any state can name any other.
  for i, raw in ipairs(raw_states) do
    if type(raw) ~= "table" then fail("states[" .. i .. "]", "must be an object") end
    local id = raw.id
    if type(id) ~= "string" or not id:match(ID) then fail("states[" .. i .. "]", "needs an id like 'fix'") end
    if by_id[id] then fail("state '" .. id .. "'", "duplicate state id") end
    local state = { id = id, steps = {}, exit = raw.exit == true, ["end"] = raw["end"], only_on_catch = raw.only_on_catch }
    by_id[id], order[id] = state, i
    states[i] = state
  end
  local function state_ref(id, where, what)
    if type(id) ~= "string" or not by_id[id] then
      fail(where, what .. " names an unknown state: " .. tostring(id))
    end
    return id
  end
  local function exit_ref(id, where)
    state_ref(id, where, "exit")
    if not by_id[id].exit then fail(where, "exit '" .. id .. "' must be a state with exit = true") end
    return id
  end
  for i, raw in ipairs(raw_states) do
    local state = states[i]
    local where = "state '" .. state.id .. "'"
    for key in pairs(raw) do
      if not ({ id = 1, steps = 1, next = 1, on = 1, exit = 1, ["end"] = 1, only_on_catch = 1 })[key] then
        fail(where, "unknown field '" .. tostring(key) .. "'")
      end
    end
    assert(raw.exit == nil or type(raw.exit) == "boolean", where .. ": exit must be a boolean")
    if state["end"] ~= nil then
      text(state["end"], where, "end")
      if not state.exit then fail(where, "end needs exit = true") end
    end
    -- The state's stop: the stop whose id is the state's id, which must be top-level.
    local hit = index[state.id]
    if hit then
      if hit.box ~= hit.stop then fail(where, "'" .. state.id .. "' is a part, not a stop") end
      if hit.stop._parent_stop then fail(where, "its stop must be top-level, not a call") end
      state.stop = state.id
    end
    local seen = {}
    for k, step in ipairs(copy_list(raw.steps, where, "steps")) do
      local at = where .. " step " .. k
      if type(step) ~= "table" then fail(at, "must be an object") end
      for key in pairs(step) do
        if not ({ part = 1, name = 1, kind = 1, model = 1, effort = 1, prompt = 1, status = 1, feedback = 1 })[key] then
          fail(at, "unknown field '" .. tostring(key) .. "'")
        end
      end
      if not KINDS[step.kind] then fail(at, "kind must be 'computer' or 'agent'") end
      local entry = { kind = step.kind, status = step.status, feedback = step.feedback == true }
      if step.status ~= nil then text(step.status, at, "status") end
      if step.feedback ~= nil and type(step.feedback) ~= "boolean" then fail(at, "feedback must be a boolean") end
      if step.kind == "agent" then
        for _, key in ipairs({ "model", "effort" }) do
          if step[key] ~= nil then entry[key] = text(step[key], at, key) end
        end
      elseif step.model or step.effort or step.prompt then
        fail(at, "model, effort and prompt belong to agent steps")
      end
      if step.part ~= nil then
        local part = index[step.part]
        if not part then fail(at, "part '" .. tostring(step.part) .. "' is not an id in this tour") end
        if not state.stop or part.stop ~= index[state.stop].stop or part.box == part.stop then
          fail(at, "part '" .. step.part .. "' is not a part of the stop '" .. state.id .. "'")
        end
        if seen[step.part] then fail(at, "part '" .. step.part .. "' is used twice") end
        seen[step.part] = true
        entry.part = step.part
      elseif state.stop then
        fail(at, "needs a part of the stop '" .. state.id .. "'")
      end
      entry.name = step.name and text(step.name, at, "name") or (entry.part and entry.part:match("([^.]+)$")) or ("step" .. k)
      if step.prompt ~= nil then
        if not index[step.prompt] then fail(at, "prompt '" .. tostring(step.prompt) .. "' is not an id in this tour") end
        entry.prompt = step.prompt
      end
      state.steps[#state.steps + 1] = entry
    end
    local routes = (raw.next ~= nil and 1 or 0) + (raw.on ~= nil and 1 or 0) + (state.exit and 1 or 0)
    if routes > 1 then fail(where, "use only one of next, on and exit") end
    if raw.next ~= nil then state.next = state_ref(raw.next, where, "next") end
    if raw.on ~= nil then
      local on = raw.on
      if type(on) ~= "table" then fail(where, "on must be an object") end
      state.on = { name = text(on.name, where, "on.name"), outcomes = {} }
      local ids, happy = {}, false
      local outcomes = copy_list(on.outcomes, where, "on.outcomes")
      if #outcomes == 0 then fail(where, "on needs outcomes") end
      for n, outcome in ipairs(outcomes) do
        local oid = type(outcome) == "table" and outcome.id
        local at = where .. " outcome " .. tostring(oid or n)
        if type(oid) ~= "string" or not oid:match(ID) then fail(where .. " outcome " .. n, "needs an id") end
        if ids[oid] then fail(at, "duplicate outcome id") end
        ids[oid] = true
        for key in pairs(outcome) do
          if not ({ id = 1, to = 1, exit = 1, when = 1, otherwise = 1, happy = 1 })[key] then
            fail(at, "unknown field '" .. tostring(key) .. "'")
          end
        end
        local item = { id = oid, happy = outcome.happy == true }
        if outcome.happy ~= nil and type(outcome.happy) ~= "boolean" then fail(at, "happy must be a boolean") end
        local ways = (outcome.to ~= nil and 1 or 0) + (outcome.exit ~= nil and 1 or 0) + (outcome.when ~= nil and 1 or 0)
        if ways ~= 1 then fail(at, "needs exactly one of to, exit or when") end
        if outcome.to ~= nil then item.to = state_ref(outcome.to, at, "to") end
        if outcome.exit ~= nil then item.exit = exit_ref(outcome.exit, at) end
        if outcome.when ~= nil then
          if item.happy then fail(at, "a guarded outcome cannot be happy") end
          item.when = {}
          for g, guard in ipairs(copy_list(outcome.when, at, "when")) do
            local gat = at .. " guard " .. g
            if type(guard) ~= "table" then fail(gat, "must be an object") end
            if type(guard.below) ~= "number" or guard.below < 1 or guard.below % 1 ~= 0 then
              fail(gat, "below must be a positive integer")
            end
            item.when[g] = { visits = state_ref(guard.visits, gat, "visits"), below = guard.below, to = state_ref(guard.to, gat, "to") }
          end
          if #item.when == 0 then fail(at, "when needs at least one guard") end
          local otherwise = outcome.otherwise
          if type(otherwise) ~= "table" or ((otherwise.to ~= nil) == (otherwise.exit ~= nil)) then
            fail(at, "a guarded outcome needs otherwise = {to=...} or {exit=...}")
          end
          item.otherwise = otherwise.to and { to = state_ref(otherwise.to, at, "otherwise") }
            or { exit = exit_ref(otherwise.exit, at) }
        elseif outcome.otherwise ~= nil then
          fail(at, "otherwise needs when")
        end
        if item.happy then
          if happy then fail(where, "two outcomes are marked happy") end
          happy = true
        end
        state.on.outcomes[n] = item
      end
    end
    if state.only_on_catch ~= nil then
      for _, name in ipairs(copy_list(state.only_on_catch, where, "only_on_catch")) do
        text(name, where, "only_on_catch entries")
      end
    end
  end
  local machine = { states = states, by_id = by_id, order = order, catch = {}, path = {} }
  for i, name in ipairs(copy_list(input.path, "machine", "path")) do
    machine.path[i] = text(name, "machine path", "each entry")
  end
  machine.start = state_ref(input.start, "machine", "start")
  local errors = {}
  for i, item in ipairs(copy_list(input.catch, "machine", "catch")) do
    local at = "catch " .. i
    if type(item) ~= "table" then fail(at, "must be an object") end
    errors[text(item.error, at, "error")] = true
    machine.catch[i] = { error = item.error, to = state_ref(item.to, at, "to") }
  end
  if input.on_abort ~= nil then machine.on_abort = state_ref(input.on_abort, "machine", "on_abort") end
  for _, state in ipairs(states) do
    for _, name in ipairs(state.only_on_catch or {}) do
      if not errors[name] then fail("state '" .. state.id .. "'", "only_on_catch '" .. name .. "' is not a catch error") end
    end
  end
  return machine
end

-- A state's outgoing transitions in reading order, for the view and the graph.
-- { to?, exit?, label, kind = "next"|"outcome"|"guard"|"otherwise", happy, loop, guard? }
function M.edges(machine, state)
  local out = {}
  local function add(edge)
    local target = edge.to or edge.exit
    edge.target = target
    edge.loop = edge.to ~= nil and machine.order[target] <= machine.order[state.id]
    out[#out + 1] = edge
  end
  if state.next then add({ to = state.next, label = state.next, kind = "next", happy = true }) end
  for _, outcome in ipairs(state.on and state.on.outcomes or {}) do
    if outcome.when then
      for _, guard in ipairs(outcome.when) do
        add({ to = guard.to, label = outcome.id, kind = "guard", outcome = outcome.id,
          guard = ("%s visits < %d"):format(guard.visits, guard.below) })
      end
      add(vim.tbl_extend("force", { label = outcome.id, kind = "otherwise", outcome = outcome.id }, outcome.otherwise))
    else
      add({ to = outcome.to, exit = outcome.exit, label = outcome.id, kind = "outcome", outcome = outcome.id, happy = outcome.happy })
    end
  end
  return out
end

return M
