local M = {}

-- Padding (in cells) inside each end of a badge, and rounded end caps. The caps are the
-- Powerline half-circle glyphs, so they need a Nerd Font; set `rounded = false` otherwise.
local config = { padding = 0, rounded = true }

function M.configure(opts)
  opts = opts or {}
  config = { padding = 0, rounded = true }
  if opts.padding ~= nil then
    assert(type(opts.padding) == "number" and opts.padding >= 0, "badge.padding must be a non-negative number")
    config.padding = math.floor(opts.padding)
  end
  if opts.rounded ~= nil then config.rounded = opts.rounded and true or false end
end

-- Highlight for a cap: the badge colour as foreground, over the line's background (so the
-- rounded corner blends into the line) when `line_bg` is given.
local function cap_group(group, line_bg)
  local name = group .. "Cap" .. (line_bg and string.format("%06x", line_bg) or "")
  local background = vim.api.nvim_get_hl(0, { name = group, link = false }).bg
  vim.api.nvim_set_hl(0, name, { fg = background, bg = line_bg })
  return name
end

-- Background the tour draws behind a row: its highest-priority line highlight, if any.
local function line_background(buf, ns, row)
  local best, priority
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })) do
    local details = mark[4]
    if details.line_hl_group and (not priority or (details.priority or 0) >= priority) then
      best, priority = details.line_hl_group, details.priority or 0
    end
  end
  return best and vim.api.nvim_get_hl(0, { name = best, link = false }).bg or nil
end

-- Virtual text at one end of a badge. Left: cap then padding. Right: padding then cap.
local function edge(group, left, line_bg)
  local cap = config.rounded and { vim.fn.nr2char(left and 0xe0b6 or 0xe0b4), cap_group(group, line_bg) } or nil
  local pad = config.padding > 0 and { string.rep(" ", config.padding), group } or nil
  local chunks = {}
  local function add(chunk) if chunk then chunks[#chunks + 1] = chunk end end
  if left then add(cap); add(pad) else add(pad); add(cap) end
  return chunks
end

local function channels(color) return math.floor(color / 65536) % 256, math.floor(color / 256) % 256, color % 256 end

-- Mix `from` toward `to` by `amount` (0..1), both 24-bit colours.
local function blend(from, to, amount)
  local fr, fg, fb = channels(from)
  local tr, tg, tb = channels(to)
  local function mix(a, b) return math.floor(a + (b - a) * amount + 0.5) end
  return mix(fr, tr) * 65536 + mix(fg, tg) * 256 + mix(fb, tb)
end

-- Colour of a theme group (`attr` is "fg" or "bg"), or `fallback` when it has none.
local function theme(name, attr, fallback)
  local value = vim.api.nvim_get_hl(0, { name = name, link = false })[attr]
  return value or fallback
end

M.blend, M.theme = blend, theme

local BADGES = {
  "CodeTourCall", "CodeTourNextCall", "CodeTourCurrentCall", "CodeTourDoneCall", "CodeTourFoldedCall",
}

-- Keep every badge's cap group in step with its colour.
local function refresh_caps()
  for _, group in ipairs(BADGES) do cap_group(group) end
end

-- The optional (red), later (gold) and folded badges are derived from the active colorscheme:
-- accents from its diagnostic groups, text from Normal. tour.lua re-runs it on ColorScheme.
function M.highlight()
  local normal_bg = theme("Normal", "bg", vim.o.background == "light" and 0xffffff or 0x1a1b26)
  local normal_fg = theme("Normal", "fg", vim.o.background == "light" and 0x1a1b26 or 0xc0caf5)
  local warn = theme("DiagnosticWarn", "fg", 0xe5b94f)
  local err = theme("DiagnosticError", "fg", 0xf7768e)
  local function set(name, spec) vim.api.nvim_set_hl(0, name, spec) end
  -- Solid accent badges use the background colour for text so they read in any scheme.
  local function solid(name, accent) set(name, { fg = normal_bg, bg = accent, bold = true }) end
  local function soft(name, accent, strength)
    set(name, { fg = normal_fg, bg = blend(normal_bg, accent, strength), bold = true })
  end
  soft("CodeTourCall", err, 0.45)                 -- optional call
  solid("CodeTourNextCall", warn)                 -- later gold call
  -- Next and visited use fixed colours (sky / sand), the same in every colorscheme.
  set("CodeTourCurrentCall", { fg = "#08203d", bg = "#7ab8ff", bold = true })  -- the call the walk takes next
  set("CodeTourCurrentLabel", { fg = "#7ab8ff", bold = true })
  set("CodeTourNextLabel", { fg = warn, bold = true })
  set("CodeTourDoneCall", { fg = "#e6dcc3", bg = "#6b6250", bold = true })      -- visited
  set("CodeTourDoneLabel", { fg = "#6b6250", bold = true })
  soft("CodeTourFoldedCall", warn, 0.25)
  set("CodeTourFoldedLabel", { fg = blend(normal_bg, warn, 0.6) })
  refresh_caps()
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

-- Draw a badge: the call text on a solid background with padding and rounded caps at its
-- outer ends. `next_call` marks a gold call; `current` is the gold call the walk takes next.
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
        -- The badge is drawn as one overlay (cap, padding, text, padding, cap) with hl_mode
        -- "replace", so it beats the tour's line background. Inline virtual text of the same
        -- width sits at the badge ends to reserve those cells, so the source text is pushed
        -- aside instead of being painted over.
        local line_bg = line_background(buf, ns, row)
        local left = row == first_row and edge(group, true, line_bg) or {}
        local right = row == last_row and edge(group, false, line_bg) or {}
        -- Neovim anchors an overlay at column 0 after the inline text, but elsewhere at its
        -- start. At column 0 the overlay therefore holds only the text; the inline pieces
        -- draw their own caps and padding (their explicit colours already beat the line).
        local overlay = {}
        if first > 0 then vim.list_extend(overlay, left) end
        overlay[#overlay + 1] = { line:sub(first + 1, last), group }
        if first > 0 then vim.list_extend(overlay, right) end
        vim.api.nvim_buf_set_extmark(buf, ns, row, first, {
          end_col = last, hl_group = group, priority = 1000,
          virt_text = overlay, virt_text_pos = "overlay", hl_mode = "replace",
        })
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
