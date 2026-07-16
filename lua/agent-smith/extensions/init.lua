--- agent-smith/extensions/init.lua
---
--- Extension loader and lifecycle management.
---
--- Extension architecture:
--- Extensions are optional modules that add features:
--- - Completions: #rule and @file autocomplete
--- - Telescope: Model/provider selection pickers
--- - fzf-lua: Same pickers for fzf-lua users
--- - Worker: Work item tracking
---
--- Each extension implements:
--- - init(state): Called once during setup()
--- - init_for_buffer(state): Called for each new buffer
---
--- Lazy loading:
--- Extensions are loaded based on availability:
--- - Telescope: only if telescope.nvim is installed
--- - fzf-lua: only if fzf-lua is installed
--- - Completions: based on "source" config (native/cmp/blink)
---
--- Completion sources:
--- The "source" option in completion config determines which backend:
--- - "native": Built-in omnifunc (no dependencies)
--- - "cmp": nvim-cmp source (requires hrsh7th/nvim-cmp)
--- - "blink": blink.cmp source (requires saghen/blink.compat)
---
--- All sources register the same # and @ triggers, just with different
--- UI integration.

local M = {}

--- Initialize extensions during plugin setup.
---
--- Discovers available extensions and initializes them.
--- Also sets the project root for file discovery.
---
---@param state table The plugin state
function M.init(state)
  -- Load the configured completion source
  local source = (state.completion or {}).source or "native"
  local ok, ext = pcall(require, "agent-smith.extensions." .. source)
  if ok and ext.init then
    ext.init(state)
  end

  -- Set project root for file discovery (prefer git root)
  local Files = require("agent-smith.extensions.files")
  Files.set_project_root(
    vim.fs.root(vim.fn.getcwd(), ".git") or vim.fn.getcwd()
  )
end

--- Initialize extensions for a specific buffer.
---
--- Called when a new buffer is created or when the prompt window opens.
--- Sets up buffer-local completion sources.
---
---@param state table The plugin state
function M.setup_buffer(state)
  local source = (state.completion or {}).source or "native"
  local ok, ext = pcall(require, "agent-smith.extensions." .. source)
  if ok and ext.init_for_buffer then
    ext.init_for_buffer(state)
  end
end

return M
