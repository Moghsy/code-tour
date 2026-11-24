-- The project index (SPEC-ast-graph §4.3): which files belong to the project, their
-- extracted facts (cached by git blob SHA), and on-demand discovery of the files that
-- declare a type, its subtypes, or a method name.
local M = {}
function M.parser_available(parser)
  local ok, loaded = pcall(vim.treesitter.language.add, parser)
  return ok and loaded == true
end

local Index = {}
Index.__index = Index

local fallback_skip = { [".git"] = true, target = true, build = true, out = true, bin = true,
  [".gradle"] = true, [".idea"] = true, node_modules = true }

local function git(root, args, input)
  local cmd = vim.list_extend({ "git", "-C", root }, args)
  local r = vim.system(cmd, { text = true, stdin = input }):wait()
  return r.code == 0 and r.stdout or nil, r
end

local function split0(out)
  local list = {}
  for item in (out or ""):gmatch("[^%z]+") do
    list[#list + 1] = item
  end
  return list
end

-- The project root: the git top level of `path`, or `path` itself.
function M.root(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p"))
  if vim.fn.isdirectory(path) == 0 then
    path = vim.fs.dirname(path)
  end
  local out = git(path, { "rev-parse", "--show-toplevel" })
  if out then
    return vim.fs.normalize(vim.trim(out)), true
  end
  return path:gsub("/$", ""), false
end

local function backends(names)
  local list, by_ext = {}, {}
  for _, name in ipairs(names or { "java" }) do
    local ok, backend = pcall(require, "code-tour.ast.lang." .. name)
    if ok then
      list[#list + 1] = backend
      for _, ext in ipairs(backend.extensions) do
        by_ext[ext] = backend
      end
    end
  end
  return list, by_ext
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
    stats = { parsed = 0, cached = 0, buffers = 0 },
    errors = {},
  }, Index)
  self:list_files()
  return self
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

-- The files of one git checkout at `dir`: candidates (tracked plus untracked, not ignored) and
-- the blob SHA of each file git can vouch for. `prefix` places them under the project root.
local function git_files(dir, prefix, candidates, blobs)
  local function place(path)
    return prefix and (prefix .. "/" .. path) or path
  end
  for _, path in ipairs(split0(git(dir, { "ls-files", "-z", "--cached", "--others", "--exclude-standard" }))) do
    candidates[#candidates + 1] = place(path)
  end
  for _, line in ipairs(split0(git(dir, { "ls-files", "-s", "-z" }))) do
    local sha, path = line:match("^%d+ (%x+) %d+\t(.*)$")
    if sha then
      blobs[place(path)] = sha
    end
  end
  -- the index SHA is wrong for files modified in the working tree, and git does not
  -- report modifications of assume-unchanged (lowercase tag) or skip-worktree (S) files
  for _, path in ipairs(split0(git(dir, { "ls-files", "-m", "-z" }))) do
    blobs[place(path)] = nil
  end
  for _, line in ipairs(split0(git(dir, { "ls-files", "-v", "-z" }))) do
    local tag, path = line:match("^(%S) (.*)$")
    if tag and (tag:match("%l") or tag == "S") then
      blobs[place(path)] = nil
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
    for _, repo in ipairs(self.workspace.repos) do
      if vim.uv.fs_stat(repo.root .. "/.git") then
        git_files(repo.root, repo.dir, candidates, self.blobs)
      else
        local found = {}
        walk_files(repo.root, nil, found)
        for _, path in ipairs(found) do
          candidates[#candidates + 1] = repo.dir .. "/" .. path
        end
      end
    end
  elseif self.git then
    git_files(self.root, nil, candidates, self.blobs)
  else
    walk_files(self.root, nil, candidates)
  end
  local seen = {}
  for _, rel in ipairs(candidates) do
    if not seen[rel] and self.by_ext[extension(rel) or ""] and not self:ignored(rel)
        and vim.uv.fs_stat(self:abs(rel)) then
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

function Index:rel(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
  for _, repo in ipairs(self.repo_list or {}) do
    if path:sub(1, #repo.root + 1) == repo.root .. "/" then
      return repo.dir .. "/" .. path:sub(#repo.root + 2)
    end
  end
  if path:sub(1, #self.root + 1) == self.root .. "/" then
    return path:sub(#self.root + 2)
  end
  return path
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
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
    return buf
  end
end

function Index:blob(rel)
  local sha = self.blobs[rel]
  if not sha then
    local repo, inside = self:repo_of(rel)
    if repo and vim.uv.fs_stat(repo.root .. "/.git") then
      local out = git(repo.root, { "hash-object", "--", inside })
      sha = out and vim.trim(out)
    elseif self.git then
      local out = git(self.root, { "hash-object", "--", rel })
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

function Index:cache_path(backend, sha)
  return ("%s/%s-v%d-%s/%s.json"):format(self.cache_dir, backend.name, backend.version, parser_tag(backend.parser), sha)
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
  local cached = self.loaded[rel]
  if cached then
    return cached
  end
  local backend = self:backend(rel)
  if not backend then
    return nil, "no backend"
  end
  if not M.parser_available(backend.parser) then
    local err = "no parser for " .. backend.parser
    self.errors[rel] = err
    return nil, err
  end
  local path = self:abs(rel)
  local facts
  local buf = buffer_for(path)
  if buf then
    -- one entry per buffer, valid for one changedtick
    local tick = vim.api.nvim_buf_get_changedtick(buf)
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
    local file = self:cache_path(backend, sha)
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

-- Files whose contents match a regular expression (git grep over the same file set).
function Index:grep(pattern)
  local cached = self.grep_cache[pattern]
  if cached then
    return cached
  end
  local found = {}
  -- git greps each checkout (the project's, or each workspace repository); only files outside
  -- any checkout are read
  local unlisted = {}
  local checkouts = {}
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
  for _, checkout in ipairs(checkouts) do
    local out = git(checkout.root, { "grep", "-l", "-z", "--untracked", "-E", pattern })
    for _, path in ipairs(split0(out)) do
      local rel = checkout.prefix .. path
      if self.file_set[rel] then
        found[#found + 1] = rel
      end
    end
  end
  if #unlisted > 0 then
    -- ERE word boundaries alternate between Vim's start-of-word and end-of-word atoms
    local opening = true
    local translated = pattern:gsub("\\b", function()
      local atom = opening and "<" or ">"
      opening = not opening
      return atom
    end)
    local regex = vim.regex("\\v" .. translated)
    for _, rel in ipairs(unlisted) do
      for _, line in ipairs(vim.fn.readfile(self:abs(rel))) do
        if regex:match_str(line) then
          found[#found + 1] = rel
          break
        end
      end
    end
  end
  if self.workspace then
    table.sort(found)
  end
  self.grep_cache[pattern] = found
  return found
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
end

-- Every project type with this simple name.
function Index:declarations_named(name, language)
  for _, file in ipairs(self:grep("\\b(class|interface|enum|record)\\s+" .. name .. "\\b")) do
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
