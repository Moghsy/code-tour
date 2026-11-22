-- Note presentation and fingerprints (§3.5). The in-memory implementation is useful
-- for isolated callers that supply their own store.
--
--   local store = notes.new()
--   store:put(address, { fingerprint, file, gist, body?, detail, model? })
--   store:lookup(address, fingerprint, detail) -> found | nil, reason
--     found  = { gist, body?, level?, exact }   body nil: gist only (§11.2 row 3)
--     reason = "missing" | "stale"
--   store:status(address, fingerprint, detail) -> "fresh" | "near" | "gist" | "missing" | "stale"
--   store:thread(address, fingerprint) -> the box's Q&A list (one table per version)
--   store:put_edge(caller, target, occurrence, { text, caller_fingerprint, target_fingerprint })
--   store:edge(caller, target, occurrence, caller_fingerprint, target_fingerprint) -> text | nil
local M = {}

M.levels = { "overview", "normal", "detailed", "exhaustive" }
local rank = {}
for i, level in ipairs(M.levels) do
  rank[level] = i
end
M.rank = rank

-- The `ts-scoped-leaves-v1` digest of a byte range (§3.2), or a digest of its text when
-- the buffer has no parser. buf must be loaded.
function M.fingerprint(buf, range, declaration_name)
  local source = require("code-tour.source")
  local fp = source.ast_digest(buf, range, declaration_name)
  if fp then
    return fp
  end
  local ok, text = pcall(vim.api.nvim_buf_get_text, buf, range.start[1], range.start[2], range["end"][1],
    range["end"][2], {})
  return "text:" .. vim.fn.sha256(ok and table.concat(text, "\n") or "")
end

local Store = {}
Store.__index = Store

function M.new()
  return setmetatable({ notes = {}, threads = {}, edges = {}, recipes_by_id = {} }, Store)
end

-- A later put for the same fingerprint replaces the gist and that level's body, and
-- keeps the other levels (§3.5: levels never replace each other). A put for another
-- fingerprint starts a new version: the old bodies described older code.
function Store:put(address, note)
  local cur = self.notes[address]
  if not cur or cur.fingerprint ~= note.fingerprint then
    cur = { region = address, file = note.file, fingerprint = note.fingerprint, bodies = {} }
    self.notes[address] = cur
  end
  return M.write_version(cur, note)
end

function M.write_version(cur, note)
  local address = cur.region
  assert(type(address) == "string" and address ~= "", "note needs a region address")
  assert(type(note.fingerprint) == "string", "note needs a fingerprint")
  assert(rank[note.detail], "note needs a detail level")
  assert(type(note.gist) == "string" and note.gist:find("%S"), "note needs a gist")
  cur.gist = note.gist
  cur.file = note.file or cur.file
  cur.symbol = note.symbol or cur.symbol
  cur.example = note.example or cur.example
  if note.body and note.body:find("%S") then
    cur.bodies[note.detail] = { text = note.body, model = note.model, written_at = os.time(), commit = note.commit,
      source = note.source }
  else
    cur.bodies[note.detail] = nil
  end
  -- a gist written at this level with no body still counts as written here
  cur.written = cur.written or {}
  cur.written[note.detail] = true
  return cur
end

function Store:lookup(address, fingerprint, detail)
  local cur = self.notes[address]
  if not cur then
    return nil, "missing"
  end
  if cur.fingerprint ~= fingerprint then
    return nil, "stale", "code changed"
  end
  return M.present(cur, detail)
end

function M.present(cur, detail)
  local want = rank[detail]
  if cur.bodies[detail] or (cur.written and cur.written[detail]) then
    local body = cur.bodies[detail]
    return { gist = cur.gist, body = body and body.text, model = body and body.model, level = detail, exact = true,
      note = cur }
  end
  -- one level away is shown, marked with its level, while this level is written (§11.2)
  local near
  for level in pairs(cur.bodies) do
    if math.abs(rank[level] - want) == 1 and (not near or rank[level] < rank[near]) then
      near = level
    end
  end
  if near then
    return { gist = cur.gist, body = cur.bodies[near].text, model = cur.bodies[near].model, level = near,
      exact = false, note = cur }
  end
  return { gist = cur.gist, exact = false, note = cur }
end

function Store:status(address, fingerprint, detail)
  local found, reason, stale_reason = self:lookup(address, fingerprint, detail)
  if not found then
    return reason, stale_reason
  end
  if found.exact then
    return "fresh"
  end
  return found.body and "near" or "gist"
end

function Store:previous(address)
  return self.notes[address]
end

-- Q&A threads belong to the region's note, independent of level (§3.5); a thread asked
-- against older code is kept and comes back when the code returns to that fingerprint.
function Store:thread(address, fingerprint)
  local key = address .. "\0" .. fingerprint
  self.threads[key] = self.threads[key] or {}
  return self.threads[key]
end

function M.upsert_turn(list, turn)
  for i, existing in ipairs(list) do
    if existing == turn or (turn.id and existing.id == turn.id) then
      list[i] = vim.deepcopy(turn)
      return
    end
  end
  list[#list + 1] = vim.deepcopy(turn)
end

function Store:save_turn(address, fingerprint, turn)
  M.upsert_turn(self:thread(address, fingerprint), turn)
end

function Store:remember(recipe)
  self.recipes_by_id[recipe.id] = vim.deepcopy(recipe)
end

local function edge_key(caller, target, occurrence)
  return caller .. "\0" .. target .. "\0" .. tostring(occurrence or 1)
end

function Store:put_edge(caller, target, occurrence, edge)
  self.edges[edge_key(caller, target, occurrence)] = vim.deepcopy(edge)
end

function Store:edge(caller, target, occurrence, caller_fp, target_fp)
  local e = self.edges[edge_key(caller, target, occurrence)]
  if e and type(target_fp) == "function" then
    target_fp = target_fp()
  end
  if e and e.caller_fingerprint == caller_fp and e.target_fingerprint == target_fp then
    return e.text
  end
end

return M
