# Agent-authored tours

Use this workflow when the AST command reports a fallback, when the reader requests a diff review, or when composing a tour from specific source ranges.

## Author a tour

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

Paths are relative to the caller's cwd or explicit `--project DIR`; absolute paths also work. Ranges are inclusive, 1-based CURRENT line numbers. Every stop has `file,start,end,note`; `title,parts,example,old` are optional. The schema above illustrates the optional example fields; omit them unless requested. Values use absolute source line numbers and are text or `{value,detail}`.

## Nested calls and explanation depth

Attach `calls` to the EXACT explanation box containing a method/function/class call, usually a part. `calls` is a list of ordinary stops, each of which may have its own parts and calls. Mark a prepared callee on the intended tour path with `next:true` and a `level` (see Level of detail). Its call expression gets a gold badge and its line gets `<- next snippet`; `aj` follows it after the containing box, explores its overview and parts, then continues at the caller's FOLLOWING part. If there are no remaining parts, continue to the next main snippet. Several gold calls on a box run in authored order; nested gold calls follow the same rule. Gold calls must have prepared explanations, never `lazy:true`. Do not duplicate the callee as a top-level snippet.

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
        {"file": "src/process.lua", "start": 20, "end": 28, "title": "process", "note": "Compute the response.", "next": true, "level": 0,
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

Use `--append` to add stops. When the user asks for a diff/review, use `--review` to compare current source with `git show HEAD:path`, or `--review --base REF` for another base. Both flags also work on `--fill ID`. Read that diff to explain what changed. A stop's optional `old` string is the exact text replaced by its current range, and overrides Git for that stop. Additions render green and removals as red virtual lines, with stronger colors in the focused part and muted colors elsewhere. `:CodeTourReview [REF]` enables diffs directly for an existing tour.

For a quick tour without authored notes, positional `FILE:LINE-END` arguments work:

```sh
python3 <skill-dir>/scripts/code-tour.py src/example.lua:10-18 src/other.lua:2-8
```

## Level of detail and pruning

You know the whole tree of snippets and calls; the reader only walks the gold route, so choose how much to present from the level of detail the user asks for (default: normal; ask only when it is genuinely unclear). Always keep one unbroken end-to-end path, the essential path that carries the user's scenario from its entry point to its final effect: every gold call must hang from a gold or top-level snippet, and a gold call below an optional or lazy one is never reached.

Give every gold call a `level` (a non-negative integer, with `next:true`). Level 0 is the essential path; higher levels are detail the reader can fold away with `a-`. A gold call without a `level` is rejected. A level-0 call must hang from top-level or level-0 snippets, or it folds with its parent and `route.shadowed` reports it. Detail means how many levels you prepare: overview, level 0 only, overview boxes only (no parts), 4-8 snippets; normal, levels 0-1, 8-15 snippets, parts where the code is not trivial; detailed, levels 0-2, 15-30 snippets with parts and sub-parts; exhaustive, every level, with the least relevant branches still optional.

You do not expand every callee. For each call in a snippet you write, choose one of three outcomes:

- Expanded: prepared and given a level (low levels are walked, deeper ones fold, a call without `next` is optional and red).
- Lazy: `{file,start,end,title,callsite,lazy:true,why}` with a short `why` such as "logging helper" or "stdlib"; the reader can still open it with `ad` and sees the reason.
- Unlisted: not attached at all, plain source. Use this for calls whose name says everything. `ad` on such a call falls back to the symbol lookup request.

Decide with judgment, per call: is it on the user's scenario path; does it change state or make a decision, or is it a pure helper; do its name and signature already say what it does (then a clause in the caller's note is enough); is it project code or a library/standard API (summarise those); is its body large or subtle; was it already explained (then it is a reference); and does expanding it keep the route within the target for the requested detail. Prune by demoting, not by cutting the story: a branch the reader does not need now becomes optional or lazy, and the parent's note says in a clause that it exists and was skipped. Never prune a snippet whose absence leaves a gap between two kept ones.

