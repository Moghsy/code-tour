local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")

t.finish("AST fallback", function()
  local ast = require("code-tour.ast")
  local root = t.project()
  local file = "Workflow.unknown"
  local lines = { "prepare input", "run checkout", "format receipt" }
  vim.fn.writefile(lines, root .. "/" .. file)
  local unavailable = ast.outline({ file .. ":2" }, { root = root })
  t.check(unavailable.fallback and unavailable.reason:find("no backend", 1, true), "Unsupported source returns fallback")
  t.check(unavailable.reason:find("AST languages enabled: java", 1, true), "A fallback names the enabled languages")

  -- a symbol in a project with no file in an enabled language is a fallback, not a typo
  local js = vim.fn.tempname()
  vim.fn.mkdir(js, "p")
  vim.fn.writefile({ "function handleKey(event) { return event.key; }" }, js .. "/keys.js")
  t.run({ "git", "init", "-q" }, js)
  t.run({ "git", "add", "-A" }, js)
  local by_symbol = ast.outline({ "Keys#handleKey" }, { root = js })
  t.check(by_symbol.fallback and by_symbol.reason:find("no source file in an enabled AST language", 1, true),
    "An unknown symbol in an unsupported project returns fallback")
  t.check(by_symbol.reason:find("CODE_TOUR_AST_LANGUAGES", 1, true), "and says how to enable Python")
  t.check(not pcall(ast.outline, { "Nowhere#nothing" }, { root = root }),
    "an unknown symbol in a supported project stays an error")
  local added = {
    kind = "add",
    value = vim.json.encode({ file = file, start = 1, ["end"] = 3,
      regions = { { start = 1, ["end"] = 2 }, { start = 3, ["end"] = 3 } } }),
  }
  local live = require("code-tour.ast.live")
  local tour = assert(live.new({ root = root, overrides = { added } }))
  local sn = tour.snippets.n1
  t.eq(sn.regions[1].origin, "agent", "Authored regions have agent origin")
  t.eq(sn.file, file, "An authored range can form an entry")
  tour:fill("n1", "## overview\nProcess a workflow.\n\nPrepare input and format the result.")
  tour:remember()
  vim.fn.writefile(vim.list_extend({ "header" }, lines), root .. "/" .. file)
  vim.cmd("checktime " .. tour:buf(file))
  local relocated = assert(live.new({ root = root, recipe = tour.recipe }))
  t.eq(relocated.snippets.n1.lines, { 2, 4 }, "Agent entry relocates after insertion")
  t.eq(relocated:lookup(relocated.snippets.n1).gist, "Process a workflow.", "Relocated range keeps its explanation")

  local java = "src/main/java/shop/order/OrderService.java"
  local add_parser = vim.treesitter.language.add
  vim.treesitter.language.add = function(lang, ...)
    if lang == "java" then return nil, "test parser is unavailable" end
    return add_parser(lang, ...)
  end
  local ok, result = pcall(ast.outline, { java .. ":29" }, { root = root })
  local ok_name, by_name = pcall(ast.outline, { "OrderService#checkout" }, { root = root })
  vim.treesitter.language.add = add_parser
  t.check(ok and result.fallback and result.reason:find("no parser", 1, true), "Missing parser returns fallback")
  t.check(ok_name and by_name.fallback and by_name.reason:find("no parser", 1, true), "Missing parser at a named entry")

  if not t.parser() then return end
  local invalid = "Broken.java"
  vim.fn.writefile({ "class Broken {", "  int invalid() {", "    return 1 + ;", "  }", "}" }, root .. "/" .. invalid)
  local broken = ast.outline({ invalid .. ":3" }, { root = root, cache_dir = t.cache })
  t.check(broken.fallback and broken.reason:find("parse error", 1, true), "Entry parse error returns fallback")
end)
