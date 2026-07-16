--- agent-smith/window/init.lua
---
--- Floating window management for the plugin.
---
--- Window types:
--- - Prompt: Centered input window for user instructions
--- - Approval: Centered window showing file changes for approval
--- - Status: Top-right indicator during in-flight requests
--- - Select: Centered list for choosing from options
--- - Error: Top error banner
--- - Full Screen: Centered message display
---
--- Window lifecycle:
--- 1. Create floating window with nvim_open_win
--- 2. Track in active_windows list
--- 3. On close (user action or programmatic): remove from list
--- 4. clear_active_popups() closes all tracked windows
---
--- Keymap legend:
--- Prompt windows show a legend at the bottom:
--- - :w = submit
--- - q = cancel
--- - etc.
---
--- Potential pitfalls:
--- - Window validity: Windows can become invalid if the user closes them
---   manually or Neovim exits. Always check vim.api.nvim_win_is_valid()
---   before operating on a window.
--- - Buffer cleanup: Windows create hidden buffers. When the window is
---   closed, the buffer should be wiped (bufhidden = "wipe"). This is
---   handled automatically by the create functions.
--- - Stale window list: If a window is closed externally (user :q), it
---   remains in active_windows until the next clear_active_popups() call.
---   This is acceptable because operations check validity before use.

local M = { active_windows = {} }

--- Get UI dimensions for window placement.
---@return number width, number height
local function get_ui_dimensions()
  local ui = vim.api.nvim_list_uis()[1]
  if not ui then return 120, 40 end
  return ui.width, ui.height
end

--- Create a centered window config.
---@param title string Window title
---@param opts table Window options
---@return table config nvim_open_win config
local function centered_config(title, opts)
  local ui_w, ui_h = get_ui_dimensions()
  local width = opts.width or math.floor(ui_w * 0.7)
  local height = opts.height or math.floor(ui_h * 0.4)
  return {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
    width = width,
    height = height,
    row = math.floor((ui_h - height) / 2),
    col = math.floor((ui_w - width) / 2),
  }
end

--- Create a floating window with content.
---
---@param title string Window title
---@param lines? string[] Initial buffer lines
---@param opts? table Options: { enter: boolean, width: number, height: number }
---@return number win Window handle
---@return number buf Buffer handle
function M.create(title, lines, opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  local win = vim.api.nvim_open_win(
    buf,
    opts.enter ~= false,
    centered_config(title, opts)
  )
  table.insert(M.active_windows, { win = win, buf = buf })
  return win, buf
end

--- Close a window safely.
---@param win? number Window handle (nil-safe)
function M.close(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

--- Close all active popup windows.
function M.clear_active_popups()
  for _, w in ipairs(M.active_windows) do
    M.close(w.win)
  end
  M.active_windows = {}
end

--- Display an error message in a top banner.
---@param text string Error message
function M.display_error(text)
  M.create(" Agent-Smith Error ", vim.split(text, "\n"), { enter = false })
end

--- Display a full-screen message (for logs, tutorials, etc.).
---@param lines string[] Message lines
---@return number win Window handle
function M.display_full_screen_message(lines)
  M.clear_active_popups()
  local _, height = get_ui_dimensions()
  return M.create(" Agent-Smith ", lines, { height = height })
end

--- Display a centered message.
---@param lines string[] Message lines
---@return number win Window handle
function M.display_centered_message(lines)
  return M.create(" Agent-Smith ", lines)
end

return M
