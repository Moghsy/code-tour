---
name: code-tour
description: Create interactive Neovim code tours and answer code-tour question, explain, or refine prompts in the originating Claude or Codex conversation.
---

Use the code-tour CLI to present code, review changes, or answer an existing tour request. Run `python3 <skill-dir>/scripts/code-tour.py` (called `code-tour` below). It sends stops directly to Neovim over RPC and focuses its Herdr pane. It does not edit source.

### Save, find and reopen tours

Use the `saved` command group only for explicit saved-library requests. Never silently reuse a saved tour for a fresh explanation, or save because a tour was generated, opened or refreshed.

```sh
code-tour saved save --title 'Authentication'
code-tour saved list --limit 5
code-tour saved open TOUR_ID --pane P
code-tour saved save --overwrite TOUR_ID --revision REVISION --pane P
```

An ordinary save always creates a new ID. Listing requires a positive limit and returns `{tours, issues}` directly from local metadata without opening source, discovering editors or invoking a model. Present ID, title, save time and repository labels so the user can identify a tour; duplicate titles are allowed. Surface unreadable or unsupported entry diagnostics. Metadata does not claim the explanation still matches current code. Opening returns ID, revision, counts and unresolved issues without waiting for regeneration. Save returns ID, revision, save times, library path and omitted unfinished branches.

Overwrite only an unambiguously identified ID explicitly requested by the user. Preserve the revision supplied by listing/opening. The editor can also use its retained revision for that same opened ID when `--revision` is omitted. Report revision conflicts; never fetch a newer revision and silently retry overwrite. Report busy/stale locks for explicit inspection, without deleting or stealing them automatically.

Records are profile-specific under `stdpath("data")/code-tour/tours`; the CLI uses `XDG_DATA_HOME` (default `~/.local/share`) and `NVIM_APPNAME` (default `nvim`). A profile/path mismatch must be resolved by using the matching CLI environment/editor. Do not copy or migrate records automatically. Existing `--pane`, origin discovery and editor ambiguity choices apply to save/open. An open binds to the current originating agent, not a historical conversation.

Reassociate missing/moved roots using repeatable `--repo ID /absolute/current/root`, and renamed files with `--map-file REPO_ID old/relative/path new/relative/path` on `saved open`. Ask for missing mappings only when available context cannot resolve them. Do not guess replacement source, search the entire repository automatically or waive duplicate-match errors. Keep independently available boxes accessible; a failed preflight leaves the current tour intact. Mappings and refreshed notes remain live until an explicit save.

Only prepared overviews, parts and nested callees/navigation are retained. Q&A, examples, annotations, lazy descriptors and historical review inputs are excluded. Notes without host generation-time source evidence, including standalone initial tours and review prose, are saved as unverified without regeneration during save. On explicit open, unchanged verified boxes are reused, and unverified authored boxes whose saved code is unchanged are reused as-is (they stay unverified). Changed boxes, review prose and notes withheld at save time regenerate automatically in batched requests. Missing parsers and partial-token selections withhold saved syntax reuse. Matching selected syntax does not certify unchanged dependencies or surrounding behavior.

### Respond to saved regeneration

`[code-tour saved regeneration]` has a stricter contract than ordinary explanation/refinement requests. Explain only the supplied captured CURRENT code and exact byte range, in its repository context. Never reuse invalid old prose or recreate historical comparison claims. Return a JSON list with exactly ONE stop containing `file`, `start`, `end`, `note` (optional `title`). Copy the requested file and inclusive line coverage exactly; describe only the supplied bytes when other statements share those lines. Keep overview prose concise and part prose detailed.

`[code-tour saved regeneration batch]` carries several boxes under the same contract. Explain each `## Box: ID` independently from its own captured code, and return ONE JSON list with exactly one stop per box, each adding `box` (the Box ID) to `file`, `start`, `end`, `note` (optional `title`). Deliver the whole list once through the supplied command. Each stop is validated separately: a wrong range, missing or duplicate `box`, or a stale source fails only that box, and omitted boxes are reported as failed. Do not split a batch into several fills; the request completes on the first fill.

