---
name: code-tour
description: Create interactive code tours in Neovim (AST-backed by default, built with `code-tour ast` from the project's symbol graph), answer code-tour editor requests, or use the code-tour knowledge commands to answer codebase questions when a repository has a .code-tour/ directory.
---

Use `python3 <skill-dir>/scripts/code-tour.py` for commands written as `code-tour` below. The outline prints fill commands that name this same script. The CLI sends the tour directly to Neovim. Leave source files untouched when presenting or replying to a tour.

## Start a tour

**Always start with `code-tour ast`.** Every tour of how code works is an AST tour unless the CLI says otherwise: do not judge the language or the project yourself and do not write JSON stops first. The CLI decides: when the AST cannot cover the code (a language without a backend, Python or TypeScript/JavaScript not enabled, a missing parser) it returns `{"fallback": true, "reason": …}`, and only then do you author stops (step 4). Author stops without trying `ast` only for a diff review (`--review`) or when the user names exact line ranges. An error such as `no type X` is not a fallback: find the right symbol with `code-tour search` and retry. If a fallback reason says a language is opt-in, tell the user how to enable it.

1. **Understand the code first.** Read the persisted graph (built on first use, so no setup step is needed) and its lazy views: `code-tour analyze communities`, `gods`, `crossings` and `neighbors SYMBOL`, then read the source. The plugin states facts (resolved calls with their confidence, gaps, sinks, hand-offs) and never decides what matters.
2. **Design the route and send the tour.** Choose the flow yourself. Write it as edges and pass it with `code-tour ast ENTRY --route route.json` (`[{"from": "A#a", "to": "B#b", "level": 0}]`, level 0 being the main walk and 1 to 5 optional branches by detail; an optional `"site": "call.text"` limits an edge to one call). `--walk 'A -> B'` and `--branch 'A -> B@2'` name single edges. Every call you do not name stays lazy, so a tour without a route shows only its entry. Fix what the outline reports: a `gap` is a routed call the code cannot follow (close it with `--edge`), and a route warning means an edge matched no call. A second `code-tour ast` is refused while a tour is live; pass `--force` to replace it, or `code-tour adjust --tour T --route route.json` to change it. Several entries may be given (`code-tour ast A B`), and `ast.boundaries` continues calls the language cannot follow. To take the reader somewhere the code does not call (where an API is defined, the interface a class implements, a client in another repository), add a **jump**: `{"from": "A#a", "to": "B" or {"file", "start", "end", "label"}, "kind": "jump", "at": "text in A", "level": 0}`. Never redirect a real call with `--edge` for this. See [jumps](references/ast-tours.md#jumps-and-code-outside-the-ast). To refresh stored explanations after the code changed, check `code-tour analyze kb`, then `code-tour ast --stale`: only stale symbols become boxes and fresh notes are reused.
3. **Explain with that context.** Read the source and fill pending boxes in walk order, starting at the reader's position. Use the returned region IDs and fill commands. Write one Markdown section per box with a gist in the first paragraph and the explanation after it. See [AST fills, examples, and knowledge queries](references/ast-tours.md).
4. Only if the CLI reports a fallback, write JSON stops and send them with `code-tour --file PATH`. Use that workflow for a diff review or a tour of specific ranges too. See [authored stop schemas, examples, and streaming](references/authored-tours.md).

## Choose the main flow

- **Agent-authored tours.** Mark essential calls with `next: true` and `level: 0`. Keep that path connected from entry to final effect. Higher levels add detail the reader can fold with `<leader>a-`. Optional and lazy branches are opened by the reader.
- **AST tours.** You supply the route (step 2 above); the plugin computes no ratings and picks no main flow. Level 0 edges are followed automatically, higher levels appear as optional branches according to the selected detail, and everything unnamed is lazy for the reader to open. Changing detail keeps the main flow.

## Answer an editor request

Use the supplied reply command and keep its pane, tour token, and target ID. Answer within the active tour and use the requested payload format. Questions take Markdown. AST fills take region-addressed Markdown when the request specifies it. Ordinary selection, definition, and refine requests take JSON stops.

- For AST requests, including an opened callee or a selection addressed by region ID, use the [AST protocol](references/ast-tours.md#handle-ast-editor-requests).
- For ordinary replies, editor ambiguity, or reader keybindings, see [editor requests and controls](references/editor-requests.md).
- For explicitly saving or reopening a tour, stale notes, or `[code-tour saved regeneration]`, see [saved tours and recovery](references/saved-tours.md).
- For a codebase question backed by the store, see [knowledge queries](references/ast-tours.md#query-the-code-graph).
