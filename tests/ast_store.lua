-- Repository notes, evidence, versioning and history (§11).
local t = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/ast_common.lua")
local check, eq = t.check, t.eq

local checkout = "OrderService#checkout"

local function live(root, entry, detail)
  return assert(require("code-tour.ast.live").new({ root = root, entries = { entry or checkout },
    overrides = t.route(), detail = detail, cache_dir = t.cache }))
end

local function gist(tour, n, r)
  local sn = tour.snippets[n or "n1"]
  return tour:lookup(sn, r and sn.regions[r] or nil)
end

local function write(root, file, edit)
  local path = root .. "/" .. file
  local txt = table.concat(vim.fn.readfile(path, "b"), "\n")
  local updated = edit(txt)
  check(updated ~= txt, "fixture edit changed " .. file)
  vim.fn.writefile(vim.split(updated, "\n", { plain = true }), path, "b")
  local buf = vim.fn.bufnr(path)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent edit!") end)
  end
  return txt
end

local function restore(root, files)
  t.run(vim.list_extend({ "git", "checkout", "--" }, files), root)
  for _, file in ipairs(files) do
    local buf = vim.fn.bufnr(root .. "/" .. file)
    if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
      vim.api.nvim_buf_call(buf, function() vim.cmd("silent edit!") end)
    end
  end
end