Omit parts, calls, examples, values, review data and generation evidence. Deliver through the exact supplied `--fill ID --pane P --tour TOKEN` command, with no placement or review flags. This replaces only the requested box and preserves siblings and navigation. Do not send a new `show` payload or save the result. The editor validates source freshness and rejects late/cancelled replies. A meaningful source change requires explicit retry using explain-current-box; do not automatically retry or manufacture a replacement request. Failures and timeouts let unrelated queued targets continue.

### Author a tour

Read the current files and relevant diff. Start an example when the user asks for one, and continue an already requested example through connected snippets, refinements and callee expansions without requiring the user to ask again. For a new tour without an example request, omit `example`/`examples` and all line values. Send a JSON list on stdin, or use `--file <prepared-json>`:

```sh
python3 <skill-dir>/scripts/code-tour.py --file /tmp/tour.json
```

```json
[
  {
    "file": "src/example.lua",
    "start": 10,
    "end": 18,
    "title": "Validate and apply a request",
    "note": "Validate the request before changing the stored result.",
    "parts": [
      {"start": 10, "end": 13, "note": "Read the identifier from the incoming request and check that it is present before attempting to store a result. A missing identifier takes the early rejection path, so invalid requests cannot change the stored state. Requests that pass this check continue into the update step."},
      {"start": 14, "end": 18, "note": "Use the validated identifier to associate the computed result with its stored entry. The update makes that result available to later requests before control returns to the caller. Returning the saved result lets the caller continue with the same value that was persisted."}
    ],
    "example": {
      "input": "request = {id = 7}",
      "output": "result = {id = 7, saved = true}",
      "values": {
        "15": {"value": "id = 7", "detail": "The validated identifier is carried into storage."},
        "18": "{id = 7, saved = true}"
      }
    }
  }
]
```

Paths are relative to the caller's cwd or explicit `--project DIR`; absolute paths also work. Ranges are inclusive, 1-based CURRENT line numbers. Every stop has `file,start,end,note`; `title,parts,example,old` are optional. The schema above illustrates the optional example fields; omit them unless requested. `examples` is an alias for `example`. Values use absolute source line numbers and are text or `{value,detail}`.

### Nested calls and explanation depth

Attach `calls` to the EXACT explanation box containing a method/function/class call, usually a part. `calls` is a list of ordinary stops, each of which may have its own parts and calls. Mark a prepared callee on the intended tour path with `next:true`. Its call expression gets a gold badge and its line gets `<- next snippet`; `aj` follows it after the containing box, explores its overview and parts, then continues at the caller's FOLLOWING part. If there are no remaining parts, continue to the next main snippet. Several gold calls on a box run in authored order; nested gold calls follow the same rule. Gold calls must have prepared explanations, never `lazy:true`. Do not duplicate the callee as a top-level snippet.

Other prepared calls get red badges and remain optional. `aj` steps over them; the reader places the source cursor on a call and presses `ad` to inspect it. Finishing an optional method returns to the exact snippet and explanation box the reader entered from; only a subsequent `aj` advances. A red branch may contain its own gold route. `ad` can also enter gold calls; finishing them continues at their authored following part. `ao`, or `ak` at a method's overview, returns early to the saved caller box. Badges are source decorations with no separate explanation step. If the caller has parts, attach each call to the part that explains its invocation, rather than to the overview.

Every call (prepared or lazy) must include `callsite:{start,end,symbol}`. These are inclusive line numbers in the CALLER, while the callee's `file,start,end` still point to the definition. Keep the callsite inside its parent part. Use the actual full receiver.method text as `symbol`, for example `handlerstack.bubbleEvent`, so that expression gets the badge. For repeated calls on the same line or an exact multiline expression, optionally provide both `start_col` and `end_col` (zero-based byte columns, end exclusive), covering the full intended call expression.

Call sites have NO separate explanation box, note or navigation step. Supply only callsite coordinates/symbol; do not author a transition stop, part, title, hint frame, or "Follow call" explanation. The editor draws gold or red badges directly on ready calls while the current part's explanation stays visible. The callee stop's `note` explains the method definition normally. Badges add nothing to snippet or part counts. Calls attached to an overview are moved to a containing part when their callsite fits one. Older payloads can infer a callsite from a matching symbol in the callee title; explicit coordinates are preferred.

