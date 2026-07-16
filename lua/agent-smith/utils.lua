--- agent-smith/utils.lua
---
--- Shared utility functions.
---
--- Functions:
--- - copy: Deep copy a table (for immutable data)
--- - random_file: Generate a unique temp file path
--- - named_file: Generate a named file in temp directory
--- - read_file: Read file contents safely
--- - write_file: Write text to file safely

local M = {}

--- Deep copy a value (handles nested tables).
---
---@param value any Value to copy
---@return any copied Deep copy of the value
function M.copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for k, v in pairs(value) do
    out[k] = M.copy(v)
  end
  return out
end

--- Generate a unique temp file path.
---
---@param dir? string Directory (default: stdpath("cache")/agent-smith)
---@return string path Absolute path to temp file
function M.random_file(dir)
  dir = dir or vim.fn.stdpath("cache") .. "/agent-smith"
  vim.fn.mkdir(dir, "p")
  return string.format("%s/request-%d-%d", dir, os.time(), math.random(1, 1e9))
end

--- Generate a named file in the temp directory.
---
---@param dir? string Directory (default: stdpath("cache")/agent-smith)
---@param name string File name
---@return string path Absolute path
function M.named_tmp_file(dir, name)
  dir = dir or vim.fn.stdpath("cache") .. "/agent-smith"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. name
end

--- Read file contents safely.
---
---@param path string File path
---@return string|nil content File contents, or nil on error
function M.read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, "\n") or nil
end

--- Write text to a file safely.
---
--- Creates parent directories if they don't exist.
---
---@param path string File path
---@param text string Content to write
---@return boolean success Whether the write succeeded
function M.write_file(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  return pcall(
    vim.fn.writefile,
    vim.split(text, "\n", { plain = true }),
    path
  )
end

return M
