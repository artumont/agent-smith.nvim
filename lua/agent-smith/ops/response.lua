--- agent-smith/ops/response.lua
---
--- Defensive normalization for provider output.
---
--- Providers occasionally wrap valid code in Markdown fences despite the
--- visual prompt requiring code only. Fences must never be inserted into the
--- user's buffer. This module extracts the first fenced block when present.

local M = {}

--- Return code inside the first fenced Markdown block, or original text.
---
--- Handles common forms:
---   ```lua
---   local value = 1
---   ```
---
---   Here is the result:
---   ```
---   local value = 1
---   ```
---
--- Non-fenced code is returned unchanged. Only an opening fence followed by a
--- closing fence is unwrapped, preventing accidental removal of literal fences
--- from a legitimate code response.
---@param text string Raw provider response
---@return string code Response with outer Markdown fence removed
function M.unwrap_code_fence(text)
  local opening_start, opening_end = text:find("```[^\r\n]*[\r\n]")
  if not opening_start then return text end

  local closing_start = text:find("[\r\n]```%s*$", opening_end + 1)
  if not closing_start then return text end

  return text:sub(opening_end + 1, closing_start - 1)
end

return M