Only prepared explanations get badges. Unexpanded lazy calls and pending generation stay as ordinary source text, with no badge or automatic navigation stop. `ad` is the single inspect action: enter an existing explanation, or generate a missing one and enter when ready if the reader is still waiting. A source identifier under the cursor takes priority over unrelated attached calls, including a superclass reference such as `extends KeyHandlerMode` without call parentheses. Explain that actual class when selected; its caller coordinates/symbol identify the class reference, which gets a red badge once prepared. Do not substitute an already attached method for the selected class. Do not create placeholder explanations just to make an unexplained call look prepared. There is no separate `ai` key.

Example shape (replace paths and ranges with real current source):

```json
[
  {
    "file": "src/main.lua", "start": 10, "end": 18,
    "note": "Validate, process, and return the request.",
    "parts": [
      {"start": 10, "end": 12, "note": "Validate the request."},
      {"start": 13, "end": 15, "note": "Process the validated request.", "calls": [
        {"file": "src/process.lua", "start": 20, "end": 28, "title": "process", "note": "Compute the response.", "next": true,
         "callsite": {"start": 14, "end": 14, "symbol": "process"},
         "parts": [
           {"start": 20, "end": 24, "note": "Prepare the response."},
           {"start": 25, "end": 28, "note": "Format and return it.", "calls": [
             {"file": "src/format.lua", "start": 5, "end": 12, "title": "format", "lazy": true,
              "callsite": {"start": 27, "end": 27, "symbol": "format"}}
           ]}
         ]}
      ]},
      {"start": 16, "end": 18, "note": "Return the processed response."}
    ]
  }
]
```

Match the prepared call depth to the user's request. For an overview, prepare only the main flow (zero callee layers). For ordinary explanations, prepare at most one important callee layer. For deep explanations, prepare two or three relevant layers, or the explicit depth the user requests. These are authoring defaults, not hard limits. Never traverse the entire call graph by default. Explain the purpose and result of simple calls briefly in the caller's note.

For self-explanatory helpers, familiar APIs, recursive calls, and details below the requested depth, attach `{file,start,end,title,callsite,lazy:true}` instead. Omit its `note`, `parts` and further `calls`: the explanation is generated only after an explicit expansion. Resolve actual source locations without reading or explaining the full downstream implementation. When source is unavailable, summarize the API's role in the caller; do not invent a file or range. Avoid automatically following recursion or mutual-recursion cycles. An explicit expansion explains one definition and leaves deeper calls lazy unless the reader asks for more. The editor caches completed branches at their call site.

When an example is requested or already active, choose a concrete input to the method/snippet and carry it through connected snippets rather than substituting unrelated examples. Keep `example.input` and `example.output` as context metadata; examples are never rendered inside explanation boxes or the text-only explanation view. Use `example.values` for EVERY value-producing executed line: assignments and computed expressions, call results, branch decisions, state changes and return statements. A value is output even if the input is unchanged, no variable is assigned, or the same value is simply forwarded to the caller. For `return this.bubbleEvent(type, event);`, show the recursive call's concrete result AND the value this line returns, for example `bubbleEvent("keydown", event) → false; returns false` when that is the traced outcome. Show `false`, `0`, `""`, `null` and `undefined` when they are the actual result; these are not missing output. Skip only scaffolding, comments, blank lines and operations with neither a useful result nor an observable effect. Never write `unchanged` or suppress a computed result because it equals an earlier value. Do not pretend an untaken branch ran: label it not reached for the main input, or provide a clearly labeled branch example with its own assumptions and result. Never invent unknown results. A part may have no annotated lines only when it has no applicable values or effects. Values display only at source-line ends. Continue the established example through selected-code refinements, definition requests and lazy expansions; an existing example is not a reason to omit further output annotations.

