--- agent-smith/ops/marks.lua
---
--- Mark management for tracking visual selection boundaries.
---
--- How it works:
--- 1. After leaving visual mode, we set marks above and below the selection
--- 2. These marks track the selection boundaries during the AI request
--- 3. On response, we use the marks to find where to insert the replacement
---
--- Mark naming:
--- We use uppercase letter marks (A-Z) to avoid conflicts with
--- user-defined marks.

local M = {}

--- Mark object with validity checking.
local Mark = {}
Mark.__index = Mark

--- Check if the mark is still valid.
---
--- A mark becomes invalid if:
--- - The buffer is no longer valid (:bdelete)
--- - The line was deleted
---@return boolean
function Mark:is_valid()
  if not vim.api.nvim_buf_is_valid(self.buffer) then
    return false
  end
  local pos = vim.api.nvim_buf_get_mark(self.buffer, self.name)
  return pos[1] > 0
end

--- Delete the mark from the buffer.
function Mark:delete()
  if vim.api.nvim_buf_is_valid(self.buffer) then
    vim.api.nvim_buf_del_mark(self.buffer, self.name)
  end
end

--- Get the mark's position as a Point.
---@return table point Point with buffer, line, col
function Mark:point()
  local geo = require("agent-smith.geo")
  local pos = vim.api.nvim_buf_get_mark(self.buffer, self.name)
  return geo.Point.new(self.buffer, pos[1], pos[2])
end

--- Set a mark at a point and return a Mark object.
---
---@param buffer number Buffer handle
---@param point table Point with line, col
---@return table mark Mark object
function M.mark_point(buffer, point)
  local name = string.char(math.random(65, 90)) -- A-Z
  vim.api.nvim_buf_set_mark(buffer, name, point.line, point.col, {})
  return setmetatable({ buffer = buffer, name = name }, Mark)
end

return M
