# code-tour.nvim specification

Behavior reference for the plugin, CLI and tour format. For install and quick start see the [README](README.md); for the agent workflow see the [authoring skill](skills/code-tour/SKILL.md).

## Rendering

An RPC code tour for Neovim 0.11+ driven by Claude or Codex (Herdr is optional). Tours own a separate tab and source window. Every prepared snippet in the current source file has a dim code highlight; the focused code uses the stronger selection highlight. Only the focused explanation box is shown as virtual rows above its code. Inactive snippets have no explanation boxes. Notes wrap to at most 100 columns and align to code indentation, reducing indentation when necessary to leave 40 columns for the frame. Explanation boxes describe general behavior; examples appear only as source-line annotations. Q&A and shortcut hints belong to the focused box. Blank virtual rows surround the frame.

Each render clears the tour namespace from every buffer, restores the muted highlights for all prepared snippets in the active file, and draws the focused frame as one `virt_lines` decoration. Removed diff lines at that anchor follow its frame. Source lines use `CodeTourFocus` for the active part and `CodeTourStop` for the remaining prepared ranges. Decorations are scoped to the tour window, so other views of the same buffer stay clear. Switching files highlights that file's snippets and shows only its selected explanation. Source text, modified state and `changedtick` stay unchanged.

Navigation centers the focused code plus its virtual rows. When that span cannot fit, the viewport starts at the focused line with `topfill` showing the virtual rows above it. Snacks owns the scrolling animation; without Snacks navigation positions the source immediately. Every displayed shortcut hint includes its action, including `af text view` for opening selectable explanation text. Narrow frames show fewer hints while retaining action labels.

## Setup and naming

The CLI needs only Python 3; it speaks Neovim's MessagePack-RPC with a small built-in codec, so no packages are required. Add the plugin to runtimepath and call `require("code-tour").setup()`.

The plugin, Lua namespace, CLI and authoring skill are named `code-tour`; editor commands use `CodeTour` (for example, `:CodeTourLoad` and `:CodeTourExpand`). `require("tour")` remains a public entry point. The former `require("code-walkthrough")`, CLI path and installed `scripts/walkthrough.py` paths forward to code-tour so existing reply commands still work. `:CodeTourLoad` reads `.nvim/code-tour.json`, with `.nvim/walkthrough.json` as a fallback for saved tours. The skill installer migrates the active skill directory to `code-tour` and preserves previous files as backups.

## CLI and tour payload

```sh
# JSON list on stdin, a prepared file, or quick ranges:
bin/code-tour --file /tmp/tour.json
bin/code-tour src/main.lua:10-18
bin/code-tour --append --file /tmp/more.json
bin/code-tour --review --base HEAD~1 --file /tmp/tour.json

# Respond using the exact command supplied by the editor:
bin/code-tour --answer 1.2 --pane /path/to/nvim.sock < /tmp/answer.md
bin/code-tour --fill REQUEST_ID --pane /path/to/nvim.sock < /tmp/definition.json
```

`show`, `answer`, and `fill` are also accepted as subcommands. A stop has `file,start,end,title,note`, optional `parts:[{start,end,note}]`, `example:{input,output,values}`, and `old` (the replaced text for review). Start/end are inclusive current line numbers. Parts must cover the snippet without gaps. Values map absolute line numbers to text or `{value,detail}` and appear at line ends. Example input/output are context metadata for questions and definition requests; they are not shown in explanation boxes. `examples` aliases `example`. Existing version-1 `snippets/sections` files still load with `:CodeTourLoad`.

## Calls and routes

Any stop or part can have `calls`, a list of callee stops. Mark prepared callees on the tour's intended path with `next:true` and a `level`. Their call expressions get gold badges (`CodeTourNextCall`) and their lines get a gold `<- next snippet` label (`CodeTourNextLabel`). `aj` follows them automatically: `A overview → A part 1 → A part 2 → B overview → B parts → A part 3`. Finishing B continues at A's following part, or the next main snippet when no parts remain. Several gold calls in a box run in authored order, and nested gold calls work recursively. A gold call must be prepared; `lazy:true` with `next:true` is rejected. For example, attach `calls:[{file:"src/process.lua",start:20,end:28,note:"Compute the response.",next:true,level:0,callsite:{start:14,end:14,symbol:"process"}}]` to the caller part containing line 14. Do not duplicate B as a top-level snippet.

