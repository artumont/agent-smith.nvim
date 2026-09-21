--- A floating status panel, pinned to a corner of the screen.
---
--- Vibe's status display. Inline draws its own status as virtual lines inside the
--- buffer it is editing, and that is right there: the selection *is* the work
--- area, so a status at the selection's edge is exactly where the eye already is.
---
--- Vibe is a different shape. It edits a clone, so there is no buffer to attach
--- to and no line that means anything, and the user is free to scroll or switch
--- files while a run is in progress. A buffer-bound status is then wrong twice
--- over: it scrolls out of sight, and a buffer switch leaves it behind in a file
--- nobody is looking at.
---
--- A float relative to the *editor* has neither problem. It belongs to the screen
--- rather than to a buffer, so it survives buffer changes, cannot scroll away, and
--- is not part of any file — nothing can be saved, undone, or read back out of it.
---
--- It must never take focus. `focusable = false` and `enter = false` keep the
--- cursor where the user put it, and `noautocmd` keeps the panel out of their
--- WinEnter and BufEnter handlers. A status display that steals your cursor is
--- worse than no status display.
---
--- The wording is not reimplemented here. `ui/progress.lua`'s `render` and
--- `describe` are pure and already tested, so both modes say the same things about
--- the same events and only the surface differs.

local Progress = require("agent-smith.ui.progress")
local Usage = require("agent-smith.usage")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("agent-smith-panel")

--- Starting width. It only ever grows within a run; see `Panel:width_for`.
M.WIDTH = 40

M.MIN_WIDTH = 22

--- Keeps the border off the screen edge, at the sides and the top.
M.MARGIN = 1

--- Rows kept clear below a bottom-corner panel, on top of M.MARGIN.
---
--- The editor's grid counts *everything*, including the command line and any
--- status line, so a float placed against the bottom edge is drawn over them
--- rather than above them. Three rows is the command line, the status line, and
--- one row of breathing room, which also keeps the panel off the last line of
--- buffer text.
---
--- Being generous costs nothing here: the panel is two rows tall and the corner is
--- not scarce, whereas a panel sitting on the message area is a panel covering the
--- messages about the very run it is reporting on.
M.BOTTOM_MARGIN = 3

M.CORNERS = {
  ["bottom-right"] = true,
  ["top-right"] = true,
  ["bottom-left"] = true,
  ["top-left"] = true,
}

M.DEFAULT_CORNER = "bottom-right"

--- Where a panel of this size sits, in a corner of an editor of this size.
---
--- Recomputed rather than stored, so resizing the terminal carries the panel along
--- to the new corner instead of leaving it stranded mid-screen where the corner
--- used to be.
---
--- The margins are not cosmetic. A float's border is drawn outside its content
--- box, so a panel placed at row 0 has its top border off-screen — and one placed
--- at the bottom is drawn over the command line unless the margin accounts for it.
---
---@param corner string One of M.CORNERS.
---@param columns number
---@param lines number
---@param width number Content width, excluding the border.
---@param height number Content height, excluding the border.
---@param bottom_margin number|nil Defaults to M.BOTTOM_MARGIN. Passed in rather
---   than read from `vim.o` here, so this stays pure and testable.
---@return table { row, col }
function M.geometry(corner, columns, lines, width, height, bottom_margin)
  local on_right = corner:match("%-right$") ~= nil
  local on_bottom = corner:match("^bottom") ~= nil

  local bottom = bottom_margin or M.BOTTOM_MARGIN

  return {
    row = math.max(on_bottom and (lines - height - bottom - 1) or M.MARGIN, 0),
    col = math.max(on_right and (columns - width - M.MARGIN - 1) or M.MARGIN, 0),
  }
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentSmithPanel", { link = "NormalFloat", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithPanelProgress", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithPanelUsage", { link = "Comment", default = true })
end

local Panel = {}
Panel.__index = Panel

