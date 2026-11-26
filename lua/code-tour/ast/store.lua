-- Repository note versions, edge notes and tour recipes (§11).
local notes = require("code-tour.ast.notes")
local parser_available = require("code-tour.ast.index").parser_available

local M = {}
local Store = {}
Store.__index = Store

local uv = vim.uv

local function git(root, ...)
  local result = vim.system(vim.list_extend({ "git", "-C", root }, { ... }), { text = false }):wait()
  return result.code == 0 and result.stdout or nil
end

local function read(path)
  local fd = io.open(path, "rb")
  if fd then
    local ok, data = pcall(vim.json.decode, fd:read("*a"), { luanil = { object = true, array = true } })
    fd:close()
    if ok and type(data) == "table" then
      return data
    end
  end
  return {}
end

local function atomic_write(path, data)
  local encoded = vim.json.encode(data) .. "\n"
  local fd, tmp = uv.fs_mkstemp(path .. ".XXXXXX")
  assert(fd, tmp)
  local written, err = uv.fs_write(fd, encoded)
  local closed, close_err = uv.fs_close(fd)
  local renamed, rename_err
  if written == #encoded and closed then
    renamed, rename_err = uv.fs_rename(tmp, path)
  end
  if not renamed then
    uv.fs_unlink(tmp)
    error(err or close_err or rename_err or ("Incomplete write to " .. path), 0)
  end
end

-- Concurrent writers can create the parent between a missing-path check and mkdir.
local function create_directory(path)
  local ok, err, code = uv.fs_mkdir(path, 448)
  if code == "ENOENT" then
    create_directory(vim.fs.dirname(path))
    ok, err, code = uv.fs_mkdir(path, 448)
  end
  if ok then return true end
  local existing = code == "EEXIST" and uv.fs_stat(path)
  if existing and existing.type == "directory" then return false end
  error(err, 0)
end

-- A process acquiring the lock re-reads the document. Rename keeps other readers
-- on either the old or the new complete document.
local function transaction(path, update)
  create_directory(vim.fs.dirname(path))
  local lock = path .. ".lock"
  local fd, err, code
  local function acquire()
    fd, err, code = uv.fs_open(lock, "wx", 384)
    if not fd and code == "EEXIST" then
      local existing = io.open(lock, "r")
      if existing then
        local pid = tonumber(existing:read("*l"))
        existing:close()
        local stat = uv.fs_stat(lock)
        local _, _, dead
        if pid then
          _, _, dead = uv.kill(pid, 0)
        end
        if dead == "ESRCH" or (not pid and stat and os.time() - stat.mtime.sec > 10) then
          uv.fs_unlink(lock)
        end
      end
    end
    return fd ~= nil or code ~= "EEXIST"
  end
  if not acquire() then
    -- Do not run editor callbacks while a synchronous fill is holding other state.
    for _ = 1, 200 do
      uv.sleep(10)
      if acquire() then
        break
      end
    end
  end
  assert(fd, err or ("Could not lock " .. path))
  uv.fs_write(fd, tostring(uv.os_getpid()) .. "\n")
  uv.fs_close(fd)
  local ok, result = pcall(function()
    local data = read(path)
    local value, changed = update(data)
    if changed ~= false then
      atomic_write(path, data)
    end
    return value
  end)
  uv.fs_unlink(lock)
  if not ok then
    error(result, 0)
  end
  return result
end

local function location(idx, options)
  local common = idx.git and git(idx.root, "rev-parse", "--path-format=absolute", "--git-common-dir")
  local main = common and vim.fs.dirname(vim.trim(common)) or idx.store_root or idx.root
  -- a workspace has no HEAD of its own: its identity is that of its repositories' HEADs
  local head = idx.workspace and idx:workspace_head() or (idx.git and git(idx.root, "rev-parse", "--verify", "HEAD"))
  if options.store == "user" then
    local commits = head and git(idx.root, "rev-list", "--max-parents=0", "HEAD")
    local first = commits and vim.split(vim.trim(commits), "\n", { plain = true }) or {}
    table.sort(first)
    local identity = first[1] and first[1] ~= "" and first[1] or main
    return vim.fn.stdpath("data") .. "/code-tour/store/" .. vim.fn.sha256(identity), nil, head
  end
  local exclude = common and vim.trim(common) .. "/info/exclude"
  local index = common and vim.trim(common) .. "/index"
  return main .. "/.code-tour", exclude, head, main, index
end

