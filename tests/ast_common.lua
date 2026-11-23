-- Shared setup for the AST tests: plugin and parser on the runtimepath, the Java
-- fixture copied into a fresh git repository, an isolated parse cache, and lookups.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME or vim.fn.expand("~/.local/share/nvim/site"))

local M = { plugin = plugin, checks = 0 }
local parser_available = require("code-tour.ast.index").parser_available

function M.check(value, message)
  if not value then
    error("FAILED: " .. message, 2)
  end
  M.checks = M.checks + 1
end

function M.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    error(("FAILED: %s\n  expected: %s\n  actual:   %s"):format(message, vim.inspect(expected), vim.inspect(actual)), 2)
  end
  M.checks = M.checks + 1
end

-- false (and a printed gap) when the Java parser is missing
-- The agent's route for the checkout tour (what the old computed main flow chose), as route overrides.
function M.route(name)
  local file = M.plugin .. "/tests/fixtures/routes/" .. (name or "checkout") .. ".json"
  local edges = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  local ops = {}
  for _, e in ipairs(edges) do
    ops[#ops + 1] = { kind = "route", from = e.from, to = e.to, level = e.level, site = e.site }
  end
  return ops
end

function M.parser()
  if parser_available("java") then
    return true
  end
  print("MISSING PARSER: java (verification gap; install it to run the AST tests)")
  return false
end

local function run(cmd, cwd)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  assert(r.code == 0, table.concat(cmd, " ") .. ": " .. (r.stderr or ""))
  return r.stdout
end
M.run = run

-- A git repository holding the Java fixture; returns its root.
function M.project()
  local root = vim.fn.tempname() .. "-shop"
  vim.fn.mkdir(root, "p")
  run({ "cp", "-r", plugin .. "/tests/fixtures/java/.", root })
  run({ "git", "init", "-q" }, root)
  run({ "git", "add", "-A" }, root)
  run({ "git", "-c", "user.email=t@example.invalid", "-c", "user.name=t", "commit", "-qm", "fixture" }, root)
  return root
end

M.cache = vim.fn.tempname() .. "-ast-cache"

function M.index(root, opts)
  return require("code-tour.ast").index(vim.tbl_extend("force", { root = root, cache_dir = M.cache }, opts or {}))
end

M.java = "src/main/java/"

-- Resolved facts of a fixture file (path relative to src/main/java).
function M.facts(idx, rel)
  return assert(idx.resolver:resolve_file(M.java .. rel), "no facts for " .. rel)
end

function M.body(idx, rel, id)
  local facts = M.facts(idx, rel)
  return assert(facts.bodies[id], "no body " .. id), facts
end

-- The nth site whose badge text is `text`.
function M.site(body, text, nth)
  nth = nth or 1
  for _, s in ipairs(body.sites) do
    if s.text == text then
      nth = nth - 1
      if nth == 0 then
        return s
      end
    end
  end
  error("no site " .. text .. " in " .. body.symbol, 2)
end

function M.targets(s)
  local out = {}
  for _, t in ipairs(s.targets or {}) do
    out[#out + 1] = t.symbol
  end
  return out
end

function M.finish(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    io.stderr:write(err .. "\n")
    vim.cmd("cquit 1")
  end
  print(("PASS: %d %s checks"):format(M.checks, name))
  vim.cmd("qa!")
end

return M
