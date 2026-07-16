--- agent-smith/state.lua
---
--- Plugin-wide state singleton.
---
--- Responsibility:
--- Holds all configuration and runtime state for the plugin:
--- - Current provider and model
--- - Provider override (for runtime switching)
--- - Custom rule directories and discovered rules
--- - Context file names (md_files like AGENTS.md)
--- - Completion settings
--- - Request tracking history
--- - Temp directory path
---
--- Rule discovery:
--- Rules are SKILL.md files organized in directories. Each directory
--- becomes a rule with the directory name as its identifier:
---
---   custom_rules/
---   +-- vim/
---   |   +-- SKILL.md      -> rule name: "vim"
---   +-- python/
---   |   +-- SKILL.md      -> rule name: "python"
---   +-- cloudflare/
---       +-- SKILL.md      -> rule name: "cloudflare"
---
--- Rules are discovered on setup and can be refreshed via refresh_rules().
--- They are referenced in prompts as #vim, #python, etc.
---
--- State flow:
--- 1. setup() creates a State instance
--- 2. All operations receive state as first argument
--- 3. State is never modified after setup (except provider_override and model)
--- 4. Tracking history grows as requests complete
---
--- Thread safety:
--- Not applicable - Neovim is single-threaded. All state mutations happen
--- in the main thread or via vim.schedule() callbacks.

local Tracking = require("agent-smith.tracking")
local Utils = require("agent-smith.utils")

local M = {}
M.__index = M

local function choice_file()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "agent-smith", "preference")
end

--- Read the persisted first-run choice.
---@return string|nil choice "red" | "blue" | nil
function M.read_choice()
  local content = Utils.read_file(choice_file())
  if content == "red" or content == "blue" then return content end
  return nil
end

--- Persist the first-run choice.
---@param choice string "red" | "blue"
function M.write_choice(choice)
  Utils.write_file(choice_file(), choice)
end

--- Discover SKILL.md files in configured directories.
---
--- Scans each directory for subdirectories containing SKILL.md files.
--- Returns an array of { name, path } entries.
---
---@param dirs string[] Array of directory paths to scan
---@return table[] rules Array of { name: string, path: string }
local function discover_rules(dirs)
  local out = {}
  for _, dir in ipairs(dirs or {}) do
    local expanded = vim.fn.expand(dir)
    for name, kind in vim.fs.dir(expanded) do
      if kind == "directory" then
        local path = vim.fs.joinpath(expanded, name, "SKILL.md")
        if vim.uv.fs_stat(path) then
          table.insert(out, { name = name, path = path })
        end
      end
    end
  end
  return out
end

--- Create a new State instance.
---
---@param opts table Configuration options from setup()
---@return table state The State instance
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    -- Provider configuration
    model = opts.model,
    provider = opts.provider,
    provider_override = nil,
    provider_extra_args = opts.provider_extra_args or {},

    -- Context discovery
    md_files = opts.md_files or { "AGENTS.md" },
    completion = opts.completion or {},
    custom_rule_dirs = (opts.completion or {}).custom_rules or {},

    -- Runtime state
    tracking = Tracking.new(),
    display_errors = opts.display_errors or false,
    tmp_dir_path = opts.tmp_dir,
    rules = {},
    matrix_mode = false,
  }, M)

  local choice = M.read_choice()
  if choice == "red" then self.matrix_mode = true end

  self:refresh_rules()
  return self
end

--- Re-scan custom rule directories for SKILL.md files.
---
--- Call this if you add/remove rule directories after setup.
function M:refresh_rules()
  self.rules = discover_rules(self.custom_rule_dirs)
end

--- Get the temp file directory (creating it if needed).
---
---@return string dir Absolute path to temp directory
function M:tmp_dir()
  return self.tmp_dir_path or "/tmp/nvim/agent-smith"
end

--- Get the active provider (override or default).
---
---@return table provider A BaseProvider instance
function M:active_provider()
  return self.provider_override or self.provider
end

return M
