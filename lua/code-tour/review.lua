local M = {}

function M.prepare(stop, root, base)
  local old, offset = stop.old, stop.start - 1
  local explicit = old ~= nil
  if old == nil then
    -- the workspace.repo hook names the repository of a file when the tour root is not one
    local gitroot = require("code-tour.workspace").repo_of(stop.path, root)
    if not gitroot then
      local top = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = root, text = true }):wait()
      assert(top.code == 0, "Review requires a Git repository or explicit old text")
      gitroot = vim.trim(top.stdout)
    end
    local path = assert(vim.fs.relpath(gitroot, stop.path), "Review file is outside Git repository")
    local result = vim.system({ "git", "show", (base or "HEAD") .. ":" .. path }, { cwd = gitroot, text = true }):wait()
    if result.code ~= 0 then
      -- A file renamed since the base has no blob at its new path: compare it with the old one,
      -- or the whole file would read as new.
      local renames = vim.system({ "git", "diff", "--find-renames", "--name-status", "-z", "--diff-filter=R",
        base or "HEAD" }, { cwd = gitroot }):wait()
      if renames.code == 0 then
        local fields = vim.split(renames.stdout or "", "\0", { plain = true })
        for i = 1, #fields - 2, 3 do
          if fields[i]:sub(1, 1) == "R" and fields[i + 2] == path then
            local previous = vim.system({ "git", "show", (base or "HEAD") .. ":" .. fields[i + 1] },
              { cwd = gitroot, text = true }):wait()
            if previous.code == 0 then
              result = previous
            end
            break
          end
        end
      end
    end
    if result.code ~= 0 then
      -- Untracked/new files have no base blob; invalid refs still fail.
      local ref = vim
        .system({ "git", "rev-parse", "--verify", (base or "HEAD") .. "^{commit}" }, { cwd = gitroot, text = true })
        :wait()
      assert(ref.code == 0, "Invalid review base: " .. (base or "HEAD"))
      old = ""
    else
      old = result.stdout
    end
    offset = 0
  end
  local lines = vim.api.nvim_buf_get_lines(stop.buf, offset, explicit and stop["end"] or -1, false)
  if not explicit and #lines == 1 and lines[1] == "" and not vim.bo[stop.buf].modified then
    -- the editor shows one blank line for an empty file; it is only a line if the file holds a newline
    local stat = vim.uv.fs_stat(stop.path)
    if stat and stat.size == 0 then
      lines = {}
    end
  end
  -- Compare a canonical form of both sides, so what the editor hides is not read as a change: a
  -- byte-order mark, and a carriage return left on the lines of a file with mixed line endings.
  local bom = "\239\187\191"
  old = old:gsub("^" .. bom, ""):gsub("\r\n", "\n")
  lines = vim.tbl_map(function(text)
    return (text:gsub("\r$", ""))
  end, lines)
  if lines[1] then
    lines[1] = lines[1]:gsub("^" .. bom, "")
  end
  local new = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
  if old ~= "" and old:sub(-1) ~= "\n" then
    old = old .. "\n"
  end
  local before = vim.split(old, "\n", { plain = true })
  stop.added, stop.removed = {}, {}
  for _, hunk in ipairs(vim.diff(old, new, { result_type = "indices", algorithm = "histogram" })) do
    local a, na, b, nb = unpack(hunk)
    for line = offset + b, offset + b + nb - 1 do
      if line >= stop.start and line <= stop["end"] then
        stop.added[line] = true
      end
    end
    local anchor = offset + (nb == 0 and b + 1 or b)
    if na > 0 then
      local removed, owners, ids = {}, {}, {}
      for index = 0, na - 1 do
        local owner = offset + (nb > 0 and b + math.min(index, nb - 1) or b + 1)
        if owner >= stop.start and (owner <= stop["end"] or (nb == 0 and owner == stop["end"] + 1)) then
          removed[#removed + 1], owners[#owners + 1] = before[a + index], math.min(owner, stop["end"])
          -- the line's number in the base: the same deleted line asked for twice is one line
          ids[#ids + 1] = not explicit and (a + index) or nil
        end
      end
      anchor = math.max(anchor, stop.start)
      if #removed > 0 then
        stop.removed[#stop.removed + 1] = {
          line = math.min(anchor, vim.api.nvim_buf_line_count(stop.buf)),
          above = anchor <= vim.api.nvim_buf_line_count(stop.buf),
          lines = removed,
          owners = owners,
          ids = #ids == #removed and ids or nil,
        }
      end
    end
  end
end

return M
