--- agent-smith/window/prompt-window.lua
---
--- Floating prompt input.
---
--- Prompt buffers use buftype=acwrite so :write can submit text. Neovim
--- rejects :write on unnamed buffers before BufWriteCmd, so every prompt gets
--- a unique agent-smith:// buffer name. Do not remove this naming step.
---
--- Submit keys:
--- - Insert mode: Ctrl-Enter or Ctrl-S
--- - Normal mode: Enter or :write
--- - Cancel: Escape, then q

local Window = require("agent-smith.window")

local M = {}

--- Open a prompt input window.
---@param title string Window title
---@param opts table { cb: fun(ok: boolean, text: string), content?: string[] }
function M.capture(title, opts)
  local win, buf = Window.create(
    string.format(" Agent-Smith %s | <C-Enter>: submit | <Esc>q: cancel ", title),
    opts.content or { "" },
    { enter = true }
  )

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, string.format("agent-smith://prompt/%d", buf))

  local completed = false
  local function finish(ok)
    if completed then return end
    completed = true

    local text = ""
    if ok and vim.api.nvim_buf_is_valid(buf) then
      text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end

    Window.close(win)
    opts.cb(ok, text)
  end

  local state = require("agent-smith").__get_state()
  if state then
    require("agent-smith.extensions").setup_buffer(state)
  end

  -- Reliable submit paths. :write is retained for users who prefer it.
  vim.keymap.set("n", "<CR>", function() finish(true) end, { buffer = buf, desc = "Submit prompt" })
  vim.keymap.set("i", "<C-CR>", function() finish(true) end, { buffer = buf, desc = "Submit prompt" })
  vim.keymap.set("i", "<C-s>", function() finish(true) end, { buffer = buf, desc = "Submit prompt" })
  vim.keymap.set("n", "q", function() finish(false) end, { buffer = buf, desc = "Cancel prompt" })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function() finish(true) end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() finish(false) end,
  })

  if opts.on_load then opts.on_load(buf) end
  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then vim.cmd("startinsert") end
  end)
end

return M
