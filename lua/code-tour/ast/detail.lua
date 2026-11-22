-- Live detail changes (SPEC-ast-graph §8.6, §10): re-project a live tour onto another
-- detail from the same rated tree. Ratings are never recomputed and the main flow stays
-- put (§8.6); only the offer cutoff and the budget move, so extras enter or leave the
-- tour. Region selection runs again at the new detail, which refines or coarsens boxes
-- along nested boundaries (§7); a box that keeps its address keeps its notes and Q&A
-- thread, and each box looks up its body for the new level, or the nearest (§11.2).
--
--   detail.change(live, detail) -> { request, detail, from, added, removed, dropped }
--     request  false when nothing changed (same detail), else true: the editor then
--              asks for the snippets that still have boxes to write (§9.5)
--     added    ids of snippets that entered the tour, in walk order
--     removed  ids of tour snippets that left it
--     dropped  keys of `ad`-expanded snippets dropped (see below)
--
-- Snippets expanded by `ad` on a lazy site (§9.5) are not part of the rated tree. They
-- are kept while the site they hang off is still a lazy site of a snippet in the tour,
-- and re-selected at the new detail (expand.rebuild). One whose parent left the tour is
-- dropped, and so is one whose site is no longer lazy: at a higher detail the target is
-- offered as an optional call of the tour itself, under the same stable id
-- (live:id_for), and two snippets cannot share it. Its notes stay in the store by
-- address, so expanding it again later shows them at once.
local M = {}

local function valid(detail)
  return type(detail) == "string" and require("code-tour.ast.live").details[detail]
end

-- The parent id and lazy site of an expansion key "n1.s13>target" (nested keys hang off
-- an expanded snippet's id the same way).
local function parse_key(key)
  local n, site, target = key:match("^(n%d+)%.([^>]+)>(.+)$")
  return n, site, target
end

local function lazy_site(sn, site_id, target)
  for _, site in ipairs(sn.sites) do
    if site.site == site_id and site.target == target then
      return site.mode == "lazy"
    end
  end
  return false
end

-- Re-select an expanded snippet at live.detail. expand.lua (piece B) provides rebuild;
-- until it does, or when it fails, the old snippet is kept as it was.
local function rebuild(live, sn)
  local ok, expand = pcall(require, "code-tour.ast.expand")
  if not ok or type(expand.rebuild) ~= "function" then
    return sn
  end
  local done, new = pcall(expand.rebuild, live, sn)
  if done and type(new) == "table" then
    return new
  end
  return sn
end

function M.change(live, detail)
  if not valid(detail) then
    error("unknown detail " .. tostring(detail) .. " (overview, normal, detailed, exhaustive)", 0)
  end
  local from = live.detail
  if detail == from then
    return { request = false, detail = detail, from = from, added = {}, removed = {}, dropped = {} }
  end
  local before = {}
  for _, sn in ipairs(live.tour.snippets) do
    before[sn.n] = true
  end

  live.detail = detail
  live.recipe.detail = detail
  -- §8.6: the same prepared (rated) tree, projected onto the new detail
  local ok, err = pcall(live.assemble, live)
  if not ok then
    live.detail, live.recipe.detail = from, from
    error(err, 0)
  end

  -- live.snippets is rebuilt from what is projected now: snippets that left the tour
  -- must not resolve any more (anchors, fills), and assemble() let expanded snippets
  -- overwrite tour snippets that share their id
  local snippets, added, now = {}, {}, {}
  for _, sn in ipairs(live.tour.snippets) do
    snippets[sn.n] = sn
    now[sn.n] = true
    if not before[sn.n] then
      added[#added + 1] = sn.n
    end
  end
  local removed = {}
  for n in pairs(before) do
    if not now[n] then
      removed[#removed + 1] = n
    end
  end
  table.sort(removed, function(a, b)
    return tonumber(a:sub(2)) < tonumber(b:sub(2))
  end)

  -- expanded snippets, parents first: an expansion is kept when its parent is projected
  -- (a tour snippet or a kept expansion) and its site is still lazy there
  local keep, dropped, pending, rebuilt = {}, {}, {}, {}
  for key, sn in pairs(live.expanded) do
    pending[key] = sn
  end
  local progress = true
  while progress do
    progress = false
    for key, sn in pairs(pending) do
      local pn, site, target = parse_key(key)
      local parent = pn and snippets[pn]
      if parent then
        pending[key] = nil
        progress = true
        if lazy_site(parent, site, target) and not now[sn.n] then
          -- a snippet shared by two lazy sites is rebuilt once and stays shared
          local new = rebuilt[sn] or rebuild(live, sn)
          rebuilt[sn] = new
          keep[key] = new
          snippets[new.n] = new
        else
          dropped[#dropped + 1] = key
        end
      end
    end
  end
  for key in pairs(pending) do
    dropped[#dropped + 1] = key
  end
  table.sort(dropped)
  live.expanded = keep
  live.snippets = snippets

  return { request = true, detail = detail, from = from, added = added, removed = removed, dropped = dropped }
end

return M
