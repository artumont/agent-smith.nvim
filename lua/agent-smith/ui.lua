--- agent-smith/ui.lua
---
--- Shared optional UI accent state and highlight groups.

local M = { accent_enabled = false }

local gradient = {
  "#5c6366", "#65766a", "#6f896f", "#789c74", "#82af79",
  "#8cc37e", "#96d683", "#a0ea88", "#7bdb6d", "#00ff41",
}

local function configure_highlights()
  vim.api.nvim_set_hl(0, "AgentSmithMatrixBorder", { fg = "#00b33c", bold = true })
  vim.api.nvim_set_hl(0, "AgentSmithMatrixText", { fg = "#9ae6a4" })
  vim.api.nvim_set_hl(0, "AgentSmithMatrixDim", { fg = "#65766a" })
  vim.api.nvim_set_hl(0, "AgentSmithMatrixAdd", { fg = "#00e65a" })
  vim.api.nvim_set_hl(0, "AgentSmithMatrixDelete", { fg = "#ff6b6b" })
  for index, color in ipairs(gradient) do
    vim.api.nvim_set_hl(0, "AgentSmithMatrixGradient" .. index, { fg = color, bold = true })
  end
end

---@param enabled boolean
function M.set_accent(enabled)
  M.accent_enabled = enabled
  if enabled then configure_highlights() end
end

---@return boolean
function M.enabled()
  return M.accent_enabled
end

---@param index integer
---@return string
function M.gradient_group(index)
  return "AgentSmithMatrixGradient" .. ((index - 1) % #gradient + 1)
end

---@param index integer
---@return string
function M.gradient_color(index)
  return gradient[(index - 1) % #gradient + 1]
end

return M
