-- What a diff review covers (`code-tour ast --review`): the symbols holding lines changed
-- since the base become entries, and changes outside any of them are reported, so the
-- agent can add them as ranges. Compares what the tour shows (buffer, else disk).
local M = {}

local callable = { method = true, constructor = true, ["function"] = true }

local function git(cwd, ...)
  return vim.system({ "git", "--literal-pathspecs", ... }, { cwd = cwd }):wait()
end

local function fields(out)
  local list = vim.split(out or "", "\0", { plain = true })
  if list[#list] == "" then
    list[#list] = nil
  end
  return list
end

-- Files under one checkout that differ from the base: { rel, path, old_path?, deleted? }.
local function changed_files(idx, checkout, base)
  assert(git(checkout.root, "rev-parse", "--verify", "--quiet", base .. "^{commit}").code == 0,
    "Invalid review base: " .. base)
  local diff = git(checkout.root, "diff", "--find-renames", "--relative", "--name-status", "-z", base)
  assert(diff.code == 0, diff.stderr)
  local out, seen = {}, {}
  local function add(path, old_path, deleted)
    local rel = checkout.prefix .. path
    if not seen[rel] then
      seen[rel] = true
      out[#out + 1] = { rel = rel, path = path, old_path = old_path, deleted = deleted }
    end
  end
  local list, i = fields(diff.stdout), 1
  while i <= #list do
    local status = list[i]:sub(1, 1)
    if status == "R" or status == "C" then
      add(list[i + 2], list[i + 1])
      i = i + 3
    else
      add(list[i + 1], status ~= "A" and list[i + 1] or nil, status == "D")
      i = i + 2
    end
  end
  for _, path in ipairs(fields(git(checkout.root, "ls-files", "--others", "--exclude-standard", "-z").stdout)) do
    if not vim.startswith(path, ".code-tour/") then
      add(path)
    end
  end
  -- unsaved edits are not in git's diff
  local buffer = require("code-tour.ast.index").buffer
  for _, rel in ipairs(idx.files) do
    if vim.startswith(rel, checkout.prefix) then
      local buf = buffer(idx:abs(rel))
      if buf and vim.bo[buf].modified then
        local path = rel:sub(#checkout.prefix + 1)
        add(path, path)
      end
    end
  end
  table.sort(out, function(a, b) return a.rel < b.rel end)
  return out
end

local function current_text(idx, rel)
  local path = idx:abs(rel)
  local buf = require("code-tour.ast.index").buffer(path)
  if buf and vim.bo[buf].modified then
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  end
  local fd = io.open(path, "rb")
  if not fd then
    return
  end
  local text = fd:read("*a")
  fd:close()
  return text
end

local function normal(text)
  text = text:gsub("^\239\187\191", ""):gsub("\r\n", "\n")
  if text ~= "" and text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  return text
end

local function symbols_of(idx, rel)
  local facts = idx.file_set[rel] and idx:facts(rel)
  local out = {}
  for id, sym in pairs(facts and facts.symbols or {}) do
    if callable[sym.kind] and sym.range and not sym.implicit and not sym.error and sym.file == rel then
      local first, last = sym.range.start[1] + 1, sym.range["end"][1] + 1
      if sym.range["end"][2] == 0 and last > first then
        last = last - 1
      end
      out[#out + 1] = { id = id, first = first, last = last }
    end
  end
  return out
end

local function innermost(symbols, first, last)
  local best
  for _, sym in ipairs(symbols) do
    if sym.first <= first and sym.last >= last
        and (not best or sym.last - sym.first < best.last - best.first) then
      best = sym
    end
  end
  return best
end

local function range_text(a, b)
  return a == b and tostring(a) or (a .. "-" .. b)
end

local function file_changes(idx, checkout, base, file, entries, uncovered)
  if file.deleted then
    uncovered[#uncovered + 1] = file.rel .. " (deleted)"
    return
  end
  local text = current_text(idx, file.rel)
  if not text then
    return
  end
  local old = ""
  if file.old_path then
    local shown = git(checkout.root, "show", base .. ":./" .. file.old_path)
    old = shown.code == 0 and shown.stdout or ""
  end
  if text:find("\0", 1, true) then
    uncovered[#uncovered + 1] = file.rel .. " (binary)"
    return
  end
  local new = normal(text)
  local lines = vim.split(new, "\n", { plain = true })
  local symbols = symbols_of(idx, file.rel)
  local touched, outside = {}, {}
  for _, hunk in ipairs(vim.diff(normal(old), new, { result_type = "indices", algorithm = "histogram" })) do
    local _, _, start, count = unpack(hunk)
    if count == 0 then
      -- a deletion sits between `start` and the next line; it belongs to a symbol holding both
      local sym = innermost(symbols, start, start + 1)
      if sym then
        touched[sym] = true
      else
        outside[#outside + 1] = "deletion after line " .. start
      end
    else
      local a, b
      for line = start, start + count - 1 do
        local sym = innermost(symbols, line, line)
        if sym then
          touched[sym] = true
        end
        if not sym and (lines[line] or ""):find("%S") then
          a, b = a or line, line
        elseif sym and a then
          outside[#outside + 1], a = range_text(a, b), nil
        end
      end
      if a then
        outside[#outside + 1] = range_text(a, b)
      end
    end
  end
  local found = vim.tbl_keys(touched)
  table.sort(found, function(x, y) return x.first < y.first end)
  for _, sym in ipairs(found) do
    entries[#entries + 1] = sym.id
  end
  if #outside > 0 then
    uncovered[#uncovered + 1] = file.rel .. ":" .. table.concat(outside, ", ")
  end
end

-- Returns { entries = symbol ids, uncovered = descriptions, files = count }.
function M.collect(idx, base)
  local checkouts = idx:search_places()
  assert(#checkouts > 0, "Review requires a Git repository")
  local entries, uncovered, files = {}, {}, 0
  for _, checkout in ipairs(checkouts) do
    for _, file in ipairs(changed_files(idx, checkout, base)) do
      files = files + 1
      file_changes(idx, checkout, base, file, entries, uncovered)
    end
  end
  return { entries = entries, uncovered = uncovered, files = files }
end

-- The entries of a review (the given ones, else the changed symbols) and the warnings to
-- print. Returns entries, warnings, or nil and why there is nothing to tour.
function M.review(idx, base, entries, has_overrides)
  local found = M.collect(idx, base)
  local warnings = {}
  for _, item in ipairs(found.uncovered) do
    warnings[#warnings + 1] = "changed outside any symbol: " .. item
  end
  if entries and #entries > 0 then
    return entries, warnings
  end
  if found.files == 0 then
    return nil, "nothing changed since " .. base
  end
  if #found.entries == 0 and not has_overrides then
    return nil, "no changed symbol the AST covers (" .. table.concat(found.uncovered, "; ") .. ")"
  end
  return found.entries, warnings
end

return M
