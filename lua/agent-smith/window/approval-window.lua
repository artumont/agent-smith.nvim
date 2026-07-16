--- agent-smith/window/approval-window.lua
---
--- Window for approving/rejecting multi-file changes.
---
--- Display:
--- Shows:
--- 1. File path (top line)
--- 2. Keymap legend
--- 3. Proposed content
---
--- Keymaps:
--- - <CR>: Approve this change (apply to file)
--- - q: Reject this change (skip)
--- - Q: Reject all remaining changes
---
--- Flow:
--- Each file change gets its own approval window. The user processes
--- them one at a time. After all changes, the multi-file module
--- reports how many were applied.

local Window = require("agent-smith.window")

local M = {}

--- Show a file change for approval.
---
---@param change table { path: string, content: string }
---@param cb function Callback: "approve" | "reject" | "reject_all"
---@return nil
function M.approve(change, cb)
  local lines = {
    change.path,
    "",
    "<CR>: approve   q: reject   Q: reject all",
    "",
    unpack(vim.split(change.content, "\n", { plain = true })),
  }

  local win, buf = Window.create(
    " Agent-Smith File Change ",
    lines,
    { enter = true }
  )

  vim.bo[buf].modifiable = false

  vim.keymap.set("n", "<CR>", function()
    Window.close(win)
    cb("approve")
  end, { buffer = buf })

  vim.keymap.set("n", "q", function()
    Window.close(win)
    cb("reject")
  end, { buffer = buf })

  vim.keymap.set("n", "Q", function()
    Window.close(win)
    cb("reject_all")
  end, { buffer = buf })
end

return M
