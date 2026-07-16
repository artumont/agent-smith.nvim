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
--- identical.

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
  a.get_provider():fetch_models(function(models, err)
    if err then
      return vim.notify(err, vim.log.levels.WARN)
    end
    require("fzf-lua").fzf_exec(models, {
      actions = {
        ["default"] = function(selected)
          a.set_model(selected[1])
        end,
      },
    })
  end)
end

return M
