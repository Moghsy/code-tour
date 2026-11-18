-- Versioned local records. This is the only library writer.
local M = {}
local uv = vim.uv
local function fail(message)
  error(message, 0)
end
local function check(value, message)
  if not value then
    fail(message)
  end
end
local function text(v)
  return type(v) == "string" and v:find("%S") ~= nil
end
local function hex(v, n)
  return type(v) == "string" and #v == n and v:match("^[0-9a-f]+$") ~= nil
end
function M.id()
  return vim.fn.sha256(tostring(uv.hrtime()) .. vim.fn.getpid() .. tostring({})):sub(1, 32)
end
function M.directory()
  return vim.fs.normalize(vim.fn.stdpath("data") .. "/code-tour/tours")
end
function M.check_directory(path)
  check(
    not path or vim.fs.normalize(path) == M.directory(),
    "Library profile/path mismatch: editor uses " .. M.directory()
  )
end
function M.timestamp(value)
  if type(value) ~= "string" then
    return false
  end
  local y, m, d, h, n, s = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not y then
    return false
  end
  y, m, d, h, n, s = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(n), tonumber(s)
  local days =
    { 31, (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  return y > 0 and days[m] ~= nil and d >= 1 and d <= days[m] and h < 24 and n < 60 and s < 60
end
local function fields(value, allowed, label)
  check(type(value) == "table", label .. " must be an object")
  for k in pairs(value) do
    check(allowed[k], "Unsupported " .. label .. " field: " .. tostring(k))
  end
end
local function keys(s)
  local out = {}
  for k in s:gmatch("%S+") do
    out[k] = true
  end
  return out
end
local function list(v, label)
  check(type(v) == "table" and vim.islist(v), label .. " must be an ordered list")
end
function M.relative(path)
  return text(path)
    and path:sub(1, 1) ~= "/"
    and not path:find("%z")
    and not path:find("\\")
    and not ("/" .. path .. "/"):find("/%.%./")
    and vim.fs.normalize(path) == path
    and path ~= "."
end
local function range(r)
  fields(r, keys("start end"), "range")
  for _, p in ipairs({ r.start, r["end"] }) do
    list(p, "position")
    check(#p == 2, "Position requires row and byte column")
    for _, n in ipairs(p) do
      check(type(n) == "number" and n >= 0 and n == math.floor(n), "Invalid byte position")
    end
  end
  check(
    r.start and r["end"] and (r.start[1] < r["end"][1] or (r.start[1] == r["end"][1] and r.start[2] < r["end"][2])),
    "Empty or reversed range"
  )
end
local function locator(v)
  fields(
    v,
    keys(
      "file_digest range owners scope_path whole_owner leaf_count target_digest before after leading_comments boundary"
    ),
    "locator"
  )
  check(hex(v.file_digest, 64), "Invalid file digest")
  range(v.range)
  list(v.owners, "owners")
  list(v.scope_path, "scope_path")
  for _, owner in ipairs(v.owners) do
    fields(owner, keys("type name"), "owner")
    check(text(owner.type) and text(owner.name), "Invalid owner")
  end
  for _, entry in ipairs(v.scope_path) do
    list(entry, "scope path component")
    check(#entry == 2 and text(entry[1]) and type(entry[2]) == "string", "Invalid structural path")
  end
  check(type(v.whole_owner) == "boolean", "Invalid whole_owner")
  check(
    type(v.leaf_count) == "number" and v.leaf_count >= 0 and v.leaf_count == math.floor(v.leaf_count),
    "Invalid leaf count"
  )
  check(v.target_digest == nil or hex(v.target_digest, 64), "Invalid target digest")
  check(v.leaf_count == 0 or hex(v.target_digest, 64), "Missing target digest")
  if v.boundary then
    list(v.boundary, "boundary signatures")
    check(#v.boundary == 2 and hex(v.boundary[1], 64) and hex(v.boundary[2], 64), "Invalid boundary signatures")
  end
  if v.leading_comments ~= nil then
    check(
      type(v.leading_comments) == "number"
        and v.leading_comments >= 0
        and v.leading_comments == math.floor(v.leading_comments),
      "Invalid leading comments"
    )
  end
  for _, side in ipairs({ v.before, v.after }) do
    list(side, "anchors")
    check(#side <= 4, "Too many anchors")
    for _, sig in ipairs(side) do
      check(hex(sig, 64), "Invalid anchor")
    end
  end
  check(v.before and v.after, "Missing anchors")
end
local function evidence(v)
  fields(v, keys("status reason scheme language parser_tag digest"), "evidence")
  if v.status == "unverified" then
    check(text(v.reason), "Unverified evidence needs a reason")
  else
    check(v.status == "verified", "Invalid evidence status")
    check(
      text(v.scheme) and text(v.language) and text(v.parser_tag) and hex(v.digest, 64),
      "Incomplete verified evidence"
    )
  end
end
function M.validate(record)
  fields(record, keys("kind version id title created_at saved_at repositories stops"), "record")
  check(record.kind == "code-tour.saved", "Not a saved code tour")
  check(record.version == 1, "Unsupported saved tour version: " .. tostring(record.version))
  check(hex(record.id, 32), "Invalid tour ID")
  check(text(record.title), "Missing title")
  check(
    M.timestamp(record.created_at) and M.timestamp(record.saved_at) and record.created_at <= record.saved_at,
    "Invalid UTC save timestamps"
  )
  list(record.repositories, "repositories")
  list(record.stops, "stops")
  check(#record.stops > 0 and #record.repositories > 0, "Empty saved tour")
  local repos, ids, count = {}, {}, 0
  for _, repo in ipairs(record.repositories) do
    fields(repo, keys("id label root"), "repository")
    check(
      text(repo.id)
        and text(repo.label)
        and text(repo.root)
        and repo.root:sub(1, 1) == "/"
        and vim.fs.normalize(repo.root) == repo.root
        and not repo.root:find("%z"),
      "Invalid repository"
    )
    check(not repos[repo.id], "Duplicate repository ID")
    repos[repo.id] = repo
  end
  local function identity(v)
    check(text(v.id) and not ids[v.id], "Missing or duplicate record-local ID")
    ids[v.id] = true
  end
  local stop, box
  box = function(v, depth)
    fields(v, keys("id note locator evidence calls"), "box")
    identity(v)
    check(text(v.note), "Box requires a prepared note")
    locator(v.locator)
    evidence(v.evidence)
    list(v.calls, "calls")
    count = count + 1
    for _, call in ipairs(v.calls) do
      stop(call, depth + 1, true)
    end
  end
  stop = function(v, depth, nested)
    check(depth <= 128, "Saved tree is too deep")
    fields(v, keys("id title repo file overview parts callsite next level"), "stop")
    identity(v)
    check(text(v.title) and repos[v.repo] and M.relative(v.file), "Invalid stop source/title")
    check(nested or (v.callsite == nil and v.next == nil), "Root cannot have caller navigation")
    check(v.next == nil or type(v.next) == "boolean", "Invalid next relationship")
    check(v.level == nil or (type(v.level) == "number" and v.level >= 0 and v.level % 1 == 0 and v.next), "Invalid level")
    check(not v.next or v.level ~= nil, "A next call needs a level")
    if v.next then
      check(v.callsite ~= nil, "Next relationship needs a caller locator")
    end
    if v.callsite then
      fields(v.callsite, keys("symbol locator"), "callsite")
      check(type(v.callsite.symbol) == "string", "Invalid call symbol")
      locator(v.callsite.locator)
    end
    box(v.overview, depth)
    list(v.parts, "parts")
    for _, p in ipairs(v.parts) do
      box(p, depth)
    end
  end
  for _, v in ipairs(record.stops) do
    stop(v, 1, false)
  end
  check(count > 0, "No prepared explanations")
  return record
end
local function bytes(path)
  local fd, err = uv.fs_open(path, "r", 384)
  check(fd, "Cannot read saved tour: " .. tostring(err))
  local stat, stat_err = uv.fs_fstat(fd)
  if not stat then
    uv.fs_close(fd)
    fail("Cannot inspect saved tour: " .. tostring(stat_err))
  end
  local data, read_err = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  check(data, "Cannot read saved tour: " .. tostring(read_err))
  return data
end
function M.read(id)
  check(hex(id, 32), "Invalid tour ID")
  local data = bytes(M.directory() .. "/" .. id .. ".json")
  local record = M.validate(vim.json.decode(data))
  check(record.id == id, "Tour ID does not match filename")
  return record, vim.fn.sha256(data)
end
function M.write(record, opts)
  opts = opts or {}
  M.check_directory(opts.library)
  record = vim.deepcopy(record)
  local overwrite = opts.overwrite
  check(not overwrite or overwrite == record.id, "Overwrite must identify this tour")
  if not overwrite then
    record.id = M.id()
  end
  local directory = M.directory()
  vim.fn.mkdir(directory, "p")
  local path, lock
  for _ = 1, 8 do
    path = directory .. "/" .. record.id .. ".json"
    lock = path .. ".lock"
    local acquired, err = uv.fs_mkdir(lock, 448)
    check(
      acquired,
      "Saved tour lock busy; inspect/remove a stale lock explicitly: " .. lock .. " (" .. tostring(err) .. ")"
    )
    if overwrite or not uv.fs_stat(path) then
      break
    end
    uv.fs_rmdir(lock)
    lock = nil
    record.id = M.id()
  end
  check(lock, "Could not allocate a new tour ID")
  local temporary, fd
  local ok, result = pcall(function()
    if overwrite then
      check(text(opts.expected_revision), "Overwrite requires an expected revision")
      local previous, revision = M.read(overwrite)
      check(revision == opts.expected_revision, "Saved tour revision conflict; entry was not overwritten")
      record.created_at = previous.created_at
    end
    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    record.created_at = overwrite and record.created_at or now
    record.saved_at = now
    M.validate(record)
    local data = vim.json.encode(record) .. "\n"
    temporary = path .. ".tmp-" .. M.id()
    local err
    fd, err = uv.fs_open(temporary, "wx", 384)
    check(fd, "Temporary write failed: " .. tostring(err))
    local written, write_err = uv.fs_write(fd, data, 0)
    check(written == #data, "Temporary write failed: " .. tostring(write_err))
    local flushed, flush_err = uv.fs_fsync(fd)
    check(flushed, "Flush failed: " .. tostring(flush_err))
    local closed, close_err = uv.fs_close(fd)
    fd = nil
    check(closed, "Close failed: " .. tostring(close_err))
    local renamed, rename_err = uv.fs_rename(temporary, path)
    check(renamed, "Atomic save failed: " .. tostring(rename_err))
    temporary = nil
    return {
      id = record.id,
      title = record.title,
      created_at = record.created_at,
      saved_at = record.saved_at,
      revision = vim.fn.sha256(data),
      library = directory,
    }
  end)
  if fd then
    uv.fs_close(fd)
  end
  if temporary then
    uv.fs_unlink(temporary)
  end
  uv.fs_rmdir(lock)
  if not ok then
    fail(result)
  end
  return result
end
return M
