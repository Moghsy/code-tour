vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local badge = require("code-tour.call-badge")
badge.highlight()
local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
local ns = vim.api.nvim_create_namespace("badge-test")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local x = handler(event)", "second line" })
local function inline()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if m[4].virt_text_pos == "inline" then
      local text = {}
      for _, c in ipairs(m[4].virt_text) do text[#text + 1] = c[1] end
      out[#out + 1] = { row = m[2], col = m[3], text = table.concat(text) }
    end
  end
  table.sort(out, function(a, b) return a.row == b.row and a.col < b.col or a.row < b.row end)
  return out
end
-- defaults: rounded caps, no padding
badge.draw(buf, ns, 0, 10, 0, 17, true, true)
local got = inline()
assert(#got == 2, vim.inspect(got))
assert(got[1].col == 10 and got[1].text == vim.fn.nr2char(0xe0b6), vim.inspect(got[1]))
assert(got[2].col == 17 and got[2].text == vim.fn.nr2char(0xe0b4), vim.inspect(got[2]))
assert(vim.api.nvim_get_hl(0, { name = "CodeTourCurrentCallCap" }).fg == vim.api.nvim_get_hl(0, { name = "CodeTourCurrentCall" }).bg)
-- no rounding, two cells of padding
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
badge.configure({ padding = 2, rounded = false })
badge.draw(buf, ns, 0, 10, 0, 17, false, nil)
got = inline()
assert(got[1].text == "  " and got[2].text == "  ", vim.inspect(got))
-- nothing inline when disabled
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
badge.configure({ padding = 0, rounded = false })
badge.draw(buf, ns, 0, 10, 0, 17, false, nil)
assert(#inline() == 0)
-- a multi-line badge is capped only on its outer ends
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
badge.configure({})
badge.draw(buf, ns, 0, 10, 1, 6, false, nil)
got = inline()
assert(#got == 2 and got[1].row == 0 and got[1].col == 10 and got[2].row == 1 and got[2].col == 6, vim.inspect(got))
assert(not pcall(badge.configure, { padding = -1 }))

-- several badges on one line: nested, adjacent and separate
vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "y = outer(inner(z)) + aa(1)bb(2)" })
vim.api.nvim_set_hl(0, "BadgeTestLine", { bg = 0x303050 })
vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_row = 1, end_col = 0, hl_group = "BadgeTestLine", hl_eol = true, priority = 100 })
badge.draw_all(buf, ns, {
  { range = { 0, 10, 0, 18 }, next_call = true, current = true }, -- inner(z), listed before its parent
  { range = { 0, 4, 0, 19 } },                                    -- outer(inner(z))
  { range = { 0, 22, 0, 27 }, next_call = true, done = true },    -- aa(1)
  { range = { 0, 27, 0, 32 }, next_call = true, current = false }, -- bb(2)
})
local ranges, caps, labels = {}, {}, {}
for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
  local d = m[4]
  if d.hl_group and d.hl_group:match("Call$") then
    assert(not d.virt_text, "badges highlight the source text instead of painting over it")
    ranges[m[3]] = { group = d.hl_group, priority = d.priority, end_col = d.end_col }
  elseif d.virt_text_pos == "inline" then
    caps[#caps + 1] = { col = m[3], priority = d.priority, group = d.virt_text[1][2] }
  elseif d.virt_text_pos == "eol" then
    labels[#labels + 1] = d.virt_text
  end
end
assert(ranges[4].priority < ranges[10].priority, "the inner badge outranks the badge around it")
assert(ranges[10].group == "CodeTourCurrentCall" and ranges[4].group == "CodeTourCall")
-- caps blend into what encloses them: the outer badge for the inner one, the line otherwise
local function cap_bg(col, group)
  for _, c in ipairs(caps) do
    if c.col == col and c.group:find("^" .. group .. "Cap") then return hl(c.group).bg end
  end
end
assert(cap_bg(10, "CodeTourCurrentCall") == hl("CodeTourCall").bg, "inner cap blends into the outer badge")
assert(cap_bg(18, "CodeTourCurrentCall") == hl("CodeTourCall").bg)
assert(cap_bg(4, "CodeTourCall") == 0x303050 and cap_bg(19, "CodeTourCall") == 0x303050, "outer caps blend into the line")
-- adjacent badges: exactly one closing and one opening cap where they meet, closing first
local meet = {}
for _, c in ipairs(caps) do if c.col == 27 then meet[#meet + 1] = c end end
table.sort(meet, function(a, b) return a.priority < b.priority end)
assert(#meet == 2 and meet[1].group:find("^CodeTourDoneCallCap") and meet[2].group:find("^CodeTourNextCallCap"), vim.inspect(meet))
-- one label per row, in column order
assert(#labels == 1 and #labels[1] == 3, vim.inspect(labels))
assert(labels[1][1][1]:find("next snippet") and labels[1][2][1]:find("visited") and labels[1][3][1]:find("later snippet"))
print("badge OK")

-- accents follow the colorscheme and are re-derived when it changes; next/visited are fixed
vim.cmd("colorscheme habamax")
badge.highlight()
local warn = hl("DiagnosticWarn").fg
assert(hl("CodeTourNextCall").bg == warn and hl("CodeTourNextCall").fg == hl("Normal").bg)
assert(hl("CodeTourCurrentCall").bg == tonumber("7ab8ff", 16) and hl("CodeTourCurrentCall").fg == tonumber("08203d", 16))
assert(hl("CodeTourDoneCall").bg == tonumber("6b6250", 16) and hl("CodeTourDoneCall").fg == tonumber("e6dcc3", 16))
local red = hl("CodeTourCall").bg
vim.cmd("colorscheme default")
vim.cmd("set background=light")
badge.highlight()
assert(hl("CodeTourCall").bg ~= red, "optional badge colour did not follow the colorscheme")
assert(hl("CodeTourNextCall").bg == hl("DiagnosticWarn").fg)
assert(hl("CodeTourCurrentCall").bg == tonumber("7ab8ff", 16), "next colour stays fixed across colorschemes")
-- every cap matches its badge, even after a colorscheme change wipes the groups
vim.cmd("colorscheme habamax")
badge.highlight()
for _, group in ipairs({ "CodeTourCall", "CodeTourNextCall", "CodeTourCurrentCall", "CodeTourDoneCall", "CodeTourFoldedCall" }) do
  assert(hl(group .. "Cap").fg == hl(group).bg, group .. " cap does not match its badge")
end
print("badge theme OK")
