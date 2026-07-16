--- agent-smith/geo.lua
---
--- Geometry primitives for buffer positions and ranges.
---
--- Three core types:
--- - Point: A single position (line, column, buffer)
--- - Range: A bounded region (start Point -> end Point)
--- - Mark: A tracked Neovim mark with validity checking
---
--- Usage pattern:
--- 1. Visual selection -> Range.from_visual_selection() captures marks
--- 2. Store marks in Prompt object for later reference
--- 3. On AI response -> range:replace_text(lines) applies changes
---
--- Column encoding:
--- Neovim columns are 0-based for API calls but 1-based for display.
--- This module uses 0-based internally (matching nvim_buf_get_text
--- and nvim_buf_set_text APIs).
---
--- Potential pitfalls:
--- - Mark validity window: Visual selection marks ('< and '>) are only
---   valid immediately after leaving visual mode. The plugin captures
---   them in Prompt.new() which is called right after the user presses
---   Esc from visual mode. If you delay the capture, the marks may
---   point to wrong positions.
--- - Buffer modification during request: If the buffer is modified while
---   a request is in flight, the marks may become invalid or point to
---   different text. The plugin doesn't guard against this - it's the
---   user's responsibility to not modify the selection during a request.
--- - Cross-buffer operations: Range:replace_text() assumes the buffer
---   is still valid. If the buffer is unloaded (e.g., :bdelete), the
---   call will fail.

local M = {}

--- A single position in a buffer.
local Point = {}
Point.__index = Point

--- Create a new Point.
---
---@param buffer number Buffer handle
---@param line number 1-based line number
---@param col number 0-based column number
---@return table point
function Point.new(buffer, line, col)
  return setmetatable({ buffer = buffer, line = line, col = col }, Point)
end

--- Create a Point from the current cursor position.
---@return table point
function Point.from_cursor()
  local pos = vim.api.nvim_win_get_cursor(0)
  return Point.new(vim.api.nvim_get_current_buf(), pos[1], pos[2])
end

--- A bounded region in a buffer, defined by start and end Points.
local Range = {}
Range.__index = Range

--- Create a new Range.
---
---@param buffer number Buffer handle
---@param start_ table Start Point
---@param end_ table End Point
---@return table range
function Range.new(buffer, start_, end_)
  -- Visual marks can be returned in cursor direction. Normalize them into
  -- buffer order because nvim_buf_get_text/set_text require start <= end.
  if start_.line > end_.line or (start_.line == end_.line and start_.col > end_.col) then
    start_, end_ = end_, start_
  end
  return setmetatable({ buffer = buffer, start = start_, end_ = end_ }, Range)
end

--- Capture the current visual selection as a Range.
---
--- MUST be called immediately after leaving visual mode (before any
--- other buffer operations). Uses '< and '> marks which are
--- only valid at that moment.
---
---@return table range
function Range.from_visual_selection()
  local buf = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  return Range.new(
    buf,
    Point.new(buf, start_pos[2], start_pos[3] - 1), -- 1-based to 0-based
    Point.new(buf, end_pos[2], end_pos[3] - 1)
  )
end

--- Create a Range from two mark objects.
---
---@param top_mark table Top mark
---@param bottom_mark table Bottom mark
---@return table range
function Range.from_marks(top_mark, bottom_mark)
  local top = top_mark:point()
  local bottom = bottom_mark:point()
  return Range.new(top.buffer, top, bottom)
end

--- Get a string representation of the range (for prompts).
---@return string e.g., "10:5-15:20"
function Range:to_string()
  return string.format(
    "%d:%d-%d:%d",
    self.start.line, self.start.col,
    self.end_.line, self.end_.col
  )
end

--- Get the text content of the range.
---@return string The text between start and end
function Range:to_text()
  local lines = vim.api.nvim_buf_get_text(
    self.buffer,
    self.start.line - 1, self.start.col,
    self.end_.line - 1, self.end_.col + 1,
    {}
  )
  return table.concat(lines, "\n")
end

--- Replace the range's text with new lines.
---
--- This is the core operation that applies AI responses to the buffer.
--- The replacement happens in-place using nvim_buf_set_text.
---
---@param lines string[] New lines to insert
function Range:replace_text(lines)
  vim.api.nvim_buf_set_text(
    self.buffer,
    self.start.line - 1, self.start.col,
    self.end_.line - 1, self.end_.col + 1,
    lines
  )
end

M.Point = Point
M.Range = Range

return M