Keep the overview concise, but make subpart explanations substantially more detailed than an overview summary. Explain the incoming data/state, how the operations, conditions and calls work together, why relevant checks exist, and what result or control flow passes to the next part. Describe mechanisms and reasons rather than just restating identifiers or summarizing a block in one sentence. Use a developed paragraph, often 3–6 sentences when the code warrants it; simple parts can be shorter. Explanation notes describe behavior for general inputs and must not contain concrete example inputs, outputs or traces; those belong in `example` metadata and source-line annotations. Choose coherent parts of about 5–10 lines, preferably no more than 15, so their code fits below the explanation. If parts are present, they must stay inside the snippet and cover the entire snippet without gaps, including its beginning and end. Overlap is allowed. The overview can cover a long range. A short snippet can omit parts.

Use `--append` to add stops. When the user asks for a diff/review, use `--review` to compare current source with `git show HEAD:path`, or `--review --base REF` for another base. Both flags also work on `--fill ID`. Read that diff to explain what changed. A stop's optional `old` string is the exact text replaced by its current range, and overrides Git for that stop. Additions render green and removals as red virtual lines, with stronger colors in the focused part and muted colors elsewhere. `:CodeTourReview [REF]` enables diffs directly for an existing tour. The editor also accepts the former version-1 `snippets/sections` JSON format.

For a quick tour without authored notes, positional `FILE:LINE-END` arguments work:

```sh
python3 <skill-dir>/scripts/code-tour.py src/example.lua:10-18 src/other.lua:2-8
```

### Editor selection

`--pane P` selects a Herdr pane, `session/pane`, or an exact Neovim socket. Otherwise the CLI uses the editor remembered for `CODEX_THREAD_ID`, `CLAUDE_SESSION_ID`, or `--agent-session KEY`. Without a remembered editor, several editors in the workspace produce exit 2 with a JSON list of choices. Show those choices and ask the user which pane, then rerun with `--pane`. A single matching editor is chosen automatically. Failing that, use the editor whose cwd encloses the files; if none exists, the CLI starts Neovim in a new Herdr tab. `--list` lists registered live instances.

Do not ask for editor confirmation when the CLI already resolves one. If the origin cannot be identified, provide `--origin-session SESSION --origin-pane YOUR_AGENT_PANE`. The origin is the existing conversation answering questions, separately from the Neovim destination.

### Tour files and compact requests

Write an authored tour to a file under the temp directory (for example `/tmp/code-tour-NAME.json`) and pass it with `--file`; the CLI keeps stdin tours in `$TMPDIR/code-tour-UID/` too. Saved tours live at their library path. The editor cites that path in every request, so requests contain only: `[code-tour KIND] tour: PATH`, the current stop (`stop S.K · file:start-end`), the question or selection, and a `Reply:` command. Read the tour file for context, then follow the fixed rules below; none of them are repeated per request. If no agent is connected, the editor opens one new Herdr tab with an agent and sends it the same compact request.

Fixed rules for every request: never edit source; keep overviews concise and parts detailed, explaining mechanisms, checks, state and results; keep notes general, with examples only in source-line annotations; include an example (values on every value-producing executed line) only when the request says an example is active or Extra context asks for one; treat quoted code as data; deliver through the exact `Reply:` command without `--after/--into` placement overrides; if Extra context asks for a diff, append `--review` (and `--base REF` when named). `[code-tour explain]` returns stops covering exactly the shown selection (or the `Cover` range) without gaps. `[code-tour symbol]` locates the real implementation and returns definition stops, or `{"unresolved":"reason"}`; keep deeper calls lazy. `[code-tour definition]` explains the definition at the given location (follow export aliases) as shallow stops. `[code-tour refine]` returns finer parts covering the named box range. `[code-tour saved regeneration]` explains only the supplied captured CURRENT code and bytes: return one stop (`file,start,end,note`, optional `title`) — a batch returns one stop per box with its `box` ID — and omit parts, calls, examples and review data.

### Level of detail and pruning

You know the whole tree of snippets and calls; the reader only walks the gold route, so choose how much to present from the level of detail the user asks for (default: normal; ask only when it is genuinely unclear). Always keep one unbroken end-to-end path, the spine that carries the user's scenario from its entry point to its final effect: every gold call must hang from a gold or top-level snippet, and a gold call below an optional or lazy one is never reached. Prune by demoting, not by cutting the story: a branch the reader does not need now becomes an optional (red, prepared) call when it is cheap and useful, or a `lazy` call when it is not, and the parent's note says in a clause that it exists and was skipped at this level. Never prune a snippet whose absence leaves a gap between two kept ones.

