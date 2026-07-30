--- agent-smith/ops/response.lua
---
--- Defensive normalization for provider output.
---
--- Providers occasionally wrap valid code in Markdown fences despite the
--- visual prompt requiring code only. Fences must never be inserted into the
--- user's buffer. This module extracts the first fenced block when present.

local M = {}

local language_tags = {
  bash = true,
  c = true,
  cpp = true,
  css = true,
  go = true,
  html = true,
  java = true,
  javascript = true,
  js = true,
  json = true,
  jsx = true,
  kotlin = true,
  lua = true,
  markdown = true,
  md = true,
  php = true,
  python = true,
  py = true,
  ruby = true,
  rust = true,
  sh = true,
  shell = true,
  sql = true,
  swift = true,
  ts = true,
  tsx = true,
  typescript = true,
  vim = true,
  yaml = true,
  yml = true,
  zsh = true,
}

--- Normalize a visual replacement without allowing Markdown fences into source.
---
--- Supports multiline and inline fences, including ` ```python code``` `.
--- Explanatory text before a fenced block is ignored; trailing text, unmatched
--- fences, and empty fenced replacements are rejected instead of inserted.
---@param text string Raw provider response
---@return string|nil code Normalized replacement
---@return string|nil error Human-readable validation error
function M.normalize_replacement(text)
  if vim.trim(text) == "" then return nil, "empty response" end

  -- A Markdown fence must begin a line. This avoids treating literal backtick
  -- strings inside source code as response wrappers.
  local opening_start, opening_end
  local cursor = 1
  while true do
    local candidate_start, candidate_end = text:find("```+", cursor)
    if not candidate_start then return text, nil end
    local before = text:sub(1, candidate_start - 1)
    local line_start = before:match(".*\n()") or 1
    if text:sub(line_start, candidate_start - 1):match("^%s*$") then
      opening_start, opening_end = candidate_start, candidate_end
      break
    end
    cursor = candidate_end + 1
  end

  local fence_length = opening_end - opening_start + 1
  local closing_start, closing_end
  cursor = opening_end + 1
  while true do
    local candidate_start, candidate_end = text:find("```+", cursor)
    if not candidate_start then return nil, "unmatched Markdown code fence" end
    if candidate_end - candidate_start + 1 >= fence_length then
      closing_start, closing_end = candidate_start, candidate_end
      break
    end
    cursor = candidate_end + 1
  end

  if not text:sub(closing_end + 1):match("^%s*$") then
    return nil, "text found after Markdown code fence"
  end

  local code = text:sub(opening_end + 1, closing_start - 1)
  local first_line, rest = code:match("^([^\r\n]*)\r?\n(.*)$")
  if first_line then
    -- Content on an opening-fence line is Markdown info-string metadata. Strip
    -- it regardless of language so unknown tags cannot leak into source.
    code = rest
  else
    local tag, body = code:match("^%s*([%w_+%.#-]+)[ \t]+(.*)$")
    if tag and language_tags[tag:lower()] then code = body end
  end

  -- Remove one newline used only to separate code from the closing fence.
  code = code:gsub("\r?\n$", "")
  if vim.trim(code) == "" then return nil, "empty fenced replacement" end
  return code, nil
end

--- Backward-compatible fence helper.
---@param text string Raw provider response
---@return string code Response with a complete outer Markdown fence removed
function M.unwrap_code_fence(text)
  return M.normalize_replacement(text) or text
end

return M
