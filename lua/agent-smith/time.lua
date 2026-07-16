--- agent-smith/time.lua
---
--- High-resolution timing for request duration tracking.
---
--- Uses vim.uv.hrtime() for nanosecond precision.

local M = {}

--- Get current time in nanoseconds.
---@return number hrtime Nanosecond timestamp
function M.now()
  return vim.uv.hrtime()
end

return M
