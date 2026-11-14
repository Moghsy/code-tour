local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
-- Read installed parsers without writing to their data directory.
vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME or (vim.fn.expand("~/.local/share/nvim/site")))
local source = require("code-tour.source")
local checks, missing = 0, {}
local function check(v, message)
  assert(v, message)
  checks = checks + 1
end
local function buffer(lang, text)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = lang
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  return buf
end
local function set(buf, text)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
end
local function capture(buf, first, last)
  return assert(source.capture(buf, source.line_range(buf, first, last)))
end
local function available(language)
  local ok = pcall(vim.treesitter.language.add, language)
  if not ok then
    missing[#missing + 1] = language
    print("MISSING PARSER: " .. language)
  end
  return ok
end
if available("lua") then
  local original = "local function run(x)\n  -- keep this\n  local y = x + 1\n  return y\nend"
  local buf = buffer("lua", original)
  local overview, part = capture(buf, 1, 5), capture(buf, 3, 3)
  check(overview.evidence.status == "verified", "Lua syntax evidence")
  set(buf, "-- unrelated\nlocal function run( x )\n -- keep this\n local y=x+1\n return y\nend")
  local moved = assert(source.locate(buf, overview.locator))
  check(source.matches(overview.evidence, moved), "Formatting and relocation tolerate whitespace")
  local moved_part = assert(source.locate(buf, part.locator))
  check(source.matches(part.evidence, moved_part) and moved_part.range.start[1] == 3, "Part follows moved source")
  for _, change in ipairs({
    { "keep this", "change this" },
    { "x + 1", "x - 1" },
    { "x + 1", "z + 1" },
    {
      "x + 1",
      "x + 2",
    },
  }) do
    set(buf, (original:gsub(change[1]:gsub("%+", "%%+"), change[2])))
    local now = assert(source.locate(buf, overview.locator))
    check(not source.matches(overview.evidence, now), "Meaningful syntax/comment change invalidates")
  end
  set(buf, original:gsub("keep this", "edited comment"))
  check(
    source.matches(part.evidence, assert(source.locate(buf, part.locator))),
    "Independent unchanged part survives sibling change"
  )
  set(buf, original:gsub("x %+ 1", "x + 8"))
  local changed = assert(source.locate(buf, part.locator))
  check(not source.matches(part.evidence, changed), "Unique anchors locate changed part")
  check(changed.text:find("x + 8", 1, true), "Anchors select exact changed target")
  local dup = buffer("lua", "print(1)\nprint(1)")
  local one = capture(dup, 1, 1)
  set(dup, "-- shifted\nprint(1)\nprint(1)")
  local found, reason = source.locate(dup, one.locator)
  check(not found and reason.code == "ambiguous", "Duplicate code must not use nearest line")
  local repeated = buffer("lua", "local function f()\n a(0)\n target(1)\n b(0)\n a(0)\n target(2)\n b(0)\nend")
  local anchored = capture(repeated, 3, 3)
  set(repeated, "local function f()\n a(0)\n target(3)\n b(0)\n a(0)\n target(4)\n b(0)\nend")
  local ambiguous, ambiguity = source.locate(repeated, anchored.locator)
  check(not ambiguous and ambiguity.code == "ambiguous", "Repeated anchors do not guess a changed target")
  local deleted = buffer("lua", "local function f()\n a(0)\n target(1)\n b(0)\nend")
  local deleted_capture = capture(deleted, 3, 3)
  set(deleted, "local function f()\n a(0)\n b(0)\nend")
  check(not source.locate(deleted, deleted_capture.locator), "Deleted target does not become an empty source stop")
  local owners = buffer("lua", "local function f() return 1 end\nlocal function f() return 1 end")
  local owner_capture = capture(owners, 1, 1)
  set(owners, "-- moved\nlocal function f() return 1 end\nlocal function f() return 1 end")
  check(not source.locate(owners, owner_capture.locator), "Duplicate named owners remain unresolved")
  local joined = buffer("lua", "local a = 1\nlocal b = 2")
  local a, b = capture(joined, 1, 1), capture(joined, 2, 2)
  set(joined, "local a=1 local b=2")
  local aa, bb = assert(source.locate(joined, a.locator)), assert(source.locate(joined, b.locator))
  check(source.matches(a.evidence, aa) and source.matches(b.evidence, bb), "Line joining preserves independent syntax")
  check(
    aa.range["end"][2] <= bb.range.start[2] and aa.range.start[1] == bb.range.start[1],
    "Joined ranges remain byte-distinct"
  )
  local comment = buffer("lua", "-- just a comment\nlocal x = 1")
  local comment_capture = capture(comment, 1, 1)
  check(comment_capture.evidence.status == "verified", "Comment-only selection is syntax")
  local partial = assert(source.capture(comment, { start = { 1, 1 }, ["end"] = { 1, 2 } }))
  check(partial.evidence.status == "unverified", "Partial token is not reusable")
  local evidence = vim.deepcopy(a.evidence)
  evidence.parser_tag = "other-parser"
  check(not source.matches(evidence, aa), "Parser compatibility is required")
  local malformed = buffer("lua", "local ok = 1\nlocal broken = (")
  check(capture(malformed, 1, 1).evidence.status == "verified", "Error elsewhere does not invalidate path")
  local literal = buffer("lua", 'local s = "a b"')
  local old = capture(literal, 1, 1)
  set(literal, 'local s = "a  b"')
  check(not source.matches(old.evidence, capture(literal, 1, 1)), "Literal whitespace is meaningful")
  local leading = buffer("lua", "-- docs\nlocal function f()\n return 1\nend")
  local docs = capture(leading, 1, 4)
  set(leading, "-- shift\n-- docs\nlocal function f()\n return 2\nend")
  local relocated = source.locate(leading, docs.locator)
  check(relocated and relocated.text:find("-- docs", 1, true), "Selected leading comments retained")
end
if available("python") then
  local buf = buffer("python", "def f(x):\n    if x:\n        print(x)\n    return x")
  local before = capture(buf, 3, 3)
  set(buf, "def f(x):\n    if x:\n        pass\n    print(x)\n    return x")
  check(not source.matches(before.evidence, capture(buf, 4, 4)), "Python structural indentation remains meaningful")
end
if available("javascript") then
  local buf = buffer("javascript", "function f() {\n return 1;\n}")
  local before = capture(buf, 2, 2)
  set(buf, "function f() {\n return\n 1;\n}")
  check(not source.matches(before.evidence, capture(buf, 2, 3)), "JavaScript semantic newline remains meaningful")
end
local unsupported = buffer("no_such_language", "some code")
local raw = capture(unsupported, 1, 1)
check(raw.evidence.status == "unverified", "Unsupported parser is explicit")
check(source.locate(unsupported, raw.locator) ~= nil, "Raw unchanged file establishes exact location")
set(unsupported, "changed code")
check(source.locate(unsupported, raw.locator) == nil, "Changed unsupported source requires reassociation")
print(("PASS: %d source checks; missing parsers: %s"):format(checks, table.concat(missing, ", ")))
