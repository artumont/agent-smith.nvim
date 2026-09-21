--- Asking for an instruction in a floating buffer.
---
--- A temp buffer rather than a command-line input: an instruction is often more
--- than one line, and a buffer brings normal editing, paste and undo with it.
--- Start in insert, `:w` to submit, `q` or `:q` to cancel — and both keys are
--- written on the bottom border, because a key that only exists in the help is a
--- key nobody finds.
---
--- The hint names the mode the user is in. The prompt opens in insert, where `q`
--- and `:w` are letters rather than commands, so while typing it says to leave
--- insert first instead of describing keys that do nothing yet.
---
--- Every part of that mechanism was measured rather than assumed:
---
---   - **`acwrite` plus a pseudo-name.** `:w` on an unnamed buffer fails with
---     `E32: No file name` *before* BufWriteCmd is reached, so a scratch buffer
---     with `buftype=nofile` cannot be saved at all. Setting `buftype=acwrite`
---     and naming the buffer `agent-smith://prompt/N` makes `:w` fire the
---     handler without touching the filesystem.
---   - **`modified` is forced back to false on every change.** `:q` on a
---     modified buffer is refused with `E37: No write since last change`, so
---     without this `:q` would not close the window — and `:q` closing it is the
---     whole reason this is a buffer.
---   - **`:w` fires even when nothing changed**, verified, so saving an empty
---     buffer is a cancel rather than a hang.
---
--- The window is a plain float. Snacks would manage it more prettily, but this
--- is one window with a border and a title, and a plugin that cannot show a
--- prompt without a third-party window library is a plugin with a dependency it
--- did not need.
---
--- Never blocks: the answer arrives through `on_submit`.

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("agent-smith-prompt")

M.WIDTH = 64
M.HEIGHT = 4

--- Written on the bottom border. Short on purpose: it is centred on a border, and
--- a footer wider than the window gets clipped.
--- Uses formatted chunk tuples ({ { "text", "HighlightGroup" }, ... }) so keys,
--- descriptions, and the box-drawing bar '─' take theme colors dynamically.
M.HINT_NORMAL = {
  { " :w ", "Keyword" },
  { "to send ", "Comment" },
  { "─", "FloatBorder" },
  { " q ", "Keyword" },
  { "to close ", "Comment" },
}

--- The border hint for a mode.
---
--- Pure, so the wording is testable without a window. `mode` is a Neovim mode
--- string from `nvim_get_mode()`, whose first character is the mode family.
---@param mode string
---@return table|string
function M.hint(mode)
  return M.HINT_NORMAL
end

local counter = 0

--- The float, sized to the editor and centred.
local function open_float(buffer, title, footer)
  local width = math.max(math.min(M.WIDTH, vim.o.columns - 4), 20)
  local height = math.max(math.min(M.HEIGHT, vim.o.lines - 4), 1)

  return vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = "minimal",
    border = "rounded",
    title = title or " agent-smith ",
    title_pos = "left",
    footer = footer,
    footer_pos = "center",
  })
end

