# State-machine view

Status: proposal. Nothing here is implemented yet. It extends the tour graph and the tree view in [SPEC.md](SPEC.md) with a second kind of picture: the **state machine of a program**, drawn in the terminal, where every node can be opened, edited and handed to an agent.

## Where the idea comes from

ThePrimeagen's thread "So one thing I have been struggling with in this agent era is having what I think should be done and the agent doing it. There is so much control that is lost. So here my current idea. The state-machine that is my program is now visualized!" (X, 13 Nov 2026). His program is an agent pipeline written as a state machine in TypeScript, and his Neovim plugin shows it as a buffer. The thread, post by post:

| # | What he says | What the image shows |
| --- | --- | --- |
| 1 | The state machine is now visualized. | One state, `write-up`, with four steps: `write-up` (an agent step, blue, with the model `muse-ember XHIGH`), `render` and `push` (both `computer`), and a red `⇥ tail` jump. A thin bracket in the left margin loops from that jump down to the next state, `tail · exit`, which has `record` (`computer`, status chip `■ fixed`), `basecamp-fix` (`computer`) and a final `end: fixed`. The cursor is a box on one cell. |
| 2 | When one part is off he can prompt Cursor with exactly that node selected. | Two floats over the dimmed source. Left, titled `[fixer › write-up]`: the same `write-up` state, footer `…ve · <M-j/k> grow · <C-x> shrink` (the first word is cut off in the image). Right, titled `[fixer › write-up]`: `New chat · Opus 5.5 High`, an empty input, footer `<CR> send · /model · q=close`. |
| 3 | He made ways to visualize loops. | Five states stacked: `fix`, `commit`, `build`, `verify`, `judge`. Each lists its steps with who runs them and a status chip (`■ fixing`, `■ building`, `■ verifying`), then an `on tried` block of named outcomes, e.g. `passed → commit` and `refused when`, whose branches read `fix visits < 10 ↻ fix` and `otherwise ⇥ gave-up`. Left-margin brackets span the states a loop covers (one long bracket for `fix` through `judge`, one short one from `build` to `verify`). The cursor is on `verify` in `built → verify`. |
| 4 | Errors and exit conditions are stated in code at the top of the pipeline, so it is easy to see where each error leads. | The head of a machine: breadcrumb `machines › launcher › work-items › fixer`, then `catch Drained ⇥ drained`, `catch ItemFailed ⇥ errored`, `catch RunFailed ⇥ broken` and `on abort ⇥ released`. Below it `▶ claim · start` with the step `claim-fix` and the transition `→ prepare`. A red bracket from the `errored` target runs down the margin. |
| 5 | `gd` on any item opens its code or its prompt. | Two images. (a) Split: the machine on the left, `fixer/job.ts` on the right at the line that defines that name (`errored: [errorItem, end("errored")]`), the line number gutter showing relative numbers. Status line: `R=refresh · C=new chat · Ctrl-h=history` on the left. (b) The same machine, with `find-duplicate` as the agent step; `gd` opened a scratch split above the source showing `agent step`, `find-duplicate` and `Model meta/muse-ember, openrouter, reasoning xhigh`, and below it the prompt file `prompts/find-duplicate.md` with template fields like `{{value.recall.cause}}`. |
| 6 | Editing a prompt gives completion for what has already run before that step, and diagnostics when a value is read too early. | Two images. (a) A diagnostic on `{{value.fix}}`: `oligarchy: value.fix is not given to find-duplicate`. (b) A completion menu after `{{value.` listing only available values: `value.worktree`, `value.workItemId`, `value.recall.cause`, `value.recall.test.name`, `…test.kind`, `…drive.job`, `…test.proof`, `…shown.case`, `config.tools.lines`, `…shown.frame`, `…shown.quote`, `models.strong.model`. |
| 7 | "Developing things in the AI age is also super fun because you can do this." | A meme: "Wait, the agent pipeline is just a program?" / "Always has been." |

