local M = {}
local keywords = {}
for word in ("and as async await break case catch class const continue def default do else elseif end enum export extends "
  .. "false finally for from function if implements import in instanceof interface let local new nil not null of or "
  .. "pass public private protected return self static super switch then this throw true try type typeof undefined "
  .. "var void while with yield"):gmatch("%S+") do keywords[word] = true end

-- A source identifier explicitly selects that symbol, even without call
-- parentheses (for example, a superclass after extends). Whitespace and language
-- keywords still let ad offer the current box's attached calls.
function M.symbol_at(text, col)
  for first, symbol, last in text:gmatch("()([%a_$][%w_$]*)()") do
    if col >= first - 1 and col < last - 1 then
      return not keywords[symbol] and symbol or nil
    end
  end
end

function M.capture(state, stop, box, site)
  local cursor = vim.api.nvim_win_get_cursor(state.win)
  if site then
    local line = vim.api.nvim_buf_get_lines(stop.buf, site.start - 1, site.start, false)[1] or ""
    local first = site.symbol and line:find(site.symbol, 1, true)
    cursor = { site.start, site.start_col or (first and first - 1 or 0) }
  end
  local text = vim.api.nvim_buf_get_lines(stop.buf, cursor[1] - 1, cursor[1], false)[1] or ""
  local col = math.min(cursor[2] + 1, #text)
  local function name_char(at)
    return at > 0 and text:sub(at, at):match("[%w_$%.:%[%]?!]") ~= nil
  end
  if not name_char(col) and name_char(col - 1) then col = col - 1 end
  local first, last = col, col
  if name_char(col) then
    while name_char(first - 1) do first = first - 1 end
    while name_char(last + 1) do last = last + 1 end
  else
    first, last = 1, 0
  end
  local expression = text:sub(first, last)
  local symbol = vim.api.nvim_win_call(state.win, function() return vim.fn.expand("<cword>") end)
  if site and site.symbol then symbol = site.symbol:match("([%w_$]+)$") or site.symbol end
  local count = vim.api.nvim_buf_line_count(stop.buf)
  local nearby_start, nearby_end = math.max(1, cursor[1] - 2), math.min(count, cursor[1] + 2)
  return {
    tour = state.id, stop = stop, box = box, win = state.win, buf = stop.buf,
    file = stop.file, path = stop.path, tick = vim.api.nvim_buf_get_changedtick(stop.buf), cursor = cursor,
    symbol = symbol, expression = expression ~= "" and expression or symbol,
    callsite = { start = cursor[1], ["end"] = cursor[1],
      symbol = expression ~= "" and expression or symbol,
      start_col = last >= first and first - 1 or nil, end_col = last >= first and last or nil },
    nearby_start = nearby_start, nearby_end = nearby_end,
    nearby = table.concat(vim.api.nvim_buf_get_lines(stop.buf, nearby_start - 1, nearby_end, false), "\n"),
    box_text = box.byte_range and require("code-tour.source").text(stop.buf, box.byte_range)
      or table.concat(vim.api.nvim_buf_get_lines(stop.buf, box.start - 1, box["end"], false), "\n"),
  }
end

function M.active(state, context)
  if state.id ~= context.tour or state.lookup ~= context
    or not vim.api.nvim_win_is_valid(context.win) or not vim.api.nvim_buf_is_valid(context.buf)
    or vim.api.nvim_win_get_buf(context.win) ~= context.buf
    or vim.api.nvim_buf_get_changedtick(context.buf) ~= context.tick
    or state.stops[state.stop] ~= context.stop then return false end
  local boxes = require("code-tour.stops").boxes(context.stop)
  local cursor = vim.api.nvim_win_get_cursor(context.win)
  return boxes[state.box] == context.box and cursor[1] == context.cursor[1] and cursor[2] == context.cursor[2]
end

function M.resolve(context, success, failure)
  local clients = vim.lsp.get_clients({ bufnr = context.buf, method = "textDocument/definition" })
  if #clients > 0 then
    local client, done = clients[1], false
    local function receive(err, result)
      if done then return end
      done = true
      vim.schedule(function()
        if err or type(result) ~= "table" or vim.tbl_isempty(result) then
          failure(err and (type(err) == "table" and err.message or tostring(err)) or "LSP returned no definition")
        else
          success(result.uri and result or result[1] or result)
        end
      end)
    end
    local ok, sent = pcall(function()
      return client:request("textDocument/definition",
        vim.lsp.util.make_position_params(context.win, client.offset_encoding), receive, context.buf)
    end)
    if not ok or sent == false then receive(ok and "LSP definition request could not be sent" or sent, nil) end
    return
  end

  -- Retain the existing local Tree-sitter lookup when no LSP provider exists.
  local ok, location = pcall(function()
    local parser = vim.treesitter.get_parser(context.buf)
    if not parser then return end
    local trees = parser:parse()
    local node = vim.treesitter.get_node({ bufnr = context.buf,
      pos = { context.cursor[1] - 1, context.cursor[2] } })
    if not node then return end
    local name, found = vim.treesitter.get_node_text(node, context.buf)
    local function walk(n)
      if found then return end
      if n:type():match("function") or n:type():match("declaration") or n:type():match("definition") then
        for _, field in ipairs(n:field("name")) do
          if vim.treesitter.get_node_text(field, context.buf) == name then
            local a, c, b, d = n:range()
            found = { uri = vim.uri_from_fname(context.path),
              range = { start = { line = a, character = c }, ["end"] = { line = b, character = d } } }
            return
          end
        end
      end
      for child in n:iter_children() do walk(child) end
    end
    if trees[1] then walk(trees[1]:root()) end
    return found
  end)
  if ok and location then return success(location) end
  return failure(ok and "No definition provider or local definition found" or tostring(location))
end

return M
