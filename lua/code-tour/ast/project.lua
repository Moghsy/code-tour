-- Projection of a live AST tour to stops (SPEC-ast-graph §3.7, L3 -> L4): the input
-- `stops.normalize` takes, so the renderer, walk, zoom, picker and tree view work on an
-- AST tour unchanged.
--
--   snippet                 stop {file, start, end, title, anchor = "n1"}
--   selected child regions  nested parts, anchor = "n1.r2"
--   walk edge               a call with next = true, main on the main flow, level = its
--                           effective rating, callsite from the site's range, attached
--                           to the part of the site's region
--   optional edge           a call without next, with its effective rating
--   lazy edge               {file, start, end, title, callsite, lazy = true, why}
--   ref edge                not projected
--   fresh note              its gist and body; otherwise "Being written…" (writing = true)
--
-- Extra keys the editor reads back (normalize keeps every key not starting with "_"):
--   ast = true on every projected stop; anchor; address (the box's region address); gist (when a fresh gist exists);
--   writing = true on a box still to be written; level_shown = the level of a body shown
--   from one level away (§11.2); site/target on calls; jump = true on a call that is a
--   jump, not a call the code makes (§8.3.1); gaps = {{callsite, text, reason}}
--   on the box holding a main-flow gap (§10).
local M = {}

M.writing = "Being written…"

-- 1-based inclusive callsite with byte columns, from a site's byte range.
function M.callsite(range, text)
  return {
    start = range.start[1] + 1,
    ["end"] = range["end"][1] + 1,
    start_col = range.start[2],
    end_col = range["end"][2],
    symbol = text,
  }
end

-- The presentation of one box: { note, gist?, writing?, level_shown? }.
-- found is a notes lookup result (or nil).
function M.box_note(found)
  if not found then
    return { note = M.writing, writing = true }
  end
  local out = { gist = found.gist }
  if found.body then
    out.note = found.gist .. "\n\n" .. found.body
  else
    out.note = found.gist .. (found.exact and "" or ("\n\n" .. M.writing))
  end
  if not found.exact then
    out.writing = true
    if found.body then
      out.level_shown = found.level
      out.note = out.note .. "\n\n*(" .. found.level .. " detail)*"
    end
  end
  return out
end

-- The path the editor opens: index paths are relative to the root, except a file in a
-- checkout attached for an agent range (`@web/src/api.ts`, §14), which is not under it.
local function editor_file(idx, file)
  local repo = file and idx and idx.repo_of and idx:repo_of(file)
  return repo and repo.attached and idx:abs(file) or file
end
M.editor_file = editor_file

local function assign(box, pres)
  box.note, box.gist, box.writing, box.level_shown = pres.note, pres.gist, pres.writing, pres.level_shown
  box.example = pres.example
end

-- Project one snippet as a stop input (without call-only fields). live provides:
--   live.snippets[n]       snippets by id
--   live:presentation(sn, region|nil) -> box presentation (root when region is nil)
--   live.expanded[key]     snippets built by `ad` on a lazy site, key = "n1.s13>target"
--   live.idx               the project index (target symbols for lazy calls)
function M.snippet(live, sn)
  local stop = {
    file = editor_file(live.idx, sn.file),
    start = sn.lines[1],
    ["end"] = sn.lines[2],
    title = sn.label,
    anchor = sn.n,
    address = sn.symbol,
    source = sn._node.sym.source,
    ast = true,
    main = sn.main or nil,
    parts = {},
    calls = {},
  }
  assign(stop, live:presentation(sn, nil))
  local boxes = { overview = stop }
  local by_id = {}
  for _, r in ipairs(sn.regions) do
    by_id[r.id] = r
  end
  -- regions are preorder with parent ids, so parents are built before their children
  for _, r in ipairs(sn.regions) do
    local part = { start = r.lines[1], ["end"] = r.lines[2], anchor = sn.n .. "." .. r.id, address = r.address,
      source = r.origin, ast = true, calls = {} }
    assign(part, live:presentation(sn, r))
    local parent = r.parent and boxes[r.parent] or stop
    parent.parts = parent.parts or {}
    table.insert(parent.parts, part)
    boxes[r.id] = part
  end
  local function box_of(region)
    return boxes[region] or stop
  end
  for _, site in ipairs(sn.sites) do
    local call = M.call(live, sn, site)
    if call then
      table.insert(box_of(site.region).calls, call)
    end
  end
  for _, g in ipairs(sn.gaps or {}) do
    local box = box_of(g.region)
    box.gaps = box.gaps or {}
    table.insert(box.gaps, { callsite = M.callsite(g._range, g.text), text = g.text, reason = g.reason })
  end
  -- empty lists are dropped so the JSON stays small
  for _, box in pairs(boxes) do
    if box.calls and #box.calls == 0 then
      box.calls = nil
    end
    if box.parts and #box.parts == 0 then
      box.parts = nil
    end
  end
  return stop
end

-- The call projected for one site of a snippet, or nil.
function M.call(live, sn, site)
  local callsite = M.callsite(site._range, site.text)
  if (site.mode == "walk" or site.mode == "optional") and site.to then
    local callee = live.snippets[site.to]
    if not callee then
      return nil
    end
    local call = M.snippet(live, callee)
    call.callsite = callsite
    call.site, call.target = site.site, site.target
    call.caller = sn.n
    call.jump = site.kind == "jump" or nil
    call.level = site.effective
    if site.mode == "walk" then
      call.next = true
      call.main = site.main or nil
      call.level = call.level or 0
    end
    call.why = site.why
    return call
  end
  if site.mode == "lazy" and site.target then
    local key = sn.n .. "." .. site.site .. ">" .. site.target
    local expanded = live.expanded and live.expanded[key]
    if expanded then
      local call = M.snippet(live, expanded)
      call.callsite = callsite
      call.site, call.target = site.site, site.target
      call.caller = sn.n
      call.jump = site.kind == "jump" or nil
      call.why, call.level = site.why, site.effective
      return call
    end
    local sym = live.idx:symbol(site.target)
    if not sym or not sym.file or sym.source == "library" or not sym.range then
      return nil
    end
    local first, last = require("code-tour.ast.outline").lines_of(sym.range)
    return {
      file = editor_file(live.idx, sym.file),
      start = first,
      ["end"] = last,
      title = sym.label,
      callsite = callsite,
      lazy = true,
      level = site.effective,
      why = site.why,
      ast = true,
      jump = site.kind == "jump" or nil,
      anchor = key,
      site = site.site,
      target = site.target,
      caller = sn.n,
    }
  end
  return nil
end

-- The whole tour: one top-level stop per root snippet (an entry), callees nested as calls.
function M.stops(live)
  local out = {}
  for _, sn in ipairs(live.tour.snippets) do
    if sn.depth == 0 and not sn._node.parent then
      out[#out + 1] = M.snippet(live, sn)
    end
  end
  return out
end

return M
