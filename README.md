# code-tour.nvim

Interactive code tours in Neovim, written by Claude or Codex. The agent picks the snippets and explains them. You step through them in the editor, ask questions about any box, and save the tour to replay later.

- Dim highlights mark every prepared snippet. The focused one gets a stronger highlight and an explanation box above it.
- `<leader>aj` / `ak` walk the route, following the calls that matter. Calls you can skip are marked, and you can open them with `<leader>ad`.
- `<leader>ar` asks about a box. `<leader>ae` explains any selected code. Replies land in the tour.
- Review mode shows a git diff with its explanation. Saved tours are revalidated against your current code.

## Requirements

- Neovim 0.11+
- Python 3 (standard library only)
- Claude Code or Codex to write the tours. Herdr is optional and only used for agent-side conveniences.
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for animated scrolling

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "Moghsy/code-tour",
  name = "code-tour.nvim",
  lazy = false,
  opts = {},
}
```

Then install the agent skill, which copies it into your Claude, Codex and shared skill directories:

```sh
python3 ~/.local/share/nvim/lazy/code-tour.nvim/scripts/install_skills.py
```

## Usage

Ask your agent for a tour ("give me a code tour of how auth works"). It uses the `code-tour` skill to send the tour to Neovim. You can also load a file or quick ranges yourself:

```sh
bin/code-tour --file tour.json
bin/code-tour src/main.lua:10-18
```

| Key | Action |
| --- | --- |
| `<leader>aj` / `ak` | Next / previous explanation |
| `<leader>an` / `ap` | Next / previous snippet |
| `<leader>al` | Snippet picker |
| `<leader>at` | Tour diagram in a float (`tree = "tab"` for a tab) |
| `<leader>ad` | Open a skipped call |
| `<leader>ao` | Return to the caller |
| `<leader>ar` | Ask about the box or selection |
| `<leader>ae` / `aE` | Explain selection (with extra context) |
| `<leader>aR` | Regenerate the box's explanation (saved and AST tours) |
| `<leader>a{` / `a}` | Previous / next question in the Q&A thread |
| `<leader>af` | Text-only view of the explanation |
| `<leader>ah` | Show / hide boxes |
| `<leader>aq` | Quit the tour |

## Configuration

```lua
opts = {
  agent = "herdr",  -- "herdr" | "auto" | "clipboard" | { send = function(text, action, done) end }
  keys = {          -- any action; false disables it, `keys = false` disables all
    next = "<leader>aj",
    prev = "<leader>ak",
  },
  page_lines = 18,
  smooth_scroll = true,
}
```

`agent` controls how questions and explain requests get back to your agent. Without Herdr, set `"clipboard"` (or `"auto"`, which falls back to it) to copy the prompt for pasting into the agent. A custom `send` function can use tmux, a terminal API or anything else. Every key action, the agent backends and the remaining options are in [SPEC-old.md](SPEC-old.md#configuration).

The commands, tour format and saved tours are also in [SPEC-old.md](SPEC-old.md). A proposed state-machine view is in [SPEC-state-machine.md](SPEC-state-machine.md), and AST-backed tours (code representation, extraction, routing, streaming) in [SPEC-ast-graph.md](SPEC-ast-graph.md).

## AST-backed tours

AST tours use Neovim's Tree-sitter parsers. Java is enabled by default. Enable Python and TypeScript/JavaScript in Neovim with `ast = { languages = { "java", "python", "typescript" } }` in the plugin setup (`javascript` is another name for `typescript`: one backend serves both). TypeScript and JavaScript need the `typescript` and `tsx` parsers, and their symbols are named by file path, such as `typescript:src.orders.service.OrderService.place`. Use a symbol or a source position to start a tour, or list candidate entry points with `--auto`.

Headless commands (`--dry-run`, `codegraph`, `search`) use the languages your editor was last started with; `CODE_TOUR_AST_LANGUAGES` overrides them.

```sh
code-tour ast 'OrderService#checkout' --detail normal
CODE_TOUR_AST_LANGUAGES=java,python code-tour ast python:shop.order.checkout --dry-run
CODE_TOUR_AST_LANGUAGES=typescript code-tour ast src/server.ts:12 --dry-run
code-tour ast --auto
```

In Neovim, run `:CodeTourAst` at the cursor, `:CodeTourDetail detailed` to change detail, or `:CodeTourHistory` to reopen a recent tour. Fills automatically persist in the repository's `.code-tour/` store and are reused when the source and walked callees still match. Set `ast.store = "user"` in setup to store them under Neovim's data directory. `code-tour store --prune` prunes the current repository's store.

### Projects of several repositories, and their worktrees

For several git repositories under one directory that is not itself a repository, opt in with `workspace` hooks in setup; nothing changes while they are unset. `repos(root)` makes AST tours span the repositories it returns, `repo(path, root)` (for example `require("code-tour.workspace").git_root`) makes review work from that root, `relocate(repo, ctx)` says where a saved tour's repository lives now, and `main(root)` marks a root as a worktree of a main copy: the worktree stays the tour root, uses its own repositories and falls back to the main copy's for the rest, shares the main copy's `.code-tour` notes, and saved tours prefer its copy of each repository. The headless CLI loads the same hooks from a Lua file named by `CODE_TOUR_CONFIG` (returning `{ ast = ..., workspace = ... }`). See `SPEC-workspace.md`.

An agent can inspect the current code with `code-tour explain`, `flow`, `callers`, `impact`, `path`, or `search`. Use `code-tour brief N --tour T` for the code, interfaces, and fill command for one live snippet, and `code-tour --fill N --tour T --model M` to record the model that wrote it.

### How an AST tour is made

The plugin supplies facts and the agent supplies judgement, in three steps:

1. **Understand.** `code-tour codegraph` persists the resolved symbol graph to `.code-tour/graph.json`, reused until a file, the language set or the resolution config changes. `code-tour analyze communities|gods|crossings|neighbors SYMBOL` gives lazy views over it (clusters of related symbols, hub symbols, calls between clusters, callers and callees with their confidence). `code-tour concept add NAME --members …` records a named idea and the symbols that implement it, so later sessions start with that context.
2. **Design the route.** The plugin never decides what matters. The agent names the flow as edges, `code-tour ast ENTRY --route route.json` with `[{"from": "A#a", "to": "B#b", "level": 0}]`, where level 0 is the main walk and 1 to 5 are optional branches. A jump edge (`"kind": "jump"`) goes where the code does not call, such as an API's definition or a range of code in another repository or language. `--walk 'A -> B'` and `--branch 'A -> B@2'` name single edges, and `code-tour adjust` changes a live tour. A call the route does not name is lazy: the reader can open it, but nothing offers it.
3. **Explain.** The agent fills the boxes with `code-tour --fill nK`, using the context it gathered.

Calls are bound by receiver type, never by bare name, so an unknown receiver stays unresolved instead of matching an unrelated method. Members generated at build time (Lombok builders including `@SuperBuilder` and `@Builder` on constructors and static methods, getters, setters, `@With`, `@Singular`, `@Slf4j` loggers and constructors, and Python dataclasses) are synthesized from annotations; add rules for other generators with `ast.synthesizers`, and continue calls the language cannot follow, such as a Lambda invoke, with `ast.boundaries = { { call = "AWSLambda.invoke", to = "OrderHandler#handleRequest" } }`.

When a project test reaches the current snippet, `:CodeTourExample` opens the test as an optional snippet. `:CodeTourRecord` captures locals from the selected Java test if nvim-dap and jdtls are configured with Java Debug and Java Test support. Recording requires project consent. Set `ast.examples.record = false` to disable execution.

## Tests

```sh
XDG_STATE_HOME=/tmp/code-tour-tests nvim --clean --headless -l tests/run.lua
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_cli.py
```

The other test files are listed in [SPEC-old.md](SPEC-old.md#tests). No test calls a live model.

## License

[MIT](LICENSE)
