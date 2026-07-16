--- agent-smith/ops/request_status.lua
---
--- Per-mark status display during in-flight requests.
---
--- Shows "Implementing…" near the selection boundaries while
--- the AI is processing. Uses the status-window module.

local Status = require("agent-smith.window.status-window")

local M = {}
M.__index = M

--- Create a new status display.
---@param _ any Unused (compatibility)
---@param _ any Unused (compatibility)
---@param label string Status label text
---@return table status Status object
function M.new(_, _, label)
  return setmetatable({
    status = Status.new(label),
  }, M)
end

--- Start showing the status indicator.
function M:start()
  self.status:start()
end

--- Stop the status indicator.
function M:stop()
  self.status:stop()
end

--- Push a status update line (for streaming output).
---@param line string Status line
function M:push(line)
  self.status:push(line)
end

return M
