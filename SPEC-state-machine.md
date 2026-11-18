# State-machine view

Status: implemented (v1; see "What shipped" at the end). It adds a **state machine** layer inside the tour JSON (see [SPEC.md](SPEC.md)): states are snippets, steps are parts, transitions are edges. It is drawn in the terminal in sync with the tour, and every node can be opened, asked about and handed to an agent.

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

## The idea here: the machine is part of the tour

A tour already has the pieces of a state machine: top-level snippets with parts, the gold route between them, optional detours, and calls that return to the exact box. What it lacks is **control flow with failure paths**: which transition leaves a state under which condition, what a catch does, where a loop goes back to.

So the state machine is not a second tool. It is an extra layer **inside the tour JSON**, written by the agent, that maps onto the snippets the tour already has:

| Machine | Tour |
| --- | --- |
| a state | a top-level snippet (the overview box explains the state) |
| a step | a part of that snippet, with its own code range and explanation |
| a transition, catch or loop | an edge between snippets, drawn in the machine view and followed by `aj` when it is on the happy path |
| the machine view | a picture of the same tour, in sync with the tour position |

Everything the tour does for snippets then works for machine nodes with no new mechanism: the explanation box above the code, `<leader>ar` / `<leader>ae` to ask about a node, the picker, saved tours, stale detection, and revalidation against your code.

The JSON is the source of truth. The plugin never parses the program, so any language or framework works, as long as the agent can describe its states.

## Authoring: the `machine` key

An ordinary tour (see `skills/code-tour/SKILL.md`) gains an optional top-level `machine`. Each state names the stop that explains it; each step names a part of that stop. Nothing is repeated: file and line ranges live only on the stops.

```json
{
  "stops": [
    {
      "id": "fix", "file": "src/sm/jobs/fixer/job.ts", "start": 20, "end": 48, "title": "fix",
      "note": "Try a fix, check it, then decide whether to commit or retry.",
      "parts": [
        {"id": "fix.begin-try", "start": 21, "end": 23, "note": "Mark the item as fixing."},
        {"id": "fix.fix",       "start": 24, "end": 30, "note": "The agent writes the change from the prompt."},
        {"id": "fix.check",     "start": 31, "end": 36, "note": "Run the checks and feed the result back."}
      ]
    },
    {"id": "commit", "file": "src/sm/jobs/fixer/job.ts", "start": 50, "end": 58, "note": "Commit the change."}
  ],
  "machine": {
    "path": ["machines", "launcher", "work-items", "fixer"],
    "start": "claim",
    "catch": [
      {"error": "Drained",    "to": "drained"},
      {"error": "ItemFailed", "to": "errored"}
    ],
    "on_abort": "released",
    "states": [
      {
        "id": "fix",
        "steps": [
          {"part": "fix.begin-try", "kind": "computer", "status": "fixing"},
          {"part": "fix.fix",       "kind": "agent", "model": "muse-ember", "effort": "xhigh",
           "prompt": "fix.prompt"},
          {"part": "fix.check",     "kind": "computer", "feedback": true}
        ],
        "on": {
          "name": "tried",
          "outcomes": [
            {"id": "passed",  "to": "commit", "happy": true},
            {"id": "refused", "when": [{"visits": "fix", "below": 10, "to": "fix"}], "otherwise": {"exit": "gave-up"}}
          ]
        }
      },
      {"id": "commit", "next": "build"},
      {"id": "gave-up", "exit": true, "end": "out of tries"}
    ]
  }
}
```

Rules:

- **Identity.** A new optional `id` on stops and parts (unique in the tour, `[a-z0-9._-]`). A state's `id` is the id of its stop; a step's `part` is the id of a part of that stop. A state with no stop (a terminal such as `released`, or a pure router) is allowed; it just has no code box.
- **State:** `id`, `steps[]` (optional), then at most one of `next` (an unconditional transition) or `on` (a named decision with `outcomes[]`), or `exit: true` with an optional `end` value.
- **Step:** `part` (required for anything with code), `kind` of `computer` or `agent`, and for `agent` the `model`, `effort` and an optional `prompt` (the `id` of a stop on the prompt file, so it can be explained and asked about like any other code). Optional `status` (the status chip) and `feedback` (the result goes to the next agent step).
- **Outcome / transition:** `to` (a state id) or `exit` (leave the machine), `happy: true` for the route `aj` follows, and optional `when` guards (`visits`, `below`, `to`) with an `otherwise`. A transition to the same or an earlier state is a loop, and the view draws it that way.
- **Machine:** `path` (breadcrumb), `start`, `catch[]` (error name to state), `on_abort`, and the optional `only_on_catch` list on states reachable only by a catch.
- **Strict loading**, like the rest of the tour. Unknown state or part ids, a duplicate id, a transition to nowhere, two `happy` outcomes in one state, or a step whose part is not in its state's stop are load errors that name the entry. Nothing is guessed or defaulted.
- **A tour without `machine` behaves exactly as today.** Nothing changes for existing tours or saved tours.

