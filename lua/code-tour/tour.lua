local M = {}
local stops = require("code-tour.stops")
local view = require("code-tour.tour-view")
local scroll = require("code-tour.scroll")
local composer = require("code-tour.prompt")
local conversation = require("code-tour.conversation")
local badge = require("code-tour.call-badge")
local definition = require("code-tour.definition")
local requests = require("code-tour.requests")
local saved = require("code-tour.saved")
local source_engine = require("code-tour.source")
local library = require("code-tour.library")
local ns = vim.api.nvim_create_namespace("CodeTourSource")
local s =
  { stops = {}, stop = 1, box = 1, page = 1, note_page = 1, visible = false, pending = {}, questions = {}, opts = {} }
local render
local function notify(value, level)
  vim.notify(tostring(value), level or vim.log.levels.WARN, { title = "Code tour" })
end
local function started(value)
  vim.notify(value, vim.log.levels.INFO, { title = "Code tour", timeout = 2000 })
end
local function current()
  local stop = s.stops[s.stop]
  return stop, stop and stops.boxes(stop)[s.box]
end
local function clear()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end
local function typing()
  return vim.api.nvim_get_mode().mode:match("^[iRc]") or composer.state()
end
local function locate(stop, box)
  for i, item in ipairs(s.stops) do
    if item == stop then
      for k, part in ipairs(stops.boxes(item)) do
        if part == (box or stop) then
          return i, k
        end
      end
    end
  end
end
local function reset_pages()
  s.page, s.note_page = 1, 1
end

local function clear_intent()
  s.awaiting, s.lookup = nil, nil
end

local function position(entry)
  s.stop, s.box = entry.stop, entry.box
  local ancestors, stop = {}, s.stops[s.stop]
  while stop do ancestors[stop] = true; stop = stop._parent_stop end
  local frames = s.frames or {}
  while #frames > 0 and not ancestors[frames[#frames].call] do table.remove(frames) end
end

