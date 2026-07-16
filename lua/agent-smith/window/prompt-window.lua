--- agent-smith/window/prompt-window.lua
---
--- Floating prompt input.
---
--- Prompt buffers use buftype=acwrite so :write can submit text. Neovim
--- rejects :write on unnamed buffers before BufWriteCmd, so every prompt gets
--- a unique agent-smith:// buffer name. Do not remove this naming step.
---
--- Submit and cancel keys are shown in the window's bottom border.
--- :write submits. Escape closes only from Normal mode.

local Window = require("agent-smith.window")

local M = {}

--- Open a prompt input window.
---@param title string Window title
---@param opts table { cb: fun(ok: boolean, text: string), content?: string[] }
function M.capture(title, opts)
  -- Match 99's centered input box. Neovim footer text is not consistently
  -- rendered by every UI, so use a child floating window for the key legend.
  local win, buf = Window.create(
    string.format(" Agent-Smith %s ", title),
    opts.content or { "" },
    { enter = true }
  )
  local parent = vim.api.nvim_win_get_config(win)
  local legend_buf = vim.api.nvim_create_buf(false, true)
  local legend = " :w to submit   esc to close "
  vim.api.nvim_buf_set_lines(legend_buf, 0, -1, false, { legend })
  vim.bo[legend_buf].buftype = "nofile"
  vim.bo[legend_buf].bufhidden = "wipe"
  vim.bo[legend_buf].modifiable = false
  local legend_win = vim.api.nvim_open_win(legend_buf, false, {
    relative = "editor",
    row = parent.row + parent.height,
    col = parent.col + 1,
    width = parent.width - 2,
    height = 1,
    style = "minimal",
    focusable = false,
    zindex = parent.zindex + 1,
  })
  local legend_ns = vim.api.nvim_create_namespace("agent-smith.prompt.legend")
  vim.api.nvim_buf_set_extmark(legend_buf, legend_ns, 0, 1, {
    end_col = 3,
    hl_group = "WarningMsg",
  })
  vim.api.nvim_buf_set_extmark(legend_buf, legend_ns, 0, 16, {
    end_col = 19,
    hl_group = "WarningMsg",
  })
  vim.wo[win].scrolloff = 3

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

    if vim.api.nvim_win_is_valid(legend_win) then
      vim.api.nvim_win_close(legend_win, true)
    end
    Window.close(win)
    opts.cb(ok, text)
  end

  local state = require("agent-smith").__get_state()
  if state then
    require("agent-smith.extensions").setup_buffer(state)
  end

  -- Insert-mode Esc keeps normal Neovim behavior: leave Insert mode.
  -- Press Esc again from Normal mode to close without submitting.
  vim.keymap.set("n", "<Esc>", function() finish(false) end, { buffer = buf, desc = "Close prompt" })
  vim.keymap.set("n", "q", function() finish(false) end, { buffer = buf, desc = "Close prompt" })

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
