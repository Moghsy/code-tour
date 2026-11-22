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

-- Highlight for a cap: the badge colour as foreground, over the background enclosing the
-- badge (the line, or an outer badge) when `line_bg` is given, so the corner blends in.
local function cap_group(group, line_bg)
  local name = group .. "Cap" .. (line_bg and string.format("%06x", line_bg) or "")
  local background = vim.api.nvim_get_hl(0, { name = group, link = false }).bg
  vim.api.nvim_set_hl(0, name, { fg = background, bg = line_bg })
  return name
end

-- Background behind (row, col): the highest-priority highlight below `below` that covers it.
-- Line backgrounds are `hl_eol` ranges, so enclosing badges and the focus range count too.
local function background(buf, ns, row, col, below)
  local best, priority
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true, overlap = true })
  for _, mark in ipairs(marks) do
    local d = mark[4]
    local p = d.priority or 0
    if d.hl_group and p < below and (not priority or p >= priority) then
      local after_start = mark[2] < row or (mark[2] == row and mark[3] <= col)
      local end_row, end_col = d.end_row or mark[2], d.end_col or mark[3]
      local before_end = end_row > row or (end_row == row and col < end_col)
      local bg = vim.api.nvim_get_hl(0, { name = d.hl_group, link = false }).bg
      if after_start and before_end and bg then best, priority = bg, p end
    end
  end
  return best
end

M.STAR = "★"

