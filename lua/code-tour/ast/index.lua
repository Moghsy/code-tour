-- The project index (SPEC-ast-graph §4.3): which files belong to the project, their
-- extracted facts (cached by git blob SHA), and on-demand discovery of the files that
-- declare a type, its subtypes, or a method name.
local deadline = require("code-tour.ast.deadline")
local slice = require("code-tour.ast.slice")
local M = {}
-- where long work may stop (deadline) or let the editor run (slice)
local function checkpoint()
  slice.point()
  deadline.check()
end
function M.parser_available(parser)
  local ok, loaded = pcall(vim.treesitter.language.add, parser)
  return ok and loaded == true
end

local Index = {}
Index.__index = Index

local fallback_skip = { [".git"] = true, target = true, build = true, out = true, bin = true,
  [".gradle"] = true, [".idea"] = true, node_modules = true }

-- Wait for a git job within the deadline: its stdout or nil, and its exit code.
local function finish_git(job)
  local r = job:wait(deadline.remaining())
  -- past the deadline `r` may be missing: report the overrun, not that
  deadline.check()
  if not r then
    return nil
  end
  return r.code == 0 and r.stdout or nil, r.code
end

local function git(root, args)
  local cmd = vim.list_extend({ "git", "-C", root }, args)
  return (finish_git(vim.system(cmd, { text = true })))
end

