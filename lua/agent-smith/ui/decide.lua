--- A floating window holding something to read, and a yes/no decision.
---
--- Used for vibe's two checkpoints. It replaces `vim.fn.confirm`, which was wrong
--- for two reasons:
---
---   - **It cannot label two options starting with the same letter.** Its
---     accelerator *is* the first letter of the label, so `&Run` and `&Reject`
---     both bound to `r` and the dialog offered no way to tell them apart. Accept
---     and deny are distinct by construction, which is why the labels changed
---     along with the surface.
---   - **It is one command-line row.** A plan and a patch are both things to read.
---     Reading them a line at a time in the message area is not reading them.
---
--- Shaped like ui/prompt.lua: a float over a scratch buffer, a footer naming the
--- keys, and a callback rather than a return value. The decision is therefore
--- asynchronous, which is why the callers pass a `decide` function.
---
--- **Denying is the default.** Escape, `q`, Ctrl-C, and closing the window all
--- deny, so dismissing without reading is not consent. Consent has to be an
--- action, not the absence of one.
---
--- The window is entered, because the body may need scrolling. That means the
--- caller's window is not current while the question is open, which is the same
--- trade the prompt already makes.

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("agent-smith-decide")

M.MAX_WIDTH = 100
M.MIN_WIDTH = 32

--- How tall the window may get before the body starts scrolling inside it.
M.MAX_HEIGHT = 24

--- The keys, and what they are called.
M.ACCEPT_KEY = "a"
M.DENY_KEY = "d"

--- Footer chunks, in the shape a border accepts. Styled like the prompt's hint so
--- the two surfaces read as the same thing.
M.HINT = {
  { (" %s "):format(M.ACCEPT_KEY), "Keyword" },
  { "accept ", "Comment" },
  { "─", "FloatBorder" },
  { (" %s "):format(M.DENY_KEY), "Keyword" },
  { "deny ", "Comment" },
}

--- The size a body of this many lines needs, clamped to the editor.
---
--- Width comes from the longest line rather than being fixed, because a diff line
--- that wraps is unreadable. Height is capped so a large patch scrolls inside the
--- window instead of growing past the screen.
---@return table { width, height }
function M.size(lines, columns, editor_lines, max_height)
  local width = M.MIN_WIDTH
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
  end
  width = math.min(width, M.MAX_WIDTH, math.max(columns - 6, M.MIN_WIDTH))

  local height = math.max(#lines, 1)
  height = math.min(height, max_height or M.MAX_HEIGHT, math.max(editor_lines - 8, 1))

  return { width = width, height = height }
end

--- Centred horizontally, and a little above centre vertically.
---@return table { row, col }
function M.geometry(columns, editor_lines, width, height)
  return {
    row = math.max(math.floor((editor_lines - height) / 2) - 1, 0),
    col = math.max(math.floor((columns - width) / 2), 0),
  }
end

--- The buffer holding a body.
---
--- Only the content: no window, so what is shown can be inspected without one.
---@param fields table { lines: string[], filetype: string|nil }
---@return integer buffer
function M.buffer(fields)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, fields.lines)

  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].modifiable = false
  -- Last, because the FileType autocommands are allowed to touch the buffer.
  vim.bo[buffer].filetype = fields.filetype or ""

  return buffer
end

--- Ask for a decision.
---
---@param fields table
---   - title: string|nil      Shown on the top border.
---   - lines: string[]        The body to read. Required.
---   - filetype: string|nil   For syntax, when the body has any.
---   - decorate: fun(buffer)|nil  Whole-line highlights, applied after the body.
---   - max_height: number|nil
---   - on_decision: fun(accepted: boolean)  Required.
---@return table handle { cancel = fun() }
function M.ask(fields)
  fields = fields or {}
  assert(type(fields.on_decision) == "function", "a decision window needs an on_decision callback")
  assert(type(fields.lines) == "table", "a decision window needs lines")

  vim.api.nvim_set_hl(0, "AgentSmithDecideFloat", { link = "NormalFloat", default = true })

  local buffer = M.buffer(fields)
  if fields.decorate then
    fields.decorate(buffer)
  end

  local size = M.size(fields.lines, vim.o.columns, vim.o.lines, fields.max_height)
  local geometry = M.geometry(vim.o.columns, vim.o.lines, size.width, size.height)

  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = geometry.row,
    col = geometry.col,
    width = size.width,
    height = size.height,
    style = "minimal",
    border = "rounded",
    title = fields.title or " agent-smith ",
    title_pos = "center",
    footer = M.HINT,
    footer_pos = "center",
    -- Opaque: the body sits over the code it is about.
    zindex = 120,
  })

  vim.api.nvim_set_option_value("winhighlight", "Normal:AgentSmithDecideFloat,NormalNC:AgentSmithDecideFloat", {
    win = window,
  })
  -- Long diff lines are more readable scrolled than wrapped.
  vim.api.nvim_set_option_value("wrap", false, { win = window })
  vim.api.nvim_set_option_value("cursorline", true, { win = window })

  local resolved = false

  local function close()
    if vim.api.nvim_win_is_valid(window) then
      pcall(vim.api.nvim_win_close, window, true)
    end
    if vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end

  --- Answer once. Every path — both keys, Escape, and the window going away —
  --- comes through here, so a decision cannot be reported twice or not at all.
  local function answer(accepted)
    if resolved then
      return
    end
    resolved = true
    close()
    vim.schedule(function()
      fields.on_decision(accepted)
    end)
  end

  local group = vim.api.nvim_create_augroup(("agent-smith-decide-%d"):format(buffer), { clear = true })

  -- Closing without answering denies: silence is not consent.
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    buffer = buffer,
    group = group,
    callback = function()
      if not resolved then
        resolved = true
        vim.schedule(function()
          fields.on_decision(false)
        end)
      end
    end,
  })

  -- Both cases, so a user holding shift is not punished for it.
  for _, key in ipairs({ M.ACCEPT_KEY, M.ACCEPT_KEY:upper() }) do
    vim.keymap.set("n", key, function()
      answer(true)
    end, { buffer = buffer, desc = "agent-smith: accept" })
  end

  for _, key in ipairs({ M.DENY_KEY, M.DENY_KEY:upper(), "q", "<Esc>", "<C-c>" }) do
    vim.keymap.set("n", key, function()
      answer(false)
    end, { buffer = buffer, desc = "agent-smith: deny" })
  end

  return {
    buffer = buffer,
    window = window,
    cancel = function()
      answer(false)
    end,
  }
end

return M
