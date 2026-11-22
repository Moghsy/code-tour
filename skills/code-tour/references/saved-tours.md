# Saved tours and recovery

## Save, find and reopen tours

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

## Respond to saved regeneration

`[code-tour saved regeneration]` has a stricter contract than ordinary explanation/refinement requests. Explain only the supplied captured CURRENT code and exact byte range, in its repository context. Never reuse invalid old prose or recreate historical comparison claims. Return a JSON list with exactly ONE stop containing `file`, `start`, `end`, `note` (optional `title`). Copy the requested file and inclusive line coverage exactly; describe only the supplied bytes when other statements share those lines. Keep overview prose concise and part prose detailed.

`[code-tour saved regeneration batch]` carries several boxes under the same contract. Explain each `## Box: ID` independently from its own captured code, and return ONE JSON list with exactly one stop per box, each adding `box` (the Box ID) to `file`, `start`, `end`, `note` (optional `title`). Deliver the whole list once through the supplied command. Each stop is validated separately: a wrong range, missing or duplicate `box`, or a stale source fails only that box, and omitted boxes are reported as failed. Do not split a batch into several fills; the request completes on the first fill.

Omit parts, calls, examples, values, review data and generation evidence. Deliver through the exact supplied `--fill ID --pane P --tour TOKEN` command, with no placement or review flags. This replaces only the requested box and preserves siblings and navigation. Do not send a new `show` payload or save the result. The editor validates source freshness and rejects late/cancelled replies. A meaningful source change requires explicit retry using explain-current-box; do not automatically retry or manufacture a replacement request. Failures and timeouts let unrelated queued targets continue.

## Stale explanations


Saved tours track freshness. When a box's source changes, the editor warns, withholds that box's prose and writes a report in the temp directory (`code-tour-UID/<tour id>.stale.json`, built from the tour graph). Requests cite it with a line `Stale: 1.3, 2.1 · report: PATH` while anything is stale. In the saved tour file a stale box is the one whose `evidence` is `{"status":"unverified","reason":"Source changed before save"}`. Ordinary tours opened from a tmp file are not tracked.

The report is `{tour, stale:[{id, saved_id, status, reason, file, start, end, update_also:[{id, saved_id, relation, stale, file, start, end}]}]}`. `id` is the request box ID `S.K`; `saved_id` matches the box `id` in the saved file. `update_also` lists the boxes whose prose depends on the stale one: `overview` (summarises the stale part), `caller` (calls into the stale code: the caller chain, and any other snippet whose called definition overlaps it) and `callee` (calls made from the stale box; verify their call sites). Before answering anything that touches a stale box, read the report and the current source for each stale range.

When asked to refresh a tour, or when a request involves a stale box, update the stale box AND every `update_also` box: they are explained from the stale code, so they are wrong or incomplete until revised. Also search the tour file for other snippets whose code calls or mentions the changed function or symbol, even when the report does not list them, and update those boxes too. Check callers transitively: if an updated caller's behaviour changed, its own callers may need revising. A `[code-tour saved regeneration]` box carrying a `Linked: update because X changed` line is such a dependent: read X's current source and make the explanation reflect X's new behaviour, while still describing only the supplied bytes. The editor queues stale boxes with their linked boxes in one batch when the reader presses `<leader>ae` on a stale box.
