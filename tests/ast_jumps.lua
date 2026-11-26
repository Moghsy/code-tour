-- Jumps (SPEC-ast-graph §8.3.1): route edges the code does not call, to symbols, types and
-- ranges (in another repository too, §14), and tours that start in an added range.
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

local function snippet(tour, label)
  for _, sn in ipairs(tour.snippets) do
    if sn.label == label then return sn end
  end
end

local function site(sn, text)
  for _, s in ipairs(sn.sites) do
    if s.text == text then return s end
  end
end

t.finish("ast jumps", function()
  if not t.parser() then
    return
  end
  local ast = require("code-tour.ast")
  local root = t.project()
  local opts = { root = root, cache_dir = t.cache }
  local function outline(entries, overrides, detail)
    return ast.outline(entries, vim.tbl_extend("force", opts, { overrides = overrides, detail = detail }))
  end
  local entry = { "OrderService#checkout" }
  local plain = outline(entry, {}).tour.snippets[1]

  -- a jump to a type: walked from its anchor, a site of its own, numbered after the calls
  local typed = outline(entry, {
    { kind = "route", jump = true, from = "OrderService#checkout", to = "Notifier", at = "notifier", line = 37, level = 0 },
  }).tour
  local n1 = typed.snippets[1]
  local jump = site(n1, "notifier")
  check(jump and jump.kind == "jump" and jump.mode == "walk", "a level-0 jump is walked")
  local ids = {}
  for _, s in ipairs(plain.sites) do ids[s.site] = true end -- one entry per target, so count ids
  eq(jump.site, "s" .. (vim.tbl_count(ids) + 1), "a jump is numbered after the method's calls")
  eq(snippet(typed, "Notifier").file, t.java .. "shop/notify/Notifier.java", "a jump to a type shows its declaration")
  eq(jump.region, site(n1, "notifier.send").region, "the anchor decides the box that offers the jump")
  local sends = vim.tbl_filter(function(s) return s.text == "notifier.send" end, n1.sites)
  eq(#sends, 2, "the real call keeps its own two targets")
  check(sends[1].target ~= jump.target, "and is not redirected to the jump's")
  for i, r in ipairs(plain.regions) do
    eq(typed.snippets[1].regions[i].lines, r.lines, "a jump does not change the regions: " .. r.id)
  end
  -- walk order: the jump comes before the calls written after its anchor
  local order = {}
  for _, s in ipairs(n1.sites) do order[#order + 1] = s.text end
  local at_jump, at_send
  for i, text in ipairs(order) do
    if text == "notifier" then at_jump = i elseif text == "notifier.send" then at_send = i end
  end
  check(at_jump < at_send, "the jump is walked at its anchor, before the call after it")
  local data = require("code-tour.ast.outline").text(outline(entry, {
    { kind = "route", jump = true, from = "OrderService#checkout", to = "Notifier", at = "notifier", line = 37, level = 0 },
  }).tour)
  check(data and true, "outline text renders")

  -- problems are warnings, never a broken tour
  local missing = outline(entry, {
    { kind = "route", jump = true, from = "OrderService#checkout", to = "Notifier", at = "nowhere", level = 0 },
  }).tour
  check(missing.warnings[1] and missing.warnings[1]:find('no "nowhere"', 1, true), "a missing anchor is a warning")
  eq(#missing.snippets, 1, "and adds nothing")

  -- a range in another repository: attached as @NAME, projected with an absolute path
  local web = vim.fn.tempname()
  vim.fn.mkdir(web .. "/src", "p")
  vim.fn.writefile({ "export async function checkout(order) {", "  const res = await fetch('/api');",
    "  return res.json();", "}" }, web .. "/src/api.js")
  t.run({ "git", "init", "-q" }, web)
  local range = { file = web .. "/src/api.js", start = 1, ["end"] = 4, label = "Web client" }
  local cross = outline(entry, {
    { kind = "route", jump = true, from = "OrderService#checkout", to = range, level = 0 },
  }).tour
  local client = snippet(cross, "Web client")
  check(client and client.file:match("^@[^/]+/src/api%.js$"), "another checkout's file reads @NAME/…: " .. tostring(client and client.file))
  eq(site(cross.snippets[1], "Web client").kind, "jump", "a range end is a jump")

  -- a tour can start in an added range and walk into the AST (was "no entry")
  local added = vim.json.encode({ file = web .. "/src/api.js", start = 1, ["end"] = 4, label = "Web client",
    sites = { { text = "fetch", line = 2, target = "OrderService#checkout" } } })
  local walked = outline({}, { { kind = "add", value = added }, { kind = "rate", value = "n1.s1=0" } }).tour
  eq(walked.snippets[1].label, "Web client", "an added entry is the tour's first snippet")
  eq(site(walked.snippets[1], "fetch").mode, "walk", "its declared call can be routed with --rate")
  eq(walked.snippets[2].label, "OrderService.checkout(Order)", "and walks into the AST")
  local from_range = outline({}, { { kind = "add", value = vim.json.encode(range) },
    { kind = "route", jump = true, from = range, to = "OrderService#checkout", at = "fetch", level = 0 } }).tour
  eq(from_range.snippets[2] and from_range.snippets[2].label, "OrderService.checkout(Order)",
    "a jump can leave from a range")

  -- a pinned range moves with its code, and stays (stale) when the code changes
  local idx = ast.index(opts)
  local rt = require("code-tour.ast.route").new(idx)
  local fallback = require("code-tour.ast.fallback")
  local spec = assert(fallback.normalize(idx, range))
  check(spec.repo and spec.repo.attached, "the spec records the checkout it came from")
  vim.fn.writefile({ "// header", "", "export async function checkout(order) {", "  const res = await fetch('/api');",
    "  return res.json();", "}" }, web .. "/src/api.js")
  assert(fallback.register(rt, spec))
  eq(idx:symbol(spec.id).range.start[1], 2, "lines inserted above: the range relocates")
  vim.fn.writefile({ "// header", "", "export async function checkout(order) {", "  const res = await fetch('/api');",
    "  return await res.json();", "}" }, web .. "/src/api.js")
  local fresh_idx = ast.index(opts)
  check(fallback.register(require("code-tour.ast.route").new(fresh_idx), spec), "a changed range is kept")
  eq(fresh_idx:symbol(spec.id).range.start[1], 2, "where most of its lines still are, under the same id")
end)
