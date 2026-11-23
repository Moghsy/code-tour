-- SPEC-ast-graph §3.7: projection of a live AST tour to stops. Snippets become stops
-- with anchors, selected regions nested parts, walk edges gold calls with main and
-- level, lazy edges lazy calls with their reason, ref edges nothing; every projected
-- payload passes stops.normalize, callsites read as the badge text, boxes without notes
-- read "Being written…", and fresh notes show gist and body.
--   nvim --clean --headless -l tests/ast_project.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

t.finish("ast project", function()
  if not t.parser() then
    return
  end
  local root = t.project()
  local live_mod = require("code-tour.ast.live")
  local notes = require("code-tour.ast.notes")
  local stops = require("code-tour.stops")
  local store = notes.new()
  local live = assert(live_mod.new({ entries = { "OrderService#checkout" }, overrides = t.route(), root = root, cache_dir = t.cache,
    store = store }))

  -- stable ids: the first projection is in walk order
  local order = {}
  for _, sn in ipairs(live:all()) do
    order[#order + 1] = sn.n .. " " .. sn.label
  end
  eq(order, { "n1 OrderService.checkout(Order)", "n2 Order.total()", "n3 Line.subtotal()",
    "n4 DiscountPolicy.apply(Order, Money)", "n5 Stats.max(int, int)", "n6 CardGateway.charge(Money)" }, "walk order")

  local input = live:stops()
  eq(#input, 1, "one top-level stop per entry")
  local data = stops.normalize(input, root)
  local by_anchor = {}
  for _, stop in ipairs(data) do
    for _, box in ipairs(stops.boxes(stop)) do
      if box.anchor then
        check(not by_anchor[box.anchor], "anchors are unique: " .. box.anchor)
        by_anchor[box.anchor] = { stop = stop, box = box }
      end
    end
  end

  -- snippet -> stop, regions -> parts covering it exactly (normalize validated coverage)
  local n1 = by_anchor.n1.stop
  eq({ n1.file, n1.start, n1["end"], n1.title, n1.ast, n1.address },
    { "src/main/java/shop/order/OrderService.java", 21, 39, "OrderService.checkout(Order)", true,
      "java:shop.order.OrderService#checkout(Order)" }, "n1 stop")
  eq(#n1.parts, 6, "n1 has r1-r6 as parts")
  for k, part in ipairs(n1.parts) do
    eq(part.anchor, "n1.r" .. k, "part anchor " .. k)
    check(part.address:find("^java:shop%.order%.OrderService#checkout%(Order%)/body/stmts%["), "part address " .. k)
  end
  eq({ n1.parts[1].start, n1.parts[1]["end"] }, { 21, 28 }, "r1 lines")

  -- every box is still to write: "Being written…", marked writing
  for anchor, item in pairs(by_anchor) do
    if not item.stop.lazy then
      eq(item.box.note, "Being written…", "unwritten box " .. anchor)
      check(item.box.writing, "writing mark " .. anchor)
    end
  end

  -- walk edges: gold calls on the main flow, level = effective rating, callsite = badge
  local n2 = by_anchor.n2.stop
  check(n2.next and n2.main, "n2 is a walked main call")
  eq(n2.level, 0, "main flow level 0")
  eq(n2._parent_stop, n1, "n2 hangs off n1")
  eq(n2._parent_box, n1.parts[2], "attached to the part of its site's region (r2)")
  local line = vim.api.nvim_buf_get_lines(n1.buf, n2.callsite.start - 1, n2.callsite.start, false)[1]
  eq(line:sub(n2.callsite.start_col + 1, n2.callsite.end_col), "order.total", "callsite columns read as the badge")
  eq({ n2.site, n2.target }, { "s5", "java:shop.order.Order#total()" }, "call keeps its site and target")
  local n3 = by_anchor.n3.stop
  eq(n3._parent_stop, n2, "nested walk call")
  local walked = {}
  for _, stop in ipairs(data) do
    if stop.next then
      walked[#walked + 1] = stop.anchor
    end
  end
  eq(walked, { "n2", "n3", "n4", "n5", "n6" }, "every walked call is a main-flow snippet")

  -- lazy edges: lazy calls with their reason and the target's range; refs are not projected
  local lazy = by_anchor["n1.s11>java:shop.order.Order#markPaid()"]
  check(lazy and lazy.stop.lazy, "lazy markPaid call")
  eq({ lazy.stop.why, lazy.stop.file, lazy.stop.title }, { "not in the route", "src/main/java/shop/order/Order.java",
    "Order.markPaid()" }, "lazy call fields")
  eq(lazy.stop._parent_box, n1.parts[6], "lazy call attached to r6")
  check(not lazy.stop.next and not lazy.stop.parts[1], "lazy calls are not walked and have no parts")
  local two = 0
  for anchor in pairs(by_anchor) do
    if anchor:find("^n1%.s13>") then
      two = two + 1
    end
  end
  eq(two, 2, "both implementations of notifier.send are offered at one site")
  for anchor in pairs(by_anchor) do
    check(not anchor:find("^n1%.s8>"), "accessor result.ok is not projected")
  end

  -- fresh notes: gist and body; one level away: marked; stale: never shown
  local r2 = live.snippets.n1.regions[2]
  local fp = live.snippets.n1._fps[r2.address]
  store:put(r2.address, { fingerprint = fp, gist = "Compute the total.", body = "Recomputed from the lines.",
    detail = "normal" })
  store:put(live.snippets.n1.symbol, { fingerprint = live.snippets.n1._fps[live.snippets.n1.symbol],
    gist = "Charge the order.", body = "More text.", detail = "detailed" })
  store:put(live.snippets.n2.symbol, { fingerprint = "old", gist = "Stale gist.", body = "Stale.", detail = "normal" })
  local again = stops.normalize(live:stops(), root)
  local function box(anchor)
    for _, stop in ipairs(again) do
      for _, b in ipairs(stops.boxes(stop)) do
        if b.anchor == anchor then
          return b
        end
      end
    end
  end
  eq(box("n1.r2").note, "Compute the total.\n\nRecomputed from the lines.", "fresh note: gist and body")
  eq(box("n1.r2").gist, "Compute the total.", "gist kept on the box")
  check(not box("n1.r2").writing, "a fresh box is not writing")
  eq(box("n1").note, "Charge the order.\n\nMore text.\n\n*(detailed detail)*", "body one level away, marked")
  check(box("n1").writing and box("n1").level_shown == "detailed", "still to write at this level")
  eq(box("n2").note, "Being written…", "a stale note is never shown")

  -- the outline reports statuses and the header carries the fill command
  local text = live:outline({ token = "T1", cli = "code-tour", servername = "/tmp/sock" })
  eq(vim.split(text, "\n")[1], "tour T1 · normal · 6 snippets · 6 to write · 0 gaps · fill: 'code-tour' --fill <n> "
    .. "--pane '/tmp/sock' --tour T1 --detail normal", "outline header")
  check(text:find("write: overview %(level missing%) r1 r3%-r6"), "n1 write list skips the fresh r2")
  check(text:find("n2 Order.total%(%)%s+Order.java:16%-22%s+standard%s+write: overview %(code changed%) r1%-r2"),
    "stale overview reads code changed")
  for _, r in ipairs(live.snippets.n1.regions) do
    store:put(r.address, { fingerprint = live.snippets.n1._fps[r.address], gist = "g", body = "b", detail = "normal" })
  end
  store:put(live.snippets.n1.symbol, { fingerprint = live.snippets.n1._fps[live.snippets.n1.symbol], gist = "g",
    body = "b", detail = "normal" })
  check(live:outline({ token = "T1", cli = "c", servername = "s" }):find("Order%)%s+OrderService.java:21%-39%s+deep%s+fresh"),
    "a fully written snippet is fresh")
  eq(#live:pending(), 5, "five snippets still to write")
end)
