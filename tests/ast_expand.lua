-- `ad` on lazy sites and selections on a live AST tour (SPEC-ast-graph §7, §9.5):
-- ast/expand.lua at unit level, then through the editor (tour.ast_tour, expand_call,
-- explain_range, fill).
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

local EMAIL = "java:shop.notify.EmailNotifier#send(String,String)"
local CHECKOUT = "java:shop.order.OrderService#checkout(Order)"

local function site_key(sn, text, nth)
  nth = nth or 1
  for _, s in ipairs(sn.sites) do
    if s.text == text and s.mode == "lazy" then
      nth = nth - 1
      if nth == 0 then
        return sn.n .. "." .. s.site .. ">" .. s.target, s
      end
    end
  end
  error("no lazy site " .. text .. " in " .. sn.n)
end

local function by_symbol(live, symbol)
  for _, sn in ipairs(live:all()) do
    if sn.symbol == symbol then
      return sn
    end
  end
end

local function region(sn, id)
  for _, r in ipairs(sn.regions) do
    if r.id == id then
      return r
    end
  end
end

-- the byte range of 1-based lines a..b, line-wise (column 0 to the end of b)
local function lines_range(live, sn, a, b)
  local buf = live:buf(sn.file)
  local last = vim.api.nvim_buf_get_lines(buf, b - 1, b, false)[1]
  return { start = { a - 1, 0 }, ["end"] = { b - 1, #last } }
end

local function fill_all(live, sn)
  live.store:put(sn.symbol, { fingerprint = sn._fps[sn.symbol], file = sn.file, gist = "Overview.", body = "Body.",
    detail = live.detail })
  for _, r in ipairs(sn.regions) do
    live.store:put(r.address, { fingerprint = sn._fps[r.address], file = sn.file, gist = "Box " .. r.id .. ".",
      body = "Body.", detail = live.detail })
  end
end

local function unit(root)
  local live_mod = require("code-tour.ast.live")
  local notes = require("code-tour.ast.notes")
  local store = notes.new()
  local live = assert(live_mod.new({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache,
    store = store }))
  local n1 = live.snippets.n1
  t.eq(n1.symbol, CHECKOUT, "n1 is checkout")

  -- lazy: n1.s13 notifier.send -> EmailNotifier.send
  local key = site_key(n1, "notifier.send", 1)
  t.eq(key, "n1.s13>" .. EMAIL, "the first notifier.send candidate is EmailNotifier")
  local sn, stop, needs = live:expand(key)
  t.eq(sn.n, "n7", "the expanded snippet takes the next free id")
  t.eq(sn.symbol, EMAIL, "it is the target's snippet")
  t.check(live.expanded[key] == sn and live.snippets.n7 == sn, "registered as expanded and as a snippet")
  t.check(needs, "nothing is written yet")
  t.eq(stop.anchor, "n7", "stop input anchored at the new snippet")
  t.check(stop.ast and stop.writing, "projected as an AST box still being written")
  t.eq(stop.note, require("code-tour.ast.project").writing, "its overview reads Being written…")
  t.eq(sn.depth, n1.depth + 1, "one level below its caller")
  t.check(sn._fps and sn._fps[EMAIL], "fingerprinted")
  for _, s in ipairs(sn.sites) do
    t.check(s.mode ~= "walk" and s.mode ~= "optional", "an expanded snippet's sites are never walked: " .. s.site)
  end
  local again = live:expand(key)
  t.check(again == sn, "expanding the same anchor twice returns the existing snippet")
  t.check(by_symbol(live, EMAIL) == sn, "live:all() lists the expanded snippet")
  local pending = vim.tbl_map(function(x)
    return x.n
  end, live:pending())
  t.check(vim.tbl_contains(pending, "n7"), "it is pending")
  -- the whole tour now projects the expanded call in place of the lazy one
  local found
  local function scan(box)
    for _, c in ipairs(box.calls or {}) do
      if c.site == "s13" and c.target == EMAIL then
        found = c
      end
      scan(c)
    end
    for _, p in ipairs(box.parts or {}) do
      scan(p)
    end
  end
  for _, st in ipairs(live:stops()) do
    scan(st)
  end
  t.check(found and not found.lazy and found.anchor == "n7", "the call projects as the expanded snippet")
  t.check(found.callsite and found.callsite.symbol == "notifier.send", "with the lazy call's callsite")
  t.check(live:outline({ token = "T", cli = "ct", servername = "S" }):find("n7 EmailNotifier.send", 1, true),
    "the outline lists it")

  -- a lazy anchor that is not lazy, or unknown, is refused
  t.check(not pcall(live.expand, live, "n1.s5>java:shop.order.Order#total()"), "a walked site is not expanded")
  t.check(not pcall(live.expand, live, "n1.s99>x"), "an unknown site is refused")

  -- nested: n4.s5 formatter.format -> Formatter.format(Money), then its money.format
  local n4 = live.snippets.n4
  local fkey = site_key(n4, "formatter.format", 1)
  local fsn = live:expand(fkey)
  t.eq(fsn.label, "Formatter.format(Money)", "n4.s5 opens Formatter.format(Money)")
  local mkey, msite = site_key(fsn, "money.format", 1)
  t.eq(msite.why, "detail", "a rated site of an expanded snippet is lazy, why detail")
  local msn, mstop = live:expand(mkey)
  t.eq(msn.symbol, "java:shop.money.Money#format()", "nested expansion opens Money.format")
  t.eq(msn.depth, fsn.depth + 1, "nested one level deeper")
  t.check(mkey:match("^" .. fsn.n .. "%.s1>"), "nested keys hang off the expanded snippet: " .. mkey)
  t.check(mstop.anchor == msn.n, "nested stop input")
  local order = vim.tbl_map(function(x)
    return x.n
  end, live:all())
  local pos = {}
  for i, x in ipairs(order) do
    pos[x] = i
  end
  t.check(pos[msn.n] and pos[fsn.n] and pos[msn.n] == pos[fsn.n] + 1 and pos[fsn.n] > pos.n4,
    "nested expansions are listed after their parent: " .. table.concat(order, " "))
  local fstop = live:snippet_stop("n4")
  local nested
  local function scan2(box, depth)
    for _, c in ipairs(box.calls or {}) do
      if c.anchor == msn.n then
        nested = depth
      end
      scan2(c, depth + 1)
    end
    for _, p in ipairs(box.parts or {}) do
      scan2(p, depth)
    end
  end
  scan2(fstop, 0)
  t.eq(nested, 1, "the nested expansion projects under the expanded call")

  -- the store already holds fresh notes for every box: nothing to write
  fill_all(live, sn)
  local live2 = assert(live_mod.new({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache,
    store = store }))
  local sn2, stop2, needs2 = live2:expand(key)
  t.check(not needs2, "fresh notes for every box: nothing needs writing")
  t.eq(stop2.note, "Overview.\n\nBody.", "the stored note is shown at once")
  t.check(not stop2.writing, "not marked writing")
  t.eq(live2:write_status(sn2), "fresh", "outline status fresh")

  -- rebuild at another detail keeps n and key
  live2.detail = "detailed"
  local re = require("code-tour.ast.expand").rebuild(live2, sn2)
  t.eq(re.n, sn2.n, "rebuild keeps the id")
  t.check(live2.expanded[key] == re and live2.snippets[re.n] == re, "rebuild re-registers the same key")
  t.eq(re._detail, "detailed", "rebuild selects at the live detail")
  t.check(re._node == sn2._node, "rebuild keeps the node (no re-rating)")
  live2.detail = "normal"

  -- selections ------------------------------------------------------------------------
  local live3 = assert(live_mod.new({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache,
    store = notes.new() }))
  local c = live3.snippets.n1
  local r2 = region(c, "r2")
  t.eq(r2.lines, { 29, 29 }, "fixture: r2 is line 29")
  local res = live3:select("n1", lines_range(live3, c, 29, 29))
  t.eq(res.boxes, { "r2" }, "a selection covering a region maps to it")
  t.check(res.synthetic == false and res.stop == nil, "no structural change")
  res = live3:select("n1", lines_range(live3, c, 21, 39))
  t.eq(res.boxes, { "overview" }, "the whole method maps to the overview")
  res = live3:select("n1", lines_range(live3, c, 29, 30))
  t.eq(res.boxes, { "overview" }, "a selection across child boxes maps to their parent box")
  t.check(not res.synthetic, "and splits nothing")
  t.eq(#c.regions, 6, "still six regions")

  local r6 = region(c, "r6")
  t.eq(r6.lines, { 35, 39 }, "fixture: r6 is lines 35-39")
  local r6_address = r6.address
  res = live3:select("n1", lines_range(live3, c, 36, 36))
  t.check(res.synthetic, "a line inside a leaf region creates a synthetic split")
  t.check(res.sn == c, "the same snippet")
  t.eq(res.boxes, { "r8", "r7", "r9" }, "the selected box first, then the runs around it")
  t.eq(#c.regions, 9, "three new regions")
  local r7, r8, r9 = region(c, "r7"), region(c, "r8"), region(c, "r9")
  t.eq(region(c, "r6").address, r6_address, "the leaf keeps its address and id")
  t.eq({ r7.parent, r8.parent, r9.parent }, { "r6", "r6", "r6" }, "the new boxes are children of the leaf")
  t.eq(r8.address, CHECKOUT .. "/body/stmts[8]", "the selected statements are addressed like regions.at builds them")
  t.eq(r7.address, CHECKOUT .. "/body/stmts[7]", "the run before")
  t.eq(r9.address, CHECKOUT .. "/body/stmts[9..10]", "the run after")
  t.eq({ r7.lines, r8.lines, r9.lines }, { { 35, 35 }, { 36, 36 }, { 37, 39 } }, "spans tile the leaf")
  t.check(r8.origin == "synthetic" and r7.origin == "synthetic", "origin synthetic")
  local regs = {}
  for _, s in ipairs(c.sites) do
    regs[s.site] = s.region
  end
  t.eq({ regs.s11, regs.s13, regs.s14, regs.s5 }, { "r7", "r9", "r9", "r2" }, "sites move to the new boxes")
  t.check(c._fps[r8.address], "the new boxes are fingerprinted")
  t.eq(live3.synthetic.n1, { { parent = r6_address, i = 8, j = 8 } }, "the split is recorded")
  t.eq(res.stop.anchor, "n1", "the snippet is re-projected")
  local p6 = res.stop.parts[6]
  t.eq(p6.anchor, "n1.r6", "r6 box")
  t.eq(vim.tbl_map(function(p)
    return p.anchor
  end, p6.parts or {}), { "n1.r7", "n1.r8", "n1.r9" }, "the new boxes nest under r6")
  res = live3:select("n1", lines_range(live3, c, 36, 36))
  t.eq(res.boxes, { "r8" }, "selecting the synthetic box again maps to it exactly")
  t.check(not res.synthetic, "no second split")

  -- re-applied on assemble; skipped where the leaf does not exist
  live3:assemble()
  local c2 = live3.snippets.n1
  t.check(c2 ~= c, "a fresh snippet")
  t.eq(region(c2, "r8") and region(c2, "r8").address, CHECKOUT .. "/body/stmts[8]", "the split survives assemble")
  live3.detail = "overview"
  live3:assemble()
  t.eq(#live3.snippets.n1.regions, 0, "at overview the leaf is gone and the split is skipped")
  live3.detail = "normal"
  live3:assemble()
  t.eq(#live3.snippets.n1.regions, 9, "back at normal it is re-applied")

  -- a split inside a synthetic box
  res = live3:select("n1", lines_range(live3, live3.snippets.n1, 38, 38))
  t.check(res.synthetic, "a statement inside the synthetic run splits it")
  t.eq(region(res.sn, res.boxes[1]).address, CHECKOUT .. "/body/stmts[10]", "nested synthetic address")
  t.eq(#live3.synthetic.n1, 2, "both splits recorded")
  live3:assemble()
  t.eq(#live3.snippets.n1.regions, 11, "both re-applied in order")

  -- selections inside an expanded snippet use its own regions
  local ex = live3:expand(key)
  res = live3:select(ex.n, lines_range(live3, ex, 6, 6))
  t.eq(res.boxes, { "overview" }, "a one-statement method maps to its overview")
end

-- Editor level ----------------------------------------------------------------------

local function editor(root)
  vim.o.lines, vim.o.columns = 50, 140
  require("code-tour.instance").register = function() end
  local sent = {}
  require("code-tour.conversation").deliver = function(_, _, prompt, _, cb)
    sent[#sent + 1] = prompt
    if cb then
      cb(true)
    end
  end
  local notices = {}
  vim.notify = function(msg)
    notices[#notices + 1] = msg
  end
  local tour = require("tour")
  tour.setup({ keys = false, smooth_scroll = false })
  local store = require("code-tour.ast.notes").new()
  local res = tour.ast_tour({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache, store = store })
  local s = tour.state()
  t.check(s.ast and res.tour, "an AST tour is open")
  local key = "n1.s13>" .. EMAIL
  local function find_anchor(anchor)
    for i, st in ipairs(s.stops) do
      if st.anchor == anchor then
        return st, i
      end
    end
  end
  local call = find_anchor(key)
  t.check(call and call.lazy, "the lazy call stop is in the tour")
  local parent, pbox, callsite = call._parent_stop, call._parent_box, vim.deepcopy(call.callsite)
  t.eq(pbox.anchor, "n1.r6", "its parent box is n1.r6")
  local before = #sent
  local n = tour.expand_call(call)
  t.eq(n, "n7", "expand_call returns the new snippet id")
  local new, at = find_anchor("n7")
  t.check(new and not new.lazy, "the snippet is inserted")
  t.check(not find_anchor(key), "the lazy call is gone")
  t.check(new._parent_stop == parent and new._parent_box == pbox, "same parent box")
  t.eq(new.callsite, callsite, "same callsite")
  t.eq(s.stop, at, "the reader entered it")
  t.check(new.writing and new.note == require("code-tour.ast.project").writing, "its boxes read Being written…")
  t.eq(#sent, before + 1, "one request is sent")
  local prompt = sent[#sent]
  t.check(prompt:find("[code-tour ast] n7", 1, true), "it is a [code-tour ast] n7 request")
  t.check(prompt:find("n7 EmailNotifier.send", 1, true), "carrying the snippet's outline")
  t.check(prompt:find("Called from n1", 1, true) and prompt:find("box r6", 1, true), "and the caller's box")
  t.check(prompt:find("--fill n7", 1, true), "with its fill command")
  t.check(not prompt:find("n2 Order.total", 1, true), "and not the rest of the tour")

  -- a fill for it
  local ok, err = pcall(tour.fill, "n7", "## overview\nSends the mail.\n\nPrints it to stdout.")
  t.check(ok, "a fill for the expanded snippet works: " .. tostring(err))
  new = find_anchor("n7")
  t.eq(new.note, "Sends the mail.\n\nPrints it to stdout.", "the box shows the fill")
  t.check(not new.writing, "no longer writing")

  -- nested expansion through the editor
  local n4 = find_anchor("n4")
  t.check(n4, "n4 is a stop")
  local fcall = find_anchor("n4.s5>java:shop.util.Formatter#format(Money)")
  t.check(fcall and fcall.lazy, "the formatter.format lazy call")
  before = #sent
  local fn = tour.expand_call(fcall)
  t.eq(#sent, before + 1, "nested: the first expansion is requested")
  local mcall = find_anchor(fn .. ".s1>java:shop.money.Money#format()")
  t.check(mcall and mcall.lazy, "the expanded snippet's own lazy call is shown")
  local mn = tour.expand_call(mcall)
  local mstop = find_anchor(mn)
  t.check(mstop and mstop._parent_stop == find_anchor(fn), "nested expansion inserted under the expanded snippet")
  t.eq(s.stop, select(2, find_anchor(mn)), "and entered")
  t.check(sent[#sent]:find("[code-tour ast] " .. mn, 1, true), "nested request sent")

  -- nothing is sent when the store already has fresh notes for every box
  local live = s.ast
  local sms_key = "n1.s13>java:shop.notify.SmsNotifier#send(String,String)"
  local sms_call = find_anchor(sms_key)
  t.check(sms_call and sms_call.lazy, "the SmsNotifier candidate is still lazy")
  -- write its notes in the store first, through a scratch live tour on the same store
  local scratch = assert(require("code-tour.ast.live").new({ entries = { "OrderService#checkout" }, root = root,
    cache_dir = t.cache, store = store }))
  fill_all(scratch, (scratch:expand(sms_key)))
  before = #sent
  local sn_id = tour.expand_call(sms_call)
  t.eq(#sent, before, "fresh notes for every box: nothing is sent")
  t.eq(find_anchor(sn_id).note, "Overview.\n\nBody.", "the stored note is shown")
  t.check(live == s.ast, "same live tour")

  -- selections ------------------------------------------------------------------------
  local sel = require("code-tour.selection")
  local n1 = find_anchor("n1")
  -- put the reader on n1 r2
  s.stop, s.box = select(2, find_anchor("n1")), 3
  tour.render(false)
  t.eq(n1.parts[2].anchor, "n1.r2", "fixture: second part is r2")
  local capture = sel.capture(s, { buf = n1.buf, start = 29, ["end"] = 29 })
  local stops_before = #s.stops
  before = #sent
  local id, p = tour.explain_range(capture)
  t.eq(id, "n1", "explain on r2 names n1")
  t.check(p:find("[code-tour explain] n1 OrderService.checkout(Order), box r2", 1, true), "asks about r2: " .. p)
  t.eq(#s.stops, stops_before, "no structural change")
  t.eq(#n1.parts, 6, "still six boxes")

  -- a line inside r6 (a leaf) splits it
  s.stop, s.box = select(2, find_anchor("n1")), 7
  t.eq(s.ast.snippets.n1.regions[6].lines, { 35, 39 }, "fixture: r6 is 35-39")
  local reading = tour.state().stops[s.stop].parts[6]
  t.eq(reading.anchor, "n1.r6", "the reader is on r6")
  capture = sel.capture(s, { buf = n1.buf, start = 36, ["end"] = 36 })
  id, p = tour.explain_range(capture)
  t.eq(id, "n1", "the request names n1")
  t.check(p:find("box r8", 1, true), "it names the new box r8: " .. p)
  t.check(p:find("write r8 for the selected statements and r7, r9 for the rest", 1, true), "and the runs around it")
  local n1b = find_anchor("n1")
  t.check(n1b ~= n1, "n1 was re-projected")
  local cur = s.stops[s.stop]
  local box = require("code-tour.stops").boxes(cur)[s.box]
  t.eq(cur.anchor, "n1", "the reader stays in n1")
  t.eq(box.anchor, "n1.r6", "on the same region (by address)")
  t.check(box.start == 35 and box["end"] == 39, "on the same code")
  t.check(find_anchor("n2") and find_anchor("n7") and find_anchor(mn), "the snippets under n1 survive the splice")
  t.check(find_anchor("n7").note:find("Sends the mail", 1, true), "and keep their notes")
  local r8box
  for _, b in ipairs(require("code-tour.stops").boxes(n1b)) do
    if b.anchor == "n1.r8" then
      r8box = b
    end
  end
  t.check(r8box and r8box.start == 36 and r8box["end"] == 36 and r8box.writing, "the synthetic box r8 is being written")

  -- a fill for the synthetic id fills it
  ok, err = pcall(tour.fill, "n1", "## r8\nCounts the order.\n\nIncrements processed.")
  t.check(ok, "a fill for the synthetic box works: " .. tostring(err))
  for _, b in ipairs(require("code-tour.stops").boxes(find_anchor("n1"))) do
    if b.anchor == "n1.r8" then
      r8box = b
    end
  end
  t.eq(r8box.note, "Counts the order.\n\nIncrements processed.", "r8 shows its note")
  t.check(not r8box.writing, "r8 is written")
end

t.finish("ast_expand", function()
  if not t.parser() then
    return
  end
  local root = t.project()
  unit(root)
  editor(root)
end)
