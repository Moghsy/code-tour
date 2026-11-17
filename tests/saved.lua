local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME or vim.fn.expand("~/.local/share/nvim/site"))
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_STATE_HOME, vim.env.XDG_CACHE_HOME = root .. "/state", root .. "/cache"
vim.env.XDG_DATA_HOME = root .. "/data"
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
local sent, fail_delivery = {}, false
require("code-tour.conversation").deliver = function(_, _root, prompt, action, callback)
  sent[#sent + 1] = { prompt = prompt, action = action }
  callback(not fail_delivery, fail_delivery and "transport unavailable" or nil)
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
local function pump()
  vim.wait(10, function()
    return false
  end, 1)
end
local function active()
  pump()
  return state().saved.active
end
local function reply(request, note)
  request = request or assert(active())
  local first, last = source.lines(request.capture.range)
  return tour.fill(
    request.id,
    { { file = request.entry.path, start = first, ["end"] = last, note = note or "Current explanation" } }
  )
end
local function drain()
  local n = 0
  while active() do
    reply()
    n = n + 1
    assert(n < 20)
  end
  return n
end
local function bytes(id)
  return table.concat(vim.fn.readfile(library.directory() .. "/" .. id .. ".json", "b"), "\n")
end
local original = { "local function main(x)", "  local y = helper(x)", "  local z = y + 1", "  return z", "end" }
local function run()
  vim.fn.mkdir(root .. "/app/.git", "p")
  vim.fn.mkdir(root .. "/helpers/.git", "p")
  vim.fn.writefile(original, root .. "/app/main.lua")
  vim.fn.writefile({ "local function helper(x)", "  return x * 2", "end" }, root .. "/helpers/helper.lua")
  -- The sequential, always-regenerate contract stays covered explicitly.
  tour.setup({ smooth_scroll = false, saved_batch_size = 1, saved_reuse_unverified = false })
  tour.show({
    {
      file = "main.lua",
      start = 1,
      ["end"] = 5,
      title = "Main",
      note = "OLD overview",
      _evidence = { status = "verified", digest = "forged" },
      example = { input = "x=1", values = { [2] = "y=2" } },
      parts = {
        {
          start = 1,
          ["end"] = 2,
          note = "OLD first",
          calls = {
            {
              file = root .. "/helpers/helper.lua",
              start = 1,
              ["end"] = 3,
              title = "Helper",
              note = "OLD helper",
              next = true, level = 1,
              callsite = { start = 2, ["end"] = 2, start_col = 12, end_col = 18, symbol = "helper" },
            },
            { file = "main.lua", start = 1, ["end"] = 5, title = "Lazy", lazy = true },
          },
        },
        { start = 3, ["end"] = 5, note = "OLD last" },
      },
    },
  }, { root = root .. "/app" })
  state().stops[1].thread = { { question = "private question", answer = "private answer" } }
  local first = tour.save_saved({ title = "Saved journey" })
  local initial = bytes(first.id)
  local record = library.read(first.id)
  check(record.stops[1].overview.evidence.status == "unverified", "External payload cannot assert host evidence")
  check(
    #first.omitted == 1 and #record.repositories == 2,
    "Export reports lazy omission and captures multiple repositories"
  )
  check(
    not initial:find("private", 1, true) and not initial:find('"example"', 1, true),
    "Only prepared notes/navigation are saved"
  )
  local second = tour.save_saved()
  check(second.id ~= first.id, "Repeated save creates another entry")
  local opened = tour.open_saved(first.id, { origin = { agent = "test" } })
  check(opened.counts.generating == 1 and opened.counts.queued == 3, "All unverified boxes enqueue on open")
  check(#state().stops[1].parts == 2, "Hydration retains authored parts")
  check(not require("code-tour.tour-view").state().text:find("OLD", 1, true), "Old prose is hidden inline")
  check(
    not sent[#sent].prompt:find("OLD", 1, true) and sent[#sent].action == "stay",
    "Regeneration prompt contains only current inputs"
  )
  local overview_request = active()
  local token = state().id
  local position = { state().stop, state().box }
  local other_buf = state().stops[2].buf
  vim.api.nvim_win_set_buf(state().win, other_buf)
  reply(overview_request, "New overview")
  check(
    vim.api.nvim_win_get_buf(state().win) == other_buf,
    "Background replacement preserves manually selected source buffer"
  )
  vim.api.nvim_win_set_buf(state().win, state().stops[1].buf)
  check(state().stops[1].note == "New overview" and #state().stops[1].parts == 2, "Overview-only fill preserves parts")
  check(state().stop == position[1] and state().box == position[2], "Background fill preserves reader position")
  check(drain() == 3, "One sequential request per remaining box")
  check(bytes(first.id) == initial, "Open and regeneration never save")
  local verified = tour.save_saved()
  local checked_record = library.read(verified.id)
  check(
    checked_record.stops[1].overview.evidence.status == "verified",
    "Checked replacements retain generation evidence"
  )
  -- Caller attachments are verified independently of reusable callee prose.
  local main_buf = state().stops[1].buf
  vim.api.nvim_buf_set_lines(main_buf, 1, 2, false, { "  local y = other(x)" })
  tour.open_saved(verified.id)
  local callee = state().stops[2]
  check(
    callee._saved.status == "ready" and not callee.callsite and not callee.next,
    "Invalid caller expression suppresses badges/continuation without losing callee"
  )
  tour.cancel()
  vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, original)
  -- A missing overview has no invented target; located parts retain authored order.
  local incomplete = vim.deepcopy(checked_record)
  incomplete.stops[1].overview.locator.file_digest = string.rep("0", 64)
  incomplete.stops[1].overview.locator.owners[1].name = "missing_owner"
  local incomplete_id = library.write(incomplete).id
  tour.open_saved(incomplete_id)
  check(state().stops[1]._unlocated and state().box == 2, "Part-only hydration skips unavailable overview")
  check(require("code-tour.stops").level_route(state().stops)[1].box == 2, "Navigation does not offer missing overview")
  local preserved = library.read(tour.save_saved().id)
  check(
    preserved.stops[1].overview.locator.owners[1].name == "missing_owner",
    "Partial save retains unresolved original locator"
  )
  tour.open_saved(verified.id)
  -- Source-bound part ranges remain distinct when formatting joins their lines.
  tour.show({
    {
      file = "main.lua",
      start = 1,
      ["end"] = 5,
      note = "Full",
      parts = {
        { start = 1, ["end"] = 2, note = "First" },
        { start = 3, ["end"] = 5, note = "Last" },
      },
    },
  }, { root = root .. "/app" })
  local join_buf = state().stops[1].buf
  local saved_initial = tour.save_saved()
  tour.open_saved(saved_initial.id)
  drain()
  local saved_checked = tour.save_saved()
  vim.api.nvim_buf_set_lines(
    join_buf,
    0,
    -1,
    false,
    { "local function main(x) local y = helper(x) local z = y + 1 return z end" }
  )
  tour.open_saved(saved_checked.id)
  check(not active() and state().saved.entries[2].status == "ready", "Joined source reuses independently checked parts")
  state().box = 2
  tour.render(true)
  local selection = require("code-tour.selection").capture(state())
  check(
    selection.text:find("helper", 1, true) and not selection.text:find("local z", 1, true),
    "Explain current relocated box captures exact bytes"
  )
  check(
    require("code-tour.tour-view").state().cursor_col == state().stops[1].parts[1].byte_range.start[2],
    "Viewer uses byte focus"
  )
  vim.api.nvim_buf_set_lines(join_buf, 0, -1, false, original)
  tour.open_saved(verified.id)
  -- Two independently changed boxes; unchanged sibling and callee remain ready.
  local buf = state().stops[1].buf
  vim.api.nvim_buf_set_lines(buf, 2, 3, false, { "  local z = y + 2" })
  local result = tour.open_saved(verified.id)
  check(
    result.counts.ready == 2 and result.counts.generating == 1 and result.counts.queued == 1,
    "Mixed valid/stale boxes refresh independently"
  )
  local overview = active()
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- unrelated line shift" })
  reply(overview, "Relocated current overview")
  check(state().stops[1].start == 2, "Harmless relocation during generation remaps accepted reply")
  local last = active()
  vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  local z = y + 3" })
  check(not pcall(reply, last, "Must reject"), "Meaningful edit during generation rejects reply")
  check(last.entry.status == "source_changed" and not active(), "Source change does not automatically retry")
  state().stop, state().box = 1, 3
  vim.api.nvim_win_set_cursor(state().win, { last.entry.runtime.start, 0 })
  local retried = tour.explain()
  check(retried ~= nil and active().entry == last.entry, "Explain current box explicitly retries failed saved target")
  reply(nil, "Retried explanation")
  check(last.entry.status == "ready", "Explicit retry accepts fresh source")
  -- Ready notes and Q&A disappear immediately after an edit, including copy/prompt paths.
  last.entry.runtime.thread = { { question = "old Q", answer = "old A" } }
  tour.focus()
  local copy_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "  local z = y + 4" })
  tour.render(false)
  check(last.entry.status == "source_changed", "Source edits invalidate ready notes")
  check(
    not require("code-tour.tour-view").state().text:find("Retried explanation", 1, true),
    "Selectable layout withholds stale notes"
  )
  check(
    not table.concat(vim.api.nvim_buf_get_lines(copy_buf, 0, -1, false), "\n"):find("Retried explanation", 1, true),
    "Open selectable buffer refreshes without stale text"
  )
  tour.focus()
  check(not pcall(tour.ask, "Why?"), "Question cannot use an invalid note")
  -- Cancellation stops the timer and makes late fills invalid.
  tour.explain()
  local pending = active()
  tour.cancel()
  check(pending.entry.status == "cancelled" and not pending.timer, "Cancel finishes generation and closes timer")
  check(not pcall(reply, pending), "Cancelled response is rejected")
  tour.open_saved(first.id)
  local old_request = active()
  tour.open_saved(first.id)
  check(state().id ~= token and not pcall(reply, old_request), "Reopening cancels old queue/late replies")
  drain()
  -- Invalid reply completes that request and progresses to the next target.
  tour.open_saved(first.id)
  local invalid = active()
  check(
    not pcall(
      tour.fill,
      invalid.id,
      { { file = invalid.entry.path, start = 1, ["end"] = 1, note = "bad", parts = {} } }
    ),
    "Saved fill rejects new parts"
  )
  check(
    active() and active().id ~= invalid.id and invalid.entry.status == "failed",
    "Failed validation advances unrelated targets"
  )
  drain()
  -- Delivery failures and timeout do not stop other targets.
  fail_delivery = true
  tour.open_saved(first.id)
  pump()
  pump()
  pump()
  check(not active() and state().saved.entries[1].status == "failed", "Transport failures drain the queue")
  fail_delivery = false
  state().opts.saved_request_timeout_ms = 5
  tour.open_saved(first.id)
  vim.wait(200, function()
    return not state().saved.active and #state().saved.queue == 0
  end, 1)
  check(not active() and state().saved.entries[1].status == "failed", "Timeout advances the queue without retry")
  state().opts.saved_request_timeout_ms = 300000
  -- Missing all targets is a preflight error and retains the active tour.
  local live_token = state().id
  local ids = {}
  for _, repo in ipairs(record.repositories) do
    ids[repo.id] = root .. "/missing"
  end
  check(
    not pcall(tour.open_saved, first.id, { repositories = ids }) and state().id == live_token,
    "Failed open preserves active tour"
  )
  check(not pcall(tour.open_saved, first.id, { library = "/wrong/profile" }), "Profile mismatch fails clearly")
  -- Missing callers keep independently usable descendants and original unresolved branches.
  local app_repo = record.stops[1].repo
  tour.open_saved(first.id, { repositories = { [app_repo] = root .. "/missing" } })
  check(
    #state().stops == 1 and #state().saved.issues == 3 and state().stops[1]._saved_detached,
    "Missing caller does not hide located nested callee"
  )
  drain()
  local partial = tour.save_saved()
  local partial_record = library.read(partial.id)
  check(
    #partial_record.stops == 1 and #partial_record.stops[1].parts[1].calls == 1,
    "Partial export preserves unresolved authored hierarchy"
  )
  -- Explicit root/file reassociation applies only to the live open.
  vim.fn.mkdir(root .. "/moved", "p")
  vim.fn.writefile(original, root .. "/moved/renamed.lua")
  tour.open_saved(
    first.id,
    { repositories = { [app_repo] = root .. "/moved" }, files = { { app_repo, "main.lua", "renamed.lua" } } }
  )
  check(state().stops[1].path == root .. "/moved/renamed.lua", "Repository and file remapping resolve current source")
  drain()
  check(bytes(first.id) == initial, "Remapping leaves saved record unchanged")
  -- New refinements and appends are exported alongside unresolved backing content.
  local added = tour.explain({ buf = state().stops[1].buf, start = 3, ["end"] = 3 })
  tour.fill(
    added,
    { { file = root .. "/moved/renamed.lua", start = 3, ["end"] = 3, note = "A new prepared refinement" } }
  )
  tour.show(
    { { file = root .. "/helpers/helper.lua", start = 1, ["end"] = 3, note = "Appended", title = "Appended" } },
    { append = true }
  )
  local extended = library.read(tour.save_saved().id)
  check(#extended.stops == 2 and #extended.stops[1].parts == 3, "Prepared refinements and append survive export")
  local refinement = state().stops[1].parts[2]
  check(refinement._saved ~= nil, "Normal refinements synchronize runtime guards and backing model")
  local appended = state().stops[#state().stops]
  vim.api.nvim_buf_set_lines(appended.buf, 1, 2, false, { "  return x * 9" })
  saved.revalidate(state())
  check(appended._saved.status == "source_changed", "New authored content in an opened tour is guarded after edits")
  -- Review inputs are excluded and cannot produce verified saved prose.
  state().review = true
  local reviewed = library.read(tour.save_saved().id)
  check(reviewed.stops[1].overview.evidence.status == "unverified", "Review explanations save as unverified")
  vim.fn.writefile({ "opaque syntax" }, root .. "/app/unknown.custom")
  tour.show(
    { { file = "unknown.custom", start = 1, ["end"] = 1, note = "Original opaque prose" } },
    { root = root .. "/app" }
  )
  local opaque = tour.save_saved()
  tour.open_saved(opaque.id)
  reply(nil, "Fresh opaque prose")
  local live_opaque = state().stops[1]
  check(live_opaque._saved.status == "ready", "Fresh exact-text reply can display without a parser")
  local opaque_saved = library.read(tour.save_saved().id)
  check(
    opaque_saved.stops[1].overview.evidence.status == "unverified",
    "Parserless generation stays unverified on save"
  )
  tour.open_saved(opaque_saved.id)
  live_opaque = state().stops[1]
  local renamed_request = active()
  vim.api.nvim_buf_set_name(live_opaque.buf, root .. "/app/different.custom")
  check(not pcall(reply, renamed_request), "Reply cannot cross a buffer file reassociation")
  vim.api.nvim_buf_set_name(live_opaque.buf, root .. "/app/unknown.custom")
  vim.api.nvim_buf_set_lines(live_opaque.buf, 0, -1, false, { "changed opaque syntax" })
  saved.revalidate(state())
  check(live_opaque._saved.status == "unresolved", "Changed unsupported source requires reassociation")
  local invalid_buf = state().stops[1].buf
  vim.api.nvim_buf_delete(invalid_buf, { force = true })
  local hidden, available_note = saved.note(state().stops[1])
  check(
    not available_note and not hidden:find("Fresh opaque prose", 1, true),
    "Closed source never exposes a cached note"
  )
  tour.stop()
end
local ok, err = xpcall(run, debug.traceback)
saved.cancel(state())
vim.fn.delete(root, "rf")
if not ok then
  error(err)
end
print("PASS: " .. checks .. " saved workflow checks")
