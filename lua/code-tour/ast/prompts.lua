-- Requests from the editor to the agent for AST tours (SPEC-ast-graph §9.5). Each
-- carries only the outline lines it concerns and the fill command, never the full tour,
-- and never a path, line or column to send back: the agent answers by box id.
local M = {}

local function fill_help(command)
  return table.concat({
    "Fill (Markdown on stdin, one section per box; the first paragraph is the gist, the rest the body):",
    "  " .. command .. " <<'EOF'",
    "  ## overview",
    "  …",
    "  ## r2",
    "  …",
    "  EOF",
    "`## n1 r2` addresses another snippet; JSON {\"r2\": {\"gist\": …, \"body\": …}} is accepted too.",
  }, "\n")
end

-- `:CodeTourAst` (editor-initiated): the whole outline as one request.
function M.tour(live, ctx)
  return table.concat({
    "[code-tour ast] Write the explanations for this AST tour (project " .. live.root .. ").",
    "Write snippets in walk order, the reader's first; each in one pass, gist and body together.",
    "",
    live:outline(ctx),
    "",
    fill_help(live:fill_command(ctx.cli, ctx.servername, ctx.token)),
  }, "\n")
end

-- Opening a tour with boxes to write, or raising its detail: the snippets that need it.
function M.write(live, ctx, list, why)
  return table.concat({
    "[code-tour ast] write — " .. (why or "boxes to write") .. " (" .. live.detail .. " detail, project " .. live.root
      .. ")",
    "",
    live:snippet_outline(list),
    "",
    fill_help(live:fill_command(ctx.cli, ctx.servername, ctx.token)),
  }, "\n")
end

-- `ad` on a lazy site: the new snippet's outline and the caller's box.
function M.snippet(live, ctx, sn, caller)
  local lines = {
    ("[code-tour ast] %s %s — the reader opened this call (%s detail, project %s)"):format(sn.n, sn.label,
      live.detail, live.root),
    "",
    live:snippet_outline({ sn }),
  }
  if caller then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Called from %s (%s), box %s:"):format(caller.n, caller.label, caller.box)
    lines[#lines + 1] = caller.note
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = fill_help(live:fill_command(ctx.cli, ctx.servername, ctx.token, sn.n))
  return table.concat(lines, "\n")
end

-- `ae`/`aE` on a selection inside an AST snippet: the region it maps to (§7).
--   args: { sn, boxes = {"r7", …} (the first is the selection's), synthetic, context?,
--           text (the selected code) }
function M.explain(live, ctx, args)
  local sn = args.sn
  local lines = {
    ("[code-tour explain] %s %s, box %s (%s detail, project %s)"):format(sn.n, sn.label, args.boxes[1], live.detail,
      live.root),
  }
  if args.synthetic and #args.boxes > 1 then
    lines[#lines + 1] = ("The selection split its region: write %s for the selected statements and %s for the rest."):format(
      args.boxes[1], table.concat(args.boxes, ", ", 2))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = live:snippet_outline({ sn })
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Selected code:"
  lines[#lines + 1] = args.text or ""
  if args.context and args.context:find("%S") then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Reader's context: " .. args.context
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = fill_help(live:fill_command(ctx.cli, ctx.servername, ctx.token, sn.n))
  return table.concat(lines, "\n")
end

return M