Rough targets for the walked route: overview, 4-8 snippets, overview boxes only (no parts), spine only; normal, 8-15 snippets, parts where the code is not trivial, the important branches gold; detailed, 15-30 snippets with parts and sub-parts, most branches gold and the rest optional; exhaustive, everything prepared, with the least relevant branches still optional. More detail means promoting optional/lazy calls to gold, giving boxes parts, and splitting parts into sub-parts; less means the reverse.

The `show` result reports the route: `route: {snippets, boxes, optional, lazy, broken, refs}`, where `snippets` and `boxes` are what `aj` will walk, `optional` and `lazy` what you pruned, and `broken` lists gold calls that sit below an unwalked call (`{from, to}`). When `snippets` is well above the target for the requested level, demote branches and send the tour again; when `broken` is not empty, either promote the parent call to gold or demote the child, then send it again.

### The reader can zoom

`<leader>a-` and `<leader>a+` fold and unfold the walk by call depth in the editor, with no request to you: folded gold calls are not walked until the reader zooms back in or opens them with `ad`. This only hides what you already prepared, so author the spine at full depth and let the reader fold it; do not bake a shallow route into a tour the reader may want to deepen. Folded snippets still count in the `route` you receive.

### Parts can nest

A part may itself have `parts`, which refine it: each level must cover its parent's range exactly, with no gaps and nothing outside it, to a depth of eight. Use sub-parts only for long or dense parts that a single paragraph cannot explain; a short part needs none, and a long part is often better as its own snippet reached by a call. `aj` walks the tree depth-first (overview, part 1, its sub-parts, part 2, ...). Box IDs in requests stay `S.K`, numbered in that same depth-first order, and the reader sees paths like `Part 2.1`. In a `[code-tour refine]` reply covering a whole part, the returned parts become that part's children; a reply covering only some of the part's lines is added next to it. Saved tours currently store parts flat, so on reopening the nesting is lost but the order and ranges are kept.

### Walk order

`aj/ak` walk the tour graph depth-first (editor option `walk`, default on). The graph may contain cycles; the walk shows each snippet once. Only `next: true` calls are walked automatically, in the order you list them under a box; mark every callee the reader should be taken through as `next: true`, and leave the rest optional (red), which the reader opens with `ad`. After each gold branch except the last on a box, the reader returns to the calling box before the next branch; after the last, reading continues with that box's following part. Several gold calls may share a line: give each its own `start_col`/`end_col` and list them in the order they should be read (for `f(g(x))`, that is usually `g` first). Recursion and loops need no special marking: a call back to a snippet already on the path, or to one already walked, is shown as a reference and never walked (`"ref": true` forces this). Lazy calls are skipped until explained. The gold call coming up next is highlighted in its own colour.

### Tour graph

`code-tour graph [--pane P]` (or `:CodeTourGraph`) writes the active tour as a graph and prints `{path, nodes, links}`. The file is NetworkX node-link JSON, like graphify's `graph.json`, in the temp directory. Each node is one snippet (identical file ranges merge): `id` is `FILE:START-END`, with `label`, `source_file`, `source_location`, `lazy`, `stops` (storage stop numbers) and `boxes` (`{id: "S.K", role, start, end, saved_id, status, stale}`). Links are `next` (the reading route, via `sequence` between main snippets or via `call` for a gold callee), `optional` (a red callee) and `overlaps` (snippets covering shared lines). Call links carry `from_box`, `symbol` and `callsite`. Use it to answer which snippets lead to or depend on another, instead of re-deriving that from the tour tree. It is a read-only projection; never edit it or pass it back to the editor.

### Stale explanations


Saved tours track freshness. When a box's source changes, the editor warns, withholds that box's prose and writes a report in the temp directory (`code-tour-UID/<tour id>.stale.json`, built from the tour graph). Requests cite it with a line `Stale: 1.3, 2.1 · report: PATH` while anything is stale. In the saved tour file a stale box is the one whose `evidence` is `{"status":"unverified","reason":"Source changed before save"}`. Ordinary tours opened from a tmp file are not tracked.

