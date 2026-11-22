-- Live AST tours across structural changes (SPEC-ast-graph §3.5, §7, §8.6, §9.4–9.5):
-- box ids handed out before a selection split keep naming the same boxes; a source edit
-- withholds the snippet's notes and refuses structural operations without leaving the
-- live tour and the shown stops out of step; stops outside the AST projection survive a
-- detail change; a snippet shared by two lazy sites stays one object; the return stack
-- survives a detail change; nothing is requested twice.
--   nvim --clean --headless -l tests/ast_live.lua
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

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

t.finish("ast live", function()
  if not t.parser() then
    return
  end
  local tour = require("tour")
  local stops = require("code-tour.stops")
  tour.setup({ keys = false, smooth_scroll = false })
  local root = t.project()
  local function open()
    sent = {}
    tour.ast_tour({ entries = { "OrderService#checkout" }, root = root, cache_dir = t.cache,
      store = require("code-tour.ast.notes").new() })
    return tour.state()
  end
  local function find(anchor)
    local s = tour.state()
    for i, stop in ipairs(s.stops) do
      for k, box in ipairs(stops.boxes(stop)) do
        if box.anchor == anchor then
          return stop, box, i, k
        end
      end
    end
  end
  local function selection(s, file, first, last)
    local buf = vim.fn.bufadd(root .. "/" .. file)
    vim.fn.bufload(buf)
    return require("code-tour.selection").capture(s, { buf = buf, start = first, ["end"] = last })
  end
  local checkout = "src/main/java/shop/order/OrderService.java"
  local addr = "java:shop.order.OrderService#checkout(Order)/body/"

  -- a split keeps every other box id: a fill for r6 handed out before it lands on r6
  local s = open()
  local r6 = select(2, find("n1.r6")).address
  eq(r6, addr .. "stmts[7..10]", "r6 before the split")
  local id = tour.explain_range(selection(s, checkout, 22, 23))
  eq(id, "n1", "the selection inside r1 asks about n1")
  check(sent[#sent]:find("%[code%-tour explain%] n1 OrderService.checkout%(Order%), box r7"), "new box r7 named")
  eq(select(2, find("n1.r6")).address, r6, "r6 still names the same region after the split")
  eq(select(2, find("n1.r1")).address, addr .. "stmts[1..2]", "the split leaf keeps its id")
  check(select(2, find("n1.r7")) and select(2, find("n1.r8")), "the new boxes take the next free ids")
  tour.fill("n1", "## r6\nMark paid and build the receipt.\n\nBody.")
  check(select(2, find("n1.r6")).note:find("^Mark paid"), "the fill lands on the box it was written for")

  -- a source edit: notes withheld, fills and structural operations refused, state in step
  s = open()
  tour.fill("n2", "## overview\nSums the lines.\n\nBody.")
  local n2 = find("n2")
  eq(n2.note, "Sums the lines.\n\nBody.", "n2 written")
  vim.api.nvim_buf_set_lines(n2.buf, n2.start, n2.start, false, { "        int unused = 42;" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = n2.buf })
  eq(find("n2").note, require("code-tour.ast.live").changed_note, "notes on edited code are withheld")
  local ok, err = pcall(tour.fill, "n2", "## overview\nNew.\n\nBody.")
  check(not ok and tostring(err):find("Source changed"), "a fill for the edited snippet is refused")
  local before = #s.stops
  ok, err = pcall(tour.ast_detail, "detailed")
  check(not ok and tostring(err):find("Source changed; rebuild with code%-tour ast %(n2%)"), "detail change refused")
  eq({ s.ast.detail, #s.stops }, { "normal", before }, "the live tour and the stops are unchanged")
  local lazy = find("n1.s11>java:shop.order.Order#markPaid()")
  tour.expand_call(lazy)
  check(find("n1.s11>java:shop.order.Order#markPaid()").lazy, "ad refused while the source differs")
  check(notices[#notices]:find("Source changed"), "and the reader is told why")
  vim.cmd("silent! %bwipeout!")

  -- stops outside the AST projection survive a detail change, with their request
  root = t.project()
  s = open()
  local cid = tour.explain_range(selection(s, "src/main/java/shop/catalog/Catalog.java", 3, 5))
  check(s.pending[cid], "an explanation outside every snippet is pending")
  tour.ast_detail("exhaustive")
  local placeholder = false
  for _, stop in ipairs(s.stops) do
    placeholder = placeholder or stop.placeholder == cid
  end
  check(placeholder and s.pending[cid], "its placeholder and request survive the detail change")
  tour.fill(cid, { { file = "src/main/java/shop/catalog/Catalog.java", start = 3, ["end"] = 5, title = "Cat",
    note = "Catalog note" } })
  local filled = false
  for _, stop in ipairs(s.stops) do
    filled = filled or stop.title == "Cat"
  end
  check(filled, "and its fill still arrives")

  -- nothing is requested twice: a detail round trip re-requests nothing already asked
  s = open()
  eq(#sent, 0, "the CLI's outline is the initial request")
  tour.ast_detail("detailed")
  local after_first = #sent
  tour.ast_detail("normal")
  eq(#sent, after_first, "returning to normal asks for nothing already requested")
  tour.ast_detail("detailed")
  eq(#sent, after_first, "nor does going back to detailed")

  -- a snippet shared by two lazy sites stays one object across a detail change
  s = open()
  local live = s.ast
  live:expand("n1.s3>java:shop.order.Order#getLines()")
  live:expand("n4.s1>java:shop.order.Order#getLines()")
  local count = #live:all()
  live:set_detail("detailed")
  local a, b = live.expanded["n1.s3>java:shop.order.Order#getLines()"],
    live.expanded["n4.s1>java:shop.order.Order#getLines()"]
  check(a == b and live.snippets[a.n] == a, "the shared snippet is rebuilt once")
  eq(#live:all(), count, "and listed once")

  -- the return stack survives a detail change
  s = open()
  local n2stop = find("n2")
  local _, pk = select(3, find(n2stop._parent_box.anchor))
  s.stop, s.box = select(3, find("n1")), pk
  tour.expand_call(n2stop)
  eq(#s.frames, 1, "entered n2 from n1")
  tour.ast_detail("detailed")
  eq(#s.frames, 1, "the frame survives")
  eq(s.frames[1].call.anchor, "n2", "and points at the new n2 stop")
  check(s.frames[1].call == find("n2"), "by identity in the new stops")
end)
