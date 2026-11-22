-- SPEC-ast-graph §9.1, §9.4, §10 (the ast_stream row of §17, `ad` aside): the skeleton
-- first, with badges and the route before any fill and fresh store notes shown at once;
-- pending snippets in walk order; partial and repeated fills; the reader never moved by
-- a fill; a fill refused after a source edit while another snippet still fills; JSON
-- fills; `## nK rJ` addressing another snippet; a fill for another detail level.
--   nvim --clean --headless -l tests/ast_stream.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

vim.o.lines, vim.o.columns = 50, 140
require("code-tour.instance").register = function() end
local sent = {}
require("code-tour.conversation").deliver = function(_, _, prompt, _, cb)
  sent[#sent + 1] = prompt
  cb(true)
end
local notified = {}
vim.notify = function(message)
  notified[#notified + 1] = message
end

local WRITING = "Being written…"

t.finish("ast stream", function()
  if not t.parser() then
    return
  end
  local tour = require("tour")
  local stops = require("code-tour.stops")
  local notes = require("code-tour.ast.notes")
  local live_mod = require("code-tour.ast.live")
  tour.setup({ keys = false, smooth_scroll = false })
  local root = t.project()

  -- a store already holding fresh notes for every box of n2 (Order.total), written
  -- against the same code by an earlier tour
  local store = notes.new()
  local earlier = assert(live_mod.new({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache,
    store = store }))
  local e2 = earlier.snippets.n2
  store:put(e2.symbol, { fingerprint = e2._fps[e2.symbol], gist = "Sum the lines.", body = "Every line counts.",
    detail = "normal" })
  for _, r in ipairs(e2.regions) do
    store:put(r.address, { fingerprint = e2._fps[r.address], gist = "Gist " .. r.id .. ".", body = "Body " .. r.id .. ".",
      detail = "normal" })
  end

  local result = tour.ast_tour({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache, store = store })
  local s = tour.state()
  local live = s.ast
  check(live and live.store == store, "the live tour uses the given store")
  eq(#sent, 0, "a CLI-started tour sends no request (the outline is the result)")

  local function box(anchor)
    for _, stop in ipairs(s.stops) do
      for _, b in ipairs(stops.boxes(stop)) do
        if b.anchor == anchor then
          return b, stop
        end
      end
    end
  end

  -- skeleton first: every box not covered by the store reads "Being written…"
  local written, writing = 0, 0
  for _, stop in ipairs(s.stops) do
    if stop.ast and not stop.lazy then
      for _, b in ipairs(stops.boxes(stop)) do
        if b.anchor:match("^n2[.]?") and not b.anchor:match("^n2%d") then
          check(not b.writing and b.note ~= WRITING, "stored note shown at once: " .. b.anchor)
          written = written + 1
        else
          eq(b.note, WRITING, "skeleton box " .. b.anchor)
          check(b.writing, "writing mark " .. b.anchor)
          writing = writing + 1
        end
      end
    end
  end
  check(written == 1 + #e2.regions and writing > 10, ("boxes: %d written, %d writing"):format(written, writing))
  eq(box("n2").note, "Sum the lines.\n\nEvery line counts.", "n2 overview from the store")
  eq(box("n2.r1").note, "Gist r1.\n\nBody r1.", "n2 r1 from the store")

  -- the outline marks n2 fresh and the header carries the tour token and fill command
  local lines = vim.split(result.outline, "\n")
  check(lines[1]:find("^tour " .. vim.pesc(s.id) .. " · normal · 6 snippets · 5 to write · 0 gaps · fill: "),
    "outline header: " .. lines[1])
  check(lines[1]:find("--fill <n> --pane", 1, true), "header fill command")
  check(result.outline:find("\nn2 Order%.total%(%)%s+Order%.java:%d+%-%d+%s+standard%s+fresh\n"), "n2 marked fresh")
  check(result.outline:find("\nn1 OrderService%.checkout%(Order%)%s+%S+%s+deep%s+write: overview r1%-r6\n"), "n1 to write")
  eq(result.tour, s.id, "result names the tour")

  -- pending snippets in walk order, each with its own fill command; n2 is not pending
  local pending = {}
  for _, p in ipairs(result.pending) do
    pending[#pending + 1] = p.n
    check(p.command:find("--fill " .. p.n .. " ", 1, true), "fill command for " .. p.n)
  end
  eq(pending, { "n1", "n3", "n4", "n5", "n6" }, "pending in walk order")

  -- badges and the route are there before any fill: walk calls with callsites, and
  -- badge extmarks in the entry's buffer
  local n1_stop = select(2, box("n1"))
  local walked = {}
  for _, stop in ipairs(s.stops) do
    if stop.next then
      walked[#walked + 1] = stop.anchor
      check(stop.callsite and stop.callsite.start_col, "walk call has a callsite: " .. stop.anchor)
    end
  end
  eq(walked, { "n2", "n3", "n4", "n5", "n6" }, "route present in the skeleton")
  tour.next_explanation(-50)
  local ns = vim.api.nvim_get_namespaces().CodeTourSource
  local function badges(buf)
    local found = 0
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      if (m[4].hl_group or ""):match("^CodeTour%a*Call$") then
        found = found + 1
      end
    end
    return found
  end
  check(badges(n1_stop.buf) > 0, "call badges drawn on the skeleton")
  local function rendered(buf)
    local text = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        for _, chunk in ipairs(vl) do
          text[#text + 1] = chunk[1]
        end
      end
    end
    return table.concat(text, "\n")
  end
  check(rendered(n1_stop.buf):find(WRITING, 1, true), "the focused box renders \"Being written…\"")

  -- the reader stays put across fills: stop, box, window, buffer and cursor
  tour.next_explanation(2)
  local function where()
    return { s.stop, s.box, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(),
      vim.api.nvim_win_get_cursor(0) }
  end
  local here = where()
  local focused = s.stops[s.stop]
  check(focused.anchor == "n1" and stops.boxes(focused)[s.box].anchor == "n1.r2", "reader on n1 r2")

  -- partial fill: only some sections arrive; the rest keep reading "Being written…"
  local res = tour.fill("n1", "## overview\nCharge the order.\n\nValidate, total, charge, receipt.\n\n## r2\nTotals.\n\n"
    .. "Recomputed from the lines.")
  eq(res.boxes, { "n1 overview", "n1 r2" }, "partial fill boxes")
  eq(res.ready, { n1 = false }, "n1 not yet ready")
  check(res.navigate == false, "a fill never navigates")
  eq(where(), here, "reader not moved by a fill")
  eq(box("n1.r2").note, "Totals.\n\nRecomputed from the lines.", "r2 re-rendered in place")
  eq(box("n1").gist, "Charge the order.", "overview gist kept on the stop")
  eq(box("n1.r3").note, WRITING, "an unfilled box keeps reading Being written…")
  check(box("n1.r3").writing, "and stays marked writing")
  check(rendered(n1_stop.buf):find("Recomputed from the lines.", 1, true), "the focused box re-rendered")

  -- repeated fill replaces the earlier note for the same box
  tour.fill("n1", "## r2\nTotals, revised.\n\nThe discount sees the recomputed total.")
  eq(box("n1.r2").note, "Totals, revised.\n\nThe discount sees the recomputed total.", "repeated fill replaces")
  eq(where(), here, "reader not moved by a repeated fill")

  -- JSON fill (as decoded by the RPC), and `## nK rJ` addressing another snippet
  res = tour.fill("n1", { r1 = { gist = "Guards.", body = "Paid and empty orders stop here." }, ["n4 r1"] = "Counters." })
  eq(res.boxes, { "n1 r1", "n4 r1" }, "JSON fill with another snippet's box")
  eq(box("n1.r1").note, "Guards.\n\nPaid and empty orders stop here.", "JSON gist and body")
  res = tour.fill("n4", "## overview\nApply the policy.\n\n## n3\nSubtotal of one line.")
  eq(res.boxes, { "n4 overview", "n3 overview" }, "## n3 in n4's fill writes n3's overview")
  eq(box("n3").note, "Subtotal of one line.", "gist-only section shows the gist")
  check(not box("n3").writing, "a gist-only section counts as written")
  eq(where(), here, "reader not moved by fills elsewhere")

  -- finish n1: ready, nothing remaining
  res = tour.fill("n1", "## r3\nA.\n\n## r4\nB.\n\n## r5\nC.\n\n## r6\nD.")
  eq(res.ready.n1, true, "n1 ready")
  eq(res.remaining, {}, "n1 has nothing left")
  check(live:outline({ token = s.id, cli = "c", servername = "s" }):find("\nn1 OrderService%.checkout%(Order%)%s+%S+%s+deep%s+fresh\n"),
    "outline marks n1 fresh after its fills")

  -- a fill for another level stores that level and leaves what normal shows alone
  res = tour.fill("n1", "## r2\nTotals, revised.\n\nAt depth: each line, then each rule.", { detail = "detailed" })
  eq(res.boxes, { "n1 r2" }, "detailed fill accepted")
  local r2 = live.snippets.n1.regions[2]
  eq(store.notes[r2.address].bodies.detailed.text, "At depth: each line, then each rule.", "detailed body stored")
  eq(box("n1.r2").note, "Totals, revised.\n\nThe discount sees the recomputed total.", "normal view unchanged")
  eq(live.detail, "normal", "the tour stays at normal")

  -- a fill after editing a snippet's source is refused; another snippet still fills
  local n5 = live.snippets.n5
  local buf = live:buf(n5.file)
  local row = n5.lines[1]
  local first = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
  vim.api.nvim_buf_set_lines(buf, row - 1, row, false, { first .. " int edited = 0;" })
  res = tour.fill("n6", "## overview\nCharge the card.\n\n## n5\nThe larger of two.")
  eq(res.boxes, { "n6 overview" }, "n6 still fills")
  eq(res.refused, { { n = "n5", reason = "Source changed; rebuild with code-tour ast" } }, "n5 refused")
  eq(box("n5").note, require("code-tour.ast.live").changed_note, "the refused box says its source changed")
  eq(box("n6").note, "Charge the card.", "n6 overview arrived")
  local ok, err = pcall(tour.fill, "n5", "## overview\nThe larger of two.")
  check(not ok and tostring(err):find("Source changed; rebuild with code-tour ast", 1, true), "n5 alone: error")

  -- invalid fills write nothing and leave the boxes as they were
  ok, err = pcall(tour.fill, "n6", "## r1\nX.\n\n## r99\nY.")
  check(not ok and tostring(err):find("Unknown box n6 r99"), "unknown box: " .. tostring(err))
  eq(box("n6.r1").note, WRITING, "nothing written by a rejected fill")
  eq(where(), here, "reader not moved by rejected fills")
  tour.stop()
end)
