-- Send only the context for this request. Full placement snapshots stay local.
local M = {}

local function rules(example, context)
  local text = "Use the code-tour skill. Do not edit source. Keep the overview concise. "
    .. "Make subpart explanations detailed: explain mechanisms, checks, state and results. "
    .. "Keep note text general; examples belong only in source-line annotations."
  if example then
    text = text .. "\nContinue the existing example through this explanation and its callees."
  elseif context and context:find("%S") then
    text = text .. "\nOnly include an example if Extra context explicitly asks for one. Otherwise omit example/values."
  else
    return text .. "\nNo example was requested. Omit example/values."
  end
  return text .. " Annotate every value-producing executed line, even if the input is unchanged. "
    .. "Forwarded calls must show their concrete return value, including false/0/empty/null/undefined. "
    .. "Skip scaffolding and no-ops; never write unchanged or invent results."
end

-- The concrete input plus values around the requested call are enough to carry
-- its trace forward, without copying annotations from the entire caller.
local function example_text(example, first, last, previous)
  if not example then return nil end
  local result = { input = example.input, output = example.output, values = {} }
  local before = {}
  for line, value in pairs(example.values or {}) do
    local number = tonumber(line)
    if number >= first and number <= last then
      result.values[tostring(line)] = value
    elseif previous and number < first then
      before[#before + 1] = { line = number, value = value }
    end
  end
  table.sort(before, function(a, b) return a.line > b.line end)
  for i = 1, math.min(2, #before) do result.values[tostring(before[i].line)] = before[i].value end
  return "Example context: " .. vim.json.encode(result)
end

local function source(stop, first, last)
  return ("%s:%d-%d\n```\n%s\n```"):format(stop.file, first, last,
    table.concat(vim.api.nvim_buf_get_lines(stop.buf, first - 1, last, false), "\n"))
end

local function deliver(lines, command)
  lines[#lines + 1] = "Default placement and caller return are saved. Use this exact command without --after/--into:\n" .. command
  return table.concat(lines, "\n")
end

function M.selection(args)
  local selection, coverage = args.selection, args.coverage or args.selection
  local lines = {
    "[code-tour explain]",
    "Explain the SELECTED CODE, not its definition.",
    "Project root: " .. args.root,
    ("%s:%d-%d\nExact selected text:\n```\n%s\n```"):format(selection.file, selection.start, selection["end"], selection.text),
    "Containing box " .. args.box_id .. ": " .. args.box.note,
    rules(args.example, args.context),
  }
  if args.context and args.context:find("%S") then lines[#lines + 1] = "Extra context:\n" .. args.context end
  local example = example_text(args.example, selection.start, selection["end"])
  if example then lines[#lines + 1] = example end
  lines[#lines + 1] = ("Return JSON stops in %s covering EXACTLY %d-%d without gaps; nested calls may use other files.")
    :format(selection.file, coverage.start, coverage["end"])
  if args.coverage then
    lines[#lines + 1] = "Read the whole coverage range from source. Parts must cover it without gaps; give the selection its own detailed part(s)."
  end
  if args.context and args.context:find("%S") then
    lines[#lines + 1] = "If Extra context asks for a diff, append --review and --base REF when specified (default HEAD); read that diff."
  end
  return deliver(lines, args.command)
end

function M.symbol(args)
  local context = args.context
  local example = context.box.example or context.stop.example
  local lines = {
    "[code-tour explain]",
    "Resolve and explain the SYMBOL AT THIS CALL SITE, not the caller. Keep this expansion shallow; deeper calls stay lazy.",
    "Definition lookup failed: " .. tostring(args.reason or "No definition found"),
    "Project root: " .. args.root,
    "Symbol under cursor: " .. context.symbol,
    "Call expression: " .. context.expression,
    ("Call site: %s:%d (byte column %d)\nNearby source:\n```\n%s\n```")
      :format(context.path, context.cursor[1], context.cursor[2] + 1, context.nearby),
    "Caller box " .. args.box_id .. ": " .. context.box.note,
    rules(example),
    'Locate the real implementation via receiver/imports; return JSON definition stops with current ranges. If unavailable, return {"unresolved":"reason"}.',
  }
  local trace = example_text(example, context.callsite.start, context.callsite["end"], true)
  if trace then lines[#lines + 1] = trace end
  return deliver(lines, args.command)
end

function M.definition(args)
  local stop, box, target = args.stop, args.box, args.target
  local example = box.example or stop.example
  local site = target and target.callsite
  local first = site and site.start or box.start
  local last = site and site["end"] or first
  -- Inferred legacy sites can span the whole overview without naming a symbol.
  if site and not site.symbol and site.start_col == nil then last = first end
  local lines = {
    args.same and "[code-tour refine]" or "[code-tour explain]",
    "Project root: " .. args.root,
    "Caller box " .. args.box_id .. ": " .. box.note,
    "Call site:\n" .. source(stop, math.max(1, first - 2), math.min(vim.api.nvim_buf_line_count(stop.buf), last + 2)),
    ("Definition: %s:%d"):format(args.path, args.line),
    rules(example),
    "Keep this expansion shallow; deeper calls stay lazy.",
  }
  if args.same then
    lines[#lines + 1] = ("Refine definition box %s at %s:%d-%d; read source and return parts covering that full range.")
      :format(args.target_id, stop.file, args.definition_box.start, args.definition_box["end"])
    if args.definition_box ~= box then lines[#lines + 1] = "Target note: " .. args.definition_box.note end
  else
    lines[#lines + 1] = "Read the real definition behind this location (follow export aliases); return JSON definition stops with current ranges."
  end
  local trace = example_text(example, first, last, true)
  if trace then lines[#lines + 1] = trace end
  return deliver(lines, args.command)
end

return M
