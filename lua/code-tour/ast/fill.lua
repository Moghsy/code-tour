-- Fills for AST snippets (SPEC-ast-graph §9.3–9.4): the agent's notes, one section per
-- box, parsed and written to the note store (§3.5, §11.1).
--
--   fill.parse(payload, default_n) -> { {n, box, gist, body?, heading} … }
--   fill.apply(live, n, payload, opts) -> result      (live:fill delegates here)
--
-- Markdown (§9.3): `## overview`, `## r2`, `## n1 r2`, `## n1 overview` or `## n1` (n1's
-- overview) start a section; the first paragraph of a section is the gist, the rest the
-- body. Only level-2 headings outside fenced code start sections, so a body may carry
-- `###` headings and code blocks. JSON: `{"r2": {"gist": …, "body": …}}`, keys shaped like
-- the headings; a string value is a section's text, split the same way.
--
-- Errors are raised with error(msg, 0) so the CLI prints them without a Lua position.
local notes = require("code-tour.ast.notes")

local M = {}

M.refused = "Source changed; rebuild with code-tour ast"

local function trim(text)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function fail(msg)
  error(msg, 0)
end

-- A heading or JSON key -> n (or nil: the fill's own snippet), box. nil when its shape
-- is not one of §9.3's.
local function address_of(text)
  local edge = text:match("^edge%s+(.+)$")
  if edge then
    local n, site = edge:match("^(n%d+)%.(s%d+)$")
    local target
    if not site then
      n, site, target = edge:match("^(n%d+)%.(s%d+)>(.+)$")
    end
    if not site then
      site = edge:match("^(s%d+)$")
    end
    if not site then
      site, target = edge:match("^(s%d+)>(.+)$")
    end
    return n, site and ("edge " .. site .. (target and (">" .. target) or "")) or nil
  end
  local words = vim.split(trim(text), "%s+", { trimempty = true })
  local function box(w)
    if w == "overview" or w:match("^r%d+$") then
      return w
    end
  end
  if #words == 1 then
    if words[1]:match("^n%d+$") then
      return words[1], "overview"
    end
    local b = box(words[1])
    if b then
      return nil, b
    end
  elseif #words == 2 and words[1]:match("^n%d+$") then
    local b = box(words[2])
    if b then
      return words[1], b
    end
  end
end

local shapes = "`## overview`, `## r2`, `## n1 r2`, `## n1 overview` or `## n1`"

-- §9.3: the first paragraph is the gist (its lines joined), the rest the body.
function M.split(text)
  local lines = vim.split(trim(text), "\n", { plain = true })
  local gist, k = {}, 1
  while lines[k] and lines[k]:find("%S") do
    gist[#gist + 1] = trim(lines[k])
    k = k + 1
  end
  local body = trim(table.concat(lines, "\n", k))
  return table.concat(gist, " "), body ~= "" and body or nil
end

local function section(list, default_n, heading, n, box, gist, body, example)
  n = n or default_n
  if not n then
    fail(("Section `%s` names no snippet: write `## nK %s`"):format(heading, box))
  end
  if not gist or not gist:find("%S") then
    fail(("Empty section `%s`: write its gist (the first paragraph), then its body"):format(heading))
  end
  list[#list + 1] = { n = n, box = box, gist = gist, body = body, example = example, heading = heading }
end

-- A repeated section in one payload: the later wins (§9.3, "a later one replaces the
-- earlier"), and it keeps the first one's place in the list.
local function dedupe(list)
  local out, at = {}, {}
  for _, s in ipairs(list) do
    local key = s.n .. " " .. s.box
    if at[key] then
      out[at[key]] = s
    else
      out[#out + 1] = s
      at[key] = #out
    end
  end
  return out
end

local function parse_markdown(text, default_n, resolve_heading)
  local list = {}
  local cur
  local fence
  local before = {}
  local function finish()
    local gist, body = M.split(table.concat(cur.lines, "\n"))
    local example
    if cur.example then
      local content = trim(table.concat(cur.example.lines, "\n"))
      if content == "" then
        fail(("Empty example for section %q"):format(cur.heading))
      end
      example = { text = content, source = cur.example.source }
    end
    section(list, default_n, cur.heading, cur.n, cur.box, gist, body, example)
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local heading = not fence and line:match("^##%s+(.-)%s*$")
    if heading and not line:match("^###") then
      if cur then
        finish()
      end
      local n, box
      if resolve_heading then
        n, box = resolve_heading(heading)
      end
      if not box then
        n, box = address_of(heading)
      end
      if not box then
        fail(("Unknown section heading `## %s`: use %s"):format(heading, shapes))
      end
      cur = { heading = heading, n = n, box = box, lines = {} }
    else
      local mark = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
      if mark then
        if not fence then
          fence = mark
        elseif mark:sub(1, 1) == fence:sub(1, 1) and #mark >= #fence then
          fence = nil
        end
      end
      local kind = cur and not fence and line:match("^### Example %((%a+)%)%s*$")
      if kind == "generated" or kind == "test" or kind == "recorded" then
        if cur.example then
          fail(("Section %q has more than one standard example"):format(cur.heading))
        end
        cur.example = { source = kind, lines = {} }
      elseif cur then
        local lines = cur.example and cur.example.lines or cur.lines
        lines[#lines + 1] = line
      else
        before[#before + 1] = line
      end
    end
  end
  if trim(table.concat(before, "\n")) ~= "" then
    fail("Text before the first section: start every box with a heading (" .. shapes .. ")")
  end
  if cur then
    finish()
  end
  if #list == 0 then
    fail("Empty fill: write one `## <box>` section per box (" .. shapes .. ")")
  end
  return dedupe(list)
end

-- JSON object keys arrive unordered, so there is no "later" between `r2` and `n1 r2`
-- in one object: naming a box twice there is an error.
local function parse_json(payload, default_n)
  local keys = vim.tbl_keys(payload)
  if #keys == 0 then
    fail("Empty fill: give one key per box, e.g. {\"r2\": {\"gist\": …, \"body\": …}}")
  end
  for _, k in ipairs(keys) do
    if type(k) ~= "string" then
      fail("A JSON fill is an object keyed by box (\"overview\", \"r2\", \"n1 r2\"), not a list")
    end
  end
  local parsed = {}
  for _, k in ipairs(keys) do
    local n, box = address_of(k)
    if not box then
      fail(("Unknown box key %q: use \"overview\", \"r2\", \"n1 r2\", \"n1 overview\" or \"n1\""):format(k))
    end
    local order = tonumber(box:match("^r(%d+)$")) or (box == "overview" and 0 or 100000)
    parsed[#parsed + 1] = { key = k, n = n or default_n, box = box,
      order = tonumber((n or default_n or "n0"):sub(2)) * 1e6 + order }
  end
  -- walk the boxes in a stable order: by snippet, overview first, then regions
  table.sort(parsed, function(a, b)
    if a.order ~= b.order then
      return a.order < b.order
    end
    return a.key < b.key
  end)
  local list, seen = {}, {}
  for _, p in ipairs(parsed) do
    local value = payload[p.key]
    local gist, body, example
    if type(value) == "string" then
      gist, body = M.split(value)
    elseif type(value) == "table" then
      gist, body = value.gist, value.body
      if gist ~= nil and type(gist) ~= "string" then
        fail(("Box %q: gist must be a string"):format(p.key))
      end
      if body == vim.NIL or (type(body) == "string" and not body:find("%S")) then
        body = nil
      elseif body ~= nil and type(body) ~= "string" then
        fail(("Box %q: body must be a string"):format(p.key))
      end
      gist = gist and trim(gist)
      body = body and trim(body)
      example = value.example ~= vim.NIL and value.example or nil
      if example then
        if type(example) ~= "table" or type(example.text) ~= "string" or not example.text:find("%S")
            or (example.source ~= "generated" and example.source ~= "test" and example.source ~= "recorded")
            or (example.test ~= nil and type(example.test) ~= "string") then
          fail(("Box %q: example needs text and a source (generated, test, recorded)"):format(p.key))
        end
        example = { text = trim(example.text), source = example.source, test = example.test }
      end
      if p.box:match("^edge ") then
        gist = gist or value.text
      end
    else
      fail(("Box %q: give {\"gist\": …, \"body\": …} or the section text"):format(p.key))
    end
    section(list, default_n, p.key, p.n, p.box, gist, body, example)
    local key = list[#list].n .. " " .. p.box
    if seen[key] then
      fail(("Box %s is named twice in one JSON fill (%q and %q)"):format(key, seen[key], p.key))
    end
    seen[key] = p.key
  end
  return list
end

-- Parse a fill into sections. payload: Markdown text, or a decoded JSON object.
-- default_n is the fill's snippet id, used for sections that name none.
function M.parse(payload, default_n, resolve_heading)
  if type(payload) == "string" then
    local text = payload
    if text:match("^%s*{") then
      local ok, decoded = pcall(vim.json.decode, text)
      if not ok or type(decoded) ~= "table" then
        fail("Fill starts with `{` but is not a JSON object: " .. tostring(decoded))
      end
      return parse_json(decoded, default_n)
    end
    return parse_markdown(text, default_n, resolve_heading)
  elseif type(payload) == "table" then
    if vim.islist(payload) and #payload > 0 then
      fail("An AST fill is Markdown or a JSON object keyed by box, not a list of stops")
    end
    return parse_json(payload, default_n)
  end
  fail("Empty fill: write Markdown sections (" .. shapes .. ")")
end

-- The boxes of a snippet at a detail: { id -> {address, fingerprint} } and the ids in
-- order. At the tour's detail they are the snippet's own boxes, with the fingerprints
-- the tour looks notes up by; at another detail the snippet's regions are selected at
-- that detail from the same rated node (§7: nested boundaries, so unsplit regions keep
-- their address) and fingerprinted against current code.
local function boxes_at(live, sn, detail)
  local map = { overview = { address = sn.symbol, fingerprint = sn._fps and sn._fps[sn.symbol] } }
  local ids = { "overview" }
  local list = sn.regions
  local current = detail == live.detail
  if not current then
    local other = require("code-tour.ast.outline").snippet(live.prep, sn._node, sn.n, {}, detail)
    list = other.regions
  end
  local buf
  for _, r in ipairs(list) do
    local fp = current and sn._fps and sn._fps[r.address]
    if not fp then
      buf = buf or live:buf(sn.file)
      fp = notes.fingerprint(buf, r._range)
    end
    map[r.id] = { address = r.address, fingerprint = fp, region = r }
    ids[#ids + 1] = r.id
  end
  if not map.overview.fingerprint then
    local sym = live.idx:symbol(sn.symbol)
    map.overview.fingerprint = notes.fingerprint(live:buf(sn.file), sym.range)
  end
  return map, ids
end

local function edge_at(live, sn, key)
  local site_id = key:match("^edge (s%d+)")
  local target = key:match(">(.*)$")
  local site
  for _, candidate in ipairs(sn.sites) do
    if candidate.site == site_id and candidate.target and (not target or target == candidate.target) then
      if site then
        fail(("Ambiguous edge %s.%s: write %s.%s>SYMBOL"):format(sn.n, site_id, sn.n, site_id))
      end
      site = candidate
    end
  end
  if not site then
    fail(("No resolved edge %s.%s"):format(sn.n, site_id))
  end
  local caller, occurrence, caller_fp = live:edge_context(sn, site)
  local target_fp = live:root_fingerprint(site.target)
  if not target_fp then
    fail(("No project source for edge %s.%s → %s"):format(sn.n, site_id, site.target))
  end
  return { caller = caller, target = site.target, occurrence = occurrence, caller_fingerprint = caller_fp,
    target_fingerprint = target_fp, file = sn.file }
end

-- §9.3–9.4: validate a whole fill, then write its sections to the store. opts: {detail?,
-- model?}; detail defaults to the tour's. A snippet whose source changed since its
-- skeleton was built is refused and its sections dropped, while the other snippets of
-- the same fill are still written; a fill whose every section is refused is an error.
-- Returns { filled = n, boxes = {"n1 overview", "n1 r2", …} (written), count,
--   ready = {[nK] = bool} (every box fresh at the tour's detail), remaining = {"n1 r3", …}
--   (boxes of the written snippets still to write at the tour's detail),
--   refused = {{n, reason}}? }.
function M.apply(live, n, payload, opts)
  opts = opts or {}
  local detail = opts.detail or live.detail
  if detail == vim.NIL then
    detail = live.detail
  end
  if not notes.rank[detail] then
    fail("Unknown detail " .. tostring(detail) .. " (overview, normal, detailed, exhaustive)")
  end
  local model = opts.model ~= vim.NIL and opts.model or nil
  local sections = M.parse(payload, n)

  -- validate everything before writing anything
  local by_n, order = {}, {}
  for _, s in ipairs(sections) do
    if not by_n[s.n] then
      local sn = live.snippets[s.n]
      if not sn then
        local known = vim.tbl_keys(live.snippets)
        table.sort(known, function(a, b)
          return tonumber(a:sub(2)) < tonumber(b:sub(2))
        end)
        fail(("Unknown snippet %s (this tour has %s)"):format(s.n, table.concat(known, " ")))
      end
      local map, ids = boxes_at(live, sn, detail)
      by_n[s.n] = { sn = sn, map = map, ids = ids, sections = {}, changed = live:source_changed(sn) }
      order[#order + 1] = s.n
    end
    local g = by_n[s.n]
    if s.box:match("^edge ") then
      s.edge = edge_at(live, g.sn, s.box)
    elseif not g.map[s.box] then
      fail(("Unknown box %s %s at %s detail (%s has %s)"):format(s.n, s.box, detail, s.n, table.concat(g.ids, " ")))
    end
    g.sections[#g.sections + 1] = s
  end
  local refused = {}
  for _, k in ipairs(order) do
    if by_n[k].changed then
      refused[#refused + 1] = { n = k, reason = M.refused }
    end
  end
  if #refused == #order then
    local ids = {}
    for _, r in ipairs(refused) do
      ids[#ids + 1] = r.n
    end
    fail(("%s (%s)"):format(M.refused, table.concat(ids, " ")))
  end

  -- write
  local result = { filled = n, boxes = {}, ready = {}, remaining = {}, count = 0 }
  for _, k in ipairs(order) do
    local g = by_n[k]
    if not g.changed then
      for _, s in ipairs(g.sections) do
        local edge = s.edge
        if edge then
          edge.text = s.gist .. (s.body and ("\n\n" .. s.body) or "")
          live.store:put_edge(edge.caller, edge.target, edge.occurrence, edge)
          result.edges = result.edges or {}
          result.edges[#result.edges + 1] = k .. " " .. s.box
        else
          local box = g.map[s.box]
          local note = live:box_context(g.sn, box.region)
          note.fingerprint, note.gist, note.body = box.fingerprint, s.gist, s.body
          note.detail, note.model, note.example = detail, model, s.example
          note.callees = live:callees(g.sn, box.region)
          live.store:put(box.address, note)
          result.boxes[#result.boxes + 1] = k .. " " .. s.box
        end
      end
      -- §9.4: a snippet is ready when all its boxes are (at the tour's detail)
      local left = live:to_write(g.sn)
      result.ready[k] = #left == 0
      for _, b in ipairs(left) do
        result.remaining[#result.remaining + 1] = k .. " " .. b.id
      end
    end
  end
  if result.edges then
    live:apply_edge_notes()
  end
  result.count = #result.boxes
  if #refused > 0 then
    result.refused = refused
  end
  return result
end

return M