Other prepared callees keep red source badges and remain optional: `aj` steps over them. Place the cursor on B() and use `ad` to inspect B; completing an optional B returns to the exact snippet and explanation box you entered from. Use `aj` to continue afterwards. An optional branch may contain its own gold route. `ad` also enters gold calls, whose completion continues at their authored following part. `ao` (out), or `ak` at a method's overview, returns early to the saved caller box for either color. The call stack saves actual entry positions, including entry from an overview. There are no separate call-site stops or explanation boxes.

Each callee should include `callsite:{start,end,symbol}` using inclusive CALLER line numbers and the full invoked expression, such as `handlerstack.bubbleEvent`. Optional `start_col,end_col` identify an exact expression using zero-based byte columns, end exclusive. Calls must be attached to the part containing those lines; overview-level calls are reassigned to a containing part when possible. Older tours can infer a callsite when the callee title names a matching invocation. Optional calls use the red `CodeTourCall` badge. No additional explanation, header, frame or hint rows are drawn. The current part keeps its explanation and Q&A.

Use a call descriptor such as `{"file":"src/helper.lua","start":20,"end":30,"title":"helper","callsite":{"start":14,"end":14,"symbol":"helper"},"lazy":true}` to defer its explanation. Omit its note, parts and nested calls. Unexpanded calls and pending generation have no badges. `<leader>ad` is the single inspect key: enter an existing explanation, or request a missing one and enter once ready. A source identifier under the cursor takes priority over unrelated attached calls, including class references such as `extends KeyHandlerMode` with no call parentheses. Once its explanation is prepared, that class reference gets its own red badge. With no symbol selected, several attached calls offer a picker. If the reader navigates away or starts typing, a reply leaves their current location in place and is available for a later `ad`. Completed explanations are reused, and failed/cancelled requests can be retried. `ao` returns from a method; `ak` revisits the preceding explanation with its badges. There are no `ai`, `au` or `aU` mappings.

When `ad` cannot resolve a definition through LSP (or local Tree-sitter lookup when no LSP is available), it sends the symbol, qualified call expression, source path/line, nearby code, current explanation and project root to the originating agent. The agent finds the implementation and returns its explanation through the supplied fill command. No call-site explanation or badge is added while the request is pending. Repeated `ad` reuses the pending request; late lookup callbacks are ignored after navigation, cancellation or source changes. If the implementation cannot be found, the agent can return `{"unresolved":"reason"}` through that fill command. The reader stays in the caller, receives the reason, and can retry without a fabricated definition.

Inspection, lazy generation, questions and explanation requests show a brief informational notification as soon as the action starts. Composer actions announce that input is being opened; generation starts are announced on submission. Repeated requests report that the explanation is already in progress.

The authoring skill chooses depth from the reader's request: an overview prepares no callee layers, normal detail prepares at most one important layer, and deep detail prepares two or three relevant layers or the requested depth. Familiar APIs, obvious helpers, recursion and details beyond that depth remain lazy. Expanding one method normally leaves its deeper calls lazy. Calls without available source are summarized in their caller rather than given invented locations.

## Boxes, counters and instance selection

Boxes have IDs `S.K`: overview/whole snippet `S.1`, then parts `S.2`, `S.3`, etc. Each box keeps its own Q&A. `--answer` without an ID works only when exactly one box has pending questions. Repeated questions for one box are answered in submission order. Questions and fills retain object identities through insertions. Replacing or quitting the tour cancels pending responses.

The header shows `Snippet X/total main snippets · Title`, stripping a redundant numbered title prefix. Only top-level snippets count: subparts, nested method branches and pending/lazy entries do not add to this total. Entering a method retains its owning main snippet's position. `an/ap` moves between main snippets, and the picker lists method branches indented beneath them. Subexplanation headers separately show `Part X/total parts`, starting at 1 to match the left-hand markers; the overview is excluded from this part count. `Page X/Y` appears only when there is more than one page. Request/outline IDs still use stable storage positions and are separate from the visible main-snippet counter.