--- Open a prompt.
---
---@param fields table { prompt: string|nil, on_submit: fun(text: string|nil) }
---@return table handle { cancel = fun() }
function M.ask(fields)
  fields = fields or {}
  assert(type(fields.on_submit) == "function", "the prompt needs an on_submit callback")

  counter = counter + 1
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, ("agent-smith://prompt/%d"):format(counter))

  vim.bo[buffer].buftype = "acwrite"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "markdown"

  -- The prompt opens in insert, so the first hint the user sees has to be the
  -- insert-mode one.
  local window = open_float(buffer, fields.prompt, M.hint("i"))

  local resolved = false

  local function close()
    if vim.api.nvim_win_is_valid(window) then
      pcall(vim.api.nvim_win_close, window, true)
    end
    if vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end

  local group =
    vim.api.nvim_create_augroup(("agent-smith-prompt-%d"):format(counter), { clear = true })

  --- Report "no answer", exactly once.
  ---
  --- The single notifier for the nil case, so that closing through the handle,
  --- typing `q`, `:q`, or wiping the buffer all answer the caller identically.
  --- Before this existed, `handle.cancel()` closed the window without calling
  --- `on_submit` at all, while `:q` did call it — the same user action reporting
  --- differently depending on which key produced it.
  local function answer_nothing()
    if resolved then
      return
    end
    resolved = true
    vim.schedule(function()
      fields.on_submit(nil)
    end)
  end

  --- Submit with the buffer's text. Empty means cancel.
  local function submit()
    if resolved then
      return
    end
    resolved = true

    local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")

    -- Written out rather than as `vim.trim(text) == "" and nil or text`:
    -- that idiom cannot produce nil, because `true and nil` is falsy and falls
    -- through to the `or`. An empty save submitted "" instead of cancelling.
    ---@type string|nil
    local answer = text
    if vim.trim(text) == "" then
      answer = nil
    end

    close()
    vim.schedule(function()
      fields.on_submit(answer)
    end)
  end

  local function cancel()
    answer_nothing()
    close()
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buffer,
    group = group,
    callback = submit,
  })

  -- `q` closes, from normal mode.
  --
  -- Normal mode only, and buffer-local. In insert mode `q` has to type the letter,
  -- and outside this buffer the mapping should not exist at all. It is reached
  -- after the Esc the user has to press anyway before `:w`, which is what makes
  -- the footer line an instruction rather than decoration.
  vim.keymap.set("n", "q", function()
    cancel()
  end, { buffer = buffer, desc = "agent-smith: close the prompt" })

  --- Re-draw the border hint for a mode.
  ---
  --- The mode is passed in rather than read from `nvim_get_mode()`, because
  --- during `InsertEnter` that call reports the transitional `"niI"` and not
  --- `"i"`. Reading it there meant the insert hint never appeared in a real
  --- session: the footer showed the normal-mode hint while the cursor was in
  --- insert, which is exactly the state the hint exists to explain. Measured with
  --- a UI attached; headless cannot show it, because insert never happens there.
  ---@param mode string
  local function update_hint(mode)
    if not vim.api.nvim_win_is_valid(window) then
      return
    end
    pcall(vim.api.nvim_win_set_config, window, {
      footer = M.hint(mode),
      footer_pos = "center",
    })
  end

  -- Keep the buffer clean so `:q` is never refused.
  --
  -- TextChanged and TextChangedI cover typing. InsertLeave is the load-bearing
  -- one: leaving insert is the last thing the user does before typing `:q`, so
  -- it guarantees the flag is clear at the moment the command runs. Measured:
  -- a buffer left modified is refused with `E37: No write since last change`,
  -- and if that happens the window does not close, which defeats the point.
  --
  -- Split by the mode each event implies, so the hint never has to be guessed
  -- from the current mode. See the note on update_hint.
  vim.api.nvim_create_autocmd({ "InsertEnter", "TextChangedI" }, {
    buffer = buffer,
    group = group,
    callback = function()
      vim.bo[buffer].modified = false
      update_hint("i")
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
    buffer = buffer,
    group = group,
    callback = function()
      vim.bo[buffer].modified = false
      update_hint("n")
    end,
  })

  -- Closing the window without saving cancels, whichever way it was closed.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buffer,
    group = group,
    callback = answer_nothing,
  })

  -- Standard practice after focusing a float, and what every prompt plugin
  -- does. It cannot be verified headlessly: there is no UI, so `startinsert`
  -- and fed keystrokes both leave the mode at `n` in a `-l` script even though
  -- the surrounding autocmds fire. Verified in a real session is still a TODO.
  vim.cmd("startinsert")
  vim.bo[buffer].modified = false

  return {
    buffer = buffer,
    window = window,
    cancel = cancel,
  }
end

return M
