-- Projects made of several git repositories under one root that is not itself a repository
-- (SPEC-workspace.md). Everything here is opt-in: with no hook set, every function answers
-- "not configured" and the callers behave exactly as before.
--
--   require("code-tour").setup({ workspace = {
--     repos = function(root) return { root .. "/api", root .. "/web" } end, -- AST tours span these
--     root = function(path) end,         -- optional: the workspace root containing `path`
--     main = function(root) end,         -- worktrees: the main copy's root, or nil
--     relocate = function(repo, ctx) end, -- saved tours: where a repository lives now
--     repo = function(path, root) end,   -- review: the git root of a file
--   } })
local M = { hooks = {} }

local NAMES = { "repos", "root", "main", "relocate", "repo" }

function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "code-tour: workspace must be a table of hooks")
  local hooks = {}
  for _, name in ipairs(NAMES) do
    local hook = opts[name]
    assert(hook == nil or type(hook) == "function", "code-tour: workspace." .. name .. " must be a function")
    hooks[name] = hook
  end
  for name in pairs(opts) do
    assert(vim.tbl_contains(NAMES, name), "code-tour: unknown workspace hook " .. tostring(name))
  end
  M.hooks = hooks
end

local function normalize(path)
  return (vim.fs.normalize(path):gsub("(.)/$", "%1"))
end

local function is_dir(path)
  local stat = path and vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

local function is_repo(path)
  return vim.uv.fs_stat(path .. "/.git") ~= nil
end

-- A hook failure must never break a tour: warn once per call and act as if it were unset.
local function call(name, ...)
  local hook = M.hooks[name]
  if not hook then
    return nil
  end
  local ok, result = pcall(hook, ...)
  if not ok then
    vim.notify("code-tour: workspace." .. name .. " failed: " .. tostring(result), vim.log.levels.WARN)
    return nil
  end
  return result
end

local function absolute(value)
  return type(value) == "string" and value:sub(1, 1) == "/" and normalize(value) or nil
end

-- The workspace root and its main copy for `path`: nil unless `root` or `main` is a hook.
function M.context(path)
  if not (M.hooks.root or M.hooks.main) then
    return nil
  end
  path = normalize(vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p"))
  local root = absolute(call("root", path)) or path
  local main = absolute(call("main", root))
  if main == root or not is_dir(main) then
    main = nil
  end
  return { root = root, main = main }
end

-- The repositories of the workspace at `path`, for an AST index:
--   { root, main?, repos = { { dir = "api", root = "/abs/api" } ... } }
-- `dir` is the repository's place under the tour root, whichever copy provides it: a worktree
-- of the project holds the repositories it has checked out and falls back to the main copy's.
function M.resolve(path)
  if not M.hooks.repos then
    return nil
  end
  path = normalize(vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p"))
  local context = M.context(path) or { root = path }
  local base = context.main or context.root
  local list = call("repos", base)
  if type(list) ~= "table" then
    return nil
  end
  local repos, seen = {}, {}
  for _, entry in ipairs(list) do
    local repo = absolute(entry)
    local dir = repo and vim.fs.relpath(base, repo)
    if dir and dir ~= "." and not seen[dir] and is_dir(repo) then
      seen[dir] = true
      local own = context.main and context.root .. "/" .. dir
      repos[#repos + 1] = { dir = dir, root = own and is_repo(own) and own or repo }
    end
  end
  if #repos == 0 then
    return nil
  end
  table.sort(repos, function(a, b)
    return a.dir < b.dir
  end)
  return { root = context.root, main = context.main, repos = repos }
end

-- Saved tours in a worktree prefer the worktree's own copy of each repository, then the main
-- copy's. `root` is a repository root recorded in a saved tour (under either copy).
function M.prefer(context, root)
  if not (context and context.main) then
    return root
  end
  local dir = vim.fs.relpath(context.main, root) or vim.fs.relpath(context.root, root)
  if not dir or dir == "." then
    return root
  end
  local own, shared = context.root .. "/" .. dir, context.main .. "/" .. dir
  if is_repo(own) then
    return own
  end
  return is_dir(shared) and shared or root
end

-- The reverse: a repository inside the worktree is recorded under the main copy, so a saved tour
-- stays valid when the worktree is gone. Repositories only the worktree has keep their own root.
function M.canonical(context, root)
  local dir = context and context.main and vim.fs.relpath(context.root, root)
  if dir and dir ~= "." and is_dir(context.main .. "/" .. dir) then
    return context.main .. "/" .. dir
  end
  return root
end

-- Where each repository of a saved record is to be opened: id -> absolute root. Explicit
-- overrides win; then the `relocate` hook (which sees the worktree's choice as `candidate`);
-- repositories that stay where they were are left out.
function M.saved_roots(record, root, explicit)
  if not (M.hooks.relocate or M.hooks.main) then
    return explicit
  end
  local context = M.context(root)
  local roots = vim.deepcopy(explicit or {})
  for _, repo in ipairs(record.repositories) do
    if roots[repo.id] == nil then
      local candidate = M.prefer(context, repo.root)
      local chosen = absolute(call("relocate", vim.deepcopy(repo), {
        root = context and context.root or normalize(root),
        main = context and context.main,
        candidate = candidate,
      }))
      candidate = chosen or candidate
      if candidate ~= repo.root then
        roots[repo.id] = candidate
      end
    end
  end
  return next(roots) and roots or explicit
end

-- Review: the git root of `path`, from the `repo` hook; nil leaves the caller's own lookup.
function M.repo_of(path, root)
  return absolute(call("repo", path, root))
end

-- A ready-made `repo` hook: the nearest enclosing directory with a .git.
function M.git_root(path)
  return vim.fs.root(path, { ".git" })
end

return M
