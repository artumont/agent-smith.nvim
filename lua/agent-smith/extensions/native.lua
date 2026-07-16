--- agent-smith/extensions/native.lua
---
--- Native Neovim completion source for #rules and @files.
---
--- How it works:
--- Uses omnifunc for completion. The complete() function is called
--- by Neovim's insert mode completion (C-x C-o).
---
--- Completion logic:
--- 1. Detect trigger character (# or @) at cursor
--- 2. Extract the query (text after trigger)
--- 3. Filter available items (rules or files) by query prefix
--- 4. Return matching items as completion candidates

local M = {}

--- Initialize the native completion source.
---
---@param state table Plugin state with rules
function M.init(state)
  local C = require("agent-smith.extensions.completions")
  local Files = require("agent-smith.extensions.files")

  -- Register # rule completion
  C.register({
    trigger = "#",
    resolve = function(name)
      for _, rule in ipairs(state.rules) do
        if rule.name == name then
          return table.concat(vim.fn.readfile(rule.path), "\n")
        end
      end
    end,
  })

  -- Register @ file completion
  C.register({
    trigger = "@",
    resolve = Files.resolve,
  })
end

--- Initialize completion for a specific buffer.
---
---@param state table Plugin state
function M.init_for_buffer(state)
  vim.bo.omnifunc = "v:lua.require'agent-smith.extensions.native'.complete"
  M._state = state
end

--- Omnifunc callback for completion.
---
--- Called by Neovim when user presses C-x C-o in insert mode.
---
---@param findstart number 1 = find start column, 0 = get completions
---@param base string Text after trigger character
---@return number|string[] Start column or completion items
function M.complete(findstart, base)
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  if findstart == 1 then
    -- Find the start of the token (trigger character)
    local start = col
    while start > 0 and line:sub(start, start):match("[^%s]") do
      start = start - 1
    end
    return start
  end

  -- Get trigger and query
  local trigger = base:sub(1, 1)
  local query = base:sub(2)

  if trigger == "#" then
    -- Filter rules by query prefix
    return vim.tbl_map(function(rule)
      return "#" .. rule.name
    end, vim.tbl_filter(function(rule)
      return rule.name:find(query, 1, true) == 1
    end, (M._state or {}).rules or {}))
  end

  if trigger == "@" then
    -- Filter files by query prefix
    return vim.tbl_map(function(file)
      return "@" .. file.label
    end, vim.tbl_filter(function(file)
      return file.label:find(query, 1, true) == 1
    end, require("agent-smith.extensions.files").items()))
  end

  return {}
end

return M
