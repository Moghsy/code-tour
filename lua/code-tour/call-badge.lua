local M = {}

-- Padding (in cells) inside each end of a badge, and rounded end caps. The caps are the
-- Powerline half-circle glyphs, so they need a Nerd Font; set `rounded = false` otherwise.
local config = { padding = 1, rounded = true }

function M.configure(opts)
  opts = opts or {}
  config = { padding = 1, rounded = true }
  if opts.padding ~= nil then
    assert(type(opts.padding) == "number" and opts.padding >= 0, "badge.padding must be a non-negative number")
    config.padding = math.floor(opts.padding)
  end
  if opts.rounded ~= nil then config.rounded = opts.rounded and true or false end
end

-- Highlight for a cap: the badge colour as foreground over whatever the line shows.
local function cap_group(group)
  local name = group .. "Cap"
  local background = vim.api.nvim_get_hl(0, { name = group, link = false }).bg
  vim.api.nvim_set_hl(0, name, { fg = background })
  return name
end

-- Virtual text at one end of a badge. Left: cap then padding. Right: padding then cap.
local function edge(group, left)
  local cap = config.rounded and { vim.fn.nr2char(left and 0xe0b6 or 0xe0b4), cap_group(group) } or nil
  local pad = config.padding > 0 and { string.rep(" ", config.padding), group } or nil
  local chunks = {}
  local function add(chunk) if chunk then chunks[#chunks + 1] = chunk end end
  if left then add(cap); add(pad) else add(pad); add(cap) end
  return chunks
end

function M.highlight()
  vim.api.nvim_set_hl(0, "CodeTourCall", {
    fg = "#f0dfe2", bg = "#5c3038", ctermfg = 188, ctermbg = 52, bold = true,
  })
  vim.api.nvim_set_hl(0, "CodeTourNextCall", {
    fg = "#241b08", bg = "#e5b94f", ctermfg = 235, ctermbg = 179, bold = true,
  })
  vim.api.nvim_set_hl(0, "CodeTourCurrentCall", {
    fg = "#0b2414", bg = "#6fd08c", ctermfg = 235, ctermbg = 114, bold = true,
  })
  vim.api.nvim_set_hl(0, "CodeTourCurrentLabel", {
    fg = "#6fd08c", ctermfg = 114, bold = true,
  })
  vim.api.nvim_set_hl(0, "CodeTourFoldedCall", {
    fg = "#bfb08a", bg = "#3d3622", ctermfg = 144, ctermbg = 58,
  })
  vim.api.nvim_set_hl(0, "CodeTourFoldedLabel", {
    fg = "#9a8a5a", ctermfg = 101,
  })
  vim.api.nvim_set_hl(0, "CodeTourDoneCall", {
    fg = "#e8def7", bg = "#6a4f8f", ctermfg = 189, ctermbg = 97, bold = true,
  })
  vim.api.nvim_set_hl(0, "CodeTourDoneLabel", {
    fg = "#a98fd0", ctermfg = 140, bold = true,
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
-- `next_call` marks a gold call; `current` is the gold call the walk takes next.
function M.draw(buf, ns, first_row, first_col, last_row, last_col, next_call, current, done, folded)
  local group = current and "CodeTourCurrentCall" or done and "CodeTourDoneCall" or folded and "CodeTourFoldedCall"
    or next_call and "CodeTourNextCall" or "CodeTourCall"
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
        -- Padding and rounded caps sit only on the outer ends of the whole badge.
        local left = row == first_row and edge(group, true) or {}
        local right = row == last_row and edge(group, false) or {}
        if #left > 0 then
          vim.api.nvim_buf_set_extmark(buf, ns, row, first, {
            virt_text = left, virt_text_pos = "inline", priority = 1000,
          })
        end
        if #right > 0 then
          vim.api.nvim_buf_set_extmark(buf, ns, row, last, {
            virt_text = right, virt_text_pos = "inline", priority = 1000,
          })
        end
      end
    end
  end
  if next_call then
    vim.api.nvim_buf_set_extmark(buf, ns, last_row, 0, {
      virt_text = { folded and { "  <- folded (a+ to open)", "CodeTourFoldedLabel" } or done and { "  <- visited", "CodeTourDoneLabel" }
        or { current ~= false and "  <- next snippet" or "  <- later snippet", current and "CodeTourCurrentLabel" or "CodeTourNextLabel" } }, virt_text_pos = "eol", priority = 1000,
    })
  end
end

return M
