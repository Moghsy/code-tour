-- Renderer marks for AST-backed tours (SPEC-ast-graph §10): ★ CodeTourMainCall badges on the
-- main flow, gap badges with their reason, and gists in the tree view.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
vim.o.lines, vim.o.columns = 50, 140
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _prompt, _, callback) callback(true) end
local notified = {}
vim.notify = function(message) notified[#notified + 1] = message end
local tour, badge = require("tour"), require("code-tour.call-badge")
local STAR = badge.STAR .. " "

local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end

-- Every badge and label in the source buffer of the current stop: badges by their first
-- (row, col), with their group and whether a ★ opens them; eol labels by row.
local function marks()
  local s = tour.state()
  local buf = s.stops[s.stop].buf
  local ns = vim.api.nvim_get_namespaces().CodeTourSource
  local badges, inline, labels = {}, {}, {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local d = m[4]
    local key = m[2] .. ":" .. m[3]
    if d.hl_group and (d.hl_group:match("Call$") or d.hl_group == "CodeTourGap") then
      badges[key] = { group = d.hl_group, end_row = d.end_row, end_col = d.end_col }
    elseif d.virt_text_pos == "inline" then
      local text = {}
      for _, c in ipairs(d.virt_text) do text[#text + 1] = c[1] end
      inline[key] = (inline[key] or "") .. table.concat(text)
    elseif d.virt_text_pos == "eol" then
      local text, groups = {}, {}
      for _, c in ipairs(d.virt_text) do text[#text + 1], groups[#groups + 1] = c[1], c[2] end
      labels[m[2]] = { text = table.concat(text), groups = groups }
    end
  end
  for key, b in pairs(badges) do b.star = (inline[key] or ""):find(STAR, 1, true) ~= nil end
  return badges, labels, buf
end

-- The badge whose text starts with `symbol` on 1-based `line`.
local function at(line, symbol)
  local badges, _, buf = marks()
  local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
  local col = assert(text:find(symbol, 1, true), symbol) - 1
  return badges[(line - 1) .. ":" .. col], col
end

local function title()
  local s = tour.state()
  return s.stops[s.stop].title
end

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p")
vim.fn.writefile({
  "local function entry(input)",
  "  local a = prepare(input)",
  "  local b = helper(a); log(b)",
  "  local c = bus.publish(b)",
  "  return finish(c)",
  "end",
  "",
  "local function other()",
  "  queue.submit(job)",
  "end",
}, root .. "/entry.lua")
for _, name in ipairs({ "prepare", "helper", "log", "finish" }) do
  vim.fn.writefile({ "local function " .. name .. "(x)", "  return x", "end" }, root .. "/" .. name .. ".lua")
end

local function callee(name, extra)
  return vim.tbl_extend("force", { file = name .. ".lua", start = 1, ["end"] = 3, title = name:gsub("^%l", string.upper),
    note = "Explain " .. name .. ".", ast = true, callsite = { start = 0, symbol = name } }, extra)
end

-- A hand-built AST-shaped tour: main calls prepare and finish, a gold helper off the main
-- flow, an optional log that (wrongly) carries `main`, a gap on bus.publish inside part 2,
-- and a second snippet in the same buffer whose overview holds a gap without a reason.
local function show()
  local prepare = callee("prepare", { next = true, main = true, level = 0 })
  prepare.callsite.start = 2
  local helper = callee("helper", { next = true, level = 1 })
  helper.callsite.start = 3
  local log = callee("log", { main = true })
  log.callsite.start = 3
  local finish = callee("finish", { next = true, main = true, level = 0 })
  finish.callsite.start = 5
  local publish_col = ("  local c = "):len()
  tour.show({
    { file = "entry.lua", start = 1, ["end"] = 6, title = "Entry", note = "Run the entry.", ast = true, anchor = "n1",
      parts = {
        { start = 1, ["end"] = 2, note = "Prepare.", anchor = "n1.r1", calls = { prepare } },
        { start = 3, ["end"] = 4, note = "Help and publish.", anchor = "n1.r2", calls = { helper, log },
          gaps = { { callsite = { start = 4, ["end"] = 4, start_col = publish_col, end_col = publish_col + #"bus.publish",
            symbol = "bus.publish" }, text = "bus.publish", reason = "target unknown" } } },
        { start = 5, ["end"] = 6, note = "Finish.", anchor = "n1.r3", calls = { finish } },
      } },
    { file = "entry.lua", start = 8, ["end"] = 10, title = "Other", note = "Queue a job.", ast = true, anchor = "n7",
      gaps = { { callsite = { start = 9, symbol = "queue.submit" }, text = "queue.submit" } } },
  }, { root = root })
end

local function hand_built()
  tour.setup({ smooth_scroll = false, keys = false })
  -- highlight groups: a stronger gold than the plain gold call, with its cap; a gap colour
  t.check(hl("CodeTourMainCall").bg and hl("CodeTourMainCall").bg ~= hl("CodeTourNextCall").bg,
    "CodeTourMainCall is a gold distinct from CodeTourNextCall")
  t.check(hl("CodeTourMainCallCap").fg == hl("CodeTourMainCall").bg, "main badge cap matches its colour")
  t.check(hl("CodeTourGap").bg and hl("CodeTourGap").bg ~= hl("CodeTourCall").bg, "CodeTourGap has its own colour")
  t.check(hl("CodeTourGapCap").fg == hl("CodeTourGap").bg, "gap badge cap matches its colour")
  show()
  t.eq(title(), "Entry", "the tour opens on the entry")

  -- the first main call is the one the walk takes next: the walk's colour wins, ★ stays
  local prepare = at(2, "prepare")
  t.eq(prepare and prepare.group, "CodeTourCurrentCall", "the current main call keeps the walk's colour")
  t.check(prepare.star, "the current main call carries ★")
  -- a later main call: stronger gold with ★
  local finish = at(5, "finish")
  t.eq(finish and finish.group, "CodeTourMainCall", "a later main call is CodeTourMainCall")
  t.check(finish.star, "a later main call carries ★")
  -- a gold call off the main flow: plain gold, no star
  local helper = at(3, "helper")
  t.eq(helper and helper.group, "CodeTourNextCall", "a gold call off the main flow stays CodeTourNextCall")
  t.check(not helper.star, "a gold call off the main flow has no ★")
  -- `main` without `next` draws no star: main edges are always walked
  local log = at(3, "log")
  t.eq(log and log.group, "CodeTourCall", "an optional call stays red")
  t.check(not log.star, "an optional call never carries ★")

  -- gaps: a badge on the site with the reason, in this snippet's part and the other snippet
  local gap, col = at(4, "bus.publish")
  t.eq(gap and gap.group, "CodeTourGap", "a gap is a CodeTourGap badge on its site")
  t.eq(gap.end_col, col + #"bus.publish", "the gap badge covers the site's columns")
  t.check(not gap.star, "a gap carries no ★")
  local _, labels = marks()
  t.check(labels[3] and labels[3].text:find("gap: target unknown", 1, true), "the gap label gives its reason")
  t.check(vim.tbl_contains(labels[3].groups, "CodeTourGapLabel"), "the gap label is CodeTourGapLabel")
  local other = at(9, "queue.submit")
  t.eq(other and other.group, "CodeTourGap", "a gap in another ready snippet of the buffer is drawn")
  t.check(labels[8] and labels[8].text:find("<- gap", 1, true) and not labels[8].text:find("gap:", 1, true),
    "a gap without a reason is labelled plainly")
  -- labels: the main call's label is in the main gold; the current call's in the walk colour
  t.check(vim.tbl_contains(labels[4].groups, "CodeTourMainLabel"), "a later main call's label is CodeTourMainLabel")
  t.check(vim.tbl_contains(labels[1].groups, "CodeTourCurrentLabel"), "the current call's label is CodeTourCurrentLabel")
  -- marks stay whichever box is focused
  tour.next_explanation(1)
  t.eq(at(4, "bus.publish").group, "CodeTourGap", "the gap badge stays when another box is focused")

  -- walk into prepare and back: the visited main call takes the visited colour, ★ stays
  for _ = 1, 10 do
    if title() == "Prepare" then break end
    tour.next_explanation(1)
  end
  t.eq(title(), "Prepare", "the walk enters the main call")
  for _ = 1, 10 do
    if title() == "Entry" then break end
    tour.next_explanation(1)
  end
  t.eq(title(), "Entry", "the walk returns to the caller")
  local done = at(2, "prepare")
  t.eq(done.group, "CodeTourDoneCall", "a visited main call shows as visited")
  t.check(done.star, "a visited main call keeps ★")

  -- tree: gists label the snippets once they exist, and only then
  tour.tree("float")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  t.check(text:find("Entry", 1, true) and not text:find("Main flow gist", 1, true), "no gist row before a gist exists")
  require("code-tour.tree").close()
  local s = tour.state()
  s.stops[1].gist = "Main flow gist: checks the input and then hands it to the helpers in turn before finishing up"
  tour.tree("float")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  text = table.concat(lines, "\n")
  t.check(text:find("Main flow gist: checks", 1, true), "the tree shows the snippet's gist")
  t.check(text:find("finishing up", 1, true), "a long gist wraps onto further rows")
  local widest = 0
  for _, l in ipairs(lines) do widest = math.max(widest, vim.fn.strdisplaywidth(l)) end
  local top
  for i, l in ipairs(lines) do if l:find("1. Entry", 1, true) then top = i end end
  t.check(lines[top + 1]:find("Main flow gist", 1, true), "the gist sits under the title")
  local has_gist_span = false
  local tree_ns = vim.api.nvim_get_namespaces()["code-tour-tree"]
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, tree_ns, 0, -1, { details = true })) do
    has_gist_span = has_gist_span or m[4].hl_group == "CodeTourTreeGist"
  end
  t.check(has_gist_span, "the gist row is highlighted CodeTourTreeGist")
  -- box borders stay aligned around the wrapped gist
  local border = vim.fn.strdisplaywidth(lines[top - 1])
  for i = top, top + 3 do t.eq(vim.fn.strdisplaywidth(lines[i]), border, "box row " .. i .. " keeps the border width") end
  require("code-tour.tree").close()
  -- an endless gist is cut off with an ellipsis after a few rows
  s.stops[1].gist = string.rep("word ", 80)
  tour.tree("float")
  text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  t.check(text:find("…", 1, true) and select(2, text:gsub("word", "")) < 80, "a long gist is truncated")
  require("code-tour.tree").close()
  s.stops[1].gist = nil
end

-- The real fixture: the checkout flow's walk calls carry `main` and so the ★ mark; a
-- written overview gist reaches the tree.
local function fixture()
  if not t.parser() then return end
  local result = tour.ast_tour({ entries = { "OrderService#checkout" }, root = t.project(), cache_dir = t.cache })
  t.check(result and result.tour, "the AST tour opens")
  local s = tour.state()
  local main_calls = 0
  for _, stop in ipairs(s.stops) do
    if stop.main and stop.next then main_calls = main_calls + 1 end
  end
  t.check(main_calls > 0, "the checkout tour has main-flow calls")
  local badges = marks()
  local starred, main_group = 0, 0
  for _, b in pairs(badges) do
    if b.star then starred = starred + 1 end
    if b.group == "CodeTourMainCall" then main_group = main_group + 1 end
  end
  local entry_main = 0
  for _, stop in ipairs(s.stops) do
    if stop.main and stop.next and stop._parent_stop == s.stops[s.stop] then entry_main = entry_main + 1 end
  end
  t.eq(starred, entry_main, "every main call of the entry carries ★, and nothing else does")
  t.check(main_group >= entry_main - 1, "main calls not yet current are CodeTourMainCall")
  -- a written gist shows in the tree
  local live = s.ast
  local sn = live.snippets.n1
  live.store:put(sn.symbol, { fingerprint = sn._fps[sn.symbol], file = sn.file, gist = "Checks out the order.",
    detail = live.detail })
  tour._ast.refresh()
  t.eq(s.stops[1].gist, "Checks out the order.", "the refreshed stop carries the gist")
  tour.tree("float")
  local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  t.check(text:find("Checks out the order.", 1, true), "the fixture tree shows n1's gist")
  require("code-tour.tree").close()
end

t.finish("ast_render", function()
  hand_built()
  fixture()
end)
