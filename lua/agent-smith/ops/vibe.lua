--- agent-smith/ops/vibe.lua
---
--- Vibe mode: open-ended AI analysis with quickfix output.
---
--- Difference from search:
--- - Search: Find specific locations matching a description
--- - Vibe: Perform an action and report what was done/found
---
--- Both use the same quickfix output format, but vibe is more open-ended.
---
--- Use cases:
--- - "Analyze all error handling patterns in this project"
--- - "Review recent commits and summarize changes"
--- - "Find potential bugs in the auth module"
--- - "Check for missing tests in the API layer"
---
--- Response format:
--- Same as search: /path/to/file:line:col,count,note

local Prompt = require("agent-smith.prompt")
local Qfix = require("agent-smith.ops.qfix-helpers")

local M = {}

--- Run the vibe operation.
---
---@param state table Plugin state
---@param opts? table Options: { additional_prompt: string }
---@return nil
function M.run(state, opts)
  opts = opts or {}

  local function send(user)
    local context = Prompt.new(state, "vibe")
    context:start(user, {
      on_complete = function(status, response)
        if status ~= "success" then
          return vim.notify("Vibe failed: " .. status, vim.log.levels.ERROR)
        end

        local items = Qfix.parse(response)
        if #items > 0 then
          vim.fn.setqflist({}, "r", {
            title = "Agent-Smith Vibe",
            items = items,
          })
          vim.cmd("copen")
        else
          vim.notify("Vibe completed without locations")
        end
      end,
    })
  end

  if opts.additional_prompt then
    send(opts.additional_prompt)
  else
    require("agent-smith.window.prompt-window").capture("Vibe", {
      cb = function(ok, text)
        if ok and vim.trim(text) ~= "" then
          send(text)
        end
      end,
    })
  end
end

return M
