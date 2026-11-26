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
local walk_move, walk_upcoming, walk_numbers_for_nav, edge_key, walk_steps, walk_index, route_summary, plan_walk -- defined once the graph helpers exist
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

-- A whole-line background. It is an `hl_eol` range rather than `line_hl_group`, because a
-- line highlight overrides every range highlight's background and would hide call badges.
local function paint_line(buf, line, group, priority)
  vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
    end_row = line, end_col = 0, hl_group = group, hl_eol = true, priority = priority, strict = false,
  })
end

local function decorate(stop, box, layout)
  clear()
  local count = vim.api.nvim_buf_line_count(stop.buf)
  for _, other in ipairs(s.stops) do
    if other ~= stop and other.buf == stop.buf and stops.ready(other) then
      for line = other.start, math.min(other["end"], count) do
        paint_line(stop.buf, line, (other.added or {})[line] and "CodeTourDiffAdd" or "CodeTourStop", 100)
      end
    end
  end
  for line = stop.start, math.min(stop["end"], count) do
    local focused = line >= box.start and line <= box["end"]
    local group = focused and not box.byte_range and "CodeTourFocus" or "CodeTourStop"
    if (stop.added or {})[line] then
      group = focused and "CodeTourDiffAddFocus" or "CodeTourDiffAdd"
    end
    paint_line(stop.buf, line, group, 110)
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
        -- Where parts nest, the deepest part owns the sign on a shared line.
        priority = 120 + (part._depth or 1),
      })
    end
  end
  local upcoming, done, folded = nil, {}, {}
  if walk_upcoming then
    upcoming, done, folded = walk_upcoming(stop, box)
  end
  -- Call badges stay visible whichever box is focused: every prepared call of this
  -- snippet, and of the other snippets shown in the same buffer.
  local badges = {}
  for _, owner in ipairs(s.stops) do
    if owner.buf == stop.buf and (owner == stop or stops.ready(owner)) then
      for _, call in ipairs(stops.calls_in(s.stops, owner, owner, true)) do
        local folded_optional = call.ast and not call.next and call.level and s.zoom and call.level > s.zoom
        local range = not folded_optional and badge.range(stop.buf, call.callsite)
        if range then
          local site = call.callsite
          -- nil outside the walk (older labels); true for the edge aj follows next, else false.
          local current = upcoming ~= nil and call.next == true and upcoming.symbol == site.symbol
            and upcoming.source == owner.path .. ":" .. owner.start .. "-" .. owner["end"]
            and upcoming.callsite ~= nil and upcoming.callsite.start == site.start
            and upcoming.callsite.start_col == site.start_col
          local finished = call.next == true and not current
            and done[edge_key(owner.path .. ":" .. owner.start .. "-" .. owner["end"], site)] or nil
          local is_folded = call.next == true and not current and not finished
            and folded[edge_key(owner.path .. ":" .. owner.start .. "-" .. owner["end"], site)] or nil
          -- `main` only marks a gold call: a main-flow edge is always walked (SPEC-ast-graph
          -- §3.7), so a stray `main` on an optional call draws no ★.
          badges[#badges + 1] = { range = range, next_call = call.next, current = current,
            done = finished, folded = is_folded, main = call.next == true and call.main == true or nil }
        end
      end
    end
  end
  -- Gaps (§8.3, §10): every box of the same snippets may list sites where the main flow
  -- breaks off; each is a badge with its reason. They come after the calls, so a gap on
  -- the same range as a call is drawn on top of it.
  for _, owner in ipairs(s.stops) do
    if owner.buf == stop.buf and (owner == stop or stops.ready(owner)) then
      for _, part in ipairs(stops.boxes(owner)) do
        if not part._unlocated then
          for _, gap in ipairs(part.gaps or {}) do
            local range = badge.range(stop.buf, gap.callsite)
            if range then badges[#badges + 1] = { range = range, gap = gap.reason or true } end
          end
        end
      end
    end
  end
  badge.draw_all(stop.buf, ns, badges)
  local example = stop.recorded_example or box.example or stop.example
  for line, value in pairs((example or {}).values or {}) do
    local label = type(value) == "table" and value.value or value
    if example.source == "recorded" then label = "[recorded] " .. label end
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
    -- The box grows or shrinks in place (answers, pages). When it sits above the view's top line, keep
    -- all of its rows in view; a stale topfill would cut the top of the box off, notably at line 1.
    if layout.above and saved.topline == layout.first and (saved.topfill or 0) > 0 then
      saved.topfill = virtual_count
    end
    vim.api.nvim_win_call(s.win, function()
      vim.fn.winrestview(saved)
    end)
  end
end

local function cli_path()
  return s.cli or (vim.fn.stdpath("config") .. "/local-plugins/code-tour.nvim/bin/code-tour")
end
local function command(action)
  local cli = cli_path()
  return vim.fn.shellescape(cli)
    .. " --"
    .. action
    .. " --pane "
    .. vim.fn.shellescape(vim.v.servername)
    .. " --tour "
    .. s.id
end
local function request_id()
  return vim.fn.sha256(tostring(vim.uv.hrtime()) .. vim.fn.getpid()):sub(1, 16)
end

-- Turn the `pending` stops of a payload into placeholders the agent fills later, in walk
-- order. Returns the list the agent needs ({id, file, start, end, title, command}), or nil.
local function register_pending(data)
  local list = {}
  local snapshot
  for _, stop in ipairs(data) do
    if stop.pending then
      snapshot = snapshot or stops.snapshot(s.stops)
      local id = request_id()
      stop.pending, stop.placeholder, stop.stream = nil, id, true
      s.pending[id] = { kind = "stream", stream = true, placeholder = stop, snapshot = snapshot }
      list[#list + 1] = {
        id = id, file = stop.file, start = stop.start, ["end"] = stop["end"], title = stop.title,
        command = command("fill " .. id),
      }
    end
  end
  return #list > 0 and list or nil
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
    s.stops, s.pending, s.questions, s.frames, s.walk_index, s.zoom = {}, {}, {}, {}, nil, nil
    s.stop, s.box = 1, 1
    s.ast = nil
  end
  clear_intent()
  s.frames = {}
  local first = #s.stops + 1
  vim.list_extend(s.stops, data)
  s.root, s.review, s.base = root, review, base
  s.lazy_agent = opts.lazy_agent
  s.standalone = opts.standalone == true
  s.origin = not s.standalone and (opts.origin or (append and s.origin or nil)) or nil
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
  -- Snippets marked `pending` are streamed: shown as placeholders on the route, then
  -- filled in by the agent in walk order (see M.fill).
  local result = activate(data, opts, root, append, review, base)
  result.pending = register_pending(data)
  if result.pending then render(false) end
  saved.sync(s)
  result.route = route_summary()
  return result
end

-- Show a tour read from a JSON file. The CLI sends the path rather than the data
-- because msgpack-RPC drops requests nested deeper than about 32 levels, which a
-- long chain of nested calls easily exceeds.
function M.show_file(path, opts)
  local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  opts = opts or {}
  -- A tmp file is only the tour's identity when this call starts a tour.
  return M.show(data, opts)
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
  -- Walk mode: the same route as aj, one stop per snippet instead of per box. A
  -- snippet's consecutive steps are one stop, and coming back to a caller after a
  -- branch is a stop of its own, exactly as when walking box by box.
  local steps = walk_steps and walk_steps()
  local at = steps and #steps > 0 and walk_index(steps)
  if at then
    local function run_start(i)
      while i > 1 and steps[i - 1].stop == steps[i].stop do
        i = i - 1
      end
      return i
    end
    local target = delta == 0 and run_start(at) or at
    for _ = 1, math.abs(delta) do
      if delta > 0 then
        local j = target
        while j <= #steps and steps[j].stop == steps[target].stop do
          j = j + 1
        end
        target = j <= #steps and j or target
      else
        local before = run_start(target) - 1
        target = before >= 1 and run_start(before) or run_start(target)
      end
    end
    -- Snippet navigation always lands on the overview; aj continues from the step.
    s.walk_index, s.frames = target, {}
    position({ stop = steps[target].stop, box = stops.first_box(s.stops[steps[target].stop]) })
    reset_pages()
    s.visible = true
    render(true)
    return
  end
  -- Off the walk (inside an optional branch): continue from the snippet it hangs off.
  local numbers = walk_numbers_for_nav and walk_numbers_for_nav()
  if numbers and #numbers.order > 0 then
    local here = numbers.owner[s.stop] or 0
    local target = numbers.order[math.max(1, math.min(#numbers.order, here + delta))]
    s.stop, s.box, s.frames, s.walk_index = target, stops.first_box(s.stops[target]), {}, nil
    reset_pages()
    s.visible = true
    render(true)
    return
  end
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
  if walk_move(delta) then
    reset_pages()
    s.visible = true
    render(true)
    return
  end
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
-- Jump to the first page of the previous/next question of the focused box's thread.
function M.question(delta)
  local firsts, owner = s.qa_firsts, s.qa_owner
  if not firsts or #firsts < 2 then return end
  local turn = math.max(1, math.min(#firsts, (owner[s.page] or #firsts) + delta))
  s.page = firsts[turn]
  render(false)
end
function M.focus()
  render(false)
  view.focus()
end
function M.list_snippets()
  local snapshot = stops.snapshot(s.stops)
  -- Walk mode lists snippets in reading order, with optional branches right after the
  -- snippet they hang off; storage order only breaks ties.
  local numbers = walk_numbers_for_nav and walk_numbers_for_nav()
  if numbers then
    local rank = {}
    for position, item in ipairs(snapshot) do
      local index = locate(item.stop)
      local own = index and numbers.by_stop[index]
      rank[item] = { own or (index and numbers.owner[index]) or math.huge, own and 0 or 1, position }
    end
    table.sort(snapshot, function(a, b)
      for k = 1, 3 do
        if rank[a][k] ~= rank[b][k] then return rank[a][k] < rank[b][k] end
      end
      return false
    end)
  end
  vim.ui.select(snapshot, {
    prompt = "CodeTour snippets",
    format_item = function(item)
      local i = stops.snippet_position(s.stops, item.stop)
      local numbers = walk_numbers_for_nav and walk_numbers_for_nav()
      local prefix = item.stop._parent_stop and "  ↳ " or ((i and tostring(i) or "…") .. ". ")
      if numbers then
        local n = numbers.by_stop[locate(item.stop)]
        prefix = n and (n .. ". ") or "  ↳ "
      end
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

-- Deliver through the configured agent backend (see `agent` in setup()).
local function deliver(prompt, action, callback)
  conversation.deliver(s.origin, s.root, prompt, action, callback, function(origin)
    s.origin = origin
  end, s.opts and s.opts.agent)
end

-- Stale explanations (saved tours only) with the boxes that depend on them. The report
-- file sits beside the tour file; requests cite it while anything is stale.
-- Sidecar files (stale report, graph) live in tmp, never in the saved-tour library.
local function sidecar(suffix)
  local dir = (vim.env.TMPDIR or "/tmp") .. "/code-tour-" .. vim.uv.getuid()
  vim.fn.mkdir(dir, "p", 448)
  local id = s.saved and s.saved.record and s.saved.record.id or s.id
  return dir .. "/" .. id .. "." .. suffix .. ".json"
end
local function box_id_of(stop, box)
  local i, k = locate(stop, box)
  return i and (i .. "." .. k) or "?"
end
local function build_graph()
  return require("code-tour.graph").build(s, box_id_of, tour_path())
end
local function stale_items()
  return require("code-tour.stale").collect(build_graph())
end
local function stale_report()
  local stale = require("code-tour.stale")
  local items = stale_items()
  local path = sidecar("stale")
  stale.write(items, path, tour_path())
  return items, stale.summary(items, path)
end
local function stale_line()
  if s.saved then
    return (select(2, stale_report()))
  end
end
local function warn_stale()
  if not s.saved then
    return
  end
  local items = stale_report()
  local ids = {}
  for _, item in ipairs(items) do
    ids[#ids + 1] = item.id
  end
  local key = table.concat(ids, ",")
  if key == s.stale_key then
    return
  end
  s.stale_key = key
  if #items == 0 then
    return
  end
  local linked = {}
  for _, item in ipairs(items) do
    for _, link in ipairs(item.update_also) do
      linked[link.id] = true
    end
  end
  local names = vim.tbl_keys(linked)
  table.sort(names)
  notify(
    "Stale explanation" .. (#items > 1 and "s" or "") .. ": " .. key
      .. (#names > 0 and ("; linked boxes to refresh: " .. table.concat(names, ", ")) or "")
      .. (require("code-tour.keys").lhs("explain")
        and (". " .. require("code-tour.keys").lhs("explain") .. " on a stale box regenerates it and its linked boxes.")
        or ". Explain the box again to regenerate it and its linked boxes."),
    vim.log.levels.WARN
  )
end

-- The graph drives reading order: depth-first over every edge, coming back to a
-- snippet between its edges (see walk.lua). Returns false to fall back to the
-- older route (e.g. when the graph has a cycle), after saying why.
-- The walk plan for the tour, limited to the zoom depth unless `unzoomed` is set.
plan_walk = function(unzoomed)
  local graph = build_graph()
  local plan, err = require("code-tour.walk").plan(graph, { max_depth = not unzoomed and s.zoom or nil })
  return plan, err, graph
end
walk_steps = function()
  local plan, err = plan_walk()
  if not plan then
    return nil, err
  end
  local steps = {}
  for _, step in ipairs(plan.steps) do
    local si, ki = step.box:match("^(%d+)%.(%d+)$")
    local stop = s.stops[tonumber(si)]
    local box = stop and stops.boxes(stop)[tonumber(ki)]
    if stop and box and stops.ready(stop) and not box._unlocated then
      steps[#steps + 1] = { stop = tonumber(si), box = tonumber(ki), id = step.box, kind = step.kind, via = step.via }
    end
  end
  return steps, nil, plan
end
-- Index of the step the reader is on: the remembered one when it still matches, else the first.
walk_index = function(steps)
  local stop, box = current()
  local here = box_id_of(stop, box)
  if s.walk_index and steps[s.walk_index] then
    if steps[s.walk_index].id == here then
      return s.walk_index
    end
    -- an leaves the reader on a snippet's overview while the walk position stays at
    -- the step that brought them there (for a return, the box that made the call).
    local si, ki = here:match("^(%d+)%.(%d+)$")
    if tonumber(ki) == 1 and steps[s.walk_index].stop == tonumber(si) then
      return s.walk_index
    end
  end
  for n, step in ipairs(steps) do
    if step.id == here then
      return n
    end
  end
end
walk_move = function(delta)
  local steps, err = walk_steps()
  if not steps then
    notify(err, vim.log.levels.WARN)
    return false
  end
  if #steps == 0 then
    return false
  end
  -- A reader inside an optional branch (opened with ad) is off the walk: the older
  -- route returns them to the box they entered from, which is on the walk.
  local index = walk_index(steps)
  if not index then
    local stop = current()
    local on_walk = false
    for _, step in ipairs(steps) do
      on_walk = on_walk or s.stops[step.stop] == stop
    end
    if not on_walk then
      return false
    end
    index = 0
  end
  local direction = delta < 0 and -1 or 1
  for _ = 1, math.abs(delta) do
    index = math.max(1, math.min(#steps, index + direction))
  end
  s.walk_index, s.frames = index, {}
  position(steps[index])
  local arrived = s.stops[steps[index].stop]
  if arrived and arrived.stream and arrived.placeholder then
    notify(("Still being written: %s"):format(arrived.title or "next snippet"), vim.log.levels.INFO)
  end
  return true
end
-- The edge the next press of aj will follow from this box (if any), and the set of
-- edges the walk has already finished, keyed by edge_key().
edge_key = function(source, site)
  return ("%s|%s|%s|%s"):format(source, site.symbol or "", site.start or "", site.start_col or "")
end
walk_upcoming = function(stop, box)
  local steps, _, plan = walk_steps()
  if not steps then
    return nil, {}, {}
  end
  local index = walk_index(steps)
  local done, folded = {}, {}
  for _, f in ipairs(plan.folded or {}) do
    if f.callsite then
      folded[edge_key(f.source, { symbol = f.symbol, start = f.callsite.start, start_col = f.callsite.start_col })] = true
    end
  end
  -- Edges walked up to and including the current step: being inside a callee counts too.
  for n = 1, index or 0 do
    local via = steps[n].via
    if steps[n].kind == "enter" and via and via.callsite then
      done[edge_key(via.source, { symbol = via.symbol, start = via.callsite.start, start_col = via.callsite.start_col })] = true
    end
  end
  -- The next snippet is the next edge the walk enters, whichever box it leaves from.
  for n = (index or #steps) + 1, #steps do
    if steps[n].kind == "enter" and steps[n].via then
      return steps[n].via, done, folded
    end
  end
  return nil, done, folded
end

-- In walk mode snippets are numbered in the order the walk first reaches them.
-- Returns { by_stop = { [stop index] = n }, order = { stop index... } } or nil
-- (older route, or a graph the walk cannot plan). Snippets off the walk, such as
-- optional branches, have no number.
local function walk_numbers()
  if #s.stops == 0 then
    return nil
  end
  local plan, _, graph = plan_walk()
  if not plan then
    return nil
  end
  local number_of, order, first_stop = {}, {}, {}
  for _, node in ipairs(graph.nodes) do
    first_stop[node.id] = node.stops[1]
  end
  for _, step in ipairs(plan.steps) do
    if (step.kind == "root" or step.kind == "enter") and not number_of[step.node] then
      local index = first_stop[step.node]
      if index and stops.ready(s.stops[index]) then
        order[#order + 1] = index
        number_of[step.node] = #order
      end
    end
  end
  local by_stop = {}
  for _, node in ipairs(graph.nodes) do
    for _, index in ipairs(node.stops) do
      by_stop[index] = number_of[node.id]
    end
  end
  -- Optional branches inherit the number of the walked snippet they hang off.
  local index_of = {}
  for i, stop in ipairs(s.stops) do
    index_of[stop] = i
  end
  local owner = {}
  for i, stop in ipairs(s.stops) do
    local at = stop
    while at and not by_stop[index_of[at]] do
      at = at._parent_stop
    end
    owner[i] = at and by_stop[index_of[at]] or nil
  end
  -- How many snippets the zoom hides from the walk.
  local folded = 0
  if s.zoom then
    local full = require("code-tour.walk").plan(graph)
    local seen = {}
    for _, step in ipairs(full and full.steps or {}) do
      if (step.kind == "root" or step.kind == "enter") and not seen[step.node] then
        seen[step.node] = true
        folded = folded + 1
      end
    end
    folded = math.max(0, folded - #order)
  end
  return { by_stop = by_stop, owner = owner, order = order, folded = folded }
end
s.snippet_numbers = walk_numbers

-- How long the walk is and what it leaves out, so the agent can prune to the level of
-- detail asked for. `broken` lists gold calls that hang below a call that is not walked:
-- they are never reached, which breaks the end-to-end path.
route_summary = function()
  if #s.stops == 0 then
    return nil
  end
  local plan, _, graph = plan_walk(true)
  if not plan then
    return nil
  end
  local walked, snippets = {}, 0
  for _, step in ipairs(plan.steps) do
    if (step.kind == "root" or step.kind == "enter") and not walked[step.node] then
      walked[step.node] = true
      snippets = snippets + 1
    end
  end
  local optional, lazy, broken = 0, 0, {}
  for _, node in ipairs(graph.nodes) do
    if node.lazy then
      lazy = lazy + 1
    elseif not walked[node.id] then
      optional = optional + 1
    end
  end
  local by_id = {}
  for _, node in ipairs(graph.nodes) do
    by_id[node.id] = node
  end
  for _, link in ipairs(graph.links) do
    local target = by_id[link.target]
    if link.via == "call" and link.relation == "next" and not walked[link.source] and not walked[link.target]
      and target and not target.lazy and not (by_id[link.source] or {}).lazy then
      broken[#broken + 1] = { from = by_id[link.source].label, to = target.label }
    end
  end
  local shadowed = {}
  for _, item in ipairs(plan.shadowed or {}) do
    shadowed[#shadowed + 1] = { from = (by_id[item.from] or {}).label, to = (by_id[item.to] or {}).label, level = item.level }
  end
  return {
    snippets = snippets, boxes = #plan.steps, optional = optional, lazy = lazy, broken = broken, refs = #plan.refs,
    levels = plan.max_depth, shadowed = shadowed,
  }
end
walk_numbers_for_nav = walk_numbers

-- a- / a+ : fold or unfold the walk by call depth, using only what is already authored.
-- Folded calls are not walked (they behave like optional ones) and are marked on screen.
function M.zoom(delta)
  if #s.stops == 0 then
    return
  end
  local full, err = plan_walk(true)
  if not full then
    notify(err, vim.log.levels.WARN)
    return
  end
  local before = walk_numbers()
  local level = (s.zoom or full.max_depth) + delta
  if level >= full.max_depth then
    s.zoom = nil
  else
    s.zoom = math.max(0, level)
  end
  local after = walk_numbers()
  -- A reader inside a branch that just folded goes back to the nearest snippet still on the walk.
  if before and after and before.by_stop[s.stop] and not after.by_stop[s.stop] then
    local at = s.stops[s.stop]
    local index_of = {}
    for i, stop in ipairs(s.stops) do
      index_of[stop] = i
    end
    while at and not after.by_stop[index_of[at]] do
      at = at._parent_stop
    end
    if at then
      s.stop, s.box = index_of[at], stops.first_box(at)
    end
  end
  s.walk_index, s.frames = nil, {}
  reset_pages()
  render(true)
  notify(("Detail: %s (%d folded)"):format(s.zoom and ("depth " .. s.zoom) or "full", after and after.folded or 0),
    vim.log.levels.INFO)
end

-- Write the tour graph (nodes = snippets, links = next/optional routes) and return its path.
function M.graph()
  assert(#s.stops > 0, "Open a tour first")
  local graph = build_graph()
  if s.ast then
    s.ast:apply_edge_notes()
    graph.tour, graph.symbol_graph = require("code-tour.ast.codegraph").tour(s.ast)
  end
  local path = require("code-tour.graph").write(graph, sidecar("graph"))
  return { path = path, nodes = #graph.nodes, links = #graph.links }
end

-- Write the project's symbol graph (SPEC-ast-graph §15) and return its path.
function M.concepts(opts)
  return require("code-tour.ast").concepts(opts)
end

function M.analyze(opts)
  return require("code-tour.ast").analyze(opts)
end

function M.code_graph(opts)
  return require("code-tour.ast").code_graph(opts)
end

-- The outline of an AST-backed tour, without opening it (SPEC-ast-graph §9.1, --dry-run).
function M.ast_outline(request)
  request = request or {}
  return require("code-tour.ast").outline(request.entries, request)
end

-- AST-backed tours (SPEC-ast-graph phase 3) ------------------------------------------
-- s.ast is the live tour (ast/live.lua): the L3 state the stops are projected from.
-- Boxes carry `anchor` ("n1", "n1.r2") and `address`; fills, `ad` on lazy sites,
-- selections and detail changes go through it and update the stops in place.

local function ast_ctx()
  return { token = s.id, cli = cli_path(), servername = vim.v.servername, root = s.root }
end

local ast_refresh

-- Test examples are optional children of the symbol's overview. They have no call badge.
local function ast_attach_examples(live, data)
  local examples = require("code-tour.ast.examples")
  local extra, offered = {}, {}
  for _, stop in ipairs(data) do
    local sn = stop.ast and not stop.lazy and live.snippets[stop.anchor]
    if sn then
      local test = examples.tests(live.idx, { sn.symbol })[1]
      if test then
        local input = examples.snippet(test)
        local why = input.why
        input.why = nil
        local example = stops.normalize({ input }, live.root)[1]
        example.why = why
        example._parent_stop, example._parent_box = stop, stop
        stop.test_example = example
        extra[#extra + 1] = example
        offered[sn.n] = { kind = "example", why = why, test = test }
      end
    end
  end
  if next(offered) then live.tour.examples = offered end
  vim.list_extend(data, extra)
end

-- Finding the tests means resolving every one of them, so the first time it happens in the
-- background: the tour is shown at once and the examples join it when they are ready.
local function ast_examples(live, data)
  if not require("code-tour.ast").options.examples.tests then return end
  local examples = require("code-tour.ast.examples")
  if examples.ready(live.idx) then
    return ast_attach_examples(live, data)
  end
  if live.examples_job and live.examples_job == live.idx.example_job then return end
  live.examples_job = examples.prepare(live.idx, function() return s.ast == live end, function()
    live.examples_job = nil
    ast_attach_examples(live, s.stops)
    ast_refresh()
    if not typing() then render(false) end
  end)
end

local function no_example()
  local live = s.ast
  return live and live.examples_job and live.examples_job == live.idx.example_job
    and "Test examples are still being collected" or nil
end

-- Refresh every AST box from the live tour: notes, gists, writing marks and Q&A
-- threads. Boxes re-render in place; the reader is never moved (§9.4).
function ast_refresh()
  local live = s.ast
  if not live then
    return
  end
  live:apply_edge_notes()
  local recordings = require("code-tour.ast.recordings")
  local record = live.recorded
  if record and not recordings.valid(live, record) then record = nil end
  local records = {}
  for _, stop in ipairs(s.stops) do
    local parent = stop.caller and live.snippets[stop.caller]
    for _, site in ipairs(parent and parent.sites or {}) do
      if site.site == stop.site and site.target == stop.target then stop.why = site.why; break end
    end
    if stop.ast and not stop.lazy then
      if not record and stop.test_example then
        local test = stop.test_example.example.test
        if records[test] == nil then records[test] = recordings.lookup(live, { id = test }) or false end
        if records[test] then record = records[test] end
      end
    end
  end
  for _, stop in ipairs(s.stops) do
    if stop.ast and not stop.lazy then
      local sn = live.snippets[stop.anchor]
      stop.recorded_example = sn and record and not live:changed(sn) and recordings.values(sn, record) or nil
      for _, box in ipairs(stops.boxes(stop)) do
        local sn, region, rest = live:resolve_anchor(box.anchor or "")
        if sn and not rest then
          local pres = live:presentation(sn, region)
          box.note, box.gist, box.writing, box.level_shown = pres.note, pres.gist, pres.writing, pres.level_shown
          box.thread = live:thread(sn, region)
          box.example = pres.example
        end
      end
    end
  end
end

local function ast_find(pred)
  for i, stop in ipairs(s.stops) do
    for k, box in ipairs(stops.boxes(stop)) do
      if pred(stop, box) then
        return i, k
      end
    end
  end
end

-- Where the reader is, in terms that survive a re-projection: the box's region address
-- and first line, its snippet, and the snippets above it.
local function ast_here()
  local stop, box = current()
  if not stop then
    return nil
  end
  local chain = {}
  local p = stop._parent_stop
  while p do
    chain[#chain + 1] = p.anchor
    p = p._parent_stop
  end
  local frames = {}
  for _, f in ipairs(s.frames or {}) do
    frames[#frames + 1] = { call = f.call.anchor, stop = f.stop.anchor, box = f.box and f.box.address }
  end
  return { anchor = box.anchor, address = box.address, line = box.start, n = stop.anchor, chain = chain,
    frames = frames }
end

-- Put the reader back on the same region, else the smallest box of the same snippet
-- holding the old first line, else that snippet, else the nearest snippet above it.
local function ast_restore(here)
  if not here then
    return
  end
  local i, k = ast_find(function(stop, box)
    return stop.anchor == here.n and box.address == here.address
  end)
  if not i then
    local best
    for si, stop in ipairs(s.stops) do
      if stop.anchor == here.n then
        for bk, box in ipairs(stops.boxes(stop)) do
          if box.start <= here.line and box["end"] >= here.line then
            if not best or (box["end"] - box.start) < best.size then
              best = { i = si, k = bk, size = box["end"] - box.start }
            end
          end
        end
      end
    end
    if best then
      i, k = best.i, best.k
    end
  end
  for _, n in ipairs(i and {} or here.chain) do
    i, k = ast_find(function(stop, box)
      return stop.anchor == n and box == stop
    end)
    if i then
      break
    end
  end
  s.stop, s.box = i or 1, k or 1
  -- the return stack is rebuilt by anchor; frames whose snippets left the tour are
  -- dropped, and the walk index is recomputed
  local frames = {}
  for _, f in ipairs(here.frames or {}) do
    local ci = f.call and ast_find(function(stop, box)
      return stop.anchor == f.call and box == stop
    end)
    local si, sk = nil, nil
    if f.stop then
      si, sk = ast_find(function(stop, box)
        return stop.anchor == f.stop and box.address == f.box
      end)
      si = si or ast_find(function(stop, box)
        return stop.anchor == f.stop and box == stop
      end)
    end
    if ci and si then
      local caller = s.stops[si]
      frames[#frames + 1] = { call = s.stops[ci], stop = caller, box = stops.boxes(caller)[sk or 1] }
    end
  end
  s.frames, s.walk_index = frames, nil
end

-- Structural operations (`ad`, selections, detail changes) rebuild stops from regions and
-- sites computed when the tour was built; after a source edit those no longer match the
-- buffer, so they are refused until the tour is rebuilt. Returns nil, message.
local function ast_guard()
  local changed = s.ast:changed_snippets()
  if #changed == 0 then
    return true
  end
  local ids = {}
  for _, sn in ipairs(changed) do
    ids[#ids + 1] = sn.n
  end
  return nil, "Source changed; rebuild with code-tour ast (" .. table.concat(ids, " ") .. ")"
end

-- Review diffs (`s.review`) for freshly normalized stops.
local function ast_review(data)
  if s.review then
    for _, stop in ipairs(data) do
      if not stop.lazy then require("code-tour.review").prepare(stop, s.root, s.base) end
    end
  end
  return data
end

-- Each snippet is requested once per detail; a detail change, a second `ad` on the same
-- snippet or a refresh asks only for what was never requested (cleared by M.cancel).
local function ast_unrequested(live, list)
  live.requested = live.requested or {}
  local out = {}
  for _, sn in ipairs(list) do
    local key = sn.n .. "@" .. live.detail
    if not live.requested[key] then
      live.requested[key] = true
      out[#out + 1] = sn
    end
  end
  return out
end

-- Replace a stop and its subtree with freshly normalized stops for `input`, keeping
-- its place under its caller. Returns the new stop.
local function ast_splice(old, input)
  local i = assert(locate(old), "Stop no longer exists")
  local function under(stop)
    while stop do
      if stop == old then
        return true
      end
      stop = stop._parent_stop
    end
  end
  local j = i
  while s.stops[j + 1] and under(s.stops[j + 1]) do
    j = j + 1
  end
  local data = ast_review(stops.normalize({ input }, s.root))
  local new = data[1]
  new._parent_stop, new._parent_box, new.callsite = old._parent_stop, old._parent_box, old.callsite
  new.next, new.level, new.main, new.site, new.target = old.next, old.level, old.main, old.site, old.target
  new.why = old.why
  for _ = i, j do
    table.remove(s.stops, i)
  end
  for n, stop in ipairs(data) do
    table.insert(s.stops, i + n - 1, stop)
  end
  s.stops = vim.tbl_filter(function(stop) return stop.kind ~= "example" end, s.stops)
  ast_examples(s.ast, s.stops)
  for _, f in ipairs(s.frames or {}) do
    if f.call == old then
      f.call = new
    end
  end
  return new
end

local function ast_deliver(prompt, label)
  started(label)
  deliver(prompt, "stay", function(ok, err)
    if not ok then
      notify("AST request delivery failed: " .. tostring(err))
    elseif err then
      notify(err)
    end
  end)
end

function M.ast_brief(id, token)
  assert(s.ast, "Open an AST tour first (code-tour ast)")
  assert(token == nil or token == s.id, "The tour changed")
  return require("code-tour.ast.brief").build(s.ast, id, ast_ctx())
end

function M.know(cmd, opts)
  return require("code-tour.ast.knowledge").run(cmd, opts)
end

local function ast_pending_list(live)
  local list = {}
  for _, sn in ipairs(live:pending()) do
    list[#list + 1] = { n = sn.n, title = sn.label, tier = sn.tier, command = live:fill_command(cli_path(), vim.v.servername, s.id, sn.n) }
  end
  return list
end

-- §9.1: build the tour, show the whole skeleton at once (fresh notes complete, every
-- other box "Being written…"), return the outline. request: { entries, root?, detail?,
-- through?, origin?, cli?, standalone?, send? (deliver the outline to the agent, as
-- :CodeTourAst does), cache_dir? }.
function M.ast_tour(request)
  request = request or {}
  local ast = require("code-tour.ast")
  if not ast.options.enabled then
    return { fallback = true, reason = "ast disabled" }
  end
  if request.auto and not request.recipe and (not request.entries or #request.entries == 0) then
    return ast.outline({}, request)
  end
  if request.keep_live and s.ast and s.id then
    -- A second `code-tour ast` would silently discard the live tour and the reader's place in it.
    local sn = s.ast.snippets and s.ast.snippets.n1
    error(("A live AST tour (%s%s) is open; adjust it with `code-tour adjust --tour %s`, or pass --force to replace it")
      :format(s.id, sn and sn.label and (" · " .. sn.label) or "", s.id), 0)
  end
  local live, err = require("code-tour.ast.live").new(request)
  if not live then
    local fallback = ast.fallback_reason(err, request.root)
    if fallback then return { fallback = true, reason = fallback } end
    error(err, 0)
  end
  local deadline = require("code-tour.ast.deadline")
  deadline.check() -- do not replace the reader's tour for a caller that gave up
  deadline.finish()
  local result = M.show(live:stops(), { root = live.root, origin = request.origin, cli = request.cli,
    standalone = request.standalone })
  s.ast = live
  ast_examples(live, s.stops)
  live:remember()
  ast_refresh()
  render(false)
  local ctx = ast_ctx()
  result.tour = s.id
  result.detail = live.detail
  result.outline = live:outline(ctx)
  result.pending = ast_pending_list(live)
  if #result.pending == 0 then
    result.pending = nil
  end
  local stale_boxes = {}
  for _, box in ipairs(live:stale()) do
    stale_boxes[#stale_boxes + 1] = box.n .. "." .. box.box .. " (" .. box.reason .. ")"
  end
  if #stale_boxes > 0 then notify("Stale explanations: " .. table.concat(stale_boxes, ", ")) end
  local pending = ast_unrequested(live, live:pending())
  local prompts = require("code-tour.ast.prompts")
  if request.send and #pending > 0 then
    if request.recipe then
      ast_deliver(prompts.write(live, ctx, pending), "Requested missing explanations")
    else
      ast_deliver(prompts.tour(live, ctx), "Sent the tour outline to the agent")
    end
  end
  return result
end

-- A fill for an AST snippet (§9.3–9.4): notes go to the store and boxes re-render in
-- place; the reader is never moved.
local function ast_fill(id, input, opts)
  local result = s.ast:fill(id, input, opts or {})
  ast_refresh()
  if not typing() then
    render(false)
  end
  result.navigate = false
  return result
end

-- `ad` on a lazy site (§9.5): build the target's snippet and insert it in place of the
-- lazy call, enter it, and ask the agent for its boxes unless the store has them all.
local function ast_expand(call)
  local ok, why = ast_guard()
  if not ok then
    notify(why)
    return nil
  end
  local parent, pbox = call._parent_stop, call._parent_box
  local sn, input, needs = s.ast:expand(call.anchor)
  local new = ast_splice(call, input)
  ast_refresh()
  enter_call(new, parent, pbox)
  reset_pages()
  M.recenter()
  if needs and #ast_unrequested(s.ast, { sn }) == 0 then
    started("Explanation already in progress: " .. sn.label)
  elseif needs then
    local caller = parent and {
      n = parent.anchor, label = parent.title, box = pbox and pbox.anchor and pbox.anchor:match("%.(.+)$") or "overview",
      note = pbox and pbox.note or "",
    }
    ast_deliver(require("code-tour.ast.prompts").snippet(s.ast, ast_ctx(), sn, caller),
      "Requested explanation: " .. sn.label)
  else
    started("Opening explanation: " .. sn.label)
  end
  return sn.n
end

-- `ae`/`aE` on code inside an AST snippet (§7, §9.5): the selection maps to the
-- smallest region containing it, or a synthetic one; the reply is a fill for it.
-- Returns id, prompt, or nil when the selection is not inside an AST snippet.
local function ast_explain(selection, context, action)
  local parent = require("code-tour.selection").placement(s, selection)
  if not (parent and parent.ast and parent.anchor and not parent.lazy) then
    return nil
  end
  local ok, why = ast_guard()
  if not ok then
    notify(why)
    return false
  end
  local here = ast_here()
  local range = selection.byte_range
  if not range then
    local last = vim.api.nvim_buf_get_lines(selection.buf, selection["end"] - 1, selection["end"], false)[1] or ""
    range = { start = { selection.start - 1, 0 }, ["end"] = { selection["end"] - 1, #last } }
  end
  local res = s.ast:select(parent.anchor, range)
  if res.stop then
    ast_splice(parent, res.stop)
    ast_refresh()
    ast_restore(here)
  end
  local boxes = {}
  for _, id in ipairs(res.boxes) do
    local _, region = s.ast:resolve_anchor(res.sn.n .. "." .. id)
    if s.ast:status(res.sn, region) ~= "fresh" then boxes[#boxes + 1] = id end
  end
  if #boxes == 0 then
    render(false)
    return res.sn.n
  end
  local prompt = require("code-tour.ast.prompts").explain(s.ast, ast_ctx(), {
    sn = res.sn, boxes = boxes, synthetic = res.synthetic, context = context, text = selection.text,
  })
  started(("Generating explanation for %s %s…"):format(res.sn.n, res.boxes[1]))
  deliver(prompt, action or "stay", function(ok, err)
    if not ok or err then
      notify(err)
    end
  end)
  render(false)
  return res.sn.n, prompt
end

-- Replace the projection while keeping the reader's position and unrelated stops.
local function ast_reproject(live, data, here, label, reason)
  ast_examples(live, data)
  for _, stop in ipairs(s.stops) do
    if not stop.ast and stop.kind ~= "example" and not (stop._parent_stop and stop._parent_stop.ast) then
      data[#data + 1] = stop
    end
  end
  s.ast = live
  s.stops = ast_review(data)
  for id, request in pairs(s.pending) do
    local target = request.placeholder or request.stop
    if target and not locate(target) then s.pending[id] = nil end
  end
  live:remember()
  ast_refresh()
  ast_restore(here)
  reset_pages()
  render(true)
  local write = ast_unrequested(live, live:pending())
  if #write > 0 then
    ast_deliver(require("code-tour.ast.prompts").write(live, ast_ctx(), write, reason or label),
      ("%s · %d snippet%s to write"):format(label, #write, #write == 1 and "" or "s"))
  else
    started(label)
  end
  return { detail = live.detail, tour = s.id, pending = ast_pending_list(live), outline = live:outline(ast_ctx()) }
end

function M.ast_detail(detail)
  require("code-tour.ast.deadline").finish() -- a detail change edits the live tour in place
  local live = assert(s.ast, "Open an AST tour first (code-tour ast)")
  assert(ast_guard())
  local here, before = ast_here(), live.detail
  local res = live:set_detail(detail)
  if res.request == false then
    return { detail = detail, tour = s.id, pending = ast_pending_list(live), outline = live:outline(ast_ctx()) }
  end
  live.recorded = nil
  local ok, data = pcall(stops.normalize, live:stops(), s.root)
  if not ok then
    live:set_detail(before)
    error(data, 0)
  end
  return ast_reproject(live, data, here, "Detail: " .. detail, "detail changed to " .. detail)
end

function M.ast_adjust(ops)
  ops = ops or {}
  local live = assert(s.ast, "Open an AST tour first (code-tour ast)")
  local overrides = ops.overrides or {}
  if #overrides == 0 then
    assert(ops.detail, "Pass --detail or an override")
    return M.ast_detail(ops.detail)
  end
  assert(ast_guard())
  local normalized, err = require("code-tour.ast.overrides").normalize(live.prep.rt, live:all(), overrides, live.detail)
  assert(normalized, err)
  local recipe = vim.deepcopy(live.recipe)
  recipe.overrides = vim.list_extend(recipe.overrides or {}, normalized)
  recipe.detail = ops.detail or live.detail
  local request = { root = live.root, recipe = recipe, store = live.store, cache_dir = live.idx.cache_dir,
    cwd = ops.cwd }
  local rebuilt, reason = require("code-tour.ast.live").new(request)
  assert(rebuilt, reason)
  require("code-tour.ast.deadline").finish()
  -- Preserve snippet IDs previously sent to a writer.
  rebuilt.ids, rebuilt.next_n = vim.deepcopy(live.ids), live.next_n
  rebuilt.snippets, rebuilt.built = {}, {}
  rebuilt:assemble()
  local data = stops.normalize(rebuilt:stops(), s.root)
  local here = ast_here()
  s.id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. vim.fn.getpid()):sub(1, 16)
  s.questions, s.tour_file = {}, nil
  return ast_reproject(rebuilt, data, here, "Tour adjusted")
end

function M.store_prune(opts)
  local ast = require("code-tour.ast")
  return require("code-tour.ast.store").new(ast.index(opts), ast.options):prune()
end

function M.ast_history(id)
  local root = s.root or vim.fn.getcwd()
  local ast = require("code-tour.ast")
  local store = require("code-tour.ast.store").new(ast.index({ root = root }), ast.options)
  local function open(recipe)
    local ok, result = pcall(M.ast_tour, { root = root, recipe = recipe, send = true, origin = s.origin })
    if not ok then notify(result)
    elseif result.fallback then notify(result.reason) end
    return ok and result or nil
  end
  if id and id ~= "" then return open(assert(store:recipe(id), "Unknown AST tour " .. id)) end
  local recipes = store:recipes()
  if #recipes == 0 then return notify("No AST tour history in this repository") end
  vim.ui.select(recipes, {
    prompt = "Open an AST tour",
    format_item = function(recipe)
      return (recipe.label or (#recipe.entries > 0 and table.concat(recipe.entries, ", ") or "Automatic entries"))
        .. " · " .. recipe.detail
    end,
  }, function(recipe)
    if recipe then open(recipe) end
  end)
end

M._ast = { refresh = ast_refresh, splice = ast_splice, here = ast_here, restore = ast_restore }

-- The tour as an outline in a floating window or a tab; <CR> jumps to the snippet.
function M.tree(mode)
  assert(#s.stops > 0, "Open a tour first")
  local stop = s.stops[s.stop]
  local current = stop and stop.path and require("code-tour.graph").key(stop) or nil
  require("code-tour.tree").open(mode or s.opts.tree, build_graph(), current, function(node)
    local i = node.stops[1]
    local item = s.stops[i]
    if not item then return end
    clear_intent()
    if item._parent_stop then
      M.expand_call(item)
    else
      s.stop, s.box, s.frames = i, stops.first_box(item), {}
      reset_pages()
      M.recenter()
    end
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
  -- workspace hooks (opt-in) may relocate repositories; explicit overrides stay in charge
  opts = vim.tbl_extend("force", opts,
    { repositories = require("code-tour.workspace").saved_roots(record, opts.root or s.root or vim.fn.getcwd(), opts.repositories) })
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

-- A reader opened from tanki (standalone) may generate only when it was started
-- with --lazy-agent. deliver() then connects to or starts the agent on first use.
local function generation()
  if not s.standalone then return true end
  if not s.lazy_agent then notify("Standalone review: generation is disabled"); return false end
  return true
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
  if not generation(function() M.ask(question, action, selected) end) then return end
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
  local stale = stale_line()
  local prompt = ("[code-tour question] tour: %s\nstop %s · %s:%d-%d%s\n%sQuestion: %s\nReply: %s")
    :format(tour_path(), id, stop.file, first, last, selected and " (selected lines)" or "",
      stale and (stale .. "\n") or "", question, command("answer " .. id))
  if s.ast and box.ast then
    local sn, region = s.ast:resolve_anchor(box.anchor)
    local found = sn and s.ast:lookup(sn, region)
    if sn then
      local tier, suggested = require("code-tour.ast.tiers").writer(sn, found and found.model)
      if suggested then prompt = prompt .. ("\nWriter tier: %s (%s)"):format(tier, suggested) end
    end
  end
  local turn = { question = question, box_id = id }
  box.thread[#box.thread + 1] = turn
  if s.ast and box.ast then
    local sn, region = s.ast:resolve_anchor(box.anchor)
    if sn then s.ast:save_turn(sn, region, turn) end
  end
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
  s.page = "latest"
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
  if s.ast and target.box.ast then
    local sn, region = s.ast:resolve_anchor(target.box.anchor)
    if sn then s.ast:save_turn(sn, region, target.turn) end
  end
  if select(2, current()) == target.box then s.page = "latest" end
  if not typing() then
    render(false)
  end
  return { answered = id }
end

function M.ast_record()
  local live = assert(s.ast, "Open an AST tour first")
  local stop = current()
  assert(stop and stop.test_example, no_example() or "This snippet has no matching project test")
  local input = require("code-tour.ast.examples").tests(live.idx, { live.snippets[stop.anchor].symbol })[1]
  require("code-tour.ast.recordings").start(live, input, {}, function(record, err)
    if not record then
      notify(err .. ". The test example is still available.")
      return
    end
    if s.ast == live then
      live.recorded = record
      ast_refresh()
      render(false)
      notify("Recorded example from " .. input.label)
    end
  end)
end

function M.ast_scenario(opts)
  local live = assert(s.ast, "Open an AST tour first")
  local id, request = opts.box, nil
  for _, candidate in ipairs(s.questions[id] or {}) do
    if not candidate.turn.answer then request = candidate; break end
  end
  if not request and type(id) == "string" and id:match("^n%d+") then
    for key, queue in pairs(s.questions) do
      for _, candidate in ipairs(queue) do
        if not candidate.turn.answer and candidate.box.anchor == id then id, request = key, candidate; break end
      end
      if request then break end
    end
  end
  assert(request and request.box.ast and locate(request.stop, request.box), "No pending AST question for that box")
  assert(type(opts.source) == "string" and opts.source:find("%S"), "Scenario source is empty")
  assert(not request.recording, "This question already has a scenario running")
  local sn, region = live:resolve_anchor(request.box.anchor)
  local token = s.id
  request.recording = true
  require("code-tour.ast.recordings").start(live, { id = sn.symbol, file = sn.file }, opts, function(record, err)
    request.recording = nil
    if s.id ~= token or s.ast ~= live or request.turn.answer or not locate(request.stop, request.box) then return end
    if not record then
      request.turn.error = err
      live:save_turn(sn, region, request.turn)
      ast_deliver("[code-tour example] Scenario unavailable for box " .. id .. " (" .. err
        .. "). Reply with an illustrative example labelled generated. " .. command("answer " .. id),
        "Requested a generated example")
      return
    end
    local addresses = vim.tbl_keys(record.values)
    table.sort(addresses)
    local lines = { "Executed example", "", "```java", opts.source, "```", "" }
    for _, address in ipairs(addresses) do
      lines[#lines + 1] = "- " .. address .. " — " .. record.values[address]:gsub("\n", " ")
    end
    request.turn.source = "executed"
    M.answer(table.concat(lines, "\n"), id)
  end)
  return { box = id, requested = true }
end


function M.explain_range(selection, context, action)
  if not generation(function() M.explain_range(selection, context, action) end) then return end
  assert(selection.tour == s.id, "The tour changed; select the code again")
  assert(
    vim.api.nvim_buf_is_valid(selection.buf) and vim.api.nvim_buf_get_changedtick(selection.buf) == selection.tick,
    "The selected code changed; select it again"
  )
  if s.ast then
    local ast_id, ast_prompt = ast_explain(selection, context, action)
    if ast_id == false then return end
    if ast_id then return ast_id, ast_prompt end
  end
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
    tour = tour_path(), stale = stale_line(), root = s.root, selection = selection, coverage = request.coverage, context = context,
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
      -- Regenerate the stale box together with the explanations that depend on it.
      local linked = {}
      for _, item in ipairs(stale_items()) do
        if item.saved_id == active_box._saved.id then
          for _, link in ipairs(item.update_also) do
            if link.saved_id then
              linked[#linked + 1] = { id = link.saved_id, because = item.id .. " (" .. link.relation .. ")" }
            end
          end
        end
      end
      if not generation() then return end
      local id = saved.retry(s, active_box._saved.id, linked)
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

-- Rewrite the focused box's explanation from scratch, even when it is still fresh.
-- Saved tours queue the box through the saved regeneration round trip; AST tours ask
-- for the box again and the reply is stored as its newest version. Q&A stays attached.
function M.regenerate(action)
  local stop, box = current()
  if not stop or not box then
    notify("Open a tour before regenerating an explanation")
    return
  end
  if box._saved then
    if not saved.guard(box._saved) then
      notify(box._saved.reason or "This saved box cannot be regenerated")
      return
    end
    if box._saved.status == "queued" or box._saved.status == "generating" then
      notify("This explanation is already being regenerated")
      return
    end
    if not generation(function() M.regenerate(action) end) then return end
    local ok, id = pcall(saved.retry, s, box._saved.id)
    if not ok then
      notify(id)
      return
    end
    render(false)
    return id
  end
  if s.ast and stop.ast and box.anchor and not stop.lazy then
    local sn, region = s.ast:resolve_anchor(box.anchor)
    if not sn then
      notify("This box is not part of the AST tour")
      return
    end
    local ok, why = ast_guard()
    if not ok then
      notify(why)
      return
    end
    local id = region and region.id or "overview"
    local text = table.concat(vim.api.nvim_buf_get_lines(stop.buf, box.start - 1, box["end"], false), "\n")
    local previous = type(box.note) == "string" and box.note:find("%S") and box.note or nil
    local context = "Regenerate: write a new explanation of this box from scratch; it replaces the existing one."
      .. (previous and ("\nExisting explanation to improve on:\n" .. previous) or "")
    local prompt = require("code-tour.ast.prompts").explain(s.ast, ast_ctx(), {
      sn = sn, boxes = { id }, context = context, text = text,
    })
    started(("Regenerating explanation for %s %s…"):format(sn.n, id))
    deliver(prompt, action or "stay", function(sent, err)
      if not sent or err then notify(err) end
    end)
    return sn.n, prompt
  end
  notify("Only saved and AST tour boxes can be regenerated; explain a selection to add finer parts")
end

function M.explain_symbol(context, reason, call)
  if not generation(function() M.explain_symbol(context, reason, call) end) then return end
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
    tour = tour_path(), stale = stale_line(),
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
  if not generation(function() M.explain_location(location, call, inspect) end) then return end
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
    tour = tour_path(), stale = stale_line(),
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
            .. (item.why and (" · " .. item.why) or "")
        end,
      }, function(item)
        if item and current() == stop and select(2, current()) == box then M.expand_call(item) end
      end)
      return
    end
    call = call or calls[1]
  end
  if not locate(call) then return end
  if s.ast and call.ast and call.lazy then return ast_expand(call) end
  -- Say why a call was left unexpanded, so opening it is an informed choice.
  if call.why and not stops.ready(call) then
    notify(("Skipped earlier: %s"):format(call.why), vim.log.levels.INFO)
  end
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
  if not generation(function() M.explain_definition(inspect) end) then return end
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
  if s.ast and type(id) == "string" and id:match("^n%d+$") and not s.pending[id] then
    return ast_fill(id, input, opts)
  end
  if not s.pending[id] and not (type(id) == "string" and id:match("^n%d+$") and s.ast) then
    local hint = s.ast and ("fill ids look like n13 (a snippet of the open AST tour, from its outline)")
      or "fill ids are the request ids the editor sent"
    error(("Unknown fill id %q: %s; or the explain request is already complete"):format(tostring(id), hint), 0)
  end
  local request = assert(s.pending[id], "Unknown or completed explain request " .. tostring(id))
  -- A streamed snippet is written where its placeholder is, so the route never changes behind the reader.
  assert(not (request.stream and (opts.after or opts.into)), "Streamed snippets are filled in place: omit --after/--into")
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
      -- A reply that covers the whole target box refines it: its parts become that box's
      -- children. A partial reply (a selected range) is an addition next to the box.
      local refines = target_box ~= target_stop and range.start <= target_box.start
        and range["end"] >= target_box["end"]
      local base = target_box == target_stop and 0 or (refines and (target_box._depth or 1) or ((target_box._depth or 1) - 1))
      for _, part in ipairs(additions) do
        part._depth = base + (part._depth or 1)
        if not part._parent_part and target_box ~= target_stop then
          part._parent_part = refines and target_box or target_box._parent_part
        end
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
        local seen = {} -- base line numbers already shown by this stop
        for _, removed in ipairs(target_stop.removed) do
          local lines, owners, ids = {}, {}, {}
          for index, line in ipairs(removed.lines) do
            local owner = (removed.owners or {})[index] or removed.line
            if owner < stop.start or owner > stop["end"] then
              lines[#lines + 1], owners[#owners + 1] = line, owner
              local id = (removed.ids or {})[index]
              ids[#ids + 1] = id
              if id then seen[id] = true end
            end
          end
          if #lines > 0 then
            retained[#retained + 1] = { line = removed.line, above = removed.above, lines = lines, owners = owners,
              ids = #ids == #lines and ids or nil }
          end
        end
        -- A deletion on the boundary between two parts is owned by both: a removed line is added
        -- only once, whichever part brought it first.
        for _, removed in ipairs(stop.removed or {}) do
          local lines, owners, ids = {}, {}, {}
          for index, line in ipairs(removed.lines) do
            local id = (removed.ids or {})[index]
            if not (id and seen[id]) then
              lines[#lines + 1], owners[#owners + 1] = line, (removed.owners or {})[index] or removed.line
              ids[#ids + 1] = id
              if id then seen[id] = true end
            end
          end
          if #lines > 0 then
            retained[#retained + 1] = { line = removed.line, above = removed.above, lines = lines, owners = owners,
              ids = #ids == #lines and ids or nil }
          end
        end
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
      root.next, root.level = target_stop.next, target_stop.level
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
  local navigate = not typing() and (not (request.call or request.stream) or waiting)
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
  return { filled = id, count = #data, navigate = navigate, pending = register_pending(data) }
end

function M.load(path)
  if not path or path == "" then
    path = vim.fn.getcwd() .. "/.nvim/code-tour.json"
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
  if s.ast then s.ast.requested = {} end
  s.id = vim.fn.sha256(tostring(vim.uv.hrtime()) .. vim.fn.getpid()):sub(1, 16)
end
function M.state()
  return s
end
M.render = render

-- Snippet highlights follow the colorscheme: the focused range uses its Visual background and
-- the other prepared ranges a softer mix of it. `default = true` lets a user override any group.
local function highlights()
  local normal_bg = badge.theme("Normal", "bg", 0x1a1b26)
  local visual = badge.theme("Visual", "bg", 0x314888)
  for name, spec in pairs({
    CodeTourStop = { bg = badge.blend(normal_bg, visual, 0.55) },
    CodeTourFocus = { bg = visual },
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
end

function M.setup(opts)
  s.opts = vim.tbl_extend("force", { page_lines = 18, smooth_scroll = true, saved_request_timeout_ms = 300000,
    saved_batch_size = 12, saved_batch_chars = 40000, saved_reuse_unverified = true, agent = "herdr", tree = "float" }, opts or {})
  assert(s.opts.tree == "float" or s.opts.tree == "tab", 'code-tour: tree must be "float" or "tab"')
  local agent = s.opts.agent
  assert(agent == "herdr" or agent == "auto" or agent == "clipboard" or (type(agent) == "table" and type(agent.send) == "function"),
    'code-tour: agent must be "herdr", "auto", "clipboard" or { send = function(text, action, done) end }')
  for _, name in ipairs({ "saved_request_timeout_ms", "saved_batch_size", "saved_batch_chars" }) do
    local value = s.opts[name]
    assert(type(value) == "number" and value > 0 and value == math.floor(value), name .. " must be a positive integer")
  end
  assert(type(s.opts.saved_reuse_unverified) == "boolean", "saved_reuse_unverified must be a boolean")
  require("code-tour.ast").setup(s.opts.ast)
  -- only an editor someone is looking at speaks for the user; scripts and tests have no UI
  local function remember()
    pcall(require("code-tour.ast").remember_languages)
  end
  if #vim.api.nvim_list_uis() > 0 then
    remember()
  else
    vim.api.nvim_create_autocmd("UIEnter", {
      group = vim.api.nvim_create_augroup("CodeTourLanguages", { clear = true }),
      once = true,
      callback = remember,
    })
  end
  require("code-tour.workspace").setup(s.opts.workspace)
  require("code-tour.instance").register()
  highlights()
  badge.configure(s.opts.badge)
  badge.highlight()
  require("code-tour.markdown").highlight()
  require("code-tour.keys").apply(s.opts.keys, {
    toggle = M.toggle,
    next = function() M.next_explanation(1) end,
    prev = function() M.next_explanation(-1) end,
    next_snippet = function() M.next_snippet(1) end,
    prev_snippet = function() M.next_snippet(-1) end,
    list = M.list_snippets,
    tree = function() M.tree() end,
    ask = M.ask,
    explain = M.explain,
    explain_context = M.explain_with_context,
    regenerate = function() M.regenerate() end,
    inspect = function() M.expand_call() end,
    back = M.return_to_caller,
    text_view = M.focus,
    stop = M.stop,
    recenter = M.recenter,
    zoom_out = function() M.zoom(-1) end,
    zoom_in = function() M.zoom(1) end,
    page_next = function() M.page(1) end,
    page_prev = function() M.page(-1) end,
    question_next = function() M.question(1) end,
    question_prev = function() M.question(-1) end,
    visual = {
      ask = function()
        local a, b = vim.fn.line("v"), vim.fn.line(".")
        M.ask(nil, "stay", { math.min(a, b), math.max(a, b) })
      end,
      explain = M.explain,
      explain_context = M.explain_with_context,
    },
  })
  local commands = {
    CodeTourToggle = M.toggle,
    CodeTourStop = M.stop,
    CodeTourList = M.list_snippets,
    CodeTourFocus = M.focus,
    CodeTourCancel = M.cancel,
    CodeTourRecenter = M.recenter,
    CodeTourExplain = M.explain,
    CodeTourExplainContext = M.explain_with_context,
    CodeTourRegenerate = function() M.regenerate() end,
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
  vim.api.nvim_create_user_command("CodeTourAst", function(args)
    local words = vim.split(vim.trim(args.args), "%s+", { trimempty = true })
    local detail
    if #words > 0 and require("code-tour.ast.live").details[words[#words]] then
      detail = table.remove(words)
    end
    if #words == 1 and words[1] == "--auto" then
      local result = M.ast_outline({ auto = true, root = vim.fn.getcwd() })
      if result.fallback then notify(result.reason); return end
      if #result.candidates == 0 then notify("No AST tour entries found"); return end
      vim.ui.select(result.candidates, { prompt = "Choose a tour entry",
        format_item = function(candidate) return candidate.label .. " · " .. candidate.file end,
      }, function(candidate)
        if candidate then M.ast_tour({ entries = { candidate.symbol }, detail = detail,
          root = result.root, send = true, origin = s.origin }) end
      end)
      return
    end
    if #words == 0 then
      local entry = vim.fn.expand("%:p") .. ":" .. vim.fn.line(".")
      words = { entry }
    end
    local ok, result = pcall(M.ast_tour, { entries = words, detail = detail, root = vim.fn.getcwd(), send = true,
      origin = s.origin })
    if not ok then
      notify(result)
    elseif result.fallback then
      notify("No AST tour: " .. tostring(result.reason))
    end
  end, { nargs = "*", force = true })
  vim.api.nvim_create_user_command("CodeTourCodeGraph", function()
    local ok, result = pcall(M.code_graph, { root = s.root or vim.fn.getcwd() })
    notify(ok and ("Code graph: " .. result.path) or result)
  end, { force = true })
  vim.api.nvim_create_user_command("CodeTourHistory", function(args)
    local ok, err = pcall(M.ast_history, args.args)
    if not ok then notify(err) end
  end, { nargs = "?", force = true })
  vim.api.nvim_create_user_command("CodeTourRecord", function()
    local ok, err = pcall(M.ast_record)
    if not ok then notify(err) end
  end, { force = true })
  vim.api.nvim_create_user_command("CodeTourExample", function()
    local stop = current()
    if stop and stop.test_example then M.expand_call(stop.test_example) else notify(no_example() or "No test example") end
  end, { force = true })
  vim.api.nvim_create_user_command("CodeTourDetail", function(args)
    local ok, err = pcall(M.ast_detail, args.args)
    if not ok then notify(err) end
  end, { nargs = 1, complete = function() return { "overview", "normal", "detailed", "exhaustive" } end, force = true })
  vim.api.nvim_create_user_command("CodeTourZoomOut", function() M.zoom(-1) end, { force = true })
  vim.api.nvim_create_user_command("CodeTourZoomIn", function() M.zoom(1) end, { force = true })
  vim.api.nvim_create_user_command("CodeTourTree", function(args)
    local ok, err = pcall(M.tree, args.args ~= "" and args.args or nil)
    if not ok then notify(err, vim.log.levels.WARN) end
  end, { nargs = "?", complete = function() return { "float", "tab" } end, force = true })
  vim.api.nvim_create_user_command("CodeTourGraph", function()
    local ok, result = pcall(M.graph)
    notify(ok and ("Tour graph: " .. result.path) or result, ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end, { force = true })
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
      if s.ast and not s.saved then
        -- a snippet whose source changed withholds its notes until the tour is rebuilt
        M._ast.refresh()
        local active = current()
        if active and s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == active.buf then
          render(false)
        end
      end
      if s.saved then
        saved.revalidate(s)
        warn_stale()
        local active = current()
        if active and s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_buf(s.win) == active.buf then
          render(false)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = function() highlights(); badge.highlight() end })
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
  M.configured = true
end

-- For callers that only need the plugin to be available: setup() resets every option it is not
-- given, so it must not run again over the user's config.
function M.ensure_setup()
  if not M.configured then
    M.setup()
  end
end
return M
