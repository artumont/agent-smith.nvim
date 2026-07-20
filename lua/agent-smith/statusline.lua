--- agent-smith/statusline.lua
---
--- Lightweight lualine-compatible status component for active requests.

local UI = require("agent-smith.ui")

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local interval = 70
local active = {}
local frame = 1
local ticking = false
local has_consumer = false

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

  -- Give configured statusline components one redraw cycle to consume the
  -- activity. Without a consumer, retain visible feedback through vim.notify.
  vim.defer_fn(function()
    if active[context.xid] == label and not has_consumer then
      vim.notify("Agent-Smith: " .. label .. "…", vim.log.levels.INFO)
    end
  end, 100)
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
  has_consumer = true
  -- Prefer visual work so queued edit count remains visible when another
  -- Agent-Smith operation is also active.
  local label
  for _, active_label in pairs(active) do
    if active_label == "Implementing" then
      label = active_label
      break
    end
  end
  if not label then
    local _, first_label = next(active)
    label = first_label
  end
  if not label then return "" end

  local count = 0
  for _, active_label in pairs(active) do
    if active_label == label then count = count + 1 end
  end
  if label == "Implementing" then
    label = string.format("Implementing (%d)", count)
  end

  local text = string.format("%s %s", frames[frame], label)
  return UI.enabled() and gradient_text(text) or text
end

--- Return current optional accent color for statusline integrations.
---@return table|nil color Lualine-compatible color table
function M.color()
  has_consumer = true
  if not UI.enabled() then return nil end
  return { fg = UI.gradient_color(frame) }
end

--- Return whether any Agent-Smith request has a statusline indicator.
---@return boolean
function M.is_active()
  has_consumer = true
  return next(active) ~= nil
end

return M
