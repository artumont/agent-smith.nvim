--- The floating window this plugin asks questions in and reports through.
---
--- Two surfaces use it: `ui/prompt.lua`, which asks for an instruction, and
--- `ui/monitor.lua`, which shows the event stream. Both are a centred, rounded
--- float over the editor, with a title on the top border and a hint on the bottom
--- one.
---
--- Shared rather than copied because the **hint is the point**: a key that only
--- exists in the help is a key nobody finds, so every float here has to carry its
--- own keys on its own border. Two hand-rolled floats drift into two different
--- hints, and that is how a keymap ends up discoverable in one window and not the
--- other.
---
--- Centred rather than corner-pinned. `ui/panel.lua` is the corner one, and
--- deliberately: a status panel must not cover the work, while these two are
--- being read or typed into and so are the thing in front of the user at that
--- moment.
---
--- Entered, not focusless. `ui/panel.lua` sets `focusable = false` because a
--- status display that steals the cursor is worse than none; here the opposite
--- holds, because scrolling and searching the log is what a log is for.

local M = {}

--- Editor rows and columns kept clear, so a float never touches an edge.
---
--- Not cosmetic: a float's border is drawn outside its content box, so a window
--- against the edge has its border off-screen or over the command line.
M.MARGIN = 4

--- Narrower than this is not worth showing, whatever the editor says.
M.MIN_WIDTH = 20

--- Used when a caller asks for no size in particular.
M.DEFAULT_WIDTH = 64
M.DEFAULT_HEIGHT = 4

--- The geometry a float of this size should have in an editor of this size.
---
--- Pure, so the arithmetic is testable without a window. Clamped to the editor
--- first, centred second: a float wider than its editor is an error rather than a
--- cosmetic problem, and centring before clamping would place the clamped window
--- off-centre.
---@param columns number Editor width.
---@param lines number Editor height.
---@param width number|nil Desired content width, excluding the border.
---@param height number|nil Desired content height, excluding the border.
---@return table { row, col, width, height }
function M.geometry(columns, lines, width, height)
  local content_width = math.max(math.min(width or M.DEFAULT_WIDTH, columns - M.MARGIN), M.MIN_WIDTH)
  local content_height = math.max(math.min(height or M.DEFAULT_HEIGHT, lines - M.MARGIN), 1)

  return {
    width = content_width,
    height = content_height,
    -- The border occupies a row of its own, which is why a centred float sits one
    -- row above the geometric centre: `- 1`.
    row = math.max(math.floor((lines - content_height) / 2) - 1, 0),
    col = math.max(math.floor((columns - content_width) / 2), 0),
  }
end

--- Open a float over the editor, sized, centred and entered.
---
--- Raises rather than returning nil when the window cannot open — a caller that
--- cannot show its float has nothing useful to do, and `pcall` at the call site
--- is a clearer statement of "this may fail" than a nil every caller forgets to
--- check.
---@param fields table
---   - buffer: number         Required.
---   - width: number|nil      Desired content width.
---   - height: number|nil     Desired content height.
---   - at: table|nil          Explicit rect, used verbatim: { row, col, width, height }.
---                            For a float docked inside another window rather
---                            than centred — the caller has already worked out
---                            that it fits, and centring it would be wrong.
---   - border: table|string|nil  Default "rounded". A table can draw one edge only.
---   - title: string|nil      Top border title.
---   - footer: table|string|nil  Border hint, as nvim_open_win wants it.
---@return number window
function M.open(fields)
  fields = fields or {}
  assert(type(fields.buffer) == "number", "a float needs a buffer")

  local geometry = fields.at or M.geometry(vim.o.columns, vim.o.lines, fields.width, fields.height)

  local config = {
    relative = "editor",
    width = geometry.width,
    height = geometry.height,
    row = geometry.row,
    col = geometry.col,
    style = "minimal",
    border = fields.border or "rounded",
    title = fields.title or " agent-smith ",
    title_pos = "left",
  }

  -- A footer is a pair: `footer_pos` without a `footer` is refused with
  -- "Required: 'footer' requires 'footer_pos'". Measured. So a caller with no
  -- hint gets no footer fields at all, rather than an empty one.
  if
    type(fields.footer) == "string"
    or (type(fields.footer) == "table" and #fields.footer > 0)
  then
    config.footer = fields.footer
    config.footer_pos = "center"
  end

  return vim.api.nvim_open_win(fields.buffer, true, config)
end

--- Move and resize an open float to the current editor geometry.
---
--- Called on every redraw, so a resized terminal carries the float along to the
--- new centre instead of leaving it where the centre used to be. A split does that
--- by itself; a float does not.
---
--- Title and border hint are deliberately not resent: a geometry-only
--- reconfiguration keeps them (measured), and resending them would mean this
--- function having to know what the caller put there.
---@param window number|nil
---@param width number|nil
---@param height number|nil
---@return boolean ok
function M.place(window, width, height)
  if window == nil or not vim.api.nvim_win_is_valid(window) then
    return false
  end

  local geometry = M.geometry(vim.o.columns, vim.o.lines, width, height)

  return pcall(vim.api.nvim_win_set_config, window, {
    -- `relative` is required when reconfiguring a float, even though the window
    -- already has one: without it Neovim answers "Required: 'relative' when
    -- reconfiguring floating window". ui/panel.lua learned this by having every
    -- resize silently fail.
    relative = "editor",
    width = geometry.width,
    height = geometry.height,
    row = geometry.row,
    col = geometry.col,
  })
end

return M
