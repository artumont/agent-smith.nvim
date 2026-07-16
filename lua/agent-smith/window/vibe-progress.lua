--- agent-smith/window/vibe-progress.lua
---
--- Non-focusable floating Vibe activity indicator. It is only used with the
--- optional accent profile, so statusline integrations always receive plain
--- text and never raw statusline highlight sequences.

local UI = require("agent-smith.ui")

local M = {}
M.__index = M

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local namespace = vim.api.nvim_create_namespace("agent-smith.vibe-progress")

---@param label string
---@return table progress
function M.new(label)
  return setmetatable({
    label = label,
    frame = 1,
    running = false,
    win = nil,
    buf = nil,
  }, M)
end

function M:_render()
  if not self.running or not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end
  local text = string.format("%s %s", frames[self.frame], self.label)
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, { text })
  vim.bo[self.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
  for index = 1, #text do
    vim.api.nvim_buf_add_highlight(
      self.buf, namespace, UI.gradient_group(self.frame + index - 1), 0, index - 1, index
    )
  end
  self.frame = self.frame % #frames + 1
end

function M:start()
  if self.running then return end
  local ui = vim.api.nvim_list_uis()[1]
  if not ui then return end
  local width = math.max(20, #self.label + 4)
  self.buf = vim.api.nvim_create_buf(false, true)
  self.win = vim.api.nvim_open_win(self.buf, false, {
    relative = "editor",
    style = "minimal",
    focusable = false,
    border = "rounded",
    width = width,
    height = 1,
    row = 1,
    col = math.max(0, ui.width - width - 3),
    zindex = 60,
  })
  vim.bo[self.buf].bufhidden = "wipe"
  vim.bo[self.buf].modifiable = false
  vim.wo[self.win].winhighlight = "Normal:NormalFloat,FloatBorder:AgentSmithMatrixBorder"
  self.running = true
  self:_render()

  local function tick()
    if not self.running then return end
    self:_render()
    vim.defer_fn(tick, 120)
  end
  vim.defer_fn(tick, 120)
end

function M:stop()
  self.running = false
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win, self.buf = nil, nil
end

return M
