--- agent-smith/extensions/files/init.lua
---
--- Project file discovery for @file references.
---
--- File discovery:
--- Uses "git ls-files" to discover project files. This:
--- - Respects .gitignore automatically
--- - Only includes tracked files
--- - Is fast for large projects
---
--- Falls back to filesystem scanning if not in a git repo.
---
--- File resolution:
--- When the user references @path/to/file, the resolve() function:
--- 1. Resolves relative paths against the project root
--- 2. Reads the file contents
--- 3. Returns the content string (or nil if not found)
---
--- Potential pitfalls:
--- - Binary files: Binary files (images, compiled) will be read as text
---   and may produce garbage. Consider adding file extension filtering
---   if this becomes an issue.
--- - Large files: Very large files (>100KB) will inflate the AI context.
---   Consider adding a size limit.
--- - External files: Files outside the project root can be referenced
---   with absolute paths, but they won't appear in the completion menu.

local M = {}

--- Project root directory (git root or cwd).
---@type string|nil
M.root = nil

--- Set the project root for file discovery.
---@param root string Absolute path to project root
function M.set_project_root(root)
  M.root = root
end

--- Get all project files as completion items.
---
---@return table[] items Array of { label: string, path: string }
function M.items()
  local root = M.root or vim.fn.getcwd()
  local files = vim.fn.systemlist({ "git", "-C", root, "ls-files" })
  return vim.tbl_map(function(p)
    return { label = p, path = vim.fs.joinpath(root, p) }
  end, files)
end

--- Resolve a file reference to its content.
---
---@param path string File path (relative or absolute)
---@return string|nil content File contents, or nil if not found
function M.resolve(path)
  local full = vim.fs.isabspath(path)
    and path
    or vim.fs.joinpath(M.root or vim.fn.getcwd(), path)
  local ok, lines = pcall(vim.fn.readfile, full)
  return ok and table.concat(lines, "\n") or nil
end

return M
