--- agent-smith/statusline.lua
---
--- Lightweight lualine-compatible status component for active requests.

local UI = require("agent-smith.ui")

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local interval = 70
local active = {}
local frame = 1
local ticking = false

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
  vim.defer_fn(tick, interval)
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

local function gradient_text(text)
  local chunks = {}
  local char_count = vim.fn.strchars(text)
  for index = 0, char_count - 1 do
    table.insert(chunks, string.format(
      "%%#%s#%s",
      UI.gradient_group(frame - index),
      vim.fn.strcharpart(text, index, 1)
    ))
  end
  return table.concat(chunks) .. "%*"
end

--- Return status text for a lualine component.
---@return string
function M.component()
  local _, label = next(active)
  if not label then return "" end
  local text = string.format("%s %s", frames[frame], label)
  return UI.enabled() and gradient_text(text) or text
end

--- Return current optional accent color for statusline integrations.
---@return table|nil color Lualine-compatible color table
function M.color()
  if not UI.enabled() then return nil end
  return { fg = UI.gradient_color(frame) }
end

--- Return whether any Agent-Smith request has a statusline indicator.
---@return boolean
function M.is_active()
  return next(active) ~= nil
end

return M
