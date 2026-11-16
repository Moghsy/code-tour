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
local original = {
  "local function main(x)",
  "  local y = x + 1",
  "  local z = y * 2",
  "  return z",
  "end",
}
local function run()
  vim.fn.mkdir(root .. "/app/.git", "p")
  local path = root .. "/app/main.lua"
  vim.fn.writefile(original, path)
  tour.setup({ smooth_scroll = false })
  local function show()
    tour.show({
      {
        file = "main.lua",
        start = 1,
        ["end"] = 5,
        title = "Main",
        note = "Authored overview",
        parts = {
          { start = 1, ["end"] = 2, note = "Authored first" },
          { start = 3, ["end"] = 3, note = "Authored middle" },
          { start = 4, ["end"] = 5, note = "Authored last" },
        },
      },
    }, { root = root .. "/app" })
  end
  show()
  local first = tour.save_saved({ title = "Batch journey" })
  check(library.read(first.id).stops[1].overview.evidence.reason == saved.UNCHECKED, "Authored prose saves unchecked")

  -- Unchanged unchecked boxes open ready without any request.
  local opened = tour.open_saved(first.id)
  check(opened.counts.ready == 4 and opened.reused_unverified == 4 and not active(), "Unchanged boxes are reused")
  check(#sent == 0, "No regeneration prompt for unchanged code")
  check(state().stops[1].note == "Authored overview", "Reused prose is displayed")
  check(state().saved.entries[3].reused, "Entry records unchecked reuse")

  -- Editing a reused box withholds it like any other stale note.
  local buf = state().stops[1].buf
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  local z = y * 3" })
  saved.revalidate(state())
  local middle = state().saved.entries[3]
  check(middle.status == "source_changed", "Edited reused box becomes unavailable")
  check(state().saved.entries[2].status == "ready", "Untouched reused sibling stays ready")

  -- Saving cannot rebind withheld prose to the edited code.
  local stale = library.read(tour.save_saved().id)
  check(stale.stops[1].parts[2].evidence.reason ~= saved.UNCHECKED, "Withheld note is not reusable after save")
  tour.open_saved(stale.id)
  check(active() and #active().items >= 1, "Stale-at-save box regenerates on open")
  tour.cancel()

  -- Changed code queues only the changed boxes, batched into one request.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  tour.open_saved(first.id)
  check(not active(), "Restored code is reusable again")
  vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "  local y = x + 5" })
  vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  return z + 0" })
  local changed = tour.open_saved(first.id)
  local request = active()
  check(changed.reused_unverified == 1 and #request.items == 3, "One batch carries every changed box")
  check(sent[#sent].prompt:find("[code-tour saved regeneration batch] tour: ", 1, true), "Batch prompt is used")
  check(select(2, sent[#sent].prompt:gsub("## Box: ", "")) == 3, "Prompt lists each box once")
  check(not sent[#sent].prompt:find("Authored", 1, true), "Batch prompt omits old prose")

  -- A partial reply accepts what it covers and fails omitted boxes.
  local result = tour.fill(request.id, { stop_for(request.items[1]), stop_for(request.items[3]) })
  check(result.count == 2 and #result.failed == 1, "Partial batch reply reports omitted box")
  check(request.items[1].entry.status == "ready" and request.items[2].entry.status == "failed", "Per-box outcome")
  check(not active() and state().saved.entries[3].status == "ready", "Unchanged middle box stayed reused")

  -- Per-box validation: one bad stop does not reject its siblings.
  local retry = tour.open_saved(first.id)
  check(retry.counts.generating == 3, "Reopen queues changed boxes again")
  request = active()
  local bad = stop_for(request.items[2])
  bad["end"] = bad["end"] + 1
  result = tour.fill(request.id, { stop_for(request.items[1]), bad, stop_for(request.items[3]) })
  check(result.count == 2 and result.failed[1].box == request.items[2].entry.id, "Bad stop fails only its box")
  check(not pcall(tour.fill, request.id, { stop_for(request.items[1]) }), "Completed batch rejects late replies")

  -- Batched stops must name their box; unknown and duplicate boxes are rejected.
  tour.open_saved(first.id)
  request = active()
  local unnamed = stop_for(request.items[1])
  unnamed.box = nil
  check(not pcall(tour.fill, request.id, { unnamed }), "Unnamed stop in a batch is rejected")
  check(not active(), "Fully rejected batch completes")
  tour.open_saved(first.id)
  request = active()
  local foreign = stop_for(request.items[1])
  foreign.box = "not-a-box"
  result = tour.fill(request.id, { stop_for(request.items[1]), stop_for(request.items[1]), foreign })
  check(result.count == 1 and #result.failed == 4, "Duplicate and foreign stops fail; omitted boxes reported")

  -- Size and byte budgets split large queues.
  state().opts.saved_batch_size = 2
  tour.open_saved(first.id)
  check(#active().items == 2, "Batch size caps a request")
  local split = active()
  tour.fill(split.id, { stop_for(split.items[1]), stop_for(split.items[2]) })
  check(active() and #active().items == 1, "Remaining boxes follow in the next batch")
  local single = active()
  check(single.entry and sent[#sent].prompt:find("[code-tour saved regeneration] tour: ", 1, true), "Singletons keep the one-box contract")
  local one = stop_for(single)
  one.box = nil
  check(tour.fill(single.id, { one }).box == single.entry.id, "Singleton reply needs no box ID")
  state().opts.saved_batch_size, state().opts.saved_batch_chars = 12, 1
  tour.open_saved(first.id)
  check(#active().items == 1, "Byte budget still sends at least one box")
  tour.cancel()
  state().opts.saved_batch_chars = 40000

  -- Reuse can be disabled.
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, original)
  state().opts.saved_reuse_unverified = false
  local strict = tour.open_saved(first.id)
  check(strict.reused_unverified == 0 and strict.counts.generating == 4, "Disabled reuse regenerates every unchecked box")
  request = active()
  local stopsreply = {}
  for _, item in ipairs(request.items) do
    stopsreply[#stopsreply + 1] = stop_for(item)
  end
  tour.fill(request.id, stopsreply)
  local verified = library.read(tour.save_saved().id)
  check(verified.stops[1].overview.evidence.status == "verified", "Batched replies save as verified")
  state().opts.saved_reuse_unverified = true
  check(tour.open_saved(verified.id).counts.ready == 4 and not active(), "Verified reopen needs no requests")
  -- Parserless sources fall back to whole-file identity.
  vim.fn.writefile({ "opaque syntax" }, root .. "/app/unknown.custom")
  tour.show({ { file = "unknown.custom", start = 1, ["end"] = 1, note = "Opaque prose" } }, { root = root .. "/app" })
  local opaque = tour.save_saved()
  local reopened = tour.open_saved(opaque.id)
  check(reopened.reused_unverified == 1 and not active(), "Unchanged parserless box is reused")
  vim.api.nvim_buf_set_lines(state().stops[1].buf, 0, -1, false, { "changed opaque syntax" })
  saved.revalidate(state())
  check(state().saved.entries[1].status ~= "ready", "Changed parserless file withholds reused prose")
  tour.stop()
end
local ok, err = xpcall(run, debug.traceback)
saved.cancel(state())
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("PASS: " .. checks .. " batched saved checks")
