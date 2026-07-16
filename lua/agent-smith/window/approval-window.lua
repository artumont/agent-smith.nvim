--- agent-smith/window/approval-window.lua
---
--- Review and approve one proposed file change. Nothing is written until the
--- user explicitly accepts it.

local Window = require("agent-smith.window")

local M = {}

--- Show a file change proposal for review.
---@param change table { path: string, content: string, snapshot?: string }
---@param cb function Callback: "approve" | "reject" | "reject_all"
function M.approve(change, cb)
  local action = change.snapshot and "Replace existing file" or "Create new file"
  local lines = {
    "Review proposed file change",
    "This change has NOT been applied.",
    "",
    "Action: " .. action,
    "Target: " .. change.path,
    "",
    "<CR> apply this change    q / Esc skip    Q skip all remaining",
    "────────────────── Proposed complete file content ──────────────────",
    "",
  }
  vim.list_extend(lines, vim.split(change.content, "\n", { plain = true }))

  local win, buf = Window.create(" Agent-Smith Change Proposal ", lines, { enter = true })
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.wo[win].cursorline = true

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
