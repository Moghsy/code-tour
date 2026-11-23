-- AST-backed code representation (SPEC-ast-graph.md). Phase 1: extraction, the
-- project index, resolution and the graphify-compatible export. Phase 2: regions (§7),
-- the route (§8) and the outline as a dry run.
local M = {}
local parser_available = require("code-tour.ast.index").parser_available

M.defaults = {
  enabled = true,
  models = {},
  examples = { tests = true, record = "ask" },
  record_timeout_ms = 30000,
  store = "repo",
  store_versions = 3,
  store_ttl_days = 180,
  languages = { "java" },
  ignore = {},
  max_files = 5000,
  detail = "normal",
  cutoffs = nil, -- the table in §8.6 (route.defaults.cutoffs)
  main_cap = 40,
  -- Cross-boundary edges: { { call = "AWSLambda.invoke", to = "OrderHandler#handleRequest" } }
  boundaries = {},
  -- Generated members: { java = { MyAnnotation = function(type, api) return { specs } end } } (ast/synth.lua)
  synthesizers = {},
}
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

local function backend_for(path, languages)
  local ext = path:match("(%.[^./]+)$")
  for _, name in ipairs(languages or M.options.languages) do
    local ok, backend = pcall(require, "code-tour.ast.lang." .. name)
    if ok then
      for _, e in ipairs(backend.extensions) do
        if e == ext then
          return backend
        end
      end
    end
  end
end

-- §4.1: a backend claims the extension, its parser loads, and the requested symbol
-- (a symbol id, or nil for the whole file) parses without an ERROR node inside it.
-- Returns ok, reason.
function M.available(path, symbol)
  if not M.options.enabled then
    return false, "ast disabled"
  end
  local backend = backend_for(path)
  if not backend then
    return false, "no backend"
  end
  if not parser_available(backend.parser) then
    return false, "no parser for " .. backend.parser
  end
  local idx = M.index({ root = vim.fs.dirname(vim.fn.fnamemodify(path, ":p")) })
  local facts, err = idx:facts(idx:rel(path))
  if not facts then
    return false, err
  end
  if symbol then
    local sym = facts.symbols[symbol]
    if not sym then
      return false, "symbol not found"
    end
    if sym.error then
      return false, "parse error in symbol"
    end
  elseif facts.error then
    return false, "parse error in file"
  end
  return true
end

-- A fresh project index with a resolver attached.
function M.index(opts)
  opts = vim.tbl_extend("force", {
    languages = M.options.languages,
    ignore = M.options.ignore,
    max_files = M.options.max_files,
  }, opts or {})
  local idx = require("code-tour.ast.index").new(opts)
  idx.resolver = require("code-tour.ast.resolve").new(idx)
  return idx
end

-- §15: write the symbol graph as graphify-compatible node-link JSON.
-- opts: { root?, out?, cache_dir? } -> { path, nodes, links, files, truncated? }
-- The persisted project graph (`.code-tour/graph.json`, beside the notes store): graphify's
-- node-link format, rebuilt only when a file, the language set or the resolution config changed.
-- Unchanged files are never re-extracted (facts are cached by blob SHA), so a rebuild is
-- incremental. `manifest` records what the graph was built from; opts.rebuild forces a rebuild.
local function manifest_of(idx)
  local files = {}
  for _, rel in ipairs(idx.files) do
    files[rel] = idx:blob(rel)
  end
  local synthesizers = {}
  for language, rules in pairs(M.options.synthesizers or {}) do
    synthesizers[language] = vim.tbl_keys(rules)
    table.sort(synthesizers[language])
  end
  return { schema = 1, files = files,
    config = vim.fn.sha256(vim.inspect({ M.options.languages, M.options.boundaries, synthesizers })) }
end

