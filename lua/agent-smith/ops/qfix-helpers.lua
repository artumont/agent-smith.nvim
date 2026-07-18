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
---@param cwd? string Base directory for relative result paths
---@return table[] items Array of quickfix entries
function M.parse(text, cwd)
  local items = {}

  for line in text:gmatch("[^\r\n]+") do
    local candidate = vim.trim(line):gsub("^[-*]%s+", "")
    candidate = candidate:gsub("^`", ""):gsub("`$", "")
    local file, lnum, col, count, note = candidate:match(
      "^(.-):(%d+):(%d+),(%d+),(.+)$"
    )

    if file then
      if cwd and vim.fn.isabsolutepath(file) ~= 1 then
        file = vim.fs.joinpath(cwd, file)
      end
      -- Quickfix accepts paths that do not exist yet. Keep those results so a
      -- valid provider response is never reported as "without locations".
      -- This matters for proposed new files returned by agentic workflows.
      local missing = vim.fn.filereadable(file) ~= 1
      table.insert(items, {
        filename = file,
        lnum = tonumber(lnum),
        col = tonumber(col),
        end_lnum = tonumber(lnum) + tonumber(count) - 1,
        text = (missing and "[missing file] " or "") .. note,
      })
    end
  end

  return items
end

return M
