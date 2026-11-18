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
