# AST tour protocol and knowledge queries

The plugin checkout contains the full protocol in `SPEC-ast-graph.md`. See §8.6 for detail and ratings, §9 for agent fills and overrides, §12 for examples, §13 for knowledge queries, and §16 for the command and option table.

## Write AST-backed tours

Start with `code-tour ast ENTRY`. Use the returned region IDs and fill commands. Read the source and write the gist and body in the same pass. Each Markdown section starts with `## overview` or a region ID such as `## r2`. The first paragraph is the gist. Explain what the code accomplishes, what it reads or changes, and how it hands off to the next region. Use the current code as the authority. Treat older prose in a brief as a draft about older code. Put a route explanation in a separate section such as `## edge s3`, adding the caller ID or a `>SYMBOL` suffix if needed. A standard example can follow a box body under `### Example (generated)`. Use the source label that matches the evidence.

Write the entry overviews and route edge notes in the originating conversation. Give workers whole snippets in walk order, starting where the reader is, and batch several light snippets together. Use the highest tier in each batch and the configured model for that tier. A worker runs `code-tour brief N --tour T`, reads interfaces and code, fills directly with `code-tour --fill N --tour T --model M`, and reports only `done` or `escalate: REASON`. Escalate an uncertain snippet one tier. Consider the model that wrote a box when following up on a reader question or raising its detail. Write the fills yourself if delegation or model mappings are unavailable. For a fallback result, author stops using the ordinary tour workflow below.

For a requested Java example, supply a scratch `CodeTourScenario.java` containing a standalone launcher method that constructs the inputs and calls the relevant symbol. Submit it with `code-tour scenario BOX FILE --tour T` using the pending question's box ID. The editor captures results when the configured debugger can run the scenario with project consent. When asked for a fallback, answer with an illustrative example labelled `generated`.

## Handle AST editor requests

A `[code-tour ast]` message already refers to a live tour. It can ask for its outline, boxes that became pending after an adjustment, or a newly opened callee. Fill the requested boxes in walk order through the supplied command. For a `[code-tour explain]` prompt that supplies AST region IDs and asks for Markdown, fill the named regions through that command. If a selection split a region, write the selected region and the remaining regions named in the request. Use the prompt's format to distinguish this from a selection request for JSON stops.

The first paragraph of each section is the gist. A snippet-specific fill accepts headings such as `## overview` and `## r2`. A multi-snippet fill can qualify a region with its snippet ID, for example `## n1 r2`. Preserve the pane and tour token from the live outline. Use `code-tour adjust --tour T` for requested route or detail changes and use the new outline and fill commands it returns.

## Query the code graph

- `code-tour flow ENTRY` shows the main flow without opening a tour. `code-tour explain SYMBOL` reads fresh notes and tests.
- `code-tour callers SYMBOL` lists call sites. `code-tour impact SYMBOL` reports transitive callers, dependent notes, and tests. Use `code-tour path A B` for connections or `code-tour search "TEXT"` to find symbols and notes.
- Queries use headless Neovim by default. Use `--pane P` when the answer needs the running editor's unsaved buffers. Use `--json` or `--budget N` when you need structured or bounded output.
- `code-tour note SYMBOL FILE` can write a coding note using the region IDs from `explain` or `flow`. Use current source to verify what the stored notes tell you.

## Fill ids, Markdown and partial fills

Fill ids look like `n13`, a snippet of the live tour; anything else is refused before the editor is asked. Pass `--markdown` with `--fill` so the input is never parsed as JSON. A fill that leaves boxes unwritten returns `partial: true`, a `warning` and the `remaining` list, and the CLI repeats the warning on stderr: keep filling until `remaining` is empty.

## Resolution limits and configuration

Calls are bound by receiver type only; a call whose receiver type is unknown stays unresolved and is never matched by bare name. Generated members (Lombok `@Builder`, `@Getter`, `@Setter`, `@Data`, `@Value` and constructors) are synthesized from annotations by `ast/synth.lua`; add rules for other generators with `ast.synthesizers = { java = { Annotation = function(type, api) return { specs } end } }`. Continue calls the language cannot follow with `ast.boundaries = { { call = "AWSLambda.invoke", to = "OrderHandler#handleRequest" } }`; such edges are `INFERRED` and print `via configured boundary`.
