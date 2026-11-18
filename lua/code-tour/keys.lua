-- Configurable key mappings. `keys` in setup() maps action -> lhs; set an action to
-- false to leave it unmapped, or `keys = false` to define no mappings at all.
local M = {}

M.defaults = {
  toggle = "<leader>ah",
  next = "<leader>aj",
  prev = "<leader>ak",
  next_snippet = "<leader>an",
  prev_snippet = "<leader>ap",
  list = "<leader>al",
  ask = "<leader>ar",
  explain = "<leader>ae",
  explain_context = "<leader>aE",
  inspect = "<leader>ad",
  back = "<leader>ao",
  text_view = "<leader>af",
  stop = "<leader>aq",
  recenter = "<leader>az",
  zoom_out = "<leader>a-",
  zoom_in = "<leader>a+",
  page_next = "<leader>a]",
  page_prev = "<leader>a[",
}

-- Which actions also work on a visual selection.
M.visual = { ask = true, explain = true, explain_context = true }

local active = vim.deepcopy(M.defaults)
local installed = {}

function M.resolve(user)
  if user == false then return {} end
  local keys = vim.deepcopy(M.defaults)
  for action, lhs in pairs(user or {}) do
    assert(M.defaults[action] ~= nil, "Unknown code-tour key action: " .. tostring(action))
    assert(lhs == false or type(lhs) == "string", "code-tour key for " .. action .. " must be a string or false")
    keys[action] = lhs
  end
  return keys
end

-- The mapping for an action (nil when disabled).
function M.lhs(action)
  return active[action] or nil
end

-- Short form shown in on-screen hints: the lhs without a leading <leader>.
function M.label(action)
  local lhs = active[action]
  return lhs and (lhs:gsub("^<[Ll]eader>", "")) or nil
end

-- "aj/ak"-style label for two related actions; nil unless both are mapped.
function M.pair(first, second)
  local a, b = M.label(first), M.label(second)
  return a and b and (a .. "/" .. b) or nil
end

-- Install mappings, replacing any from an earlier setup().
function M.apply(user, actions)
  for _, map in ipairs(installed) do pcall(vim.keymap.del, map.mode, map.lhs) end
  installed = {}
  active = M.resolve(user)
  for action, lhs in pairs(active) do
    local callback = actions[action]
    if lhs and callback then
      local desc = "CodeTour " .. action:gsub("_", " ")
      vim.keymap.set("n", lhs, callback, { desc = desc })
      installed[#installed + 1] = { mode = "n", lhs = lhs }
      if M.visual[action] and actions.visual and actions.visual[action] then
        vim.keymap.set("x", lhs, actions.visual[action], { desc = desc .. " (selection)" })
        installed[#installed + 1] = { mode = "x", lhs = lhs }
      end
    end
  end
end

return M
