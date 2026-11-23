-- Headless entry for the CLI when no editor is used:
--   nvim --headless -u NONE -i NONE -l lua/code-tour/ast/headless.lua codegraph --root R [--out P]
--   nvim --headless -u NONE -i NONE -l lua/code-tour/ast/headless.lua ast --request '{"entries":[...]}'
-- Prints one JSON object on stdout; exits 1 with {"error": ...} on failure.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
vim.opt.rtp:prepend(plugin)
if vim.env.CODE_TOUR_PARSER_RUNTIME then
  vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME)
end

-- Headless Neovim skips the user's init, so allow a language list for CLI jobs.
if vim.env.CODE_TOUR_AST_LANGUAGES then
  local languages = vim.split(vim.env.CODE_TOUR_AST_LANGUAGES, "[,%s]+", { trimempty = true })
  require("code-tour.ast").setup({ languages = languages })
end

local function parse(argv)
  local cmd, opts = argv[1], {}
  local i = 2
  while i <= #argv do
    local key = argv[i]:match("^%-%-(.+)$")
    if not key then
      error("unexpected argument: " .. argv[i])
    end
    opts[key:gsub("%-", "_")] = argv[i + 1]
    i = i + 2
  end
  return cmd, opts
end

local ok, result = pcall(function()
  local cmd, opts = parse(arg)
  if cmd == "codegraph" then
    return require("code-tour.ast").code_graph(opts)
  elseif cmd == "analyze" then
    return require("code-tour.ast").analyze(vim.json.decode(opts.request))
  elseif cmd == "ast" then
    -- the request is one JSON object: { entries, root?, detail?, through? }
    local req = vim.json.decode(opts.request)
    return require("code-tour.ast").outline(req.entries, req)
  elseif cmd == "knowledge" then
    local req = vim.json.decode(opts.request)
    if opts.input then
      local file = assert(io.open(opts.input, "r"))
      req.markdown = file:read("*a")
      file:close()
    end
    return require("code-tour.ast.knowledge").run(req.action, req)
  elseif cmd == "store" then
    return require("code-tour.ast.store").new(require("code-tour.ast").index({ root = opts.root }),
      require("code-tour.ast").options):prune()
  end
  error("unknown command: " .. tostring(cmd))
end)
if ok then
  io.stdout:write(vim.json.encode(result), "\n")
  vim.cmd("qall!")
else
  io.stdout:write(vim.json.encode({ error = tostring(result) }), "\n")
  vim.cmd("cquit 1")
end
