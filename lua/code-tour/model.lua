local M = {}

local function range(value, lower, upper)
  return type(value) == "number" and value == math.floor(value) and value >= lower and value <= upper
end

function M.validate(data, root, max_section_lines)
  max_section_lines = max_section_lines or 25
  assert(type(data) == "table" and data.version == 1, "Expected tour version 1")
  assert(type(data.snippets) == "table" and vim.islist(data.snippets) and #data.snippets > 0, "Expected snippets list")
  root = assert(vim.uv.fs_realpath(root), "Project root does not exist")
  for _, snippet in ipairs(data.snippets) do
    assert(type(snippet.file) == "string" and not snippet.file:match("^/"), "File must be relative to project root")
    local path = vim.uv.fs_realpath(root .. "/" .. snippet.file)
    assert(path and path:sub(1, #root + 1) == root .. "/", "File missing or outside project: " .. snippet.file)
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    local count = vim.api.nvim_buf_line_count(buf)
    assert(range(snippet.start_line, 1, count) and range(snippet.end_line, snippet.start_line, count), "Invalid snippet range")
    assert(type(snippet.overview) == "string" and snippet.overview ~= "", "Snippet requires an overview")
    assert(snippet.title == nil or type(snippet.title) == "string", "Invalid snippet title")
    snippet.sections = snippet.sections or {}
    assert(type(snippet.sections) == "table" and vim.islist(snippet.sections), "Sections must be a list")
    for _, section in ipairs(snippet.sections) do
      assert(range(section.start_line, snippet.start_line, snippet.end_line)
        and range(section.end_line, section.start_line, snippet.end_line), "Section outside snippet")
      assert(section.end_line - section.start_line + 1 <= max_section_lines,
        "Section exceeds " .. max_section_lines .. " lines; split it into smaller explanations")
      assert(type(section.explanation) == "string" and section.explanation ~= "", "Section requires explanation")
      assert(section.title == nil or type(section.title) == "string", "Invalid section title")
    end
    snippet.buf = buf
    snippet.tick = vim.api.nvim_buf_get_changedtick(buf)
    snippet.answers = {}
  end
  return data
end

-- Keep words intact; only tokens wider than an entire row need UTF-8-safe splitting.
function M.wrap(text, width)
  width = math.max(4, width)
  local lines = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local row, found = "", false
    line = line:gsub("\t", "  ")
    for spaces, word in line:gmatch("( *)([^ ]+)") do
      local first = not found
      found = true
      if vim.fn.strdisplaywidth(row .. spaces .. word) > width and row ~= "" then
        lines[#lines + 1] = row
        row, spaces = "", ""
      end
      if row == "" and not first then spaces = "" end
      if vim.fn.strdisplaywidth(spaces .. word) > width and vim.fn.strdisplaywidth(word) <= width then spaces = "" end
      row = row .. spaces
      for i = 0, vim.fn.strchars(word) - 1 do
        local char = vim.fn.strcharpart(word, i, 1)
        if vim.fn.strdisplaywidth(row .. char) > width then
          if row ~= "" then lines[#lines + 1] = row end
          row = ""
        end
        row = row .. char
      end
    end
    if not found then
      row = line
    else
      local trailing = line:match(" +$") or ""
      if vim.fn.strdisplaywidth(row .. trailing) <= width then row = row .. trailing end
    end
    lines[#lines + 1] = row
  end
  return lines
end

function M.pages(text, width, height)
  local lines, pages = M.wrap(text, width), {}
  height = math.max(1, height)
  for i = 1, #lines, height do
    pages[#pages + 1] = vim.list_slice(lines, i, i + height - 1)
  end
  return pages
end

return M
