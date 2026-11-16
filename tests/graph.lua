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
local function run()
  vim.fn.mkdir(root .. "/app/.git", "p")
  vim.fn.writefile({ "local function main(x)", "  local y = helper(x)", "  return y", "end", "",
    "local function helper(x)", "  return x * 2", "end" }, root .. "/app/main.lua")
  tour.setup({ smooth_scroll = false })
  tour.show({
    { file = "main.lua", start = 1, ["end"] = 4, title = "Main", note = "Main flow",
      parts = { { start = 1, ["end"] = 2, note = "Call helper", calls = {
        { file = "main.lua", start = 6, ["end"] = 8, title = "Helper", note = "Doubles x", next = true,
          callsite = { start = 2, ["end"] = 2, symbol = "helper" } },
      } }, { start = 3, ["end"] = 4, note = "Return" } } },
    { file = "main.lua", start = 6, ["end"] = 8, title = "Helper again", note = "Same code, second tour stop" },
  }, { root = root .. "/app" })
  local info = tour.graph()
  local graph = vim.json.decode(table.concat(vim.fn.readfile(info.path), "\n"))
  check(graph.directed and graph.graph.kind == "code-tour", "Node-link graph header")
  local nodes = {}
  for _, node in ipairs(graph.nodes) do nodes[node.id] = node end
  local helper = nodes[root .. "/app/main.lua:6-8"]
  check(#graph.nodes == 2 and helper and #helper.stops == 2, "Identical ranges merge into one node")
  local relations = {}
  for _, link in ipairs(graph.links) do relations[#relations + 1] = link.relation .. ":" .. (link.via or "") end
  table.sort(relations)
  check(vim.deep_equal(relations, { "next:call", "next:sequence", "overlaps:range" }) or vim.deep_equal(relations, { "next:call", "next:sequence" }),
    "Gold call and route edges: " .. table.concat(relations, ","))
  local call
  for _, link in ipairs(graph.links) do if link.via == "call" then call = link end end
  check(call.relation == "next" and call.symbol == "helper" and call.from_box:match("^1%."), "Call edge keeps its caller box and symbol")
  check(call.source:find("main.lua:1-4", 1, true) and call.target == helper.id, "Call edge runs caller to callee")
  -- An optional (non-next) call is an optional edge.
  tour.show({ { file = "main.lua", start = 1, ["end"] = 4, title = "Main", note = "Main flow",
    parts = { { start = 1, ["end"] = 2, note = "Call helper", calls = {
      { file = "main.lua", start = 6, ["end"] = 8, title = "Helper", note = "Doubles x",
        callsite = { start = 2, ["end"] = 2, symbol = "helper" } } } },
      { start = 3, ["end"] = 4, note = "Return" } } } }, { root = root .. "/app" })
  graph = vim.json.decode(table.concat(vim.fn.readfile(tour.graph().path), "\n"))
  check(graph.links[1].relation == "optional", "Non-gold calls are optional edges")
end
local ok, err = pcall(run)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("PASS: " .. checks .. " tour graph checks")
