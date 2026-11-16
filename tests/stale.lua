-- Default saved-open behavior: unchanged unchecked prose is reused, and the
-- remaining regeneration targets travel in batched requests.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME or vim.fn.expand("~/.local/share/nvim/site"))
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = root .. "/state", root .. "/cache"
vim.env.XDG_DATA_HOME = root .. "/data"
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
local sent = {}
require("code-tour.conversation").deliver = function(_, _root, prompt, action, callback)
  sent[#sent + 1] = { prompt = prompt, action = action }
  callback(true)
end
local tour, source, saved, library =
  require("tour"), require("code-tour.source"), require("code-tour.saved"), require("code-tour.library")
local checks = 0
local function check(value, message)
  assert(value, message)
  checks = checks + 1
end
local function state()
  return tour.state()
end
local function active()
  vim.wait(10, function()
    return false
  end, 1)
  return state().saved.active
end
local function stop_for(item)
  local first, last = source.lines(item.capture.range)
  return { box = item.entry.id, file = item.entry.path, start = first, ["end"] = last, note = "Fresh " .. item.entry.id }
end
local original = { "local function main(x)", "  local y = x + 1", "  local z = y * 2", "  return z", "end" }
local notes = {}
vim.notify = function(message, level) notes[#notes + 1] = { message = message, level = level } end
local stale_path = (vim.env.TMPDIR or "/tmp") .. "/code-tour-" .. vim.uv.getuid() .. "/%ID%.stale.json"
local function run()
  vim.fn.mkdir(root .. "/app/.git", "p")
  vim.fn.writefile(original, root .. "/app/main.lua")
  tour.setup({ smooth_scroll = false })
  tour.show({ {
    file = "main.lua", start = 1, ["end"] = 5, title = "Main", note = "Authored overview",
    parts = {
      { start = 1, ["end"] = 2, note = "Authored first" },
      { start = 3, ["end"] = 3, note = "Authored middle" },
      { start = 4, ["end"] = 5, note = "Authored last" },
    },
  } }, { root = root .. "/app" })
  local first = tour.save_saved({ title = "Stale journey" })
  stale_path = stale_path:gsub("%%ID%%", first.id)
  check(not table.concat(vim.fn.glob(library.directory() .. "/*.json", false, true), ""):find("stale", 1, true), "Library stays free of sidecars")
  tour.open_saved(first.id)
  check(not active(), "Unchanged tour has nothing stale")
  local buf = state().stops[1].buf
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  local z = y * 3" })
  vim.api.nvim_exec_autocmds("BufEnter", {})
  local warned = vim.tbl_filter(function(n) return n.message:find("Stale explanation", 1, true) end, notes)
  check(#warned == 1 and warned[1].level == vim.log.levels.WARN, "Stale boxes raise one warning")
  check(warned[1].message:find("1.3", 1, true) and warned[1].message:find("1.1", 1, true), "Warning names stale and linked boxes")
  vim.api.nvim_exec_autocmds("BufEnter", {})
  check(#vim.tbl_filter(function(n) return n.message:find("Stale explanation", 1, true) end, notes) == 1, "Same staleness warns once")
  local report = vim.json.decode(table.concat(vim.fn.readfile(stale_path), "\n"))
  local by_id = {}
  for _, item in ipairs(report.stale) do by_id[item.id] = item end
  check(by_id["1.3"] and by_id["1.3"].start == 3 and by_id["1.3"].saved_id, "Report identifies the stale part")
  check(by_id["1.3"].update_also[1].relation == "overview" and by_id["1.3"].update_also[1].id == "1.1", "Report links the overview")
  -- The saved file marks the stale prose.
  local saved_file = library.read(tour.save_saved().id)
  check(saved_file.stops[1].parts[2].evidence.reason == "Source changed before save", "Saved file flags stale boxes")
  -- Requests cite the stale report.
  tour.next_explanation(1)
  tour.ask("Why?", "stay")
  check(sent[#sent].prompt:find("Stale: 1.1, 1.3", 1, true), "Requests list stale boxes and the report path")
  -- Regenerating the stale box refreshes the linked overview in the same batch.
  tour.next_explanation(1)
  tour.explain()
  local request = active()
  check(request and #request.items == 2, "Stale box and linked overview share one request")
  check(sent[#sent].prompt:find("Linked: update because 1.3 (overview) changed", 1, true), "Linked box says why it is regenerated")
  local items = {}
  for _, item in ipairs(request.items) do
    local a, b = source.lines(item.capture.range)
    items[#items + 1] = { box = item.entry.id, file = item.entry.path, start = a, ["end"] = b, note = "Fresh " .. item.entry.id }
  end
  tour.fill(request.id, items)
  vim.api.nvim_exec_autocmds("BufEnter", {})
  check(not vim.uv.fs_stat(stale_path), "Report is removed once nothing is stale")
  check(not table.concat(vim.fn.glob(library.directory() .. "/*.json", false, true), ""):find("stale", 1, true), "Library still has no sidecars")
end
local ok, err = pcall(run)
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("PASS: " .. checks .. " stale explanation checks")
