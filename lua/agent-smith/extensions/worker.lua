--- agent-smith/extensions/worker.lua
---
--- Work item tracking for iterative development.
---
--- Concept:
--- A "work item" is a persistent description of what you're building.
--- The Worker extension uses this to:
--- - Assess what's left to do (via search)
--- - Guide AI analysis of remaining work
--- - Track progress across sessions
---
--- Usage:
---   local smith = require("agent-smith")
---   smith.Extensions.Worker.set_work({ description = "Add user auth" })
---   -- ... make some changes ...
---   smith.Extensions.Worker.search() -- find remaining work
---
--- Persistence:
--- Work items are saved to a temp file so they persist across
--- Neovim sessions. The file is in stdpath("cache")/agent-smith/work-item.

local Utils = require("agent-smith.utils")

local M = {
  current_work_item = nil,
}

--- Get the work item file path.
---@return string
local function work_item_path()
  return Utils.named_tmp_file(nil, "work-item")
end

--- Set the current work item.
---
--- If description is provided, uses it directly.
--- Otherwise, prompts the user for input.
---
---@param opts? table { description: string }
function M.set_work(opts)
  opts = opts or {}
  if opts.description then
    M.current_work_item = opts.description
    Utils.write_file(work_item_path(), M.current_work_item)
  else
    -- TODO: Could open a prompt window here
    vim.notify("Agent-Smith: Set work item via set_work({ description = '...' })")
  end
end

--- Search for remaining work on the current work item.
---
--- Uses the search operation with a crafted prompt that includes
--- the work item description and git state.
function M.search()
  assert(M.current_work_item, "Set a work item first via set_work()")
  require("agent-smith").search({
    additional_prompt = string.format(
      [[Assess remaining work for this work item:
%s

Inspect git diff and current state. Report what still needs to be done.]],
      M.current_work_item
    ),
  })
end

--- Run vibe mode on the current work item.
function M.vibe()
  assert(M.current_work_item, "Set a work item first via set_work()")
  require("agent-smith").vibe({
    additional_prompt = "Complete/analyze work item: " .. M.current_work_item,
  })
end

return M