--- The lines to show, from the shared pure renderer.
---@return string[]
function Panel:lines()
  -- Written as a statement rather than `self.done and nil or self.frame`, which
  -- cannot produce nil: `true and nil` is falsy and falls through to the `or`.
  -- A finished panel would otherwise keep spinning.
  local frame = nil
  if not self.done then
    frame = self.frame
  end

  return Progress.render({ frame = frame, action = self.action, summary = self.summary })
end

--- The width to draw at, which only ever grows.
---
--- Growing but never shrinking is the point: the action text changes with every
--- tool call, and a panel that resized to fit each one would twitch continuously.
--- Clamped to the editor so a long usage line cannot push it off screen.
---@return number
function Panel:width_for(lines)
  local widest = self.width
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line) + 2)
  end

  local limit = math.max(vim.o.columns - 4, M.MIN_WIDTH)
  return math.min(math.max(widest, M.MIN_WIDTH), limit)
end

--- Whether the panel currently has a window on screen.
---
--- Nil-safe on purpose. `nvim_win_is_valid(nil)` raises rather than returning
--- false — "Invalid 'win': Expected Lua number" — so every check has to confirm a
--- window was ever opened before asking whether it still is.
---@return boolean
function Panel:has_window()
  return self.window ~= nil and vim.api.nvim_win_is_valid(self.window)
end

--- Open the window, or move and resize the existing one.
---@return boolean ok
function Panel:open(width, height)
  -- `cmdheight` is part of the grid a float is positioned against, so a taller
  -- command line eats into the margin. Read here rather than inside geometry,
  -- which stays pure and testable.
  local bottom = M.BOTTOM_MARGIN + math.max((vim.o.cmdheight or 1) - 1, 0)
  local geometry = M.geometry(self.corner, vim.o.columns, vim.o.lines, width, height, bottom)

  if self:has_window() then
    -- `relative` is required when reconfiguring a float, even though the window
    -- already has one: without it Neovim answers "Required: 'relative' when
    -- reconfiguring floating window". Leaving it out made every move and resize
    -- fail, and because the call is protected the failure was invisible — the
    -- panel simply never grew and never followed a terminal resize.
    return pcall(vim.api.nvim_win_set_config, self.window, {
      relative = "editor",
      row = geometry.row,
      col = geometry.col,
      width = width,
      height = height,
    })
  end

  local opened, window = pcall(vim.api.nvim_open_win, self.buffer, false, {
    relative = "editor",
    row = geometry.row,
    col = geometry.col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = self.title,
    title_pos = "left",
    -- See the note at the top of this module: never entered, never focusable,
    -- never visible to the user's autocommands.
    focusable = false,
    noautocmd = true,
    zindex = 100,
  })
  if not opened then
    return false
  end

  self.window = window

  -- Opaque rather than see-through: the panel sits over the code it is reporting
  -- on, and a transparent background makes both unreadable at once.
  vim.api.nvim_set_option_value("winhighlight", "Normal:AgentSmithPanel,NormalNC:AgentSmithPanel", { win = window })
  vim.api.nvim_set_option_value("wrap", false, { win = window })

  return true
end

