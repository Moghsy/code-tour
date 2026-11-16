local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, cb) cb(true) end
local tour, view, stops = require("tour"), require("code-tour.tour-view"), require("code-tour.stops")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local lines = {}
for i = 1, 40 do lines[i] = "line " .. i end
vim.fn.writefile(lines, root .. "/main.lua")
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function header() return view.state().rows[2][2][1] end
local function state() return tour.state() end
local function part(a, b, note, parts, calls) return { start = a, ["end"] = b, note = note or ("p" .. a), parts = parts, calls = calls } end

local function run()
  tour.setup({ smooth_scroll = false })
  -- Nested parts flatten depth-first and keep their tree.
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 12, title = "Tree", note = "Overview",
    parts = {
      part(1, 4, "A", { part(1, 2, "A1"), part(3, 4, "A2") }),
      part(5, 8, "B"),
      part(9, 12, "C", { part(9, 10, "C1", { part(9, 9, "C1a"), part(10, 10, "C1b") }), part(11, 12, "C2") }),
    },
  } }, { root = root })
  local stop = state().stops[1]
  local notes = {}
  for _, p in ipairs(stop.parts) do notes[#notes + 1] = p.note end
  check(table.concat(notes, " ") == "A A1 A2 B C C1 C1a C1b C2", "Parts flatten depth-first: " .. table.concat(notes, " "))
  check(#stops.top_parts(stop) == 3 and #stops.children(stop, stop.parts[1]) == 2, "The tree of parts is kept")
  local paths = {}
  for _, p in ipairs(stop.parts) do paths[#paths + 1] = stops.path(stop, p) end
  check(table.concat(paths, " ") == "1 1.1 1.2 2 3 3.1 3.1.1 3.1.2 3.2", "Part paths: " .. table.concat(paths, " "))
  check(stop.parts[7]._depth == 3 and stop.parts[1]._depth == 1, "Depth is recorded")
  -- aj walks the tree depth-first and the header shows where the part sits in it.
  tour.next_explanation(2)
  check(header():find("Part 1.1 (2/9)", 1, true), "Header shows the part path: " .. header())
  tour.next_explanation(5)
  check(header():find("Part 3.1.1 (7/9)", 1, true), "Deep parts show their full path: " .. header())
  -- Every level must cover its parent.
  local ok, err = pcall(tour.show, { {
    file = "main.lua", start = 1, ["end"] = 8, title = "Gap", note = "x",
    parts = { part(1, 8, "A", { part(1, 3, "A1"), part(5, 8, "A2") }) },
  } }, { root = root })
  check(not ok and tostring(err):find("cover the whole part", 1, true), "Children must cover their part: " .. tostring(err))
  ok, err = pcall(tour.show, { {
    file = "main.lua", start = 1, ["end"] = 8, title = "Out", note = "x",
    parts = { part(1, 4, "A", { part(1, 6, "A1") }), part(5, 8, "B") },
  } }, { root = root })
  check(not ok and tostring(err):find("outside its parent part", 1, true), "Children stay inside their part: " .. tostring(err))
  -- A flat tour still reads Part N/M.
  tour.show({ { file = "main.lua", start = 1, ["end"] = 4, title = "Flat", note = "x",
    parts = { part(1, 2), part(3, 4) } } }, { root = root })
  tour.next_explanation(1)
  check(header():find("Part 1/2", 1, true) and not stops.nested(state().stops[1]), "Flat tours keep the old counter: " .. header())
  -- The graph keeps the tree and a stale deep part lists every ancestor.
  tour.show({ { file = "main.lua", start = 1, ["end"] = 12, title = "Tree", note = "Overview",
    parts = { part(1, 6, "A", { part(1, 3, "A1"), part(4, 6, "A2") }), part(7, 12, "B") } } }, { root = root })
  local graph = vim.json.decode(table.concat(vim.fn.readfile(tour.graph().path), "\n"))
  local boxes = graph.nodes[1].boxes
  check(boxes[3].parent == boxes[2].id and boxes[3].depth == 2 and boxes[2].parent == boxes[1].id, "Graph boxes record their parent and depth")
  boxes[3].stale, boxes[3].status = true, "source_changed"
  boxes[3].saved_id = "x"
  local items = require("code-tour.stale").collect(graph)
  local relations = {}
  for _, link in ipairs(items[1].update_also) do relations[#relations + 1] = link.relation .. ":" .. link.id end
  check(#relations == 2 and relations[1]:match("^parent:") and relations[2]:match("^overview:"),
    "A stale deep part lists its parent part and the overview: " .. table.concat(relations, ","))
  -- Refining a whole part makes the reply its children.
  tour.show({ { file = "main.lua", start = 1, ["end"] = 8, title = "Refine", note = "Overview",
    parts = { part(1, 4, "A"), part(5, 8, "B") } } }, { root = root })
  tour.next_explanation(1)
  local request = tour.explain_location({ uri = vim.uri_from_fname(root .. "/main.lua"),
    range = { start = { line = 0, character = 0 }, ["end"] = { line = 3, character = 1 } } })
  tour.fill(request, { { file = "main.lua", start = 1, ["end"] = 4, title = "A", note = "A detail",
    parts = { part(1, 2, "A1"), part(3, 4, "A2") } } })
  local refined = state().stops[1]
  local order = {}
  for _, p in ipairs(refined.parts) do order[#order + 1] = p.note .. (p._parent_part and "<" .. p._parent_part.note or "") end
  check(#refined.parts == 4 and refined.parts[2]._parent_part == refined.parts[1] and refined.parts[3]._parent_part == refined.parts[1],
    "Refining a part makes its replies children: " .. table.concat(order, " "))
  tour.stop()
end
local ok, err = xpcall(run, debug.traceback)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else print("PASS: " .. checks .. " part tree checks"); vim.cmd("qa!") end
