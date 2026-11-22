-- The snippet context handed to a writer (§9.7).
local outline = require("code-tour.ast.outline")
local notes = require("code-tour.ast.notes")
local M = {}

local function doc(live, sym)
  if sym.doc then return sym.doc end
  local above = vim.api.nvim_buf_get_lines(live:buf(sym.file), 0, sym.range.start[1], false)
  local last = #above
  if not above[last] or not above[last]:match("%*/%s*$") then return end
  for i = last, 1, -1 do
    if above[i]:find("/*", 1, true) then
      if above[i]:match("^%s*/%*%*") then return table.concat(above, "\n", i, last) end
      return
    end
  end
end

function M.build(live, id, ctx)
  local sn = assert(live.snippets[id], "No AST snippet " .. tostring(id))
  assert(not live:changed(sn), "Source changed; rebuild with code-tour ast")
  live:apply_edge_notes()
  local out = {
    "Follow the AST writing rules in skills/code-tour/SKILL.md.",
    ("Snippet %s · %s · %s detail"):format(id, sn.tier, live.detail),
  }
  local function add(line)
    if line and line ~= "" then out[#out + 1] = line end
  end
  for _, entry in ipairs(live.tour.entries) do
    local top = live.snippets[live.ids[entry]]
    local found = top and not live:changed(top) and live:lookup(top)
    if found then add("Entry overview: " .. found.gist) end
  end
  for _, parent in ipairs(live:all()) do
    for _, site in ipairs(parent.sites) do
      local caller, region = live:resolve_anchor(parent.n .. "." .. site.region)
      if ((site.to == id and (site.mode == "walk" or site.mode == "optional")) or live.expanded[parent.n .. "." .. site.site .. ">" .. (site.target or "")] == sn)
          and not live:changed(parent) then
        add(("Caller: %s %s.%s"):format(parent.label, parent.n, site.region))
        local found = live:lookup(caller, region)
        if found then add(found.gist); add(found.body) end
        if site.why then add("Why this call: " .. site.why) end
      end
    end
  end
  add(live:snippet_outline({ sn }))
  local seen = {}
  for _, site in ipairs(sn.sites) do
    local sym = site.target and live.idx:symbol(site.target)
    if sym and not seen[sym.id] then
      seen[sym.id] = true
      add("Callee: " .. (sym.signature or sym.label))
      if sym.file and sym.range and sym.source ~= "library" then
        add(doc(live, sym))
        local fp = notes.fingerprint(live:buf(sym.file), sym.range)
        local found = live.store:lookup(sym.id, fp, live.detail, { file = sym.file, symbol = sym.id })
        if found then add(found.gist) end
      end
      local callee = site.to and live.snippets[site.to]
      for _, target in ipairs(callee and callee.sites or {}) do
        if target.mode == "walk" then
          add("  Main flow: " .. target.site .. " " .. target.text .. " → " .. (target.target_label or target.target or "?"))
        end
      end
    end
  end
  add("Source with box boundaries:")
  local boundaries = {}
  local function mark(line, value)
    boundaries[line] = (boundaries[line] and (boundaries[line] .. ", ") or "") .. value
  end
  mark(sn.lines[1], "begin overview")
  mark(sn.lines[2] + 1, "end overview")
  for _, region in ipairs(sn.regions) do
    mark(region.lines[1], "begin " .. region.id)
    mark(region.lines[2] + 1, "end " .. region.id)
  end
  local code = vim.api.nvim_buf_get_lines(live:buf(sn.file), sn.lines[1] - 1, sn.lines[2], false)
  for i, line in ipairs(code) do
    local row = sn.lines[1] + i - 1
    add(boundaries[row] and ("[" .. boundaries[row] .. "]"))
    add(("%4d  %s"):format(row, line))
  end
  add("[" .. boundaries[sn.lines[2] + 1] .. "]")
  local function previous(region)
    local old = live.previous and live:previous(sn, region)
    if not old then return end
    add("Previous note for " .. (region and region.id or "overview") .. " (describes older code):")
    add(old.gist)
    local body = old.bodies and old.bodies[live.detail]
    add(body and body.text)
  end
  previous()
  for _, region in ipairs(sn.regions) do previous(region) end
  local tiers = require("code-tour.ast.tiers")
  local tier, model = tiers.writer(sn)
  for _, r in ipairs(live:to_write(sn)) do
    local _, region = live:resolve_anchor(id .. "." .. r.id)
    local found = live:lookup(sn, region)
    if found and not found.exact then
      local previous = found.model
      if not previous and found.note and found.note.bodies then
        local closest
        for level, body in pairs(found.note.bodies) do
          local distance = math.abs(notes.rank[level] - notes.rank[live.detail])
          if not closest or distance < closest then closest, previous = distance, body.model end
        end
      end
      local upgraded, suggested = tiers.writer(sn, previous)
      if upgraded == "deep" or (upgraded == "standard" and tier == "light") then tier, model = upgraded, suggested end
    end
  end
  add("Fill: " .. live:fill_command(ctx.cli, ctx.servername, ctx.token, id)
    .. (model and (" --model " .. vim.fn.shellescape(model)) or " --model <model>"))
  return { brief = table.concat(out, "\n"), n = id, tier = tier, model = model }
end

return M
