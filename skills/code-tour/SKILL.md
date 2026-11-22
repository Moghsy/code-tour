---
name: code-tour
description: Create interactive code tours in Neovim, answer code-tour editor requests, or use the code-tour knowledge commands to answer codebase questions when a repository has a .code-tour/ directory.
---

Use `python3 <skill-dir>/scripts/code-tour.py` for commands written as `code-tour` below. The CLI sends the tour directly to Neovim. Leave source files untouched when presenting or replying to a tour.

## Start a tour

1. Run `code-tour ast ENTRY` from the project root with a symbol or `file:line`. The editor shows the route and the CLI returns the outline of boxes that need prose.
2. Read the source and fill pending boxes in walk order, starting at the reader's position. Use the returned region IDs and fill commands. Write one Markdown section per box with a gist in the first paragraph and the explanation after it. See [AST fills, examples, and knowledge queries](references/ast-tours.md).
3. If the CLI reports a fallback, write JSON stops and send them with `code-tour --file PATH`. Use that workflow for a diff review or a tour of specific ranges too. See [authored stop schemas, examples, and streaming](references/authored-tours.md).

## Choose the main flow

- **Agent-authored tours.** Mark essential calls with `next: true` and `level: 0`. Keep that path connected from entry to final effect. Higher levels add detail the reader can fold with `<leader>a-`. Optional and lazy branches are opened by the reader.
- **AST tours.** The plugin computes ratings. Rating 0 is the main flow and is followed automatically. Higher ratings appear as optional or on-demand branches according to the selected detail. Changing detail keeps the main flow. Read the outline before writing and use route overrides only when the task calls for changing it.

## Answer an editor request

Use the supplied reply command and keep its pane, tour token, and target ID. Answer within the active tour and use the requested payload format. Questions take Markdown. AST fills take region-addressed Markdown when the request specifies it. Ordinary selection, definition, and refine requests take JSON stops.

- For AST requests, including an opened callee or a selection addressed by region ID, use the [AST protocol](references/ast-tours.md#handle-ast-editor-requests).
- For ordinary replies, editor ambiguity, or reader keybindings, see [editor requests and controls](references/editor-requests.md).
- For explicitly saving or reopening a tour, stale notes, or `[code-tour saved regeneration]`, see [saved tours and recovery](references/saved-tours.md).
- For a codebase question backed by the store, see [knowledge queries](references/ast-tours.md#query-the-code-graph).