Selection order: explicit `--pane`, editor remembered for the Claude/Codex session, sole editor in the workspace, closest editor cwd enclosing the files, then a new Herdr tab running Neovim. Several editors in the workspace produce exit 2 with choices, so the agent can ask the user. `--list` lists registered instances. Pane selectors accept Herdr pane IDs, `session/pane`, and socket paths. RPC addresses and editor identity are registered on setup and cwd changes, and checked live. Authoring conversations are recorded independently from the chosen editor.

## Questions and explanations

Questions and explanation requests return to the authoring agent through the configured agent backend (see Configuration). The composer offers stay, follow, and add (paste without sending). The exact `--answer S.K --pane P` command accompanies the box note, code/selection, example and thread. `<leader>ae` adds an explanation for selected code; `<leader>aE` opens a multiline box for extra context first. Without a visual selection, they explain the current box or cursor line. Both work in any source file while a tour is active. Selections inside a snippet get new explanation boxes at the containing box; other selections get new stops in source order. The request captures the selection and stable insertion target, so concurrent fills retain their places. `:CodeTourDefinition` separately uses LSP definitions or same-file Tree-sitter name lookup.

Examples are opt-in and continue through connected snippets, refinements and callee expansions once requested. The agent chooses a concrete method/snippet input and returns context metadata in `example.input` and `example.output`, with `example.values` for every executed assignment, computed expression, call result, branch decision, state change and return statement. A result is still output when the input stays unchanged or a return simply forwards another call's result. For `return this.bubbleEvent(type, event);`, show the recursive call's result and the returned value. Actual `false`, `0`, `""`, `null` and `undefined` results must be shown. Skip scaffolding, comments, blank lines and operations with neither a useful result nor an observable effect; never write `unchanged`. Untaken branches are labeled as not reached, or demonstrated with clearly labeled alternate inputs and results. The renderer hides blank labels and legacy `unchanged` annotations. Example data survives fills, but never appears in explanation boxes or the text-only explanation view. New tours without an example request omit examples.

Overviews stay concise. Subpart notes explain the mechanism in more detail: the incoming data/state, how operations and conditions work together, why checks exist, and the result or control flow passed onward. They describe general behavior rather than tracing a particular example, with detail scaled to the code's complexity.

Explanation requests send only the selected code or a small call-site neighborhood, the relevant box note/ID, requested extra context, nearby example values and the exact `--fill ID --pane P --tour TOKEN` command. They do not resend the full tour outline or unrelated explanation notes. Definition requests give a source location for the agent to read on demand. The full placement snapshot stays inside Neovim, so compact requests still retain stable reply placement through concurrent insertions. Default fill adds the selected range at its saved location; nested calls may use other files. Definition requests replace their call-site placeholder or refine their target box. Advanced `--after N` and `--into N.K` (`--int`) still resolve against the saved snapshot; use only IDs explicitly supplied for that request. Selection/refinement fills visit their result unless the user is typing; inspected call fills enter only while the reader is still waiting at the caller. Answers update their original thread without moving the reader.

## Review diffs

Ask for a diff in the `<leader>aE` context, such as “Explain the diff against HEAD.” The agent returns its explanation using `--fill ID --review`, adding `--base REF` when a different Git base is requested. Diff data survives fills into an existing snippet and updates only the requested range. `:CodeTourReview [REF]` also enables diffs directly for the existing tour without an agent request.

Review uses `git show REF:path` (HEAD by default) or a stop's explicit `old` text. Added source lines use green backgrounds and removed text appears as red virtual lines. Both use a stronger intensity inside the focused subpart and a muted intensity elsewhere. Removed lines in a replacement hunk track their corresponding current lines, so focus can shade different removed rows within one hunk. The highlight groups are `CodeTourDiffAddFocus`, `CodeTourDiffAdd`, `CodeTourDiffDeleteFocus` and `CodeTourDiffDelete`. Unchanged focused code uses blue (`#314888`), with a quieter blue (`#273668`) for the rest of the snippet. Normal source text colors are preserved. Review never opens a diff split or edits source.

## Keys and commands

