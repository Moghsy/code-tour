# code-tour.nvim

Interactive code tours in Neovim, written by Claude or Codex. The agent picks the snippets and explains them. You step through them in the editor, ask questions about any box, and save the tour to replay later.

- Dim highlights mark every prepared snippet. The focused one gets a stronger highlight and an explanation box above it.
- `<leader>aj` / `ak` walk the route, following the calls that matter. Calls you can skip are marked, and you can open them with `<leader>ad`.
- `<leader>ar` asks about a box. `<leader>ae` explains any selected code. Replies land in the tour.
- Review mode shows a git diff with its explanation. Saved tours are revalidated against your current code.

## Requirements

- Neovim 0.11+
- Python 3 with `msgpack` (`python3-msgpack` on Debian/Ubuntu)
- Claude Code or Codex running in Herdr for the agent side
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
| `<leader>ad` | Open a skipped call |
| `<leader>ao` | Return to the caller |
| `<leader>ar` | Ask about the box or selection |
| `<leader>ae` / `aE` | Explain selection (with extra context) |
| `<leader>af` | Text-only view of the explanation |
| `<leader>ah` | Show / hide boxes |
| `<leader>aq` | Quit the tour |

The full key list, commands, tour format, saved tours and options are in [SPEC.md](SPEC.md).

## Tests

```sh
XDG_STATE_HOME=/tmp/code-tour-tests nvim --clean --headless -l tests/run.lua
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_cli.py
```

The other test files are listed in [SPEC.md](SPEC.md#tests). No test calls a live model.

## License

[MIT](LICENSE)
