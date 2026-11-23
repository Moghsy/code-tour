# Code representation and AST-backed tours

This spec describes the AST-backed tour, persistent note store, agent commands, Java examples and opt-in Python backend. Library source navigation, AST route confirmation by LSP, and additional walk types are deferred.

The plugin derives the regions, call sites and route for supported source. The agent writes explanations addressed by short IDs such as `n1 r2`. The repository store retains each explanation while its source and walked callees still match the saved evidence. For source without a suitable parser, an agent can supply the ranges (§14).

AST tours build on the renderer, walk, zoom, streaming, Q&A and saved-tour behavior in [SPEC-old.md](SPEC-old.md).

## 1. Inspirations

The design borrows from two tools that turn code into graphs, and departs from each where a tour has needs they don't.

### From graphify

| Taken | Where it lands |
| --- | --- |
| A deterministic, LLM-free code layer | §4–5: structure is computed, never generated |
| Two passes per file: declarations first, then bodies, joined by a table of names declared in the file | §4.2 |
| Node-type lists per language driving one generic extractor | §4.1 |
| Leftover calls handed to a project-wide resolver | §5.2 |
| Node-link JSON, relation names, `EXTRACTED`/`INFERRED`/`AMBIGUOUS` confidence | §3, §15 |
| Cautious resolution: bind only a unique match; package check on imports; superclass chain beats interfaces; drop names declared twice with different types | §5 |

| Rejected | Why | Instead |
| --- | --- | --- |
| One `calls` edge per caller/target pair, first line only | badges need every call site with exact columns | call sites are nodes (§3.3) |
| A method is a point at one line; bodies discarded | boxes need regions inside a method | the region tree (§3.2) |
| Method ids ignore parameters | overloads collide or produce no edge | parameter types in ids (§3.1) |
| Ambiguous calls dropped | the reader should still be offered the candidates | kept as `AMBIGUOUS`, never walked |
| Calls stop at the interface method | the walk should reach code that runs | dispatch to implementations (§5.4) |
| For-each loop variables untyped | real calls are lost (`line.subtotal()`) | block-scoped locals of every kind (§4.2) |
| A built-in names list applied to every language | Java's own `max()` loses its callers | built-ins listed per language (§5.3) |

### From Understand Anything

| Taken | Where it lands |
| --- | --- |
| Two phases: mechanical structure first, LLM text attached afterwards | the whole design: §4–8 mechanical, §9 agent |
| Text attached to graph nodes rather than to free-floating steps | notes live on regions (§3.5) |
| One central graph per repository, updated incrementally | the note store (§11) |
| Scoring likely entry points (file names, depth, fan-in/fan-out) | entry-free tours (§8.1) |
| Checking a graph against the git commit it was built from, then per-file fingerprints | the store's quick checks (§11.3) |
| Per-node metrics such as complexity feeding later decisions | metrics only choose the model for a box (§8.4); the agent chooses the route (§8.3) |
| Optional hints from an existing graph | not used; the plugin keeps its own graph and concepts (§15) |

| Rejected | Why | Instead |
| --- | --- | --- |
| LLM summaries for every node in the repo, up front | expensive, slow, mostly unread | explain only what the tour visits, on demand, streamed |
| Tours of 5–15 file-level steps, in architecture order | a code tour reads execution, method by method | route over resolved call sites (§8) |
| Breadth-first order along imports | breadth-first reading jumps between unrelated files | depth-first along calls, with returns |
| Staleness decided per file and commit, with body-only changes treated as cosmetic | explanations describe bodies; a commit says nothing about the other methods in a file, or about uncommitted edits | a fingerprint per note, covering its region and its walked callees (§11.3) |
| A browser dashboard | the reader stays in the editor, on the source | the existing Neovim renderer |

## 2. Layers

```
L0  source + Tree-sitter tree      ephemeral, never stored
L1  symbol graph                   declarations and references, project-wide, cached
L2  region tree + sites            what happens, in what order, inside each symbol
L3  tour                           a view: entries, detail, ratings, chosen regions, the route
L4  stops tree                     what today's renderer, walk, picker and tree view consume

    note store                     explanations attached to regions; one per repository; written on every fill
```

Each layer is computed from the one below, and L0–L4 are rebuilt from source whenever they are needed, so they cannot drift. Two things are durable (§11): the **note store**, which holds every explanation written for the repository, keyed by region address and fingerprint; and **tour recipes** (entries, detail, overrides), so a tour can be reopened. A tour is a view over the code and the store; there is no save command.

## 3. Data model

### 3.1 Symbols

A symbol is a declaration: file, type, method, constructor, field.

| Field | Meaning |
| --- | --- |
| `id` | `lang:` + qualified name + parameter types. Type: `java:shop.order.OrderService`. Method: `java:shop.order.OrderService#checkout(Order)`. Nested type: `java:shop.Outer.Inner`. Constructor: `java:shop.money.Money#Money(long)`. Field or record component: `java:shop.money.Money#cents`. Anonymous and local classes take javac's binary names: `java:shop.order.OrderService$1`, `java:shop.order.OrderService$1Counter` (numbered per enclosing class in source order); an enum constant's body is an anonymous class of its enum. File: `file:src/main/java/shop/order/OrderService.java`. Parameter types are written as the last segment of the name the source spells, without generics, arrays kept: `Map.Entry<K,V>` → `Entry`, `String...` → `String...`, a type variable as itself (`T`). Comparing signatures therefore treats a supertype's type variable as matching any type (§5.4). |
| `kind` | `file`, `class`, `interface`, `enum`, `record`, `annotation`, `method`, `constructor`, `field` |
| `label` | `OrderService`, `OrderService.checkout(Order)` |
| `file` | repo-relative path |
| `range` | byte range `{start:[row,col], end:[row,col]}`, end exclusive (the `source.lua` convention). Computed from the syntax tree; never stored in the note store or a tour recipe. The parse cache (§4.3), keyed by file content, may hold it. |
| `signature` | method only: the declaration up to the body |
| `abstract` | method only: no body |
| `returns` | method only: declared return type name |
| `metrics` | method only: `{lines, statements, branches, loops, sites, project_sites, field_writes, throws}` |
| `source` | `ast`, `library` (§4.4) or `agent` (fallback, §14) |

### 3.2 Regions

A region is a contiguous piece of a symbol's code that can carry an explanation. Regions form a tree: a method's root region covers the method, and its children cover groups of statements, which may in turn have children (the arms of an `if`, a loop body).

| Field | Meaning |
| --- | --- |
| `address` | structural path from the symbol: `java:shop.order.OrderService#checkout(Order)/body/stmts[3..4]`, `…/body/stmts[1]/then`, `…/body/stmts[5]/catch[0]`. The root region's address is the symbol id. |
| `kind` | `root`, `guard`, `setup`, `work`, `delegate`, `loop`, `branch`, `try`, `switch`, `result`, `mixed` |
| `origin` | `syntactic` (one syntax node: a statement, an arm) or `synthetic` (a run of sibling statements chosen by §7) |
| `fingerprint` | the `ts-scoped-leaves-v1` digest of the region's bytes (`source.lua`) |
| `children` | ordered child regions |
| `facts` | mechanical facts for the agent outline: locals declared, fields written, guard conditions, loop subject |

A region's line range is derived from its address whenever it is needed. Ranges always start at a token and end at a token, and children always cover their parent exactly (comments and blank lines between statements go to the preceding child), so the coverage rule of today's parts holds by construction.

### 3.3 Sites

A site is one occurrence of a reference inside a region: a call, a constructor call, a method reference, an accessor.

