-- SPEC-workspace.md: projects of several git repositories under a root that is not one, and
-- worktrees of such a project. Every behaviour is opt-in through `workspace` hooks.
--   nvim --headless --clean -u NONE -l tests/workspace.lua
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME or vim.fn.expand("~/.local/share/nvim/site"))
local sandbox = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(sandbox, "p")
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = sandbox .. "/state", sandbox .. "/cache"
vim.env.XDG_DATA_HOME = sandbox .. "/data"
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _prompt, _action, callback)
  callback(true)
end

local checks = 0
local function check(value, message)
  if not value then
    error("FAILED: " .. message, 2)
  end
  checks = checks + 1
end
local function eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("FAILED: %s\n  expected: %s\n  actual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
  checks = checks + 1
end

local function run(cmd, cwd)
  local result = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(result.code == 0, table.concat(cmd, " ") .. ": " .. (result.stderr or ""))
  return result.stdout
end
local function git(cwd, ...)
  return run(vim.list_extend({ "git", "-c", "user.email=t@example.invalid", "-c", "user.name=t" }, { ... }), cwd)
end
local function write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end
local function repo(root, name, files)
  local dir = root .. "/" .. name
  vim.fn.mkdir(dir, "p")
  git(dir, "init", "-q")
  for path, lines in pairs(files) do
    write(dir .. "/" .. path, lines)
  end
  git(dir, "add", "-A")
  git(dir, "commit", "-qm", "base")
  return dir
end

local workspace = require("code-tour.workspace")
local ast = require("code-tour.ast")
local function index(root)
  return ast.index({ root = root, cache_dir = sandbox .. "/ast-cache", languages = { "java" } })
end

-- base/ is not a repository; it holds api/, web/ and tools/, each its own.
local base = sandbox .. "/base"
vim.fn.mkdir(base, "p")
local api = repo(base, "api", {
  ["src/A.java"] = { "class A {", "  void run() {}", "}" },
  [".gitignore"] = { "ignored/" },
})
write(api .. "/ignored/Skip.java", { "class Skip {}" })
local web = repo(base, "web", { ["src/B.java"] = { "class B {", "  void go() {}", "}" } })
repo(base, "tools", { ["Tool.java"] = { "class Tool {}" } })
write(base .. "/notes/Loose.java", { "class Loose {}" })

local function all_repos(root)
  return { root .. "/api", root .. "/web", root .. "/tools" }
end

local function unset()
  -- no hook set: a plain directory is walked, nothing about repositories changes
  workspace.setup(nil)
  eq(workspace.resolve(base), nil, "resolve is nil without a repos hook")
  eq(workspace.context(base), nil, "context is nil without hooks")
  local idx = index(base)
  eq({ idx.workspace, idx.git, idx.root }, { nil, false, base }, "an unconfigured root keeps the old index")
  check(idx.file_set["notes/Loose.java"] and idx.file_set["api/ignored/Skip.java"], "the plain walk is unchanged")
  -- inside a repository the root is still its git top level
  local inner = index(api .. "/src")
  eq({ inner.root, inner.git, inner.workspace }, { api, true, nil }, "a repository root is unchanged")
  eq(workspace.saved_roots({ repositories = {} }, base, nil), nil, "saved roots are untouched")
  eq(workspace.repo_of(api .. "/src/A.java", base), nil, "no review hook, no repository")
  local ok, err = pcall(workspace.setup, { repos = "nope" })
  check(not ok and err:find("workspace.repos must be a function"), "hooks are validated")
  ok, err = pcall(workspace.setup, { typo = function() end })
  check(not ok and err:find("unknown workspace hook"), "unknown hooks are rejected")
  workspace.setup(nil)
end

local function spanning()
  workspace.setup({ repos = all_repos })
  local idx = index(base)
  eq({ idx.root, idx.git }, { base, false }, "the workspace root is the index root")
  eq(idx.files, { "api/src/A.java", "tools/Tool.java", "web/src/B.java" }, "files of every repository, git-listed")
  check(not idx.file_set["notes/Loose.java"], "files outside the repositories are not part of the project")
  check(not idx.file_set["api/ignored/Skip.java"], "each repository's own ignore rules apply")
  eq(idx:abs("web/src/B.java"), web .. "/src/B.java", "abs maps into the repository")
  eq(idx:rel(web .. "/src/B.java"), "web/src/B.java", "rel maps back")
  eq(idx:rel(base .. "/api/src/A.java"), "api/src/A.java", "rel of a path under the root")
  local expected = vim.trim(git(api, "rev-parse", "HEAD:src/A.java"))
  eq(idx:blob("api/src/A.java"), expected, "blobs are the repository's own")
  write(api .. "/src/A.java", { "class A {", "  void run() { }", "}" })
  local changed = index(base)
  check(changed:blob("api/src/A.java") ~= expected, "a modified file is hashed by content, not by the index")
  git(api, "checkout", "--", "src/A.java")
  -- the root hook finds the workspace from inside a repository
  eq(workspace.resolve(api .. "/src"), nil, "without a root hook the path itself is the root, and holds no repositories")
  workspace.setup({ repos = all_repos, root = function() return base end })
  eq(index(api .. "/src").root, base, "the root hook locates the workspace")
  -- hook failures degrade to the unconfigured behaviour with a warning
  local warned
  local notify = vim.notify
  vim.notify = function(message) warned = message end
  workspace.setup({ repos = function() error("boom") end })
  eq(workspace.resolve(base), nil, "a failing hook is ignored")
  check(warned and warned:find("workspace.repos failed"), "and reported")
  vim.notify = notify
  workspace.setup({ repos = function() return { "relative", base .. "/missing", base } end })
  eq(workspace.resolve(base), nil, "unusable repositories leave no workspace")
  workspace.setup(nil)
end

local wt = sandbox .. "/base-wt"
local function worktrees()
  -- base-wt/ holds a worktree of api only; web and tools fall back to base/
  vim.fn.mkdir(wt, "p")
  git(api, "worktree", "add", "-q", wt .. "/api", "-b", "feature")
  write(wt .. "/api/src/A.java", { "class A {", "  void run() { changed(); }", "}" })
  workspace.setup({ repos = all_repos, main = function(root) return root == wt and base or nil end })
  eq(workspace.context(wt), { root = wt, main = base }, "the worktree knows its main copy")
  eq(workspace.context(base), { root = base }, "the main copy is its own")
  local idx = index(wt)
  eq({ idx.root, idx.git, idx.store_root }, { wt, false, base }, "the worktree stays the root; the store is the main copy's")
  eq(idx.files, { "api/src/A.java", "tools/Tool.java", "web/src/B.java" }, "the same project, whichever copy provides it")
  eq(idx:abs("api/src/A.java"), wt .. "/api/src/A.java", "the worktree's repository wins")
  eq(idx:abs("web/src/B.java"), web .. "/src/B.java", "the main copy fills in the rest")
  eq(idx:rel(wt .. "/api/src/A.java"), "api/src/A.java", "rel from the worktree copy")
  eq(idx:rel(web .. "/src/B.java"), "web/src/B.java", "rel from the fallback copy")
  check(idx:blob("api/src/A.java") ~= vim.trim(git(api, "rev-parse", "HEAD:src/A.java")), "content comes from the worktree")
  if require("code-tour.ast.index").parser_available("java") then
    local store = require("code-tour.ast.store").new(idx, ast.options)
    store:put("java:A#run()", { file = "api/src/A.java", symbol = "java:A#run()", detail = "normal",
      fingerprint = "x", gist = "Runs." })
    check(vim.uv.fs_stat(base .. "/.code-tour") ~= nil, "notes are written to the main copy's store")
    check(vim.uv.fs_stat(wt .. "/.code-tour") == nil, "and not to the worktree")
  else
    print("MISSING PARSER: java (store location check skipped)")
  end
  -- a main hook that names the root itself, or a missing directory, means no main copy
  workspace.setup({ repos = all_repos, main = function() return wt end })
  eq(workspace.context(wt).main, nil, "a copy is not its own main copy")
  workspace.setup({ repos = all_repos, main = function() return sandbox .. "/gone" end })
  eq(workspace.context(wt).main, nil, "a missing main copy is ignored")
  workspace.setup(nil)
end

-- freshness, commits, pruning and grep use each repository's git, not a root that has none
local function stores()
  workspace.setup({ repos = all_repos })
  local idx = index(base)
  eq(idx:grep("class B"), { "web/src/B.java" }, "grep finds files through each repository's git grep")
  write(web .. "/src/Untracked.java", { "class B2 {}" })
  eq(index(base):grep("class B"), { "web/src/B.java", "web/src/Untracked.java" }, "git grep includes untracked files")
  vim.fn.delete(web .. "/src/Untracked.java")
  eq(idx:grep("ignored|Skip"), {}, "and honours the repository's ignore rules")
  local head = vim.trim(git(api, "rev-parse", "HEAD"))
  eq({ idx:head_of("api/src/A.java"), idx:head_of("web/src/B.java") ~= head, idx:head_of("notes/Loose.java") },
    { head, true, nil }, "each file has its own repository's HEAD")
  local before = idx:workspace_head()
  check(before ~= nil, "the workspace has a combined HEAD")
  write(api .. "/extra.txt", { "x" })
  git(api, "add", "-A")
  git(api, "commit", "-qm", "more")
  check(index(base):workspace_head() ~= before, "a commit in any repository changes it")
  if not require("code-tour.ast.index").parser_available("java") then
    print("MISSING PARSER: java (store checks skipped)")
    return
  end
  local fresh = index(base)
  local store = require("code-tour.ast.store").new(fresh, vim.tbl_extend("force", ast.options, { store_ttl_days = -1 }))
  eq(store.head, fresh:workspace_head(), "the store's HEAD is the combined one")
  eq(vim.tbl_count(store.baselines), 3, "clean files are known per repository, so they are not re-hashed")
  store:put("java:A#run()", { file = "api/src/A.java", symbol = "java:A#run()", detail = "normal",
    fingerprint = "x", gist = "Runs.", body = "Body." })
  local doc = vim.json.decode(table.concat(vim.fn.readfile(store:file_path("api/src/A.java")), "\n"))
  eq(doc.notes["java:A#run()"][1].bodies.normal.commit, vim.trim(git(api, "rev-parse", "HEAD")),
    "a note records the commit of its repository")
  local state = store:file_state("api/src/A.java")
  check(state.clean, "an unmodified file is clean against its repository's HEAD")
  store:put("java:A#gone()", { file = "api/src/A.java", symbol = "java:A#gone()", detail = "normal",
    fingerprint = "y", gist = "Gone." })
  eq(store:prune().removed, 1, "ttl pruning checks symbols against the repository's HEAD")
  workspace.setup(nil)
end

-- the headless CLI loads the hooks from CODE_TOUR_CONFIG
local function cli()
  if not require("code-tour.ast.index").parser_available("java") then
    return
  end
  local config = sandbox .. "/config.lua"
  vim.fn.writefile({ "return { workspace = { repos = function(root)",
    "  return { root .. '/api', root .. '/web', root .. '/tools' } end } }" }, config)
  local script = plugin .. "/lua/code-tour/ast/headless.lua"
  local function codegraph(env)
    local result = vim.system({ "nvim", "--headless", "-u", "NONE", "-i", "NONE", "-l", script, "codegraph",
      "--root", base }, { text = true, env = vim.tbl_extend("force", {
        CODE_TOUR_PARSER_RUNTIME = vim.fn.expand("~/.local/share/nvim/site"),
        XDG_CACHE_HOME = sandbox .. "/cli-cache", XDG_STATE_HOME = sandbox .. "/cli-state" }, env) }):wait()
    assert(vim.trim(result.stdout) ~= "", result.stderr)
    local line = vim.split(vim.trim(result.stdout), "\n")
    return vim.json.decode(line[#line])
  end
  eq(codegraph({ CODE_TOUR_CONFIG = config }).files, 3, "the CLI spans the repositories when configured")
  check(codegraph({}).files ~= 3, "and walks the directory, as before, when it is not")
  check(codegraph({ CODE_TOUR_CONFIG = sandbox .. "/missing.lua" }).error, "an unreadable config is an error")
end

local function review()
  local review_mod = require("code-tour.review")
  write(web .. "/src/B.java", { "class B {", "  void go() { more(); }", "}" })
  local function stop()
    local normalized = require("code-tour.stops").normalize(
      { { file = "web/src/B.java", start = 1, ["end"] = 3, note = "n" } }, base)[1]
    return normalized
  end
  local s = stop()
  local ok, err = pcall(review_mod.prepare, s, base, "HEAD")
  check(not ok and err:find("Review requires a Git repository"), "without the hook a non-repository root still fails")
  workspace.setup({ repo = workspace.git_root })
  s = stop()
  review_mod.prepare(s, base, "HEAD")
  check(s.added[2] and not s.added[1], "with the hook the file's own repository is diffed")
  eq(s.removed[1] and s.removed[1].lines, { "  void go() {}" }, "and removed lines are the base's")
  -- an explicit hook answer for a repository beats the root's own
  workspace.setup({ repo = function() return nil end })
  s = stop()
  ok = pcall(review_mod.prepare, s, base, "HEAD")
  check(not ok, "a hook with no answer falls back to the root lookup")
  git(web, "checkout", "--", "src/B.java")
  workspace.setup(nil)
end

local function saved()
  local tour, library = require("tour"), require("code-tour.library")
  tour.setup({ smooth_scroll = false, saved_batch_size = 1 })
  local function show(root, file)
    tour.show({ { file = file, start = 1, ["end"] = 3, title = "T", note = "Overview",
      parts = { { start = 1, ["end"] = 3, note = "Part" } } } }, { root = root })
  end
  local function opened_root()
    return tour.state().stops[1].path
  end

  -- relocation: the repository moved
  show(base, "web/src/B.java")
  local first = tour.save_saved({ title = "Moved" })
  eq(library.read(first.id).repositories[1].root, web, "the saved tour records its repository")
  local moved = sandbox .. "/moved-web"
  run({ "mv", web, moved })
  local ok, err = pcall(tour.open_saved, first.id)
  check(not ok and tostring(err):find("Missing repository/file"), "unset: a moved repository fails as before")
  workspace.setup({ relocate = function(repo, ctx)
    eq({ repo.label, ctx.root ~= nil }, { "web", true }, "the hook sees the repository and the context")
    return moved
  end })
  tour.open_saved(first.id, { root = base })
  eq(opened_root(), moved .. "/src/B.java", "the hook relocates the repository")
  -- explicit overrides stay in charge
  workspace.setup({ relocate = function() error("unused") end })
  tour.open_saved(first.id, { root = base, repositories = { [library.read(first.id).repositories[1].id] = moved } })
  eq(opened_root(), moved .. "/src/B.java", "explicit repositories win over the hook")
  -- a relocation to nothing leaves the record alone
  workspace.setup({ relocate = function() return nil end })
  ok = pcall(tour.open_saved, first.id, { root = base })
  check(not ok, "a hook with no answer keeps the recorded root")
  workspace.setup(nil)
  run({ "mv", moved, web })

  -- worktrees: saved in the worktree, recorded under the main copy, opened with the worktree's copy
  workspace.setup({ main = function(root) return root == wt and base or nil end })
  show(wt, "api/src/A.java")
  local second = tour.save_saved({ title = "From worktree" })
  eq(library.read(second.id).repositories[1].root, api, "a worktree's repository is recorded under the main copy")
  tour.open_saved(second.id, { root = wt })
  eq(opened_root(), wt .. "/api/src/A.java", "opening in the worktree prefers its copy of the repository")
  tour.open_saved(second.id, { root = base })
  eq(opened_root(), api .. "/src/A.java", "opening in the main copy uses the main copy")
  -- a repository the worktree lacks falls back to the main copy
  show(base, "web/src/B.java")
  local third = tour.save_saved({ title = "Shared repo" })
  tour.open_saved(third.id, { root = wt })
  eq(opened_root(), web .. "/src/B.java", "a repository the worktree lacks stays the main copy's")
  -- without the worktree the saved tour still opens
  run({ "rm", "-rf", wt .. "/api" })
  tour.open_saved(second.id, { root = wt })
  eq(opened_root(), api .. "/src/A.java", "a removed worktree falls back to the main copy")
  workspace.setup(nil)
end

local ok, err = xpcall(function()
  unset()
  spanning()
  worktrees()
  stores()
  cli()
  review()
  saved()
end, debug.traceback)
if not ok then
  io.stderr:write(err .. "\n")
  os.exit(1)
end
print(("workspace: %d checks passed"):format(checks))
vim.cmd("qa!")
