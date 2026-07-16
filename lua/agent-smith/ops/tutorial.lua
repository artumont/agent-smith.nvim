--- agent-smith/ops/tutorial.lua
---
--- Tutorial generation operation.
---
--- Sends a prompt to the AI asking it to create a tutorial.
--- The response must be valid Markdown with a title on the first line.
--- The tutorial is displayed in a split window.

local Prompt = require("agent-smith.prompt")
local Window = require("agent-smith.window")

local M = {}

--- Run the tutorial operation.
---
---@param state table Plugin state
---@param opts? table Options
---@return nil
function M.run(state, opts)
  opts = opts or {}

  require("agent-smith.window.prompt-window").capture("Tutorial", {
    cb = function(ok, text)
      if not ok or vim.trim(text) == "" then return end

      local p = Prompt.new(state, "tutorial")
      p:start(text, {
        on_complete = function(status, response)
          if status == "success" then
            Window.display_full_screen_message(
              vim.split(response, "\n", { plain = true })
            )
            local smith = require("agent-smith")
            local msg = smith.quote("tutorial")
            if msg then vim.notify(msg) end
          else
            vim.notify("Tutorial failed", vim.log.levels.ERROR)
          end
        end,
      })
    end,
  })
end

return M
