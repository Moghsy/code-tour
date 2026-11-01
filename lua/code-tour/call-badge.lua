local M = {}

function M.highlight()
  vim.api.nvim_set_hl(0, "CodeTourCall", {
    fg = "#f0dfe2", bg = "#5c3038", ctermfg = 188, ctermbg = 52, bold = true,
  })
  vim.api.nvim_set_hl(0, "CodeTourNextCall", {
    fg = "#241b08", bg = "#e5b94f", ctermfg = 235, ctermbg = 179, bold = true,
  })
  vim.api.nvim_set_hl(0, "CodeTourNextLabel", {
    fg = "#e5b94f", ctermfg = 179, bold = true,
  })
end

function M.range(buf, site)
  if not site then return end
  if site.start_col ~= nil then
    return { site.start - 1, site.start_col, site["end"] - 1, site.end_col }
  end
  if not site.symbol or site.symbol == "" then return end
  for line = site.start, site["end"] do
    local text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
    local first, last = text:find(site.symbol, 1, true)
    if first then
      local receiver = text:sub(1, first - 1):match("([%a_][%w_%.:]*[%.:])$")
      if receiver then first = first - #receiver end
      return { line - 1, first - 1, line - 1, last }
    end
  end
end

function M.contains(range, line, col)
  if not range then return false end
  local row = line - 1
  return row >= range[1] and row <= range[3]
    and (row > range[1] or col >= range[2]) and (row < range[3] or col < range[4])
end

-- Replace the rendered glyphs with identical source text on a solid badge
-- background. A range highlight alone inherits the tour's blue line background.
function M.draw(buf, ns, first_row, first_col, last_row, last_col, next_call)
  local group = next_call and "CodeTourNextCall" or "CodeTourCall"
  for row = first_row, last_row do
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if line then
      local first = row == first_row and first_col or 0
      local last = row == last_row and last_col or #line
      first, last = math.min(first, #line), math.min(last, #line)
      if last > first then
        vim.api.nvim_buf_set_extmark(buf, ns, row, first, {
          end_col = last, hl_group = group, priority = 1000,
          virt_text = { { line:sub(first + 1, last), group } },
          virt_text_pos = "overlay", hl_mode = "replace",
        })
      end
    end
  end
  if next_call then
    vim.api.nvim_buf_set_extmark(buf, ns, last_row, 0, {
      virt_text = { { "  <- next snippet", "CodeTourNextLabel" } }, virt_text_pos = "eol", priority = 1000,
    })
  end
end

return M
