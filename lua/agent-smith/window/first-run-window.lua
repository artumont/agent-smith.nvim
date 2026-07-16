--- agent-smith/window/first-run-window.lua
---
--- One-time, self-contained first-run choice. Uses a floating window rather
--- than vim.ui.select so completion plugins and UI backends cannot alter the
--- user's layout.

local Window = require("agent-smith.window")

local M = {}
local namespace = vim.api.nvim_create_namespace("agent-smith.first-run")

---@param cb fun(choice: "red"|"blue")
function M.open(cb)
  local lines = {
    "Choose a connection profile",
    "",
    "  [r] Red pill",
    "      Enable subtle Matrix accents in Agent-Smith status.",
    "",
    "  [b] Blue pill",
    "      Keep default Agent-Smith styling.",
    "",
    "r / b select   Esc keeps default styling",
  }
  local win, buf = Window.create(" Agent-Smith ", lines, {
    enter = true,
    width = 58,
    height = #lines,
    border = "rounded",
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:Comment"
  vim.api.nvim_set_hl(0, "AgentSmithFirstRunRed", { fg = "#ff5555", bold = true })
  vim.api.nvim_set_hl(0, "AgentSmithFirstRunBlue", { fg = "#61afef", bold = true })
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "AgentSmithFirstRunRed", 2, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "AgentSmithFirstRunBlue", 5, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 8, 0, -1)

  local finished = false
  local function finish(choice)
    if finished then return end
    finished = true
    Window.close(win)
    cb(choice)
  end

  vim.keymap.set("n", "r", function() finish("red") end, {
    buffer = buf, nowait = true, desc = "Choose red pill",
  })
  vim.keymap.set("n", "b", function() finish("blue") end, {
    buffer = buf, nowait = true, desc = "Choose blue pill",
  })
  vim.keymap.set("n", "<Esc>", function() finish("blue") end, {
    buffer = buf, nowait = true, desc = "Keep default Agent-Smith styling",
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() finish("blue") end,
  })
end

return M
