--- agent-smith/id.lua
---
--- Unique trace ID generator.
---
--- Each request gets a unique ID for logging and history tracking.
--- IDs are monotonically increasing integers starting from 1.

local id = 0

--- Generate and return a unique ID.
---@return number
return function()
  id = id + 1
  return id
end