| Key | Action |
| --- | --- |
| `<leader>ah` | Show/hide boxes |
| `<leader>aj` / `ak` | Next/previous explanation; follow gold calls, step over red calls |
| `<leader>an` / `ap` | Next/previous snippet |
| `<leader>al` | Snippet picker |
| `<leader>a]` / `a[` | Page note, then Q&A |
| `<leader>ar` | Ask about box or selected lines |
| `<leader>ae` | Add explanation for selection/current code |
| `<leader>aE` | Add explanation with extra context |
| `<leader>ad` | Inspect a call: enter its explanation or generate it lazily |
| `<leader>ao` | Return to the original caller explanation (`out`) |
| `<leader>az` | Recenter focused code |
| `<leader>af` | Open/close a centered, text-only explanation view |
| `<leader>aq` | Quit and cancel pending requests |

Composer: Ctrl-S stay/submit context, Ctrl-F follow, Ctrl-A add without sending, Ctrl-B save draft, Escape normal mode, q close. Question and explanation-context drafts are separate. Virtual rows are not selectable source text; `<leader>af` opens the full note and Q&A as plain text in a centered view, without examples, the inline frame or shortcut hints. It supports visual selection and yank, tracks box navigation, and q/Escape returns to source. Commands include `CodeTourLoad [path]`, `CodeTourAsk [question]`, `CodeTourExplain`, `CodeTourExplainContext`, `CodeTourDefinition`, `CodeTourExpand`, `CodeTourReturn`, `CodeTourReview [REF]`, `CodeTourList`, `CodeTourToggle`, `CodeTourFocus`, `CodeTourRecenter`, `CodeTourCancel`, and `CodeTourStop`.

## Configuration

All options are passed to `require("code-tour").setup(opts)`:

| Option | Default | Meaning |
| --- | --- | --- |
| `agent` | `"herdr"` | How the editor sends prompts back to the agent: `"herdr"`, `"auto"`, `"clipboard"` or `{ send = fn }` |
| `keys` | see below | Key mappings; `false` for no mappings |
| `badge` | `{ padding = 0, rounded = true }` | Call badges: padding cells inside each end, and rounded end caps (Powerline glyphs, so a Nerd Font; `rounded = false` without one). |
| `tree` | `"float"` | Where `:CodeTourTree` and `<leader>at` show the tour outline: `"float"` (floating window) or `"tab"` (a tab of its own). `:CodeTourTree float\|tab` overrides it once. |
| `page_lines` | `18` | Upper page budget for explanation boxes |
| `smooth_scroll` | `true` | Animate navigation (needs Snacks) |
| `saved_batch_size` | `12` | Boxes per regeneration request for a reopened saved tour |
| `saved_batch_chars` | `40000` | Approximate captured-code characters per regeneration batch |
| `saved_request_timeout_ms` | `300000` | Timeout per regeneration batch |
| `saved_reuse_unverified` | `true` | Reuse unverified authored prose while its saved code is unchanged |

### Agent backends

The agent-to-editor direction (showing a tour, answering, filling) is plain RPC and needs no multiplexer. `agent` only controls the editor-to-agent direction: questions, "explain this" requests and lazy definitions.

- `"herdr"` (default): delivers the prompt to the authoring agent's pane (stay, follow or paste), checks that the conversation is still live, and starts an agent in a new tab when none is connected. Needs the `herdr` binary (`HERDR_BIN_PATH` overrides it).
- `"auto"`: `"herdr"` when the tour was authored under Herdr or `HERDR_SESSION` is set, otherwise `"clipboard"`.
- `"clipboard"`: copies the prompt (including the exact reply command) to the `+` and `"` registers and tells you to paste it into your agent. The reply still arrives through the CLI.
- `{ send = function(text, action, done) ... end }`: your own transport. `action` is `"stay"`, `"follow"` or `"add"`; call `done(true)` or `done(false, "reason")`. For example, with tmux:

```lua
agent = {
  send = function(text, action, done)
    vim.system({ "tmux", "send-keys", "-t", "agent-pane", "-l", text }, {}, function(r)
      done(r.code == 0, r.stderr)
    end)
  end,
}
```

### Keys

`keys` maps an action to a left-hand side; set an action to `false` to leave it unmapped, or set `keys = false` to define none. Actions marked * also work on a visual selection. Unknown action names are an error. On-screen hints follow your mappings (a leading `<leader>` is omitted from them).

