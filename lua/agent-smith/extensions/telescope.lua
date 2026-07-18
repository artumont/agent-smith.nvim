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
--- - search_results: Fuzzy-find semantic search locations with file preview
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

--- Open semantic search results in a fuzzy picker with file preview.
---@param items table[] Parsed quickfix-style search entries
---@param cb fun(item: table) Called with selected result
---@return boolean opened Whether Telescope was available
function M.search_results(items, cb)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then return false end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "Agent-Smith Codebase Search",
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        local path = vim.fn.fnamemodify(item.filename, ":.")
        local display = string.format(
          "%s:%d:%d  %s",
          path,
          item.lnum or 1,
          item.col or 1,
          item.text or ""
        )
        return {
          value = item,
          display = display,
          ordinal = display,
          filename = item.filename,
          lnum = item.lnum,
          col = item.col,
        }
      end,
    }),
    previewer = conf.grep_previewer({}),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(buf)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(buf)
        if entry then cb(entry.value) end
      end)
      return true
    end,
  }):find()

  return true
end

return M
