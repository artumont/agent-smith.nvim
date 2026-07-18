--- agent-smith/extensions/fzf-lua.lua
---
--- fzf-lua pickers for model and provider selection.
---
--- Requirements
---
--- Requires fzf-lua to be installed. If not available,
--- shows a warning notification.
---
--- Alternative to Telescope
---
--- This provides the same functionality as telescope.lua but
--- for users who prefer fzf-lua. The pickers are functionally
--- identical, including fuzzy semantic search results.

local M = {}

--- Open provider selection picker using fzf-lua.
function M.select_provider()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    return vim.notify("fzf-lua not installed", vim.log.levels.WARN)
  end

  local a = require("agent-smith")
  local names = {
    "OpenCodeProvider",
    "ClaudeCodeProvider",
    "CursorAgentProvider",
    "GeminiCLIProvider",
    "KiroProvider",
    "PiProvider",
  }

  fzf.fzf_exec(names, {
    actions = {
      ["default"] = function(selected)
        a.set_provider(a.Providers[selected[1]])
      end,
    },
  })
end

--- Open model selection picker using fzf-lua.
function M.select_model()
  local a = require("agent-smith")
  local provider = a.get_provider()
  if type(provider.fetch_models) ~= "function" then
    return vim.notify(
      a.get_provider_name() .. " does not support model listing",
      vim.log.levels.WARN
    )
  end

  local ok, fetch_error = pcall(provider.fetch_models, provider, function(models, err)
    if err then
      return vim.notify(err, vim.log.levels.WARN)
    end
    if type(models) ~= "table" or #models == 0 then
      return vim.notify("Provider returned no available models", vim.log.levels.WARN)
    end
    require("fzf-lua").fzf_exec(models, {
      actions = {
        ["default"] = function(selected)
          a.set_model(selected[1])
        end,
      },
    })
  end)
  if not ok then
    vim.notify("Failed to list models: " .. tostring(fetch_error), vim.log.levels.ERROR)
  end
end

--- Open semantic search results in an fzf-lua picker.
---@param items table[] Parsed quickfix-style search entries
---@param cb fun(item: table) Called with selected result
---@return boolean opened Whether fzf-lua was available
function M.search_results(items, cb)
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then return false end

  local labels = {}
  local by_label = {}
  for _, item in ipairs(items) do
    local label = string.format(
      "%s:%d:%d  %s",
      vim.fn.fnamemodify(item.filename, ":."),
      item.lnum or 1,
      item.col or 1,
      item.text or ""
    )
    table.insert(labels, label)
    by_label[label] = item
  end

  fzf.fzf_exec(labels, {
    prompt = "Agent-Smith Codebase Search> ",
    actions = {
      ["default"] = function(selected)
        local item = selected and by_label[selected[1]]
        if item then cb(item) end
      end,
    },
  })
  return true
end

return M