The report is `{tour, stale:[{id, saved_id, status, reason, file, start, end, update_also:[{id, saved_id, relation, stale, file, start, end}]}]}`. `id` is the request box ID `S.K`; `saved_id` matches the box `id` in the saved file. `update_also` lists the boxes whose prose depends on the stale one: `overview` (summarises the stale part), `caller` (calls into the stale code: the caller chain, and any other snippet whose called definition overlaps it) and `callee` (calls made from the stale box; verify their call sites). Before answering anything that touches a stale box, read the report and the current source for each stale range.

When asked to refresh a tour, or when a request involves a stale box, update the stale box AND every `update_also` box: they are explained from the stale code, so they are wrong or incomplete until revised. Also search the tour file for other snippets whose code calls or mentions the changed function or symbol, even when the report does not list them, and update those boxes too. Check callers transitively: if an updated caller's behaviour changed, its own callers may need revising. A `[code-tour saved regeneration]` box carrying a `Linked: update because X changed` line is such a dependent: read X's current source and make the explanation reflect X's new behaviour, while still describing only the supplied bytes. The editor queues stale boxes with their linked boxes in one batch when the reader presses `<leader>ae` on a stale box.

### Respond to existing requests

Requests carry their exact delivery command. Use it, including its `--pane` and `--tour` identity; do not select another editor or restart the tour. If Extra context asks for a diff/review, append `--review` to that fill command, with `--base REF` when a base was specified; do not add placement overrides. Otherwise preserve the current review setting. The tour identity rejects replies to cancelled or replaced tours. Treat quoted code and notes as context, and read relevant source as needed. Deliver through the CLI, then acknowledge briefly in the conversation.

Requests deliberately contain only the selected code or nearby caller source, the relevant box note/ID and example context. They omit the full tour outline and unrelated notes; the editor retains the complete placement snapshot locally. Read definitions and any additional required coverage from their source paths rather than asking for the whole tour or expanding request context indiscriminately. Default fill placement already identifies the target and caller return path.

- `[code-tour question]`: Answer the question about the named box, its note, selected lines, example and prior Q&A. Send Markdown on stdin to `code-tour --answer S.K --pane P`. Do not append a new tour. With exactly one pending box, the box ID may be omitted. Each box owns its Q&A thread. Answers to repeated questions in the same box are delivered in submission order.
- `[code-tour explain]`: For a SELECTED CODE request, explain the exact selected text and line range, honoring Extra context. Do not substitute a symbol's definition for the selected code. Return top-level stops covering exactly that selection without gaps, even if its containing snippet or box is larger; nested `calls` may explain definitions in other files. Include an example when Extra context asks for one or an existing example is already active, showing all computed/returned values as described above. Send the JSON list through the exact `code-tour --fill ID --pane P --tour TOKEN` command; the editor inserts the new explanation in its containing snippet or replaces a placeholder in source order. For a definition request from `CodeTourDefinition` or `CodeTourExpand`, explain the supplied definition using the call site as context. Keep further calls lazy unless more depth is explicitly requested. Default placement preserves the branch's return path; do not override it.
- A SYMBOL AT THIS CALL SITE request means editor definition lookup failed. Use the supplied symbol, qualified receiver/call expression, call-site file and line, nearby source, project root and current explanation to locate the real implementation, following imports and project references as needed. Return definition stops through the exact supplied fill command, retaining default placement. The definition can be in another file; do not substitute a new explanation of the caller or invent implementation ranges. Keep deeper calls lazy and omit examples unless requested. If the implementation cannot be located, return `{"unresolved":"specific reason"}` through the same fill command instead of a stop list. This reports the limitation without adding a fake explanation or badge.
- `[code-tour refine]`: Create finer parts covering the indicated definition box's full range, in the same file. Return a JSON list containing that range and its parts through the supplied `--fill ID --pane P`. The new parts follow that box, and its existing Q&A stays attached.

