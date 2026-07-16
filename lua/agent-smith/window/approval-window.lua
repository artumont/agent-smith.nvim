--- agent-smith/window/approval-window.lua
---
--- Neogit-inspired review panel for one proposed file change. Nothing is
--- written until the user explicitly accepts the proposal.

local Window = require("agent-smith.window")

local M = {}
local namespace = vim.api.nvim_create_namespace("agent-smith.change-proposal")

local function ui_size()
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  return math.floor(ui.width * 0.9), math.floor(ui.height * 0.78)
end

local function highlight_literal(buf, row, line, literal, group)
  local start_col = line:find(literal, 1, true)
  if start_col then
    vim.api.nvim_buf_add_highlight(buf, namespace, group, row, start_col - 1, start_col - 1 + #literal)
  end
end

--- Show a file change proposal for review.
---@param change table { path: string, content: string, snapshot?: string }
---@param cb function Callback: "approve" | "reject" | "reject_all"
function M.approve(change, cb)
  local is_new = change.snapshot == nil
  local action = is_new and "Create new file" or "Replace existing file"
  local hint = "Hint:  <CR> apply  |  q skip  |  Q skip all remaining  |  Esc close"
  local target = action .. ": " .. change.path
  local lines = {
    hint,
    "",
    target,
    "",
    "Proposed content",
    "────────────────────────────────────────────────────────────────────────",
    "",
  }
  vim.list_extend(lines, vim.split(change.content, "\n", { plain = true }))

  local width, height = ui_size()
  local win, buf = Window.create("", lines, {
    enter = true,
    width = width,
    height = height,
    border = "single",
    title = false,
  })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].bufhidden = "wipe"
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:Comment"

  -- Neogit-like metadata and action colors. Keep proposal content readable.
  highlight_literal(buf, 0, hint, "Hint:", "Comment")
  for _, key in ipairs({ "<CR>", "q", "Q", "Esc" }) do
    highlight_literal(buf, 0, hint, key, "Special")
  end
  highlight_literal(buf, 2, target, action, is_new and "String" or "WarningMsg")
  highlight_literal(buf, 2, target, change.path, "Directory")
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 4, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 5, 0, -1)
  if is_new then
    for row = 7, #lines - 1 do
      vim.api.nvim_buf_add_highlight(buf, namespace, "DiffAdd", row, 0, -1)
    end
  end

  -- Put focus on content instead of the action hint.
  vim.api.nvim_win_set_cursor(win, { math.min(8, #lines), 0 })

  vim.keymap.set("n", "<CR>", function()
    Window.close(win)
    cb("approve")
  end, { buffer = buf, nowait = true, desc = "Apply proposed change" })

  local function reject()
    Window.close(win)
    cb("reject")
  end
  vim.keymap.set("n", "q", reject, { buffer = buf, nowait = true, desc = "Skip proposed change" })
  vim.keymap.set("n", "<Esc>", reject, { buffer = buf, nowait = true, desc = "Skip proposed change" })

  vim.keymap.set("n", "Q", function()
    Window.close(win)
    cb("reject_all")
  end, { buffer = buf, nowait = true, desc = "Skip all remaining changes" })
end

return M
