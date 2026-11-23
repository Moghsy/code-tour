-- SPEC-ast-graph §9.3–9.4: fills for AST snippets. The parser (Markdown sections and
-- JSON, the gist as the first paragraph, `## n1 r2` addressing, errors) and fill.apply on
-- a live tour (validation before any write, unknown boxes, stale refusal, other detail
-- levels, the result's ready/remaining lists).
--   nvim --clean --headless -l tests/ast_fill.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

local function err_of(fn, ...)
  local ok, err = pcall(fn, ...)
  check(not ok, "expected an error")
  return tostring(err)
end

local function parser_units(fill)
  local function short(list)
    local out = {}
    for _, s in ipairs(list) do
      out[#out + 1] = { s.n, s.box, s.gist, s.body }
    end
    return out
  end

  -- §9.3's example: first paragraph gist, the rest body
  local md = table.concat({
    "## overview",
    "Validate the order, charge the discounted total,",
    "then mark it paid.",
    "",
    "## r2",
    "Compute the order total and apply discounts.",
    "",
    "The total is recomputed from the lines.",
    "",
    "### Why both",
    "One rule depends on the amount.",
    "",
  }, "\n")
  eq(short(fill.parse(md, "n1")), {
    { "n1", "overview", "Validate the order, charge the discounted total, then mark it paid.", nil },
    { "n1", "r2", "Compute the order total and apply discounts.",
      "The total is recomputed from the lines.\n\n### Why both\nOne rule depends on the amount." },
  }, "markdown sections: gist lines joined, body kept, ### stays in the body")

  -- addressing other snippets; `## n1` is n1's overview
  eq(short(fill.parse("## n2 r1\nA.\n\n## n3\nB.\n\n## n4 overview\nC.\n\nBody.", "n1")), {
    { "n2", "r1", "A.", nil }, { "n3", "overview", "B.", nil }, { "n4", "overview", "C.", "Body." },
  }, "## nK rJ, ## nK and ## nK overview")

  -- fenced code is not split by a `## ` line inside it
  local fenced = fill.parse("## r1\nGist.\n\n```java\n## not a heading\n```\n", "n1")
  eq(#fenced, 1, "a fenced ## is body text")
  eq(fenced[1].body, "```java\n## not a heading\n```", "fence kept in the body")

  -- a repeated section in one payload: the later wins, at the first one's place
  eq(short(fill.parse("## r1\nOld.\n\n## r2\nTwo.\n\n## n1 r1\nNew.", "n1")),
    { { "n1", "r1", "New.", nil }, { "n1", "r2", "Two.", nil } }, "later repeated section wins")

  -- JSON objects (decoded or as text); string values split like a section
  eq(short(fill.parse({ r2 = { gist = "G2", body = "B2" }, overview = "Over.\n\nAll of it.", ["n3 r1"] = { gist = "G3" } },
    "n1")), {
    { "n1", "overview", "Over.", "All of it." }, { "n1", "r2", "G2", "B2" }, { "n3", "r1", "G3", nil },
  }, "JSON fill: sorted by snippet, overview first")
  eq(short(fill.parse('{"r1": {"gist": "J", "body": ""}}', "n2")), { { "n2", "r1", "J", nil } },
    "JSON text; an empty body is no body")

  -- errors with clear messages
  check(err_of(fill.parse, "Intro.\n\n## r1\nG.", "n1"):find("Text before the first section"), "text before a heading")
  check(err_of(fill.parse, "## r1\n\n## r2\nG.", "n1"):find("Empty section `r1`"), "empty section")
  check(err_of(fill.parse, "## Summary\nG.", "n1"):find("Unknown section heading `## Summary`"), "unknown heading")
  check(err_of(fill.parse, "## n1 r2 r3\nG.", "n1"):find("Unknown section heading"), "three-word heading")
  check(err_of(fill.parse, "", "n1"):find("Empty fill"), "empty fill")
  check(err_of(fill.parse, "## r1\nG.", nil):find("names no snippet"), "no default snippet")
  check(err_of(fill.parse, { bogus = "x" }, "n1"):find('Unknown box key "bogus"'), "unknown JSON key")
  check(err_of(fill.parse, { r1 = 3 }, "n1"):find("give"), "bad JSON value")
  check(err_of(fill.parse, { r1 = { body = "only body" } }, "n1"):find("Empty section"), "JSON without gist")
  check(err_of(fill.parse, { r1 = "A.", ["n1 r1"] = "B." }, "n1"):find("named twice"), "JSON names a box twice")
  check(err_of(fill.parse, { { file = "x" } }, "n1"):find("not a list"), "a list of stops is not an AST fill")
  check(err_of(fill.parse, "{ nope", "n1"):find("not a JSON object"), "broken JSON")
end

t.finish("ast fill", function()
  local fill = require("code-tour.ast.fill")
  parser_units(fill)
  if not t.parser() then
    return
  end
  local root = t.project()
  local notes = require("code-tour.ast.notes")
  local store = notes.new()
  local live = assert(require("code-tour.ast.live").new({ entries = { "OrderService#checkout" }, root = root,
    cache_dir = t.cache, store = store }))
  local n1, n2 = live.snippets.n1, live.snippets.n2
  eq(#n1.regions, 6, "n1 has r1-r6 at normal")

  -- partial fill: written boxes listed, ready false, the rest remaining
  local res = live:fill("n1", "## overview\nCharge the order.\n\nBody.\n\n## r2\nTotals.\n\nRecomputed.")
  eq(res.boxes, { "n1 overview", "n1 r2" }, "written boxes")
  eq(res.count, 2, "count")
  eq(res.filled, "n1", "filled id")
  eq(res.ready, { n1 = false }, "n1 not ready")
  eq(res.remaining, { "n1 r1", "n1 r3", "n1 r4", "n1 r5", "n1 r6" }, "remaining boxes of n1")
  check(res.partial and res.warning:find("Partial fill: 5 boxes", 1, true), "a partial fill carries a warning")
  check(res.refused == nil, "nothing refused")
  local found = store:lookup(n1.regions[2].address, n1._fps[n1.regions[2].address], "normal")
  eq({ found.gist, found.body, found.exact }, { "Totals.", "Recomputed.", true }, "stored at normal, by fingerprint")
  eq(live:status(n1, nil), "fresh", "overview fresh")

  -- model recorded with the body
  live:fill("n1", "## r1\nGuards.", { model = "haiku" })
  eq(store.notes[n1.regions[1].address].bodies.normal, nil, "gist-only section stores no body")
  live:fill("n1", "## r1\nGuards.\n\nTwo guards.", { model = "haiku" })
  eq(store.notes[n1.regions[1].address].bodies.normal.model, "haiku", "--model kept with the body")

  -- the rest of n1 plus n2 in one fill; n1 becomes ready
  local all = { "## r3\nA.", "## r4\nB.", "## r5\nC.", "## r6\nD.", "## n2\nTotal.", "## n2 r1\nSum." }
  res = live:fill("n1", table.concat(all, "\n\n"))
  eq(res.ready.n1, true, "n1 ready once every box is fresh")
  check(res.ready.n2 == false, "n2 touched, not ready")
  eq(res.remaining, { "n2 r2" }, "remaining lists the touched snippets' boxes")

  -- validation before any write: an unknown box anywhere writes nothing
  local before = vim.deepcopy(store.notes)
  local msg = err_of(live.fill, live, "n1", "## r2\nChanged.\n\n## n2 r9\nNo such box.")
  check(msg:find("Unknown box n2 r9 at normal detail %(n2 has overview r1 r2%)"), "unknown box lists valid ids: " .. msg)
  eq(store.notes, before, "nothing written when one section is invalid")
  msg = err_of(live.fill, live, "n1", "## n99 r1\nX.")
  check(msg:find("Unknown snippet n99"), "unknown snippet: " .. msg)
  check(err_of(live.fill, live, "n1", "## r1\nX.", { detail = "huge" }):find("Unknown detail huge"), "bad detail")

  -- a fill for another level stores that level; what normal shows is unchanged
  local r2 = n1.regions[2]
  res = live:fill("n1", "## r2\nTotals.\n\nIn depth: every line, every rule.", { detail = "detailed" })
  eq(res.boxes, { "n1 r2" }, "detailed fill written")
  eq(store.notes[r2.address].bodies.detailed.text, "In depth: every line, every rule.", "detailed body stored")
  eq(store.notes[r2.address].bodies.normal.text, "Recomputed.", "normal body kept beside it")
  eq(live:presentation(n1, r2).note, "Totals.\n\nRecomputed.", "normal still shows the normal body")
  -- boxes are those of the other detail: overview has none but the overview box
  check(err_of(live.fill, live, "n1", "## r1\nX.", { detail = "overview" }):find("n1 has overview%)"),
    "at overview only the overview box exists")
  local other = require("code-tour.ast.outline").snippet(live.prep, n1._node, "n1", {}, "detailed")
  local last = other.regions[#other.regions]
  res = live:fill("n1", ("## %s\nDetailed only."):format(last.id), { detail = "detailed" })
  eq(res.boxes, { "n1 " .. last.id }, "a detailed box id is accepted at detailed")
  check(store.notes[last.address] and store.notes[last.address].bodies.detailed == nil
    and store.notes[last.address].written.detailed, "stored under the detailed region's address")

  -- stale refusal: editing n2's source refuses n2, n1 still written
  local buf = live:buf(n2.file)
  local row = n2.lines[1] + 1
  local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { text .. " int extra = 1;" })
  check(live:source_changed(n2), "n2 source changed")
  res = live:fill("n1", "## r3\nRevised.\n\n## n2 r2\nNew.")
  eq(res.boxes, { "n1 r3" }, "n1 still written")
  eq(res.refused, { { n = "n2", reason = "Source changed; rebuild with code-tour ast" } }, "n2 refused")
  eq(store.notes[n1.regions[3].address].gist, "Revised.", "later fill replaced n1 r3")
  msg = err_of(live.fill, live, "n2", "## r2\nNew.")
  eq(msg, "Source changed; rebuild with code-tour ast (n2)", "a fill whose every section is refused errors")
end)
