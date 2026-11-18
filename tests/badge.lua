vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
local badge = require("code-tour.call-badge")
badge.highlight()
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
-- defaults: rounded caps plus one cell of padding at both ends
badge.draw(buf, ns, 0, 10, 0, 17, true, true)
local got = inline()
assert(#got == 2, vim.inspect(got))
assert(got[1].col == 10 and got[1].text == vim.fn.nr2char(0xe0b6) .. " ", vim.inspect(got[1]))
assert(got[2].col == 17 and got[2].text == " " .. vim.fn.nr2char(0xe0b4), vim.inspect(got[2]))
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
print("badge OK")

-- colours follow the colorscheme and are re-derived when it changes
badge.configure({ palette = "theme" })
vim.cmd("colorscheme habamax")
badge.highlight()
local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end
local info = hl("DiagnosticInfo").fg
assert(hl("CodeTourCurrentCall").bg == info and hl("CodeTourCurrentLabel").fg == info)
assert(hl("CodeTourCurrentCall").fg == hl("Normal").bg)
local first = hl("CodeTourDoneCall").bg
vim.cmd("colorscheme default")
vim.cmd("set background=light")
badge.highlight()
assert(hl("CodeTourDoneCall").bg ~= first, "visited colour did not follow the colorscheme")
assert(hl("CodeTourCurrentCall").bg == hl("DiagnosticInfo").fg)
print("badge theme OK")

-- the default is the sky / sand palette
badge.configure({})
badge.highlight()
assert(hl("CodeTourCurrentCall").bg == tonumber("7ab8ff", 16) and hl("CodeTourDoneCall").bg == tonumber("6b6250", 16), "default palette is sky / sand")
assert(not pcall(badge.configure, { palette = "nope" }))
badge.configure({ palette = "theme" })

-- manual palette cycling: next/prev wrap, caps follow, theme slot restores derived colours
vim.cmd("colorscheme habamax")
badge.highlight()
local derived = hl("CodeTourCurrentCall").bg
assert(badge.cycle(1) == "cyan / grey")
assert(hl("CodeTourCurrentCall").bg == tonumber("4fc1d9", 16))
assert(hl("CodeTourCurrentCallCap").fg == tonumber("4fc1d9", 16), "cap does not match the badge colour")
assert(hl("CodeTourDoneCallCap").fg == hl("CodeTourDoneCall").bg)
assert(badge.cycle(1) == "orange / green")
assert(badge.cycle(-1) == "cyan / grey")
assert(badge.cycle(-1) == "theme" and hl("CodeTourCurrentCall").bg == derived)
assert(badge.cycle(-1) == "coral / steel", "wraps backwards past the theme slot")
vim.api.nvim_exec_autocmds("ColorScheme", {})
badge.highlight() -- a colorscheme change keeps the chosen palette
assert(hl("CodeTourCurrentCall").bg == tonumber("ff7f6b", 16))
assert(badge.select("theme") and hl("CodeTourCurrentCall").bg == derived)
assert(badge.select("mint / maroon") and hl("CodeTourDoneCall").bg == tonumber("7a3a48", 16))
assert(badge.select("nope") == false and hl("CodeTourDoneCall").bg == tonumber("7a3a48", 16), "unknown palette keeps the current one")
print("badge cycle OK")
