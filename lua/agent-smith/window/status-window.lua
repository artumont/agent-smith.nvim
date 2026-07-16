--- agent-smith/window/status-window.lua
---
--- In-flight status indicator window.
---
--- Shows a brief notification while the AI is processing.
--- Currently uses vim.notify() for simplicity. Could be enhanced
--- with a floating window showing streaming output.

local M = {}
M.__index = M

--- Create a new status window.
---
---@param label string Status label (e.g., "Agent-Smith implementing")
---@return table status
function M.new(label)
  return setmetatable({
    label = label or "Working",
    timer = nil,
  }, M)
end

--- Start showing the status indicator.
function M:start()
  vim.notify(self.label .. "…", vim.log.levels.INFO)
end

--- Push a status update (currently no-op).
---@param _ string Status line (unused)
function M:push(_)
  -- Could display streaming output in a floating window
end

--- Stop the status indicator.
function M:stop()
  -- Currently a no-op; notifications fade automatically
end

return M
