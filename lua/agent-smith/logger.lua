--- agent-smith/logger.lua
---
--- Structured logging for debugging and request tracing.
---
--- Log levels:
--- - DEBUG: Detailed diagnostic information
--- - INFO: General operational messages
--- - WARN: Warning messages (unexpected but recoverable)
--- - ERROR: Error messages (request failed)
--- - FATAL: Critical errors (should never happen)
---
--- Log storage:
--- Logs are stored in memory keyed by request ID (xid).
--- Optionally written to a file if logger.path is configured.
---
--- Usage:
---   local Logger = require("agent-smith.logger")
---   local log = Logger:set_id(request_id)
---   log:debug("visual request start", "range", range)
---   log:error("request failed", "error", response)

local M = {}

--- In-memory log storage keyed by request ID.
---@type table<number, string[]>
M._logs = {}

--- Logger configuration.
---@type table
M._opts = {
  level = "warn",
  path = nil,
  max_requests_cached = 50,
}

--- Logger instance with bound request ID.
local Logger = {}
Logger.__index = Logger

--- Configure logger settings.
---
---@param opts table Options: { level: string, path?: string }
function M:configure(opts)
  self._opts = vim.tbl_extend("force", self._opts, opts or {})
end

--- Create a logger bound to a specific request ID.
---
---@param id number Request trace ID
---@return table logger Logger instance
function M:set_id(id)
  return setmetatable({ id = id, area = "core" }, Logger)
end

--- Get logs for a specific request.
---
---@param id number Request trace ID
---@return string[]|nil logs Array of log lines, or nil if not found
function M:logs_by_id(id)
  return self._logs[id]
end

--- Set the logging area/module name.
---
---@param area string Area name (e.g., "visual", "search", "provider")
---@return table self For chaining
function Logger:set_area(area)
  self.area = area
  return self
end

--- Internal: log a message at the given level.
---
---@param level string Log level ("DEBUG", "INFO", etc.)
---@param ... any Additional arguments (converted to string)
function Logger:_log(level, ...)
  local parts = {}
  for _, v in ipairs({ ... }) do
    table.insert(parts, tostring(v))
  end
  local line = string.format(
    "[%s][%s] %s",
    level,
    self.area,
    table.concat(parts, " ")
  )

  -- Store in memory
  M._logs[self.id] = M._logs[self.id] or {}
  table.insert(M._logs[self.id], line)

  -- Write to file if configured
  if M._opts.path then
    vim.fn.writefile({ line }, M._opts.path, "a")
  end

  -- Show notification for errors
  if level == "ERROR" or level == "FATAL" then
    vim.schedule(function()
      vim.notify(line, vim.log.levels.ERROR)
    end)
  end
end

-- Define log methods for each level
for _, level in ipairs({ "debug", "info", "warn", "error", "fatal" }) do
  Logger[level] = function(self, ...)
    self:_log(level:upper(), ...)
  end
end

return M
