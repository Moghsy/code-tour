local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/nested", "p")
local function git(args)
  local command = { "git" }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function test()
  git({ "init", "--quiet" })
  vim.fn.writefile({ "one", "two", "three", "four" }, root .. "/nested/code.txt")
  git({ "add", "." })
  git({ "-c", "user.name=Tour test", "-c", "user.email=tour@test.invalid", "commit", "--quiet", "-m", "base" })
  vim.fn.writefile({ "one", "new", "four" }, root .. "/nested/code.txt")
  local stop = require("code-tour.stops").normalize(
    { { file = "code.txt", start = 1, ["end"] = 3, note = "Changes" } },
    root .. "/nested"
  )[1]
  local review = require("code-tour.review")
  review.prepare(stop, root .. "/nested", "HEAD")
  assert(stop.added[2] and not stop.added[1] and not stop.added[3], "Git additions must use current line numbers")
  assert(vim.deep_equal(stop.removed[1].lines, { "two", "three" }), "Git deletion should preserve old text")
  assert(stop.removed[1].line == 2 and stop.removed[1].above, "Replacement deletions belong above replacement")
  assert(not pcall(review.prepare, stop, root, "missing-ref"), "Invalid Git ref must fail")
  vim.fn.writefile({ "fresh" }, root .. "/new.txt")
  local fresh = require("code-tour.stops").normalize(
    { { file = "new.txt", start = 1, ["end"] = 1, note = "New file" } },
    root
  )[1]
  review.prepare(fresh, root, "HEAD")
  assert(fresh.added[1], "New files must be additions")
  local explicit = require("code-tour.stops").normalize(
    { { file = "nested/code.txt", start = 2, ["end"] = 2, note = "Local", old = "prior" } },
    root
  )[1]
  review.prepare(explicit, root, "missing-ref")
  assert(
    explicit.added[2] and explicit.removed[1].lines[1] == "prior",
    "Explicit old overrides Git and offsets to snippet lines"
  )
  print("PASS: Git base, subdirectory paths, removed text, invalid ref, new file, explicit old")
end
local ok, err = xpcall(test, debug.traceback)
if ok then
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