A reply from ShortcutFoo ("gd on a prompt node was not on our 2026 bingo card") shows the plugin's states and a prompt in one screen.

### What he is really saying

1. **The control problem.** Agents decide too much. The fix he proposes is to take control back by making the *workflow* an explicit program (a state machine), where the agent is one step type among others.
2. **The program is the picture.** The diagram is generated from the same data the program runs, so it cannot drift from the code.
3. **Every node is an addressable thing.** You can jump to its code or its prompt (`gd`), or select it and send exactly that node to an agent with a prompt.
4. **Failure paths are first-class.** Catches, exits, aborts and bounded loops are drawn the same way as the happy path, so you can see where each error leads.
5. **The editor knows the data flow.** Prompt templates complete only against values produced earlier and warn on values that are not available yet.

## What this plugin should do

code-tour already explains code for a human reader and already sends a selected box to the agent (`<leader>ar`, `<leader>ae`). The state-machine view adds the part that is missing: a picture of **control flow with failure paths**, where a node is a step and not a snippet. Two uses:

- **Reading.** An agent explaining a workflow, a pipeline, a router or a reducer can attach a machine to the tour. The reader sees the states, the transitions and the loops at once, and presses `gd` to read the code behind any node.
- **Steering.** The reader selects a node that looks wrong and asks the agent about it or asks for a change, with only that node as context. This is his "prompt Cursor with that individual node".

The existing tree view (`:CodeTourTree`) stays the picture of the *tour* (snippets and calls). The machine view is the picture of the *program*.

## Data model

A machine is authored by the agent next to the tour (same JSON file, key `machines`) or loaded alone. It is plain data; the plugin never runs it.

```json
{
  "machines": [{
    "id": "fixer",
    "path": ["machines", "launcher", "work-items", "fixer"],
    "start": "claim",
    "catch": [
      { "error": "Drained", "to": "drained" },
      { "error": "ItemFailed", "to": "errored" }
    ],
    "on_abort": "released",
    "states": [
      {
        "id": "claim",
        "steps": [
          { "id": "claim-fix", "kind": "computer", "status": "fixing",
            "source": { "file": "src/sm/jobs/fixer/job.ts", "start": 7, "end": 9 } }
        ],
        "next": { "to": "prepare" }
      },
      {
        "id": "fix",
        "steps": [
          { "id": "fix", "kind": "agent", "model": "muse-ember", "effort": "xhigh",
            "prompt": "src/sm/jobs/fixer/prompts/fix.md", "feedback": false }
        ],
        "on": { "name": "tried", "outcomes": [
          { "id": "passed", "to": "commit" },
          { "id": "refused", "when": [{ "visits": "fix", "below": 10, "to": "fix" }], "otherwise": { "exit": "gave-up" } }
        ] }
      },
      { "id": "tail", "exit": true, "steps": [{ "id": "end", "end": "fixed" }] }
    ]
  }]
}
```

