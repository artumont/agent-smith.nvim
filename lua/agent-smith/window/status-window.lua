--- agent-smith/window/status-window.lua
---
--- Inline request feedback rendered as virtual lines near selected code.
--- No notification or floating window is created.

local namespace = vim.api.nvim_create_namespace("agent-smith.request-status")
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local M = {}
M.__index = M

--- Create inline status anchored to a buffer position.
---@param label string Status label
---@param opts table { buffer: number, row: number, col?: number }
---@return table status
function M.new(label, opts)
  opts = opts or {}
  return setmetatable({
    label = label or "Working",
    buffer = opts.buffer,
    row = opts.row,
    col = opts.col or 0,
    frame = 1,
    running = false,
    extmark = nil,
  }, M)
end

function M:_render()
  if not self.running or not vim.api.nvim_buf_is_valid(self.buffer) then return end

  local line_count = vim.api.nvim_buf_line_count(self.buffer)
  local row = math.max(0, math.min(self.row, line_count - 1))
  local text = string.format("%s %s", frames[self.frame], self.label)
  self.extmark = vim.api.nvim_buf_set_extmark(self.buffer, namespace, row, self.col, {
    id = self.extmark,
    virt_lines = { { { text, "Comment" } } },
    virt_lines_above = true,
  })
  self.frame = self.frame % #frames + 1
end

function M:start()
  if not self.buffer or not self.row then return end
  self.running = true
  self:_render()

  local function tick()
    if not self.running then return end
    self:_render()
    vim.defer_fn(tick, 120)
  end
  vim.defer_fn(tick, 120)
end

---@param _ string Provider output is intentionally not shown inline.
function M:push(_) end

function M:stop()
  self.running = false
  if self.extmark and vim.api.nvim_buf_is_valid(self.buffer) then
    pcall(vim.api.nvim_buf_del_extmark, self.buffer, namespace, self.extmark)
  end
  self.extmark = nil
end

return M
