--- agent-smith/tracking.lua
---
--- Request history management.
---
--- Tracks all in-flight and completed requests for:
--- - Request history browsing (view_logs)
--- - Status info (how many requests completed)
--- - Cleanup on exit (stop_all_requests)
---
--- Thread safety:
--- Not applicable - Neovim is single-threaded. All mutations happen
--- in the main thread or via vim.schedule() callbacks.

local M = {}
M.__index = M

--- Create a new Tracking instance.
---@return table
function M.new()
  return setmetatable({
    history = {},   -- Completed requests
    active = {},    -- In-flight requests (keyed by xid)
  }, M)
end

--- Start tracking a request.
---@param prompt table Prompt object with xid field
function M:track(prompt)
  self.active[prompt.xid] = prompt
end

--- Mark a request as completed (move from active to history).
---@param prompt table Prompt object with xid field
function M:complete(prompt)
  self.active[prompt.xid] = nil
  table.insert(self.history, prompt)
end

--- Get all successful requests.
---@return table[] Array of Prompt objects
function M:successful()
  return vim.tbl_filter(function(p)
    return p.state == "success"
  end, self.history)
end

--- Get count of completed requests.
---@return number
function M:completed()
  return #self.history
end

--- Cancel all in-flight requests.
function M:stop_all_requests()
  for _, p in pairs(self.active) do
    p:cancel()
  end
end

--- Clear request history.
function M:clear_history()
  self.history = {}
end

--- Convert requests to a selectable list for display.
---@param items table[] Array of Prompt objects
---@return string[] Array of display strings
function M.to_selectable_list(items)
  return vim.tbl_map(function(p)
    return string.format("%s: %s", p.operation, p:summary())
  end, items)
end

return M