| Field | Meaning |
| --- | --- |
| `id` | `s1`, `s2`… numbered in evaluation order within the symbol |
| `region` | the deepest region containing it |
| `order` | evaluation order (`f(g(x))`: `g` before `f`) |
| `kind` | `call`, `new`, `this()`, `super()`, `method_ref`, `accessor` |
| `text` | the badge text: receiver plus name when the receiver is an id, `this`, `super`, `Outer.super`, or a field access one level deep (`this.gateway.charge()` → `gateway.charge`, `a.b.c()` → `a.b.c`); otherwise just the name (`c` in `a.b().c()`). Explicit type arguments (`this.<T>m()`), and a receiver on another line, also leave just the name. `new T(…)` reads `new T` as the source spells `T`, without type arguments. The text always reads as the source within the range. |
| `range` | byte range of the badge text, computed from the syntax node |
| `targets` | `[{symbol, confidence, via}]`; several for dispatch or ambiguity, none when unresolved |
| `declared` | the method the call names, when it is abstract (§5.4); its implementations are the `targets` |
| `unresolved` | reason when there is no target: `library` (no library source available, §4.4), `builtin` (§5.3), `generic`, `dynamic`, `abstract` (an abstract method with no implementation in the project, often supplied by a framework, §5.6), `no backend` |
| `deferred` | a site inside a lambda: `{kind: "lambda", call: sN, arg}` when the lambda is passed to call `sN` and runs during it, `{kind: "lambda"}` when it is stored or returned and runs later. Lambda sites are numbered where they appear in the source (inside the call's arguments, before the call). |
| `passed` | a method reference passed to a call: `{call: sN, arg}` |

Repeated calls to the same target are separate sites, each with its own badge.

### 3.4 Edges

The symbol graph has graphify's relations between symbols: `contains`, `method`, `field`, `inherits`, `implements`, `imports`, `references` (with `context`: `param`, `local`, `return`, `field`, `new`, `cast`, `static`, `accessor`), `overrides`. Calls are not symbol-to-symbol edges; they are `site → target` edges, so the graph keeps every call site.

Every edge carries:

| Field | Values |
| --- | --- |
| `confidence` | `EXTRACTED` (the syntax and declared types prove it, through the language's scoping rules, in this file or another), `INFERRED` (some step was heuristic: a unique project name, rule 7 of §5.2; name-only matching; dispatch; an agent edge), `AMBIGUOUS` (several candidates kept) |
| `via` | how it was resolved: `local`, `param`, `field`, `this`, `super`, `static`, `import`, `package`, `chain`, `dispatch`, `declared` (the export's edge to an abstract method a call names, §15), `boundary` (a configured cross-boundary edge, §5.6), `lsp`, `agent` |
| `source` | `ast`, `lsp`, `agent`, `hint` |

The agent may add edges the syntax tree cannot see (dependency injection, event buses, reflection, framework callbacks) through `--edge` (§9.6). They carry `source: agent, confidence: INFERRED` and can be walked like any other.

### 3.5 Notes

A note belongs to one region and lives in the note store (§11), not in a tour.

```
{ region: <address>, file, gist: "one line",
  bodies: { overview?, normal?, detailed?, exhaustive?: { text, model, commit, written_at } },
  example?: { text, source: "test" | "recorded" | "generated", test?: <symbol id> },
  evidence: { fingerprint, callees: { <symbol id>: <fingerprint> } } }
```

- The **gist** is the first sentence of a box's section (§9.3), written together with the body, not in a pass of its own. It is the same at every detail level, so it is stored once per note. Zoomed-out views, the tree view, `an`/`ap` headers and other snippets' briefs (§9.7) show gists.
- **Bodies** are the explanation in today's style, one per detail level (§8.6): a box can hold an overview, a normal, a detailed and an exhaustive body side by side, and writing one never replaces another. Reopening a tour shows the body at the tour's level, or the nearest one (§11.2).
- `evidence.fingerprint` is the region's fingerprint when the note was written; `evidence.callees` holds the root fingerprints of the symbols walked from sites in the region. Together they decide freshness (§11.3), so a note goes stale when the code it describes changes *or* when a method it explains a call into changes. Every level shares them, so a code change makes all levels of a box stale at once.
- `example` is the box's **standard example** (§12), stored and checked for freshness like the bodies. Examples the reader asks for are not stored here (§12.1).
- `model` is the model that wrote a body (§9.7), so a later request can upgrade it. A lighter model does not make a body stale.
- `commit` records when a body was written; it is provenance only and never decides freshness.

A note is **fresh** when its fingerprint and all its callee fingerprints match the current code, and **stale** otherwise. A box shows a fresh note; a stale or missing note shows "Being written…". **Stale text is never displayed**, even while its replacement is being written.

**Edge notes.** The reason a tour visits a symbol ("this is where the discounted total is charged") depends on the caller, not on the callee's code, so it is stored separately, keyed by the caller's region and the target: `{caller: <region address>, target: <symbol id>, occurrence, text, evidence: {caller_fingerprint, target_fingerprint}}`, where `occurrence` counts calls to that target within the region (1 for the first). Site numbers (`s5`) are never part of the key, since they follow evaluation order and shift whenever a call is added earlier in the method. The edge note becomes the `why` of the route edge.

Q&A threads stay attached to boxes as today, and are stored with the region's note, independent of level: a question asked at normal stays visible at detailed. When the note is stale they are hidden with it and kept; they reappear only if the code returns to the fingerprint they were asked against.

### 3.6 The tour

```
recipe (durable):   { id, entries: [symbol…], detail, through: [symbol…], overrides: [...] }
derived (rebuilt):  { snippets: [{n, symbol, tier, regions: [address…]}],
                      route: [{from: {n, site}, to: n, rating, main, mode, why}], gaps: [...] }
```

- A **snippet** is a symbol the tour visits, with the regions selected for it (§7) and its tier (§9.7). The initial projection assigns short IDs (`n1`, `n2`…) in walk order. A live tour keeps each symbol’s ID when detail changes or a lazy snippet opens.
- The **route** is the list of site edges the tour uses. Each rated edge has a **rating** (§8.2), an integer where 0 is most important, and its **mode** follows from the rating and the detail's cutoffs (§8.6): `walk` (gold, followed by `aj`), `optional` (red) or `lazy` (opened with `ad`, explained on demand). Edges to code already shown are `ref` and unrated. Edges on the **main flow** (§8.3) have `main: true` and rating 0.

**Who decides the flow (supersedes the computed route of §8.2–8.5).** The plugin does not rate calls or pick a main flow. The agent studies the project graph (`graph.json`, `code-tour analyze`) and supplies the route as edges `{from, to, level, site?}`: level 0 is the main walk, levels 1 to 5 are optional branches offered by detail (§8.6), and every call the route does not name is lazy (`why: "not in the route"`). `site` limits an edge to one call written as that text. The route reaches the plugin as `route` overrides (`--route FILE`, `--walk`, `--branch`), is kept in the recipe like any override, and may name an implementation to settle a dispatch. What the plugin still computes are facts about the code, not judgements: sinks, hand-offs and forks, gaps where a routed call cannot be followed, and the success-path and effect analysis that shapes regions. The scoring, trivial-target detection, carriers-and-effects promotion, rating bands and the graphify/Understand-Anything hints were removed.
- `through` lists symbols the main flow must pass through (§8.1); `gaps` lists the places where the main flow could not be followed (§8.3).
- **Overrides** record the agent's or reader's corrections (§9.6), so a reopened tour keeps them.
- Notes are not part of the tour; the tour looks them up in the store by region address (§11.2).

### 3.7 Projection to stops (L3 → L4)

| Tour | Stop |
| --- | --- |
| snippet | stop `{file, start, end, title}` with `anchor = "n1"` |
| selected child regions | nested `parts`, each with `anchor = "n1.r2"` |
| route edge `walk` | a call with `next: true`, `main: true` on the main flow, `level` = its effective rating, `callsite` from the site's range, attached to the part of the site's region |
| route edge `optional` | a call without `next`, `level` = its effective rating |
| route edge `lazy` | `{file, start, end, title, callsite, lazy: true, why}` |
| route edge `ref` | not projected |
| region with a fresh note in the store | the note's gist or body |
| region with a stale or no note | "Being written…" on the projected box until a fresh section arrives |

`anchor` survives `stops.normalize` (only `_` keys are stripped), which is how the editor maps boxes back to regions. Opening a lazy call replaces its branch. An override or detail change rebuilds the projection and restores the reader’s position where possible. Editing source hides affected prose and requires a rebuild before further structural operations.

## 4. Extraction

### 4.1 Backends

A language backend is a Lua module in `lua/code-tour/ast/lang/`:

```lua
backend.name        = "java"
backend.extensions  = { ".java" }
backend.parser      = "java"               -- Tree-sitter language
backend.types       = {                    -- node-type lists, graphify-style
  type      = { "class_declaration", "interface_declaration", "enum_declaration",
                "record_declaration", "annotation_type_declaration" },
  method    = { "method_declaration", "constructor_declaration", "compact_constructor_declaration" },
  import    = { "import_declaration" },
  call      = { "method_invocation", "object_creation_expression",
                "explicit_constructor_invocation", "method_reference" },
  statement = { … }, compound = { "if_statement", "for_statement", "enhanced_for_statement",
                "while_statement", "do_statement", "try_statement", "try_with_resources_statement",
                "switch_expression", "synchronized_statement" },
}
backend.builtins    = { "String", "Object", "System", "Math", … }   -- this language only
backend.sinks       = { … }   -- library calls where the main flow ends (§8.3): JDBC/JPA writes, file and stream writes, HTTP clients, message producers
backend.handoffs    = { … }   -- library calls that pass control on invisibly (§8.3): event publishers, executors, async futures
backend.extract(file, source) -> FileFacts                     -- index entry point
backend.declarations(file, root, source) -> FileFacts, pending -- pass 1
backend.bodies(file, source, facts, pending) -> FileFacts       -- pass 2 fills facts.bodies
```

`ast.available(path)` is true when a backend claims the extension, its parser loads (`vim.treesitter.language.add`), and the requested symbol parses without an `ERROR` node inside it.

### 4.2 Two passes per file

**Pass 1, declarations** (graphify's `walk`): a recursive descent dispatching on node type.

- import → single, wildcard, static-single and static-wildcard import maps
- type → symbol, `contains`, `inherits`/`implements` names (resolved in §5), fields with declared types, record components (as fields plus implicit accessors)
- method → symbol with parameters, return type, modifiers; the body is remembered, not descended into
- record component → a field and, unless the record declares it, an implicit accessor method (`implicit: true`)
- enum constant with a body → an anonymous class of the enum (§3.1), whose methods are implementations of the enum's abstract ones
- anything else → descend

The result is the file's **declaration table**: every name declared in the file, with its symbol.

**Pass 2, bodies** (graphify's `walk_calls`, extended): for every remembered body, a recursive descent that records three things graphify does not:

1. **Locals with scopes**: `local_variable_declaration`, `enhanced_for_statement`, `catch_formal_parameter`, `resource`, pattern variables, lambda parameters. Each is `{name, type or nil, declared_at, scope range}`, so the type of a name at a site is the innermost declaration in scope, not a method-wide guess. `var` takes its initializer's type when that is `new T`, a cast or a call with a resolvable return type. Each local also records its **definitions** (the declaration's initializer and every later assignment, with the sites in each expression) and its **uses** (the statement, and the site and argument position when it is passed to a call, or the `return` that contains it), so values can be traced through locals within the method (§8.3). A parameter is a local of kind `param`. A pattern variable is scoped from its declaration to the end of the enclosing block, which is wider than Java's flow scoping but binds the same names, since a later declaration of the name shadows it.
2. **Sites** with a receiver descriptor for §5: `{k:"implicit"}` (a bare call), `{k:"id",name,local?}` (`local` is the index of the local it names, with `local_body` when it is captured from an enclosing method), `{k:"this",outer?}`, `{k:"super",outer?}` (`Outer.this`, `Outer.super`, `Iface.super`), `{k:"field",object,name}`, `{k:"call",site,name,arity}` (`site` is the inner call), `{k:"new",type}`, `{k:"cast",type}`, `{k:"type",type}` (the `T` of `T::m`), `{k:"lit",type}`, `{k:"other"}`.
3. **The statement tree** for §7: each statement's kind, range, `guard` (an `if` with no `else` whose consequence only returns, throws, breaks or continues; an `if`/`else` is a two-arm branch, §8.3), `blank_before`, `comment_before`, sites, field writes, and the arms of compound statements. Old-style `case` groups of one switch share one scope; pattern variables and guards of `case` labels belong to their arm.

**Local and anonymous classes** are found in pass 2, since pass 1 never enters bodies. Each becomes a type symbol (§3.1) with its own members, and its methods get their own bodies and sites, walked in place so they see the names of the enclosing method (captured locals). A bare call inside such a class binds to its own members first, then its supertype's, then the enclosing types'. An anonymous class's supertype is a class or an interface, as the resolver finds it. The enclosing method has the creating `new` site (with `anonymous: <type id>`), not the class's sites.

**Field initializers, initializer blocks and enum-constant arguments** have their sites in a body keyed by the type's own symbol id, marked `initializer`. Whether they become regions of the type's snippet or snippets of their own is open (§19, question 1).

### 4.3 The project index

- **Root**: the git top-level, or `--project`.
- **Files**: the project's files are exactly what git lists: `git ls-files -z --cached --others --exclude-standard`, i.e. tracked files plus untracked ones that are not ignored. `.gitignore`, `.git/info/exclude` and the user's global excludes are therefore honoured for free, build output and dependencies drop out, and so does `.code-tour/` (§11.1). `ast.ignore` removes further paths from that list. Outside a git repository, a fallback walk skips `.git`, `target`, `build`, `out`, `bin`, `.gradle`, `.idea` and `node_modules`.
- **On demand**: the index starts from the entry's file and parses outward as resolution needs other files. Java's package-to-path convention finds most files directly (`shop.order.Order` → `**/shop/order/Order.java`); otherwise `git grep -l --untracked -E '\b(class|interface|enum|record)\s+Order\b'` gives candidates to parse, searching the same file set and needing no extra tool. A full scan runs for `codegraph`, entry-free tours, and coding queries that need project-wide matches or reverse edges.
- **Cache**: facts are keyed by git blob SHA (`git ls-files -s`; `git hash-object` for untracked files, files modified in the working tree (`git ls-files -m`), and files git is told not to watch (`assume-unchanged` or `skip-worktree`, from `git ls-files -v`)), together with the backend's version and the parser's ABI, so identical content parses once across branches and worktrees. Python cache keys also include the source path because it determines module identity and relative imports. A loaded, modified buffer is keyed by its `changedtick` instead. The cache lives under `stdpath("cache")/code-tour/`, never in the repository.
- **Budget**: `ast.max_files` caps full scans at 5000 files by default. Parsing and resolution run inline. Event-loop batching is deferred.

### 4.4 Library source navigation (deferred)

The AST route identifies known library calls, sinks and hand-offs. Loading library source and sharing library notes are planned extensions. In that design, library code can be walked like project code. Sources are found, in order:

1. **Source jars**: the build's dependency caches (`~/.m2/repository`, `~/.gradle/caches/modules-2`) keep `-sources.jar` files beside the binaries. The jar for a dependency is unpacked into `stdpath("cache")/code-tour/lib/<group>/<artifact>/<version>/`.
2. **The language server**: when jdtls is attached, `textDocument/definition` on a library site returns a `jdt://` URI, and `java/classFileContents` returns its source, from a source jar or decompiled.
3. **The JDK's `src.zip`**, for the standard library.

Library files are parsed by the same backend into symbols with `source: library` and an `origin`: `maven:<group>:<artifact>:<version>`, `jdk:<version>`, or `decompiled`. They are read-only, and badges into them work as usual.

- **On demand only.** A library file is parsed when one of its symbols is needed (a route edge, `ad`, `--through`), never in a full scan.
- **Extras by default.** Library targets are rated at least 3 (§8.2), so they are offered from normal detail up, and never join the main flow unless `--through` or `--rate …=0` puts them there. Built-ins (§5.3) stay unrated: walking `ArrayList.add` is rarely the point.
- **Decompiled code** has no comments and loses some names; its snippets are tier `deep` (§9.7) and marked `decompiled` in the outline.
- **Notes on library code** are stored outside the repository, in `stdpath("data")/code-tour/lib/<origin>/`, keyed like any other note (§11). A released library version never changes, so its notes stay fresh, and every project using that version shares them.

### 4.5 What another language needs

Everything from regions upward (the route, the store, the agent protocol, the editor) consumes the facts of §3 and is independent of language. Fingerprints and addresses are too, since Tree-sitter supplies them for any parser. A new language supplies a backend (§4.1) and answers these questions in it:

| Concern | Java | Elsewhere |
| --- | --- | --- |
| symbol ids | qualified name and parameter types | without overloading (Python, TypeScript, Go), module path plus name, with the class where there is one |
| imports | packages map to paths | Python packages and relative imports; TypeScript `tsconfig` paths, `index` files and `node_modules`; Go module paths; Rust `mod`/`use` |
| receiver types | declared | optional or absent (Python, JavaScript): name-only resolution and the language server become the main means, not a fallback or a confirmation (§5.3, §5.5) |
| dispatch | subtypes of an interface | duck typing, protocols and structural interfaces (Go, TypeScript): implementations matched by method set, `INFERRED` |
| statements and arms | blocks | indentation blocks, closures and callbacks, `async`/`await`, `match`, `defer` |
| success path | `if … return/throw` | Go's `if err != nil { return err }` is already a guard by the same rule; Rust's `?` and `Result` arms; Python's `try/except` |
| sinks and hand-offs | JDBC, HTTP clients, executors | `requests`/`fetch`, `asyncio.create_task`, goroutines and channels, `setTimeout`, event emitters |
| entry points (§8.1) | `main`, annotations | `if __name__ == "__main__"`, route decorators (FastAPI, Flask), Express routes, CLI frameworks |
| tests (§12) | JUnit | pytest, Jest/Vitest, `go test` |
| debugger (§12.2) | java-debug | debugpy, js-debug, delve |
| library sources (§4.4) | source jars, jdtls | usually plain source already: `site-packages`, `node_modules`, the Go module cache |

Python is the second backend. It resolves module-qualified symbols such as `python:checkout.pipeline.handle`, relative imports, re-exports, and calls on receivers inferred from assignments and constructors. Calls that cannot be bound statically may use name-only inference or remain unresolved. Python recognizes `__main__` guards and common route decorators as entry candidates and discovers pytest-style tests. Test discovery is available for Python. Debugger recording currently uses the Java adapter.

Java is enabled by default. Enable Python in Neovim with `ast = { languages = { "java", "python" } }` in plugin setup. Headless CLI commands use `CODE_TOUR_AST_LANGUAGES=java,python` to select both backends. Use `CODE_TOUR_PARSER_RUNTIME` to add a Neovim runtime directory containing the parsers.

## 5. Resolution

### 5.1 In-file binding

After pass 2, each site is first tried against its own file, as graphify does: a bare call against the declaration table and the enclosing type's members; `this.m()` against the enclosing type; a receiver whose declared type is a type in this file against that type's members. Bound sites are `EXTRACTED`.

### 5.2 Project-wide binding

Remaining sites are resolved against the index.

**Type names.** A simple name `T` used in file `F` inside type `C` is tried in order:

1. type parameters in scope → generic, unresolved
2. nested types of `C`, then of each enclosing type, including inherited member types
3. single-type imports of `F`
4. types in `F`'s package
5. wildcard imports of `F`
6. the language's built-ins (§5.3) → built-in, unrated. A built-in name reached by rule 3, 5 or a qualified spelling from the platform's packages (`java.util.List`, `java.util.ArrayList`) is a built-in too, since such types are always imported; other platform types (`java.net.http.HttpClient`) are library types (rule 8), so sinks and hand-offs among them can be rated
7. a unique project type with that name → `INFERRED`
8. otherwise → a library type, resolved through library sources when they are available (§4.4), else library, unresolved

An import binds only to a project type whose file declares the imported package (graphify's package check).

**Receivers.**

| Descriptor | Type |
| --- | --- |
| `id` | innermost local in scope; else a parameter; else a field of the enclosing type, its supertypes and enclosing types; else a type name (a static call) |
| `this` / `super` | the enclosing type / its single superclass; `Outer.this` gives the outer type |
| `field` | the object's type, then that type's field |
| `call` | the resolved callee's `returns`, resolved in the callee's file |
| `new`, `cast` | the named type |
| `lit` | a built-in |

**Members.** `name` with `arity` is looked up on the type, then up its supertypes: the superclass chain first, then interfaces level by level (graphify's "class wins"). The first level with a match decides. Varargs match `arity ≥ n − 1`. `new T(…)` resolves to `T`'s constructor; a type with no explicit constructor gets a `references` edge (`context: new`) and no call. `this(…)`/`super(…)` resolve to constructors of the type and its superclass. `X::m` matches any arity.

**Overloads with the same arity** are scored by the argument types that can be inferred (literals, typed locals, `new`, casts). One best candidate → `EXTRACTED`; a tie → all kept, `AMBIGUOUS`.

### 5.3 Built-ins and fallbacks

- Built-in names are listed **per language** (`backend.builtins`), never in a shared list, so a project method named `max` keeps its callers.
- **No name-only fallback**: a call whose receiver type is unknown stays unresolved and is never bound by bare name. Generated members come from `ast/synth.lua`, and configured `ast.boundaries` edges bind as `via: boundary`. (Removed rule: a project method unique by name and arity, except for common names (`get`, `set`, `add`, `put`, `apply`, `run`, `call`, `accept`, `test`, `of`, `map`, `size`, `equals`, `hashCode`, `toString`, `close`, `remove`, `contains`, `isEmpty`, `build`).
- **Record accessors** (`line.item()`) are `accessor` sites with a `references` edge to the component, not calls. Explicitly declared accessors are ordinary methods.

### 5.4 Dispatch

A site whose target is abstract lists the implementations: overriding methods with bodies in project subtypes, anonymous classes and enum-constant bodies included, each an `INFERRED` edge with `via: dispatch`. A method overrides another when the names and arities match and each parameter is spelled the same or is a type variable of the overridden method (`Handler<T>.handle(T)` ← `handle(Order)`). The abstract method stays on the site as `declared`. With no implementation in the project, the site has no target and is `unresolved: abstract`; on the main flow that is a gap (§8.3). The route chooses among several implementations (§8.5).

### 5.5 LSP confirmation (deferred)

The AST route currently uses deterministic resolution and explicit agent edges. In the planned confirmation pass, when an LSP client with `textDocument/definition` is attached (for example jdtls), sites that are `INFERRED` or `AMBIGUOUS` **and on the route** are confirmed in one batch before the skeleton is shown. Agreement would raise them to `EXTRACTED`; a different answer replaces the target with `via: lsp`. A time budget applies (`ast.lsp_budget_ms`, default 1500).

### 5.6 Code wired up by frameworks (later)

The main flow must be explained in full (§8.3), but frameworks often connect its layers in ways the syntax tree cannot see: a request reaches a handler through a URL mapping, a dependency arrives by injection, and some interfaces are implemented by the framework at run time, with no implementation in the project. In a Spring application, for example, the main flow of an API call runs controller → service → repository, and the last two links are exactly of this kind.

Until anything framework-specific exists, such links appear as gaps (§8.3), and the agent closes them with `--edge` (§9.6), so the main flow is still complete and nothing is claimed that the code doesn't show. If gaps of this kind prove common, a later **framework layer** on top of a language backend could supply the missing facts mechanically: entry points, injection targets, stops for framework-implemented code, and annotations that change behaviour. This spec does not define one.

## 6. Enrichment

### 6.1 Metrics

Computed in pass 2, no LLM: `lines`, `statements`, `branches`, `loops`, `sites`, `project_sites`, `field_writes`, `throws`. They feed the route's importance score (§8.4) and the agent outline.

### 6.2 Other graphs

The plugin reads no other tool's graph and takes no hints from one. The knowledge the agent needs comes from the project graph the plugin itself persists (`.code-tour/graph.json`, §15) and the lazy views over it (`code-tour analyze`: communities, hubs, crossings, neighbors). Agent-written concepts (§15.2) add the semantic layer.

## 7. Where explanations attach: region selection

Selection turns a symbol's statement tree into the regions that get boxes. It is deterministic.

| | overview | normal | detailed | exhaustive |
| --- | --- | --- | --- | --- |
| child regions | none | yes | yes | yes |
| `min` / `target` / `max` lines | — | 3 / 8 / 15 | 3 / 6 / 12 | 2 / 5 / 10 |
| nested regions | none | compound statements over `max` | over `max` | over `max`, and every multi-arm `if`/`switch`/`try` |
| symbol too short for children | — | ≤ 6 lines, or one group | ≤ 5 | ≤ 4 |

Rules, applied to the top-level statements in order:

1. **Hard boundaries** close the current group before a statement: a compound statement longer than 3 lines (it becomes its own region); a leading comment (it opens the new region).
2. **Soft boundaries**, once the group has `min` lines: a blank line before the statement; exceeding `target`; a change of role (setup → work → result).
3. **Guard runs**: consecutive guard `if`s, with the statements that only compute what they test, form one `guard` region.
4. **Walked calls end a beat**: a statement containing a walked site closes its region after itself, so the walk reads region → callee → next region, with the badge in the box just read.
5. **Recursion**: a region that is one compound statement longer than `max` gets child regions, one per arm (`then`/`else`, each `case`, each `catch`, `finally`, the loop body), selected with the same rules; arm headers (`} else {`, `case X ->`) belong to the arm they introduce.
6. **Runts**: a region under `min` lines merges into its smaller neighbor, unless it is a guard run or contains a walked site.
7. **Kinds and facts**: each region gets its `kind` and the mechanical `facts` the outline shows (§9.2).

**Roles.** Rule 2's change of role, and region kinds, rest on a role given to each top-level statement by the first test that matches:

| Role | Statement |
| --- | --- |
| `guard` | a guard `if` (§4.2), or a statement in a guard run (rule 3) |
| `result` | the trailing run that ends the method: its last statement is a `return`, or an `if`/`switch` whose arms all return or throw, extended backward over statements that only declare locals used by it |
| `delegate` | a statement whose substance is one main site (§8.3) whose target has an effect, with or without assigning its result: `result = gateway.charge(discounted);` |
| `work` | a statement that writes a field, contains a site whose target has an effect, or is a compound statement |
| `setup` | any other declaration or assignment of a local: values computed for later statements, including by carrier calls without effects |
| `mixed` | anything else (a bare call to a library method, an expression statement) |

A region's kind is its statements' role when they share one, `loop`/`branch`/`try`/`switch` for a region that is one compound statement, `root` for a symbol's root region, and `mixed` otherwise. In `checkout`, the two guards form `r1` (`guard`), the `total` and `discounted` declarations `r2` (`setup`), the charge `r3` (`delegate`), and the final `if` with its returns `r4` (`result`).

Because regions are syntax nodes or runs of sibling statements, every region has an address, and coverage is exact.

**Nesting across levels.** Selection runs from the coarsest level to the finest. Every boundary chosen at one level is kept at each higher level, which may only add boundaries inside existing regions, and a runt merges only within its parent at the lower level. Each region at a higher level therefore lies inside exactly one region of every lower level, and a region that a higher level does not split keeps its address. That is what lets a box keep its bodies across levels (§3.5). Because the walked set is the main flow at every level (§8.6), rule 4 places the same boundaries at every level.

**Selections.** When the reader selects code (`ae`, `ar`), the selection maps to the smallest region containing it. If none matches closely (the selection is a few lines inside a large region), the editor creates a synthetic child region for the statements the selection touches, and asks the agent about that region.

## 8. Where to go next: the route

### 8.1 Entries

`entry` accepts a symbol (`OrderService#checkout`, `shop.order.OrderService#checkout(Order)`, `OrderService.checkout`), `path:line` (the symbol at that line), a type (its `main`, else its public methods as consecutive top-level snippets). Several entries are allowed.

The agent turns the user's question into an entry: "what happens when we place an order?" becomes the method that handles it. When the question names a part of the flow ("how is the discount applied when ordering?"), `--through 'DiscountPolicy#apply'` makes the main flow pass through that symbol: the plugin finds the shortest call paths from the entry to it, through project sites, and marks every site on them as main, in addition to the main-flow rule (§8.3).

**Entry-free tours** (`code-tour ast --auto`), after Understand Anything's entry scoring, on a full index:

| Signal | Score |
| --- | --- |
| a `main(String[])` method, or a type named `Application`, `Main`, `*Controller`, `*Handler`, `*Command` | +3 |
| framework entry annotations (`@SpringBootApplication`, `@RestController`, `@GetMapping`…, `@Test` excluded) | +3 |
| no project callers (fan-in 0) | +1 |
| top 10% by project sites (fan-out) | +1 |
| shallow path from the source root | +1 |

The top candidates are returned for the agent (or the reader) to pick from; nothing is walked until one is chosen.

### 8.2 Labels and ratings

Depth-first from each entry, visiting sites in evaluation order. Some sites get a **label**: a fact unrelated to importance. Labelled sites are never rated:

| Check, in order | Label |
| --- | --- |
| no target, or a built-in | `unresolved`, listed in the outline |
| `accessor` site | `accessor` |
| target on the current path, or already visited | `ref`, why "already shown" |
| same target already reached from this symbol | `ref` |

Every other site gets a **rating** from the agent's route (§8.3) and nowhere else, an integer where 0 is the main walk:

| Condition | Rating |
| --- | --- |
| the route names the call (`from → to`, optionally limited to one call by `site`) | its `level`, 0 to 5 |
| `--rate nK.sJ=N` (§9.6) | N |
| otherwise | 9, why "not in the route" |

The plugin never scores a call. 9 lies above every cutoff, so a call the route does not name is always lazy: the reader can open it, but nothing offers it. `N = 5` is the largest rating any cutoff reaches (§8.6).

**Effective rating** = the larger of a site's own rating and the effective rating of the edge that reached its symbol. A call can never rank above the call that leads to it, so every cutoff produces a connected tree, and no gold call sits beneath a red one.

`AMBIGUOUS` sites, and sites with several implementations (§8.5), are rated like any other, but their mode is at most `optional`: the reader chooses the candidate.

### 8.3 The route: the agent decides the flow

The **main flow** is the vital path through the code from the entry to its end: the calls without which the entry would not do what it exists to do. **The agent chooses it.** It studies the project graph and the code (§1 steps 1–2), then supplies the route as edges:

```json
[{"from": "OrderService#checkout", "to": "Order#total", "level": 0},
 {"from": "OrderService#checkout", "to": "Notifier#send", "level": 3, "site": "email.send"}]
```

`from` and `to` are symbol specs (§8.1); `level` 0 is the main walk, 1 to 5 are optional branches, offered by detail (§8.6); `site` limits an edge to the one call written as that text. The route is passed as `--route FILE`, `--walk 'A -> B'` and `--branch 'A -> B@N'`, on `ast`, `adjust`, `flow` and `explain`; it is stored in the recipe and re-applied on every rebuild, and its endpoints follow a renamed symbol like entries do (§11.5). An edge that matches no resolved call is a warning. Naming a concrete implementation settles a dispatch among several (§8.5). `--through SYMBOL` is a helper that routes the shortest call path from the entry to a symbol at level 0.

**The main flow is always walked and always explained in full, at every detail.** `ast.main_cap` (default 40 main snippets) bounds it as protection against pathological routes: past the cap, the tour warns and the remaining main sites become `lazy`, why "main cap".

The plugin still reports **facts** about the code the route walks:

- **Success path and forks.** For region selection (§7) the plugin knows which statements lie on a method's success path (outside guard consequences, `catch` clauses, terminating arms and all but one `switch` case); where a name-based tie-break decided, the outline lists the **fork** (`fork:`).
- **Sinks.** A library call that leaves the program's memory, listed per backend (`backend.sinks`), is a leaf, listed in the outline (`sink:`).
- **Gaps.** A routed call the code cannot follow: unresolved, abstract with no implementation, several implementations without a named one or a known construction (§8.5), or a **hand-off** (`backend.handoffs`, such as an executor or event publisher). The outline lists each (`gap: s3 bus.publish — target unknown`), the header counts them, and an agent edge (`--edge`, §9.6) or a configured boundary (`ast.boundaries`) closes one.

A tour without a route shows only its entry; every call is lazy until the agent names it.

### 8.4 Complexity

The plugin does compute one number, and uses it only to tell the agent which model should write a box (§9.7), never to choose what the tour shows:

```
score = min(lines, 40) / 5  + 2 × branches + 1.5 × loops + 1.5 × project_sites
      + 2 × field_writes + 1 (throws or catches)
      − 2 (named log/debug/trace/print*/toString/equals/hashCode)
```

Example: `Order.total()` has 7 lines (1.4), one loop (1.5) and one project site (1.5), so `score = 4.4`.

### 8.5 Dispatch on the route

- One implementation → rated and routed to it.
- Several → each is an edge at the same site (the `ad` picker offers them), at most `optional`, why "one of N implementations". If the implementation constructed on the path is known (a `new CardGateway(…)` flowing through locals, constructor parameters and field assignments in visited symbols into the receiver), that one is treated as the only implementation and may be walked.
- None → not routed.
- On the main flow, several implementations with no known construction are a gap (§8.3), and the implementations are offered.

### 8.6 Detail: cutoffs, budget, zoom

Detail never changes the main flow. It decides two things: **which extras are offered**, and **how deeply everything shown is explained**.

| Detail | offer extras rated ≤ | budget (offered snippets) | boxes (§7) | body per box |
| --- | --- | --- | --- | --- |
| overview | 1 | 8 | one per snippet | 2–4 sentences |
| normal | 3 | 15 | groups of about 8 lines | 2–4 sentences |
| detailed | 4 | 30 | groups of about 6 lines | one or two paragraphs |
| exhaustive | 5 | 80 | groups of about 5 lines, every multi-arm statement split | as long as needed, line by line where it matters |

- **Mode**: rating 0 (the main flow) → `walk`; rated ≤ the offer cutoff → `optional`; otherwise `lazy`, why "detail" (or "not in the route"). Gold therefore means the main flow, and only the main flow, at every detail.
- **Budget**: the budget limits extras only. When offered snippets exceed it, they are ordered by effective rating, then by walk order, and those past the budget become `lazy`, why "budget". The final snippet order is still walk order.
- **Zoom**: each call's `level` is its effective rating, and `a-` folds calls above the zoom level, as today. Level 0 is the main flow.
- **Changing detail** on a live tour (§10) moves the offer cutoff only; ratings are not recomputed and the main flow stays put. Boxes are refined or coarsened along nested boundaries (§7), and each box shows its body for the new level from the store, or the nearest level while that one is written (§11.2).
- The cutoffs are tunable (`ast.cutoffs`).

### 8.7 Other walks (later)

The representation supports routes over other edges. The call walk is the default; the others are listed so the model keeps room for them:

| Walk | Follows |
| --- | --- |
| data | a local's use → its definition, across parameters and returns ("where does this value come from?") |
| error | `throw` → the enclosing or calling `catch`; the failure paths the main flow leaves out (§8.3) |
| event | a listener registration → the code that invokes it (usually agent-supplied edges) |

## 9. Agent protocol

### 9.1 Starting a tour

```sh
code-tour ast 'OrderService#checkout' --detail normal
code-tour ast 'OrderService#checkout' --through 'DiscountPolicy#apply'
code-tour ast src/main/java/shop/app/Main.java:9
code-tour ast --auto
```

The editor builds the tour and shows the whole skeleton immediately: boxes with fresh notes in the store (§11.2) are complete at once, and every other box reads "Being written…". It returns the outline, which marks what still needs writing. If the entry has no backend or parser, or the selected symbol has a parse error, the result is `{"fallback": true, "reason": "…"}` and the agent authors the tour as described in SPEC-old.md.

### 9.2 The outline

`ast` prints an outline by default. In a live tour, `--json` returns the outline and pending fill commands along with the tour token. With `--dry-run --json`, it returns the derived tour graph. `--auto` without an entry lists candidates without opening a tour.

```
tour T7f3 · normal · 5 snippets · 4 to write · 0 gaps · fill: code-tour --fill <n> --tour T7f3
models: light=haiku standard=sonnet deep=opus · brief: code-tour brief <n> --tour T7f3

n1 OrderService.checkout(Order)        OrderService.java:15-33   deep   write: overview r1-r4
   r1 15-23 guard     2 guards: order.isPaid(), order.getLines().isEmpty()
                      lazy: s1 Order.isPaid [9 accessor], s2 Order.getLines [9 accessor]
   r2 24-26 setup     locals: total, discounted
                      walk: s3 order.total → n2 [0★], s4 discounts.apply → n3 [0★]
   r3 27    delegate  locals: result
                      walk: s5 gateway.charge → n4 [0★] (PaymentGateway, 1 impl: CardGateway)
                      lazy: s6 Order.getCustomer [9 accessor]
   r4 28-33 result    if !result.ok() return …; else markPaid, return receipt(…)
                      walk: s9 receipt → n5 [0★] · lazy: s8 Order.markPaid [9 setter, main] · accessor: s7 result.ok, result.message
n2 Order.total()                       Order.java:22-28          light  write: overview
   lazy: s1 Line.subtotal [4 detail] (via for-each variable `line`)
n3 DiscountPolicy.apply(Order, Money)  DiscountPolicy.java:18-41 standard  fresh
n4 CardGateway.charge(Money)           CardGateway.java:30-58    deep   write: r2 (stale: code changed), overview (linked)
   r2 41-52 work      sink: s4 http.send (HttpClient)
…
```

Grammar:

- A **snippet line** starts flush left: id, symbol label, `file:lines` for reading, the tier (§9.7), then either `write:` with the boxes that need notes, or `fresh` when every box already has a fresh note (the snippet is listed for context only). Each box listed under `write:` carries its reason when it is not simply missing: `code changed`, `callee changed`, `linked` (a root whose child changed), or `level missing` (fresh at another level, but not yet written at this one, §11.2).
- A **region line** is indented: id, lines for reading, kind, then mechanical facts.
- **Site lines** follow their region, grouped by mode: `walk:`, `optional:`, `lazy:`, `accessor:`, `unresolved:`, `ambiguous:`, each site as `sN text → nM [rating]` (when routed to a snippet), with the lazy reason inside the brackets and a parenthesized note where resolution was not direct. `★` marks the main flow.
- **Main-flow lines** (§8.3) follow the same layout: `sink:` (where the flow ends), `gap:` (where it could not be followed, with the reason), and `fork:` (a success-path choice the agent should confirm).
- Lines and paths in the outline are for reading only. The agent never sends them back.

### 9.3 Writing notes

Each snippet has one fill command, which may be called any number of times. A fill is Markdown with one section per box:

```markdown
## overview
Validate the order, charge the discounted total, then mark it paid and build a receipt.

## r2
Compute the order total and apply discounts.

The total is recomputed from the order's lines rather than cached, so it always reflects the
current contents. The discount policy receives both the order and that total because one rule
depends on the amount and another on the item count…
```

- The **first paragraph** of a section is the gist; the rest is the body.
- A section may repeat in a later fill; the later one replaces the earlier.
- `## r2` may be written `## n1 r2`, and one fill may then carry sections for several snippets.
- JSON is accepted too, as in `{"r2": {"gist": "…", "body": "…"}}`.
- Add a standard example at the end of a box under `### Example (generated)`, `### Example (test)` or `### Example (recorded)`. The JSON equivalent is an `example` object with `text`, `source` and an optional `test` symbol.
- An edge note has its own heading, such as `## edge s3` or `## edge n1.s3`. Add `>SYMBOL` when the site has multiple targets. The JSON equivalent is `{"edge s3": {"text": "…"}}`.
- Bodies are stored at the tour's detail (§3.5), and the outline header names it. A fill for another level passes `--detail`.

### 9.4 Streaming

Snippets are written in walk order, depth-first, as the reader will meet them, each in a single pass: gist and body together. The snippet at the reader's position goes first; with subagents (§9.7), units start in that order and run in parallel. Boxes not yet written read "Being written…".

There is no separate gist pass. It would make the agent read every snippet twice, to produce summaries the reader mostly skips past.

To explain a call without first explaining its callee, each writer receives the **interfaces** of what its snippet calls, mechanically, in its brief (§9.7): each callee's signature, its doc comment, its fresh gist from the store if one exists, and the outline facts of its own main-flow calls. That is usually enough to say what a call does. A writer that needs more reads the callee's code.

Rules:

- Every fill is written to the note store as it arrives (§11.1); there is nothing to save.
- A box is `ready` once its section has arrived, and a snippet is `ready` when all its boxes are. A fill may carry only some of a snippet's sections; the rest keep reading "Being written…".
- A box shows only a fresh note. A stale note is never displayed, even while its replacement is being written.
- The reader is never moved by a fill; a box re-renders in place when its note arrives.
- A fill is refused for a snippet whose source changed since the skeleton was built (`Source changed; rebuild with code-tour ast`); other snippets keep streaming.
- A later section replaces an earlier note for the same box, so the agent can revise until the snippet is `ready`. After that, changes go through the usual refine and explain requests.

### 9.5 Requests from the editor

| Reader action | Request to the agent |
| --- | --- |
| `ad` on a `lazy` site | the plugin builds the target's regions and its own sites (all `lazy`) and inserts the snippet. If the store has fresh notes for all its boxes, nothing is sent. Otherwise the snippet is a placeholder, and `[code-tour ast] n6 …` is sent with that snippet's outline and the caller's box. The agent fills it like any snippet. |
| reopening from history, adjusting the tour, or changing its detail when boxes need writing | `[code-tour ast] write` with the outline lines of the snippets that need writing, each stale box with its reason |
| `ae` / `aE` on a selection | the selection maps to a region (§7). When its note is needed, `[code-tour explain]` names that region and the reply fills it |
| `ar` | answer by the editor’s box ID. The question can suggest a higher configured model tier based on the previous writer |
| `:CodeTourAst [entry or --auto] [detail]` | the editor builds and shows the tour, then sends the whole outline as one `[code-tour ast]` request |

Editor requests include the relevant outline and fill command. Starting a tour from `:CodeTourAst` supplies the full outline when work is pending. Starting from the CLI returns the outline to its caller.

### 9.6 Overrides and additions

The agent can correct the structure without writing numbers:

```sh
code-tour ast 'OrderService#checkout' --rate n1.s8=0 --rate n1.s9=9 # change a site's rating
code-tour ast … --split n1.r4@stmt2                                 # split a region before its 2nd statement
code-tour ast … --merge n1.r2,n1.r3                                 # merge adjacent regions
code-tour ast … --edge 'n4.s3 -> java:shop.audit.Ledger#record(Charge)'   # add an edge the AST cannot see
```

A rating override replaces the computed rating; the effective-rating rule (§8.2) still applies beneath it. Rating 0 is reserved for the main flow, so `--rate n1.s6=0` adds a site to it and `--rate n1.s4=2` takes one out. Settling a fork or closing a gap uses the same operations. The same operations are accepted on a live tour (`code-tour adjust --tour T …`). They are stored in the recipe’s `overrides` and re-applied whenever the tour is rebuilt. The recipe stores site and region identities so it can replay the edits without relying on the original short IDs. Splits and merges apply at the detail where they were authored. A merge is already satisfied when rerating produces the same combined leaf. A live structural adjustment returns a new tour token because a region ID can denote a different range after a split or merge. Use the fill commands from the new outline. A detail-only adjustment retains the token.

### 9.7 Orchestration and model tiers

Several agents can write the fills for one tour at once. The design assumes one capable **orchestrator**, the agent in the user's conversation, that delegates snippets to **subagents** of varying capability. It works unchanged when the orchestrator writes everything itself.

**Tiers.** The plugin labels each snippet mechanically:

| Tier | When |
| --- | --- |
| `deep` | `score ≥ 12`; or a walked site resolved by dispatch, name-only matching or an agent edge; or field writes together with branches; or a `catch` that rethrows, or a `finally`; or concurrency (`synchronized`, executor or thread calls, writes to `volatile` fields) |
| `light` | at most 5 statements, no branches, at most one project site, and none of the `deep` conditions |
| `standard` | otherwise |

The conditions that raise a tier are chosen because they are where a weaker model is most likely to write a confident but wrong explanation, not merely because the code is long. `ast.models` maps tiers to model names and is printed in the outline header. The plugin never calls a model itself.

**Division of work.**

- The orchestrator reads the outline and writes the tour-wide text itself: the overview of each entry and the edge notes (§3.5), which need the whole tour in view.
- It groups the remaining snippets that need writing into **work units** and gives each unit to a subagent of the unit's highest tier. Light snippets are batched several to a unit, since a subagent starts without context and tiny units cost more than they save.
- Units are snippets, never single regions. The regions of one method share their code and context, and later boxes refer to earlier ones.
- Each subagent takes its brief from `code-tour brief`, writes its snippet's sections in order, and fills **directly** with `code-tour --fill N --tour T --model M`. The explanations never pass back through the orchestrator, which only receives `done` or `escalate: <reason>`.
- On escalation, the orchestrator reruns the snippet one tier up. It also does this when a reader asks about a box written by a lighter model (`ar`), or needs it at a higher detail.
- Editor requests (§9.5) are dispatched the same way.
- Without subagents (an agent that cannot delegate, or `ast.models` unset), the orchestrator writes everything, and tiers are informational.

**The brief.** `code-tour brief n3 --tour T` prints everything one snippet needs and nothing else:

- a pointer to the skill's style rules;
- the tour's overview gist, the caller's box, and the edge note (why the tour comes here);
- the snippet's outline lines;
- the **interfaces** of the snippet's callees: signatures, doc comments, and fresh gists where the store has them (§9.4);
- the code, with region boundaries marked by id;
- for stale boxes, the previous note, labelled as describing older code: a starting point for the writer, never shown to the reader;
- the fill command.

Fills from several writers are accepted concurrently. Ordinary writer fills address one snippet by default. Explicit snippet headings allow a fill to address multiple snippets. The editor serializes RPC calls, and repository writes use a lock and atomic replacement.

## 10. Editor behavior

- The skeleton, badges and route appear before any agent work, and boxes with fresh notes in the store are complete at once. Badge columns come from site ranges.
- Main-flow badges carry a distinct mark (`CodeTourMainCall`: a stronger gold with `★`), so the main flow stands out without zooming; `a-` to level 0 shows only the main flow. Gaps appear as a badge on the site where the flow breaks off, with the reason.
- A box reads "Being written…" until its section arrives. A zoomed-out walk (`a-`) and `an`/`ap` show gists; the focused box shows the body. Stale notes are never shown (§3.5).
- `:CodeTourDetail {detail}` (and `code-tour adjust --detail`) changes the detail of a live tour (§8.6). The main flow stays; extras enter or leave the tour; boxes are refined or coarsened along nested boundaries (§7); and each box shows its body for the new level, so only levels never written for that box are requested.
- `:CodeTourTree` labels snippets with gists once they exist.
- `:CodeTourGraph` writes node-link JSON with the rendered graph at the top level and the AST tour and its symbol subgraph under `tour` and `symbol_graph`. `:CodeTourCodeGraph` exports the project symbol graph (§15).
- Everything else (walk order with returns, zoom, Q&A, review diffs, the text view) is unchanged and operates on the projected stops.

## 11. The note store

### 11.1 Automatic persistence

- **One store per repository** holds every note and edge note written for it, attached to region addresses and fingerprints. It is one central place, like Understand Anything's `.ua/knowledge-graph.json` or graphify's `graphify-out/graph.json`. Unlike them, it is written incrementally, one fill at a time, and nothing is computed up front.
- **No save command.** Every fill is written as it arrives, atomically (a temporary file, then a rename). Concurrent editors re-read the file before writing, so neither loses the other's notes.
- **Location**: `.code-tour/` at the repository root, beside the code it describes, as graphify keeps `graphify-out/` and Understand Anything keeps `.ua/`. Only notes, recordings and tour history live there; parsed syntax facts are cheap to rebuild and stay in `stdpath("cache")`.
  - **Worktrees**: the store resolves to the *main* worktree's root (the parent of `git rev-parse --git-common-dir`), so every worktree reads and writes one store.
  - **Ignored locally by default**: on first use the plugin adds `.code-tour/` to `.git/info/exclude`, not to `.gitignore`, so it stays out of `git status` without creating a tracked change. A team that wants to share explanations removes that line and commits the directory.
  - **Conflicts**: a note file that git reports as conflicted is treated as stale and regenerated, never merged by hand. One file per source file keeps conflicts rare.
  - `ast.store = "user"` keeps the store in `stdpath("data")/code-tour/store/<hash of the first commit>/` instead, outside the repository.
- **Layout**:
  - `notes/<path hash>.json`: one file per source file, holding that file's notes and edge notes;
  - `tours.json`: tour recipes (§11.5);
  - `recordings/`: recorded runs (§12.2);
  - `meta.json`: validation state (§11.3).
- A shared library note store is planned with library source navigation (§4.4).
- **Versions**: a note is keyed by address *and* fingerprint, and up to `ast.store_versions` (default 3) versions are kept per address. Switching branches back and forth therefore reuses the note for each version instead of rewriting it. Each version holds its gist and all its level bodies, so levels never push each other out.

### 11.2 Lookup

Every request that needs a box looks it up in the store before asking the agent: a new tour, a change of detail, `ad`, `ae`, or a tour reopened from history.

| The store has | Outcome |
| --- | --- |
| a fresh note (this address, this fingerprint, fresh callees) with a body at this level | shown; no agent work |
| a fresh note with a body one level away | that body, marked with its level ("normal"), while this level is written in the background and replaces it in place |
| a fresh note with bodies only further away | the gist; the body reads "Being written…" and is requested (`detail`) |
| a note with this fingerprint at another address in the same symbol | reused at the new address (code moved within the method) |
| a note with this fingerprint under a symbol that no longer resolves | reused (the method was renamed or moved) |
| a note at this address with a different fingerprint, or with a changed callee | stale: "Being written…", regenerated |
| nothing | missing: "Being written…", requested |

- A body one level away is not stale: it describes the current code, only at another depth. A body further away is withheld because it would read as too thin, or too long, for the level asked for.
- A box that exists only at some levels (a normal box that detailed splits in two, §7) has its own address, so other levels' bodies never apply to it. They are not lost: switching back to their level shows them again.
- Only the level being viewed is regenerated when a note goes stale; its other levels are rewritten when they are next viewed.
- A root region's fingerprint covers its children, so any change inside a method also makes its overview stale. Such a root is **linked**, and it is regenerated in the same work unit as the changed child.
- A symbol id that no longer resolves, and whose fingerprint is found nowhere, makes its snippet reported as missing, and its callers' sites become unresolved.

### 11.3 Freshness

Three checks run, cheapest first:

1. **Store commit.** `meta.json` records the commit and the working-tree state at the last validation. An individual version whose recorded commit matches HEAD can use this fast path when its source and callee files were clean at validation and remain clean.
2. **Changed files.** Otherwise the current blob SHAs of those files (`git ls-files -s`, or `git hash-object` for modified and untracked files) are compared with the recorded ones. A note is fresh if its file is unchanged and the files of all its recorded callees are unchanged too.
3. **Fingerprints.** For the remaining notes, the region is fingerprinted again (`ts-scoped-leaves-v1`), and each recorded callee's root fingerprint is compared. Tree-sitter fingerprints ignore formatting and comments. Agent ranges without a usable parser use text fingerprints.

A change confined to a method body is never treated as cosmetic, as Understand Anything treats it, because explanations describe bodies. A commit is never the test for a single note: it says nothing about the other methods in a file, nothing about uncommitted edits, and it differs between branches that hold identical code. Validation runs on demand, only for the regions a request touches, and updates `meta.json` afterwards.

### 11.4 Stale text and reports

- Stale notes are never shown. The latest version stays in the store and goes into the brief (§9.7) as a starting point for the rewrite.
- Q&A threads are hidden with a stale note and kept (§3.5).
- When a tour opens with stale boxes, a notification lists them with reasons (`code changed`, `callee changed`, `symbol missing`), and the write request (§9.5) carries the same list.

### 11.5 Tour history

`tours.json` keeps recent recipes with entries, detail, through-symbols, overrides and the last-opened time. `:CodeTourHistory [id]` lists or opens those recipes for the current repository. Reopening reruns the recipe and uses stored fingerprints to recover a uniquely matching renamed entry or route endpoint. Missing entries are reported and surviving entries still open. Agent-supplied ranges retain a line hint and a relocation fingerprint. Tours authored entirely as stops keep the existing save format in SPEC-old.md.

### 11.6 Pruning

`code-tour store --prune` removes:
- versions beyond `ast.store_versions`;
- notes whose file no longer exists;
- notes not read for `ast.store_ttl_days` (default 180) whose address can be checked at `HEAD` and no longer resolves. TTL pruning preserves existing-file notes when the required backend, parser or usable HEAD source is unavailable.

## 12. Examples

### 12.1 Kinds

- A box's **standard example** ("an order of 2 lines totalling 30 and a 10% discount, so 27 is charged") is part of its explanation. It is stored in the note (§3.5), shown at normal detail and above, and goes stale with the note.
- **Requested examples** ("show me with an empty order", "what if the card is declined?") are answers to questions. They live in the box's Q&A thread and never become its explanation, so the next tour does not present one reader's scenario as the box's example.

Every example shows its source: `test`, `recorded`, `executed` or `generated`.

### 12.2 Sources, preferred first

The agent should invent as little as possible: the project's tests and its running code supply most of an example's substance, and what they supply is true by construction.

1. **Tests, mechanically.** The symbol graph indexes test methods (in test source roots, annotated `@Test` or in classes named `*Test`/`*Tests`) whose sites reach a symbol, directly or along its main flow. Python also recognizes pytest-style names. The most direct test, then the one with the most assertions, is offered beside the root box as an extra snippet of kind `example` (why "example: test"). Open it with `:CodeTourExample` or select it from the snippet list. The agent writes nothing; at most it adds one sentence to the standard example pointing at the test.
2. **Recorded runs.** `:CodeTourRecord` runs the selected Java test through nvim-dap, jdtls and the Java Debug and Java Test extensions. The default consent prompt remembers the reader’s Allow or Decline decision for the project in `meta.json`. It stops at the region boundaries of the main-flow snippets and records the locals: primitives and strings in full, other objects by `toString()` truncated to 80 characters. The tour then shows real values inline as virtual text (`total = 30.00`, `discounted = 27.00`, `result.ok = true`), a data-flow example produced entirely by execution. A recording is keyed by the test’s identity and fingerprint together with the main-flow region fingerprints. Recordings are stored under `recordings/` and are reused only for matching code. `ast.record_timeout_ms` (default 30000) bounds a run.
3. **Executed scenarios.** For a requested Java example, the agent submits the source of a scratch `CodeTourScenario.java` with a launcher that builds the inputs and calls the symbol. Use `code-tour scenario BOX FILE --tour T` for a pending question. The plugin compiles the launcher against the project’s test classpath, captures values through the debugger, and adds them to the Q&A thread alongside the scenario code. Scratch files live in `stdpath("cache")`.
4. **Generated**, as today, only when nothing can run (no build, no debugger, no consent). Such examples are marked `generated`, so the reader knows they are illustrative.

### 12.3 Safety

- Only tests and scratch scenarios are ever run, never the application itself, and only after consent. Tests may still touch real resources (a database, the network); the consent prompt says so.
- Runs happen in the background and never block the tour. A failed or timed-out run falls back to the next source.
- Everything degrades gracefully: without a debugger, tests are still offered (1); without tests, examples are generated (4).

## 13. Using the store while coding

Like graphify, whose `query`, `path` and `explain` commands let an agent consult the graph before touching code, the symbol graph and the note store serve any coding agent, not only tours. An agent about to change code it has not read can learn the main flow, the explanations already written, the callers that depend on it and the tests that exercise it, without reading every file.

### 13.1 Commands

They work with or without a running editor; without one they run Neovim headless. All accept `--pane` to query a running editor, `--json` for compact JSON and `--budget N` for an approximate token budget. The budget keeps gists ahead of optional body text.

| Command | Returns |
| --- | --- |
| `code-tour explain SYMBOL [--detail D]` | the symbol's boxes with fresh gists and bodies at the level, its standard example and its tests; stale boxes listed by address and reason, never their text |
| `code-tour flow ENTRY [--through S]` | structured main-flow data (§8.3) with outline lines and fresh gists. The command reads the graph without opening a tour or requesting prose |
| `code-tour callers SYMBOL` | every call site of the symbol, with confidence and `via` |
| `code-tour impact SYMBOL` | callers transitively (depth 3), the notes a change would make stale (those recording it as a callee), and the tests that reach it |
| `code-tour path A B` | shortest call paths between two symbols |
| `code-tour search "TEXT"` | symbols whose names, gists or bodies match, ranked, with their gists |

The never-show-stale rule (§3.5) applies to agents too: a stale explanation would mislead an agent as surely as a reader.

### 13.2 Integration

- `code-tour agent install` writes a `## code-tour` section to the project's `CLAUDE.md` and `AGENTS.md`, as `graphify claude install` does (`code-tour agent uninstall` removes it). It tells the agent to:
  - run `code-tour flow` or `code-tour explain` before changing code it has not read;
  - run `code-tour impact` before changing a symbol's behaviour or signature;
  - treat notes as orientation and the code as the authority.
- The code-tour skill's description also triggers on questions about the codebase when `.code-tour/` exists, as graphify's does when `graphify-out/` exists.
- No rebuild hook is needed, unlike graphify's post-commit hook: structure is computed on demand, and notes are checked by fingerprint whenever they are read.

### 13.3 Writing back

As graphify's `save-result` feeds answers back into its graph, an agent that has come to understand some code while working can record it: `code-tour note SYMBOL FILE` takes Markdown sections as in §9.3, addressed by the region ids that `explain` or `flow` printed, at a given `--detail`. Such bodies carry the agent's `model` and `source: coding`. Writing back is optional and never required. Notes on code the agent then changes go stale by fingerprint like any other.

## 14. Fallback: the same representation without a parser

When a symbol has no backend or parser, pass a JSON range via `code-tour ast --add` or `code-tour adjust --add`. The supplied code becomes a snippet with `source: agent`. Include a `site` to attach it to a call or omit `site` to create an entry:

```json
{"site": "n4.s10", "file": "src/main/kotlin/shop/payment/StripeClient.kt", "start": 12, "end": 30,
 "regions": [{"start": 12, "end": 19}, {"start": 20, "end": 30}]}
```

- Agent regions are addressed by file and fingerprint, and their notes go into the note store like any other. Lookup relocates them by fingerprint when lines move.
- A tour can contain only `--add` entries. The existing stop-based authoring workflow also supports wholly agent-authored tours and exports agent provenance for their boxes.
- An agent-supplied snippet has no sites of its own unless the agent lists them (`"sites": [{"text": "client.post", "line": 14, "target": "…"}]`).

## 15. The project graph, analysis and concepts

### 15.1 The persisted graph

`code-tour codegraph [--project DIR] [--out PATH] [--rebuild] [--pane P]` writes the resolved symbol graph to `.code-tour/graph.json` (kept out of git like the notes) as node-link JSON (a directed multigraph): `id`, `label`, `file_type: "code"`, `source_file`, `source_location` (`L<n>` or `L<a>-<b>`), `kind`, `signature`, `metrics` for bodies; links are the relations of §3.4, each call site its own `calls` link keyed by site id with `confidence`, `via`, `callsite`, `call_range` and `origin`. The graph carries a **manifest** (each file's hash, the language set, the boundary rules and the synthesizer names); a request reuses the file while the manifest matches and rebuilds otherwise, re-extracting only changed files because facts are cached by blob SHA. `--out` writes elsewhere. Without `--pane` the command runs Neovim headless; with it, the editor's unsaved buffers count.

Members generated at build time (Lombok `@Builder`, `@Getter`, `@Setter`, `@Data`, `@Value`, constructors) are synthesized from annotations (`ast/synth.lua`, user rules in `ast.synthesizers`) as implicit symbols, and `ast.boundaries` binds calls the language cannot follow. A call is never bound by its bare name.

### 15.2 Analysis and concepts

`code-tour analyze VIEW` computes lazily over the graph and caches in `analysis.json` under the manifest hash: `communities` (label propagation over containment, calls, inheritance and references, seeded by file so files merge rather than single symbols, with clusters under three symbols absorbed by their strongest neighbour; named by dominant package and type or module). Test code is left out of every view unless `--tests` is given, because tests call everything and fuse unrelated modules into one cluster. On a 589-file Python project (12k symbols) the first run takes about ten seconds and yields about a hundred communities, `gods` (the symbols with the most distinct callers and callees), `crossings` (calls between communities, grouped by pair) and `neighbors SYMBOL` (callers and callees with `confidence`, `via` and the symbol's concepts). These are facts about the graph's shape, never a ranking of importance.

`code-tour concept add NAME --members SYMBOL… [--summary TEXT]`, `concept list` and `concept remove ID` keep **concepts**, the semantic layer: the agent names an idea and the symbols that implement it while it explains code. A concept is a hyperedge over the graph stored in `concepts.json`; each member keeps a fingerprint of its source, so a concept turns stale member by member when the code changes (`fresh`, `stale`, `missing`). The plugin extracts nothing semantic itself. `analyze concepts` lists them.

## 16. Commands, RPC and options

| CLI | RPC | Does |
| --- | --- | --- |
| `code-tour ast ENTRY… [--route FILE] [--walk/--branch EDGE…] [--through SYMBOL…] [--detail D] [--auto] [--force] [--json] [--dry-run] [--rate/--split/--merge/--edge/--add …]` | `ast_tour(request)` | build, show the skeleton, return the outline |
| `code-tour --fill N --tour T [--detail D] [--model M]` | `fill(id, payload, opts)` | for AST snippets, attach notes (§9.3) and write them to the store |
| `code-tour brief N --tour T` | `ast_brief(id, tour)` | one snippet's brief for a subagent (§9.7) |
| `code-tour adjust --tour T [--detail D] …` | `ast_adjust(ops)` | change detail, or apply overrides, on a live tour |
| `code-tour store --prune` | `store_prune(opts)` | §11.6 |
| `code-tour explain/flow/callers/impact/path/search …` | `know(cmd, args)` | the store and symbol graph for coding agents (§13.1) |
| `code-tour note SYMBOL FILE [--detail D] [--model M]` | `know("note", opts)` | write back an explanation (§13.3) |
| `code-tour scenario BOX FILE --tour T` | `ast_scenario(opts)` | run a scratch Java scenario for a pending question (§12.2) |
| `code-tour agent install/uninstall` | | the `CLAUDE.md`/`AGENTS.md` section (§13.2) |
| `code-tour codegraph [--project DIR] [--out PATH] [--rebuild] [--pane P]` | `code_graph(opts)` | write or reuse the persisted graph (§15.1) |
| `code-tour analyze communities\|gods\|crossings\|neighbors SYMBOL\|concepts` | `analyze(opts)` | lazy graph analysis (§15.2) |
| `code-tour concept add\|list\|remove …` | `concepts(opts)` | agent-authored concepts (§15.2) |
| `:CodeTourAst [entry] [detail]` or `:CodeTourAst --auto [detail]` | | editor-initiated tour or entry picker (§9.5) |
| `:CodeTourDetail {detail}` | | change detail on the current tour (§10) |
| `:CodeTourHistory [id]` | | open an AST recipe from the repository history |
| `:CodeTourExample` | | open the current snippet’s test example |
| `:CodeTourRecord` | | capture Java test locals for the current tour |
| `:CodeTourCodeGraph` | | export the project symbol graph and show its path |

| Option | Default | Meaning |
| --- | --- | --- |
| `ast.enabled` | `true` | `false` makes `ast_tour` always fall back |
| `ast.languages` | `{"java"}` | backends to use |
| `ast.detail` | `"normal"` | default detail |
| `ast.max_files` | `5000` | full-scan cap |
| `ast.boundaries` | `{}` | cross-boundary edges `{call, to}` that continue a call the language cannot follow (§5.6) |
| `ast.synthesizers` | `{}` | rules for members generated at build time (Lombok and the like), per language |
| `ast.ignore` | `{}` | extra paths to remove from git's file list (§4.3) |
| `ast.cutoffs` | the table in §8.6 | offer cutoff and budget per detail |
| `ast.main_cap` | `40` | most main-flow snippets in a tour (§8.3) |
| `ast.models` | `{}` | tier → model name for delegation (§9.7); empty means no delegation |
| `ast.store` | `"repo"` | `"repo"` (`.code-tour/` in the main worktree) or `"user"` (data directory) |
| `ast.examples` | `{tests = true, record = "ask"}` | example sources (§12.2); `record` is `"ask"`, `true` or `false` |
| `ast.record_timeout_ms` | `30000` | bound on a recorded run |
| `ast.store_versions` | `3` | note versions kept per address |
| `ast.store_ttl_days` | `180` | pruning age for notes whose address no longer resolves |

## 17. Tests

The Java fixture covers a multi-package checkout flow, interfaces with one or several implementations, a record, same-arity overloads, lambdas, inner classes, recursion, wildcard imports and a method named `max`. The Python fixture covers module IDs, relative imports, re-exports, nested functions, receiver inference and entry markers. Both are under `tests/fixtures/`.

Run the Neovim scripts individually. `tests/ast_common.lua` is a helper. The AST scripts load parsers from `CODE_TOUR_PARSER_RUNTIME` or the local Neovim site directory and report missing parsers. Editor integration tests use local Neovim RPC sockets.

```sh
export XDG_STATE_HOME="$(mktemp -d)"
export NVIM_LOG_FILE="$XDG_STATE_HOME/nvim.log"
for test in tests/*.lua; do
  case "$test" in tests/ast_common.lua) continue ;; esac
  nvim --clean --headless -l "$test" || exit
done
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py'
```

| Files | Coverage |
| --- | --- |
| `tests/ast_extract.lua`, `tests/ast_resolve.lua` | Java declarations, lexical scopes, sites, statement trees and deterministic resolution |
| `tests/ast_regions.lua`, `tests/ast_route.lua` | region boundaries and nesting, success paths, carriers, effects, hand-offs, ratings, detail budgets and dispatch |
| `tests/ast_project.lua`, `tests/ast_render.lua`, `tests/ast_detail.lua` | projection, badges, note display, detail round-trips and reader position |
| `tests/ast_stream.lua`, `tests/ast_fill.lua`, `tests/ast_expand.lua`, `tests/ast_live.lua` | partial and revised fills, lazy calls, stale-fill rejection, selection and live state |
| `tests/ast_store.lua` | worktree and user stores, conflicts, versions, relocation, freshness, Q&A, concurrent fills, history and pruning |
| `tests/ast_examples.lua`, `tests/ast_recordings.lua` | test ranking and navigation, consent, executed example Q&A, recording fingerprints and mocked debugger lifecycle |
| `tests/ast_tiers.lua` | tier rules, brief contents, previous stale text and model attribution |
| `tests/ast_enrichment.lua`, `tests/ast_fallback.lua` | hints, entry candidates, overrides, parser errors, missing backends and agent-authored ranges |
| `tests/ast_python.lua` | opt-in extraction, resolution, route, entry discovery and symbol export |
| `tests/test_cli.py`, `tests/test_library_cli.py` | headless queries, write-back, live RPC, CLI parsing, graph export and the saved-tour library |

The graphify interoperability test loads and merges the fixture export with graphify’s own extraction and checks the endpoints. It reports a skip if graphify is unavailable.

The opt-in Java debugger test uses a JDK, Mason installations of jdtls, Java Debug and Java Test, plus nvim-dap and nvim-jdtls. Run it with `CODE_TOUR_REAL_JAVA=1 nvim --clean --headless -l tests/ast_java_debug.lua`. Set `CODE_TOUR_JAVA_MASON` or `CODE_TOUR_JAVA_NVIM_PLUGINS` if the dependencies live outside the default Mason and Lazy directories. This test exercises passing and failing JUnit cases, executed Q&A scenarios, local values, failure status and debugger cleanup.


## 18. Phases

1. **Extraction and resolution**: the Java backend, the index, §5, `codegraph`. Testable on its own against graphify's output.
2. **Regions, ratings and route**: §7–8, with the outline as a dry run (`code-tour ast --dry-run` prints the outline without opening a tour).
3. **Tours**: projection, skeleton, Markdown fills with gist and body, `ad` on lazy sites, selections, live detail changes.
4. **The note store**: automatic persistence, lookup, the freshness checks, versions, tour history, pruning.
5. **Orchestration**: tiers, `brief`, `--model`, and the skill's section on delegation and escalation.
6. **Agents while coding**: the commands of §13, `agent install`, write-back. Needs only phases 1, 2 and 4.
7. **Examples**: tests as examples, then recorded runs, then executed scenarios.
8. **Adjustments and hints**: overrides, agent edges, `.ua/` and graphify hints, entry-free tours.
9. **Second backend**: opt-in Python exercised the backend interface with a dynamically typed language (§4.5).

## 19. Open questions

1. Field initializers and static blocks: regions of the type's snippet, or snippets of their own when they contain project sites?
2. Is construction tracking within visited symbols (§8.5) enough, or should the index record every constructor site for a whole-program pass?
3. Should region selection learn from overrides (a `--split` the agent keeps making for a pattern), or stay strictly rule-based?
4. Which language should follow Python, and which Python integrations should be added first?
5. Is the success-path rule for two terminating arms (§8.3) reliable enough, or should every such `if` be listed as a fork for the agent to settle? And should failure paths get a main flow of their own (`--failure`) before the error walk exists?
6. When a box exists only at some levels (§11.2), should its first body be derived from the enclosing box's body at another level (the agent splitting or condensing it), rather than written from scratch?
7. Recordings keep a short `toString()` representation for objects. Should field capture be added, and how should stored recordings handle sensitive values?
