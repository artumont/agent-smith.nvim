--- agent-smith/window/select-window.lua
---
--- Selection list window for choosing from options.
---
--- Behavior
---
--- - Opens a centered floating window with a list
--- - User navigates with j/k
--- - Press <CR> to select
--- - Press q to cancel

local Window = require("agent-smith.window")

local M = {}

--- Open a selection list window.
---
---@param title string Window title
---@param items string[] Items to display
---@param cb function Callback with selected index (1-based) or nil
---@return nil
function M.select(title, items, cb)
  local win, buf = Window.create(
    " Agent-Smith " .. title .. " ",
    items,
    { enter = true }
  )

  vim.bo[buf].modifiable = false

  vim.keymap.set("n", "q", function()
    Window.close(win)
    cb(nil)
  end, { buffer = buf })

  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    Window.close(win)
    cb(row)
  end, { buffer = buf })
end

return M