local function local_exclude(path)
  pcall(function()
    local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
    if vim.tbl_contains(lines, ".code-tour/") or vim.tbl_contains(lines, "/.code-tour/") then
      return
    end
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    assert(vim.fn.writefile({ ".code-tour/" }, path, "a") == 0)
  end)
end

local function unmerged(root)
  local paths = {}
  if root then
    local raw = git(root, "ls-files", "-u", "-z", "--", ".code-tour/notes")
    for entry in (raw or ""):gmatch("[^%z]+") do
      local stage, path = entry:match("^([^\t]+)\t(.*)$")
      if stage then
        local name = vim.fs.basename(path)
        paths[name] = (paths[name] or "") .. stage .. "\n"
      end
    end
  end
  return paths
end

local function stamp(s)
  if s then
    return table.concat({ s.dev, s.ino, s.size, s.mtime.sec, s.mtime.nsec, s.ctime.sec, s.ctime.nsec }, ":")
  end
end

local function clean_files(idx)
  local files = {}
  -- the project's checkout, or each workspace repository; `prefix` places its paths in the index
  local checkouts = {}
  if idx.workspace then
    for _, repo in ipairs(idx.workspace.repos) do
      if idx:git_dir(repo.dir .. "/") then
        checkouts[#checkouts + 1] = { root = repo.root, prefix = repo.dir .. "/" }
      end
    end
  elseif idx.git then
    checkouts[1] = { root = idx.root, prefix = "" }
  end
  local dirty = {}
  local listed = {}
  for _, checkout in ipairs(checkouts) do
    local raw = git(checkout.root, "status", "--porcelain=v1", "-z", "--untracked-files=no", "--no-renames")
    if raw then
      listed[checkout.prefix] = true
      for entry in raw:gmatch("[^%z]+") do
        dirty[checkout.prefix .. entry:sub(4)] = true
      end
    end
  end
  for _, file in ipairs(idx.files) do
    local repo = idx:repo_of(file)
    if (listed[repo and repo.dir .. "/" or ""]) and idx.blobs[file] and not dirty[file] then
      files[file] = stamp(uv.fs_stat(idx:abs(file)))
    end
  end
  return files
end

function M.new(idx, options)
  options = options or {}
  local path, exclude, head, main, index = location(idx, options)
  return setmetatable({
    idx = idx, path = path, exclude = exclude, head = head and vim.trim(head), main = main, git_index = index,
    max_versions = math.max(1, options.store_versions or 3), ttl_days = options.store_ttl_days or 180,
    identities = {}, docs = {}, baselines = clean_files(idx),
  }, Store)
end

function Store:begin_write()
  if self.exclude then
    if create_directory(self.path) then
      local_exclude(self.exclude)
    end
    self.exclude = nil
  end
end

function Store:conflict(path)
  if self.git_index then
    local signature = stamp(uv.fs_stat(self.git_index))
    if not self.conflicts or self.conflict_signature ~= signature then
      self.conflicts = unmerged(self.main)
      self.conflict_signature = signature
    end
    return self.conflicts[vim.fs.basename(path)]
  end
end

local function load_buf(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  return buf
end

local function digest_range(path, state, range, parser)
  local buf = state.buf or load_buf(path)
  local scratch
  if not state.modified then
    local disk = state.disk or vim.fn.readfile(path)
    state.disk = disk
    if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), disk) then
      scratch = vim.api.nvim_create_buf(false, true)
      vim.bo[scratch].filetype = parser or vim.bo[buf].filetype
      vim.api.nvim_buf_set_lines(scratch, 0, -1, false, disk)
      buf = scratch
    end
  end
  local fp = notes.fingerprint(buf, range)
  if scratch then vim.api.nvim_buf_delete(scratch, { force = true }) end
  return fp
end

