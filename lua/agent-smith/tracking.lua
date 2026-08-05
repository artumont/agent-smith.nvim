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
    active = {},    -- Provider-running requests (keyed by xid)
    queued = {},    -- Requests waiting for a per-buffer queue slot
  }, M)
end

--- Track a request waiting for execution.
---@param prompt table Prompt object with xid field
function M:queue(prompt)
  self.queued[prompt.xid] = prompt
end

--- Start tracking a provider-running request.
---@param prompt table Prompt object with xid field
function M:track(prompt)
  self.queued[prompt.xid] = nil
  self.active[prompt.xid] = prompt
end

--- Mark a request as completed (move from active or queue to history).
---@param prompt table Prompt object with xid field
function M:complete(prompt)
  self.queued[prompt.xid] = nil
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
  local requests = self:pending()
  for _, prompt in ipairs(requests) do prompt:cancel() end
end

--- Return queued and active requests in creation order.
---@return table[] requests
function M:pending()
  local requests = {}
  for _, prompt in pairs(self.queued) do table.insert(requests, prompt) end
  for _, prompt in pairs(self.active) do table.insert(requests, prompt) end
  table.sort(requests, function(a, b) return a.started_at < b.started_at end)
  return requests
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
