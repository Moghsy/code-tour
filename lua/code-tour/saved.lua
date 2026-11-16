-- Prepared-content codec and batched regeneration. No library writes occur here.
local M = {}
local source = require("code-tour.source")
local library = require("code-tour.library")
local stops = require("code-tour.stops")
-- Authored notes saved without host evidence. Only these may be reused unchanged;
-- review-derived, parserless and stale-at-save prose always regenerates.
M.UNCHECKED = "No host generation-time source evidence"
local STALE = "Source changed before save"
local function reusable(evidence)
  return evidence and evidence.status == "unverified" and evidence.reason == M.UNCHECKED
end
-- The saved code itself is unchanged: same syntax-token digest, or the same file
-- bytes when no parser produced one.
local function unchanged(locator, capture)
  if not locator or not capture or not capture.locator then
    return false
  end
  if locator.target_digest then
    return capture.locator.target_digest == locator.target_digest
  end
  return locator.file_digest ~= nil and capture.file_digest == locator.file_digest
end
local function loading(entry)
  if entry.status == "queued" or entry.status == "generating" then
    return "Loading explanation…"
  end
  return "Explanation unavailable: " .. (entry.reason or entry.status) .. ". Use explain-current-box to retry."
end
local function apply_range(entry, capture)
  entry.capture = capture
  if entry.runtime then
    entry.runtime._unlocated = nil
    entry.runtime.byte_range = vim.deepcopy(capture.range)
    entry.runtime.start, entry.runtime["end"] = source.lines(capture.range)
  end
end
local function unavailable(entry, status, reason)
  entry.status, entry.reason = status, reason
  if entry.runtime then
    entry.runtime.note, entry.runtime.thread = loading(entry), {}
  end
end
function M.guard(entry)
  if not entry then
    return false
  end
  if not entry.buf or not vim.api.nvim_buf_is_valid(entry.buf) or not vim.api.nvim_buf_is_loaded(entry.buf) then
    unavailable(entry, "unresolved", "Source buffer closed; reopen or reassociate the saved tour")
    if entry.runtime then
      entry.runtime._unlocated = true
    end
    return false
  end
  if vim.fs.normalize(vim.api.nvim_buf_get_name(entry.buf)) ~= entry.path then
    unavailable(entry, "unresolved", "Source buffer file association changed; reassociate source")
    if entry.runtime then
      entry.runtime._unlocated = true
    end
    return false
  end
  local capture, err = source.locate(entry.buf, entry.capture and entry.capture.locator or entry.model.locator)
  if not capture then
    unavailable(entry, "unresolved", err.reason)
    if entry.runtime then
      entry.runtime._unlocated = true
    end
    return false
  end
  local previous = entry.capture
  apply_range(entry, capture)
  if entry.status == "ready" then
    local matches = entry.session_evidence and source.matches(entry.session_evidence, capture)
      or (not entry.session_evidence and source.matches(entry.model.evidence, capture))
    -- A fresh parserless reply is safe for this live exact snapshot only.
    if not matches and entry.raw_freshness then
      matches = capture.file_digest == entry.raw_freshness
    end
    -- Reused unchecked prose stays visible only while its saved code is untouched.
    if not matches and entry.reused and not entry.session_evidence then
      matches = unchanged(entry.model.locator, capture)
    end
    if not matches then
      unavailable(entry, "source_changed", "Source changed; explicitly regenerate this box")
    end
  elseif entry.status == "generating" and previous then
    -- The request snapshot is checked again on acceptance; never auto-enqueue edits.
    entry.reason = nil
  end
  return entry.status == "ready"
end
function M.note(box)
  if box._unlocated then
    return "Explanation unavailable: source is unresolved", false
  end
  local entry = box._saved
  if not entry then
    return box.note, true
  end
  M.guard(entry)
  return entry.status == "ready" and box.note or loading(entry), entry.status == "ready"
end
function M.revalidate(state)
  local plan = state.saved
  if not plan then
    return
  end
  for _, entry in ipairs(plan.entries) do
    if entry.runtime then
      M.guard(entry)
    end
  end
  for _, edge in ipairs(plan.edges) do
    local capture = source.locate(edge.buf, edge.locator)
    local valid = capture
      and capture.locator.target_digest
      and capture.locator.target_digest == edge.locator.target_digest
    local caller = edge.runtime._parent_box
    if valid and caller and caller.byte_range then
      valid = source.contains(caller.byte_range, capture.range)
    end
    if valid then
      local a, b = source.lines(capture.range)
      edge.runtime.callsite = {
        start = a,
        ["end"] = b,
        start_col = capture.range.start[2],
        end_col = capture.range["end"][2],
        symbol = edge.symbol,
      }
      edge.runtime.next = edge.next
    else
      edge.runtime.callsite, edge.runtime.next = nil, nil
    end
  end
