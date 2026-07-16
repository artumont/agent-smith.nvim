--- agent-smith/statusline.lua
---
--- Lightweight lualine-compatible status component for active requests.

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local active = {}
local frame = 1
local ticking = false
local matrix_mode = false

local M = {}

local function redraw()
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
  end)
end

local function tick()
  if next(active) == nil then
    ticking = false
    redraw()
    return
  end

  frame = frame % #frames + 1
  redraw()
  vim.defer_fn(tick, 120)
end

--- Begin displaying status for a request.
---@param context table Prompt object with xid
---@param label string Text displayed after spinner
function M.start(context, label)
  active[context.xid] = label
  if not ticking then
    ticking = true
    tick()
  end
  redraw()
end

--- Stop displaying status for a request.
---@param context table Prompt object with xid
function M.stop(context)
  active[context.xid] = nil
  redraw()
end

--- Return status text for a lualine component.
---@return string
function M.component()
  local _, label = next(active)
  if not label then return "" end
  local text = string.format("%s %s", frames[frame], label)
  return matrix_mode and "%#AgentSmithMatrix#" .. text .. "%*" or text
end

--- Enable or disable the optional statusline accent.
---@param enabled boolean
function M.set_matrix_mode(enabled)
  matrix_mode = enabled
  if enabled then
    vim.api.nvim_set_hl(0, "AgentSmithMatrix", { fg = "#00ff41", bold = true })
  end
end

--- Return whether any Agent-Smith request has a statusline indicator.
---@return boolean
function M.is_active()
  return next(active) ~= nil
end

return M
