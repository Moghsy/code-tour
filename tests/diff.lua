local plugin = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(plugin)
vim.o.lines, vim.o.columns = 50, 120
require("code-tour.instance").register = function() end
require("code-tour.conversation").deliver = function(_, _root, _, _, cb)
  cb(true)
end
local tour = require("tour")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local checks = 0
local function check(value, message)
  assert(value, message)
  checks = checks + 1
end
local function stop(a, b)
  return { file = "code.lua", start = a, ["end"] = b, note = "Changes" }
end
local function show()
  local data = stop(1, 7)
  data.parts = {
    { start = 1, ["end"] = 2, note = "Multiply" },
    { start = 3, ["end"] = 5, note = "Return" },
    { start = 6, ["end"] = 7, note = "Call" },
  }
  tour.show({ data }, { root = root })
end
local function colors()
  local state = tour.state()
  local groups, removed = {}, {}
  for _, mark in
    ipairs(
      vim.api.nvim_buf_get_extmarks(
        state.stops[1].buf,
        vim.api.nvim_get_namespaces().CodeTourSource,
        0,
        -1,
        { details = true }
      )
    )
  do
    if mark[4].hl_eol then
      groups[mark[2] + 1] = mark[4].hl_group
    end
    for _, row in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(row) do
        if chunk[1]:sub(1, #"− ") == "− " then
          removed[chunk[1]:sub(#"− " + 1)] = chunk[2]
        end
      end
    end
  end
  return groups, removed
end
local function request(a, b)
  local sel = require("code-tour.selection").capture(tour.state(), { start = a, ["end"] = b })
  return tour.explain_range(sel, "Please explain the diff against HEAD")
end
local function test()
  git({ "init", "--quiet" })
  local before = {
    "local function sum(a, b)",
    "  local value = a + b",
    "  return value",
    "end",
    "",
    "local result = sum(1, 2)",
    "print(result)",
  }
  vim.fn.writefile(before, root .. "/code.lua")
  git({ "add", "." })
  git({ "-c", "user.name=Tour test", "-c", "user.email=tour@test.invalid", "commit", "--quiet", "-m", "base" })
  local after = {
    "local function sum(a, b)",
    "  local value = a * b",
    "  return value + 1",
    "end",
    "",
    "local result = sum(3, 4)",
    "print(result)",
  }
  vim.fn.writefile(after, root .. "/code.lua")
  tour.setup({ smooth_scroll = false })
  show()
  local buf = tour.state().stops[1].buf
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  check(not tour.state().stops[1].added, "Plain tours should not enable diff styling")
  tour.review("HEAD")
  tour.next_explanation(1)
  local green, red = colors()
  check(
    green[2] == "CodeTourDiffAddFocus" and green[3] == "CodeTourDiffAdd" and green[6] == "CodeTourDiffAdd",
    "Added code needs selected and unselected green backgrounds"
  )
  check(green[1] == "CodeTourFocus" and green[4] == "CodeTourStop", "Unchanged lines retain normal focus backgrounds")
  check(
    red[before[2]] == "CodeTourDiffDeleteFocus"
      and red[before[3]] == "CodeTourDiffDelete"
      and red[before[6]] == "CodeTourDiffDelete",
    "Removed lines need selected and unselected red intensities even within one hunk"
  )
  tour.next_explanation(1)
  green, red = colors()
  check(
    green[2] == "CodeTourDiffAdd" and green[3] == "CodeTourDiffAddFocus",
    "Green focus intensity follows subpart navigation"
  )
  check(
    red[before[2]] == "CodeTourDiffDelete" and red[before[3]] == "CodeTourDiffDeleteFocus",
    "Red focus intensity follows the corresponding removed line"
  )
  local previous = tour.state().stops[1].added
  check(
    not pcall(tour.review, "missing-ref") and tour.state().stops[1].added == previous,
    "Invalid review bases must leave existing diff data intact"
  )

  show()
  local one = request(6, 6)
  tour.fill(one, { stop(6, 6) }, { review = true, base = "HEAD" })
  check(tour.state().stops[1].added[6], "Requested diff data must survive fill into an existing snippet")
  local two, prompt = request(3, 3)
  check(prompt:find("Extra context:", 1, true), "Context requests carry the extra context")
  tour.fill(two, { stop(3, 3) }, { review = true, base = "HEAD" })
  green, red = colors()
  check(
    green[3] == "CodeTourDiffAddFocus" and green[6] == "CodeTourDiffAdd" and not tour.state().stops[1].added[2],
    "Selection diff fill must preserve sibling changes without expanding its range"
  )
  check(
    red[before[3]] == "CodeTourDiffDeleteFocus" and red[before[6]] == "CodeTourDiffDelete" and not red[before[2]],
    "A selection starting inside a replacement hunk must keep just its removed lines"
  )
  local again = request(3, 3)
  tour.fill(again, { stop(3, 3) }, { review = true })
  local deleted_count = 0
  for _, removed in ipairs(tour.state().stops[1].removed) do
    for _, line in ipairs(removed.lines) do
      if line == before[3] then
        deleted_count = deleted_count + 1
      end
    end
  end
  check(deleted_count == 1, "Repeated fills must replace rather than duplicate a range's removed lines")
  check(
    vim.api.nvim_buf_get_changedtick(buf) == tick
      and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), after),
    "Diff rendering must never change source or changedtick"
  )
  tour.stop()
  print("PASS: " .. checks .. " diff requests, per-subpart colors and clipped deletion assertions")
end
local ok, err = xpcall(test, debug.traceback)
if ok then
  vim.cmd("qa!")
else
  io.stderr:write(err .. "\n")
  vim.cmd("cquit 1")
end
