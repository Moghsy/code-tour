-- Headless CLI runs use the language list the editor recorded; the variable overrides it.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local t = dofile(here .. "/ast_common.lua")
local ast = require("code-tour.ast")

t.finish("AST languages", function()
  local data = vim.fn.tempname()
  vim.env.XDG_DATA_HOME = data
  t.eq(ast.remembered_languages(), nil, "nothing recorded yet")

  require("code-tour.instance").register = function() end
  require("tour").setup({ keys = false, ast = { languages = { "java", "typescript" } } })
  t.eq(ast.remembered_languages(), nil, "a Neovim without a UI records nothing")
  vim.api.nvim_exec_autocmds("UIEnter", {})
  t.eq(ast.remembered_languages(), { "java", "typescript" }, "the editor records its list once it has a UI")

  if not require("code-tour.ast.index").parser_available("typescript") then
    print("MISSING PARSER: typescript (verification gap)")
    return
  end
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "export function main() {}" }, root .. "/main.ts")
  t.run({ "git", "init", "-q" }, root)
  local function graph(env)
    local run = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l",
      t.plugin .. "/lua/code-tour/ast/headless.lua", "codegraph", "--root", root, "--out", vim.fn.tempname() },
      { text = true, env = vim.tbl_extend("force", {
        XDG_DATA_HOME = data, XDG_CACHE_HOME = vim.fn.tempname(),
        CODE_TOUR_PARSER_RUNTIME = vim.env.CODE_TOUR_PARSER_RUNTIME or vim.fn.expand("~/.local/share/nvim/site"),
      }, env or {}) }):wait()
    t.eq(run.code, 0, "headless codegraph: " .. run.stderr)
    return vim.json.decode(run.stdout).files
  end
  t.eq(graph(), 1, "a headless run reads the recorded list")
  t.eq(graph({ CODE_TOUR_AST_LANGUAGES = "java" }), 0, "the variable overrides it")
end)