| Action | Default | Action | Default |
| --- | --- | --- | --- |
| `toggle` | `<leader>ah` | `inspect` | `<leader>ad` |
| `next` | `<leader>aj` | `back` | `<leader>ao` |
| `prev` | `<leader>ak` | `text_view` | `<leader>af` |
| `next_snippet` | `<leader>an` | `stop` | `<leader>aq` |
| `prev_snippet` | `<leader>ap` | `recenter` | `<leader>az` |
| `list` | `<leader>al` | `zoom_out` | `<leader>a-` |
| `ask`* | `<leader>ar` | `zoom_in` | `<leader>a+` |
| `explain`* | `<leader>ae` | `page_next` | `<leader>a]` |
| `explain_context`* | `<leader>aE` | `page_prev` | `<leader>a[` |
| `tree` | `<leader>at` | | |

```lua
opts = { keys = { next = "<C-j>", prev = "<C-k>", stop = "<leader>tq", zoom_in = false } }
```

## Saved tours

Saved tours live in a central library for the current Neovim profile. Save, list and open are explicit operations:

```sh
bin/code-tour saved save --title 'Authentication'
bin/code-tour saved list --limit 5
bin/code-tour saved open TOUR_ID --pane SOCKET
bin/code-tour saved save --overwrite TOUR_ID --revision REVISION
```

Every ordinary save creates a distinct entry. Titles may repeat; use the stable ID to open or overwrite. Listing returns `{tours, issues}` with IDs, titles, UTC save times, repository labels/roots and exact-file SHA-256 revisions, sorted by most recent explicit save then ID. It reads JSON using Python's standard library and needs no editor, MessagePack, Herdr or source access. A missing library returns an empty list without creating it. Malformed and unsupported entries are reported individually.

The library is `stdpath("data")/code-tour/tours`, normally `~/.local/share/nvim/code-tour/tours`. The CLI resolves `XDG_DATA_HOME` and `NVIM_APPNAME` to the same directory; editor-bound operations reject a profile/path mismatch. Records contain nested prepared overviews, ordered parts and prepared callees with independent source evidence and caller locators. They omit Q&A, examples, values, lazy branches, unfinished placeholders, historical source/diffs and conversation addresses. Save reports unfinished branches it omitted. Standalone author payloads and review explanations are saved as unverified; measuring current code during save cannot establish their generation inputs.

Opening checks each box against current buffer contents, including unsaved edits. Verified matching syntax reuses its prose. Authored prose saved without host evidence is also reused while its saved code is unchanged (same syntax-token digest, or identical file bytes for parserless sources); it stays labelled unverified in the record and is withheld as soon as that code is edited (`saved_reuse_unverified = true`). Review-derived prose, parserless replies and notes that were already withheld at save time are never reused this way. Every remaining changed or unverified box queues for regeneration by the agent opening the tour. Queued boxes are sent in batches of up to `saved_batch_size = 12` boxes and roughly `saved_batch_chars = 40000` characters of captured code per request (always at least one box); a batch reply names each box and is validated per box, so a bad or missing stop fails only that box. Requests run one batch at a time, with the existing loading presentation and a default five-minute timeout per batch (`saved_request_timeout_ms = 300000`). Delivery errors, invalid replies and timeouts allow other queued targets to continue. Stale text and its Q&A are withheld in inline frames, the selectable view and question context. Replies are checked against captured source; harmless formatting/relocation can be accepted, while a meaningful edit requires explicit retry with the existing explain-current-box action (`<leader>ae`). Editing a ready box also makes it unavailable until explicitly regenerated. Cancelling, stopping or replacing the tour cancels its queue and timers.

Use repeatable `--repo REPO_ID /current/root` and `--map-file REPO_ID old/path.lua new/path.lua` on `saved open` to reassociate moved repositories and renamed files. These mappings affect the live tour only. Missing or ambiguous targets are reported independently; usable descendants remain accessible through the snippet picker. If no target resolves, opening preserves the active tour. Caller attachments are checked separately, so an invalid caller cannot restore an obsolete badge or automatic continuation.

Reusable syntax needs an installed Tree-sitter parser with the same compatibility tag. The matcher retains structure, identifiers, operators, literal values and comment text, ignoring coordinates and nonsemantic formatting. Byte ranges distinguish statements joined onto one line. Duplicate matches and unusable anchors remain unresolved rather than choosing a nearby line. Unsupported or partial-token selections can be freshly explained from exact text but remain unverified for future reuse. An unchanged selected snippet does not certify unchanged behavior in its dependencies or surrounding code.

