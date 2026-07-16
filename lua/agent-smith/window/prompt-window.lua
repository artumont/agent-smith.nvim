--- agent-smith/window/prompt-window.lua
---
--- Floating window for capturing user prompt input.
---
--- Behavior:
--- - Opens a centered floating window
--- - User types instructions
--- - Press :w (write) to submit
--- - Press q to cancel
--- - On submit: BufWriteCmd fires, text is captured, callback called
--- - On cancel: WinClosed fires, callback called with empty string
---
--- Buffer settings:
--- - buftype = "acwrite": Enables :w to trigger BufWriteCmd
--- - bufhidden = "wipe": Buffer is deleted when window closes
--- - swapfile = false: No swap file for prompt buffers
---
--- Integration with completions:
--- When the prompt window opens, it calls setup_buffer() on the
--- extensions module. This initializes buffer-local completion
--- sources for #rule and @file autocomplete.
---
--- Keymaps:
--- Default keymaps in prompt buffer:
--- - :w -> submit (triggers BufWriteCmd)
--- - q -> cancel (closes window, calls callback with "")

local Window = require("agent-smith.window")

local M = {}

--- Open a prompt capture window.
---
---@param title string Window title (e.g., "Visual", "Search")
---@param opts table Options:
---   - cb: function(ok: boolean, text: string) Callback
---   - content?: string[] Initial buffer content
---@return nil
function M.capture(title, opts)
  local win, buf = Window.create(
    " Agent-Smith " .. title .. " ",
    opts.content or { "" },
    { enter = true }
  )

  -- Configure buffer for prompt input
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false

  -- Initialize completion extensions for this buffer
  local state = require("agent-smith").__get_state()
  if state then
    require("agent-smith.extensions").setup_buffer(state)
  end

  -- Cancel on q
  vim.keymap.set("n", "q", function()
    Window.close(win)
    opts.cb(false, "")
  end, { buffer = buf })

  -- Submit on :w (BufWriteCmd)
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local text = table.concat(lines, "\n")
      Window.close(win)
      opts.cb(true, text)
    end,
  })

  -- Call on_load if provided (for setting up completion, etc.)
  if opts.on_load then
    opts.on_load(buf)
  end
end

return M
