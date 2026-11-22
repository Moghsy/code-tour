-- SPEC-ast-graph §8.6, §10, §11.2: live detail changes. The main flow (walk calls) is the
-- same at every detail and ratings are never recomputed; extras enter and leave per the
-- offer cutoffs; boxes refine along nested boundaries (every finer box inside one
-- coarser box, unsplit boxes keep their address); each box shows its body for the new
-- level, or the body one level away marked with its level, or the gist only; the write
-- request lists only snippets with boxes to write; the reader stays on the same region
-- (or the box holding their line); zoom and Q&A threads survive; :CodeTourDetail works.
--
-- The fixture's checkout tour selects the same boxes at normal and detailed, so the
-- split case is tested between detailed and exhaustive (n1 r6 35-39 splits in two).
--   nvim --clean --headless -l tests/ast_detail.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

vim.o.lines, vim.o.columns = 50, 140
require("code-tour.instance").register = function() end
local sent = {}
require("code-tour.conversation").deliver = function(_, _, prompt, _, cb)
  sent[#sent + 1] = prompt
  cb(true)
end
local notes_seen = {}
vim.notify = function(message)
  notes_seen[#notes_seen + 1] = tostring(message)
end

local writing = require("code-tour.ast.project").writing

t.finish("ast detail", function()
  if not t.parser() then
    return
  end
  local tour = require("tour")
  tour.setup({ keys = false, smooth_scroll = false })
  local stops = require("code-tour.stops")
  local notes = require("code-tour.ast.notes")
  local live_mod = require("code-tour.ast.live")
  local root = t.project()
  local store = notes.new()

  -- --------------------------------------------------------------- unit: detail.change
  do
    local live = assert(live_mod.new({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache,
      store = notes.new() }))
    local ok, err = pcall(live.set_detail, live, "verbose")
    check(not ok and err:find("overview, normal, detailed, exhaustive", 1, true), "unknown detail lists the four: "
      .. tostring(err))
    eq(live.detail, "normal", "a rejected detail changes nothing")
    local same = live:set_detail("normal")
    eq(same.request, false, "same detail: nothing to request")

    -- fake expansions: one on a site that stays lazy, one on a site that becomes optional
    local n1 = live.snippets.n1
    local stay, become
    for _, site in ipairs(n1.sites) do
      if site.site == "s11" then
        stay = "n1.s11>" .. site.target
      elseif site.site == "s13" and site.target:find("EmailNotifier") then
        become = "n1.s13>" .. site.target
      end
    end
    check(stay and become, "fixture sites s11 and s13 exist")
    local fake = { n = "n90", symbol = "fake", sites = {}, regions = {} }
    local fake2 = { n = "n91", symbol = "fake2", sites = {}, regions = {} }
    live.expanded[stay], live.expanded[become] = fake, fake2
    local tree = live.prep.tree
    local res = live:set_detail("exhaustive")
    eq(res.request, true, "a change requests")
    eq({ live.detail, live.recipe.detail }, { "exhaustive", "exhaustive" }, "detail and recipe updated")
    check(live.prep.tree == tree, "the rated tree is reused (no re-rating)")
    eq(#res.added, 5, "five extras enter at exhaustive")
    eq(res.removed, {}, "nothing leaves")
    -- expand.rebuild (piece B) cannot rebuild a fake snippet, so the old one is kept
    local kept = live.expanded[stay]
    check(kept and kept.n == "n90" and live.snippets.n90 == kept, "an expansion whose site stays lazy is kept")
    check(live.expanded[become] == nil and live.snippets.n91 == nil, "an expansion whose site is now optional is dropped")
    eq(res.dropped, { become }, "dropped keys reported")
    -- an expansion hanging off an extra that leaves the tour
    local extra = live.snippets[res.added[1]]
    local key = extra.n .. ".s1>fake"
    live.expanded[key] = { n = "n92", symbol = "fake3", sites = {}, regions = {} }
    res = live:set_detail("normal")
    eq(#res.removed, 5, "the extras leave at normal")
    for _, n in ipairs(res.removed) do
      check(live.snippets[n] == nil, "a snippet that left no longer resolves: " .. n)
    end
    check(live.expanded[key] == nil and vim.tbl_contains(res.dropped, key), "an expansion whose parent left is dropped")
    check(live.expanded[stay] and live.expanded[stay].n == "n90", "the kept expansion survives a second change")
    eq(#res.added, 0, "nothing enters going back to normal")
    -- extras that come back keep their ids
    local again = live:set_detail("exhaustive")
    table.sort(again.added)
    local before = vim.deepcopy(res.removed)
    table.sort(before)
    eq(again.added, before, "extras re-enter under their stable ids")
  end

  -- --------------------------------------------------------------- editor: tour.ast_detail
  local result = tour.ast_tour({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache, store = store })
  local s = tour.state()
  local live = s.ast
  check(live and result.detail == "normal", "AST tour open at normal")
  local tree = live.prep.tree

  local function boxes()
    local out = {}
    for i, stop in ipairs(s.stops) do
      if stop.ast and not stop.lazy then
        for k, box in ipairs(stops.boxes(stop)) do
          out[box.anchor] = { stop = stop, box = box, i = i, k = k }
        end
      end
    end
    return out
  end
  local function main_flow()
    local out = {}
    for _, stop in ipairs(s.stops) do
      if stop.next then
        out[#out + 1] = { stop.anchor, stop.title, stop.main == true, stop.level, stop.site,
          stop._parent_stop and stop._parent_stop.anchor }
      end
    end
    return out
  end
  local function regions_now()
    local out = {}
    for n, sn in pairs(live.snippets) do
      out[n] = {}
      for _, r in ipairs(sn.regions) do
        out[n][#out[n] + 1] = { address = r.address, lines = r.lines, id = r.id }
      end
    end
    return out
  end
  -- write every box of the current projection at the current detail (except `skip`)
  local function fill(detail, skip)
    for _, sn in ipairs(live:all()) do
      local list = { { address = sn.symbol } }
      for _, r in ipairs(sn.regions) do
        list[#list + 1] = { address = r.address }
      end
      for _, b in ipairs(list) do
        if not (skip and skip[b.address]) then
          store:put(b.address, { fingerprint = sn._fps[b.address], file = sn.file, gist = "Gist " .. b.address .. ".",
            body = detail .. " body of " .. b.address, detail = detail })
        end
      end
    end
  end
  local function put(sn, detail)
    store:put(sn.symbol, { fingerprint = sn._fps[sn.symbol], file = sn.file, gist = "Gist " .. sn.symbol .. ".",
      body = detail .. " body of " .. sn.symbol, detail = detail })
  end
  local function at_reader()
    local stop = s.stops[s.stop]
    return stop, stops.boxes(stop)[s.box]
  end

  local flow = main_flow()
  eq(#flow, 5, "five walked calls at normal")
  for _, f in ipairs(flow) do
    check(f[3] and f[4] == 0, "every walked call is main flow, level 0: " .. f[1])
  end
  local n5 = live.snippets.n5
  fill("normal", { [n5.symbol] = true })

  -- reader on n1 r6, zoomed out, with a Q&A thread on n1 r2
  local b = boxes()
  local r6 = b["n1.r6"]
  local r6_address, r6_start = r6.box.address, r6.box.start
  s.stop, s.box = r6.i, r6.k
  tour.zoom(-1)
  local zoom = s.zoom
  check(zoom ~= nil, "zoomed out")
  local r2_address = b["n1.r2"].box.address
  local thread = live:thread(live.snippets.n1, live.snippets.n1.regions[2])
  thread[#thread + 1] = { question = "Why here?", answer = "Because." }

  -- normal -> detailed: same boxes (unsplit), each shows the normal body marked, writing
  local before_regions = regions_now()
  local sent_before = #sent
  local res = tour.ast_detail("detailed")
  eq(res.detail, "detailed", "detail changed")
  check(live.prep.tree == tree, "ratings not recomputed (same rated tree)")
  eq(main_flow(), flow, "the main flow is identical at detailed")
  local after_regions = regions_now()
  for n, list in pairs(before_regions) do
    eq(after_regions[n], list, "unsplit boxes keep their address at detailed: " .. n)
  end
  b = boxes()
  for anchor, item in pairs(b) do
    local box = item.box
    if box.address == n5.symbol then
      eq(box.note, writing, "a box never written reads Being written…")
    else
      eq(box.note, ("Gist %s.\n\nnormal body of %s\n\n*(normal detail)*"):format(box.address, box.address),
        "the normal body is shown, marked: " .. anchor)
      check(box.writing and box.level_shown == "normal", "marked writing at its level: " .. anchor)
    end
  end
  local stop, box = at_reader()
  eq({ stop.anchor, box.address }, { "n1", r6_address }, "the reader stays on the same region")
  eq(s.zoom, zoom, "zoom level kept")
  check(b["n1.r2"].box.address == r2_address and b["n1.r2"].box.thread == thread and #thread == 1,
    "the Q&A thread survives on a box that keeps its address")
  eq(#sent, sent_before + 1, "one write request")
  local req = sent[#sent]
  check(req:find("[code-tour ast] write", 1, true) and req:find("detail changed to detailed", 1, true),
    "a write request for the new level")
  check(req:find("--detail detailed", 1, true), "its fill command names the new level")
  for _, n in ipairs({ "n1", "n2", "n3", "n4", "n5", "n6" }) do
    check(req:find("\n" .. n .. " ", 1, true), "the request lists " .. n)
  end
  eq(#res.pending, 6, "six snippets to write at detailed")

  -- same detail: nothing changes, nothing is requested
  sent_before = #sent
  tour.ast_detail("detailed")
  eq(#sent, sent_before, "the same detail sends nothing")
  stop, box = at_reader()
  eq(box.address, r6_address, "and leaves the reader in place")

  -- invalid detail: an error, the tour unchanged
  local ok, err = pcall(tour.ast_detail, "verbose")
  check(not ok and tostring(err):find("overview, normal, detailed, exhaustive", 1, true), "unknown detail refused")
  eq(live.detail, "detailed", "unchanged after a refused detail")

  -- detailed -> exhaustive: extras enter, n1 r6 splits, new boxes are written fresh
  fill("detailed", { [n5.symbol] = true })
  local n3 = live.snippets.n3
  put(n3, "exhaustive")
  put(n5, "exhaustive")
  before_regions = regions_now()
  sent_before = #sent
  res = tour.ast_detail("exhaustive")
  check(live.prep.tree == tree, "ratings not recomputed at exhaustive")
  eq(main_flow(), flow, "the main flow is identical at exhaustive")
  local extras = {}
  for _, st in ipairs(s.stops) do
    if st.ast and not st.lazy and not st.next and st._parent_stop then
      check(type(st.level) == "number", "A prepared AST extra keeps its effective rating")
      extras[#extras + 1] = st.title
    end
  end
  table.sort(extras)
  eq(extras, { "ChargeResult.message()", "EmailNotifier.send(String, String)", "Money.format()", "Money.isZero()",
    "SmsNotifier.send(String, String)" }, "the rated-5 extras enter as optional calls at exhaustive")
  after_regions = regions_now()
  local split = {}
  for n, list in pairs(before_regions) do
    local old_by_address = {}
    for _, r in ipairs(list) do
      old_by_address[r.address] = r
    end
    for _, r in ipairs(after_regions[n]) do
      -- §7 nesting: every finer box lies inside a coarser one, and never straddles two
      local inside, straddles = false, false
      for _, o in ipairs(list) do
        if o.lines[1] <= r.lines[1] and r.lines[2] <= o.lines[2] then
          inside = true
        elseif o.lines[1] <= r.lines[2] and r.lines[1] <= o.lines[2] and not (r.lines[1] <= o.lines[1]
          and o.lines[2] <= r.lines[2]) then
          straddles = true
        end
      end
      check(inside and not straddles, ("every exhaustive box lies inside one detailed box: %s %s"):format(n, r.id))
      local same = false
      for _, o in ipairs(list) do
        if o.lines[1] == r.lines[1] and o.lines[2] == r.lines[2] then
          same = o.address == r.address
        end
      end
      if not old_by_address[r.address] then
        split[#split + 1] = n .. " " .. r.id
      else
        check(same, "an unsplit box keeps its address: " .. n .. " " .. r.id)
      end
    end
  end
  table.sort(split)
  eq(split, { "n1 r6", "n1 r7" }, "only n1's old r6 is split at exhaustive")
  b = boxes()
  local fresh_r = { ["n1.r6"] = true, ["n1.r7"] = true }
  for anchor, item in pairs(b) do
    local bx = item.box
    if fresh_r[anchor] or anchor:match("^n%d%d?$") and tonumber(anchor:sub(2)) > 6 then
      eq(bx.note, writing, "a box that exists only at exhaustive reads Being written…: " .. anchor)
      check(bx.writing, "and is writing: " .. anchor)
    elseif bx.address == n3.symbol or bx.address == n5.symbol then
      eq(bx.note, ("Gist %s.\n\nexhaustive body of %s"):format(bx.address, bx.address), "an exhaustive body: " .. anchor)
      check(not bx.writing, "fresh at exhaustive: " .. anchor)
    else
      eq(bx.note, ("Gist %s.\n\ndetailed body of %s\n\n*(detailed detail)*"):format(bx.address, bx.address),
        "the detailed body, marked, on an unsplit box: " .. anchor)
    end
  end
  stop, box = at_reader()
  check(stop.anchor == "n1" and box.start <= r6_start and box["end"] >= r6_start and box.address ~= r6_address,
    "the reader moves to the box holding their line when their region split")
  eq(s.zoom, zoom, "zoom kept at exhaustive")
  eq(#sent, sent_before + 1, "one write request at exhaustive")
  req = sent[#sent]
  check(not req:find("\nn3 ", 1, true) and not req:find("\nn5 ", 1, true),
    "snippets with every box fresh are not requested")
  check(req:find("\nn1 ", 1, true) and req:find("\nn7 ", 1, true), "snippets with boxes to write are")
  eq(#res.pending, 9, "nine snippets to write at exhaustive")

  -- exhaustive -> overview (two levels apart): gist only for a body written only at exhaustive
  res = tour.ast_detail("overview")
  eq(main_flow(), flow, "the main flow is identical at overview")
  b = boxes()
  for anchor, item in pairs(b) do
    check(anchor:match("^n%d$"), "overview has root boxes only: " .. anchor)
    check(tonumber(anchor:sub(2)) <= 6, "the extras left at overview: " .. anchor)
  end
  for n = 7, 11 do
    check(live.snippets["n" .. n] == nil, "an extra that left does not resolve: n" .. n)
  end
  eq(b.n5.box.note, ("Gist %s.\n\n%s"):format(n5.symbol, writing), "two levels apart: gist only")
  check(b.n5.box.writing and not b.n5.box.level_shown, "gist only is still writing, with no level")
  eq(b.n1.box.note, ("Gist %s.\n\nnormal body of %s\n\n*(normal detail)*"):format(b.n1.box.address,
    b.n1.box.address), "normal is one level from overview")
  stop = at_reader()
  eq(stop.anchor, "n1", "the reader stays in their snippet at overview")

  -- back to normal: the normal bodies again, and only the never-written box is requested
  put(live.snippets.n5, "normal")
  sent_before = #sent
  res = tour.ast_detail("normal")
  eq(main_flow(), flow, "the main flow is identical back at normal")
  b = boxes()
  for anchor, item in pairs(b) do
    eq(item.box.note, ("Gist %s.\n\nnormal body of %s"):format(item.box.address, item.box.address),
      "the normal body again: " .. anchor)
    check(not item.box.writing, "not writing: " .. anchor)
  end
  check(b["n1.r2"].box.thread == thread and #thread == 1, "the thread is back on n1 r2")
  eq(#sent, sent_before, "nothing is requested when every box has its normal body")
  eq(res.pending, {}, "no pending snippets at normal")
  check(notes_seen[#notes_seen]:find("Detail: normal", 1, true), "the change is announced: " .. notes_seen[#notes_seen])
  eq(s.zoom, zoom, "zoom kept back at normal")

  -- :CodeTourDetail
  vim.cmd("CodeTourDetail detailed")
  eq(live.detail, "detailed", ":CodeTourDetail detailed changes the detail")
  eq(main_flow(), flow, "the main flow is identical after :CodeTourDetail")
  vim.cmd("CodeTourDetail bogus")
  check(notes_seen[#notes_seen]:find("unknown detail", 1, true), ":CodeTourDetail reports an unknown detail")
  eq(live.detail, "detailed", "and leaves the tour as it was")
  -- code-tour adjust --detail goes the same way
  res = tour.ast_adjust({ detail = "normal" })
  eq({ res.detail, live.detail }, { "normal", "normal" }, "ast_adjust changes the detail")
  check(res.outline:find("· normal ·", 1, true), "and returns the outline at the new level")
  check(live.prep.tree == tree, "ratings never recomputed across all changes")
  tour.stop()
end)