Opening, remapping, source edits and generation replies never write the library. Explicit overwrite checks the supplied revision under a per-entry lock and atomically replaces the JSON. Without `--revision`, overwrite can use the revision retained when that same ID was opened. A conflict or busy lock is reported without automatic retry; inspect the entry or stale lock before another explicit operation. A refreshed live tour still needs an explicit save.

## RPC API

RPC API (both `require("tour")` and `require("code-tour")`):

```lua
show(stops, { root = "/project", append = false, review = true, base = "HEAD", origin = origin })
answer(markdown, "1.2")
fill(request_id, stops, { after = 2 }) -- or { into = "1.2" }
fill(request_id, stops, { review = true, base = "HEAD" })
save_saved({ title = "Authentication" })
open_saved(id, { origin = origin, repositories = { app = "/project" } })
```

## Skill and installation

The Claude/Codex [authoring skill](skills/code-tour/SKILL.md) documents the complete payload and response workflows. Its small wrapper runs the installed CLI; set `CODE_TOUR_CLI` for a different installation path.

`python3 scripts/install_skills.py` updates the existing shared, Claude and Codex skill directories, backing up changed files. Restart Neovim after updating an already loaded plugin. Response commands include `--tour TOKEN` so a late answer cannot enter a replacement tour.

## Tests

Checks (temporary local sockets need permission in restricted sandboxes; no live model calls):

```sh
XDG_STATE_HOME=/tmp/code-tour-tests nvim --clean --headless -l tests/run.lua
nvim --clean --headless -l tests/scroll.lua
nvim --clean --headless -l tests/review.lua
nvim --clean --headless -l tests/conversation.lua
nvim --clean --headless -l tests/selection.lua
nvim --clean --headless -l tests/render.lua
nvim --clean --headless -l tests/inactive.lua
nvim --clean --headless -l tests/count.lua
nvim --clean --headless -l tests/lookup.lua
nvim --clean --headless -l tests/diff.lua
nvim --clean --headless -l tests/diff_fuzz.lua   # properties over random diffs; DIFF_FUZZ_SEED, DIFF_FUZZ_CASES, DIFF_FUZZ_REPLIES
nvim --clean --headless -l tests/saved_batch.lua
nvim --clean --headless -l tests/branches.lua
nvim --clean --headless -l tests/tree.lua
nvim --clean --headless -l tests/calls.lua
nvim --clean --headless -l tests/next.lua
nvim --clean --headless -l tests/outputs.lua
nvim --clean --headless -l tests/context.lua
nvim --clean --headless -i NONE -l tests/source.lua
nvim --clean --headless -i NONE -l tests/library.lua
nvim --clean --headless -i NONE -l tests/saved.lua
nvim --clean --headless -l tests/ast_extract.lua
nvim --clean --headless -l tests/ast_resolve.lua
nvim --clean --headless -l tests/ast_regions.lua
nvim --clean --headless -l tests/ast_route.lua
nvim --clean --headless -l tests/ast_project.lua
nvim --clean --headless -l tests/ast_fill.lua
nvim --clean --headless -l tests/ast_stream.lua
nvim --clean --headless -l tests/ast_expand.lua
nvim --clean --headless -l tests/ast_detail.lua
nvim --clean --headless -l tests/ast_render.lua
nvim --clean --headless -l tests/ast_live.lua
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_library_cli.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/test_cli.py
```

