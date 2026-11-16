-- Send only the context for this request. Full placement snapshots stay local.
local M = {}

-- Optional lines may be nil inside a table constructor; drop them before joining.
local function join(lines)
  local out = {}
  for i = 1, table.maxn(lines) do
    if lines[i] ~= nil then
      out[#out + 1] = lines[i]
    end
  end
  return table.concat(out, "\n")
end

function M.saved(args)
  local entry, capture = args.entry, args.capture
  local first, last = require("code-tour.source").lines(capture.range)
  return join({
    "[code-tour saved regeneration] tour: " .. args.tour,
    "Project root: " .. entry.root,
    entry.because and ("Linked: update because " .. entry.because) or nil,
    "Box: " .. entry.id .. " (" .. entry.role .. ")",
    ("%s:%d-%d\nExact byte range (zero-based, exclusive end): %s\n```\n%s\n```")
      :format(entry.path, first, last, vim.json.encode(capture.range), capture.text),
    "Reply: " .. args.command,
  })
end

-- Several queued saved boxes in one round trip; each reply stop names its box.
function M.saved_batch(args)
  local lines_of = require("code-tour.source").lines
  local items = args.items
  local lines = {
    "[code-tour saved regeneration batch] tour: " .. args.tour,
    "Project root: " .. items[1].entry.root,
    ("Boxes: %d"):format(#items),
  }
  for _, item in ipairs(items) do
    local entry, capture = item.entry, item.capture
    local first, last = lines_of(capture.range)
    lines[#lines + 1] = ("\n## Box: %s (%s)\n%s:%d-%d\n%sExact byte range (zero-based, exclusive end): %s\n```\n%s\n```")
      :format(entry.id, entry.role, entry.path, first, last,
        entry.because and ("Linked: update because " .. entry.because .. "\n") or "",
        vim.json.encode(capture.range), capture.text)
  end
  vim.list_extend(lines, {
    "",
    "Reply: " .. args.command,
  })
  return join(lines)
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

local function reply(lines, command, stale)
  if stale then
    table.insert(lines, 2, stale)
  end
  lines[#lines + 1] = "Reply: " .. command
  return join(lines)
end

function M.selection(args)
  local selection = args.selection
  local lines = {
    "[code-tour explain] tour: " .. args.tour,
    ("stop %s · %s:%d-%d\n```\n%s\n```"):format(args.box_id, selection.file, selection.start, selection["end"], selection.text),
  }
  if args.coverage then
    lines[#lines + 1] = ("Cover %d-%d."):format(args.coverage.start, args.coverage["end"])
  end
  if args.context and args.context:find("%S") then lines[#lines + 1] = "Extra context: " .. args.context end
  local example = example_text(args.example, selection.start, selection["end"])
  if example then lines[#lines + 1] = example end
  return reply(lines, args.command, args.stale)
end

function M.symbol(args)
  local context = args.context
  local example = context.box.example or context.stop.example
  local lines = {
    "[code-tour symbol] tour: " .. args.tour,
    ("stop %s · call site %s:%d (byte column %d)"):format(args.box_id, context.path, context.cursor[1], context.cursor[2] + 1),
    "Symbol: " .. context.symbol .. " · Call: " .. context.expression,
    "Lookup failed: " .. tostring(args.reason or "No definition found"),
  }
  local trace = example_text(example, context.callsite.start, context.callsite["end"], true)
  if trace then lines[#lines + 1] = trace end
  return reply(lines, args.command, args.stale)
end

function M.definition(args)
  local stop, box, target = args.stop, args.box, args.target
  local example = box.example or stop.example
  local site = target and target.callsite
  local first = site and site.start or box.start
  local last = site and site["end"] or first
  if site and not site.symbol and site.start_col == nil then last = first end
  local lines = {
    (args.same and "[code-tour refine]" or "[code-tour definition]") .. " tour: " .. args.tour,
    ("stop %s · call site %s:%d-%d"):format(args.box_id, stop.file, first, last),
    ("Definition: %s:%d"):format(args.path, args.line),
  }
  if args.same then
    lines[#lines + 1] = ("Refine box %s (%s:%d-%d)"):format(args.target_id, stop.file, args.definition_box.start, args.definition_box["end"])
  end
  local trace = example_text(example, first, last, true)
  if trace then lines[#lines + 1] = trace end
  return reply(lines, args.command, args.stale)
end

return M
