-- Index reuse, remembered lookup misses, per-language greps, deadlines and path spelling.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

t.finish("AST cache", function()
  if not t.parser() then return end
  local ast = require("code-tour.ast")
  local deadline = require("code-tour.ast.deadline")
  local root = t.project()
  local opts = { root = root, cache_dir = t.cache }

  local idx = ast.cached_index(opts)
  t.eq(ast.cached_index(opts), idx, "An unchanged project reuses its index")

  -- every git grep, as { argument... }
  local greps, system = {}, vim.system
  vim.system = function(cmd, ...)
    if cmd[4] == "grep" then greps[#greps + 1] = cmd end
    return system(cmd, ...)
  end
  t.eq(idx:type("shop.order.SdkException"), nil, "An unknown type is not found")
  t.eq(#greps, 1, "It is searched once")
  t.eq(greps[1][#greps[1]], "*.java", "The search is limited to the language's files")
  idx:type("shop.order.SdkException")
  idx:declarations_named("SdkException", "java")
  t.eq(#greps, 1, "A name that was not found is not searched again")

  -- ast.external: a type it claims is not searched for
  local asked, before = {}, #greps
  vim.system = function(cmd, ...)
    if cmd[4] == "grep" then greps[#greps + 1] = cmd end
    return system(cmd, ...)
  end
  local function hooked(external)
    return ast.index(vim.tbl_extend("force", opts, { external = external }))
  end
  local claimed = hooked(function(...) asked[#asked + 1] = { ... }; return true end)
  t.eq(claimed:type("software.amazon.SdkClient"), nil, "An external type is not found")
  claimed:type("software.amazon.SdkClient")
  t.eq(#greps, before, "and not searched for")
  t.eq(asked, { { "software.amazon.SdkClient", "java", claimed.root } }, "The hook is asked once")
  t.check(claimed:type("shop.order.Order"), "A type found by its path is found")
  t.eq(#asked, 1, "without asking the hook")
  for name, external in pairs({ Declines = function() return false end, Fails = function() error("boom") end }) do
    local count = #greps
    t.eq(hooked(external):type("software.amazon." .. name), nil, name .. ": still not found")
    t.eq(#greps, count + 1, name .. ": searched as usual")
  end
  vim.system = system
  ast.setup({ external = function() return true end })
  local first = ast.cached_index(opts)
  t.check(first.external, "The setup option reaches the index")
  ast.options.external = function() return false end -- not through setup(), which clears the cache
  t.check(ast.cached_index(opts) ~= first, "Another hook builds another index")
  ast.setup()
  idx = ast.cached_index(opts)

  local path = root .. "/" .. t.java .. "shop/order/Order.java"
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "// unsaved" })
  local unsaved = ast.cached_index(opts)
  t.check(unsaved ~= idx, "An unsaved edit builds a new index")
  vim.api.nvim_buf_call(buf, function() vim.cmd("silent write") end)
  local saved = ast.cached_index(opts)
  t.check(saved ~= unsaved, "A changed file builds a new index")
  vim.fn.writefile({ "package shop.order;", "class SdkException {}" }, root .. "/" .. t.java .. "shop/order/SdkException.java")
  t.check(ast.cached_index(opts):type("shop.order.SdkException"), "A new file is seen, past remembered misses")

  local current = ast.cached_index(opts)
  current:facts(t.java .. "shop/order/Order.java")
  local ok, why = pcall(deadline.run, 0, function() current:facts(t.java .. "shop/order/Order.java") end)
  t.check(not ok and why:find("was stopped", 1, true), "Work past its deadline stops")
  t.eq(next(current.loaded), nil, "A stopped request leaves no half-resolved facts")
  t.check(ast.cached_index(opts) ~= current, "and its index is not reused")
  t.check(current:facts(t.java .. "shop/order/Order.java"), "The index still works without a deadline")

  -- one search answers for every expected name
  local batched = ast.index(opts)
  batched.expected = { Order = true, Money = true, Missing = true }
  local searches = 0
  vim.system = function(cmd, ...)
    if cmd[4] == "grep" then searches = searches + 1 end
    return system(cmd, ...)
  end
  for _, name in ipairs({ "Line", "Order", "Money" }) do
    t.eq(batched:declaring(name, "java"), { t.java .. (name == "Money" and "shop/money/" or "shop/order/") .. name .. ".java" },
      "Declaring file of " .. name)
  end
  t.eq(batched:declaring("Missing", "java"), {}, "An expected name with no declaration")
  t.eq(searches, 1, "They were searched together")
  vim.system = system

  -- a tour built in slices, yielding at every chance, is the tour built at once
  local tour = require("code-tour.tour")
  tour.setup({ smooth_scroll = false })
  require("code-tour.conversation").deliver = function(_, _, _, _, callback) callback(true) end
  local function outline(result) return (result.outline:gsub("%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x", "TOKEN")) end
  local request = { entries = { "OrderService#checkout" }, overrides = t.route(), root = root }
  local at_once = tour.ast_tour(vim.tbl_extend("force", request, { cache_dir = vim.fn.tempname() }))
  local slice, ticks = require("code-tour.ast.slice"), 0
  slice.budget = 0
  ast.setup() -- forget the index, so everything is resolved again
  local started = tour.ast_tour_start(vim.tbl_extend("force", request, { cache_dir = vim.fn.tempname() }))
  t.check(started.job, "The build is started, not awaited")
  local timer = assert(vim.uv.new_timer())
  timer:start(0, 1, vim.schedule_wrap(function() ticks = ticks + 1 end))
  local state
  t.check(vim.wait(30000, function()
    state = tour.ast_tour_poll(started.job)
    return not state.pending
  end, 5), "The build finishes")
  timer:close()
  t.check(ticks > 1, "The editor ran other work meanwhile")
  t.eq(outline(state.result), outline(at_once), "Slicing does not change the tour")
  local cancelled = tour.ast_tour_start(request)
  tour.ast_tour_cancel(cancelled.job)
  t.check(not pcall(tour.ast_tour_poll, cancelled.job), "A cancelled build is gone")
  local function build(extra, during)
    ast.setup()
    local outcome
    local job = tour.ast_tour_start(vim.tbl_extend("force", request, extra or {}),
      function(ok, result) outcome = { ok = ok, result = result } end)
    if during then during() end
    t.check(vim.wait(30000, function() return outcome ~= nil end, 5), "The build ends")
    return outcome, job
  end
  slice.budget = 0

  -- the source moves under the build: the tour is built again from what is there now
  local service = root .. "/" .. t.java .. "shop/order/OrderService.java"
  local before = vim.fn.readfile(service)
  local edited = build(nil, function()
    vim.fn.writefile(vim.list_extend({ "", "", "" }, before), service)
  end)
  t.check(edited.ok, "A build whose sources change still ends in a tour")
  local live = tour.state().ast
  t.eq(#live:changed_snippets(), 0, "No snippet is marked changed")
  local stop = tour.state().stops[1]
  local shown = table.concat(vim.api.nvim_buf_get_lines(stop.buf, stop.start - 1, stop.start + 1, false), "\n")
  t.check(shown:find("checkout", 1, true), "Its boxes are on the moved lines: " .. shown)
  vim.fn.writefile(before, service)

  local closed = build(nil, function() tour.stop() end)
  t.check(not closed.ok and closed.result:find("changed while", 1, true), "Closing the tour drops the build")

  local superseded
  local replaced = build(nil, function()
    superseded = nil
    tour.ast_tour_start(request, function(ok) superseded = ok end)
  end)
  t.check(not replaced.ok and replaced.result:find("replaced", 1, true), "A superseded build says so")
  t.check(vim.wait(30000, function() return superseded ~= nil end, 5), "and the newer one ends")

  -- examples still arrive when a stopped request drops what the build had read
  local examples = require("code-tour.ast.examples")
  local fresh = ast.index(opts)
  local arrived = false
  examples.prepare(fresh, function() return true end, function() arrived = true end)
  fresh:reset()
  t.check(vim.wait(30000, function() return arrived end, 5), "The examples build restarts after a reset")

  -- a failed search is not an answer
  local failing = ast.index(opts)
  failing.expected = { Order = true }
  vim.system = function(cmd, o)
    if cmd[4] == "grep" then cmd = { "git", "-C", cmd[3], "grep", "-E", "(", "--" } end
    return system(cmd, o)
  end
  t.eq(failing:declarations_named("Money", "java"), {}, "A failed search finds nothing")
  vim.system = system
  t.eq(#failing:declarations_named("Money", "java"), 1, "and is tried again")
  t.eq(#failing:declarations_named("Order", "java"), 1, "also for the names batched with it")
  t.eq(failing:declaring("foo(", "java"), {}, "A non-identifier is not searched")

  slice.budget = 10e6

  local link = vim.fn.tempname() .. "-link"
  vim.uv.fs_symlink(root, link)
  local linked = ast.index({ root = link, cache_dir = t.cache })
  local rel = t.java .. "shop/order/Order.java"
  t.eq(linked.root, idx.root, "A symlinked root is the same root")
  for _, spelled in ipairs({ link .. "/" .. rel, root .. "/" .. rel, root .. "/./src/../" .. rel }) do
    t.eq(linked:rel(spelled), rel, "One project path for " .. spelled)
  end
  local rt = require("code-tour.ast.route").new(linked)
  rt.cwd = root .. "/" .. t.java .. "shop"
  t.check(rt:resolve_entry("order/Order.java:10"), "path:line resolves against the caller's directory")
end)
