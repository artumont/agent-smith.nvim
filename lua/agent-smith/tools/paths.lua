--- Path handling shared by the file tools.
---
--- Tools are bound to a project root at assembly time, so they can accept the
--- relative paths a model prefers without guessing a working directory.
---
--- This module only interprets paths. Whether a path outside the root is
--- acceptable is a policy question owned by the scope: see
--- spec/open-questions.md Q9.

local M = {}

--- Resolve a model-supplied path against the project root.
---
--- Relative paths resolve against the root. Absolute paths are taken as given,
--- deliberately: rejecting them here would silently decide the open question of
--- whether reads may leave the project.
---@param root string
---@param path string
---@return string absolute
function M.resolve(root, path)
  if path:sub(1, 1) == "/" then
    return vim.fs.normalize(path)
  end
  return vim.fs.normalize(vim.fs.joinpath(root, path))
end

--- Whether `path` is inside `root`.
---@return boolean
function M.inside(root, path)
  local normal_root = vim.fs.normalize(root)
  local normal_path = vim.fs.normalize(path)
  return normal_path == normal_root or vim.startswith(normal_path, normal_root .. "/")
end

--- The path as shown to the model.
---
--- Relative to the root where possible: shorter, and it avoids putting absolute
--- paths from the user's machine into a prompt that goes to a vendor.
---@return string
function M.display(root, path)
  local normal_root = vim.fs.normalize(root)
  local normal_path = vim.fs.normalize(path)
  if vim.startswith(normal_path, normal_root .. "/") then
    return normal_path:sub(#normal_root + 2)
  end
  return normal_path
end

return M
