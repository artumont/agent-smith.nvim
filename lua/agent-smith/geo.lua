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
function Range.new(buffer, start_, end_, visual_mode)
  -- Visual marks can be returned in cursor direction. Normalize them into
  -- buffer order because nvim_buf_get_text/set_text require start <= end.
  if start_.line > end_.line or (start_.line == end_.line and start_.col > end_.col) then
    start_, end_ = end_, start_
  end
  return setmetatable({
    buffer = buffer,
    start = start_,
    end_ = end_,
    visual_mode = visual_mode,
  }, Range)
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
    Point.new(buf, end_pos[2], end_pos[3] - 1),
    vim.fn.mode(1)
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

--- Return normalized API positions or nil for an invalid visual selection.
---
--- Marks can change after selection capture. Normalize again here instead of
--- trusting stored positions: Neovim rejects start_col > end_col with E5108.
---@return number|nil start_row
---@return number|nil start_col
---@return number|nil end_row
---@return number|nil end_col Exclusive end column
function Range:_api_positions()
  if not vim.api.nvim_buf_is_valid(self.buffer) then return nil end

  local line_count = vim.api.nvim_buf_line_count(self.buffer)
  if self.start.line < 1 or self.end_.line < 1 or line_count == 0 then return nil end

  local start_row = math.min(self.start.line, self.end_.line) - 1
  local end_row = math.max(self.start.line, self.end_.line) - 1
  if start_row >= line_count then return nil end
  end_row = math.min(end_row, line_count - 1)

  local start_col = self.start.col
  local end_col = self.end_.col
  if self.start.line > self.end_.line then
    start_col, end_col = end_col, start_col
  elseif start_row == end_row and start_col > end_col then
    start_col, end_col = end_col, start_col
  end

  -- Linewise visual selections cover complete first and last lines.
  if self.visual_mode == "V" then
    start_col = 0
    end_col = #vim.api.nvim_buf_get_lines(self.buffer, end_row, end_row + 1, false)[1] - 1
  end

  local start_line = vim.api.nvim_buf_get_lines(self.buffer, start_row, start_row + 1, false)[1]
  local end_line = vim.api.nvim_buf_get_lines(self.buffer, end_row, end_row + 1, false)[1]
  start_col = math.max(0, math.min(start_col, #start_line))
  end_col = math.max(0, math.min(end_col, #end_line - 1))

  -- `end_col` is inclusive in visual marks; Neovim APIs require exclusive.
  local end_exclusive = math.min(#end_line, end_col + 1)
  if start_row == end_row and start_col > end_exclusive then return nil end

  return start_row, start_col, end_row, end_exclusive
end

--- Get the text content of the range.
---@return string The text between start and end, or empty when marks are invalid
function Range:to_text()
  local start_row, start_col, end_row, end_col = self:_api_positions()
  if not start_row then return "" end
  local lines = vim.api.nvim_buf_get_text(
    self.buffer,
    start_row, start_col,
    end_row, end_col,
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
---@return boolean changed False when the range is no longer valid
function Range:replace_text(lines)
  local start_row, start_col, end_row, end_col = self:_api_positions()
  if not start_row then return false end
  vim.api.nvim_buf_set_text(
    self.buffer,
    start_row, start_col,
    end_row, end_col,
    lines
  )
  return true
end

M.Point = Point
M.Range = Range

return M
