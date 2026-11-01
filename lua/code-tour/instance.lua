local M = {}
local path
function M.id()
  if not vim.g.code_tour_instance_id then
    vim.g.code_tour_instance_id = tostring(vim.fn.getpid()) .. ":" .. tostring(vim.uv.hrtime())
  end
  return vim.g.code_tour_instance_id
end
function M.register()
  if vim.v.servername == "" then
    vim.fn.serverstart()
  end
  local directory = vim.fn.stdpath("state") .. "/code-tour/instances"
  vim.fn.mkdir(directory, "p", 448)
  path = directory .. "/" .. vim.fn.getpid() .. ".json"
  local record = {
    editor_pid = vim.fn.getpid(),
    instance_id = M.id(),
    address = vim.v.servername,
    cwd = vim.fn.getcwd(),
    session = vim.env.HERDR_SESSION,
    pane_id = vim.env.HERDR_PANE_ID,
    tab_id = vim.env.HERDR_TAB_ID,
  }
  local temporary = path .. ".tmp"
  vim.fn.writefile({ vim.json.encode(record) }, temporary)
  assert(vim.uv.fs_rename(temporary, path))
end
function M.unregister()
  if path then
    vim.uv.fs_unlink(path)
  end
end
return M