-- Several git commands ({ root, args }) at once, a bounded number at a time. Returns the
-- stdout of each (false when it failed) and the exit codes.
local function git_all(commands)
  local out, codes = {}, {}
  for first = 1, #commands, 16 do
    local jobs = {}
    for i = first, math.min(first + 15, #commands) do
      local c = commands[i]
      jobs[i] = vim.system(vim.list_extend({ "git", "-C", c[1] }, c[2]), { text = true })
    end
    for i = first, math.min(first + 15, #commands) do
      local stdout, code = finish_git(jobs[i])
      out[i], codes[i] = stdout or false, code or -1
    end
  end
  return out, codes
end

local function split0(out)
  local list = {}
  for item in (out or ""):gmatch("[^%z]+") do
    list[#list + 1] = item
  end
  return list
end

-- Absolute, without "." and ".." segments or a trailing slash. Symlinks are kept.
local function absolute(path)
  return (vim.fs.normalize(vim.fn.simplify(vim.fn.fnamemodify(path, ":p"))):gsub("(.)/$", "%1"))
end

-- The one spelling of a path: absolute with symlinks resolved, as far as the path exists.
-- Roots, repositories and the files looked up in them are all compared in this form.
function M.realpath(path)
  path = absolute(path)
  local head, tail = path, {}
  while true do
    local real = vim.uv.fs_realpath(head)
    if real then
      table.insert(tail, 1, real)
      return vim.fs.normalize(table.concat(tail, "/"))
    end
    local parent = vim.fs.dirname(head)
    if parent == head then
      return path
    end
    table.insert(tail, 1, vim.fs.basename(head))
    head = parent
  end
end

-- The loaded buffer of a file. `bufnr()` takes a pattern, which misreads names such as
-- `[id].tsx`; `bufexists()` compares whole names.
function M.buffer(path)
  if vim.fn.bufexists(path) == 1 then
    local buf = vim.fn.bufadd(path)
    if vim.api.nvim_buf_is_loaded(buf) then
      return buf
    end
  end
end

-- The project root: the git top level of `path`, or `path` itself.
function M.root(path)
  path = M.realpath(path or vim.fn.getcwd())
  if vim.fn.isdirectory(path) == 0 then
    path = vim.fs.dirname(path)
  end
  local out = git(path, { "rev-parse", "--show-toplevel" })
  if out then
    return M.realpath(vim.trim(out)), true
  end
  return path, false
end

local function backends(names)
  local list, by_ext = {}, {}
  for _, name in ipairs(names or { "java" }) do
    local ok, backend = pcall(require, "code-tour.ast.lang." .. name)
    -- two names may share a backend (javascript is typescript)
    if ok and not vim.tbl_contains(list, backend) then
      list[#list + 1] = backend
      for _, ext in ipairs(backend.extensions) do
        by_ext[ext] = backend
      end
    end
  end
  return list, by_ext
end

-- The grammar a backend uses for one file (a backend may serve several).
function M.parser_of(backend, rel)
  return backend.parser_for and backend.parser_for(rel) or backend.parser
end

local function extension(path)
  return path:match("(%.[^./]+)$")
end

-- opts: { root?, languages?, ignore = {patterns}, cache_dir?, max_files? }
function M.new(opts)
  opts = opts or {}
  -- a workspace (several repositories under a root that is none) is opt-in: workspace.lua
  local workspace = opts.workspace or require("code-tour.workspace").resolve(opts.root or vim.fn.getcwd())
  local root, is_git
  if workspace then
    workspace = vim.deepcopy(workspace)
    workspace.root = M.realpath(workspace.root)
    workspace.main = workspace.main and M.realpath(workspace.main)
    for _, repo in ipairs(workspace.repos) do
      repo.root = M.realpath(repo.root)
    end
    root, is_git = workspace.root, false
  else
    root, is_git = M.root(opts.root)
  end
  local list, by_ext = backends(opts.languages)
  local self = setmetatable({
    root = root,
    git = is_git,
    workspace = workspace,
    -- the notes store lives with the main copy when the root is a worktree of the project
    store_root = workspace and (workspace.main or workspace.root) or nil,
    backends = list,
    by_ext = by_ext,
    ignore = opts.ignore or {},
    cache_dir = opts.cache_dir or (vim.fn.stdpath("cache") .. "/code-tour/ast"),
    max_files = opts.max_files or 5000,
    loaded = {}, -- rel path -> facts
    symbols = {}, -- id -> symbol
    type_files = {}, -- type ID -> rel path
    grep_cache = {},
    type_misses = {}, -- "language:qname" looked up and not found
    name_misses = {}, -- simple name -> { language -> true }
    declaring_files = {}, -- extensions and simple name -> files that declare it
    expected = {}, -- simple names likely to be looked up, searched together with the next one
    buffered = {}, -- rel -> changedtick of the unsaved buffer its facts came from
    stats = { parsed = 0, cached = 0, buffers = 0 },
    errors = {},
  }, Index)
  self:configure()
  self:list_files()
  return self
end

local configured -- the index whose root's settings the backends hold

-- Backends keep the root's settings in module state, so an index sets them again before
-- extracting when another index was used since.
function Index:configure()
  configured = self
  for _, backend in ipairs(self.backends) do
    if backend.configure then
      backend.configure(self.root)
    end
  end
end

function Index:ignored(rel)
  for _, pattern in ipairs(self.ignore) do
    if rel == pattern or rel:sub(1, #pattern + 1) == pattern .. "/" or vim.glob.to_lpeg(pattern):match(rel) then
      return true
    end
  end
  return false
end

-- Files: exactly what git lists (tracked plus untracked, not ignored), minus ast.ignore.
local function walk_files(dir, rel, out)
  for name, kind in vim.fs.dir(dir) do
    local r = rel and (rel .. "/" .. name) or name
    if kind == "directory" then
      if not fallback_skip[name] then
        walk_files(dir .. "/" .. name, r, out)
      end
    elseif kind == "file" then
      out[#out + 1] = r
    end
  end
end

-- The files of git checkouts ({ dir, prefix }), listed at once: candidates (tracked plus
-- untracked, not ignored) and the blob SHA of each file git can vouch for. `prefix` places
-- them under the project root.
local function git_files(checkouts, candidates, blobs)
  local queries = {
    { "ls-files", "-z", "--cached", "--others", "--exclude-standard" },
    { "ls-files", "-s", "-z" },
    { "ls-files", "-m", "-z" },
    { "ls-files", "-v", "-z" },
  }
  local commands = {}
  for _, checkout in ipairs(checkouts) do
    for _, args in ipairs(queries) do
      commands[#commands + 1] = { checkout.dir, args }
    end
  end
  local out = git_all(commands)
  for k, checkout in ipairs(checkouts) do
    local function place(path)
      return checkout.prefix and (checkout.prefix .. "/" .. path) or path
    end
    local at = (k - 1) * #queries
    for _, path in ipairs(split0(out[at + 1] or "")) do
      candidates[#candidates + 1] = place(path)
    end
    for _, line in ipairs(split0(out[at + 2] or "")) do
      local sha, path = line:match("^%d+ (%x+) %d+\t(.*)$")
      if sha then
        blobs[place(path)] = sha
      end
    end
    -- the index SHA is wrong for files modified in the working tree, and git does not
    -- report modifications of assume-unchanged (lowercase tag) or skip-worktree (S) files
    for _, path in ipairs(split0(out[at + 3] or "")) do
      blobs[place(path)] = nil
    end
    for _, line in ipairs(split0(out[at + 4] or "")) do
      local tag, path = line:match("^(%S) (.*)$")
      if tag and (tag:match("%l") or tag == "S") then
        blobs[place(path)] = nil
      end
    end
  end
end

-- Files: exactly what git lists (tracked plus untracked, not ignored), minus ast.ignore.
-- In a workspace, each repository is listed under its directory in the project root.
function Index:list_files()
  self.files, self.file_set, self.blobs = {}, {}, {}
  self.modules = {}
  local candidates = {}
  if self.workspace then
    self.repo_list = {}
    for _, repo in ipairs(self.workspace.repos) do
      self.repo_list[#self.repo_list + 1] = repo
    end
    -- the longest directory first, so a nested repository wins over the one around it
    table.sort(self.repo_list, function(a, b)
      return #a.dir > #b.dir
    end)
    vim.list_extend(self.repo_list, self.attached or {})
    local checkouts = {}
    for _, repo in ipairs(self.workspace.repos) do
      if vim.uv.fs_stat(repo.root .. "/.git") then
        checkouts[#checkouts + 1] = { dir = repo.root, prefix = repo.dir }
      else
        local found = {}
        walk_files(repo.root, nil, found)
        for _, path in ipairs(found) do
          candidates[#candidates + 1] = repo.dir .. "/" .. path
        end
      end
    end
    git_files(checkouts, candidates, self.blobs)
  elseif self.git then
    git_files({ { dir = self.root } }, candidates, self.blobs)
  else
    walk_files(self.root, nil, candidates)
  end
  local seen = {}
  self.stamps = {}
  for _, rel in ipairs(candidates) do
    local stat = not seen[rel] and self.by_ext[extension(rel) or ""] and not self:ignored(rel)
      and vim.uv.fs_stat(self:abs(rel))
    if stat then
      self.stamps[rel] = ("%d.%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
      seen[rel] = true
      self.files[#self.files + 1] = rel
      self.file_set[rel] = true
    end
  end
  table.sort(self.files)
  for _, rel in ipairs(self.files) do
    local backend = self:backend(rel)
    if backend.module_name then
      local key = backend.name .. ":" .. backend.module_name(rel)
      self.modules[key] = self.modules[key] or {}
      table.insert(self.modules[key], rel)
    end
  end
end

-- Everything the index was built from: when it is unchanged, the index can be used again.
function Index:signature()
  local parts = { self.root }
  for _, repo in ipairs(self.workspace and self.workspace.repos or {}) do
    parts[#parts + 1] = repo.dir .. "=" .. repo.root
  end
  for _, rel in ipairs(self.files) do
    parts[#parts + 1] = rel .. " " .. self.stamps[rel]
  end
  -- path aliases are read from these (lang/typescript.lua)
  for _, name in ipairs({ "tsconfig.json", "tsconfig.base.json", "jsconfig.json" }) do
    local stat = vim.uv.fs_stat(self.root .. "/" .. name)
    if stat then
      parts[#parts + 1] = ("%s %d.%d:%d"):format(name, stat.mtime.sec, stat.mtime.nsec, stat.size)
    end
  end
  local unsaved = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name ~= "" and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
      local rel = self:rel(name)
      if self.file_set[rel] then
        unsaved[#unsaved + 1] = rel .. " @" .. vim.api.nvim_buf_get_changedtick(buf)
      end
    end
  end
  table.sort(unsaved)
  return vim.fn.sha256(table.concat(vim.list_extend(parts, unsaved), "\n"))
end

-- False once facts read from an unsaved buffer no longer match that buffer.
function Index:buffers_current()
  for rel, tick in pairs(self.buffered) do
    local buf = M.buffer(self:abs(rel))
    if not (buf and vim.bo[buf].modified and vim.api.nvim_buf_get_changedtick(buf) == tick) then
      return false
    end
  end
  return true
end

-- Drop everything derived from the files, in place, so holders of this index and of its
-- resolver read afresh. Used when a request stops half way through resolution.
function Index:reset()
  self.loaded, self.buffered = {}, {}
  self.type_misses, self.name_misses = {}, {}
  self.declaring_files, self.expected = {}, {}
  self.example_catalog = nil
  if self.example_job then
    self.example_job.restart = true
  end
  local r = self.resolver
  if r then
    r.type_cache, r.super_cache, r.subtype_cache, r.resolved_files, r.named_cache = {}, {}, {}, {}, {}
    r.global_names, r.boundary_cache = nil, nil
  end
end

-- A checkout outside the project that an agent range names (SPEC-ast-graph §14): it joins
-- repo_list under the reserved directory `@NAME`, so abs/rel/git_dir/head_of work on its
-- files as on a workspace repository's. Its files are not indexed (no symbols, no graph).
-- repo: { dir, root } from a stored range spec, or nil to derive it from `path`.
-- Returns the repository and `path` relative to the index.
function Index:attach(path, repo)
  self.attached = self.attached or {}
  if repo then
    for _, known in ipairs(self.attached) do
      if known.root == repo.root then
        return known
      end
    end
  else
    path = M.realpath(path)
    for _, known in ipairs(self.attached) do
      if path:sub(1, #known.root + 1) == known.root .. "/" then
        return known, known.dir .. "/" .. path:sub(#known.root + 2)
      end
    end
    local dir = vim.fs.dirname(path)
    local top = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
    local root = top.code == 0 and M.realpath(vim.trim(top.stdout)) or dir
    local name, taken = "@" .. vim.fs.basename(root), {}
    for _, known in ipairs(self.attached) do
      taken[known.dir] = true
    end
    local unique, k = name, 1
    while taken[unique] do
      k = k + 1
      unique = name .. "-" .. k
    end
    repo = { dir = unique, root = root, attached = true }
  end
  self.attached[#self.attached + 1] = repo
  self.repo_list = self.repo_list or {}
  self.repo_list[#self.repo_list + 1] = repo
  return repo, path and repo.dir .. "/" .. path:sub(#repo.root + 2) or nil
end

-- The workspace repository holding `rel` and the path inside it.
function Index:repo_of(rel)
  for _, repo in ipairs(self.repo_list or {}) do
    if rel:sub(1, #repo.dir + 1) == repo.dir .. "/" then
      return repo, rel:sub(#repo.dir + 2)
    end
  end
end

function Index:abs(rel)
  local repo, inside = self:repo_of(rel)
  return (repo and repo.root or self.root) .. "/" .. (repo and inside or rel)
end

-- `rel` for a path under the project or one of its repositories, else nil.
function Index:inside(path)
  local inside = path:sub(1, #self.root + 1) == self.root .. "/"
  for _, repo in ipairs(self.repo_list or {}) do
    -- an attached checkout may contain the project itself; the project's own files stay its own
    if not (repo.attached and inside) and path:sub(1, #repo.root + 1) == repo.root .. "/" then
      return repo.dir .. "/" .. path:sub(#repo.root + 2)
    end
  end
  if inside then
    return path:sub(#self.root + 2)
  end
end

-- The project path of a file however it is spelled; outside the project, its real path.
function Index:rel(path)
  -- as written first, so a symlink tracked inside the project keeps its own name
  local plain = absolute(path)
  local found = self:inside(plain)
  if found and (not self.file_set or self.file_set[found]) then
    return found
  end
  local real = M.realpath(plain)
  return self:inside(real) or found or real
end

-- The git checkout that holds `rel`, and the path inside it: the workspace repository, or the
-- project's own repository. Nil when the file is under no git checkout.
function Index:git_dir(rel)
  local repo, inside = self:repo_of(rel)
  if repo then
    return vim.uv.fs_stat(repo.root .. "/.git") and repo.root or nil, inside
  end
  if self.git then
    return self.root, rel
  end
end

-- HEAD of the checkout holding `rel` (cached per checkout), or nil.
function Index:head_of(rel)
  local dir = self:git_dir(rel)
  if not dir then
    return nil
  end
  self.heads = self.heads or {}
  if self.heads[dir] == nil then
    local out = git(dir, { "rev-parse", "--verify", "HEAD" })
    self.heads[dir] = out and vim.trim(out) or false
  end
  return self.heads[dir] or nil
end

-- One identity for the HEADs of all the workspace's repositories: it changes when any does.
function Index:workspace_head()
  local lines = {}
  for _, repo in ipairs(self.workspace and self.workspace.repos or {}) do
    local head = self:head_of(repo.dir .. "/")
    if head then
      lines[#lines + 1] = repo.dir .. "=" .. head
    end
  end
  table.sort(lines)
  return #lines > 0 and vim.fn.sha256(table.concat(lines, "\n")) or nil
end

function Index:backend(rel)
  return self.by_ext[extension(rel) or ""]
end

-- Content identity: a loaded, modified buffer by changedtick; otherwise the blob SHA.
local function buffer_for(path)
  local buf = M.buffer(path)
  if buf and vim.bo[buf].modified then
    return buf
  end
end

-- Hash every file git could not vouch for in one call per checkout.
function Index:hash_files()
  self.hashed = true
  local groups = {}
  for _, rel in ipairs(self.files) do
    if not self.blobs[rel] then
      local dir, inside = self:git_dir(rel)
      if dir then
        groups[dir] = groups[dir] or {}
        table.insert(groups[dir], { rel = rel, path = inside })
      end
    end
  end
  for dir, list in pairs(groups) do
    for first = 1, #list, 200 do
      local args = { "hash-object", "--" }
      for i = first, math.min(first + 199, #list) do
        args[#args + 1] = list[i].path
      end
      local k = first
      for sha in (git(dir, args) or ""):gmatch("%x+") do
        self.blobs[list[k].rel] = sha
        k = k + 1
      end
    end
  end
end

function Index:blob(rel)
  if not self.blobs[rel] and not self.hashed then
    self:hash_files()
  end
  local sha = self.blobs[rel]
  if not sha then
    local dir, inside = self:git_dir(rel)
    if dir then
      local out = git(dir, { "hash-object", "--", inside })
      sha = out and vim.trim(out)
    end
    if not sha then
      local data = table.concat(vim.fn.readfile(self:abs(rel), "b"), "\n")
      sha = vim.fn.sha256(data)
    end
    self.blobs[rel] = sha
  end
  return sha
end

local function strip_file(facts)
  -- cached facts are keyed by content, so the path is not part of them
  return vim.json.encode(facts)
end

-- Cached facts depend on the backend's extraction code and on the parser's grammar.
local abi = {}
local function parser_tag(lang)
  if abi[lang] == nil then
    local ok, info = pcall(vim.treesitter.language.inspect, lang)
    abi[lang] = ok and ("abi%d-%d"):format(info.abi_version or 0, #(info.symbols or {})) or "abi0"
  end
  return abi[lang]
end

function Index:cache_path(backend, sha, rel)
  local parser = M.parser_of(backend, rel)
  return ("%s/%s-v%d-%s/%s.json"):format(self.cache_dir, backend.name, backend.version, parser_tag(parser), sha)
end

local function rebase(facts, rel)
  -- facts cached under another path: rewrite every file reference
  local old = facts.file
  if old == rel then
    return facts
  end
  facts.file = rel
  local symbols = {}
  for id, sym in pairs(facts.symbols) do
    sym.file = rel
    if sym.kind == "file" then
      id = "file:" .. rel
      sym.id, sym.label = id, vim.fs.basename(rel)
    end
    symbols[id] = sym
  end
  facts.symbols = symbols
  return facts
end

-- Facts for one project file (both passes), parsing at most once per content.
function Index:facts(rel)
  checkpoint()
  local cached = self.loaded[rel]
  if cached then
    return cached
  end
  local backend = self:backend(rel)
  if not backend then
    return nil, "no backend"
  end
  if configured ~= self then
    self:configure()
  end
  local parser = M.parser_of(backend, rel)
  if not M.parser_available(parser) then
    local err = "no parser for " .. parser
    self.errors[rel] = err
    return nil, err
  end
  local path = self:abs(rel)
  local facts
  local buf = buffer_for(path)
  if buf then
    -- one entry per buffer, valid for one changedtick
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    self.buffered[rel] = tick
    local entry = M.buffer_cache[buf]
    if entry and entry.tick == tick and entry.backend == backend.name then
      facts = rebase(vim.deepcopy(entry.facts), rel)
    else
      facts = backend.extract(rel, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
      M.buffer_cache[buf] = { tick = tick, backend = backend.name, facts = vim.deepcopy(facts) }
      self.stats.buffers = self.stats.buffers + 1
    end
  else
    local sha = self:blob(rel)
    if backend.cache_identity then
      sha = vim.fn.sha256(sha .. "\0" .. backend.cache_identity(rel))
    end
    local file = self:cache_path(backend, sha, rel)
    local fd = io.open(file, "r")
    if fd then
      local ok, decoded = pcall(vim.json.decode, fd:read("*a"), { luanil = { object = true, array = true } })
      fd:close()
      if ok and type(decoded) == "table" then
        facts = rebase(decoded, rel)
        self.stats.cached = self.stats.cached + 1
      end
    end
    if not facts then
      local lines = vim.fn.readfile(path, "b")
      facts = backend.extract(rel, table.concat(lines, "\n"))
      self.stats.parsed = self.stats.parsed + 1
      vim.fn.mkdir(vim.fs.dirname(file), "p")
      local tmp = file .. ".tmp" .. vim.uv.os_getpid()
      local out = io.open(tmp, "w")
      if out then
        out:write(strip_file(facts))
        out:close()
        vim.uv.fs_rename(tmp, file)
      end
    end
  end
  facts.backend = backend.name
  self.loaded[rel] = facts
  for id, sym in pairs(facts.symbols) do
    self.symbols[id] = sym
  end
  for _, id in pairs(facts.types) do
    self.type_files[id] = self.type_files[id] or rel
    -- a type that appears only now (synthesized ones are not in any text) is no longer missing
    local sym = facts.symbols[id]
    if sym then
      self.name_misses[sym.name] = nil
    end
  end
  return facts
end
M.buffer_cache = {}
vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
  callback = function(args)
    M.buffer_cache[args.buf] = nil
  end,
})

function Index:symbol(id)
  return self.symbols[id]
end

function Index:module(language, name)
  local paths = self.modules[language .. ":" .. name]
  if paths and #paths == 1 then
    return self:facts(paths[1])
  end
end

-- Module-oriented languages encode both functions and types in qualified IDs.
function Index:qualified_symbol(language, qname)
  local id = language .. ":" .. qname
  local name = qname:match("^(.*)%.[^.]+$")
  while name do
    local facts = self:module(language, name)
    if facts and facts.symbols[id] then
      return facts.symbols[id]
    end
    name = name:match("^(.*)%.[^.]+$")
  end
end

-- The extensions to search: one language's, or every enabled one's.
function Index:extensions(language)
  local out = {}
  for ext, backend in pairs(self.by_ext) do
    if not language or backend.name == language then
      out[#out + 1] = ext
    end
  end
  table.sort(out)
  return out
end

-- Where to search for files of these extensions: git checkouts, and the files outside any.
function Index:search_places()
  local checkouts, unlisted = {}, {}
  if self.workspace then
    for _, repo in ipairs(self.workspace.repos) do
      if vim.uv.fs_stat(repo.root .. "/.git") then
        checkouts[#checkouts + 1] = { root = repo.root, prefix = repo.dir .. "/" }
      end
    end
    for _, rel in ipairs(self.files) do
      if not self:git_dir(rel) then
        unlisted[#unlisted + 1] = rel
      end
    end
  elseif self.git then
    checkouts[1] = { root = self.root, prefix = "" }
  else
    unlisted = self.files
  end
  return checkouts, unlisted
end

-- An ERE as a Vim regex; its word boundaries alternate between start-of-word and end-of-word.
local function vim_regex(pattern)
  local opening = true
  local translated = pattern:gsub("\\b", function()
    local atom = opening and "<" or ">"
    opening = not opening
    return atom
  end)
  return vim.regex("\\v" .. translated)
end

-- `git grep` for an ERE in every checkout at once, plus a read of the files outside them.
-- Calls `found(rel)` once per matching file, or with `matches`, `found(rel, text)` per match.
-- False when a checkout could not be searched, so the answer must not be remembered.
function Index:search(pattern, extensions, matches, found)
  local wanted = {}
  for _, ext in ipairs(extensions) do
    wanted[ext] = true
  end
  local checkouts, unlisted = self:search_places()
  local args = { "grep", matches and "-o" or "-l", "-z", "--untracked", "-E", "-e", pattern, "--" }
  for _, ext in ipairs(extensions) do
    args[#args + 1] = "*" .. ext
  end
  local outputs, codes = git_all(vim.tbl_map(function(checkout)
    return { checkout.root, args }
  end, checkouts))
  local complete = true
  for i, checkout in ipairs(checkouts) do
    -- 1 is "no match"; anything else is a failure
    complete = complete and (codes[i] == 0 or codes[i] == 1)
    local out = outputs[i] or ""
    -- `-o -z` prints "path NUL match LF"; `-l -z` prints "path NUL"
    for path, text in out:gmatch(matches and "([^%z]+)%z([^\n]*)\n" or "([^%z]+)%z()") do
      local rel = checkout.prefix .. path
      if self.file_set[rel] then
        found(rel, text)
      end
    end
  end
  if #unlisted == 0 then
    return complete
  end
  local regex = vim_regex(pattern)
  for _, rel in ipairs(unlisted) do
    deadline.check()
    for _, line in ipairs(wanted[extension(rel)] and vim.fn.readfile(self:abs(rel)) or {}) do
      local from, to = regex:match_str(line)
      if from and not matches then
        found(rel)
        break
      end
      while from do
        found(rel, line:sub(from + 1, to))
        line = line:sub(math.max(to, 1) + 1)
        from, to = regex:match_str(line)
      end
    end
  end
  return complete
end

-- Files whose contents match a regular expression (git grep over the same file set),
-- searching only the file types of `language` (default: all enabled languages).
function Index:grep(pattern, language)
  checkpoint()
  local extensions = self:extensions(language)
  if #extensions == 0 then
    return {}
  end
  local key = table.concat(extensions, " ") .. "\0" .. pattern
  local cached = self.grep_cache[key]
  if cached then
    return cached
  end
  local found = {}
  local complete = self:search(pattern, extensions, false, function(rel)
    found[#found + 1] = rel
  end)
  if self.workspace then
    table.sort(found)
  end
  if complete then
    self.grep_cache[key] = found
  end
  return found
end

-- Names a file mentions that may need looking up: they are searched in one batch.
function Index:expect(facts)
  local seen = {}
  local function walk(value)
    if type(value) == "string" then
      for word in value:gmatch("%f[%w_]%u[%w_]*") do
        self.expected[word] = true
      end
    elseif type(value) == "table" and not seen[value] then
      seen[value] = true
      for _, item in pairs(value) do
        walk(item)
      end
    end
  end
  walk({ facts.imports, facts.symbols, facts.bodies })
end

local batch_size = 400

-- The files that declare a type of this name. One search answers for the expected names too.
function Index:declaring(name, language)
  checkpoint()
  local extensions = self:extensions(language)
  -- a name goes into a regular expression: anything but an identifier declares no type
  if #extensions == 0 or not name:match("^[%w_$\128-\255]+$") then
    return {}
  end
  local prefix = table.concat(extensions, " ") .. "\0"
  local cached = self.declaring_files[prefix .. name]
  if cached then
    return cached
  end
  local names, wanted = { name }, { [name] = {} }
  for other in pairs(self.expected) do
    if #names >= batch_size then
      break
    end
    if not wanted[other] and not self.declaring_files[prefix .. other] then
      names[#names + 1], wanted[other] = other, {}
    end
  end
  local keywords = "class|interface|enum|record"
  -- TypeScript and JavaScript also declare types as `type X = {…}` and `const X = {…}`
  if language ~= "java" and self.by_ext[".ts"] then
    keywords = keywords .. "|type|const|let|var"
  end
  local pattern = "\\b(" .. keywords .. ")\\s+(" .. table.concat(names, "|"):gsub("%$", "[$]") .. ")\\b"
  local listed = {}
  local complete = self:search(pattern, extensions, true, function(rel, text)
    local declared = text:match("([^%s]+)$")
    if wanted[declared] and not listed[declared .. "\0" .. rel] then
      listed[declared .. "\0" .. rel] = true
      table.insert(wanted[declared], rel)
    end
  end)
  for _, each in ipairs(names) do
    if self.workspace then
      table.sort(wanted[each])
    end
    if complete then
      self.declaring_files[prefix .. each] = wanted[each]
    end
  end
  return wanted[name]
end

-- The type symbol with qualified name `qname`, loading the file that declares it.
-- Java's package-to-path convention finds most; otherwise declarations are grepped.
-- A file only provides the types it declares in its own package (the package check).
function Index:type(qname, language)
  if language and language ~= "java" then
    local sym = self:qualified_symbol(language, qname)
    return sym and self.type_files[sym.id] and sym or nil
  end
  local id = "java:" .. qname
  local rel = self.type_files[id]
  if rel then
    return self.symbols[id]
  end
  if self.type_misses[qname] then
    return nil
  end
  local segments = vim.split(qname, ".", { plain = true })
  for k = #segments, 1, -1 do
    local suffix = table.concat(segments, "/", 1, k) .. ".java"
    for _, file in ipairs(self.files) do
      if not self.loaded[file] and (file == suffix or file:sub(-#suffix - 1) == "/" .. suffix) then
        self:facts(file)
      end
    end
    if self.type_files[id] then
      return self.symbols[id]
    end
  end
  self:declarations_named(segments[#segments], "java")
  if self.type_files[id] then
    return self.symbols[id]
  end
  self.type_misses[qname] = true
end

-- Every project type with this simple name.
function Index:declarations_named(name, language)
  local misses = self.name_misses[name]
  if misses and misses[language or ""] then
    return {}
  end
  for _, file in ipairs(self:declaring(name, language)) do
    if not language or self:backend(file).name == language then
      self:facts(file)
    end
  end
  local out = {}
  for _, facts in pairs(self.loaded) do
    for _, id in pairs(facts.types) do
      local sym = facts.symbols[id]
      if sym and sym.name == name and (not language or facts.lang == language) then
        out[#out + 1] = sym
      end
    end
  end
  table.sort(out, function(a, b)
    return a.id < b.id
  end)
  local extensions = table.concat(self:extensions(language), " ")
  -- remember the miss only when the search itself succeeded
  if #out == 0 and self.declaring_files[extensions .. "\0" .. name] then
    self.name_misses[name] = self.name_misses[name] or {}
    self.name_misses[name][language or ""] = true
  end
  return out
end

-- Load every file that mentions `word` (candidates for subtypes, name-only callees).
function Index:mentioning(word)
  for _, file in ipairs(self:grep("\\b" .. word .. "\\b")) do
    self:facts(file)
  end
end

-- Parse the whole project (codegraph, entry-free tours), capped at max_files.
function Index:scan()
  local count = 0
  for _, rel in ipairs(self.files) do
    if count >= self.max_files then
      self.truncated = true
      break
    end
    self:facts(rel)
    count = count + 1
  end
  self.scanned = true
  return count
end

M.Index = Index
return M
