-- Render Markdown into styled, width-wrapped virtual-text rows.
-- Boxes are virt_lines, so the markdown filetype cannot style them; each row is
-- a list of { text, hl } chunks instead.
local M = {}

local BODY = "Normal"
local CODE = "CodeTourMdCode"

function M.highlight()
  for name, spec in pairs({
    CodeTourMdHeading = { link = "Title" },
    CodeTourMdBold = { bold = true },
    CodeTourMdItalic = { italic = true },
    CodeTourMdStrike = { strikethrough = true },
    CodeTourMdCode = { link = "@markup.raw" },
    CodeTourMdLink = { link = "Underlined" },
    CodeTourMdMarker = { link = "Special" },
    CodeTourMdQuote = { link = "Comment" },
    CodeTourMdRule = { link = "FloatBorder" },
  }) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

local function stack(base, extra)
  local result = type(base) == "table" and vim.list_slice(base) or { base }
  result[#result + 1] = extra
  return result
end

-- Inline spans: `code`, **bold**, *italic*, ~~strike~~, [link](url), escapes.
local function inline(text, hl, out)
  out = out or {}
  local plain, i = "", 1
  local function flush()
    if plain ~= "" then out[#out + 1] = { plain, hl }; plain = "" end
  end
  local function span(open, close, group)
    if text:sub(i, i + #open - 1) ~= open then return false end
    local inner_start = i + #open
    local stop = text:find(close, inner_start + 1, true)
    if not stop or text:sub(inner_start, inner_start):match("%s") then return false end
    -- Underscore emphasis only applies at word boundaries (snake_case stays literal).
    if open:sub(1, 1) == "_" and (text:sub(i - 1, i - 1):match("[%w]")
      or text:sub(stop + #close, stop + #close):match("[%w]")) then return false end
    flush()
    inline(text:sub(inner_start, stop - 1), stack(hl, group), out)
    i = stop + #close
    return true
  end
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\\" and text:sub(i + 1, i + 1):match("%p") then
      plain, i = plain .. text:sub(i + 1, i + 1), i + 2
    elseif c == "`" then
      local ticks = text:match("^`+", i)
      local stop = text:find(ticks, i + #ticks, true)
      if stop then
        flush()
        local code = text:sub(i + #ticks, stop - 1)
        if #ticks > 1 then code = code:gsub("^ (.-) $", "%1") end
        out[#out + 1] = { code, stack(hl, CODE) }
        i = stop + #ticks
      else
        plain, i = plain .. ticks, i + #ticks
      end
    elseif c == "[" and text:match("^%[[^%]]+%]%([^%)]*%)", i) then
      local label, rest = text:match("^%[([^%]]+)%]%([^%)]*%)()", i)
      flush()
      inline(label, stack(hl, "CodeTourMdLink"), out)
      i = rest
    elseif not (span("**", "**", "CodeTourMdBold") or span("__", "__", "CodeTourMdBold")
      or span("~~", "~~", "CodeTourMdStrike") or span("*", "*", "CodeTourMdItalic")
      or span("_", "_", "CodeTourMdItalic")) then
      plain, i = plain .. c, i + 1
    end
  end
  flush()
  return out
end

local function width_of(chunks)
  local total = 0
  for _, chunk in ipairs(chunks) do total = total + vim.fn.strdisplaywidth(chunk[1]) end
  return total
end

-- Take the longest character prefix of `text` that fits in `room` cells.
local function fit(text, room)
  local take, n = "", 0
  while n < vim.fn.strchars(text) do
    local char = vim.fn.strcharpart(text, n, 1)
    if vim.fn.strdisplaywidth(take .. char) > room then break end
    take, n = take .. char, n + 1
  end
  return take, vim.fn.strcharpart(text, n)
end

-- Greedy word wrap over styled chunks; continuation rows start with `hang`.
local function wrap(chunks, width, prefix, hang)
  local words, word, gap, gap_hl = {}, {}, "", BODY
  local function close()
    if #word > 0 then words[#words + 1] = { gap = gap, hl = gap_hl, chunks = word }; word, gap = {}, "" end
  end
  for _, chunk in ipairs(chunks) do
    for spaces, piece in chunk[1]:gsub("\t", "  "):gmatch("( *)([^ ]*)") do
      if spaces ~= "" then close(); gap, gap_hl = gap .. spaces, chunk[2] end
      if piece ~= "" then word[#word + 1] = { piece, chunk[2] } end
    end
  end
  close()
  local rows, row, used, fresh = {}, vim.deepcopy(prefix), width_of(prefix), true
  local function newline()
    rows[#rows + 1] = row
    row, used, fresh = vim.deepcopy(hang), width_of(hang), true
  end
  for _, item in ipairs(words) do
    local gap = fresh and "" or item.gap
    if not fresh and used + #gap + width_of(item.chunks) > width then newline(); gap = "" end
    if gap ~= "" then row[#row + 1] = { gap, item.hl }; used = used + #gap end
    for _, chunk in ipairs(item.chunks) do
      local text = chunk[1]
      -- Only tokens wider than a whole row are split at character boundaries.
      while used + vim.fn.strdisplaywidth(text) > width do
        local take, rest = fit(text, width - used)
        if take == "" and fresh then take, rest = vim.fn.strcharpart(text, 0, 1), vim.fn.strcharpart(text, 1) end
        if take ~= "" then row[#row + 1] = { take, chunk[2] } end
        text = rest
        newline()
      end
      if text ~= "" then
        row[#row + 1] = { text, chunk[2] }
        used, fresh = used + vim.fn.strdisplaywidth(text), false
      end
    end
  end
  rows[#rows + 1] = row
  return rows
end

local function code_rows(lines, lang, width)
  local styles = {}
  local code = table.concat(lines, "\n")
  local ok_lang, language = pcall(vim.treesitter.language.get_lang, lang ~= "" and lang or "text")
  language = ok_lang and language or lang
  local ok, parser = pcall(vim.treesitter.get_string_parser, code, language)
  local query = ok and language and vim.treesitter.query.get(language, "highlights")
  if query then
    local tree = parser:parse()[1]
    for id, node in query:iter_captures(tree:root(), code, 0, -1) do
      local name = query.captures[id]
      if not name:match("^_") and name ~= "spell" and name ~= "nospell" then
        local sr, sc, er, ec = node:range()
        for row = sr, er do
          styles[row] = styles[row] or {}
          local from = row == sr and sc or 0
          local to = row == er and ec or #(lines[row + 1] or "")
          for col = from, to - 1 do styles[row][col] = "@" .. name .. "." .. language end
        end
      end
    end
  end
  local rows = {}
  for index, line in ipairs(lines) do
    line = line:gsub("\t", "  ")
    local chunks, current, text = {}, nil, ""
    local marks = styles[index - 1] or {}
    for col = 0, #line - 1 do
      local hl = marks[col] or CODE
      if hl ~= current and text ~= "" then chunks[#chunks + 1] = { text, current }; text = "" end
      current, text = hl, text .. line:sub(col + 1, col + 1)
    end
    if text ~= "" then chunks[#chunks + 1] = { text, current } end
    -- Code keeps its spacing: hard-wrap by display width instead of by words.
    local row, used = { { "  ", BODY } }, 2
    for _, chunk in ipairs(chunks) do
      local piece = chunk[1]
      while piece ~= "" do
        local take, rest = fit(piece, width - used)
        if take == "" and used == 2 then take, rest = vim.fn.strcharpart(piece, 0, 1), vim.fn.strcharpart(piece, 1) end
        if take == "" then
          rows[#rows + 1] = row
          row, used = { { "  ", BODY } }, 2
        else
          row[#row + 1] = { take, chunk[2] }
          used, piece = used + vim.fn.strdisplaywidth(take), rest
        end
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

-- A run of pipe-table lines, with columns padded to a shared width.
function M.table_rows(lines, first, width)
  local grid, widths = {}, {}
  local index = first
  while lines[index] and lines[index]:match("^%s*|") do
    local body = lines[index]:gsub("^%s*|", ""):gsub("|%s*$", "")
    if body:match("^[%s:|%-]+$") then
      grid[#grid + 1] = false
    else
      local cells = {}
      for _, cell in ipairs(vim.split(body, "|", { plain = true })) do
        local chunks = inline(vim.trim(cell), BODY)
        cells[#cells + 1] = chunks
        widths[#cells] = math.max(widths[#cells] or 0, width_of(chunks))
      end
      grid[#grid + 1] = cells
    end
    index = index + 1
  end
  local rows = {}
  for _, cells in ipairs(grid) do
    local chunks = {}
    for column, size in ipairs(widths) do
      if column > 1 then chunks[#chunks + 1] = { cells and " │ " or "─┼─", "CodeTourMdRule" } end
      if cells then
        vim.list_extend(chunks, cells[column] or {})
        chunks[#chunks + 1] = { string.rep(" ", size - width_of(cells[column] or {})), BODY }
      else
        chunks[#chunks + 1] = { string.rep("─", size), "CodeTourMdRule" }
      end
    end
    vim.list_extend(rows, wrap(chunks, width, {}, {}))
  end
  return rows
end

-- Returns rows of { text, hl } chunks, each at most `width` display cells.
function M.render(text, width)
  width = math.max(4, width)
  local rows, lines, i = {}, vim.split(text, "\n", { plain = true }), 1
  local function add(list) vim.list_extend(rows, list) end
  while i <= #lines do
    local line = lines[i]
    local fence, lang = line:match("^%s*(```+)%s*([%w_+%-]*)")
    if not fence then fence, lang = line:match("^%s*(~~~+)%s*([%w_+%-]*)") end
    if fence then
      local body = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("^%s*" .. vim.pesc(fence:sub(1, 1)):rep(#fence)) do
        body[#body + 1] = lines[i]
        i = i + 1
      end
      add(code_rows(body, lang, width))
    elseif line:match("^%s*$") then
      rows[#rows + 1] = { { "", BODY } }
    elseif line:match("^%s*#+%s") then
      local title = line:match("^%s*#+%s+(.-)%s*#*%s*$")
      add(wrap(inline(title, { BODY, "CodeTourMdHeading", "CodeTourMdBold" }), width, {}, {}))
    elseif line:match("^%s*[-*_]%s*[-*_]%s*[-*_][-*_%s]*$") then
      rows[#rows + 1] = { { string.rep("─", width), "CodeTourMdRule" } }
    elseif line:match("^%s*|") then
      add(M.table_rows(lines, i, width))
      while lines[i + 1] and lines[i + 1]:match("^%s*|") do i = i + 1 end
    elseif line:match("^%s*>") then
      local body = line:gsub("^%s*>%s?", "")
      local bar = { { "▎ ", "CodeTourMdQuote" } }
      add(wrap(inline(body, { BODY, "CodeTourMdQuote" }), width, bar, bar))
    else
      local indent, marker, rest = line:match("^(%s*)([-*+])%s+(.*)$")
      if marker then marker = "•" else indent, marker, rest = line:match("^(%s*)(%d+[.)])%s+(.*)$") end
      if marker then
        local pad = string.rep(" ", math.floor(#indent:gsub("\t", "  ") / 2) * 2)
        local check = rest:match("^%[([ xX])%]%s+")
        if check then
          marker, rest = check == " " and "☐" or "☑", rest:gsub("^%[[ xX]%]%s+", "")
        end
        local lead = pad .. marker .. " "
        add(wrap(inline(rest, BODY), width, { { pad, BODY }, { marker .. " ", "CodeTourMdMarker" } },
          { { string.rep(" ", vim.fn.strdisplaywidth(lead)), BODY } }))
      else
        local lead = line:match("^%s*")
        add(wrap(inline(line:sub(#lead + 1), BODY), width, { { lead, BODY } }, {}))
      end
    end
    i = i + 1
  end
  return rows
end

-- Join neighbouring chunks that share a style so each row stays compact.
local function merge(row)
  local result = {}
  for _, chunk in ipairs(row) do
    local last = result[#result]
    if last and vim.deep_equal(last[2], chunk[2]) then
      last[1] = last[1] .. chunk[1]
    elseif chunk[1] ~= "" or #row == 1 then
      result[#result + 1] = { chunk[1], chunk[2] }
    end
  end
  return #result > 0 and result or { { "", BODY } }
end

function M.pages(text, width, height)
  local rows, pages = vim.tbl_map(merge, M.render(text, width)), {}
  height = math.max(1, height)
  for i = 1, #rows, height do
    pages[#pages + 1] = vim.list_slice(rows, i, i + height - 1)
  end
  return pages
end

return M
