--- agent-smith/extensions/telescope.lua
---
--- Telescope pickers for model and provider selection.
---
--- Requirements:
--- Requires telescope.nvim to be installed. If not available,
--- shows a warning notification instead of erroring.
---
--- Pickers:
--- - select_provider: List all providers, switch on selection
--- - select_model: List models for current provider, switch on selection
---
--- Model fetching:
--- Model list is fetched asynchronously from the provider.
--- Some providers don't support model listing (returns error).

local M = {}

--- Generic picker helper using Telescope.
---
---@param title string Picker title
---@param items string[] Items to display
---@param cb function Callback with selected item
local function picker(title, items, cb)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return vim.notify("telescope.nvim not installed", vim.log.levels.WARN)
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = title,
      finder = finders.new_table(items),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(buf)
        actions.select_default:replace(function()
          local entry = state.get_selected_entry()
          actions.close(buf)
          cb(entry[1])
        end)
        return true
      end,
    })
    :find()
end

--- Open provider selection picker.
function M.select_provider()
  local a = require("agent-smith")
  local providers = a.Providers
  local names = {
    "OpenCodeProvider",
    "ClaudeCodeProvider",
    "CursorAgentProvider",
    "GeminiCLIProvider",
    "KiroProvider",
    "PiProvider",
  }
  picker("Agent-Smith Providers", names, function(name)
    a.set_provider(providers[name])
  end)
end

--- Open model selection picker.
function M.select_model()
  local a = require("agent-smith")
  a.get_provider():fetch_models(function(models, err)
    if err then
      return vim.notify(err, vim.log.levels.WARN)
    end
    picker("Agent-Smith Models", models, a.set_model)
  end)
end

return M