-- Uncommitted buffers cannot use the Git shortcuts. A stat stamp also invalidates
-- a cached blob when the working tree changes from another process.
function Store:file_state(file)
  local path = self.idx:abs(file)
  local buf = vim.fn.bufnr(path)
  local modified = buf > 0 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified
  local signature = modified and ("buf:%d:%d"):format(buf, vim.api.nvim_buf_get_changedtick(buf))
    or stamp(uv.fs_stat(path))
  if not signature then
    return nil
  end
  local prior = self.identities[file]
  if prior and prior.signature == signature then
    return prior
  end
  local blob, clean
  if modified then
    blob = "buffer:" .. vim.fn.sha256(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  elseif self.baselines[file] == signature then
    blob, clean = self.idx.blobs[file], true
  else
    local checkout, inside = self.idx:git_dir(file)
    local value = checkout and git(checkout, "hash-object", "--", inside)
    blob = value and vim.trim(value) or vim.fn.sha256(table.concat(vim.fn.readfile(path, "b"), "\n"))
    local head = self.idx:head_of(file)
    local head_blob = head and git(checkout, "rev-parse", "--verify", head .. ":" .. inside)
    clean = head_blob and vim.trim(head_blob) == blob or false
  end
  local state = { signature = signature, blob = blob, clean = clean, modified = modified, buf = modified and buf or nil }
  self.identities[file] = state
  return state
end

function Store:symbol_file(symbol)
  local idx = self.idx
  local sym = idx:symbol(symbol)
  if not sym then
    local language, name = symbol:match("^(.-):(.+)$")
    if language == "java" then
      idx:type(name:match("^[^#]+"))
    elseif language == "file" then
      idx:facts(name)
    elseif language then
      idx:qualified_symbol(language, name)
    end
    sym = idx:symbol(symbol)
  end
  return sym and sym.file
end

-- Resolve the address against the current file contents, even when the live skeleton
-- or the index loaded the old contents earlier.
function Store:region_fingerprint(address, opts)
  local symbol = opts and opts.symbol or address:match("^(.-)/body/") or address
  local file = self:symbol_file(symbol) or (opts and opts.file)
  local state = file and self:file_state(file)
  local backend = file and self.idx:backend(file)
  local agent = self.idx:symbol(symbol)
  if state and agent and agent.source == "agent" then
    local path = self.idx:abs(file)
    local parser = backend and require("code-tour.ast.index").parser_of(backend, file)
    if symbol == address then return digest_range(path, state, agent.range, parser), agent.range, agent end
    for _, region in ipairs(agent.agent_regions) do
      if address == region.address then return digest_range(path, state, region.range, parser), region.range, agent end
    end
  end
  if not state or not backend then
    return nil
  end
  if not state.facts then
    local raw = state.modified and vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
      or vim.fn.readfile(self.idx:abs(file), "b")
    state.facts = backend.extract(file, table.concat(raw, "\n"))
  end
  local sym = state.facts.symbols[symbol]
  if not sym or sym.error then
    return nil
  end
  local range = require("code-tour.ast.regions").range_at(sym, state.facts.bodies[symbol], address)
  if not range then
    return nil, nil, sym
  end
  state.fingerprints = state.fingerprints or {}
  if not state.fingerprints[address] then
    state.fingerprints[address] = digest_range(self.idx:abs(file), state, range,
      require("code-tour.ast.index").parser_of(backend, file))
  end
  return state.fingerprints[address], range, sym
end

function Store:meta()
  return read(self.path .. "/meta.json")
end

function Store:set_meta(key, value)
  self:begin_write()
  return transaction(self.path .. "/meta.json", function(data)
    if vim.deep_equal(data[key], value) then
      return nil, false
    end
    data[key] = value
  end)
end

function Store:validated(files)
  if not self.validation then
    local saved = self:meta().validation or {}
    self.validation = saved.head == self.head and saved.files or {}
  end
  local changed = {}
  for file, state in pairs(files) do
    if state and self.validation[file] ~= state.blob then
      changed[file] = state.blob
    end
  end
  if vim.tbl_isempty(changed) then
    return
  end
  self:begin_write()
  transaction(self.path .. "/meta.json", function(meta)
    local validation = meta.validation or {}
    local saved = validation.head == self.head and validation.files or {}
    meta.validation = { head = self.head, files = vim.tbl_extend("force", saved or {}, changed) }
  end)
  self.validation = vim.tbl_extend("force", self.validation, changed)
end

function Store:states(file, callees)
  local files = { [file] = self:file_state(file) or false }
  local by_symbol = {}
  for id in pairs(callees or {}) do
    local rel = self:symbol_file(id)
    by_symbol[id] = rel
    if rel and files[rel] == nil then
      files[rel] = self:file_state(rel) or false
    end
  end
  return files, by_symbol
end

local function same_state(validation, files, head)
  local committed = validation.head and validation.head == head
  local unchanged = true
  for file, state in pairs(files) do
    if not state then
      return false
    end
    committed = committed and state.clean and validation.clean[file]
    unchanged = unchanged and validation.files[file] == state.blob
  end
  return committed or unchanged
end

function Store:fresh_callees(version, known)
  for id, fp in pairs(version.evidence.callees or {}) do
    local actual = known and known[id] or self:region_fingerprint(id)
    if actual ~= fp then
      return false, actual and "callee changed" or "symbol missing"
    end
  end
  return true
end

function Store:is_fresh(version, fingerprint, opts)
  local evidence = version.evidence
  local files, by_symbol = self:states(version.file, evidence.callees)
  self:validated(files)
  local all_resolve = true
  for id in pairs(evidence.callees or {}) do
    all_resolve = all_resolve and by_symbol[id] ~= nil
  end
  local validation = version.validation
  if validation and all_resolve and (not fingerprint or fingerprint == evidence.fingerprint)
      and same_state(validation, files, self.head) then
    return true
  end
  local found = fingerprint or self:region_fingerprint(version.region, { file = version.file, symbol = version.symbol })
  if found ~= evidence.fingerprint then
    return false, found and "code changed" or "symbol missing"
  end
  return self:fresh_callees(version, opts and opts.callees)
end

function Store:file_path(file)
  file = self.idx:rel(file:sub(1, 1) == "/" and file or self.idx:abs(file))
  return self.path .. "/notes/" .. vim.fn.sha256(file) .. ".json"
end

function Store:document(path)
  local signature = stamp(uv.fs_stat(path))
  local cache = self.docs[path]
  if not cache or cache.signature ~= signature then
    cache = { signature = signature, data = read(path) }
    self.docs[path] = cache
  end
  local conflict = self:conflict(path)
  if conflict and cache.data.conflict ~= conflict then
    return {}, true
  end
  return cache.data
end

function Store:paths()
  local paths = {}
  if uv.fs_stat(self.path .. "/notes") then
    for name, kind in vim.fs.dir(self.path .. "/notes") do
      if kind == "file" and name:match("%.json$") then
        paths[#paths + 1] = self.path .. "/notes/" .. name
      end
    end
  end
  table.sort(paths)
  return paths
end

function Store:all()
  local out = {}
  for _, path in ipairs(self:paths()) do
    local doc = self:document(path)
    for _, versions in pairs(doc.notes or {}) do
      for _, version in ipairs(versions) do
        if version.gist then
          out[#out + 1] = version
        end
      end
    end
  end
  return out
end

function Store:touch(path, version)
  local now = os.time()
  if now - (version.last_read or 0) < 86400 then
    return
  end
  self:begin_write()
  transaction(path, function(doc)
    for _, saved in ipairs(doc.notes and doc.notes[version.region] or {}) do
      if vim.deep_equal(saved.evidence, version.evidence) then
        saved.last_read = now
        return
      end
    end
    return nil, false
  end)
end

-- Exact address first. A relocated box can match another address in the same
-- symbol or an obsolete symbol. A still-resolving, unrelated symbol is never a match.
function Store:find(address, fingerprint, opts)
  opts = opts or {}
  local symbol = opts.symbol or address:match("^(.-)/body/") or address
  local file = opts.file or self:symbol_file(symbol)
  local path = file and self:file_path(file)
  local stale, reason
  if path then
    local doc, conflict = self:document(path)
    for _, version in ipairs(doc.notes and doc.notes[address] or {}) do
      local fresh, why = self:is_fresh(version, fingerprint, opts)
      if fresh and version.gist then
        self:touch(path, version)
        return version
      elseif version.gist and not stale then
        stale, reason = version, why
      end
    end
    if conflict then
      return nil, "stale", "note conflict"
    end
  end
  if not fingerprint then
    return nil, stale and "stale" or "missing", reason, stale
  end
  local function moved(doc, same_symbol)
    local addresses = vim.tbl_keys(doc.notes or {})
    table.sort(addresses)
    for _, old in ipairs(addresses) do
      if old ~= address then
        for _, version in ipairs(doc.notes[old]) do
          local evidence = version.evidence
          local same_fp = evidence.fingerprint == fingerprint
            or (opts.relocation_fingerprint and evidence.relocation == opts.relocation_fingerprint)
          if same_fp and version.gist and ((same_symbol and version.symbol == symbol)
              or (not same_symbol and version.symbol ~= symbol and not self:region_fingerprint(version.symbol))) then
            local fresh = self:fresh_callees(version, opts.callees)
            if fresh then
              return version
            end
          end
        end
      end
    end
  end
  local first = path and moved(self:document(path), true)
  if first then
    self:touch(path, first)
    return first
  end
  for _, candidate in ipairs(self:paths()) do
    local old = moved(self:document(candidate), false)
    if old then
      self:touch(candidate, old)
      return old
    end
  end
  return nil, stale and "stale" or "missing", reason, stale
end

function Store:lookup(address, fingerprint, detail, opts)
  local version, status, reason = self:find(address, fingerprint, opts)
  if version then
    return notes.present(version, detail)
  end
  return nil, status, reason
end

function Store:status(address, fingerprint, detail, opts)
  local found, status, reason = self:lookup(address, fingerprint, detail, opts)
  if not found then
    return status, reason
  end
  return found.exact and "fresh" or (found.body and "near" or "gist")
end

function Store:previous(address, fingerprint, opts)
  local _, _, _, old = self:find(address, fingerprint, opts)
  return old
end

local function merge_evidence(version, incoming, store)
  if version.evidence.fingerprint ~= incoming.fingerprint then
    return false
  end
  for id, fp in pairs(version.evidence.callees or {}) do
    local actual = incoming.callees[id] or store:region_fingerprint(id)
    if actual ~= fp then
      return false
    end
  end
  return true
end

function Store:update_note(address, note, update)
  note.file = assert(note.file, "Persistent notes need a source file")
  note.symbol = note.symbol or address:match("^(.-)/body/") or address
  local path = self:file_path(note.file)
  local conflict = self:conflict(path)
  local incoming = { fingerprint = note.fingerprint, relocation = note.relocation_fingerprint, callees = note.callees or {} }
  local reusable = self:find(address, note.fingerprint, note)
  if reusable and reusable.region == address then
    reusable = nil
  end
  self:begin_write()
  local cur = transaction(path, function(doc)
    if conflict and doc.conflict ~= conflict then
      doc.notes, doc.edges, doc.conflict = {}, {}, conflict
    end
    doc.file = note.file
    doc.notes = doc.notes or {}
    local versions = doc.notes[address] or {}
    local version
    for i, candidate in ipairs(versions) do
      if merge_evidence(candidate, incoming, self) then
        version = table.remove(versions, i)
        break
      end
    end
    if not version then
      version = reusable and vim.deepcopy(reusable) or { bodies = {} }
      version.region, version.symbol, version.file = address, note.symbol, note.file
      version.fingerprint = note.fingerprint
      version.evidence = { fingerprint = incoming.fingerprint, relocation = incoming.relocation,
        callees = reusable and vim.deepcopy(reusable.evidence.callees) or {} }
    end
    version.evidence.callees = vim.tbl_extend("force", version.evidence.callees or {}, incoming.callees)
    version.evidence.relocation = incoming.relocation or version.evidence.relocation
    local files = self:states(note.file, version.evidence.callees)
    local validation = { head = self.head, files = {}, clean = {} }
    for file, state in pairs(files) do
      if state then
        validation.files[file] = state.blob
        validation.clean[file] = state.clean or nil
      end
    end
    local current = self:region_fingerprint(address, { file = note.file, symbol = note.symbol })
    if current == version.evidence.fingerprint and self:fresh_callees(version) then
      version.validation = validation
      self:validated(files)
    else
      version.validation = nil
    end
    version.last_read = os.time()
    update(version)
    table.insert(versions, 1, version)
    -- Questions belong to the code they were asked about: a newer version drops them from the older ones.
    for i = 2, #versions do versions[i].thread = nil end
    while #versions > self.max_versions do
      table.remove(versions)
    end
    doc.notes[address] = versions
    return version
  end)
  self.docs[path] = nil
  return cur
end

function Store:put(address, note)
  -- the commit of the repository holding the note's file
  local file = note.file or (note.symbol and self:symbol_file(note.symbol))
  note.commit = file and self.idx:head_of(file) or nil
  return self:update_note(address, note, function(cur)
    notes.write_version(cur, note)
  end)
end

function Store:thread(address, fingerprint, opts)
  local version = self:find(address, fingerprint, opts)
  if version then
    return vim.deepcopy(version.thread or {})
  end
  local file = opts and opts.file
  local doc = file and self:document(self:file_path(file)) or {}
  for _, cur in ipairs(doc.notes and doc.notes[address] or {}) do
    if cur.thread and not cur.gist and self:is_fresh(cur, fingerprint, opts) then
      return vim.deepcopy(cur.thread)
    end
  end
  return {}
end

function Store:save_turn(address, fingerprint, turn, opts)
  local note = vim.tbl_extend("force", { fingerprint = fingerprint }, opts or {})
  return self:update_note(address, note, function(version)
    version.thread = version.thread or {}
    notes.upsert_turn(version.thread, turn)
  end)
end

local function edge_key(caller, target, occurrence)
  return caller .. "|" .. target .. "|" .. tostring(occurrence or 1)
end

function Store:put_edge(caller, target, occurrence, edge)
  local symbol = caller:match("^(.-)/body/") or caller
  local file = assert(edge.file or self:symbol_file(symbol))
  local path = self:file_path(file)
  local conflict = self:conflict(path)
  self:begin_write()
  transaction(path, function(doc)
    if conflict and doc.conflict ~= conflict then
      doc.notes, doc.edges, doc.conflict = {}, {}, conflict
    end
    doc.file = file
    doc.edges = doc.edges or {}
    local key = edge_key(caller, target, occurrence)
    local versions = doc.edges[key] or {}
    local evidence = { caller_fingerprint = edge.caller_fingerprint, target_fingerprint = edge.target_fingerprint }
    for i, saved in ipairs(versions) do
      if vim.deep_equal(saved.evidence, evidence) then
        table.remove(versions, i)
        break
      end
    end
    table.insert(versions, 1, { caller = caller, target = target, occurrence = occurrence or 1, text = edge.text,
      evidence = evidence })
    while #versions > self.max_versions do
      table.remove(versions)
    end
    doc.edges[key] = versions
  end)
  self.docs[path] = nil
end

function Store:edge(caller, target, occurrence, caller_fp, target_fp, file)
  if not caller_fp or not target_fp then
    return nil
  end
  file = file or self:symbol_file(caller:match("^(.-)/body/") or caller)
  if file then
    local doc = self:document(self:file_path(file))
    for _, edge in ipairs(doc.edges and doc.edges[edge_key(caller, target, occurrence)] or {}) do
      if edge.evidence.caller_fingerprint == caller_fp and type(target_fp) == "function" then
        target_fp = target_fp()
      end
      if edge.evidence.caller_fingerprint == caller_fp and edge.evidence.target_fingerprint == target_fp then
        return edge.text
      end
    end
  end
end

function Store:remember(recipe)
  self:begin_write()
  transaction(self.path .. "/tours.json", function(doc)
    doc.recipes = doc.recipes or {}
    doc.recipes[recipe.id] = recipe
  end)
end

function Store:recipe(id)
  local doc = read(self.path .. "/tours.json")
  return doc.recipes and doc.recipes[id]
end

function Store:recipes()
  local list = vim.tbl_values(read(self.path .. "/tours.json").recipes or {})
  table.sort(list, function(a, b)
    return a.last_opened > b.last_opened or (a.last_opened == b.last_opened and a.id < b.id)
  end)
  return list
end

local function head_facts(store, file)
  local backend = store.idx:backend(file)
  local checkout, inside = store.idx:git_dir(file)
  local head = store.idx:head_of(file)
  if not head or not backend or not parser_available(require("code-tour.ast.index").parser_of(backend, file)) then
    return false
  end
  local tree = git(checkout, "ls-tree", "-z", head, "--", inside)
  if tree == "" then
    return { symbols = {}, bodies = {} }
  end
  local raw = tree and git(checkout, "show", head .. ":" .. inside)
  local facts = raw and backend.extract(file, raw)
  return facts and not facts.error and facts or false
end

function Store:prune()
  local removed = 0
  local cutoff = os.time() - self.ttl_days * 86400
  for _, path in ipairs(self:paths()) do
    local _, conflicted = self:document(path)
    if not conflicted then
      transaction(path, function(doc)
        local changed = false
        local missing_file = doc.file and not uv.fs_stat(self.idx:abs(doc.file))
        local at_head
        for address, versions in pairs(doc.notes or {}) do
          local kept = {}
          for i, version in ipairs(versions) do
            local expired = false
            if not missing_file and (version.last_read or 0) < cutoff then
              if at_head == nil then
                at_head = head_facts(self, doc.file)
              end
              if at_head then
                local sym = at_head.symbols[version.symbol]
                expired = not sym or not require("code-tour.ast.regions").range_at(sym, at_head.bodies[version.symbol], address)
              end
            end
            if missing_file or i > self.max_versions or expired then
              removed, changed = removed + 1, true
            else
              kept[#kept + 1] = version
            end
          end
          doc.notes[address] = #kept > 0 and kept or nil
        end
        if missing_file and doc.edges and not vim.tbl_isempty(doc.edges) then
          doc.edges, changed = nil, true
        end
        return nil, changed
      end)
      self.docs[path] = nil
    end
  end
  return { path = self.path, removed = removed }
end

return M
