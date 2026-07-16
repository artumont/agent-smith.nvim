--- agent-smith/ops/throbber.lua
---
--- ASCII spinner animation for status indicators.
---
--- Uses braille characters for a smooth animation effect.

local M = {}
M.__index = M

--- Create a new throbber.
---@return table throbber
function M.new()
  return setmetatable({
    frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    index = 1,
  }, M)
end

--- Get the next frame in the animation.
---@return string frame The next spinner character
function M:next()
  local frame = self.frames[self.index]
  self.index = self.index % #self.frames + 1
  return frame
end

return M
