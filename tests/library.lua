local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = root .. "/state", root .. "/cache"
vim.env.XDG_DATA_HOME = root
local library = require("code-tour.library")
local fixture = vim.json.decode(table.concat(vim.fn.readfile(plugin .. "/tests/fixtures/saved-v1.json"), "\n"))
local checks = 0
local function check(value, message)
  assert(value, message)
  checks = checks + 1
end
local function rejects(fn, message)
  check(not pcall(fn), message)
end
local function raw(id)
  return table.concat(vim.fn.readfile(library.directory() .. "/" .. id .. ".json", "b"), "\n")
end
local function run()
  check(library.directory() == root .. "/nvim/code-tour/tours", "Profile data contract")
  check(library.validate(fixture) == fixture, "Shared nested multi-repository fixture")
  local result = library.write(fixture)
  local record, revision = library.read(result.id)
  check(record.stops[1].parts[1].calls[1].overview.note == "Compute a result.", "Nested round-trip")
  check(revision == result.revision and revision == vim.fn.sha256(raw(result.id)), "Exact JSON revision")
  local second = library.write(record)
  check(result.id ~= second.id, "Ordinary saves create distinct IDs")
  local original = raw(result.id)
  local changed = vim.deepcopy(record)
  changed.title = "Updated"
  rejects(function()
    library.write(changed, { overwrite = result.id })
  end, "Overwrite needs revision")
  rejects(function()
    library.write(changed, { overwrite = result.id, expected_revision = string.rep("0", 64) })
  end, "Wrong revision conflicts")
  check(raw(result.id) == original, "Failed overwrite preserves JSON bytes")
  local lock = library.directory() .. "/" .. result.id .. ".json.lock"
  vim.fn.mkdir(lock)
  rejects(function()
    library.write(changed, { overwrite = result.id, expected_revision = revision })
  end, "Concurrent writer lock is exclusive")
  check(raw(result.id) == original, "Busy lock preserves prior bytes")
  vim.fn.delete(lock, "d")
  for _, operation in ipairs({ "fs_open", "fs_write", "fs_fsync", "fs_rename" }) do
    local original_fn = vim.uv[operation]
    vim.uv[operation] = function(...)
      local args = { ... }
      if operation ~= "fs_open" or tostring(args[1]):find(".tmp-", 1, true) then
        return nil, "injected failure"
      end
      return original_fn(...)
    end
    local ok = pcall(library.write, changed, { overwrite = result.id, expected_revision = revision })
    vim.uv[operation] = original_fn
    check(not ok and raw(result.id) == original, operation .. " failure preserves old record")
    check(not vim.uv.fs_stat(lock), "Failure releases owned lock")
    check(#vim.fn.glob(library.directory() .. "/*.tmp-*", false, true) == 0, "Failure removes owned temporary file")
  end
  local overwritten = library.write(changed, { overwrite = result.id, expected_revision = revision })
  local updated = library.read(result.id)
  check(
    updated.title == "Updated" and updated.created_at == record.created_at,
    "Explicit overwrite preserves identity/creation"
  )
  check(overwritten.revision ~= revision, "Successful overwrite returns new revision")
  for _, mutate in ipairs({
    function(r)
      r.version = 2
    end,
    function(r)
      r.stops[1].parts[1].id = r.stops[1].overview.id
    end,
    function(r)
      r.stops[1].file = "../escape.lua"
    end,
    function(r)
      r.stops[1].repo = "missing"
    end,
    function(r)
      r.stops[1].overview.thread = {}
    end,
    function(r)
      r.stops[1].overview.locator.range["end"] = { 0, 0 }
    end,
    function(r)
      r.stops[1].parts[1].calls[1].callsite = nil
    end,
    function(r)
      r.saved_at = "2026-02-30T00:00:00Z"
    end,
    function(r)
      r.stops[1].overview.evidence = { status = "verified", digest = "invented" }
    end,
  }) do
    local invalid = vim.deepcopy(fixture)
    mutate(invalid)
    rejects(function()
      library.validate(invalid)
    end, "Malformed records fail validation")
  end
  rejects(function()
    library.check_directory("/another/profile")
  end, "Profile mismatch is explicit")
  check(#vim.fn.glob(library.directory() .. "/*", false, true) == 2, "Only per-tour JSON files persist")
  local future = library.directory() .. "/" .. fixture.id .. ".json"
  local invalid = vim.deepcopy(fixture)
  invalid.version = 99
  vim.fn.writefile({ vim.json.encode(invalid) }, future)
  rejects(function()
    library.read(fixture.id)
  end, "Unsupported versions are read errors")
  check(
    vim.json.decode(table.concat(vim.fn.readfile(future), "\n")).version == 99,
    "Unsupported version remains untouched"
  )
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("PASS: " .. checks .. " library checks")
