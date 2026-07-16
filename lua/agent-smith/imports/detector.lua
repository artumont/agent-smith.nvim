--- agent-smith/imports/detector.lua
---
--- Detect and route import statements from AI responses.
---
--- Problem:
--- When an AI modifies a function body, it may need to add imports (e.g.,
--- "local debounce = require('utils').debounce"). These imports belong at
--- the top of the file, not inside the function body being edited.
---
--- Solution:
--- Pattern-match each line in the AI response to classify it as either:
--- - An import line -> will be inserted at the file's import section
--- - A code line -> will replace the visual selection
---
--- Language support (currently):
---
--- Lua:
---   - "local X = require('...')" - Local require
---   - "require('...')" - Bare require
---
--- TypeScript/JavaScript:
---   - "import X from '...'" - Default import
---   - "import { X } from '...'" - Named import
---   - "import type { X } from '...'" - Type import
---   - "export import X from '...'" - Re-export
---   - "const X = require('...')" - CommonJS require
---
--- Python:
---   - "import X" - Direct import
---   - "from X import Y" - From import
---
--- Ruby:
---   - "require '...'" - Require
---   - "require_relative '...'" - Relative require
---   - "use X" / "include X" - Mixins
---
--- Go:
---   - "import '...'" - Import
---   - "import ( ... )" - Grouped import
---
--- Import section detection:
--- The insert() function finds where to put new imports:
--- 1. Scan from top of file
--- 2. Find the last line that matches an import pattern
--- 3. Insert new imports after that line
--- 4. If no imports exist, insert before the first non-blank, non-comment line
---
--- Edge cases:
--- - Mixed imports and code: Only lines matching import patterns are classified
--- - Comments: Lines starting with "--" (Lua) or "//" (JS) are not imports
--- - Multi-line imports: Only single-line patterns are detected. Multi-line
---   Python imports like "from foo import (bar, baz)" won't be fully detected.
---   This is acceptable because AI responses are typically single-line.
--- - Shebang lines: "#!/usr/bin/env lua" won't match any import pattern
--- - Empty lines: Never classified as imports

local M = {}

--- Check if a line is an import statement for the given file type.
---
---@param line string The line to check (will be trimmed)
---@param ft string The Neovim filetype
---@return boolean
local function is_import(line, ft)
  line = vim.trim(line)

  -- Lua imports
  if ft == "lua" then
    return line:match("^local%s+.+%s+=%s+require%s*%(")
      or line:match("^require%s*%(")
  end

  -- TypeScript/JavaScript imports
  if ft == "typescript" or ft == "javascript" or ft == "typescriptreact" or ft == "javascriptreact" then
    return line:match("^import%s")
      or line:match("^export%s+import%s")
      or line:match("^const%s+.+%s*=%s*require%s*%(")
  end

  -- Python imports
  if ft == "python" then
    return line:match("^import%s")
      or line:match("^from%s+.+%s+import%s")
  end

  -- Ruby imports
  if ft == "ruby" then
    return line:match("^require%s")
      or line:match("^require_relative%s")
      or line:match("^use%s")
      or line:match("^include%s")
  end

  -- Go imports
  if ft == "go" then
    return line:match('^import%s+"')
      or line:match("^import%s+%(")
  end

  -- Fallback: generic patterns
  return line:match("^import%s")
    or line:match("^from%s+.+%s+import%s")
    or line:match("^use%s+")
    or line:match("^require%s*%(")
end

--- Separate AI response into imports and code body.
---
--- Each line is classified as either an import or code. This allows
--- the caller to insert imports at the file's import section and
--- apply the code body to the visual selection.
---
---@param text string The raw AI response
---@param ft string The Neovim filetype
---@return string[] imports Array of import lines
---@return string[] body Array of code lines
function M.extract(text, ft)
  local imports = {}
  local body = {}

  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    if is_import(line, ft) then
      table.insert(imports, line)
    else
      table.insert(body, line)
    end
  end

  return imports, body
end

--- Insert import lines at the appropriate location in a buffer.
---
--- Finds the import section boundary and inserts new imports there.
--- The logic:
--- 1. Scan lines top to bottom
--- 2. Track the last line that is an import
--- 3. When we hit a non-import, non-blank line after seeing imports,
---    insert before that line
--- 4. If no imports exist, insert at line 1 (before everything)
---
---@param buffer number The buffer handle
---@param imports string[] Import lines to insert
---@param ft string The Neovim filetype
---@return nil
function M.insert(buffer, imports, ft)
  if #imports == 0 then return end

  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local at = 0 -- insertion point (0 = before line 1)

  for i, line in ipairs(lines) do
    if is_import(line, ft) then
      at = i
    elseif at > 0 and vim.trim(line) ~= "" then
      -- We've passed the import section, stop here
      break
    end
  end

  -- Insert after the last import (or at line 0 if no imports found)
  vim.api.nvim_buf_set_lines(buffer, at, at, false, imports)
end

return M
