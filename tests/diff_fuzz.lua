-- Property tests for review diffs. For many random base/new file pairs the diff data
-- (`added`, `removed`) must reconstruct BOTH files exactly, whatever the edit looks like:
-- merging context, added and removed lines in display order gives the old file when the added
-- lines are dropped and the new file when the removed lines are dropped. The same must hold for
-- what is drawn (highlights and virtual lines), for sub-ranges, and for awkward files (empty,
-- no trailing newline, CRLF, BOM, renames).
--   nvim --clean --headless -l tests/diff_fuzz.lua
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, cb) cb(true) end
local tour = require("tour")
local review = require("code-tour.review")
local stops = require("code-tour.stops")
tour.setup({ smooth_scroll = false })

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(args)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = root, text = true }):wait()
  assert(result.code == 0, table.concat(args, " ") .. ": " .. (result.stderr or ""))
  return result.stdout
end
local function commit(message)
  git({ "add", "-A" })
  git({ "-c", "user.name=t", "-c", "user.email=t@t.invalid", "commit", "--quiet", "--allow-empty", "-m", message })
end
git({ "init", "--quiet" })
git({ "config", "core.autocrlf", "false" })

local checks, failures = 0, {}
local function fail(case, message)
  failures[#failures + 1] = ("%s: %s"):format(case, message)
end
local function eq(case, actual, expected, message)
  checks = checks + 1
  if not vim.deep_equal(actual, expected) then
    fail(case, ("%s\n    expected %s\n    actual   %s"):format(message, vim.inspect(expected), vim.inspect(actual)))
    return false
  end
  return true
end

-- Merge new lines with the removed blocks in display order.
local function merged(new, stop, removed_blocks)
  local rows = {}
  local function dels(line, above)
    for _, block in ipairs(removed_blocks) do
      if block.line == line and (block.above == true) == above then
        for _, text in ipairs(block.lines) do rows[#rows + 1] = { kind = "del", text = text } end
      end
    end
  end
  for i = 1, #new do
    dels(i, true)
    rows[#rows + 1] = { kind = stop.added[i] and "add" or "ctx", text = new[i] }
    dels(i, false)
  end
  return rows
end
local function view(rows, drop)
  local out = {}
  for _, row in ipairs(rows) do
    if row.kind ~= drop then out[#out + 1] = row.text end
  end
  return out
end

-- file contents as written (so tests control newlines and CRs)
local function write(path, text)
  local fd = assert(io.open(root .. "/" .. path, "wb"))
  fd:write(text)
  fd:close()
end
local function split(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  return lines
end

local function stop_for(path, first, last)
  return stops.normalize({ { file = path, start = first, ["end"] = last, note = "n" } }, root)[1]
end

-- ---- generators ------------------------------------------------------------------------
math.randomseed(tonumber(vim.env.DIFF_FUZZ_SEED) or 20260101)
local alphabet = { "a", "b", "c", "d", "", "x = 1", "x = 1", "end", "  b", "}", "}" } -- repeats and blanks on purpose
local function line() return alphabet[math.random(#alphabet)] end
local function random_lines(n)
  local out = {}
  for i = 1, n do out[i] = line() end
  return out
end
local function mutate(lines)
  local out = vim.deepcopy(lines)
  for _ = 1, math.random(1, 4) do
    local kind = math.random(6)
    local at = math.random(0, #out)
    if kind == 1 then
      for _, l in ipairs(random_lines(math.random(1, 3))) do table.insert(out, at + 1, l) end
    elseif kind == 2 and #out > 0 then
      for _ = 1, math.random(1, 3) do if #out > 0 then table.remove(out, math.max(1, math.min(at + 1, #out))) end end
    elseif kind == 3 and #out > 0 then
      out[math.max(1, math.min(at + 1, #out))] = line() .. "!"
    elseif kind == 4 and #out > 1 then -- move a line
      local from = math.random(#out)
      local l = table.remove(out, from)
      table.insert(out, math.random(0, #out) + 1, l)
    elseif kind == 5 and #out > 0 then -- duplicate a block
      local from = math.random(#out)
      table.insert(out, from, out[from])
    elseif kind == 6 then
      out = {}
    end
  end
  return out
end
local function join(lines, newline, final)
  local text = table.concat(lines, newline)
  if #lines > 0 and final then text = text .. newline end
  return text
end

-- ---- the property --------------------------------------------------------------------------
local function check_pair(case, old_text, new_text, opts)
  opts = opts or {}
  local path = opts.path or "f.txt"
  vim.cmd("silent! %bwipeout!") -- the files are rewritten on disk between cases
  write(path, old_text)
  commit("base " .. case)
  write(path, new_text)
  local function lines_of(text)
    return split((text:gsub("\r\n", "\n"):gsub("^\239\187\191", "")))
  end
  local old_lines, new_lines = lines_of(old_text), lines_of(new_text)
  local stop = stop_for(path, 1, math.max(#new_lines, 1))
  local ok, err = pcall(review.prepare, stop, root, "HEAD")
  if not ok then
    fail(case, "prepare raised: " .. tostring(err))
    return
  end
  if #new_lines == 0 then
    -- an emptied file: the editor shows one blank line, which is not a line of the file
    local flat = {}
    for _, block in ipairs(stop.removed) do vim.list_extend(flat, block.lines) end
    eq(case, flat, old_lines, "emptied file: every old line is shown as removed")
    eq(case, vim.tbl_count(stop.added), 0, "emptied file: the editor's blank line is not an addition")
    return
  end
  local function counts()
    local removed_count = 0
    for _, block in ipairs(stop.removed) do removed_count = removed_count + #block.lines end
    return { vim.tbl_count(stop.added), removed_count }
  end
  if opts.counts then
    -- directed cases where the right answer is known and git's own count is not it (line endings, BOM)
    eq(case, counts(), opts.counts, "only the real change is shown")
  end
  if opts.oracle ~= false and not opts.counts then
    -- git's histogram diff (the algorithm the plugin asks for) must report the same amount of change:
    -- a line the plugin shows as changed that git does not is a false positive
    local numstat = git({ "diff", "--numstat", "--diff-algorithm=histogram", "--", path })
    local adds, dels = numstat:match("^(%d+)%s+(%d+)")
    local removed_count = 0
    for _, block in ipairs(stop.removed) do removed_count = removed_count + #block.lines end
    if not eq(case, { vim.tbl_count(stop.added), removed_count }, { tonumber(adds) or 0, tonumber(dels) or 0 },
        "added/removed line counts match git diff --numstat") then
      failures[#failures] = failures[#failures] .. ("\n    old %s\n    new %s"):format(vim.inspect(old_text), vim.inspect(new_text))
    end
  end
  local rows = merged(new_lines, stop, stop.removed)
  eq(case, view(rows, "del"), new_lines, "new file = context + added")
  eq(case, view(rows, "add"), old_lines, "old file = context + removed")
  for line_no in pairs(stop.added) do
    if line_no < 1 or line_no > #new_lines then fail(case, "added line outside the file: " .. line_no) end
  end
  for _, block in ipairs(stop.removed) do
    if block.line < 1 or block.line > #new_lines then fail(case, "removed block anchored outside the file: " .. block.line) end
  end

  -- a sub-range keeps exactly the additions inside it, and never invents removed text
  if #new_lines >= 2 then
    local first = math.random(#new_lines)
    local last = math.random(first, #new_lines)
    local sub = stop_for(path, first, last)
    review.prepare(sub, root, "HEAD")
    local expected = {}
    for line_no in pairs(stop.added) do
      if line_no >= first and line_no <= last then expected[line_no] = true end
    end
    eq(case, sub.added, expected, ("sub-range %d-%d keeps the additions inside it"):format(first, last))
    local pool = {}
    for _, block in ipairs(stop.removed) do
      for _, text in ipairs(block.lines) do pool[text] = (pool[text] or 0) + 1 end
    end
    for _, block in ipairs(sub.removed) do
      for _, text in ipairs(block.lines) do
        pool[text] = (pool[text] or 0) - 1
        if pool[text] < 0 then fail(case, "sub-range invented removed text: " .. vim.inspect(text)) end
      end
    end
  end
  return stop, new_lines, old_lines
end

-- random pairs
local cases = tonumber(vim.env.DIFF_FUZZ_CASES) or 300
for n = 1, cases do
  local base = random_lines(math.random(0, 12))
  local new = mutate(base)
  local final_old, final_new = math.random() > 0.2, math.random() > 0.2
  -- an end-of-file newline alone is invisible in the editor, so it is not a change the review shows
  check_pair(("random#%d"):format(n), join(base, "\n", final_old), join(new, "\n", final_new),
    { oracle = final_old and final_new })
end

-- ---- directed edge cases ----------------------------------------------------------------------
local base6 = { "one", "two", "three", "four", "five", "six" }
check_pair("identical", join(base6, "\n", true), join(base6, "\n", true))
check_pair("only a trailing newline added", join(base6, "\n", false), join(base6, "\n", true), { oracle = false })
check_pair("only the trailing newline removed", join(base6, "\n", true), join(base6, "\n", false), { oracle = false })
check_pair("mixed line endings", "one\r\ntwo\nthree\r\nfour\n", "one\r\nTWO\nthree\r\nfour\n",
  { path = "mixedeol.txt", counts = { 1, 1 } })
check_pair("mixed line endings, CR line changed", "one\r\ntwo\nthree\r\nfour\n", "one\r\ntwo\nTHREE\r\nfour\n",
  { path = "mixedeol2.txt", counts = { 1, 1 } })
check_pair("all lines replaced", join(base6, "\n", true), join({ "u", "v", "w" }, "\n", true))
check_pair("emptied", join(base6, "\n", true), "")
check_pair("from empty", "", join(base6, "\n", true))
check_pair("blank line only", "a\n\nb\n", "a\n\n\nb\n")
check_pair("CRLF both sides", join(base6, "\r\n", true), join({ "one", "TWO", "three", "four", "five", "six" }, "\r\n", true), { path = "crlf.txt" })
check_pair("CRLF base, LF edit", join(base6, "\r\n", true), join({ "one", "two", "3", "four", "five", "six" }, "\n", true),
  { path = "mixed.txt", counts = { 1, 1 } })
check_pair("BOM", "\239\187\191" .. join(base6, "\n", true), "\239\187\191" .. join({ "one", "two", "3", "four", "five", "six" }, "\n", true),
  { path = "bom.txt", counts = { 1, 1 } })
check_pair("BOM, first line changed", "\239\187\191" .. join(base6, "\n", true), "\239\187\191" .. join({ "ONE", "two", "three", "four", "five", "six" }, "\n", true),
  { path = "bom2.txt", counts = { 1, 1 } })
check_pair("unicode", "héllo\nwörld\n日本語\n", "héllo\nwörld!\n日本語\n日本\n", { path = "uni.txt" })
check_pair("tabs and trailing spaces", "a\t\nb  \nc\n", "a\t\nb\nc  \n", { path = "ws.txt" })
check_pair("long line", string.rep("x", 5000) .. "\nend\n", string.rep("x", 5000) .. "y\nend\n", { path = "long.txt" })

-- renamed file: only the real change is shown, not the whole file as added
local big = {}
for i = 1, 12 do big[i] = "line number " .. i end
write("f.txt", table.concat(big, "\n") .. "\n")
commit("before rename")
git({ "mv", "f.txt", "renamed.txt" })
big[1] = "CHANGED"
write("renamed.txt", table.concat(big, "\n") .. "\n")
vim.cmd("silent! %bwipeout!")
local rename_stop = stop_for("renamed.txt", 1, #big)
review.prepare(rename_stop, root, "HEAD")
local added = vim.tbl_count(rename_stop.added)
checks = checks + 1
if added ~= 1 then
  fail("rename", ("a renamed file with one changed line shows %d added lines (the whole file reads as new)"):format(added))
end

-- an older base
write("g.txt", "1\n2\n3\n")
commit("g1")
write("g.txt", "1\n2\n3\n4\n")
commit("g2")
write("g.txt", "1\n2b\n3\n4\n")
local old_stop = stop_for("g.txt", 1, 4)
review.prepare(old_stop, root, "HEAD~1")
eq("base HEAD~1", vim.tbl_keys(old_stop.added), { 2, 4 }, "against an older base both changes show")

-- ---- several stops over one file ------------------------------------------------------------
-- A tour that cuts a file into consecutive stops must show every change exactly once: each
-- removed line belongs to one stop, and the additions of the stops add up to the file's.
local function partition(n)
  local cuts, ranges, at = {}, {}, 1
  for _ = 1, math.random(1, 4) do cuts[#cuts + 1] = math.random(1, n) end
  table.sort(cuts)
  for _, cut in ipairs(cuts) do
    if cut >= at then
      ranges[#ranges + 1] = { at, cut }
      at = cut + 1
    end
  end
  if at <= n then ranges[#ranges + 1] = { at, n } end
  return ranges
end
for n = 1, tonumber(vim.env.DIFF_FUZZ_PARTITIONS) or 300 do
  local case = ("partition#%d"):format(n)
  vim.cmd("silent! %bwipeout!")
  local base = random_lines(math.random(2, 12))
  local new = mutate(base)
  if #new < 2 then new = vim.list_extend(new, { "p", "q" }) end
  write("p.txt", join(base, "\n", true))
  commit(case)
  write("p.txt", join(new, "\n", true))
  local whole = stop_for("p.txt", 1, #new)
  review.prepare(whole, root, "HEAD")
  local expected_removed = {}
  for _, block in ipairs(whole.removed) do
    for _, text in ipairs(block.lines) do expected_removed[#expected_removed + 1] = text end
  end
  local got_removed, got_added = {}, {}
  local ranges = partition(#new)
  for _, range in ipairs(ranges) do
    local part = stop_for("p.txt", range[1], range[2])
    review.prepare(part, root, "HEAD")
    for _, block in ipairs(part.removed) do
      for _, text in ipairs(block.lines) do got_removed[#got_removed + 1] = text end
    end
    for line_no in pairs(part.added) do got_added[#got_added + 1] = line_no end
  end
  table.sort(got_added)
  local expected_added = vim.tbl_keys(whole.added)
  table.sort(expected_added)
  eq(case, got_added, expected_added, "the stops' additions add up to the file's " .. vim.inspect(ranges))
  -- A deletion between two stops is drawn by both neighbours (each reads it beside its own code), so
  -- a removed line may appear twice, but never zero times and never more than twice.
  local function tally(list)
    local out = {}
    for _, text in ipairs(list) do out[text] = (out[text] or 0) + 1 end
    return out
  end
  local have, want = tally(got_removed), tally(expected_removed)
  for text, count in pairs(want) do
    if (have[text] or 0) < count then
      fail(case, ("removed line %s is shown by no stop %s"):format(vim.inspect(text), vim.inspect(ranges)))
    elseif have[text] > 2 * count then
      fail(case, ("removed line %s is shown %d times for %d removals %s"):format(vim.inspect(text), have[text], count, vim.inspect(ranges)))
    end
  end
  for text in pairs(have) do
    if not want[text] then fail(case, "a stop invented removed text " .. vim.inspect(text)) end
  end
  checks = checks + 1
end

-- ---- a reader's question about part of a reviewed stop ---------------------------------------------
-- The reply's diff data replaces only its own range. After any number of such replies the stop must
-- still show exactly the whole file's changes: no addition lost, no removed line dropped or doubled.
local function removed_texts(stop)
  local out = {}
  for _, block in ipairs(stop.removed or {}) do vim.list_extend(out, block.lines) end
  table.sort(out)
  return out
end
for n = 1, tonumber(vim.env.DIFF_FUZZ_REPLIES) or 120 do
  local case = ("reply#%d"):format(n)
  vim.cmd("silent! %bwipeout!")
  local base = random_lines(math.random(3, 12))
  local new = mutate(base)
  while #new < 3 do new[#new + 1] = line() .. "+" end
  write("q.txt", join(base, "\n", true))
  commit(case)
  write("q.txt", join(new, "\n", true))
  local whole = stop_for("q.txt", 1, #new)
  review.prepare(whole, root, "HEAD")
  local trace = {}
  local ok, err = pcall(function()
    tour.show({ { file = "q.txt", start = 1, ["end"] = #new, note = "all" } }, { root = root })
    tour.review("HEAD")
    for _ = 1, 1 do
      local first = math.random(#new)
      local last = math.random(first, #new)
      local selection = require("code-tour.selection").capture(tour.state(), { start = first, ["end"] = last })
      local id = tour.explain_range(selection, "explain this part")
      -- the reply must cover the whole box it refines: the part before, the selection, the part after
      local cover = tour.state().pending[id].coverage or { start = first, ["end"] = last }
      local parts = {}
      if cover.start < first then parts[#parts + 1] = { cover.start, first - 1 } end
      parts[#parts + 1] = { first, last }
      if last < cover["end"] then parts[#parts + 1] = { last + 1, cover["end"] } end
      local reply = {}
      for _, range in ipairs(parts) do
        reply[#reply + 1] = { file = "q.txt", start = range[1], ["end"] = range[2], note = "part" }
      end
      trace[#trace + 1] = vim.inspect(parts)
      tour.fill(id, reply, { review = true, base = "HEAD" })
    end
    local stop = tour.state().stops[1]
    local added = vim.tbl_keys(stop.added)
    table.sort(added)
    local expected_added = vim.tbl_keys(whole.added)
    table.sort(expected_added)
    -- a false entry is a line a reply marked unchanged
    local real = {}
    for _, line_no in ipairs(added) do if stop.added[line_no] then real[#real + 1] = line_no end end
    eq(case, real, expected_added, "additions survive replies about sub-ranges")
    if not eq(case, removed_texts(stop), removed_texts(whole), "removed lines are neither lost nor doubled by replies") then
      failures[#failures] = failures[#failures] .. ("\n    base %s\n    new  %s\n    reply parts %s\n    whole removed %s\n    stop removed %s")
        :format(vim.inspect(base), vim.inspect(new), table.concat(trace, " "), vim.inspect(whole.removed), vim.inspect(stop.removed))
    end
    tour.stop()
  end)
  if not ok then fail(case, "reply raised: " .. tostring(err)) end
end

-- ---- explicit old text ------------------------------------------------------------------------
-- An agent may give the old text of a range itself (no Git). The same property holds for that range.
for n = 1, tonumber(vim.env.DIFF_FUZZ_EXPLICIT) or 150 do
  local case = ("explicit#%d"):format(n)
  vim.cmd("silent! %bwipeout!")
  local file = random_lines(math.random(3, 12))
  write("e.txt", join(file, "\n", true))
  local first = math.random(#file)
  local last = math.random(first, #file)
  local slice = vim.list_slice(file, first, last)
  local old_lines = mutate(slice)
  if #old_lines == 0 then old_lines = { "gone" } end
  local stop = stops.normalize({ { file = "e.txt", start = first, ["end"] = last, note = "n",
    old = join(old_lines, "\n", true) } }, root)[1]
  local ok, err = pcall(review.prepare, stop, root, "HEAD")
  if not ok then
    fail(case, "prepare raised: " .. tostring(err))
  else
    local rows = {}
    for i = first, last do
      for _, block in ipairs(stop.removed) do
        if block.line == i and block.above then
          for _, text in ipairs(block.lines) do rows[#rows + 1] = { kind = "del", text = text } end
        end
      end
      rows[#rows + 1] = { kind = stop.added[i] and "add" or "ctx", text = file[i] }
      for _, block in ipairs(stop.removed) do
        if block.line == i and not block.above then
          for _, text in ipairs(block.lines) do rows[#rows + 1] = { kind = "del", text = text } end
        end
      end
    end
    -- deletions after the range's last line hang above the next line, which is right after the range
    for _, block in ipairs(stop.removed) do
      if block.line == last + 1 and block.above then
        for _, text in ipairs(block.lines) do rows[#rows + 1] = { kind = "del", text = text } end
      end
    end
    local ok_new = eq(case, view(rows, "del"), slice, "explicit old: new range = context + added")
    local ok_old = eq(case, view(rows, "add"), old_lines, "explicit old: given old text = context + removed")
    if not (ok_new and ok_old) then
      failures[#failures] = failures[#failures] .. ("\n    range %d-%d added %s removed %s"):format(first, last,
        vim.inspect(stop.added), vim.inspect(stop.removed))
    end
  end
end

-- ---- what is drawn ----------------------------------------------------------------------------
local function drawn(case, old_lines, new_lines, stop)
  local buf = stop.buf
  local ns = vim.api.nvim_get_namespaces().CodeTourSource
  local above, below, groups = {}, {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local row, details = mark[2] + 1, mark[4]
    if details.hl_eol and details.hl_group then groups[row] = details.hl_group end
    if details.virt_lines then
      local texts = {}
      for _, virt in ipairs(details.virt_lines) do
        for _, chunk in ipairs(virt) do
          if chunk[1]:sub(1, #"− ") == "− " then texts[#texts + 1] = chunk[1]:sub(#"− " + 1) end
        end
      end
      if #texts > 0 then
        local into = details.virt_lines_above and above or below
        into[row] = vim.list_extend(into[row] or {}, texts)
      end
    end
  end
  local rows = {}
  for i = 1, #new_lines do
    for _, text in ipairs(above[i] or {}) do rows[#rows + 1] = { kind = "del", text = text } end
    local group = groups[i] or ""
    rows[#rows + 1] = { kind = group:match("^CodeTourDiffAdd") and "add" or "ctx", text = new_lines[i] }
    for _, text in ipairs(below[i] or {}) do rows[#rows + 1] = { kind = "del", text = text } end
  end
  eq(case, view(rows, "del"), new_lines, "drawn: new file = context + added highlights")
  eq(case, view(rows, "add"), old_lines, "drawn: old file = context + virtual removed lines")
end

local rendered = tonumber(vim.env.DIFF_FUZZ_RENDERED) or 60
for n = 1, rendered do
  local case = ("render#%d"):format(n)
  local base = random_lines(math.random(1, 12))
  local new = mutate(base)
  if #new == 0 then new = { "only" } end
  write("r.txt", join(base, "\n", true))
  commit(case)
  write("r.txt", join(new, "\n", true))
  vim.cmd("silent! %bwipeout!")
  local ok, err = pcall(function()
    tour.show({ { file = "r.txt", start = 1, ["end"] = #new, note = "all" } }, { root = root })
    tour.review("HEAD")
    tour.next_explanation(1)
    drawn(case, split(join(base, "\n", true)), new, tour.state().stops[1])
    tour.stop()
  end)
  if not ok then fail(case, "render raised: " .. tostring(err)) end
end

if #failures == 0 then
  print(("PASS: %d diff property checks over %d random pairs, %d rendered pairs and the directed edge cases"):format(checks, cases, rendered))
  vim.cmd("qa!")
else
  io.stderr:write(("FAILED: %d of %d checks\n"):format(#failures, checks))
  local shown = {}
  for i = 1, math.min(#failures, 12) do io.stderr:write("  " .. failures[i] .. "\n") end
  vim.cmd("cquit 1")
end