-- Virtual text at one end of a badge. Left: cap, padding, then the main-flow star when
-- `star` is set. Right: padding then cap.
local function edge(group, left, line_bg, star)
  local cap = config.rounded and { vim.fn.nr2char(left and 0xe0b6 or 0xe0b4), cap_group(group, line_bg) } or nil
  local pad = config.padding > 0 and { string.rep(" ", config.padding), group } or nil
  local chunks = {}
  local function add(chunk) if chunk then chunks[#chunks + 1] = chunk end end
  if left then add(cap); add(pad); add(star and { M.STAR .. " ", group } or nil) else add(pad); add(cap) end
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
  "CodeTourCall", "CodeTourNextCall", "CodeTourMainCall", "CodeTourCurrentCall", "CodeTourDoneCall",
  "CodeTourFoldedCall", "CodeTourGap",
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
  local hint = theme("DiagnosticHint", "fg", 0x1abc9c)
  local function set(name, spec) vim.api.nvim_set_hl(0, name, spec) end
  -- Solid accent badges use the background colour for text so they read in any scheme.
  local function solid(name, accent) set(name, { fg = normal_bg, bg = accent, bold = true }) end
  local function soft(name, accent, strength)
    set(name, { fg = normal_fg, bg = blend(normal_bg, accent, strength), bold = true })
  end
  soft("CodeTourCall", err, 0.45)                 -- optional call
  solid("CodeTourNextCall", warn)                 -- later gold call
  -- Main flow (SPEC-ast-graph §10): a stronger gold, the theme's warning pulled toward a
  -- deep amber, so it stands apart from the other gold calls even before the ★ is read.
  solid("CodeTourMainCall", blend(warn, 0xff9e00, 0.6))
  set("CodeTourMainLabel", { fg = blend(warn, 0xff9e00, 0.6), bold = true })
  -- Next and visited use fixed colours (sky / sand), the same in every colorscheme.
  set("CodeTourCurrentCall", { fg = "#08203d", bg = "#7ab8ff", bold = true })  -- the call the walk takes next
  set("CodeTourCurrentLabel", { fg = "#7ab8ff", bold = true })
  set("CodeTourNextLabel", { fg = warn, bold = true })
  set("CodeTourDoneCall", { fg = "#e6dcc3", bg = "#6b6250", bold = true })      -- visited
  set("CodeTourDoneLabel", { fg = "#6b6250", bold = true })
  soft("CodeTourFoldedCall", warn, 0.25)
  set("CodeTourFoldedLabel", { fg = blend(normal_bg, warn, 0.6) })
  -- A gap: where the main flow breaks off (§8.3). The hint accent, italic, so it reads as
  -- a remark about the code rather than a call to follow.
  set("CodeTourGap", { fg = normal_fg, bg = blend(normal_bg, hint, 0.4), bold = true, italic = true })
  set("CodeTourGapLabel", { fg = hint, italic = true })
  refresh_caps()
end

function M.range(buf, site)
  if not site then return end
  if site.start_col ~= nil then
    return { site.start - 1, site.start_col, site["end"] - 1, site.end_col }
  end
  if not site.symbol or site.symbol == "" then return end
  for line = site.start, site["end"] or site.start do
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

-- A main-flow call keeps the walk's colours for its state (current, visited, folded), so
-- the walk reads the same on and off the main flow; only a main call still waiting its
-- turn gets the stronger gold in place of the plain gold. The ★ shows in every state.
local function group_for(item)
  if item.gap then return "CodeTourGap" end
  return item.current and "CodeTourCurrentCall" or item.done and "CodeTourDoneCall"
    or item.folded and "CodeTourFoldedCall" or item.next_call and (item.main and "CodeTourMainCall" or "CodeTourNextCall")
    or "CodeTourCall"
end

local function label_for(item)
  if item.gap then
    return "  <- gap" .. (type(item.gap) == "string" and item.gap ~= "" and (": " .. item.gap) or ""), "CodeTourGapLabel"
  end
  if item.folded then return "  <- folded (a+ to open)", "CodeTourFoldedLabel" end
  if item.done then return "  <- visited", "CodeTourDoneLabel" end
  return item.current ~= false and "  <- next snippet" or "  <- later snippet",
    item.current and "CodeTourCurrentLabel" or item.main and "CodeTourMainLabel" or "CodeTourNextLabel"
end

-- Draw every badge of a buffer in one pass. Each item is { range = { first_row, first_col,
-- last_row, last_col }, next_call, current, done, folded, main, gap }: `next_call` marks a
-- gold call, `current` the gold call the walk takes next, `main` a gold call on the main
-- flow (★ after the left cap), and `gap` (the reason, or true) a site where the main flow
-- breaks off; a gap is not a call, so it takes no walk state.
--
-- A badge is a plain `hl_group` range, so the source text stays real text and several badges
-- can share a line, sit side by side or nest. Outer badges get lower priorities than the
-- badges inside them, so the innermost colour wins. Caps and padding are inline virtual text
-- at the outer ends; Neovim draws inline marks on one column in ascending priority, so a
-- badge closing on a column comes before one opening there, inner badges close first and
-- outer badges open first. Each cap blends into whatever encloses the badge.
function M.draw_all(buf, ns, items)
  local badges = {}
  for _, item in ipairs(items) do
    local r = item.range
    local count = vim.api.nvim_buf_line_count(buf)
    if r and r[1] < count then
      local last_row = math.min(r[3], count - 1)
      local first_line = vim.api.nvim_buf_get_lines(buf, r[1], r[1] + 1, false)[1]
      local last_line = vim.api.nvim_buf_get_lines(buf, last_row, last_row + 1, false)[1]
      local first_col = math.min(r[2], #first_line)
      local last_col = last_row == r[3] and math.min(r[4], #last_line) or #last_line
      if last_row > r[1] or last_col > first_col then
        badges[#badges + 1] = { item = item, first_row = r[1], first_col = first_col,
          last_row = last_row, last_col = last_col }
      end
    end
  end
  -- Depth: how many other badges enclose this one (identical ranges stack in input order).
  local function encloses(a, b)
    local starts = a.first_row < b.first_row or (a.first_row == b.first_row and a.first_col <= b.first_col)
    local ends = a.last_row > b.last_row or (a.last_row == b.last_row and a.last_col >= b.last_col)
    return starts and ends
  end
  for i, b in ipairs(badges) do
    b.depth = 0
    for j, other in ipairs(badges) do
      if i ~= j and encloses(other, b) and (not encloses(b, other) or j < i) then b.depth = b.depth + 1 end
    end
  end
  table.sort(badges, function(a, b)
    if a.depth ~= b.depth then return a.depth < b.depth end
    if a.first_row ~= b.first_row then return a.first_row < b.first_row end
    return a.first_col < b.first_col
  end)
  -- Highlights first, so caps can see every enclosing badge's colour.
  for i, b in ipairs(badges) do
    b.group, b.priority = group_for(b.item), 1000 + i
    vim.api.nvim_buf_set_extmark(buf, ns, b.first_row, b.first_col, {
      end_row = b.last_row, end_col = b.last_col, hl_group = b.group, priority = b.priority,
    })
  end
  for i, b in ipairs(badges) do
    local star = b.item.main and b.item.next_call and not b.item.gap
    local left = edge(b.group, true, background(buf, ns, b.first_row, b.first_col, b.priority), star)
    local right = edge(b.group, false, background(buf, ns, b.last_row, math.max(b.last_col - 1, 0), b.priority))
    if #left > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, b.first_row, b.first_col, {
        virt_text = left, virt_text_pos = "inline", priority = 3000 + i,
      })
    end
    if #right > 0 then
      vim.api.nvim_buf_set_extmark(buf, ns, b.last_row, b.last_col, {
        virt_text = right, virt_text_pos = "inline", priority = 2999 - i,
      })
    end
  end
  -- One end-of-line label per row, listing that row's gold calls and gaps left to right.
  local labels, rows = {}, {}
  table.sort(badges, function(a, b)
    if a.last_row ~= b.last_row then return a.last_row < b.last_row end
    return a.first_col < b.first_col
  end)
  for _, b in ipairs(badges) do
    if b.item.next_call or b.item.gap then
      if not labels[b.last_row] then labels[b.last_row], rows[#rows + 1] = {}, b.last_row end
      local text, group = label_for(b.item)
      labels[b.last_row][#labels[b.last_row] + 1] = { text, group }
    end
  end
  for _, row in ipairs(rows) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_text = labels[row], virt_text_pos = "eol", priority = 1000 })
  end
end

-- Draw a single badge (see draw_all).
function M.draw(buf, ns, first_row, first_col, last_row, last_col, next_call, current, done, folded)
  M.draw_all(buf, ns, { {
    range = { first_row, first_col, last_row, last_col },
    next_call = next_call, current = current, done = done, folded = folded,
  } })
end

return M
