local M = {}

function M.prepare(stop, root, base)
  local old, offset = stop.old, stop.start - 1
  local explicit = old ~= nil
  if old == nil then
    local gitroot = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = root, text = true }):wait()
    assert(gitroot.code == 0, "Review requires a Git repository or explicit old text")
    gitroot = vim.trim(gitroot.stdout)
    local path = assert(vim.fs.relpath(gitroot, stop.path), "Review file is outside Git repository")
    local result = vim.system({ "git", "show", (base or "HEAD") .. ":" .. path }, { cwd = gitroot, text = true }):wait()
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
      local removed, owners = {}, {}
      for index = 0, na - 1 do
        local owner = offset + (nb > 0 and b + math.min(index, nb - 1) or b + 1)
        if owner >= stop.start and (owner <= stop["end"] or (nb == 0 and owner == stop["end"] + 1)) then
          removed[#removed + 1], owners[#owners + 1] = before[a + index], math.min(owner, stop["end"])
        end
      end
      anchor = math.max(anchor, stop.start)
      if #removed > 0 then
        stop.removed[#stop.removed + 1] = {
          line = math.min(anchor, vim.api.nvim_buf_line_count(stop.buf)),
          above = anchor <= vim.api.nvim_buf_line_count(stop.buf),
          lines = removed,
          owners = owners,
        }
      end
    end
  end
end

return M
