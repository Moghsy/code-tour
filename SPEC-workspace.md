# Workspaces: several repositories under one root, and their worktrees

Status: implemented (`lua/code-tour/workspace.lua`, `tests/workspace.lua`).

A *workspace* is a project made of several git repositories that sit under one directory which
is not itself a repository. Nothing here is on by default: every behaviour is reached through a
hook in `setup({ workspace = { ... } })`. **With no hook set, nothing changes**: the same
index, the same git lookups, the same saved-tour roots. A hook that throws is reported once as a
warning and treated as unset; a hook that returns something unusable (a relative path, a
missing directory) is ignored the same way.

## 1. Hooks

| Hook | Receives | Returns | Effect |
|------|----------|---------|--------|
| `repos(root)` | the workspace root (the main copy's, in a worktree) | absolute repository roots | AST tours span these repositories |
| `root(path)` | a directory (cwd, or the root asked for) | the workspace root containing it | lets a tour start from inside a repository |
| `main(root)` | the workspace root | the main copy's root, or `nil` | marks `root` as a worktree of that copy |
| `relocate(repo, ctx)` | a saved repository `{ id, label, root }`; `ctx = { root, main?, candidate }` | an absolute root, or `nil` | where a saved tour's repository lives now |
| `repo(path, root)` | a file and the tour root | that file's git root, or `nil` | review when the tour root is not a repository |

`require("code-tour.workspace").git_root` is a ready-made `repo` hook (the nearest directory with
a `.git`).

```lua
require("code-tour").setup({
  workspace = {
    repos = function(root)
      return vim.tbl_map(vim.fs.dirname, vim.fn.glob(root .. "/*/.git", false, true))
    end,
    repo = require("code-tour.workspace").git_root,
  },
})
```

## 2. AST tours across repositories

With `repos` set and a root that resolves to at least one repository directory below it, the
project index is a *workspace index*:

- `idx.root` is the workspace root and `idx.git` is `false`; `idx.workspace` holds
  `{ root, main?, repos = { { dir, root } } }`.
- Files are listed by each repository's own `git ls-files` (tracked plus untracked, not ignored)
  and keyed by `dir/<path in repository>`. A repository without a `.git` is walked. Files
  outside every repository are not part of the project.
- `idx:abs(rel)` and `idx:rel(path)` translate between those keys and real paths (longest
  directory first, so a nested repository wins). Everything downstream keeps using keys
  relative to the root, so addresses, regions, routes and the persisted graph are unchanged.
- Blob identity is the repository's own blob SHA; a file modified in the working tree is
  hashed with that repository's `git hash-object`, exactly as in a single repository.
- `idx:grep` runs `git grep` in each repository that has a `.git`; only files under no checkout
  are read in Lua.
- Git is consulted per checkout (`idx:git_dir(rel)`, `idx:head_of(rel)`): clean-file baselines
  come from each repository's `git status`; a file is clean when its blob equals the blob at
  *its* repository's HEAD; a note records the commit of the repository holding its file; and
  TTL pruning compares a note's symbol with the file at that repository's HEAD.
- The store's HEAD (`store.head`, the freshness shortcut's identity) is
  `idx:workspace_head()`: a digest of every repository's HEAD, so a commit anywhere makes
  the committed-state shortcut fall back to blob comparison, never to re-fingerprinting.
- The notes store is `<root>/.code-tour` (the root has no git common directory), or the main
  copy's in a worktree.

## 3. Saved tours that relocate

On `open_saved`, for every repository of the record that has no explicit
`opts.repositories[id]`, the root becomes `relocate(repo, ctx)` if the hook returns an
absolute path, otherwise `ctx.candidate` (§5), otherwise the recorded root. Only roots that
differ are passed on, through the existing override that `saved.prepare` already validates, so
a repository that cannot be found still fails with the usual "Missing repository/file".
Explicit overrides always win.

## 4. Review without a repository at the tour root

`review.prepare` asks `repo(stop.path, root)` first. A returned root is used as the git
top level for `git show`, rename detection and base validation. If the hook is unset or
returns `nil`, the old lookup (`git rev-parse --show-toplevel` in the tour root) runs and fails
with "Review requires a Git repository or explicit old text" as before.

## 5. Worktrees of a workspace

A worktree is a directory holding worktrees (or clones) of *some* of the repositories, with the
same layout as the main copy. With `main(root)` returning the main copy:

- **The worktree is the tour root.** `idx.root` is the worktree; `idx.workspace.main` is the
  main copy.
- **Repositories** are enumerated by `repos(main)`. For each one at `dir`, the worktree's
  `root/dir` is used when it is a repository (has `.git`), otherwise the main copy's. Keys are
  the same either way, so a tour reads as one project.
- **Notes**: the store is `<main>/.code-tour` (`idx.store_root`), shared by every copy.
- **Saved tours** are already global (`stdpath("data")`). When saving, a repository inside the
  worktree is recorded under the main copy, so the record survives the worktree; a repository
  only the worktree has keeps its own root. When opening, `candidate` is the worktree's copy of
  each recorded repository, then the main copy's, then the recorded root; `relocate` may
  overrule it.
- A `main` that returns the root itself, or a missing directory, means "not a worktree".

## 6. The headless CLI

`bin/code-tour` runs headless Neovim without `setup`. Set `CODE_TOUR_CONFIG` to a Lua file
returning `{ ast = {...}, workspace = {...} }` (the tables `setup` takes) and the CLI loads
them before any command; an unreadable file is a JSON error. When it is set, the wrapper no
longer replaces the working directory with its git top level, so the `root` hook can find the
workspace from anywhere inside it. With `--pane`, the running editor's own setup applies.
Unset, nothing is loaded and nothing changes. Authored tours need nothing: they already take
any file under their root.

## 7. Tests

`tests/workspace.lua`: unconfigured behaviour is unchanged and hooks are validated; spanning
index (listing, ignore rules, abs/rel, blobs, root hook, failing hooks); git grep, per-repository HEADs, clean baselines, note commits and TTL pruning; the CLI with and without `CODE_TOUR_CONFIG`; worktree index and
shared store; review with and without the hook; saved relocation, explicit overrides,
worktree preference, canonical recording and fallback after the worktree is removed.