The `ast_*` tests, `CodeGraphTests`, `AstDryRunTests` and `AstTourTests` in `test_cli.py` copy `tests/fixtures/java/` into a temporary git repository and use an isolated parse cache. Without the Java parser they print a verification gap; without graphify the merge check is skipped (`GRAPHIFY_PYTHON` names graphify's interpreter when it is not found from the `graphify` launcher).

The scroll test uses the local Lazy installation of Snacks. `page_lines = 18` controls the upper page budget and `smooth_scroll = false` skips animated tour navigation. Animation timing remains under Snacks configuration.

The saved tests use isolated temporary data/state/cache roots and stub agent delivery. Source tests read installed Lua, Python and JavaScript parsers, printing any missing parser as a verification gap. Set `CODE_TOUR_PARSER_RUNTIME` to the directory containing `parser/` when it differs from `~/.local/share/nvim/site`. No test calls a live model.

## Tour graph

`:CodeTourGraph` (or `code-tour graph`) writes the active tour as NetworkX node-link JSON, the shape graphify uses, in `$TMPDIR/code-tour-UID/`. Nodes are snippets (identical ranges merge, boxes are attributes with their stale status); links are `next` (reading route), `optional` (red callees) and `overlaps`. Stale-explanation reports are computed from this graph. It is a projection of the tour; the saved tour format is unchanged.

`code-tour codegraph [--project DIR] [--out PATH] [--pane P]` writes the project's symbol graph (SPEC-ast-graph.md §15, phase 1 of that proposal): Java types, methods, constructors and fields as nodes; `contains`, `method`, `field`, `inherits`, `implements`, `imports`, `references` and `overrides` links; and one `calls` link per call site, keyed by site id, with its badge text, columns, confidence and `via`. Without `--pane` it runs headless Neovim (`CODE_TOUR_NVIM` overrides the binary); with one, the editor's unsaved buffers count. The default output is `$TMPDIR/code-tour-UID/codegraph.json`; the RPC is `require("code-tour").code_graph({root, out})`. Parsed facts are cached by git blob SHA under `stdpath("cache")/code-tour/ast/`.

`code-tour ast ENTRY… --dry-run [--detail D] [--through SYMBOL]… [--json] [--project DIR] [--pane P]` (phase 2 of SPEC-ast-graph.md) builds an AST-backed tour for Java entries (`Type#method`, `Type#method(Params)`, `Type.method`, a type, or `path:line`) and prints its outline (§9.2) without opening anything: each snippet with its regions (§7) and their sites by mode (`walk`, `optional`, `lazy`, `ref`, `accessor`, `unresolved`), plus `sink:`, `gap:` and `fork:` lines for the main flow (§8.3). `--json` prints the derived tour (§3.6) instead. The RPC is `require("code-tour").ast_outline({entries, root, detail, through})`; options `ast.detail`, `ast.rating_bands`, `ast.cutoffs` and `ast.main_cap` apply.

Without `--dry-run` (phase 3), `code-tour ast ENTRY… [--detail D] [--through S] [--pane P]` opens the tour in the editor (RPC `ast_tour`) and prints the outline; its header carries the tour token and the fill command. The whole skeleton appears at once: each snippet is a stop (`anchor = "n1"`), its regions nested parts (`n1.r2`), main-flow calls gold `next` calls with `level` = effective rating and a `CodeTourMainCall` ★ badge, other routed callees optional calls, lazy sites lazy calls with their reason, and main-flow gaps a `CodeTourGap` badge with the reason. Boxes without a fresh note read "Being written…". `code-tour --fill nK --tour T --pane P [--detail D] [--model M]` takes Markdown on stdin, one `## overview` / `## rK` / `## nK rK` section per box (first paragraph the gist, the rest the body), or JSON `{"rK": {"gist", "body"}}`; boxes re-render in place and the reader is not moved; a snippet whose source changed is refused. `ad` on a lazy AST call builds the target's snippet in place, enters it and sends `[code-tour ast] nK …` unless every box is already written; `ae`/`aE` inside an AST snippet maps the selection to a region (splitting a leaf region when the selection covers only some of its statements) and sends `[code-tour explain]` for it. `:CodeTourDetail {detail}` or `code-tour adjust --tour T --detail D` changes the detail of the live tour without re-rating: extras enter or leave, boxes refine or coarsen, each box shows its body for the new level or the nearest one (marked with its level), and only boxes never written at that level are requested. `:CodeTourAst [entry] [detail]` builds a tour from the editor (default entry: the cursor's method) and sends the outline to the agent. `:CodeTourTree` shows snippet gists once they exist. Notes are kept in memory for the editor session until the note store (phase 4) exists.

`:CodeTourTree [float|tab]` (`<leader>at`) draws the graph in the terminal (`lua/code-tour/tree.lua`): every snippet is a box with its title, `file:lines` and part count. Top-level snippets run down the left, joined by `▼`, and a snippet's calls branch off it as indented boxes (`├─▶` gold route, `┄○` optional). `●` marks the snippet you are in, `…` one not explained yet, and `↺` a snippet already drawn, so recursion cannot loop. `<CR>` on any box jumps to that snippet (a call opens like `ad`), `q` or `<Esc>` closes, and pressing the key again toggles it. It reads the graph and never changes the tour.