-- Analysis views over the persisted graph: view = "communities" | "gods" | "crossings" | "neighbors".
-- Computed on first use, then cached in analysis.json under the graph's manifest hash.
function M.analyze(opts)
  opts = opts or {}
  local built = M.code_graph({ root = opts.root, cache_dir = opts.cache_dir, out = opts.graph })
  local fd = assert(io.open(built.path, "rb"))
  local graph = vim.json.decode(fd:read("*a"), { luanil = { object = true, array = true } })
  fd:close()
  local analysis = require("code-tour.ast.analysis")
  local limit = tonumber(opts.limit) or 15
  if opts.view == "neighbors" then
    local result, err = analysis.neighbors(graph, assert(opts.symbol, "neighbors needs a symbol"))
    if not result then
      error(err, 0)
    end
    return result
  end
  local key = vim.fn.sha256(vim.json.encode(graph.graph.manifest))
  local cache = vim.fs.dirname(built.path) .. "/analysis.json"
  local data
  local cfd = io.open(cache, "rb")
  if cfd then
    local ok, old = pcall(vim.json.decode, cfd:read("*a"), { luanil = { object = true, array = true } })
    cfd:close()
    if ok and type(old) == "table" and old.key == key then
      data = old.data
    end
  end
  local cached = data ~= nil
  if not data then
    data = analysis.compute(graph)
    local tmp = cache .. ".tmp" .. vim.uv.os_getpid()
    local wfd = assert(io.open(tmp, "w"))
    wfd:write(vim.json.encode({ key = key, data = data }))
    wfd:close()
    assert(vim.uv.fs_rename(tmp, cache))
  end
  if opts.view == "gods" then
    return { hubs = vim.list_slice(data.hubs, 1, limit), cached = cached }
  elseif opts.view == "crossings" then
    return { crossings = vim.list_slice(data.crossings, 1, limit), communities = vim.tbl_map(function(c)
      return { id = c.id, name = c.name, size = c.size }
    end, data.communities), cached = cached }
  end
  local communities = {}
  for _, c in ipairs(vim.list_slice(data.communities, 1, limit)) do
    communities[#communities + 1] = { id = c.id, name = c.name, size = c.size, packages = c.packages,
      types = c.types, members = opts.members and c.members or nil }
  end
  return { communities = communities, total = #data.communities, cached = cached }
end

function M.code_graph(opts)
  opts = opts or {}
  local idx = M.index({ root = opts.root, cache_dir = opts.cache_dir })
  local store = require("code-tour.ast.store").new(idx, M.options)
  local out = opts.out
  if not out or out == "" then
    out = store.path .. "/graph.json"
  end
  out = vim.fn.fnamemodify(out, ":p")
  idx:scan()
  local manifest = manifest_of(idx)
  if not opts.rebuild then
    local fd = io.open(out, "rb")
    if fd then
      local ok, old = pcall(vim.json.decode, fd:read("*a"), { luanil = { object = true, array = true } })
      fd:close()
      if ok and type(old) == "table" and old.graph and vim.deep_equal(old.graph.manifest, manifest) then
        return { path = out, nodes = #old.nodes, links = #old.links, files = #idx.files, root = idx.root,
          reused = true, truncated = idx.truncated or nil }
      end
    end
  end
  local graph = require("code-tour.ast.codegraph").build(idx)
  if #graph.nodes == 0 and next(idx.errors) then
    local files = vim.tbl_keys(idx.errors)
    table.sort(files)
    error(idx.errors[files[1]], 0)
  end
  graph.graph.manifest = manifest
  if out == store.path .. "/graph.json" then
    store:begin_write()
  end
  vim.fn.mkdir(vim.fs.dirname(out), "p")
  local tmp = out .. ".tmp" .. vim.uv.os_getpid()
  local fd = assert(io.open(tmp, "w"))
  fd:write(vim.json.encode(graph))
  fd:close()
  assert(vim.uv.fs_rename(tmp, out))
  return { path = out, nodes = #graph.nodes, links = #graph.links, files = #idx.files, root = idx.root,
    reused = false, truncated = idx.truncated or nil }
end

function M.fallback_reason(err)
  if type(err) ~= "string" then return end
  if err:find("no parser", 1, true) or err:find("no backend", 1, true) or err:find("parse error", 1, true) then
    return err
  end
  if not (err:match("^no type") or err:match("^no method") or err:match("^no symbol")) then return end
  local missing
  for _, language in ipairs(M.options.languages) do
    local ok, backend = pcall(require, "code-tour.ast.lang." .. language)
    if ok then
      if parser_available(backend.parser) then return end
      missing = missing or backend.parser
    end
  end
  return missing and ("no parser for " .. missing) or "no supported backend"
end

-- §9.1 dry run: build the tour for entries and return its outline without opening it.
-- opts: { root?, cache_dir?, detail?, through = {specs}, json? }
--   -> { outline = text, tour = data } or error
function M.outline(entries, opts)
  opts = opts or {}
  if not M.options.enabled then
    return { fallback = true, reason = "ast disabled" }
  end
  if type(entries) == "string" then
    entries = { entries }
  end
  local idx = M.index({ root = opts.root, cache_dir = opts.cache_dir })
  if opts.auto and (not entries or #entries == 0) then
    return { root = idx.root, auto = true, candidates = require("code-tour.ast.outline").auto_entries(idx), truncated = idx.truncated or nil }
  end
  local outline = require("code-tour.ast.outline")
  local tour, err = outline.build(idx, entries, {
    detail = opts.detail or M.options.detail,
    through = opts.through,
    overrides = opts.overrides,
    options = {
      cutoffs = M.options.cutoffs,
      main_cap = M.options.main_cap,
    },
  })
  if not tour then
    local reason = M.fallback_reason(err)
    if reason then return { fallback = true, reason = reason, root = idx.root } end
    error(err, 0)
  end
  return { outline = outline.text(tour), tour = outline.data(tour), root = idx.root }
end

return M