- **machine**: `id`, optional `path` (breadcrumb of nested machines), `start`, `catch[]` (error name to target), `on_abort`, `states[]`.
- **state**: `id`, `steps[]`, then either `next` (an unconditional transition) or `on` (a named decision with `outcomes[]`). `exit: true` marks a terminal state. `only_on_catch` lists errors for states that are reachable only by a catch (his `only on catch RunFailed` block).
- **step**: `id`, `kind` of `computer` (deterministic code) or `agent` (a model step, with `model`, `effort`, `prompt`). Optional `status` (a status chip like `■ fixing`), `feedback` (the step's result is fed back, shown as `as feedback`) and `end` (a terminal value such as `fixed`). `source` is the code location, as in a tour snippet.
- **transition**: `to` (a state `id`). It is a *jump* (`exit`) when it leaves the machine or goes to a terminal state, and a *loop* when its target is the same or an earlier state. An outcome may carry `when` guards (`visits`, `below`, `to`) and `otherwise`; a guarded outcome is how bounded retries are shown (`fix visits < 10 ↻ fix`, `otherwise ⇥ gave-up`).
- All names must resolve. A transition to an unknown state, a duplicate id or a step without a `source` or `prompt` is a load error that names the entry, in line with the strict schema the tour already uses.
- A machine can be **derived** with no authoring: the tour graph projected as a machine (snippets are states, gold calls are `next`, optional calls are outcomes). That gives every tour a state-machine view for free, with fewer details.

## The view

`:CodeTourMachine [float|tab|split]` (default key `<leader>aM`, key action `machine`). It is a read-only buffer, drawn as text, following the colour scheme, and uses the same window options as the tree view.

Layout, top to bottom, as in the thread:

```
machines › launcher › work-items › fixer
catch Drained     ⇥ drained
catch ItemFailed  ⇥ errored
on abort          ⇥ released

▶ claim · start
  claim-fix       computer  ■ fixing
  → prepare

search
  find-duplicate  muse-ember XHIGH
  catch RunFailed ⇥ unsearched
  on found
  ├ duplicate → duplicate
  └ none      → fix

fix
  begin-try       computer  ■ fixing
  fix             muse-ember XHIGH
  check           computer  as feedback
  on tried
  ├ passed → commit
  └ refused when
    ├ fix visits < 10 ↻ fix
    └ otherwise ⇥ gave-up
```

Glyphs and colours (taken from the screenshots; each is a theme link, so they follow the colour scheme):

| Mark | Meaning |
| --- | --- |
| `▶` and `· start` | The start state. |
| `→ name` | A normal transition (goto). |
| `⇥ name` | A jump out: a catch, an abort or an exit. Drawn in the error colour. |
| `↻ name` | A loop back to an earlier state, with its guard (`visits < 10`). |
| `· exit` | A state that ends the machine. |
| `■ name` | A status chip: the item's status while the step runs. |
| `as feedback` | The step's result is fed back to the next agent step. |
| agent step name | Drawn in the accent (blue) colour, with its model and effort in the dim colour. Computer steps use the normal colour. |
| `only on catch X` | A dashed gold bar in the margin around a state reachable only by a catch. |
| margin brackets `╭ │ ╰▸` | A loop or jump span. The bracket runs from the source of a back edge to its target state header, so you can see which states a loop covers. The bracket for the transition under the cursor is highlighted, and the short ones nest inside the long ones. |

Rules:

- States are drawn in `states[]` order, separated by a blank line. Steps keep their authored order.
- Names align in a column; the executor column is at a fixed width per machine.
- Back-edge brackets are computed from state order, so they are stable. They use at most one column per nesting level and are drawn in the left margin, never over text.
- Wrapping is off. A long state list scrolls; `{` and `}` jump to the previous and next state.
- A machine can contain nested machines (`path`). A step of kind `machine` shows the child's id and `gd` opens that machine in the same window; `<BS>` returns to the parent, and the breadcrumb is the first line.

### Navigation

- `j` / `k` move one **item** at a time (a step, a transition, a catch or a state header), skipping blank lines and margin-only rows, as in the tree view. A count moves that many items.
- `gd` on a step opens its code (`source`) or its prompt (`prompt`) in a split beside the machine and puts the cursor on the matching line. On a transition it moves the cursor to the target state. On a catch line it goes to the handler state.
- `<CR>` on a transition is the same as `gd`. `<C-o>` goes back.
- `R` refreshes the machine from the file; `q` or `<Esc>` closes.

## Talking to the agent about a node

His flow: select a node, open a small prompt, send. In code-tour this reuses the existing agent channel (`agent = "herdr" | "clipboard" | custom`), so nothing here depends on Cursor.

- `<leader>ar` (or `C`) on a node opens a composer titled `[fixer › write-up]` with the node's lines above and an empty input below, with the hint line `<CR> send · q close` built from the key map.
- The prompt sent to the agent is small and exact: the machine and state names, the node's text, its `source` or `prompt` path with line range, the incoming and outgoing transitions, and the user's text. It never includes the whole machine unless the user asks (`<leader>aE`, the existing "with extra context" action).
- The reply lands as a normal explanation box on the node's `source` snippet (when it has one), so the tour keeps the answer; otherwise it is shown in the composer's history.
- `Ctrl-h` lists earlier questions for the node; `C` starts a new thread. This mirrors the footers in the screenshots (`R=refresh · C=new chat · Ctrl-h=history`).

## Prompt helpers (stretch goal, separate phase)

What the thread shows for prompt files is an editor feature: typing `{{value.` completes only values produced by earlier steps, and `{{value.fix}}` read too early shows an error. For code-tour:

- The machine file lists, per step, the `value` names it **produces**, and the prompt's `{{value.x}}` fields are what it **reads**.
- A diagnostic source (via `vim.diagnostic`) marks a read that no earlier step on any path produces. The message names the step: `value.fix is not given to find-duplicate`.
- A completion source offers the values available at that step.
- The data-flow check also runs on load and reports every violation in one list, so the agent that authored the machine can be told to fix them.

This only makes sense where a prompt file is edited in Neovim, so it ships separately and is not required for the view.

## Configuration

```lua
opts = {
  machine = {
    open = "float",   -- "float" | "tab" | "split"
    code = "split",   -- where gd opens code and prompts: "split" | "vsplit" | "float"
  },
  keys = { machine = "<leader>aM" },   -- false to disable
}
```

## Parts to build

1. **Model:** `lua/code-tour/machine.lua`: schema validation, the derived machine from a tour graph, back-edge and nesting computation. Pure Lua, no windows.
2. **Layout:** `lua/code-tour/machine-view.lua`: draws the lines, glyphs and margin brackets, and returns item anchors for `j` / `k`. Follows the same pattern as `tree.lua` (pure layout, then a window).
3. **Window and keys:** open modes, `gd`, `<CR>`, `{` / `}`, `R`, breadcrumb navigation.
4. **Agent channel:** the node composer and the scoped prompt, through `conversation.deliver`.
5. **Skill:** `skills/code-tour/SKILL.md` documents the `machines` key so authoring agents know when to attach one.
6. **Prompt helpers:** the data-flow check, diagnostics and completion (phase 2).

## Tests

- Schema: a valid machine loads; unknown state, duplicate id, a missing `source` or `prompt`, and a bad guard each fail with the entry named.
- Layout: the demo machine above renders exact text for the header, the start state, an `on` block and a bounded loop; glyphs match the table; the same input renders the same text.
- Brackets: a back edge draws a bracket that spans the right states; nested loops nest; the bracket under the cursor is highlighted.
- Navigation: `j` / `k` land on items only, counts work, `gd` on a step opens the right file and line, `gd` on a transition moves to the target, `<C-o>` returns.
- Derived machine: a tour with gold calls and an optional call projects to states, `next` and outcomes with no authored machine.
- Agent: the node prompt contains the node text, its source range and its transitions, and not the rest of the machine; the clipboard backend receives it.
- Headless only: no live model, no network.

## Open questions

1. **What is the source of truth?** This spec has the agent *author* a machine (the data is describing the program). Prime's program *is* the machine, so his picture is generated from running code. Reading real code (for example a TypeScript table like `fixer: [...]` with `on(...)`, `when(...)`, `end(...)`) would need one parser per framework. Proposal: start with the authored JSON, and add an importer only for frameworks you actually use.
2. **Is the derived machine enough for tours that are not state machines?** If most tours are plain call trees, the tree view already covers them and the derived machine adds little. It is cheap to keep, but optional.
3. **Prompt helpers.** The data-flow check needs `produces` in the data. Do you want it, or should the view stay a picture and a jump-to-code tool?
4. **Images.** The thread's screenshots are not stored in this repo. They belong to their author; keep them out of the repository and refer to the thread.