--- Draw the current state.
function Panel:draw()
  if self.closed then
    return self
  end
  if not vim.api.nvim_buf_is_valid(self.buffer) then
    return self
  end

  local lines = self:lines()
  local width = self:width_for(lines)
  local height = math.max(#lines, 1)
  self.width = width

  local current = vim.api.nvim_buf_get_lines(self.buffer, 0, -1, false)
  if not vim.deep_equal(current, lines) then
    pcall(vim.api.nvim_buf_set_lines, self.buffer, 0, -1, false, lines)

    pcall(vim.api.nvim_buf_clear_namespace, self.buffer, M.NAMESPACE, 0, -1)
    pcall(vim.api.nvim_buf_add_highlight, self.buffer, M.NAMESPACE, "AgentSmithPanelProgress", 0, 0, -1)
    if #lines > 1 then
      pcall(vim.api.nvim_buf_add_highlight, self.buffer, M.NAMESPACE, "AgentSmithPanelUsage", 1, 0, -1)
    end
  end

  self:open(width, height)
  return self
end

--- Start the spinner.
function Panel:start()
  if self.timer or self.interval <= 0 or self.closed then
    return self
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    self.interval,
    vim.schedule_wrap(function()
      self.frame = (self.frame % #Progress.FRAMES) + 1
      self:draw()
    end)
  )
  return self
end

function Panel:stop()
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
  return self
end

--- Set the current action and redraw.
function Panel:action_for(text)
  if text then
    self.action = text
    self:draw()
  end
  return self
end

--- Route one typed event into the panel.
function Panel:event(event)
  if type(event) ~= "table" then
    return self
  end

  if event.type == "tool_use" then
    self:action_for(Progress.describe(event))
  elseif event.type == "usage" then
    Usage.add(self.usage, event)
    self.summary = Usage.render(self.usage)
    self:draw()
  elseif event.type == "text_delta" and not self.action then
    self:action_for("writing the change")
  end

  return self
end

--- Stop, show the outcome, then close.
function Panel:finish(result)
  self:stop()
  self.done = true
  self.action = (result and result.ok) and "done" or "stopped"

  if result and result.summary then
    self.summary = result.summary
  elseif next(self.usage) then
    self.summary = Usage.render(self.usage)
  end

  self:draw()

  if self.linger > 0 then
    vim.defer_fn(function()
      self:clear()
    end, self.linger)
  else
    -- Unlike the inline status, which lingers as an extmark and is harmless if
    -- nobody clears it, a zero linger here closes immediately. A floating window
    -- left behind is a window the user has to close by hand.
    self:clear()
  end

  return self
end

--- Close the window and throw away the buffer.
function Panel:clear()
  self:stop()
  self.closed = true

  if self:has_window() then
    pcall(vim.api.nvim_win_close, self.window, true)
  end
  self.window = nil

  if vim.api.nvim_buf_is_valid(self.buffer) then
    pcall(vim.api.nvim_buf_delete, self.buffer, { force = true })
  end

  return self
end

--- A status panel.
---@param fields table
---   - corner: string|nil   Which corner. Default bottom-right.
---   - title: string|nil
---   - width: number|nil    Starting width; it grows from here.
---   - interval: number|nil Spinner interval, 0 to disable.
---   - linger: number|nil   How long the finished state stays, before closing.
---   - action: string|nil   What to say before anything has happened.
---@return table panel
function M.new(fields)
  fields = fields or {}
  setup_highlights()

  local corner = fields.corner or M.DEFAULT_CORNER
  if not M.CORNERS[corner] then
    error(("corner must be one of %s, got %q"):format(table.concat(vim.tbl_keys(M.CORNERS), ", "), corner), 0)
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  -- `hide`, not `wipe`. A wiping buffer is destroyed the moment its window goes
  -- away, which would leave the panel unable to come back — closing a tabpage
  -- closes its floats, and the run carries on regardless. `clear()` deletes the
  -- buffer explicitly, so nothing is left behind either way.
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false

  local panel = setmetatable({
    buffer = buffer,
    window = nil,
    corner = corner,
    title = fields.title or " agent-smith ",
    width = fields.width or M.WIDTH,
    interval = fields.interval ~= nil and fields.interval or Progress.INTERVAL_MS,
    linger = fields.linger ~= nil and fields.linger or Progress.LINGER_MS,
    frame = 1,
    usage = {},
    action = fields.action,
    summary = nil,
    timer = nil,
    done = false,
    closed = false,
  }, Panel)

  -- Drawn immediately, so the panel is on screen from the first moment of a run
  -- rather than appearing at the first timer tick.
  panel:draw()
  return panel
end

return M
