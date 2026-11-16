-- Default saved-open behavior: unchanged unchecked prose is reused, and the
-- remaining regeneration targets travel in batched requests.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME or vim.fn.expand("~/.local/share/nvim/site"))
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = root .. "/state", root .. "/cache"
vim.env.XDG_DATA_HOME = root .. "/data"
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
local sent = {}
require("code-tour.conversation").deliver = function(_, _root, prompt, action, callback)
  sent[#sent + 1] = { prompt = prompt, action = action }
  callback(true)
end
local tour, source, saved, library =
  require("tour"), require("code-tour.source"), require("code-tour.saved"), require("code-tour.library")
local checks = 0
local function check(value, message)
  assert(value, message)
  checks = checks + 1
end
local function state()
  return tour.state()
end
local function active()
  vim.wait(10, function()
    return false
  end, 1)
  return state().saved.active
end
local function stop_for(item)
  local first, last = source.lines(item.capture.range)
  return { box = item.entry.id, file = item.entry.path, start = first, ["end"] = last, note = "Fresh " .. item.entry.id }
end
local function titles()
  local s = tour.state()
  return s.stops[s.stop].title .. "." .. s.box
end
local function walk_through(n)
  local seen = { titles() }
  for _ = 1, n do
    tour.next_explanation(1)
    seen[#seen + 1] = titles()
  end
  return table.concat(seen, " ")
end
local notes = {}
vim.notify = function(message) notes[#notes + 1] = message end
local function run()
  vim.fn.mkdir(root .. "/app/.git", "p")
  local lines = {}
  for i = 1, 20 do lines[i] = "line " .. i end
  vim.fn.writefile(lines, root .. "/app/main.lua")
  tour.setup({ smooth_scroll = false })
  check(tour.state().opts.walk == true, "Graph-driven navigation is the default")
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 6, title = "Main", note = "Main flow",
    parts = {
      { start = 1, ["end"] = 3, note = "Calls B then C", calls = {
        { file = "main.lua", start = 8, ["end"] = 9, title = "B", note = "B body", next = true,
          callsite = { start = 2, ["end"] = 2, symbol = "b" } },
        { file = "main.lua", start = 11, ["end"] = 12, title = "C", note = "C body",
          callsite = { start = 3, ["end"] = 3, symbol = "c" } },
      } },
      { start = 4, ["end"] = 6, note = "Finish" },
    },
  } }, { root = root .. "/app" })
  local expected = "Main.1 Main.2 B.1 Main.3"
  check(walk_through(3) == expected, "Only the gold callee is walked; the optional one waits: " .. expected)
  local view = require("code-tour.tour-view")
  local function header() return view.state().rows[2][2][1] end
  tour.next_explanation(-1)
  check(titles() == "B.1" and header():find("Snippet 2/2", 1, true), "Snippets are numbered in walk order: " .. header())
  tour.next_explanation(-1)
  check(header():find("Snippet 1/2", 1, true), "The caller keeps its own number: " .. header())
  tour.next_snippet(1)
  check(titles() == "B.1" and header():find("Snippet 2/2", 1, true), "an goes to the next snippet in walk order")
  tour.next_snippet(-1)
  check(titles() == "Main.1" and header():find("Snippet 1/2", 1, true), "ap goes back in walk order")
  tour.next_explanation(3)
  tour.expand_call(tour.state().stops[3])
  check(header():find("Snippet 1/2 · optional", 1, true), "An optional branch is labelled as optional: " .. header())
  tour.next_snippet(-1)
  tour.next_explanation(3)
  check(titles() == "Main.3", "Back on the walk after the optional branch")
  tour.next_explanation(1)
  check(titles() == "Main.3", "The end of the walk stays put")
  tour.next_explanation(-1)
  check(titles() == "B.1", "Previous walks back up the route")
  tour.next_explanation(-1)
  check(titles() == "Main.2", "Walking back returns to the caller")
  tour.next_explanation(1)
  check(titles() == "B.1", "Walking forward again repeats the same route")
  tour.next_explanation(-5)
  check(titles() == "Main.1", "The start stays put when going back")
  -- Call badges stay visible when another part of the snippet is focused.
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 6, title = "Main", note = "Main flow",
    parts = {
      { start = 1, ["end"] = 3, note = "Calls B then C", calls = {
        { file = "main.lua", start = 8, ["end"] = 9, title = "B", note = "B body", next = true,
          callsite = { start = 2, ["end"] = 2, symbol = "line" } },
        { file = "main.lua", start = 11, ["end"] = 12, title = "C", note = "C body",
          callsite = { start = 3, ["end"] = 3, symbol = "line" } },
      } },
      { start = 4, ["end"] = 6, note = "Finish" },
    },
  } }, { root = root .. "/app" })
  local function badge_rows()
    local s2, rows = tour.state(), {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s2.stops[s2.stop].buf,
      vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })) do
      local g = mark[4].hl_group
      if g == "CodeTourCurrentCall" or g == "CodeTourNextCall" or g == "CodeTourCall" or g == "CodeTourDoneCall" then rows[mark[2] + 1] = g end
    end
    return rows
  end
  local overview_rows = badge_rows()
  tour.next_explanation(3)
  check(titles() == "Main.3", "Moved to the last part: " .. titles())
  local later = badge_rows()
  check(later[2] == "CodeTourDoneCall" and later[3] == "CodeTourCall",
    "Badges of calls in other parts stay visible, the finished gold call in its own colour: " .. vim.inspect(later))
  check(vim.deep_equal(vim.tbl_keys(later), vim.tbl_keys(overview_rows)) or #vim.tbl_keys(later) == #vim.tbl_keys(overview_rows),
    "The same calls are badged in every box")
  -- Several calls on one line are separate edges, walked in authored order.
  vim.fn.writefile({ "local r = first(1) + second(2) + third(3)", "return r", "", "local function first() end",
    "local function second() end", "local function third() end" }, root .. "/app/multi.lua")
  tour.show({ {
    file = "multi.lua", start = 1, ["end"] = 2, title = "Line", note = "One line, three calls",
    parts = { { start = 1, ["end"] = 2, note = "Sum", calls = {
      { file = "multi.lua", start = 5, ["end"] = 5, title = "Second", note = "s", next = true,
        callsite = { start = 1, ["end"] = 1, start_col = 21, end_col = 30, symbol = "second" } },
      { file = "multi.lua", start = 4, ["end"] = 4, title = "First", note = "f", next = true,
        callsite = { start = 1, ["end"] = 1, start_col = 10, end_col = 18, symbol = "first" } },
      { file = "multi.lua", start = 6, ["end"] = 6, title = "Third", note = "t", next = true,
        callsite = { start = 1, ["end"] = 1, start_col = 33, end_col = 41, symbol = "third" } },
    } } },
  } }, { root = root .. "/app" })
  local line = {}
  for _ = 1, 6 do tour.next_explanation(1); line[#line + 1] = titles() end
  check(table.concat(line, " ") == "Line.2 Second.1 Line.2 First.1 Line.2 Third.1", "Calls on one line walk in authored order: " .. table.concat(line, " "))
  local graph = vim.json.decode(table.concat(vim.fn.readfile(tour.graph().path), "\n"))
  local columns = {}
  for _, link in ipairs(graph.links) do if link.via == "call" then columns[#columns + 1] = link.callsite.start_col end end
  check(#columns == 3 and columns[1] == 21, "Each edge keeps its own call columns on a shared line")
  -- Recursion marked ref is a reference, not a cycle.
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 6, title = "Main", note = "Main flow",
    parts = { { start = 1, ["end"] = 3, note = "Calls B", calls = {
      { file = "main.lua", start = 8, ["end"] = 9, title = "B", note = "B calls Main again", next = true, calls = {
        { file = "main.lua", start = 1, ["end"] = 6, title = "Main again", note = "recursion", ref = true,
          callsite = { start = 8, ["end"] = 8, symbol = "main" } } },
        callsite = { start = 2, ["end"] = 2, symbol = "b" } } } },
      { start = 4, ["end"] = 6, note = "Finish" } },
  } }, { root = root .. "/app" })
  local seen = {}
  local before = #notes
  tour.next_explanation(0)
  for _ = 1, 4 do tour.next_explanation(1); seen[#seen + 1] = titles() end
  check(table.concat(seen, " ") == "Main.2 B.1 Main.3 Main.3" and #notes == before, "Marked recursion walks without a cycle: " .. table.concat(seen, " "))
  -- Recursion needs no marking: the call back onto the path is a reference automatically.
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 6, title = "Main", note = "Main flow",
    parts = { { start = 1, ["end"] = 3, note = "Calls B", calls = {
      { file = "main.lua", start = 8, ["end"] = 9, title = "B", note = "B calls Main again", next = true, calls = {
        { file = "main.lua", start = 1, ["end"] = 6, title = "Main again", note = "recursion", next = true,
          callsite = { start = 8, ["end"] = 8, symbol = "main" } } },
        callsite = { start = 2, ["end"] = 2, symbol = "b" } } } },
      { start = 4, ["end"] = 6, note = "Finish" } },
  } }, { root = root .. "/app" })
  seen = {}
  for _ = 1, 4 do tour.next_explanation(1); seen[#seen + 1] = titles() end
  check(table.concat(seen, " ") == "Main.2 B.1 Main.3 Main.3" and #notes == before, "Unmarked recursion walks without a warning: " .. table.concat(seen, " "))
  -- The gold call the walk takes next gets its own colour; other gold calls keep theirs.
  tour.show({ {
    file = "multi.lua", start = 1, ["end"] = 2, title = "Line", note = "One line, three calls",
    parts = { { start = 1, ["end"] = 2, note = "Sum", calls = {
      { file = "multi.lua", start = 4, ["end"] = 4, title = "First", note = "f", next = true,
        callsite = { start = 1, ["end"] = 1, start_col = 10, end_col = 18, symbol = "first" } },
      { file = "multi.lua", start = 5, ["end"] = 5, title = "Second", note = "s", next = true,
        callsite = { start = 1, ["end"] = 1, start_col = 21, end_col = 30, symbol = "second" } },
      { file = "multi.lua", start = 6, ["end"] = 6, title = "Third", note = "t",
        callsite = { start = 1, ["end"] = 1, start_col = 33, end_col = 41, symbol = "third" } },
    } } },
  } }, { root = root .. "/app" })
  local function groups()
    local s, found = tour.state(), {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.stops[s.stop].buf,
      vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })) do
      local group = mark[4].hl_group
      if group == "CodeTourCurrentCall" or group == "CodeTourNextCall" or group == "CodeTourCall" or group == "CodeTourDoneCall" then
        found[mark[3]] = group
      end
    end
    return found
  end
  tour.next_explanation(1)
  local g = groups()
  check(g[10] == "CodeTourCurrentCall" and g[21] == "CodeTourNextCall" and g[33] == "CodeTourCall",
    "Upcoming gold call is its own colour, other gold and optional calls keep theirs: " .. vim.inspect(g))
  tour.next_explanation(2)
  g = groups()
  check(g[21] == "CodeTourCurrentCall" and g[10] == "CodeTourDoneCall" and g[33] == "CodeTourCall",
    "After returning, the finished call is marked done and the following gold call is current: " .. vim.inspect(g))
  tour.next_explanation(2)
  g = groups()
  check(g[21] == "CodeTourDoneCall" and g[10] == "CodeTourDoneCall",
    "Every call we came out of is marked done: " .. vim.inspect(g))
  tour.next_explanation(-2)
  g = groups()
  check(g[10] == "CodeTourDoneCall" and g[21] == "CodeTourCurrentCall", "Walking back un-marks the later call, which is the next snippet again: " .. vim.inspect(g))
  -- an walks the same route as aj, one stop per snippet: parts are skipped but the
  -- returns to the calling snippet between branches are kept.
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 9, title = "Main", note = "Main flow",
    parts = {
      { start = 1, ["end"] = 3, note = "Setup" },
      { start = 4, ["end"] = 6, note = "Calls B then C", calls = {
        { file = "main.lua", start = 11, ["end"] = 12, title = "B", note = "B body", next = true,
          parts = { { start = 11, ["end"] = 11, note = "b1" }, { start = 12, ["end"] = 12, note = "b2" } },
          callsite = { start = 4, ["end"] = 4, symbol = "line" } },
        { file = "main.lua", start = 14, ["end"] = 15, title = "C", note = "C body", next = true,
          callsite = { start = 5, ["end"] = 5, symbol = "line" } },
      } },
      { start = 7, ["end"] = 9, note = "Finish" },
    },
  } }, { root = root .. "/app" })
  local function an(delta, n)
    local seen = {}
    for _ = 1, n do tour.next_snippet(delta); seen[#seen + 1] = titles() end
    return table.concat(seen, " ")
  end
  check(titles() == "Main.1", "Starts at the first snippet")
  check(an(1, 5) == "B.1 Main.1 C.1 Main.1 Main.1", "an returns to the caller's overview between branches: " .. an(-1, 0))
  check(an(-1, 5) == "C.1 Main.1 B.1 Main.1 Main.1", "ap retraces the same snippet-level route")
  -- After an returns to the caller, aj carries on along the route instead of replaying it.
  tour.next_snippet(1)
  tour.next_snippet(1)
  check(titles() == "Main.1", "Back on the caller")
  tour.next_explanation(1)
  check(titles() == "C.1", "aj continues with the next branch after a returned-to caller: " .. titles())
  -- The next snippet is green whichever box is focused, not only the box that makes the call.
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 6, title = "Main", note = "Main flow",
    parts = {
      { start = 1, ["end"] = 3, note = "First part" },
      { start = 4, ["end"] = 6, note = "Second part", calls = {
        { file = "main.lua", start = 8, ["end"] = 9, title = "B", note = "B body", next = true,
          callsite = { start = 5, ["end"] = 5, symbol = "line" } } } },
    },
  } }, { root = root .. "/app" })
  local function rows()
    local s2, found = tour.state(), {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s2.stops[s2.stop].buf,
      vim.api.nvim_get_namespaces().CodeTourSource, 0, -1, { details = true })) do
      local g = mark[4].hl_group
      if g == "CodeTourCurrentCall" or g == "CodeTourNextCall" or g == "CodeTourCall" or g == "CodeTourDoneCall" then found[mark[2] + 1] = g end
    end
    return found
  end
  check(titles() == "Main.1" and rows()[5] == "CodeTourCurrentCall", "Next snippet is green from the overview: " .. vim.inspect(rows()))
  tour.next_explanation(1)
  check(titles() == "Main.2" and rows()[5] == "CodeTourCurrentCall", "Next snippet is green in a part that does not make the call: " .. vim.inspect(rows()))
  tour.next_explanation(1)
  check(titles() == "Main.3" and rows()[5] == "CodeTourCurrentCall", "Next snippet is green in the calling part")
  tour.next_explanation(1)
  check(titles() == "B.1" and rows()[5] == "CodeTourDoneCall", "Once entered it is no longer next: " .. vim.inspect(rows()))
  -- Turning the option off restores the older route.
  tour.setup({ smooth_scroll = false, walk = false })
  tour.show({ { file = "main.lua", start = 1, ["end"] = 4, title = "Plain", note = "n",
    parts = { { start = 1, ["end"] = 2, note = "a" }, { start = 3, ["end"] = 4, note = "b" } } } }, { root = root .. "/app" })
  tour.next_explanation(1)
  check(titles() == "Plain.2", "walk = false uses the older route")
end
local ok, err = pcall(run)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("PASS: " .. checks .. " graph navigation checks")