end
local function merge(old, fresh)
  local by_id, result = {}, vim.list_extend({}, fresh)
  for _, item in ipairs(fresh) do
    by_id[item.id] = true
  end
  -- Runtime ordering includes newly inserted content. Retain unavailable old
  -- branches immediately before their next surviving authored sibling.
  for index, item in ipairs(old or {}) do
    if not by_id[item.id] then
      local next_id
      for j = index + 1, #old do
        if by_id[old[j].id] then
          next_id = old[j].id
          break
        end
      end
      local at = #result + 1
      if next_id then
        for j, candidate in ipairs(result) do
          if candidate.id == next_id then
            at = j
            break
          end
        end
      end
      table.insert(result, at, vim.deepcopy(item))
      by_id[item.id] = true
    end
  end
  return result
end
function M.export(state, opts)
  opts = opts or {}
  M.revalidate(state)
  local record = state.saved and vim.deepcopy(state.saved.record)
    or {
      kind = "code-tour.saved",
      version = 1,
      id = library.id(),
      repositories = {},
      stops = {},
      created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
  local omitted, prepared = {}, 0
  local function repo_for(path)
    for _, repo in ipairs(record.repositories) do
      if vim.fs.relpath(repo.root, path) then
        return repo
      end
    end
    local root = vim.fs.root(path, { ".git" })
    if not root then
      root = vim.fs.relpath(state.root, path) and state.root or vim.fs.dirname(path)
    end
    root = assert(vim.uv.fs_realpath(root), "Source repository missing")
    local repo = { id = "repo-" .. library.id():sub(1, 12), root = root, label = vim.fs.basename(root) }
    record.repositories[#record.repositories + 1] = repo
    return repo
  end
  local export_stop
  local function export_box(stop, box)
    local old = box._saved and box._saved.model or (box == stop and stop._saved_stop and stop._saved_stop.overview)
    if box._unlocated then
      return vim.deepcopy(old)
    end
    local note = old and old.note or box.note
    if not note or not note:find("%S") then
      return nil
    end
    box._saved_id = box._saved_id or (old and old.id) or library.id()
    local capture
    if not box._saved or box._saved.status ~= "unresolved" then
      capture = source.capture(stop.buf, box.byte_range or source.line_range(stop.buf, box.start, box["end"]))
    end
    local evidence = box._evidence
      or (old and old.evidence)
      or { status = "unverified", reason = M.UNCHECKED }
    -- Never rebind a withheld (edited, failed or pending) note to the current code.
    if box._saved and box._saved.status == "source_changed"
      or (box._saved and box._saved.status ~= "ready" and box._saved.status ~= "unresolved" and evidence.status ~= "verified") then
      evidence = { status = "unverified", reason = STALE }
    end
    if stop.old or stop.added or stop.removed or state.review then
      evidence = { status = "unverified", reason = "Historical review inputs are excluded" }
    end
    local result = {
      id = box._saved_id,
      note = note,
      locator = capture and capture.locator or (old and old.locator),
      evidence = vim.deepcopy(evidence),
      calls = {},
    }
    assert(result.locator, "Cannot locate prepared source for saving")
    for _, call in ipairs(stops.calls(state.stops, box)) do
      local child = export_stop(call)
      if child then
        result.calls[#result.calls + 1] = child
      end
    end
    result.calls = merge(old and old.calls, result.calls)
    prepared = prepared + 1
    return result
  end
  export_stop = function(stop)
    if stop.lazy or stop.placeholder then
      omitted[#omitted + 1] = stop.title or stop.file
      return nil
    end
    local old = stop._saved_stop
    local repo = repo_for(stop.path)
    stop._saved_stop_id = stop._saved_stop_id or (old and old.id) or library.id()
    local result = {
      id = stop._saved_stop_id,
      title = stop.title or "Snippet",
      repo = repo.id,
      file = assert(vim.fs.relpath(repo.root, stop.path)),
      overview = export_box(stop, stop),
      parts = {},
    }
    for _, part in ipairs(stop.parts) do
      local box = export_box(stop, part)
      if box then
        result.parts[#result.parts + 1] = box
      end
    end
    result.parts = merge(old and old.parts, result.parts)
    if stop._parent_stop and stop.callsite then
      local site, parent = stop.callsite, stop._parent_stop
      local r = site.start_col
          and { start = { site.start - 1, site.start_col }, ["end"] = { site["end"] - 1, site.end_col } }
        or source.line_range(parent.buf, site.start, site["end"])
      local capture = source.capture(parent.buf, r)
      if capture then
        result.callsite = { symbol = site.symbol or "", locator = capture.locator }
        result.next = stop.next
      end
    elseif old then
      result.callsite, result.next = vim.deepcopy(old.callsite), old.next
    end
    return result
  end
  local fresh = {}
  for _, stop in ipairs(stops.roots(state.stops)) do
    -- Detached saved descendants remain under their original backing-model parent.
    if not stop._saved_detached then
      local item = export_stop(stop)
      if item then
        fresh[#fresh + 1] = item
      end
    end
  end
  record.stops = merge(record.stops, fresh)
  -- Update detached descendants in place without turning them into duplicate roots.
  local function update(items)
    for _, item in ipairs(items) do
      for _, runtime in ipairs(state.stops) do
        if runtime._saved_detached and runtime._saved_stop_id == item.id then
          local fresh_item = export_stop(runtime)
          item.overview, item.parts = fresh_item.overview, fresh_item.parts
        end
      end
      for _, box in ipairs(vim.list_extend({ item.overview }, item.parts)) do
        update(box.calls)
      end
    end
  end
  update(record.stops)
  for id, pending in pairs(state.pending) do
    if not pending.placeholder then
      omitted[#omitted + 1] = "Pending explanation " .. id
    end
  end
  assert(prepared > 0 or #record.stops > 0, "No prepared explanations to save")
  record.title = opts.title or (record.stops[1] and record.stops[1].title) or "Code tour"
  return library.validate(record), omitted
end
function M.prepare(record, opts)
  library.validate(record)
  opts = opts or {}
  local plan =
    { record = vim.deepcopy(record), entries = {}, by_id = {}, issues = {}, edges = {}, queue = {}, runtime = {} }
  local repos, files = {}, {}
  for _, repo in ipairs(plan.record.repositories) do
    repos[repo.id] = repo
  end
  for id, root in pairs(opts.repositories or {}) do
    assert(repos[id], "Unknown repository override: " .. id)
    assert(type(root) == "string" and root:sub(1, 1) == "/", "Repository override requires an absolute root")
    repos[id].root = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
  end
  for _, mapping in ipairs(opts.files or {}) do
    assert(
      repos[mapping[1]] and library.relative(mapping[2]) and library.relative(mapping[3]),
      "Invalid file reassociation"
    )
    files[mapping[1] .. "/" .. mapping[2]] = mapping[3]
  end
  local function load(item)
    local repo = repos[item.repo]
    local relative = files[item.repo .. "/" .. item.file] or item.file
    local root = vim.uv.fs_realpath(repo.root)
    local path = root and vim.uv.fs_realpath(root .. "/" .. relative)
    if not root or not path then
      return nil, "Missing repository/file: " .. repo.root .. "/" .. relative
    end
    if not vim.fs.relpath(root, path) then
      return nil, "File escapes repository root"
    end
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then
      return nil, "Source is not a file"
    end
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    item.file, repo.root = relative, root
    return { buf = buf, path = path, root = root, file = relative }
  end
  local hydrate
  hydrate = function(item, parent, parent_box)
    local location, reason = load(item)
    local entries = {}
    for index, box in ipairs(vim.list_extend({ item.overview }, item.parts)) do
      local capture, err
      if location then
        capture, err = source.locate(location.buf, box.locator)
      end
      local entry = {
        id = box.id,
        model = box,
        stop_model = item,
        role = index == 1 and "overview" or "part",
        buf = location and location.buf,
        path = location and location.path,
        root = location and location.root,
      }
      entry.capture = capture
      entry.status = capture and (source.matches(box.evidence, capture) and "ready" or "queued") or "unresolved"
      if entry.status == "queued" and opts.reuse_unverified ~= false and reusable(box.evidence)
        and unchanged(box.locator, capture) then
        entry.status, entry.reused = "ready", true
      end
      entry.reason = not capture and (reason or (err and err.reason)) or nil
      plan.entries[#plan.entries + 1] = entry
      plan.by_id[box.id] = entry
      entries[index] = entry
      if entry.status == "unresolved" then
        plan.issues[#plan.issues + 1] = { box = box.id, reason = entry.reason }
      elseif entry.status == "queued" then
        plan.queue[#plan.queue + 1] = entry
      end
    end
    local runtime
    if location then
      local located = vim.tbl_filter(function(e)
        return e.capture ~= nil
      end, entries)
      if #located > 0 then
        runtime = stops.hydrate_saved(item, location, entries)
        local attached = parent and type(parent_box) == "table"
        runtime._parent_stop, runtime._parent_box = attached and parent or nil, attached and parent_box or nil
        runtime._saved_detached = (parent_box == false or (parent and not attached)) or nil
        plan.runtime[#plan.runtime + 1] = runtime
        if attached and item.callsite then
          local edge = {
            buf = parent.buf,
            locator = item.callsite.locator,
            symbol = item.callsite.symbol,
            runtime = runtime,
            next = item.next,
          }
          plan.edges[#plan.edges + 1] = edge
        end
      end
    end
    for i, entry in ipairs(entries) do
      for _, child in ipairs(entry.model.calls) do
        -- A usable descendant is still accessible when its caller is missing.
        hydrate(child, runtime, (runtime and entry.runtime) or false)
      end
    end
  end
  for _, item in ipairs(plan.record.stops) do
    hydrate(item)
  end
  assert(#plan.runtime > 0, "No saved source targets can be opened: " .. vim.json.encode(plan.issues))
  return plan
end

-- Normal authored additions keep their live presentation, while acquiring
-- host-owned freshness guards and a place in the prepared backing tree.
function M.sync(state)
  local plan = state.saved
  if not plan then
    return
  end
  local record = M.export(state)
  plan.record = record
  local runtimes, repos = {}, {}
  for _, repo in ipairs(record.repositories) do
    repos[repo.id] = repo
  end
  for _, runtime in ipairs(state.stops) do
    if runtime._saved_stop_id then
      runtimes[runtime._saved_stop_id] = runtime
    end
  end
  local function visit(items)
    for _, item in ipairs(items) do
      local runtime = runtimes[item.id]
      if runtime then
        runtime._saved_stop = item
      end
      for index, box in ipairs(vim.list_extend({ item.overview }, item.parts)) do
        local entry = plan.by_id[box.id]
        if entry then
          entry.model, entry.stop_model = box, item
        elseif runtime then
          for _, live_box in ipairs(stops.boxes(runtime)) do
            if live_box._saved_id == box.id then
              local capture = source.capture(
                runtime.buf,
                live_box.byte_range or source.line_range(runtime.buf, live_box.start, live_box["end"])
              )
              if capture then
                entry = {
                  id = box.id,
                  model = box,
                  stop_model = item,
                  role = index == 1 and "overview" or "part",
                  status = "ready",
                  buf = runtime.buf,
                  path = runtime.path,
                  root = repos[item.repo].root,
                  runtime = live_box,
                }
                live_box._saved = entry
                apply_range(entry, capture)
                if source.matches(box.evidence, capture) then
                  entry.session_evidence = box.evidence
                else
                  entry.raw_freshness = capture.file_digest
                end
                plan.entries[#plan.entries + 1] = entry
                plan.by_id[box.id] = entry
              end
            end
          end
        end
        visit(box.calls)
      end
      if runtime and runtime._parent_stop and item.callsite then
        local existing = false
        for _, edge in ipairs(plan.edges) do
          if edge.runtime == runtime then
            existing = true
          end
        end
        if not existing then
          plan.edges[#plan.edges + 1] = {
            buf = runtime._parent_stop.buf,
            locator = item.callsite.locator,
            symbol = item.callsite.symbol,
            runtime = runtime,
            next = item.next,
          }
        end
      end
    end
  end
  visit(record.stops)
end
local function close_timer(request)
  if request and request.timer then
    request.timer:stop()
    request.timer:close()
    request.timer = nil
  end
end
local dispatch
-- Settle every box still generating in this request; replies already marked
-- their own accepted or rejected boxes.
local function finish(state, request, status, reason)
  local plan = state.saved
  if not plan or plan.active ~= request then
    return
  end
  close_timer(request)
  state.pending[request.id] = nil
  plan.active = nil
  for _, item in ipairs(request.items) do
    if item.entry.status == "generating" then
      unavailable(item.entry, status or "failed", reason or "Reply omitted this box")
    end
  end
  if plan.hooks.refresh then
    plan.hooks.refresh()
  end
  vim.schedule(function()
    if state.saved == plan and not plan.cancelled then
      dispatch(state)
    end
  end)
end
local function limits(state)
  local opts = state.opts or {}
  return opts.saved_batch_size or 12, opts.saved_batch_chars or 40000
end
dispatch = function(state)
  local plan = state.saved
  if not plan or plan.cancelled or plan.active then
    return
  end
  local size, budget = limits(state)
  local items, used = {}, 0
  while #plan.queue > 0 and #items < size do
    local entry = plan.queue[1]
    if entry.status ~= "queued" then
      table.remove(plan.queue, 1)
    else
      local capture, err = source.locate(entry.buf, entry.capture.locator)
      if not capture or capture.path ~= entry.path then
        table.remove(plan.queue, 1)
        unavailable(entry, "unresolved", err and err.reason or "Source buffer file association changed")
      else
        -- One request always carries at least one box, however large.
        local cost = #capture.text + 300
        if #items > 0 and used + cost > budget then
          break
        end
        table.remove(plan.queue, 1)
        apply_range(entry, capture)
        items[#items + 1] = { entry = entry, capture = capture }
        used = used + cost
      end
    end
  end
  if #items == 0 then
    return
  end
  local id = library.id():sub(1, 16)
  local request = { id = id, kind = "saved", items = items, by_box = {}, tour = state.id }
  if #items == 1 then
    request.entry, request.capture = items[1].entry, items[1].capture
  end
  plan.active, state.pending[id] = request, request
  for _, item in ipairs(items) do
    request.by_box[item.entry.id] = item
    item.entry.status = "generating"
    item.entry.runtime.note = loading(item.entry)
  end
  request.timer = assert(vim.uv.new_timer())
  request.timer:start(
    state.opts.saved_request_timeout_ms or 300000,
    0,
    vim.schedule_wrap(function()
      finish(state, request, "failed", "Generation timed out")
    end)
  )
  local requests = require("code-tour.requests")
  local command = plan.hooks.command(id)
  local prompt = #items == 1 and requests.saved({ entry = items[1].entry, capture = items[1].capture, command = command, tour = plan.hooks.tour() })
    or requests.saved_batch({ items = items, command = command, tour = plan.hooks.tour() })
  request.prompt = prompt
  local ok, failure = pcall(plan.hooks.send, prompt, function(sent, message)
    if not sent then
      finish(state, request, "failed", "Delivery failed: " .. tostring(message))
    end
  end)
  if not ok then
    finish(state, request, "failed", "Delivery failed: " .. tostring(failure))
  end
end
function M.start(state, plan, hooks)
  state.saved, plan.hooks = plan, hooks
  M.revalidate(state)
  if state.standalone then
    for _, entry in ipairs(plan.queue) do
      unavailable(entry, "unavailable", "Source requires regeneration; disabled in standalone review")
    end
    plan.queue = {}
    return
  end
  dispatch(state)
end
-- Validate and apply one reply stop to the box it names.
local function accept_item(request, target, item)
  local entry, requested = target.entry, target.capture
  for k in pairs(item) do
    assert(
      vim.tbl_contains({ "box", "file", "start", "end", "note", "title" }, k),
      "Saved reply must contain only one note and its requested source coverage"
    )
  end
  assert(type(item.note) == "string" and item.note:find("%S"), "Missing replacement note")
  local path = type(item.file) == "string"
    and vim.uv.fs_realpath(item.file:sub(1, 1) == "/" and item.file or entry.root .. "/" .. item.file)
  assert(path == entry.path, "Saved reply file differs from requested source")
  local first, last = source.lines(requested.range)
  assert(item.start == first and item["end"] == last, "Saved reply must cover exactly the requested range")
  local capture, err = source.locate(entry.buf, requested.locator)
  assert(capture, err and err.reason or "Source missing")
  assert(
    capture.path == entry.path and capture.path == requested.path,
    "Source file association changed; reassociate source"
  )
  local fresh = source.matches(requested.evidence, capture)
  if requested.evidence.status ~= "verified" then
    fresh = requested.file_digest == capture.file_digest
  end
  assert(fresh, "Source changed during generation; explicitly retry this box")
  apply_range(entry, capture)
  entry.model.note, entry.model.evidence, entry.model.locator =
    item.note, vim.deepcopy(capture.evidence), vim.deepcopy(capture.locator)
  entry.runtime.note, entry.runtime._evidence = item.note, vim.deepcopy(capture.evidence)
  entry.status, entry.reason, entry.reused, entry.because = "ready", nil, nil, nil
  entry.session_evidence = capture.evidence.status == "verified" and capture.evidence or nil
  entry.raw_freshness = capture.evidence.status ~= "verified" and capture.file_digest or nil
end
function M.accept(state, request, payload, opts)
  local ok, err = pcall(function()
    assert(
      state.saved and state.saved.active == request and state.id == request.tour,
      "Replaced or cancelled saved request"
    )
    assert(not opts or next(opts) == nil, "Saved regeneration does not accept placement/review options")
    assert(type(payload) == "table" and vim.islist(payload) and #payload >= 1, "Return a JSON list of saved explanation stops")
    if #request.items == 1 then
      assert(#payload == 1, "Return exactly one saved explanation stop")
    end
  end)
  if not ok then
    finish(state, request, "failed", tostring(err))
    error(err, 0)
  end
  local accepted, failed, seen = {}, {}, {}
  for _, item in ipairs(payload) do
    local target
    local fine, problem = pcall(function()
      assert(type(item) == "table", "Each reply stop must be an object")
      if item.box ~= nil then
        target = request.by_box[item.box]
        assert(target, "Reply names a box outside this request: " .. tostring(item.box))
      else
        assert(#request.items == 1, "Each batched reply stop needs its box ID")
        target = request.items[1]
      end
      assert(not seen[target], "Duplicate reply for box " .. target.entry.id)
      seen[target] = true
      accept_item(request, target, item)
    end)
    if fine then
      accepted[#accepted + 1] = target.entry.id
    else
      local reason = tostring(problem)
      failed[#failed + 1] = { box = target and target.entry.id or (type(item) == "table" and item.box) or nil, reason = reason }
      if target and target.entry.status == "generating" then
        unavailable(target.entry, reason:find("Source changed", 1, true) and "source_changed" or "failed", reason)
      end
    end
  end
  finish(state, request)
  if #accepted == 0 then
    error(failed[1] and failed[1].reason or "No saved explanation accepted", 0)
  end
  local result = { filled = request.id, count = #accepted, navigate = false, boxes = accepted }
  if #request.items == 1 then
    result.box = accepted[1]
  end
  local reported = {}
  for _, id in ipairs(accepted) do
    reported[id] = true
  end
  for _, f in ipairs(failed) do
    if f.box then
      reported[f.box] = true
    end
  end
  for _, item in ipairs(request.items) do
    if not reported[item.entry.id] then
      failed[#failed + 1] = { box = item.entry.id, reason = "Reply omitted this box" }
    end
  end
  if #failed > 0 then
    result.failed = failed
  end
  return result
end
function M.retry(state, box_id, linked)
  local plan = assert(state.saved, "No saved tour")
  local entry = assert(plan.by_id[box_id], "Unknown saved box")
  if entry.status == "queued" or entry.status == "generating" then
    return
  end
  assert(entry.buf, "Reassociate missing source before retrying this box")
  local capture, err = source.locate(entry.buf, entry.capture and entry.capture.locator or entry.model.locator)
  assert(capture, err and err.reason or "Reassociate source before retrying")
  plan.cancelled = false
  apply_range(entry, capture)
  entry.status = "queued"
  plan.queue[#plan.queue + 1] = entry
  -- Ready or stale boxes that depend on this one are regenerated in the same round trip.
  for _, link in ipairs(linked or {}) do
    local other = plan.by_id[link.id]
    if other and other ~= entry and (other.status == "ready" or other.status == "source_changed")
      and other.runtime and other.buf and other.capture then
      other.status, other.because = "queued", link.because .. " changed"
      plan.queue[#plan.queue + 1] = other
    end
  end
  dispatch(state)
  return plan.active and plan.active.id
end
function M.cancel(state)
  local plan = state.saved
  if not plan then
    return
  end
  plan.cancelled = true
  if plan.active then
    close_timer(plan.active)
    state.pending[plan.active.id] = nil
    plan.active = nil
  end
  for _, entry in ipairs(plan.entries) do
    if entry.status == "generating" or entry.status == "queued" then
      unavailable(entry, "cancelled", "Generation cancelled")
    end
  end
  plan.queue = {}
end
return M
