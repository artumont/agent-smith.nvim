--- agent-smith/window/plan-window.lua
---
--- Review the model's Vibe plan and requested editable file scope before the
--- execution phase starts inside the temporary sandbox.

local Window = require("agent-smith.window")

local M = {}
local namespace = vim.api.nvim_create_namespace("agent-smith.vibe-plan")

---@param plan table { files: string[], steps: string }
---@param cb fun(approved: boolean)
function M.review(plan, cb)
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  local lines = {
    "Hint:  <CR> approve and execute  |  q / Esc cancel",
    "",
    "Vibe execution plan",
    "Nothing has been changed. Execution will run in a temporary sandbox.",
    "",
    "Editable file scope",
  }
  if #plan.files == 0 then
    table.insert(lines, "  (analysis only; no file writes allowed)")
  else
    for _, path in ipairs(plan.files) do table.insert(lines, "  • " .. path) end
  end
  vim.list_extend(lines, {
    "",
    "Implementation steps",
    "────────────────────────────────────────────────────────────────────────",
  })
  vim.list_extend(lines, vim.split(plan.steps, "\n", { plain = true }))

  local win, buf = Window.create("", lines, {
    enter = true,
    width = math.floor(ui.width * 0.86),
    height = math.floor(ui.height * 0.72),
    border = "single",
    title = false,
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:Comment"
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 2, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "WarningMsg", 3, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 5, 0, -1)
  for row = 6, 5 + math.max(1, #plan.files) do
    vim.api.nvim_buf_add_highlight(buf, namespace, "Directory", row, 0, -1)
  end

  local completed = false
  local function finish(approved)
    if completed then return end
    completed = true
    Window.close(win)
    cb(approved)
  end
  vim.keymap.set("n", "<CR>", function() finish(true) end, {
    buffer = buf, nowait = true, desc = "Approve Vibe plan",
  })
  vim.keymap.set("n", "q", function() finish(false) end, {
    buffer = buf, nowait = true, desc = "Cancel Vibe plan",
  })
  vim.keymap.set("n", "<Esc>", function() finish(false) end, {
    buffer = buf, nowait = true, desc = "Cancel Vibe plan",
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() finish(false) end,
  })
end

return M