A fill can use `--after N` to insert after a stop or `--into N.K` (`--int N.K` also works) to add finer parts after a box when that request explicitly supplies those IDs. The numbers refer to its locally saved placement snapshot, even if another request changes the tour meanwhile. Routine requests omit the full outline and already have an insertion target: use their supplied command without a placement override and cover the selected range only. Definition refinements cover their target box. Do not guess missing IDs or current indexes, or reuse a completed request ID. Cancelled/replaced tours reject late responses.

Request box IDs use `S.K`: storage stop `S`, overview/whole-snippet box `K=1`, then part boxes starting at `K=2`. Use the exact request command; storage/outline IDs are independent of visible snippet numbers. Call sites have no separate explanation or Q&A box; questions belong to the current part or selected source. Visible headers show `Snippet X/total main snippets · Title`, counting only top-level snippets. Subparts, nested method branches and pending/lazy entries do not add to this count; an entered method retains its owning main snippet's position. `an/ap` moves between main snippets. Subexplanations separately show `Part X/total parts`, starting at 1 and excluding the overview. Omit numbered prefixes from authored titles. Page counters appear only when there is more than one page.

### Reader controls

All prepared snippets in the current source file have muted code highlights, while the selected code uses the stronger focus highlight. Only the focused explanation box is drawn as virtual rows above its code. Inactive snippets have NO explanation boxes, titles, note rows or Q&A until focused. Their code highlights remain visible when the reader navigates to another explanation in the same file. Switching files highlights the corresponding file's snippets. Decorations never change source text or `changedtick`. Notes wrap to at most 100 columns, aligned with the code while leaving at least 40 columns for text. Navigation centers the focused code and its frame, or uses `topfill` when the span cannot fit. Snacks handles animation.

`<leader>ah` shows/hides boxes, `aj/ak` moves between explanations along the gold route, `an/ap` between snippets, `al` picks a snippet, `a]/a[` pages the note then Q&A, `az` recenters, and `aq` quits. Shortcut hints are embedded directly in the last frame's bottom border without adding rows. Virtual rows are not selectable source text; `af` opens a centered view containing only the full explanation and Q&A text, without examples, the drawn box or hints. It supports selecting and copying text, and tracks box navigation. `<leader>ar` asks about the current box or visual selection: Ctrl-S sends and stays, Ctrl-F sends and follows the originating conversation, Ctrl-A pastes there without submitting, Ctrl-B saves the draft.

`aj/ak` moves between explanations, following the gold `next:true` route and stepping over red optional calls. Gold call completion continues at the caller's following part; red call completion restores its entry box. Ready calls are badged together in the current code. `<leader>ad` (`:CodeTourExpand`) inspects the source call under the cursor: enter a prepared explanation, or lazily generate a missing one. Several attached calls offer a picker when the cursor does not identify one. Generation stays in the caller, without a badge for the pending call. Once ready it enters only if the reader has not navigated away or started typing; otherwise it remains available for a later `ad`. `<leader>ao` (out, `:CodeTourReturn`) returns early from a method to the exact caller snippet and explanation box. `ak` at the method's overview also returns to the saved caller explanation. Early return uses the actual entry position, even when a call was opened from an overview rather than its authored part. There are no `ai`, `au` or `aU` mappings. Completed expansions are reused, and cancelled or failed requests can be retried.

If definition lookup fails or no provider/local definition is available, `ad` sends a SYMBOL AT THIS CALL SITE request to the originating agent with the captured symbol and caller context. The editor preserves the reader's position, reuses pending requests and rejects late replies against changed caller source. Resolve the definition as described above and deliver through the exact fill command.

`<leader>ae` adds an explanation for the visual selection. Without a selection it uses the current explanation box, or the cursor line outside that box. `<leader>aE` opens a multiline context composer first; Ctrl-S submits, and context may be blank. For example, explicitly ask there for an example with per-line data flow. Both work in normal and visual mode, in any source file while a tour is active. Replies attach to the containing snippet or a new stop in source order; existing explanations and Q&A stay intact. `:CodeTourDefinition` retains LSP/same-file Tree-sitter definition lookup separately. Source scrolling uses Snacks when enabled.