The `show` result reports the route: `route: {snippets, boxes, optional, lazy, broken, refs, levels, shadowed}`, where `snippets` and `boxes` are what `aj` will walk, `optional` and `lazy` what you pruned, `levels` the deepest level, `broken` lists gold calls that sit below an unwalked call (`{from, to}`), and `shadowed` lists calls whose level is below their parent's. When `snippets` is well above the target for the requested level, raise levels or demote branches and send the tour again; when `broken` or `shadowed` is not empty, fix those calls, then send it again.

## Streaming an end-to-end tour

For a long end-to-end tour, send a skeleton first and write the rest while the reader walks it. Plan the essential path from the code graph, then `show` the first snippets prepared and the later ones as `{file,start,end,title,next,level,callsite,pending:true}` with no note, parts or calls. The result lists `pending` entries in walk order, each with a `command`; fill them one at a time in that order through that command, as for any `--fill`, without `--after`/`--into` (they are refused for streamed snippets). A callee's caller needs only its contract (signature, result, effects), not the callee's explanation, so you can write top-down. Decide as you go: when you write a snippet you have just read its code, so announce as `pending` only the callees worth expanding, and leave the rest lazy or unlisted. A fill may announce deeper `pending` calls; they are returned in the fill result. Write the level-0 path first; optional and deep branches can be written after it, or left lazy for the reader to open. Never insert before the reader's position, and write an overview last when it needs the whole story. A reader who reaches an unwritten snippet sees "Still being written" and its number as "…".

## The reader can zoom

`<leader>a-` and `<leader>a+` fold and unfold the walk by level in the editor, with no request to you: folded gold calls are not walked until the reader zooms back in or opens them with `ad`. This only hides what you already prepared, so give the essential path level 0 and author the detail at higher levels; do not bake a shallow route into a tour the reader may want to deepen. Folded snippets still count in the `route` you receive.

## Parts can nest

A part may itself have `parts`, which refine it: each level must cover its parent's range exactly, with no gaps and nothing outside it, to a depth of eight. Use sub-parts only for long or dense parts that a single paragraph cannot explain; a short part needs none, and a long part is often better as its own snippet reached by a call. `aj` walks the tree depth-first (overview, part 1, its sub-parts, part 2, ...). Box IDs in requests stay `S.K`, numbered in that same depth-first order, and the reader sees paths like `Part 2.1`. In a `[code-tour refine]` reply covering a whole part, the returned parts become that part's children; a reply covering only some of the part's lines is added next to it. Saved tours currently store parts flat, so on reopening the nesting is lost but the order and ranges are kept.

## Walk order

`aj/ak` walk the tour graph depth-first (editor option `walk`, default on). The graph may contain cycles; the walk shows each snippet once. Only `next: true` calls are walked automatically, in the order you list them under a box; mark every callee the reader should be taken through as `next: true`, and leave the rest optional (red), which the reader opens with `ad`. Every gold branch, the last included, ends with a return to the calling box before reading goes on to the next branch, that box's following part, or out of the snippet; moving between top-level snippets has no return, and the run of returns at the very end of the tour is dropped, so the walk ends on the last snippet it reached. A deep chain therefore walks back up through each caller, so the route is longer than the number of snippets: `boxes` in the route report counts those returns. Several gold calls may share a line: give each its own `start_col`/`end_col` and list them in the order they should be read (for `f(g(x))`, that is usually `g` first). Recursion and loops need no special marking: a call back to a snippet already on the path, or to one already walked, is shown as a reference and never walked (`"ref": true` forces this). Lazy calls are skipped until explained. The gold call coming up next is highlighted in its own colour.

## Tour graph

`code-tour graph [--pane P]` (or `:CodeTourGraph`) writes the active tour as a graph and prints `{path, nodes, links}`. The file is NetworkX node-link JSON, like graphify's `graph.json`, in the temp directory. Each node is one snippet (identical file ranges merge): `id` is `FILE:START-END`, with `label`, `source_file`, `source_location`, `lazy`, `stops` (storage stop numbers) and `boxes` (`{id: "S.K", role, start, end, saved_id, status, stale}`). Links are `next` (the reading route, via `sequence` between main snippets or via `call` for a gold callee), `optional` (a red callee) and `overlaps` (snippets covering shared lines). Call links carry `from_box`, `symbol` and `callsite`. Use it to answer which snippets lead to or depend on another, instead of re-deriving that from the tour tree. It is a read-only projection; never edit it or pass it back to the editor.
