local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

t.finish("AST examples", function()
  local recordings = require("code-tour.ast.recordings")
  local consent, stored, asked
  local select = vim.ui.select
  vim.ui.select = function(_, _, callback)
    asked = (asked or 0) + 1
    callback("Decline")
  end
  local store = { meta = function() return { recording_consent = stored } end,
    set_meta = function(_, _, value) stored = value end }
  recordings.consent(store, "ask", function(value) consent = value end)
  t.eq({ consent, stored, asked }, { false, false, 1 }, "Recording permission is requested and saved")
  recordings.consent(store, "ask", function(value) consent = value end)
  t.eq({ consent, asked }, { false, 1 }, "A stored decline persists across requests")
  vim.ui.select = select

  if not t.parser() then return end
  local root = t.project()
  local path = "src/test/java/shop/order/OrderServiceTest.java"
  vim.fn.mkdir(vim.fs.dirname(root .. "/" .. path), "p")
  vim.fn.writefile({
    "package shop.order;",
    "class OrderServiceTest {",
    "  void weak(OrderService service, Order order) {",
    "    service.checkout(order);",
    "  }",
    "  @Test void strong(OrderService service, Order order) {",
    "    var receipt = service.checkout(order);",
    "    assertNotNull(receipt);",
    "    assertTrue(true);",
    "  }",
    "}",
  }, root .. "/" .. path)
  local idx = t.index(root)
  local examples = require("code-tour.ast.examples")
  local matches = examples.tests(idx, { "java:shop.order.OrderService#checkout(Order)" })
  t.eq(vim.tbl_map(function(test) return test.label end, matches), { "OrderServiceTest.strong(OrderService, Order)", "OrderServiceTest.weak(OrderService, Order)" }, "Test calls are indexed")
  t.eq(matches[1].assertions, 2, "The more specific asserted test wins ties")
  t.eq(matches[1].distance, 1, "A direct test outranks an indirect test")
  t.eq(examples.snippet(matches[1]).kind, "example", "Test examples have their own optional snippet")
  t.eq(examples.snippet(matches[1]).example.source, "test", "Example identifies the test source")

  local tour = require("code-tour.tour")
  tour.setup({ smooth_scroll = false })
  local delivered = {}
  require("code-tour.conversation").deliver = function(_, _, prompt, _, callback)
    delivered[#delivered + 1] = prompt
    callback(true)
  end
  tour.ast_tour({ entries = { "OrderService#checkout" }, overrides = t.route(), root = root, cache_dir = t.cache })
  local state = tour.state()
  local stop = state.stops[1]
  t.check(not stop.test_example, "The tour is shown before the tests are searched")
  t.check(vim.wait(10000, function() return stop.test_example ~= nil end), "Examples join the tour afterwards")
  t.eq(stop.test_example._parent_stop, stop, "Example links to its overview")
  t.check(not stop.test_example.next, "Test example stays off the main flow")
  tour.expand_call(stop.test_example)
  t.eq(state.stops[state.stop].kind, "example", "Reader can open the example")
  tour.return_to_caller()
  t.eq(state.stops[state.stop].anchor, "n1", "Reader returns to the symbol")
  local graph = vim.json.decode(table.concat(vim.fn.readfile(tour.graph().path), "\n"))
  t.eq(graph.tour.examples.n1.test.id, matches[1].id, "Graph export includes the offered test")
  t.check(vim.tbl_contains(vim.tbl_map(function(node) return node.id end, graph.symbol_graph.nodes), matches[1].id),
    "Exported symbol subgraph contains the test definition")
  tour.fill("n1", "## overview\nValidate the order.\n\nCharge and issue a receipt.")
  tour.ask("What happens with an empty order?")
  local start = recordings.start
  recordings.start = function(_, _, _, callback)
    callback({ source = "executed", values = { ["checkout"] = "lines = 0" } })
  end
  local result = tour.ast_scenario({ box = "n1", source = "class CodeTourScenario {}" })
  recordings.start = start
  t.eq(result.box, "1.1", "Scenario resolves the pending question")
  local answer = state.stops[state.stop].thread[1]
  t.eq(answer.source, "executed", "Captured scenario is stored as executed")
  t.check(answer.answer:find("lines = 0", 1, true), "Scenario result is part of the answer")
  local recipe = state.ast.recipe.id
  tour.ast_history(recipe)
  t.eq(state.stops[1].gist, "Validate the order.", "Reopening uses the persisted note")
  t.eq(state.stops[1].thread[1].answer, answer.answer, "A scenario answer persists in the Q&A thread")
  require("code-tour.instance").unregister()
end)
