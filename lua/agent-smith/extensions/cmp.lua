--- agent-smith/extensions/cmp.lua
---
--- nvim-cmp source for #rules and @files.
---
--- Requirements
---
--- Requires hrsh7th/nvim-cmp to be installed.
---
--- Integration
---
--- Delegates to the native completion module for the actual
--- completion logic. The difference is in how completions are
--- presented to the user (nvim-cmp UI vs native omnifunc).

local M = {}

--- Initialize the cmp source.
---@param state table Plugin state
function M.init(state)
  require("agent-smith.extensions.native").init(state)
end

--- Initialize for a specific buffer.
---@param state table Plugin state
function M.init_for_buffer(state)
  require("agent-smith.extensions.native").init_for_buffer(state)
end

return M
