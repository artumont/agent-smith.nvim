--- agent-smith/ops/qfix-helpers.lua
---
--- Parse AI responses into quickfix list entries.
---
--- Expected format:
--- The AI outputs lines like:
---   /path/to/file.lua:24:8,3,Some notes about this location
---   /path/to/other.js:13:2,1,Another note
---
--- Fields:
--- - filename: absolute path to file
--- - lnum: line number (1-based)
--- - col: column number (1-based)
--- - count: number of lines to highlight
--- - text: brief note (no newlines allowed)
---
--- Validation:
--- - File must exist (vim.fn.filereadable check)
--- - All fields must parse correctly
--- - Malformed lines are silently skipped

local M = {}

--- Parse response text into quickfix entries.
---
---@param text string The raw AI response
---@return table[] items Array of quickfix entries
function M.parse(text)
  local items = {}

  for line in text:gmatch("[^\r\n]+") do
    local file, lnum, col, count, note = line:match(
      "^(.-):(%d+):(%d+),(%d+),(.+)$"
    )

    if file and vim.fn.filereadable(file) == 1 then
      table.insert(items, {
        filename = file,
        lnum = tonumber(lnum),
        col = tonumber(col),
        end_lnum = tonumber(lnum) + tonumber(count) - 1,
        text = note,
      })
    end
  end

  return items
end

return M
