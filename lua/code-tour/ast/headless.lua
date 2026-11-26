-- Headless entry for the CLI when no editor is used:
--   nvim --headless -u NONE -i NONE -l lua/code-tour/ast/headless.lua codegraph --root R [--out P]
--   nvim --headless -u NONE -i NONE -l lua/code-tour/ast/headless.lua ast --request '{"entries":[...]}'
-- Prints one JSON object on stdout; exits 1 with {"error": ...} on failure.
local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
vim.opt.rtp:prepend(plugin)
if vim.env.CODE_TOUR_PARSER_RUNTIME then
  vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME)
end

-- Headless Neovim skips the user's init. The language list is CODE_TOUR_AST_LANGUAGES for
-- CLI jobs, else the one the editor last used, else the default.
local languages = vim.env.CODE_TOUR_AST_LANGUAGES
    and vim.split(vim.env.CODE_TOUR_AST_LANGUAGES, "[,%s]+", { trimempty = true })
  or require("code-tour.ast").remembered_languages()
if languages then
  require("code-tour.ast").setup({ languages = languages })
end

-- CODE_TOUR_CONFIG: a Lua file returning { ast = {...}, workspace = {...} }, the same tables as
-- setup() takes, so the CLI sees the workspace hooks (SPEC-workspace.md §6). Unset, nothing loads.
if vim.env.CODE_TOUR_CONFIG and vim.env.CODE_TOUR_CONFIG ~= "" then
  local loaded, err = pcall(function()
    local config = assert(loadfile(vim.fn.expand(vim.env.CODE_TOUR_CONFIG)))()
    assert(type(config) == "table", "CODE_TOUR_CONFIG must return a table")
    if config.ast then
      require("code-tour.ast").setup(vim.tbl_extend("force", { languages = languages }, config.ast))
    end
    require("code-tour.workspace").setup(config.workspace)
  end)
  if not loaded then
    io.stdout:write(vim.json.encode({ error = "CODE_TOUR_CONFIG: " .. tostring(err) }), "\n")
    vim.cmd("cquit 1")
  end
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
  elseif cmd == "concepts" then
    return require("code-tour.ast").concepts(vim.json.decode(opts.request))
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