## How it connects to walking the tour

`aj` / `ak` keep their meaning: they follow the tour's route. The machine only adds edges to that route.

- The walk reads a state as a snippet: overview, then each step as a part, in order. Then it follows the state's `happy` transition (or `next`) to the target state's snippet. This is the existing gold-route rule, with the transition as the edge.
- Every other transition (failed guards, catches, aborts, loops) is **optional**, like a red call: the reader chooses it, the walk steps over it, and the existing "return to the exact box" behaviour applies. The reader follows one with `<leader>ad` on the box (the existing inspect key), which offers a picker when a state has several.
- A loop back to a state that is already on the path, or already walked, is drawn and listed but **not walked**: this is the existing reference rule in `walk.lua`, so the walk cannot cycle.
- A catch or `on_abort` applies to the whole machine, so it hangs off the machine header and every step, not one box. It is reachable from the header line in the machine view and from the picker.
- A state with no stop has no box; the walk passes through it silently and the machine view shows it dimmed.
- Levels and zoom (`a-`, `a+`) are unchanged. A state's optional branches fold like optional calls, and the happy path stays level 0.

In the tour graph (`graph.lua`) the machine adds links with `relation` `"transition"` (happy, walked), `"branch"` (optional), `"catch"` and `"loop"`, and each carries `from_box`, a label and, for guards, the guard text. Stale-explanation reports and the picker already read this graph.

## The view

`:CodeTourMachine [float|tab|split]` (key action `machine`, default `<leader>aM`) shows the machine as text, following the colour scheme, in the same window kinds as the tree view. `split` is the best fit here: it stays open beside the code.

```
machines › launcher › work-items › fixer
catch Drained     ⇥ drained
catch ItemFailed  ⇥ errored
on abort          ⇥ released

▶ claim · start
  claim-fix       computer  ■ fixing
  → prepare

fix
  begin-try       computer  ■ fixing
  ● fix           muse-ember XHIGH          ← you are here
  check           computer  as feedback
  on tried
  ├ passed → commit
  └ refused when
    ├ fix visits < 10 ↻ fix
    └ otherwise ⇥ gave-up
```

Glyphs and colours, from the screenshots (each is a theme link):

| Mark | Meaning |
| --- | --- |
| `▶`, `· start` | The start state. |
| `→ name` | A normal transition; the `happy` one is the route `aj` follows (gold, as in the tour). |
| `⇥ name` | A jump out: catch, abort or exit. Error colour. |
| `↻ name` | A loop back, with its guard. |
| `· exit` | A state that ends the machine. |
| `■ name` | The status chip. |
| `as feedback` | The step's result is fed back. |
| agent step | Accent colour, with model and effort dimmed. Computer steps use the normal colour. |
| `only on catch X` | A dashed gold bar in the margin around a state reachable only by a catch. |
| margin brackets `╭ │ ╰▸` | A loop or jump span: from the source of a back edge down to its target state header. The bracket for the transition under the cursor is highlighted; short ones nest inside long ones. |
| `●` | The step the tour is on. |

Rules: states in authored order, steps in authored order, one executor column per machine, brackets drawn only in the left margin. A state that was not explained yet (`lazy`) shows `…`, a stale one shows its stale marker.

### Sync with the tour

- The machine view always shows the tour's current box: `●` marks the step, and the view scrolls to keep it visible. Moving in the tour (`aj`, `ak`, the picker, `ao`) moves the marker; the view never moves the tour on its own.
- `<CR>` or `gd` on a state, step or transition jumps the tour there and shows its box above the code, exactly as the picker does (`list_snippets`). On a step with a `prompt`, it opens that prompt's box. On a transition it jumps to the target state (or, for an optional one, enters it like `ad`, with the caller to return to).
- `j` / `k` move by line, as in any buffer.
- `{` / `}` move to the previous and next state; `q` / `<Esc>` close; `R` redraws from the tour.

## Talking to the agent about a node

His flow is "select a node, prompt the agent with just that node". In code-tour that is the existing question flow, now aimed at a machine node:

- `<leader>ar` in the machine view, on a step, opens the normal composer for that step's box, titled `[fixer › fix]`. The existing request goes out through the configured agent (`herdr`, `clipboard` or a custom function); nothing depends on a particular editor or tool.
- The request is small and exact (the existing contract): the state and step names, the box's note and its code range, plus the transitions into and out of the state, and the user's text. It does not resend the whole machine unless `<leader>aE` (explain with extra context) is used.
- On a transition line the question is about the edge: "why does this go to `gave-up` and not `fix`?", with the guard text in the request.
- The reply is a normal Q&A thread on the box, so the tour keeps it, and it appears in the text view (`<leader>af`).