local function enter_call(call, stop, box)
  s.frames = s.frames or {}
  if stop ~= call._parent_stop then
    s.frames = {}
    stop, box = call._parent_stop, call._parent_box
  elseif call.callsite and (call.callsite.start < box.start or call.callsite["end"] > box["end"]) then
    box = call._parent_box
  end
  while #s.frames > 0 and s.frames[#s.frames].call ~= stop do table.remove(s.frames) end
  s.frames[#s.frames + 1] = { call = call, stop = stop, box = box }
  s.stop, s.box = locate(call)
  s.box = stops.first_box(call)
  clear_intent()
end

local function resume_caller(call)
  local parent, anchor = call._parent_stop, call._parent_box
  local frames = s.frames or {}
  for n = #frames, 1, -1 do
    if frames[n].call == call then
      parent, anchor = frames[n].stop, frames[n].box
      for _ = #frames, n, -1 do table.remove(frames) end
      break
    end
  end
  if not parent then return false end
  local i, k = locate(parent, anchor)
  if not i then return false end
  position({ stop = i, box = k })
  return true
end

local function window()
  if s.tab and vim.api.nvim_tabpage_is_valid(s.tab) and s.win and vim.api.nvim_win_is_valid(s.win) then
    return
  end
  -- A tour owns its tab and source window; existing layouts and diff views stay intact.
  vim.cmd("tabnew")
  s.tab, s.win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
  vim.wo[s.win].diff, vim.wo[s.win].scrollbind, vim.wo[s.win].cursorbind = false, false, false
  vim.wo[s.win].scrolloff, vim.wo[s.win].signcolumn = 0, "yes:2"
  assert(vim.api.nvim__ns_set, "CodeTour requires Neovim with window-scoped namespaces")
  vim.api.nvim__ns_set(ns, { wins = { s.win } })
end

local function decorate(stop, box, layout)
  clear()
  local count = vim.api.nvim_buf_line_count(stop.buf)
  for _, other in ipairs(s.stops) do
    if other ~= stop and other.buf == stop.buf and stops.ready(other) then
      for line = other.start, math.min(other["end"], count) do
        vim.api.nvim_buf_set_extmark(stop.buf, ns, line - 1, 0, {
          line_hl_group = (other.added or {})[line] and "CodeTourDiffAdd" or "CodeTourStop", priority = 100,
        })
      end
    end
  end
  for line = stop.start, math.min(stop["end"], count) do
    local focused = line >= box.start and line <= box["end"]
    local group = focused and not box.byte_range and "CodeTourFocus" or "CodeTourStop"
    if (stop.added or {})[line] then
      group = focused and "CodeTourDiffAddFocus" or "CodeTourDiffAdd"
    end
    vim.api.nvim_buf_set_extmark(stop.buf, ns, line - 1, 0, { line_hl_group = group, priority = 110 })
  end
  if box.byte_range and not box._unlocated then
    local r = box.byte_range
    vim.api.nvim_buf_set_extmark(stop.buf, ns, r.start[1], r.start[2], {
      end_row = r["end"][1], end_col = r["end"][2], hl_group = "CodeTourFocus", priority = 115,
    })
  end
  for k, part in ipairs(stop.parts) do
    for line = part.start, math.min(part["end"], count) do
      vim.api.nvim_buf_set_extmark(stop.buf, ns, line - 1, 0, {
        sign_text = line == part.start and tostring(k):sub(-2) or "│",
        sign_hl_group = part == box and "CodeTourFocus" or "CodeTourMeta",
        priority = 120,
      })
    end
  end
  for _, call in ipairs(stops.calls_in(s.stops, stop, box, true)) do
    local range = badge.range(stop.buf, call.callsite)
    if range then badge.draw(stop.buf, ns, range[1], range[2], range[3], range[4], call.next) end
  end
  local example = box.example or stop.example
  for line, value in pairs((example or {}).values or {}) do
    local label = type(value) == "table" and value.value or value
    if label:find("%S") and not label:lower():match("^%s*unchanged[%s%.!]*$") then
      vim.api.nvim_buf_set_extmark(
        stop.buf,
        ns,
        math.min(tonumber(line), count) - 1,
        0,
        { virt_text = { { "  ⇒ " .. label:gsub("\n", " "), "CodeTourExample" } }, virt_text_pos = "eol" }
      )
    end
  end
  for _, removed in ipairs(stop.removed or {}) do
    local lines = {}
    for index, line in ipairs(removed.lines) do
      local owner = (removed.owners or {})[index] or removed.line
      local focused = owner >= box.start and owner <= box["end"]
      lines[#lines + 1] = { { "− " .. line, focused and "CodeTourDiffDeleteFocus" or "CodeTourDiffDelete" } }
    end
    if removed.line == layout.anchor and (removed.above == true) == layout.above then
      vim.list_extend(layout.rows, lines)
    else
      vim.api.nvim_buf_set_extmark(
        stop.buf,
        ns,
        removed.line - 1,
        0,
        { virt_lines = lines, virt_lines_above = removed.above, virt_lines_leftcol = false }
      )
    end
  end
  if #layout.rows > 0 then
    vim.api.nvim_buf_set_extmark(stop.buf, ns, layout.anchor - 1, 0, {
      virt_lines = layout.rows, virt_lines_above = layout.above, virt_lines_leftcol = false,
    })
  end
  return #layout.rows
end

render = function(jump)
  saved.revalidate(s)
  local stop, box = current()
  if box and box._unlocated then
    clear()
    view.close()
    return
  end
  if not stop or not s.visible or not s.win or not vim.api.nvim_win_is_valid(s.win) then
    return
  end
  if vim.api.nvim_win_get_tabpage(s.win) ~= vim.api.nvim_get_current_tabpage() then
    return
  end
  if not vim.api.nvim_buf_is_valid(stop.buf) then
    notify("Source buffer closed; show the tour again")
    return
  end
  if vim.api.nvim_win_get_buf(s.win) ~= stop.buf then
    vim.api.nvim_win_set_buf(s.win, stop.buf)
  end
  vim.wo[s.win].diff = false
  local saved = vim.api.nvim_win_call(s.win, vim.fn.winsaveview)
  local layout = view.build(s, stop, box)
  local virtual_count = decorate(stop, box, layout)
  if jump then
    scroll.move(s.win, function()
      vim.api.nvim_win_call(s.win, function()
        vim.api.nvim_win_set_cursor(s.win, {
          layout.cursor_line or math.min(box.start, vim.api.nvim_buf_line_count(stop.buf)), layout.cursor_col or 0,
        })
        vim.cmd("normal! zv")
        vim.fn.winrestview(
          view.target(s.win, layout.first, math.min(box["end"], vim.api.nvim_buf_line_count(stop.buf)), virtual_count, layout.above)
        )
      end)
    end, nil, s.opts.smooth_scroll)
  else
    vim.api.nvim_win_call(s.win, function()
      vim.fn.winrestview(saved)
    end)
  end
end

local function prepare(input, root, review, base)
  local data = stops.normalize(input, root)
  if review then
    for _, stop in ipairs(data) do
      if not stop.lazy then require("code-tour.review").prepare(stop, root, base) end
    end
  end
  return data
end

function M.review(base)
  assert(current(), "Open a tour before showing its diff")
  base = base and base ~= "" and base or s.base or "HEAD"
  local prepared = {}
  for _, stop in ipairs(s.stops) do
    if not stop.placeholder and not stop.lazy then
      local copy = vim.deepcopy(stop)
      require("code-tour.review").prepare(copy, s.root, base)
      prepared[#prepared + 1] = { stop = stop, added = copy.added, removed = copy.removed }
    end
  end
  for _, item in ipairs(prepared) do
    item.stop.added, item.stop.removed = item.added, item.removed
  end
  s.review, s.base = true, base
  render(false)
  return { review = true, base = base }
end

local function activate(data, opts, root, append, review, base)
  if not append then
    saved.cancel(s)
    s.saved = nil
    M.hide()
    composer.clear()
    s.arrival = nil
    s.id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. vim.fn.getpid()):sub(1, 16)
    s.stops, s.pending, s.questions, s.frames = {}, {}, {}, {}
    s.stop, s.box = 1, 1
  end
  clear_intent()
  s.frames = {}
  local first = #s.stops + 1
  vim.list_extend(s.stops, data)
  s.root, s.review, s.base = root, review, base
  s.origin = opts.origin or (append and s.origin or nil)
  if opts.tour_file or not append then
    s.tour_file = opts.tour_file
  end
  s.cli = opts.cli or s.cli
  s.visible = true
  reset_pages()
  window()
  vim.api.nvim_set_current_tabpage(s.tab)
  vim.api.nvim_set_current_win(s.win)
  s.stop, s.box = first, stops.first_box(s.stops[first])
  render(true)
  return { shown = #stops.roots(data), stop = s.stop, pane = vim.env.HERDR_PANE_ID }
end

function M.show(input, opts)
  opts = opts or {}
  local append = opts.append and #s.stops > 0
  local root = vim.fs.normalize(opts.root or vim.fn.getcwd())
  if append then
    root = s.root
  end
  local review = opts.review
  if review == nil and append then
    review = s.review
  end
  local base = opts.base or (append and s.base or nil)
  local data = prepare(input, root, review, base)
  local result = activate(data, opts, root, append, review, base)
  saved.sync(s)
  return result
end

function M.hide()
  s.visible = false
  scroll.cancel()
  clear()
  view.close()
end
function M.toggle()
  if s.visible then
    M.hide()
  elseif #s.stops > 0 then
    s.visible = true
    window()
    vim.api.nvim_set_current_tabpage(s.tab)
    render(true)
  else
    M.load()
  end
end
function M.stop()
  M.hide()
  composer.clear()
  M.cancel()
  local tab, win = s.tab, s.win
  s.tab, s.win = nil, nil
  if tab and vim.api.nvim_tabpage_is_valid(tab) and win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_tabpage(tab)
    -- Close only windows owned by the tour, without forcing edited source buffers.
    pcall(vim.api.nvim_win_close, win, false)
  end
end
function M.recenter()
  if #s.stops == 0 then
    return
  end
  window()
  vim.api.nvim_set_current_tabpage(s.tab)
  vim.api.nvim_set_current_win(s.win)
  s.visible = true
  render(true)
end
function M.next_snippet(delta)
  if #s.stops == 0 then
    return
  end
  clear_intent()
  local order = {}
  local index = stops.snippet_position(s.stops, current()) or 1
  for i, stop in ipairs(s.stops) do
    if not stop._parent_stop and stops.ready(stop) then order[#order + 1] = i end
  end
  if #order == 0 then return end
  s.stop = order[math.max(1, math.min(#order, index + delta))]
  s.box = stops.first_box(s.stops[s.stop])
  s.frames = {}
  reset_pages()
  s.visible = true
  render(true)
end
function M.next_explanation(delta)
  if #s.stops == 0 then
    return
  end
  clear_intent()
  local direction = delta < 0 and -1 or 1
  for _ = 1, math.abs(delta) do
    local stop, box = current()
    local scope = stop
    while scope._parent_stop and scope.next do scope = scope._parent_stop end
    scope = scope._parent_stop and scope or nil
    local route, index = stops.level_route(s.stops, scope), 1
    for n, entry in ipairs(route) do
      if entry.stop == s.stop and entry.box == s.box then index = n; break end
    end
    local entry = route[index + direction]
    if direction < 0 and stop._parent_stop and s.box == 1 then
      resume_caller(stop)
    elseif entry then
      local destination = s.stops[entry.stop]
      if direction > 0 and destination ~= stop and destination._parent_stop == stop then
        enter_call(destination, stop, box)
      end
      position(entry)
    elseif scope then
      resume_caller(scope)
    end
  end
  reset_pages()
  s.visible = true
  render(true)
end
function M.page(delta)
  if delta > 0 and s.note_page < (s.note_pages or 1) then
    s.note_page = s.note_page + 1
  elseif delta < 0 and s.page == 1 then
    s.note_page = math.max(1, s.note_page - 1)
  else
    s.page = math.max(1, math.min(s.qa_pages or 1, s.page + delta))
  end
  render(false)
end
function M.focus()
  render(false)
  view.focus()
end
function M.list_snippets()
  local snapshot = stops.snapshot(s.stops)
  vim.ui.select(snapshot, {
    prompt = "CodeTour snippets",
    format_item = function(item)
      local i = stops.snippet_position(s.stops, item.stop)
      local prefix = item.stop._parent_stop and "  ↳ " or ((i and tostring(i) or "…") .. ". ")
      return ("%s%s — %s:%d-%d"):format(
        prefix,
        item.stop.title or "Snippet",
        item.stop.file,
        item.stop.start,
        item.stop["end"]
      )
    end,
  }, function(item)
    if item then
      local i = locate(item.stop)
      if i then
        clear_intent()
        if item.stop._parent_stop then
          M.expand_call(item.stop)
        else
          s.stop, s.box, s.frames = i, stops.first_box(item.stop), {}
          reset_pages()
          M.recenter()
        end
      end
    end
  end)
end

local function box_id(stop, box)
  local i, k = locate(stop, box)
  assert(i, "Box no longer exists")
  return i .. "." .. k
end
local function command(action)
  local cli = s.cli or (vim.fn.stdpath("config") .. "/local-plugins/code-tour.nvim/bin/code-tour")
  return vim.fn.shellescape(cli)
    .. " --"
    .. action
    .. " --pane "
    .. vim.fn.shellescape(vim.v.servername)
    .. " --tour "
    .. s.id
end
-- Path of the file that describes this tour: the saved library entry, else the tmp tour file.
local function tour_path()
  if s.saved and s.saved.record and s.saved.record.id then
    return library.directory() .. "/" .. s.saved.record.id .. ".json"
  end
  if not s.tour_file then
    local dir = (vim.env.TMPDIR or "/tmp") .. "/code-tour-" .. vim.uv.getuid()
    vim.fn.mkdir(dir, "p", 448)
    s.tour_file = dir .. "/" .. s.id .. ".md"
    vim.fn.writefile(vim.split(stops.outline(s.stops), "\n", { plain = true }), s.tour_file)
  end
  return s.tour_file
end

-- Deliver to the connected agent; open one new Herdr tab for it when none is connected.
local function deliver(prompt, action, callback)
  conversation.deliver(s.origin, s.root, prompt, action, callback, function(origin)
    s.origin = origin
  end)
end

function M.save_saved(opts)
  opts = opts or {}
  library.check_directory(opts.library)
  assert(#s.stops > 0, "Open a tour before saving")
  local revision = opts.revision
  if opts.overwrite and not revision and s.saved and s.saved.record.id == opts.overwrite then
    revision = s.saved.revision
  end
  assert(not opts.overwrite or revision, "Overwrite requires --revision or opening that same entry first")
  local record, omitted = saved.export(s, opts)
  if opts.overwrite then record.id = opts.overwrite end
  local result = library.write(record, { overwrite = opts.overwrite, expected_revision = revision, library = opts.library })
  result.omitted = omitted
  if s.saved and s.saved.record.id == result.id then s.saved.revision = result.revision end
  return result
end

function M.open_saved(id, opts)
  opts = opts or {}
  library.check_directory(opts.library)
  local record, revision = library.read(id)
  -- Preflight all mappings before touching the active tour or its queue.
  local plan = saved.prepare(record, vim.tbl_extend("force", opts,
    { reuse_unverified = not s.opts or s.opts.saved_reuse_unverified ~= false }))
  plan.revision = revision
  local root = plan.runtime[1].path
  root = vim.fs.dirname(root)
  activate(plan.runtime, opts, root, false, false, nil)
  saved.start(s, plan, {
    command = function(request) return command("fill " .. request) end,
    tour = function() return library.directory() .. "/" .. id .. ".json" end,
    send = function(prompt, callback) return deliver(prompt, "stay", callback) end,
    refresh = function()
      saved.revalidate(s)
      local active = current()
      if active and s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == active.buf then
        render(false)
      end
    end,
  })
  render(false)
  local counts = {}
  local reused = 0
  for _, entry in ipairs(plan.entries) do
    counts[entry.status] = (counts[entry.status] or 0) + 1
    if entry.reused then reused = reused + 1 end
  end
  return { id = id, title = record.title, revision = revision, library = library.directory(),
    opened = #plan.runtime, counts = counts, reused_unverified = reused, issues = plan.issues }
end

function M.ask(question, action, selected)
  local stop, box = current()
  if not stop then
    return
  end
  local _, ready = stops.note(box)
  assert(ready, "Regenerate this explanation before asking a question")
  action = action or "stay"
  if not question or question == "" then
    local target_stop, target_box = stop, box
    started("Opening question composer…")
    composer.open({
      title = "Box " .. box_id(stop, box),
      submit = function(value, mode)
        if current() ~= target_stop or select(2, current()) ~= target_box then
          notify("Box changed; reopen the question")
          return
        end
        M.ask(value, mode == true and "follow" or (mode or "stay"), selected)
      end,
    })
    return
  end
  assert(
    type(question) == "string" and question:find("%S") and not question:find("[%z\1-\8\11-\31\127]"),
    "Invalid question"
  )
  local id = box_id(stop, box)
  for _, pending in ipairs(s.questions[id] or {}) do
    assert(
      pending.turn.answer or pending.box == box,
      "This box number belongs to a pending reply; wait for it before asking again"
    )
  end
  local first, last = box.start, box["end"]
  if selected then
    first, last = math.max(stop.start, selected[1]), math.min(stop["end"], selected[2])
  end
  -- The originating agent built this tour and holds its notes, examples and
  -- earlier Q&A, so only send what identifies the box and the new question.
  local prompt = ("[code-tour question] tour: %s\nstop %s · %s:%d-%d%s\nQuestion: %s\nReply: %s")
    :format(tour_path(), id, stop.file, first, last, selected and " (selected lines)" or "", question,
      command("answer " .. id))
  local turn = { question = question, box_id = id }
  box.thread[#box.thread + 1] = turn
  s.questions[id] = s.questions[id] or {}
  s.questions[id][#s.questions[id] + 1] = { box = box, stop = stop, turn = turn }
  started(action == "add" and "Sending question draft to agent…" or "Sending question to agent…")
  deliver(prompt, action, function(ok, err)
    if not ok then
      turn.error = tostring(err)
      notify(err)
    elseif err then
      notify(err)
    end
    render(false)
  end)
  render(false)
  return prompt
end

function M.answer(text, id)
  assert(type(text) == "string" and text:find("%S"), "Answer is empty")
  if not id then
    local ids = {}
    for key, queue in pairs(s.questions) do
      for _, request in ipairs(queue) do
        if not request.turn.answer then
          ids[#ids + 1] = key
          break
        end
      end
    end
    assert(#ids == 1, "Supply a box ID when there is not exactly one pending question")
    id = ids[1]
  end
  local queue = s.questions[id] or {}
  local target
  for _, request in ipairs(queue) do
    if not request.turn.answer then
      target = request
      break
    end
  end
  assert(target and locate(target.stop, target.box), "No pending question for box " .. tostring(id))
  target.turn.answer, target.turn.error = text, nil
  if not typing() then
    render(false)
  end
  return { answered = id }
end

local function request_id()
  return vim.fn.sha256(tostring(vim.uv.hrtime()) .. vim.fn.getpid()):sub(1, 16)
end

function M.explain_range(selection, context, action)
  assert(selection.tour == s.id, "The tour changed; select the code again")
  assert(
    vim.api.nvim_buf_is_valid(selection.buf) and vim.api.nvim_buf_get_changedtick(selection.buf) == selection.tick,
    "The selected code changed; select it again"
  )
  local parent, anchor, position = require("code-tour.selection").placement(s, selection)
  local stop, box = current()
  local id = request_id()
  local request = { stop = parent or stop, box = anchor or box, into = anchor, selection = selection }
  if parent and (#parent.parts == 0 or not pcall(stops.validate_coverage, parent)) then
    request.coverage = { path = parent.path, start = parent.start, ["end"] = parent["end"] }
  end
  if not parent then
    request.placeholder = stops.normalize({
      {
        file = selection.path,
        start = selection.start,
        ["end"] = selection["end"],
        title = "Loading explanation…",
        note = "Waiting for the selected code explanation (" .. id .. ")",
      },
    }, s.root)[1]
    request.placeholder.placeholder = id
    table.insert(s.stops, position, request.placeholder)
    -- Inserting before the reader must not change which box they are reading.
    s.stop, s.box = locate(stop, box)
  end
  request.snapshot = stops.snapshot(s.stops)
  s.pending[id] = request
  local prompt = requests.selection({
    tour = tour_path(), root = s.root, selection = selection, coverage = request.coverage, context = context,
    box = anchor or box, box_id = box_id(parent or stop, anchor or box),
    example = (anchor or box).example or (parent or stop).example,
    command = command("fill " .. id),
  })
  request.prompt = prompt
  local function refresh()
    local active = current()
    if
      not typing()
      and s.win
      and vim.api.nvim_win_is_valid(s.win)
      and vim.api.nvim_win_get_buf(s.win) == active.buf
    then
      render(false)
    end
  end
  started(("Generating explanation for %s:%d-%d…"):format(selection.file, selection.start, selection["end"]))
  deliver(prompt, action or "stay", function(ok, err)
    if not ok then
      request.error = tostring(err)
      if request.placeholder then
        request.placeholder.note = "Explain request delivery failed: " .. tostring(err)
      end
      notify(err)
    elseif err then
      notify(err)
    end
    refresh()
  end)
  refresh()
  return id, prompt
end

function M.explain(selected, with_context)
  local _, active_box = current()
  local mode = vim.api.nvim_get_mode().mode
  if not selected and not mode:match("^[vV\22]") and active_box and active_box._saved then
    saved.guard(active_box._saved)
    if active_box._saved.status ~= "ready" then
      local id = saved.retry(s, active_box._saved.id)
      render(false)
      return id
    end
  end
  if not current() then
    notify("Open a tour before adding an explanation")
    return
  end
  local ok, selection = pcall(require("code-tour.selection").capture, s, selected)
  if not ok then
    notify(selection)
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd("normal! \27")
  end
  if with_context then
    started("Opening explanation context composer…")
    composer.open({
      kind = "explain",
      title = ("Explain %s:%d-%d · extra context"):format(selection.file, selection.start, selection["end"]),
      allow_empty = true,
      footer = " ^S explain · ^F explain + follow · ^A draft · ^B save · Esc normal · q close ",
      submit = function(text, action)
        local sent, err = pcall(M.explain_range, selection, text, action)
        if not sent then
          notify(err)
        end
      end,
    })
  else
    return M.explain_range(selection)
  end
end

function M.explain_with_context(selected)
  return M.explain(selected, true)
end

function M.explain_symbol(context, reason, call)
  if context.tour ~= s.id or not locate(context.stop, context.box) then return end
  if not context.expression:find("%S") then notify("Place the cursor on a symbol to inspect it"); return end
  for id, pending in pairs(s.pending) do
    local other = pending.lookup
    if other and other.path == context.path and other.callsite.start == context.callsite.start
      and other.callsite.start_col == context.callsite.start_col and other.expression == context.expression
      and other.tick == context.tick then
      pending.stop, pending.box = context.stop, context.box
      s.awaiting = id
      started("Symbol lookup already in progress: " .. context.expression)
      return id, pending.prompt
    end
  end
  local id = request_id()
  if not call then
    call = stops.normalize({{
      file = context.path, start = context.callsite.start, ["end"] = context.callsite["end"],
      title = context.expression, note = "Waiting for symbol resolution",
    }}, s.root)[1]
    call._parent_stop, call._parent_box = context.stop, context.box
    if context.callsite.start < context.box.start or context.callsite["end"] > context.box["end"] then
      call._parent_box = context.stop
      for _, part in ipairs(context.stop.parts) do
        if part.start <= context.callsite.start and part["end"] >= context.callsite["end"] then
          call._parent_box = part
          break
        end
      end
    end
    call.callsite = vim.deepcopy(context.callsite)
    table.insert(s.stops, s.stop + 1, call)
  end
  call.lazy, call.placeholder, call._symbol_lookup = true, id, true
  local request = { stop = context.stop, box = context.box, placeholder = call,
    call = true, enter = true, lookup = context, snapshot = stops.snapshot(s.stops) }
  s.pending[id], s.awaiting, s.lookup = request, id, nil
  local prompt = requests.symbol({
    tour = tour_path(),
    root = s.root, context = context, reason = reason, box_id = box_id(context.stop, context.box),
    command = command("fill " .. id),
  })
  request.prompt = prompt
  started("Starting agent lookup for " .. context.expression .. "…")
  deliver(prompt, "stay", function(ok, err)
    if not ok and s.pending[id] == request then
      s.pending[id] = nil
      call.placeholder, call.note = nil, "Symbol lookup failed: " .. tostring(err)
      if s.awaiting == id then s.awaiting = nil end
      notify(err)
    elseif err then
      notify(err)
    end
    render(false)
  end)
  render(false)
  return id, prompt
end

function M.explain_location(location, call, inspect)
  local stop, box = current()
  if not stop then
    return
  end
  local path = vim.uv.fs_realpath(vim.uri_to_fname(location.uri or location.targetUri))
  assert(path, "Definition file does not exist")
  local range = location.range or location.targetSelectionRange or location.targetRange
  local line = range.start.line + 1
  local same = not call and not inspect and vim.fs.normalize(path) == stop.path and line >= stop.start and line <= stop["end"]
  local definition_box = stop
  if same then
    for _, part in ipairs(stop.parts) do
      if
        line >= part.start
        and line <= part["end"]
        and (part["end"] - part.start < definition_box["end"] - definition_box.start or part == box)
      then
        definition_box = part
      end
    end
  end
  local id, snapshot = request_id(), stops.snapshot(s.stops)
  local request = { snapshot = snapshot, stop = stop, box = box, into = same and definition_box or nil, call = not same }
  request.enter = inspect == true or call ~= nil
  if call then
    assert(locate(call), "Call branch no longer exists")
    request.placeholder = call
    call.placeholder = id
    call.note = "Waiting for the definition explanation (" .. id .. ")"
  elseif not same then
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    local last = range["end"].line + (range["end"].character == 0 and 0 or 1)
    request.placeholder = stops.normalize({
      {
        file = path,
        start = line,
        ["end"] = math.min(vim.api.nvim_buf_line_count(buf), math.max(line, last)),
        title = "Loading definition…",
        note = "Waiting for the definition explanation (" .. id .. ")",
      },
    }, s.root)[1]
    request.placeholder.placeholder = id
    request.placeholder._parent_stop, request.placeholder._parent_box = stop, box
    local cursor = vim.api.nvim_win_get_cursor(s.win)
    if cursor[1] >= box.start and cursor[1] <= box["end"] then
      request.placeholder.callsite = { start = cursor[1], ["end"] = cursor[1],
        symbol = vim.api.nvim_win_call(s.win, function() return vim.fn.expand("<cword>") end) }
    else
      request.placeholder.callsite = stops.callsite(request.placeholder, stop, box)
    end
    table.insert(s.stops, s.stop + 1, request.placeholder)
  end
  if request.placeholder then
    request.definition = { buf = request.placeholder.buf, tick = vim.api.nvim_buf_get_changedtick(request.placeholder.buf) }
  end
  s.pending[id] = request
  if request.enter then s.awaiting = id end
  local prompt = requests.definition({
    tour = tour_path(),
    root = s.root, stop = stop, box = box, box_id = box_id(stop, box),
    target = request.placeholder, path = path, line = line, same = same,
    definition_box = definition_box, target_id = same and box_id(stop, definition_box) or nil,
    command = command("fill " .. id),
  })
  request.snapshot = stops.snapshot(s.stops)
  request.prompt = prompt
  started(same and "Refining explanation…" or ("Generating definition explanation for " .. vim.fs.basename(path) .. "…"))
  deliver(prompt, "stay", function(ok, err)
    if not ok then
      request.error = tostring(err)
      if request.placeholder then
        request.placeholder.note = "Explain request delivery failed: " .. tostring(err)
        request.placeholder.lazy, request.placeholder.placeholder = true, nil
        s.pending[id] = nil
        if s.awaiting == id then s.awaiting = nil end
      end
      notify(err)
    end
    render(false)
  end)
  render(false)
  return id, prompt
end

function M.expand_call(call)
  local stop, box = current()
  if not stop then return end
  s.lookup = nil
  if not call then
    local calls = stops.calls_in(s.stops, stop, box)
    local cursor = vim.api.nvim_win_get_cursor(s.win)
    local line = vim.api.nvim_buf_get_lines(stop.buf, cursor[1] - 1, cursor[1], false)[1] or ""
    for _, candidate in ipairs(stops.calls_in(s.stops, stop, stop)) do
      if badge.contains(badge.range(stop.buf, candidate.callsite), cursor[1], cursor[2]) then
        call = candidate
        break
      end
    end
    if not call then
      if definition.symbol_at(line, cursor[2]) then return M.explain_definition(true) end
      local from = 1
      while from <= #line do
        local first, last = line:find("[%a_][%w_%.:]*%s*%(", from)
        if not first then break end
        if cursor[2] >= first - 1 and cursor[2] < last then return M.explain_definition(true) end
        from = last + 1
      end
    end
    if not call and #calls == 0 then return M.explain_definition(true) end
    if not call and #calls > 1 then
      started("Choosing a call to inspect…")
      vim.ui.select(calls, {
        prompt = "Inspect call",
        format_item = function(item)
          return (item.title or item.file) .. (stops.ready(item) and " · enter" or " · generate explanation")
        end,
      }, function(item)
        if item and current() == stop and select(2, current()) == box then M.expand_call(item) end
      end)
      return
    end
    call = call or calls[1]
  end
  if not locate(call) then return end
  if stops.ready(call) then
    started("Opening explanation: " .. (call.title or call.file))
    enter_call(call, stop, box)
    reset_pages()
    M.recenter()
    return
  end
  if stop ~= call._parent_stop then
    s.stop, s.box = locate(call._parent_stop, call._parent_box)
  end
  if call.placeholder then
    local request = s.pending[call.placeholder]
    if request and request.lookup and vim.api.nvim_buf_get_changedtick(request.lookup.buf) ~= request.lookup.tick then
      s.pending[call.placeholder] = nil
      if s.awaiting == call.placeholder then s.awaiting = nil end
      call.placeholder, request = nil, nil
    end
    if request then
      request.enter = true
      request.stop, request.box = current()
      s.awaiting = call.placeholder
      started("Explanation already in progress: " .. (call.title or call.file))
    end
    if call.placeholder then return call.placeholder, request and request.prompt end
  end
  if call._symbol_lookup then
    local parent, anchor = current()
    return M.explain_symbol(definition.capture(s, parent, anchor, call.callsite), "Retrying unresolved symbol", call)
  end
  return M.explain_location({
    uri = vim.uri_from_fname(call.path),
    range = { start = { line = call.start - 1, character = 0 }, ["end"] = { line = call["end"], character = 0 } },
  }, call, true)
end

function M.return_to_caller()
  local call = current()
  clear_intent()
  if not call or not call._parent_stop then return end
  started("Returning to caller…")
  resume_caller(call)
  reset_pages()
  M.recenter()
end

function M.explain_definition(inspect)
  inspect = inspect == true
  local stop, box = current()
  if not stop then return end
  local context = definition.capture(s, stop, box)
  s.lookup = context
  started("Looking up " .. (context.expression ~= "" and context.expression or "definition") .. "…")
  local function failed(reason)
    if not definition.active(s, context) then return end
    s.lookup = nil
    if inspect then return M.explain_symbol(context, reason) end
    notify(reason)
  end
  return definition.resolve(context, function(location)
    if not definition.active(s, context) then return end
    local ok, id, prompt = pcall(M.explain_location, location, nil, inspect)
    if not ok then return failed(tostring(id)) end
    s.lookup = nil
    return id, prompt
  end, failed)
end

function M.fill(id, input, opts)
  opts = opts or {}
  local request = assert(s.pending[id], "Unknown or completed explain request " .. tostring(id))
  if request.kind == "saved" then return saved.accept(s, request, input, opts) end
  if request.lookup and type(input) == "table" and input.unresolved ~= nil then
    assert(type(input.unresolved) == "string" and input.unresolved:find("%S"), "Supply an unresolved-symbol reason")
    request.placeholder.placeholder = nil
    request.placeholder.note = input.unresolved
    s.pending[id] = nil
    if s.awaiting == id then s.awaiting = nil end
    notify(input.unresolved)
    return { filled = id, count = 0, navigate = false, unresolved = true }
  end
  if request.lookup then
    assert(vim.api.nvim_buf_is_valid(request.lookup.buf)
      and vim.api.nvim_buf_get_changedtick(request.lookup.buf) == request.lookup.tick,
      "Call-site source changed; request a new symbol explanation")
  end
  assert(not (opts.after and opts.into), "Choose after or into")
  local review = opts.review
  if review == nil then
    review = s.review
  end
  local data = prepare(input, s.root, review, opts.base or s.base)
  local roots = stops.roots(data)
  if request.definition then
    assert(vim.api.nvim_buf_is_valid(request.definition.buf)
      and vim.api.nvim_buf_get_changedtick(request.definition.buf) == request.definition.tick,
      "Definition source changed; request a new explanation")
  end
  if request.selection then
    local selection = request.selection
    assert(
      vim.api.nvim_buf_get_changedtick(selection.buf) == selection.tick,
      "Selected source changed; request a new explanation"
    )
    local ordered = vim.list_extend({}, roots)
    table.sort(ordered, function(a, b)
      return a.start < b.start
    end)
    local required = request.coverage or selection
    local covered = required.start - 1
    for _, stop in ipairs(ordered) do
      assert(
        stop.path == required.path and stop.start >= required.start and stop["end"] <= required["end"],
        "Explanation must stay inside the requested coverage range"
      )
      assert(stop.start <= covered + 1, "Selected code explanation has gaps")
      covered = math.max(covered, stop["end"])
    end
    assert(covered == required["end"], "Explanation must cover the entire requested range")
  end
  -- Only host-captured source supplied in this request can verify new notes.
  if request.selection and request.selection.source_capture and not review then
    local captured = request.selection.source_capture.range
    for _, item in ipairs(data) do
      for _, part in ipairs(stops.boxes(item)) do
        local r = source_engine.line_range(item.buf, part.start, part["end"])
        local a, b = captured.start, captured["end"]
        if item.path == request.selection.path and
          (r.start[1] > a[1] or (r.start[1] == a[1] and r.start[2] >= a[2])) and
          (r["end"][1] < b[1] or (r["end"][1] == b[1] and r["end"][2] <= b[2])) then
          part._evidence = source_engine.capture(item.buf, r).evidence
        end
      end
    end
  end
  local selected_stop, selected_box = current()
  local target_stop, target_box, insertion
  if opts.into then
    local a, b = tostring(opts.into):match("^(%d+)%.(%d+)$")
    local entry = a and request.snapshot[tonumber(a)]
    target_stop, target_box = entry and entry.stop, entry and entry.boxes[tonumber(b)]
    assert(target_box, "Invalid box in request outline")
  elseif opts.after then
    local entry = request.snapshot[tonumber(opts.after)]
    target_stop = assert(entry and entry.stop, "Invalid stop in request outline")
  elseif request.into then
    target_stop, target_box = request.stop, request.into
  else
    target_stop = request.placeholder
  end
  local i, k = locate(target_stop, target_box)
  assert(i, "Request target no longer exists")
  if target_box then
    local range = request.selection and not opts.into and not opts.after and (request.coverage or request.selection) or target_box
    local parts = {}
    for _, stop in ipairs(roots) do
      assert(
        stop.path == target_stop.path and stop.start >= range.start and stop["end"] <= range["end"],
        "Refinement must stay inside its target box"
      )
      local additions = #stop.parts > 0 and stop.parts or { stop }
      for _, part in ipairs(additions) do
        if stop.example then
          part.example = stops.example_range(stop.example, part.start, part["end"])
        end
        parts[#parts + 1] = part
      end
    end
    local cover = range.start - 1
    local sorted = vim.list_extend({}, parts)
    table.sort(sorted, function(a, b)
      return a.start < b.start
    end)
    for _, part in ipairs(sorted) do
      assert(part.start <= cover + 1, "Refinement has gaps")
      cover = math.max(cover, part["end"])
    end
    assert(cover == range["end"], "Refinement must cover its target box")
    local after = target_box == target_stop and 0 or k - 1
    local combined = vim.list_extend({}, target_stop.parts)
    for n, part in ipairs(parts) do table.insert(combined, after + n, part) end
    stops.validate_coverage(target_stop, combined)
    insertion = parts[1]
    if request.coverage then
      insertion = nil
      for _, part in ipairs(parts) do
        local selection = request.selection
        if part.start >= selection.start and part["end"] <= selection["end"] then insertion = insertion or part end
      end
      assert(insertion, "Give the selected range its own subexplanation(s), separate from the rest of the overview")
    end
    if review then
      -- Replace only this reply's ranges so sibling diff information survives.
      target_stop.added, target_stop.removed = target_stop.added or {}, target_stop.removed or {}
      for _, stop in ipairs(roots) do
        for line = stop.start, stop["end"] do
          target_stop.added[line] = (stop.added or {})[line]
        end
        local retained = {}
        for _, removed in ipairs(target_stop.removed) do
          local lines, owners = {}, {}
          for index, line in ipairs(removed.lines) do
            local owner = (removed.owners or {})[index] or removed.line
            if owner < stop.start or owner > stop["end"] then
              lines[#lines + 1], owners[#owners + 1] = line, owner
            end
          end
          if #lines > 0 then
            retained[#retained + 1] = { line = removed.line, above = removed.above, lines = lines, owners = owners }
          end
        end
        vim.list_extend(retained, stop.removed or {})
        target_stop.removed = retained
      end
    end
    target_stop.parts = combined
    -- Refining a box adopts the reply's callee branches into the existing
    -- snippet. Overview calls attach to the refined box when its parts replace it.
    local children = {}
    for _, child in ipairs(data) do
      if child._parent_stop then
        for _, root in ipairs(roots) do
          if child._parent_stop == root then
            child._parent_stop = target_stop
            if child._parent_box == root and #root.parts > 0 then child._parent_box = target_box end
            break
          end
        end
        children[#children + 1] = child
      end
    end
    for n, child in ipairs(children) do table.insert(s.stops, i + n, child) end
  else
    local replace = not opts.after and request.placeholder == target_stop
    if replace then
      table.remove(s.stops, i)
    else
      i = i + 1
    end
    for _, root in ipairs(roots) do
      root._parent_stop, root._parent_box = target_stop._parent_stop, target_stop._parent_box
      root.callsite = target_stop.callsite
      root.next = target_stop.next
    end
    for n, stop in ipairs(data) do
      table.insert(s.stops, i + n - 1, stop)
    end
    target_stop, insertion = data[1], data[1]
  end
  -- Overrides still consume and remove the original placeholder by identity.
  if request.placeholder then
    local placeholder_index = locate(request.placeholder)
    if placeholder_index then
      table.remove(s.stops, placeholder_index)
    end
  end
  s.pending[id] = nil
  local previous_i, previous_k = locate(selected_stop, selected_box)
  saved.sync(s)
  if previous_i then
    s.stop, s.box = previous_i, previous_k
  end
  -- A lazy response may finish after the reader has already continued. Keep
  -- their current box unless they are still waiting at this call's origin.
  local waiting = request.enter and s.awaiting == id and selected_stop == request.stop and selected_box == request.box
  local navigate = not typing() and (not request.call or waiting)
  if s.awaiting == id then s.awaiting = nil end
  if navigate then
    if request.call and waiting and not opts.into and not opts.after then
      enter_call(target_stop, request.stop, request.box)
    else
      s.stop, s.box = locate(target_stop, insertion)
    end
    reset_pages()
    M.recenter()
  else
    if not previous_i then
      s.stop, s.box = locate(target_stop, insertion)
    end
    if typing() then s.arrival = { stop = target_stop, box = insertion } end
  end
  return { filled = id, count = #data, navigate = navigate }
end

function M.load(path)
  if not path or path == "" then
    path = vim.fn.getcwd() .. "/.nvim/code-tour.json"
    local legacy = vim.fn.getcwd() .. "/.nvim/walkthrough.json"
    if not vim.uv.fs_stat(path) and vim.uv.fs_stat(legacy) then path = legacy end
  end
  path = vim.fn.fnamemodify(path, ":p")
  local ok, result = pcall(function()
    local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    return M.show(data, { root = vim.fs.dirname(vim.fs.dirname(path)), origin = data.origin })
  end)
  if not ok then
    notify(result)
  end
  return ok
end
function M.cancel()
  saved.cancel(s)
  for _, queue in pairs(s.questions) do
    for _, request in ipairs(queue) do
      if not request.turn.answer then
        request.turn.error = "Cancelled"
      end
    end
  end
  -- Collapsed cancelled requests can be expanded again in the same tour.
  for _, request in pairs(s.pending) do
    if request.call and request.placeholder then
      if current() == request.placeholder then
        s.stop, s.box = locate(request.stop, request.box)
      end
      request.placeholder.placeholder = nil
      request.placeholder.lazy = true
      request.placeholder.note = "Expand to explain this call."
    end
  end
  s.pending, s.questions, s.arrival, s.awaiting, s.lookup = {}, {}, nil, nil, nil
  s.id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. vim.fn.getpid()):sub(1, 16)
end
function M.state()
  return s
end
M.render = render

function M.setup(opts)
  s.opts = vim.tbl_extend("force", { page_lines = 18, smooth_scroll = true, saved_request_timeout_ms = 300000,
    saved_batch_size = 12, saved_batch_chars = 40000, saved_reuse_unverified = true }, opts or {})
  for _, name in ipairs({ "saved_request_timeout_ms", "saved_batch_size", "saved_batch_chars" }) do
    local value = s.opts[name]
    assert(type(value) == "number" and value > 0 and value == math.floor(value), name .. " must be a positive integer")
  end
  assert(type(s.opts.saved_reuse_unverified) == "boolean", "saved_reuse_unverified must be a boolean")
  require("code-tour.instance").register()
  for name, spec in pairs({
    CodeTourStop = { bg = "#273668" },
    CodeTourFocus = { bg = "#314888" },
    CodeTourDiffAdd = { bg = "#25352e" },
    CodeTourDiffAddFocus = { bg = "#314b3a" },
    CodeTourDiffDelete = { fg = "#b87d85", bg = "#39252d" },
    CodeTourDiffDeleteFocus = { fg = "#f0a2ac", bg = "#56313d" },
    CodeTourSnippet = { link = "CodeTourStop" },
    CodeTourRange = { link = "CodeTourFocus" },
    CodeTourMeta = { link = "Comment" },
    CodeTourExample = { link = "DiagnosticVirtualTextInfo" },
  }) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  badge.highlight()
  require("code-tour.markdown").highlight()
  local old_return = vim.fn.maparg("<leader>au", "n", false, true)
  if old_return.desc == "CodeTour au" then vim.keymap.del("n", "<leader>au") end
  local mappings = {
    ah = M.toggle,
    aj = function()
      M.next_explanation(1)
    end,
    ak = function()
      M.next_explanation(-1)
    end,
    an = function()
      M.next_snippet(1)
    end,
    ap = function()
      M.next_snippet(-1)
    end,
    al = M.list_snippets,
    ar = M.ask,
    ae = M.explain,
    aE = M.explain_with_context,
    ad = function() M.expand_call() end,
    ao = M.return_to_caller,
    af = M.focus,
    aq = M.stop,
    az = M.recenter,
    ["a]"] = function()
      M.page(1)
    end,
    ["a["] = function()
      M.page(-1)
    end,
  }
  for key, callback in pairs(mappings) do
    vim.keymap.set("n", "<leader>" .. key, callback, { desc = "CodeTour " .. key })
  end
  vim.keymap.set("x", "<leader>ar", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    M.ask(nil, "stay", { math.min(a, b), math.max(a, b) })
  end, { desc = "Ask about selected tour lines" })
  vim.keymap.set("x", "<leader>ae", M.explain, { desc = "Explain selected code in tour" })
  vim.keymap.set("x", "<leader>aE", M.explain_with_context, { desc = "Explain selected code with extra context" })
  local commands = {
    CodeTourToggle = M.toggle,
    CodeTourStop = M.stop,
    CodeTourList = M.list_snippets,
    CodeTourFocus = M.focus,
    CodeTourCancel = M.cancel,
    CodeTourRecenter = M.recenter,
    CodeTourExplain = M.explain,
    CodeTourExplainContext = M.explain_with_context,
    CodeTourDefinition = M.explain_definition,
    CodeTourExpand = function() M.expand_call() end,
    CodeTourReturn = M.return_to_caller,
  }
  for name, callback in pairs(commands) do
    vim.api.nvim_create_user_command(name, callback, { force = true })
  end
  vim.api.nvim_create_user_command("CodeTourLoad", function(args)
    M.load(args.args ~= "" and args.args or nil)
  end, { nargs = "?", complete = "file", force = true })
  vim.api.nvim_create_user_command("CodeTourAsk", function(args)
    M.ask(args.args)
  end, { nargs = "*", force = true })
  vim.api.nvim_create_user_command("CodeTourReview", function(args)
    local ok, err = pcall(M.review, args.args)
    if not ok then
      notify(err)
    end
  end, { nargs = "?", force = true })
  local group = vim.api.nvim_create_augroup("CodeTour", { clear = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    group = group,
    callback = function()
      if s.saved then
        saved.revalidate(s)
        local active = current()
        if active and s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == active.buf then
          render(false)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = badge.highlight })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "TabEnter" }, {
    group = group,
    callback = function()
      if not scroll.active() then
        render(false)
      end
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      if s.arrival then
        -- Preserve the user's current input location; recenter is an explicit navigation.
        notify("Definition explanation ready; use <leader>al to visit it", vim.log.levels.INFO)
        s.arrival = nil
      end
      render(false)
    end,
  })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      require("code-tour.instance").register()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      M.cancel()
      require("code-tour.instance").unregister()
    end,
  })
end
return M
