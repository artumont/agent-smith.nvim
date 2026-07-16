--- agent-smith/ui.lua
---
--- Shared optional UI accent state and highlight groups.

local M = { accent_enabled = false }

local gradient = {
  "#5c6366", "#65766a", "#6f896f", "#789c74", "#82af79",
  "#8cc37e", "#96d683", "#a0ea88", "#7bdb6d", "#00ff41",
}

local quotes = {
  "There is no spoon.",
  "Follow the white rabbit.",
  "Free your mind.",
  "What is real?",
  "The choice is yours.",
}

local footer_namespace = vim.api.nvim_create_namespace("agent-smith.matrix-footer")

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

---@return string
function M.random_quote()
  return quotes[math.random(#quotes)]
end

--- Add a right-aligned quote on a padded final row of a floating review buffer.
---@param buf integer
---@param height integer Floating window content height
---@param quote string
function M.add_quote_footer(buf, height, quote)
  if not M.enabled() then return end
  local line_count = vim.api.nvim_buf_line_count(buf)
  local footer_row = math.max(line_count, height) - 1
  if line_count <= footer_row then
    local padding = {}
    for _ = line_count, footer_row do table.insert(padding, "") end
    vim.api.nvim_buf_set_lines(buf, line_count, -1, false, padding)
  end
  vim.api.nvim_buf_clear_namespace(buf, footer_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, footer_namespace, footer_row, 0, {
    virt_text = { { "  " .. quote .. "  ", "AgentSmithMatrixDim" } },
    virt_text_pos = "right_align",
  })
end

return M