## Graph-driven navigation

`aj`/`ak` follow the tour graph depth-first (`lua/code-tour/walk.lua`). The tour is a directed graph and may contain cycles (recursion); the walk is a spanning tree of it, so each snippet is shown once and reading cannot loop.

- Only gold (`next`) calls are walked automatically, in authored order. Optional (red) calls stay the reader's to open with `ad`; finishing one returns to the box it was opened from.
- Every gold branch, the last included, ends with a return to the calling box before the walk goes on to the next branch, the box's following part, or out of the snippet. Moving between top-level snippets is not a call and has no return. The run of returns at the very end of the tour is dropped, so the walk (and the snippet counter) ends on the last snippet reached, not on a caller with a lower number.
- A gold call back to a snippet already on the path (recursion or a loop) or to one already walked (a shared callee) is a reference: it is never walked. No marking is needed; `"ref": true` only forces it. Lazy snippets are skipped until explained.
- The gold call `aj` takes next is highlighted in its own colour (green); other gold calls keep the gold badge, labelled "later snippet". Several calls on one line are separate edges, each with its own columns.
- Walking back (`ak`) retraces the same steps, including the returns.
- The header numbers snippets in the order the walk first reaches them ("Snippet 10/34"); `an`/`ap` follow the same route as `aj` but one stop per snippet: a snippet's parts are skipped, while the returns to a calling snippet between branches are kept. The `al` picker uses the numbering order. A branch you opened yourself with `ad` reads "Snippet N/34 · optional", where N is the walked snippet it hangs off. With `walk = false` the older count of top-level snippets is used.
- The CLI hands the tour to the editor as a file path, because msgpack-RPC drops requests nested more than about 32 levels deep, which a long chain of nested calls exceeds.

## Parts tree and route summary

Parts nest: a part may carry its own `parts`, each level covering its parent. `stop.parts` stays the depth-first flat list (so box ids `S.K` and `aj` are unchanged); each part records `_parent_part` and `_depth`, the header shows paths like `Part 2.1 (4/9)` for nested snippets, and graph boxes carry `parent`/`depth`. `show` returns `route = {snippets, boxes, optional, lazy, broken, refs}` so an agent can prune to a requested level of detail while keeping the end-to-end path: `broken` lists gold calls hanging below calls that are not walked.

## Streaming a tour

An end-to-end tour can be shown before it is fully written. Mark snippets and calls `pending:true` (file, range, title and, for calls, `callsite`/`next`/`level` as usual; no note, parts or nested calls). They sit on the route as placeholders reading "Being written…", and `show` returns `pending: [{id, file, start, end, title, command}]` in walk order. The agent fills each one with the `command` it was given (`code-tour --fill ID ...`), in walk order. A fill may itself contain `pending` calls, which come back in the fill result, so the tour grows one layer at a time. The reader who is standing on a placeholder when its fill arrives lands on the finished snippet; a reader elsewhere is not moved. The gold and level marks of a placeholder carry over to its fill. Fill in walk order and add only below the reader's position, so the route never changes behind them.

## Zoom

`<leader>a-` / `<leader>a+` (`:CodeTourZoomOut` / `:CodeTourZoomIn`) fold or unfold the walk by level, using only what is already authored; no agent is involved. Every gold call (`next:true`) must carry a `level`, a non-negative integer; a tour with a gold call and no level is rejected. Optional calls have no level. Top-level snippets are level 0 and never fold, and a call with `level:0` is part of the essential path at any zoom. Gold calls above the zoom level are folded: they are not walked (they behave like optional ones, still openable with `ad`), they are drawn in a dim colour labelled "folded (a+ to open)", and the header adds "+N folded". Zooming out while standing inside a branch that folds moves the reader to the nearest snippet still on the walk. A new tour starts unfolded. `show` reports `route.levels` (the deepest level) and `route.shadowed`, the calls whose level is below the snippet they hang off, which fold with it and so are not really on the essential path. A call may carry `why`, a short reason it was skipped (for example "logging helper"), shown next to it in the `ad` picker.
