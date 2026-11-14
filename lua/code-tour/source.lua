-- Source identity and relocation. All coordinates here are byte-based, end exclusive.
local M = { scheme = "ts-scoped-leaves-v1" }
local cache = {}
vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(args)
    cache[args.buf] = nil
  end,
})
local function digest(value)
  return vim.fn.sha256(value)
end
local function stable(value)
  if type(value) ~= "table" then
    return vim.json.encode(value)
  end
  if vim.islist(value) then
    local out = {}
    for _, v in ipairs(value) do
      out[#out + 1] = stable(v)
    end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys, out = vim.tbl_keys(value), {}
  table.sort(keys)
  for _, k in ipairs(keys) do
    out[#out + 1] = vim.json.encode(k) .. ":" .. stable(value[k])
  end
  return "{" .. table.concat(out, ",") .. "}"
end
local function le(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end
local function eq(a, b)
  return a[1] == b[1] and a[2] == b[2]
end
local function contains(a, b)
  return le(a.start, b.start) and le(b["end"], a["end"])
end
M.contains = contains
local function node_range(n)
  local a, b, c, d = n:range()
  return { start = { a, b }, ["end"] = { c, d } }
end
function M.line_range(buf, first, last)
  local line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1]
  return { start = { first - 1, 0 }, ["end"] = { last - 1, #(line or "") } }
end
function M.lines(range)
  return range.start[1] + 1, range["end"][1] + (range["end"][2] == 0 and range["end"][1] > range.start[1] and 0 or 1)
end
function M.valid_range(buf, r)
  if type(r) ~= "table" or type(r.start) ~= "table" or type(r["end"]) ~= "table" then
    return false
  end
  local count = vim.api.nvim_buf_line_count(buf)
  for _, p in ipairs({ r.start, r["end"] }) do
    if #p ~= 2 then
      return false
    end
    for _, n in ipairs(p) do
      if type(n) ~= "number" or n < 0 or n ~= math.floor(n) then
        return false
      end
    end
    if p[1] >= count then
      if not (p == r["end"] and p[1] == count and p[2] == 0) then
        return false
      end
    elseif p[2] > #(vim.api.nvim_buf_get_lines(buf, p[1], p[1] + 1, false)[1] or "") then
      return false
    end
  end
  return le(r.start, r["end"]) and not eq(r.start, r["end"])
end
function M.text(buf, r)
  assert(M.valid_range(buf, r), "Invalid byte range")
  local row, col, suffix = r["end"][1], r["end"][2], ""
  if row == vim.api.nvim_buf_line_count(buf) then
    row, suffix = row - 1, "\n"
    col = #(vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or "")
  end
  return table.concat(vim.api.nvim_buf_get_text(buf, r.start[1], r.start[2], row, col, {}), "\n") .. suffix
end
function M.snapshot(buf)
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    return nil, { code = "buffer", reason = "Source buffer is closed or unloaded" }
  end
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local language = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
  if not language then
    local ft = vim.filetype.match({ buf = buf })
    language = ft and (vim.treesitter.language.get_lang(ft) or ft)
  end
  local ok, inspection = pcall(vim.treesitter.language.inspect, language or "")
  local tag = ok and digest(stable(inspection)) or nil
  local old = cache[buf]
  if old and old.tick == tick and old.language == language and old.parser_tag == tag then
    return old
  end
  local raw = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local snap = {
    buf = buf,
    tick = tick,
    file_digest = digest(raw),
    language = language,
    parser_tag = tag,
    leaves = {},
    owners = {},
    errors = {},
  }
  cache[buf] = snap
  if not tag then
    snap.reason = "No usable Tree-sitter parser for " .. tostring(language)
    return snap
  end
  local parsed, err = pcall(function()
    local parser = vim.treesitter.get_parser(buf, language)
    local root = parser:parse()[1]:root()
    snap.scope = node_range(root)
    local function walk(n, path, chain, bad)
      bad = bad or n:type() == "ERROR" or n:missing()
      if n:missing() then
        snap.errors[#snap.errors + 1] = node_range(n)
      end
      local names = n:field("name")
      if #names > 0 then
        chain = vim.deepcopy(chain)
        chain[#chain + 1] = { type = n:type(), name = vim.treesitter.get_node_text(names[1], buf) }
        snap.owners[#snap.owners + 1] = { chain = chain, range = node_range(n), bad = bad }
      end
      if n:child_count() == 0 then
        local r = node_range(n)
        if not eq(r.start, r["end"]) then
          local value = { n:type(), vim.treesitter.get_node_text(n, buf), path }
          snap.leaves[#snap.leaves + 1] = { range = r, value = value, sig = digest(stable(value)), bad = bad }
        end
      else
        for child, field in n:iter_children() do
          local child_path = vim.deepcopy(path)
          child_path[#child_path + 1] = { child:type(), field or "" }
          walk(child, child_path, chain, bad)
        end
      end
    end
    walk(root, { { root:type(), "" } }, {}, false)
  end)
  if not parsed then
    snap.reason = "Source parse failed: " .. tostring(err)
    snap.leaves = {}
  end
  return snap
end
local function stream_digest(snap, first, last)
  local values = {}
  for i = first, last do
    values[#values + 1] = snap.leaves[i].value
  end
  return digest(stable({ M.scheme, snap.language, snap.parser_tag, values }))
end
local function indices(snap, range)
  for _, err in ipairs(snap.errors) do
    if le(range.start, err.start) and le(err["end"], range["end"]) then
      return nil, nil, "Missing syntax on selected path"
    end
  end
  local first, last
  for i, leaf in ipairs(snap.leaves) do
    if le(range.start, leaf.range.start) and le(leaf.range["end"], range["end"]) then
      if leaf.bad then
        return nil, nil, "Syntax error on selected path"
      end
      first, last = first or i, i
    elseif not le(leaf.range["end"], range.start) and not le(range["end"], leaf.range.start) then
      return nil, nil, "Selection cuts a syntax token"
    end
  end
  if not first then
    return nil, nil, "Empty or unsupported syntax range"
  end
  return first, last
end
local function anchors(snap, first, last, scope)
  local before, after = {}, {}
  for i = math.max(1, first - 4), first - 1 do
    if contains(scope, snap.leaves[i].range) then
      before[#before + 1] = snap.leaves[i].sig
    end
  end
  for i = last + 1, math.min(#snap.leaves, last + 4) do
    if contains(scope, snap.leaves[i].range) then
      after[#after + 1] = snap.leaves[i].sig
    end
  end
  return before, after
end
function M.capture(buf, range)
  local snap, err = M.snapshot(buf)
  if not snap then
    return nil, err
  end
  if not M.valid_range(buf, range) then
    return nil, { code = "range", reason = "Invalid or empty byte range" }
  end
  local result = {
    buf = buf,
    path = vim.fs.normalize(vim.api.nvim_buf_get_name(buf)),
    range = vim.deepcopy(range),
    text = M.text(buf, range),
    tick = snap.tick,
    file_digest = snap.file_digest,
    evidence = { status = "unverified", reason = snap.reason or "Unsupported source" },
  }
  local locator = {
    file_digest = snap.file_digest,
    range = vim.deepcopy(range),
    owners = {},
    scope_path = {},
    whole_owner = false,
    leaf_count = 0,
    before = {},
    after = {},
  }
  result.locator = locator
  if snap.reason then
    return result
  end
  local first, last, reason = indices(snap, range)
  if not first then
    result.evidence.reason = reason
    return result
  end
  local owner
  for _, candidate in ipairs(snap.owners) do
    if
      contains(candidate.range, { start = snap.leaves[first].range.start, ["end"] = snap.leaves[last].range["end"] })
      and (not owner or #candidate.chain > #owner.chain)
    then
      owner = candidate
    end
  end
  -- Leading comments selected directly alongside a whole named declaration.
  if not owner then
    for _, candidate in ipairs(snap.owners) do
      if contains(range, candidate.range) and eq(candidate.range["end"], snap.leaves[last].range["end"]) then
        local comments = true
        for i = first, last do
          if
            le(snap.leaves[i].range["end"], candidate.range.start) and not snap.leaves[i].value[1]:match("comment")
          then
            comments = false
          end
        end
        if comments and (not owner or #candidate.chain < #owner.chain) then
          owner = candidate
        end
      end
    end
  end
  local scope = owner and owner.range or snap.scope
  locator.owners = owner and vim.deepcopy(owner.chain) or {}
  locator.scope_path = vim.deepcopy(snap.leaves[first].value[3])
  local ofirst, olast = indices(snap, scope)
  locator.whole_owner = owner ~= nil and ofirst ~= nil and first <= ofirst and last == olast
  locator.leading_comments = locator.whole_owner and ofirst - first or 0
  locator.leaf_count = last - first + 1
  locator.target_digest = stream_digest(snap, first, last)
  locator.boundary = { snap.leaves[first].sig, snap.leaves[last].sig }
  locator.before, locator.after = anchors(snap, first, last, scope)
  result.evidence = {
    status = "verified",
    scheme = M.scheme,
    language = snap.language,
    parser_tag = snap.parser_tag,
    digest = locator.target_digest,
  }
  return result
end
function M.matches(evidence, capture)
  local now = capture and capture.evidence
  return evidence
      and now
      and evidence.status == "verified"
      and now.status == "verified"
      and evidence.scheme == now.scheme
      and evidence.language == now.language
      and evidence.parser_tag == now.parser_tag
      and evidence.digest == now.digest
    or false
end
local function issue(code, reason)
  return nil, { code = code, reason = reason }
end
function M.locate(buf, locator)
  local snap, err = M.snapshot(buf)
  if not snap then
    return nil, err
  end
  if snap.file_digest == locator.file_digest then
    return M.capture(buf, locator.range)
  end
  if snap.reason or not locator.target_digest then
    return issue("unsupported", snap.reason or "No supported locator; reassociate source")
  end
  local scope, owner
  if #locator.owners > 0 then
    for _, candidate in ipairs(snap.owners) do
      if stable(candidate.chain) == stable(locator.owners) then
        if owner then
          return issue("ambiguous", "Several matching named owners")
        end
        owner = candidate
      end
    end
    if not owner or owner.bad then
      return issue("owner", "Named owner missing or invalid; reassociate source")
    end
    scope = owner.range
  else
    scope = snap.scope
  end
  local first, last = indices(snap, scope)
  if not first then
    return issue("syntax", "Scope cannot be parsed")
  end
  -- A whole owner tracks its extent even after its implementation changes.
  if locator.whole_owner and owner then
    local begin = first - (locator.leading_comments or 0)
    if begin < 1 then
      return issue("comments", "Leading comments missing")
    end
    for i = begin, first - 1 do
      if not snap.leaves[i].value[1]:match("comment") then
        return issue("comments", "Leading comments missing")
      end
    end
    return M.capture(buf, { start = snap.leaves[begin].range.start, ["end"] = scope["end"] })
  end
  local found
  for i = first, last - locator.leaf_count + 1 do
    local j = i + locator.leaf_count - 1
    local boundary = locator.boundary
    if
      (not boundary or (snap.leaves[i].sig == boundary[1] and snap.leaves[j].sig == boundary[2]))
      and stream_digest(snap, i, j) == locator.target_digest
    then
      if found then
        return issue("ambiguous", "Duplicate matching source")
      end
      found = { start = snap.leaves[i].range.start, ["end"] = snap.leaves[j].range["end"] }
    end
  end
  if found then
    return M.capture(buf, found)
  end
  local starts, ends = {}, {}
  for boundary = first, last + 1 do
    local before_ok, after_ok = true, true
    local before, after = locator.before or {}, locator.after or {}
    if #before == 0 then
      before_ok = boundary == first
    else
      for k = 1, #before do
        local leaf = snap.leaves[boundary - #before + k - 1]
        if boundary - #before < first or not leaf or leaf.sig ~= before[k] then
          before_ok = false
          break
        end
      end
    end
    if #after == 0 then
      after_ok = boundary == last + 1
    else
      for k = 1, #after do
        local leaf = snap.leaves[boundary + k - 1]
        if boundary + #after - 1 > last or not leaf or leaf.sig ~= after[k] then
          after_ok = false
          break
        end
      end
    end
    if before_ok then
      starts[#starts + 1] = boundary
    end
    if after_ok then
      ends[#ends + 1] = boundary
    end
  end
  local pair
  for _, a in ipairs(starts) do
    for _, b in ipairs(ends) do
      if a < b then
        if pair then
          return issue("ambiguous", "Several boundary anchor pairs")
        end
        pair = { a, b - 1 }
      end
    end
  end
  if not pair then
    return issue("missing", "Source deleted or anchors unusable; reassociate source")
  end
  return M.capture(buf, { start = snap.leaves[pair[1]].range.start, ["end"] = snap.leaves[pair[2]].range["end"] })
end
return M