## Prompt data flow (separate phase)

The thread's last two images are about editing prompt files: completion offers only values produced by earlier steps, and reading a value too early gives an error. This is an editor feature on top of the machine data, and it stays a later phase:

- A step may list `produces: ["recall.cause", ...]`, and a prompt part `reads` its `{{value.x}}` fields (or the plugin scans the prompt range for them).
- A `vim.diagnostic` source reports a read that no earlier step on any path produces: `value.fix is not given to find-duplicate`. A completion source offers what is available at that step.
- Load also checks it and lists every violation, so the agent that wrote the machine can be told to fix it.

## Configuration

```lua
opts = {
  machine = {
    open = "split",   -- "float" | "tab" | "split"
  },
  keys = { machine = "<leader>aM" },   -- false to disable
}
```

## Parts to build

1. **Schema:** `lua/code-tour/machine.lua` validates `machine` against the stops (ids, parts, transitions, `happy`), and normalises it. Pure Lua. `stops.lua` gains optional `id` on stops and parts.
2. **Graph and walk:** `graph.lua` emits the machine edges, `walk.lua` follows `happy`/`next` transitions and treats the rest as optional, with the existing reference rule for loops.
3. **Layout:** `lua/code-tour/machine-view.lua` draws the text, glyphs, margin brackets and the lines, as a pure function in the same style as `tree.lua`.
4. **Window and keys:** open modes, `<CR>` / `gd`, `{` / `}`, `R`, syncing the `●` marker with the tour position.
5. **Questions:** `<leader>ar` on machine nodes and transitions, with the scoped request.
6. **Skill and saved tours:** `skills/code-tour/SKILL.md` documents `machine` and says when to attach one. The saved-tour schema keeps the `machine` key and revalidates it with the stops.
7. **Prompt data flow:** phase 2.

## Tests

- **Schema:** a valid machine loads; each of unknown state, unknown part, duplicate id, a transition to nowhere, two `happy` outcomes, and a step whose part is not in its stop fails and names the entry. A tour without `machine` loads and behaves as before.
- **Graph:** transitions, branches, catches and loops become links with the right `relation`, `from_box` and label.
- **Walk:** `aj` goes overview → steps → the happy target; optional branches are skipped and enterable with `ad`, and return to the exact box; a loop to a visited state is shown but never walked, so a cyclic machine terminates.
- **Layout:** the demo machine renders exact text for the header, the start state, an `on` block and a bounded loop; glyphs match the table; the same input renders the same text; brackets span the right states and nest.
- **Navigation and sync:** `●` follows the tour; `<CR>` on a step shows that step's box; `<CR>` on a transition enters the target.
- **Ask:** the scoped request has the node, its range and its transitions and not the rest of the machine.
- **Saved tours:** the machine survives save and open, and a changed range marks the affected node stale.
- Headless only: no live model and no network.

## Open questions

1. **Machines that are not state-shaped.** The model is built for state-machine-style pipelines. A plain call tree already has the tree view, so it will not get a machine unless the agent writes one.
2. **One machine or many.** The spec has one `machine` per tour. A program with several machines can use several tours or, later, a list. Say if you want a list now.
3. **Prompt data flow.** The data-flow check is a separate phase. Do you want it?
4. **Images.** The thread's screenshots stay out of this repository; they belong to their author. Refer to the thread.

## What shipped (v1)

Implemented: the schema and its validation (`lua/code-tour/machine.lua`), the graph edges and the walk (`graph.lua`, `walk.lua`), the view with margin brackets (`lua/code-tour/machine-view.lua`), the `:CodeTourMachine [float|tab|split]` command and the `machine` key, the `{stops, machine}` payload through the CLI, saved tours that keep the machine and the authored ids, and the skill section. Tests: `tests/machine.lua` and a real-RPC test in `tests/test_cli.py`.

Where it differs from the text above:

- **Step prompts** are the `id` of a stop on the prompt file, not a file range (a part must lie inside its stop's file and range). `p` in the view jumps to it.
- **Optional transitions** (failures, loops, catches, exits) are opened from the machine view with `<CR>` / `gd`; they do not go through `<leader>ad` and have no return stack, so `ao` does not apply to them. Use `ak`, the picker or the view to go back.
- **Catches and `on_abort`** link from the start state in the graph.
- **The bracket under the cursor is not highlighted** yet.
- **Not built:** the prompt data-flow phase (`produces`, diagnostics, completion).
- **Questions:** `<leader>ar` in the view jumps to the row's box and opens the normal composer there. Transition-specific questions (about the edge) are not built.
