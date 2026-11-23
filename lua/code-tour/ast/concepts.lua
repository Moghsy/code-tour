-- Concepts: the semantic layer, written lazily by the agent. A concept names an idea
-- ("order totalling") and groups the symbols that implement it, with a short summary. It is
-- a hyperedge over the project graph: the plugin extracts nothing semantic by itself, and a
-- concept exists only when the agent records one while it explains code.
--
-- Each member keeps the fingerprint of its source at the time of writing, so a concept goes
-- stale member by member when the code changes, the way notes do (§11.3). Concepts live in
-- concepts.json beside the notes store and are read by `code-tour analyze concepts` and
-- `neighbors`.
local notes = require("code-tour.ast.notes")

local M = {}

local function fingerprint(idx, sym)
  local buf = vim.fn.bufadd(idx:abs(sym.file))
  if vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
    vim.cmd("silent checktime " .. buf) -- pick up an edit made on disk since the buffer loaded
  end
  vim.fn.bufload(buf)
  return notes.fingerprint(buf, sym.range, sym.name)
end

-- A symbol by id in a fresh index: load its type first, then fall back to a scan.
local function symbol_of(idx, id)
  local sym = idx:symbol(id)
  if sym then
    return sym
  end
  local qname = id:match("^%a+:([^#]+)")
  if qname then
    pcall(idx.type, idx, qname)
    sym = idx:symbol(id)
  end
  if not sym and not idx.scanned then
    idx:scan()
    sym = idx:symbol(id)
  end
  return sym
end

local function path_of(store)
  return store.path .. "/concepts.json"
end

local function read(store)
  local fd = io.open(path_of(store), "rb")
  if not fd then
    return { version = 1, concepts = {} }
  end
  local ok, data = pcall(vim.json.decode, fd:read("*a"), { luanil = { object = true, array = true } })
  fd:close()
  if ok and type(data) == "table" and type(data.concepts) == "table" then
    return data
  end
  return { version = 1, concepts = {} }
end

local function write(store, data)
  store:begin_write()
  vim.fn.mkdir(store.path, "p")
  local out = path_of(store)
  local tmp = out .. ".tmp" .. vim.uv.os_getpid()
  local fd = assert(io.open(tmp, "w"))
  fd:write(vim.json.encode(data), "\n")
  fd:close()
  assert(vim.uv.fs_rename(tmp, out))
end

local function slug(name)
  local id = name:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return id ~= "" and id or "concept"
end

-- Record or replace a concept. spec: { name, summary?, members = {symbol specs}, id? }.
function M.add(idx, store, spec)
  assert(type(spec.name) == "string" and spec.name:find("%S"), "A concept needs a name")
  assert(type(spec.members) == "table" and #spec.members > 0, "A concept needs members (symbol specs)")
  local route = require("code-tour.ast.route").new(idx)
  local members, fingerprints, seen = {}, {}, {}
  for _, member in ipairs(spec.members) do
    local ids, err = route:resolve_entry(member)
    if not ids then
      error(("member %s: %s"):format(member, err), 0)
    end
    for _, id in ipairs(ids) do
      local sym = idx:symbol(id)
      if sym and sym.range and not seen[id] then
        seen[id] = true
        members[#members + 1] = id
        fingerprints[id] = fingerprint(idx, sym)
      end
    end
  end
  assert(#members > 0, "No member resolved to a symbol with source")
  local data = read(store)
  local id = spec.id or slug(spec.name)
  local previous = data.concepts[id]
  data.concepts[id] = { id = id, name = spec.name, summary = spec.summary, members = members,
    fingerprints = fingerprints, origin = "agent", created = previous and previous.created or os.time(),
    updated = os.time() }
  write(store, data)
  return { id = id, members = #members, replaced = previous ~= nil }
end

function M.remove(store, id)
  local data = read(store)
  local found = data.concepts[id] ~= nil
  data.concepts[id] = nil
  if found then
    write(store, data)
  end
  return { id = id, removed = found }
end

-- Every concept with the freshness of each member: fresh, stale (the code changed) or missing.
function M.list(idx, store)
  local data = read(store)
  local ids = vim.tbl_keys(data.concepts)
  table.sort(ids)
  local out = {}
  for _, id in ipairs(ids) do
    local concept = data.concepts[id]
    local members, stale = {}, 0
    for _, member in ipairs(concept.members) do
      local sym = symbol_of(idx, member)
      local status = "missing"
      if sym and sym.range then
        status = fingerprint(idx, sym) == concept.fingerprints[member] and "fresh" or "stale"
      end
      if status ~= "fresh" then
        stale = stale + 1
      end
      members[#members + 1] = { symbol = member, status = status }
    end
    out[#out + 1] = { id = id, name = concept.name, summary = concept.summary, members = members,
      stale = stale > 0 or nil, updated = concept.updated }
  end
  return out
end

-- The concepts a symbol belongs to (ids and names).
function M.of(idx, store, symbol)
  local out = {}
  for _, concept in ipairs(M.list(idx, store)) do
    for _, member in ipairs(concept.members) do
      if member.symbol == symbol then
        out[#out + 1] = { id = concept.id, name = concept.name, stale = concept.stale }
        break
      end
    end
  end
  return out
end

return M
