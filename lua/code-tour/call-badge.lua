local M = {}

-- Named palettes for the next and visited badges, for trying colours with M.cycle().
-- { name, next_bg, next_fg, visited_bg, visited_fg }
M.palettes = {
  { "cyan / grey", "#4fc1d9", "#06222a", "#4a4f5a", "#aab0bd" },
  { "orange / green", "#f2994a", "#2a1704", "#3f6b4a", "#bfe3c8" },
  { "lime / slate", "#a6e22e", "#1a2606", "#44506a", "#b9c3d9" },
  { "pink / teal", "#ff79c6", "#2b0a1d", "#2f6f6a", "#c3ebe7" },
  { "sky / sand", "#7ab8ff", "#08203d", "#6b6250", "#e6dcc3" },
  { "mint / maroon", "#5ee6b0", "#052b1d", "#7a3a48", "#f0cdd4" },
  { "yellow / indigo", "#ffe066", "#2e2504", "#4b4a8f", "#d6d5f5" },
  { "coral / steel", "#ff7f6b", "#2e0d07", "#566f8a", "#d3e0ee" },
}
local DEFAULT_PALETTE = "sky / sand"
local palette = 0 -- index into M.palettes; 0 = colours derived from the colorscheme

local function find_palette(name)
  if name == "theme" then return 0 end
  for i, p in ipairs(M.palettes) do if p[1] == name then return i end end
end


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
  local name = opts.palette == nil and DEFAULT_PALETTE or opts.palette
  local found = find_palette(name)
  assert(found, "badge.palette must be \"theme\" or one of the names in require(\"code-tour.call-badge\").palettes")
  palette = found
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

local function apply_palette()
  local p = M.palettes[palette]
  if not p then return end
  local function set(name, spec) vim.api.nvim_set_hl(0, name, spec) end
  set("CodeTourCurrentCall", { fg = p[3], bg = p[2], bold = true })
  set("CodeTourCurrentLabel", { fg = p[2], bold = true })
  set("CodeTourDoneCall", { fg = p[5], bg = p[4], bold = true })
  set("CodeTourDoneLabel", { fg = p[4], bold = true })
  refresh_caps()
end

-- Step through the palettes (step = 1 or -1); the slot before the first is the theme-derived
-- default. Returns the active palette's name.
function M.cycle(step)
  palette = (palette + (step or 1)) % (#M.palettes + 1)
  M.highlight()
  return palette == 0 and "theme" or M.palettes[palette][1]
end

-- Select a palette by name ("theme" for the colorscheme-derived default); false if unknown.
function M.select(name)
  local found = find_palette(name)
  if not found then return false end
  palette = found
  M.highlight()
  return true
end

-- Badge colours are derived from the active colorscheme: accent colours come from its
-- diagnostic groups, text and muted tones from Normal and Comment. tour.lua re-runs it on ColorScheme.
function M.highlight()
  local normal_bg = theme("Normal", "bg", vim.o.background == "light" and 0xffffff or 0x1a1b26)
  local normal_fg = theme("Normal", "fg", vim.o.background == "light" and 0x1a1b26 or 0xc0caf5)
  local muted = theme("Comment", "fg", blend(normal_bg, normal_fg, 0.5))
  local info = theme("DiagnosticInfo", "fg", 0x4fc1d9)
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
  solid("CodeTourCurrentCall", info)              -- the call the walk takes next
  set("CodeTourCurrentLabel", { fg = info, bold = true })
  set("CodeTourNextLabel", { fg = warn, bold = true })
  soft("CodeTourDoneCall", muted, 0.35)           -- visited
  set("CodeTourDoneLabel", { fg = muted, bold = true })
  soft("CodeTourFoldedCall", warn, 0.25)
  set("CodeTourFoldedLabel", { fg = blend(normal_bg, warn, 0.6) })
  refresh_caps()
  apply_palette()
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