t.finish("ast store", function()
  if not t.parser() then
    return
  end
  local store = require("code-tour.ast.store")
  local root = t.project()
  local first = live(root)
  local entry, callee = first.snippets.n1, first.snippets.n2
  local address = { file = entry.file, symbol = entry.symbol }
  eq(first.store.path, root .. "/.code-tour", "repository store name")
  check(not vim.uv.fs_stat(first.store.path), "an empty lookup creates no store files")

  first:fill("n1", { overview = { gist = "Charge the order.", body = "Calculate the amount and charge it.",
    example = { source = "generated", text = "Two items cost a total of 30." } } }, { model = "light-model" })
  first:fill("n1", "## r2\nRecalculate the total.\n\nFold all line amounts.")
  first:fill("n2", "## overview\nSum the line amounts.\n\nSum.")
  local call
  for _, site in ipairs(entry.sites) do
    if site.target == callee.symbol and site.mode == "walk" then call = site end
  end
  check(call ~= nil, "fixture has a walked caller and callee")
  first:fill("n1", "## edge " .. call.site .. "\nCompute the amount to charge.")
  local id = first:remember()
  local stored = vim.json.decode(table.concat(vim.fn.readfile(first.store:file_path(entry.file)), "\n"))
  local version = stored.notes[entry.symbol][1]
  eq(version.evidence.callees[callee.symbol], callee._fps[callee.symbol], "overview records walked callee")
  eq(version.bodies.normal.model, "light-model", "body model provenance")
  eq(version.bodies.normal.commit, vim.trim(t.run({ "git", "rev-parse", "HEAD" }, root)), "body commit provenance")
  check(vim.tbl_contains(vim.fn.readfile(root .. "/.git/info/exclude"), ".code-tour/"), "local Git exclusion")
  eq(vim.trim(t.run({ "git", "status", "--short" }, root)), "", "store leaves a clean status")

  local reopened = live(root)
  local reopened_entry = reopened.snippets.n1
  eq(gist(reopened).body, "Calculate the amount and charge it.", "filled body persists on reopen")
  check(reopened:presentation(reopened_entry).note:find("Example (generated)", 1, true), "example labeled by source")
  eq(gist(reopened).note.example.text, "Two items cost a total of 30.", "standard example persists")
  eq(reopened.store:recipe(id).entries, { entry.symbol }, "recipes keep stable symbol ids")
  eq(reopened.store:recipes()[1].id, id, "history gets the recipe")
  local edge_notes = vim.tbl_filter(function(edge) return edge.target == callee.symbol end, reopened.tour.route)
  eq(edge_notes[1].why, "Compute the amount to charge.", "edge why persists")
  local detail = live(root, checkout, "detailed")
  eq({ gist(detail).body, gist(detail).level, gist(detail).exact },
    { "Calculate the amount and charge it.", "normal", false }, "nearest body fallback")
  local far = live(root, checkout, "exhaustive")
  check(gist(far).body == nil and gist(far).gist == "Charge the order.", "only gist two levels away")
  detail:fill("n1", "## overview\nCharge the order.\n\nDetailed.")
  eq(gist(reopened).body, "Calculate the amount and charge it.", "other level survives overlapping store instances")
  eq(gist(detail).body, "Detailed.", "detailed body stored")

  local turn = { question = "How is it calculated?" }
  first:save_turn(entry, nil, turn)
  turn.answer = "Add the line amounts."
  reopened:save_turn(reopened_entry, nil, turn)
  local thread = detail:thread(detail.snippets.n1)
  eq(#thread, 1, "reply replaces question by turn identity")
  eq(thread[1].answer, turn.answer, "thread stored across writers and detail")

  write(root, callee.file, function(txt) return txt:gsub("Money sum = Money.zero%(%)", "Money sum = Money.of(200)") end)
  eq(first:status(entry), "stale", "an already open tour also rechecks changed callees")
  local changed = live(root)
  local _, status, reason = gist(changed)
  eq({ status, reason }, { "stale", "callee changed" }, "body-only callee edit invalidates stored caller")
  eq(changed:presentation(changed.snippets.n1).note, "Being written…", "stale text and example are hidden")
  eq(changed:thread(changed.snippets.n1), {}, "thread is hidden with stale note")
  eq(changed:previous(changed.snippets.n1).gist, "Charge the order.", "writer can see prior gist")
  check(not changed.tour.route[1].why or changed.tour.route[1].why ~= edge_notes[1].why, "old edge why is withheld")
  local _, child_status = gist(changed, "n1", 2)
  eq(child_status, "stale", "callee evidence also covers its caller box")
  check(changed:write_status(changed.snippets.n1):find("overview (linked)", 1, true), "stale root linked to child")
  changed:fill("n1", "## overview\nChanged estimate.\n\nIncludes a constant.")
  eq(gist(changed).gist, "Changed estimate.", "new callee version is stored")
  eq(changed:thread(changed.snippets.n1), {}, "rewritten note does not inherit older thread")
  restore(root, { callee.file })
  local restored = live(root)
  eq(gist(restored).gist, "Charge the order.", "older callee version reused after switching back")
  eq(restored:thread(restored.snippets.n1)[1].answer, turn.answer, "original evidence restores the old thread")

  write(root, callee.file, function(txt) return txt:gsub("Money sum = ", "/* accumulated */ Money   sum = ") end)
  local cosmetic = live(root)
  eq(gist(cosmetic).gist, "Charge the order.", "comments and formatting preserve evidence")
  restore(root, { callee.file })

  local worktree = vim.fn.tempname() .. "-linked"
  t.run({ "git", "worktree", "add", "-q", "--detach", worktree }, root)
  eq(store.new(t.index(worktree)).path, first.store.path, "linked worktree uses main store")
  eq(gist(live(worktree)).gist, "Charge the order.", "notes are usable in linked worktree")
  local user_options = { store = "user" }
  local user = store.new(t.index(root), user_options)
  local expected = vim.fn.stdpath("data") .. "/code-tour/store/" ..
    vim.fn.sha256(vim.trim(t.run({ "git", "rev-list", "--max-parents=0", "HEAD" }, root)))
  eq(user.path, expected, "user store is keyed by the first commit")
  eq(store.new(t.index(worktree), user_options).path, expected, "user store identity is shared by worktrees")
  user:set_meta("record_consent", true)
  eq(user:meta().record_consent, true, "project metadata survives a write")
  eq(user:status(entry.symbol, entry._fps[entry.symbol], "normal", address), "missing", "user mode is isolated")

  -- Conflict provenance stays invalid until this worktree writes a fresh version.
  local absolute = first.store:file_path(entry.file)
  local rel = absolute:sub(#root + 2)
  local sha = vim.trim(t.run({ "git", "hash-object", "-w", "--", rel }, root))
  local stage = ("100644 %s 1\t%s\n100644 %s 2\t%s\n100644 %s 3\t%s\n"):format(sha, rel, sha, rel, sha, rel)
  local git = vim.system({ "git", "-C", root, "update-index", "--index-info" }, { stdin = stage }):wait()
  eq(git.code, 0, "create an unmerged note index entry")
  local conflicted = live(root)
  local _, conflict_status, conflict_reason = gist(conflicted)
  eq({ conflict_status, conflict_reason }, { "stale", "note conflict" }, "unmerged note does not leak valid-looking JSON")
  conflicted:fill("n1", "## overview\nRegenerated after conflict.")
  eq(gist(live(root)).gist, "Regenerated after conflict.", "regeneration becomes available even before Git stages the note")

  -- Renames and moves keep prior text, while missing history entries remain in the
  -- durable recipe so a later branch can restore them.
  local relocated_root = t.project()
  local initial = live(relocated_root, "Order#total")
  local initial_entry = initial.snippets.n1
  initial:fill("n1", "## overview\nSum all the amounts.\n\nFold the line totals.")
  local initial_id = initial:remember()
  local saved = initial.store:recipe(initial_id)
  write(relocated_root, initial_entry.file, function(txt) return txt:gsub("Money total%(%)", "Money amount()", 1) end)
  local recovered, recovery_err = require("code-tour.ast.live").new({ root = relocated_root, recipe = saved,
    cache_dir = t.cache })
  check(recovered ~= nil, tostring(recovery_err))
  check(recovered.snippets.n1.symbol:find("#amount", 1, true), "history reopens the uniquely renamed symbol")
  eq(gist(recovered).body, "Fold the line totals.", "renamed symbol reuses its previous note")
  check(recovered.snippets.n2 and recovered.snippets.n2.symbol:find("Line#subtotal", 1, true),
    "a route edge follows the renamed caller, so the walked call is still on the tour")
  eq(saved.symbols["shop.order.Order#total()"] ~= nil, true, "route endpoints are remembered with fingerprints")
  local missing = vim.deepcopy(saved)
  missing.entries[#missing.entries + 1] = "java:shop.order.Missing#missing()"
  local partial = assert(require("code-tour.ast.live").new({ root = relocated_root, recipe = missing, cache_dir = t.cache }))
  check(vim.tbl_contains(partial.tour.warnings, "symbol missing: java:shop.order.Missing#missing()"), "missing history entry is reported")
  eq(partial.recipe.entries, missing.entries, "history keeps missing symbols for another branch")

  -- Old notes for positions that no longer exist at HEAD are pruned. Preserve the
  -- note reachable by address on HEAD even if it was read long ago.
  local r = recovered.snippets.n1.regions[1]
  local current = recovered.snippets.n1
  local obsolete = current.symbol .. "/body/stmts[99]"
  recovered.store:put(obsolete, { file = current.file, symbol = current.symbol,
    detail = "normal", fingerprint = current._fps[r.address], gist = "Moved region." })
  eq(gist(recovered, "n1", 1).gist, "Moved region.", "same-symbol region evidence can move to a new address")
  local unavailable = store.new(t.index(relocated_root, { languages = {} }), { store_ttl_days = -1 })
  eq(unavailable:prune().removed, 0, "prune keeps notes when their backend is disabled")
  local prune = store.new(t.index(relocated_root), { store_ttl_days = -1 })
  check(prune:prune().removed >= 1, "prune removes expired addresses missing from HEAD")
  check(vim.tbl_contains(vim.tbl_map(function(note) return note.region end, prune:all()), initial_entry.symbol),
    "prune retains an old note whose address resolves at HEAD")
  local unborn_root = vim.fn.tempname() .. "-unborn"
  vim.fn.mkdir(unborn_root, "p")
  t.run({ "git", "init", "-q" }, unborn_root)
  vim.fn.writefile({ "class Unborn {}" }, unborn_root .. "/Unborn.java")
  local unborn = store.new(t.index(unborn_root), { store_ttl_days = -1 })
  unborn:put("java:Former", { file = "Unborn.java", detail = "normal", fingerprint = "old", gist = "Older note." })
  eq(unborn:prune().removed, 0, "prune keeps notes when HEAD is absent")

  -- Two editor processes repeatedly fill different regions in the same note file.
  local worker = vim.fn.tempname() .. "-store-worker.lua"
  vim.fn.writefile({
    "local plugin, root, cache, gate, box = unpack(arg)",
    "vim.opt.rtp:prepend(plugin)",
    'vim.opt.rtp:append(vim.env.CODE_TOUR_PARSER_RUNTIME or vim.fn.expand("~/.local/share/nvim/site"))',
    'local ops = {}',
    'for _, e in ipairs(vim.json.decode(table.concat(vim.fn.readfile(plugin .. "/tests/fixtures/routes/checkout.json"), "\\n"))) do',
    '  ops[#ops + 1] = { kind = "route", from = e.from, to = e.to, level = e.level }',
    'end',
    'local tour = assert(require("code-tour.ast.live").new({ root = root, entries = {"OrderService#checkout"}, overrides = ops, cache_dir = cache }))',
    'assert(vim.wait(3000, function() return vim.uv.fs_stat(gate) end, 10), "worker gate never opened")',
    'for i = 1, 8 do tour:fill("n1", { [box] = "Concurrent " .. box .. " " .. i }) end',
  }, worker)
  local concurrent_root = t.project()
  local gate = vim.fn.tempname() .. "-store-gate"
  local function writer(box)
    return vim.system({ vim.v.progpath, "--clean", "--headless", "-l", worker, t.plugin, concurrent_root,
      t.cache, gate, box }, { text = true })
  end
  local one, two = writer("r1"), writer("r2")
  vim.fn.writefile({}, gate)
  for _, job in ipairs({ one, two }) do
    local result = job:wait(5000)
    eq(result.code, 0, "concurrent worker completed: " .. (result.stderr or ""))
  end
  local exclude_entries = vim.fn.readfile(concurrent_root .. "/.git/info/exclude")
  eq(#vim.tbl_filter(function(line) return line == ".code-tour/" end, exclude_entries), 1,
    "concurrent first writes add one local exclusion")
  local combined = live(concurrent_root)
  eq(gist(combined, "n1", 1).gist, "Concurrent r1 8", "first writer's fill survives")
  eq(gist(combined, "n1", 2).gist, "Concurrent r2 8", "second writer's fill survives")
end)
