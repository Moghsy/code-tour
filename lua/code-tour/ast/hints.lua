local M = {}

local function read(path)
  local f = io.open(path, "r")
  if not f then
    return
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function decode(path)
  local content = read(path)
  if not content then
    return
  end
  local ok, value = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
  return ok and type(value) == "table" and value or false
end

local function git(idx, args)
  local res = vim.system(vim.list_extend({ "git", "-C", idx.root }, args), { text = true }):wait()
  return res.code == 0 and res.stdout or nil
end

local function clean(idx, graph)
  local project = type(graph.project) == "table" and graph.project or {}
  local commit = project.gitCommitHash or graph.built_at_commit
  if not idx.git or type(commit) ~= "string" or not commit:match("^%x+$") then
    return false
  end
  local graph_head = git(idx, { "rev-parse", "--verify", commit .. "^{commit}" })
  if not graph_head or graph_head ~= git(idx, { "rev-parse", "HEAD" }) then
    return false
  end
  local paths = {}
  for _, node in ipairs(graph.nodes) do
    local path = type(node) == "table" and (node.filePath or node.source_file)
    if type(path) == "string" then
      paths[path] = true
    end
  end
  local status = git(idx, { "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames" })
  if not status then
    return false
  end
  for record in status:gmatch("[^%z]+") do
    local file = record:sub(4)
    if paths[file] or idx.file_set[file] or idx:backend(file) then
      return false
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].modified then
      local rel = idx:rel(vim.api.nvim_buf_get_name(buf))
      if paths[rel] or idx.file_set[rel] then
        return false
      end
    end
  end
  return true
end

local function god_labels(idx)
  local labels = {}
  local report = read(idx:abs("graphify-out/GRAPH_REPORT.md")) or ""
  local inside = false
  for line in report:gmatch("[^\n]+") do
    if line:match("^## ") then
      inside = line:match("^## God Nodes") ~= nil
    elseif inside then
      local label = line:match("^%d+%. `([^`]+)`")
      if label then
        labels[label] = true
      end
    end
  end
  return labels
end

function M.load(idx)
  local by_id, by_file, warnings = {}, {}, {}
  local function include(path, graph, graphify)
    if not graph or not vim.islist(graph.nodes) then
      warnings[#warnings + 1] = "ignored " .. path .. " (invalid graph)"
      return
    end
    if not clean(idx, graph) then
      warnings[#warnings + 1] = "ignored " .. path .. " (graph does not match current project)"
      return
    end
    local labels = graphify and god_labels(idx) or {}
    local listed = {}
    for _, god in ipairs(vim.islist(graph.god_nodes) and graph.god_nodes or {}) do
      local id = type(god) == "table" and god.id or god
      if type(id) == "string" then
        listed[id] = true
      end
    end
    for _, node in ipairs(graph.nodes) do
      if type(node) == "table" and type(node.id) == "string" then
        local rel = node.filePath or node.source_file
        local summary = type(node.summary) == "string" and node.summary or nil
        local info = { summary = summary, complex = node.complexity == "complex", community = node.community,
          god = node.god_node == true or listed[node.id] or labels[node.label] or nil }
        by_id[node.id] = info
        if type(rel) == "string" then
          local line = type(node.lineRange) == "table" and node.lineRange[1]
            or tonumber(type(node.source_location) == "string" and node.source_location:match("^L(%d+)") or nil)
          by_file[rel] = by_file[rel] or {}
          table.insert(by_file[rel], { name = node.name or node.label, kind = node.type or node.kind,
            line = line, info = info })
        end
      end
    end
  end
  for _, path in ipairs({ ".ua/knowledge-graph.json", ".understand-anything/knowledge-graph.json" }) do
    local graph = decode(idx:abs(path))
    if graph ~= nil then
      include(path, graph, false)
      break
    end
  end
  local graphify_path = "graphify-out/graph.json"
  local graph = decode(idx:abs(graphify_path))
  if graph ~= nil then
    include(graphify_path, graph, true)
  end
  local symbols = setmetatable({}, { __index = function(cache, id)
    local sym = idx:symbol(id)
    if not sym then
      return
    end
    local info = vim.deepcopy(by_id[id] or {})
    for _, item in ipairs(by_file[sym.file] or {}) do
      local same_name = item.name == sym.name or (sym.label and item.name == sym.label)
      local same_line = item.line and sym.range and sym.range.start[1] + 1 == item.line
      local method = sym.kind == "method" or sym.kind == "constructor"
      if (same_line and item.kind ~= "file" and (same_name or item.kind == "function"))
          or (same_name and not item.line and not method) then
        info = vim.tbl_extend("keep", info, item.info)
      end
    end
    cache[id] = info
    return info
  end })
  return { symbols = symbols, warnings = warnings }
end

return M
