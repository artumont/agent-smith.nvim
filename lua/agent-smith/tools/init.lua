--- Assembling the tool set.
---
--- Tools are bound to a project root here, at assembly time, so that handlers
--- never have to guess a working directory and so tests can point the whole set
--- at a temporary directory.

local Registry = require("agent-smith.tools.registry")
local Read = require("agent-smith.tools.read")
local Grep = require("agent-smith.tools.grep")
local Glob = require("agent-smith.tools.glob")
local Edit = require("agent-smith.tools.edit")
local Bash = require("agent-smith.tools.bash")
local Diagnostics = require("agent-smith.tools.diagnostics")
local Plan = require("agent-smith.tools.plan")

local M = {}

--- A registry containing the whole tool set.
---
---@param options table
---   - root: string          Project root.
---   - writable: string|nil  Bound read-write by bash, i.e. the vibe clone.
---   - network: boolean|nil  For bash. Default false.
---   - max_lines?: number
---   - max_results?: number
---   - timeout_ms?: number
---@return table registry
function M.default(options)
  assert(type(options) == "table", "tools.default needs an options table")
  assert(options.root, "tools.default needs a root")

  local registry = Registry.new()
  registry:register(Read.tool(options))
  registry:register(Grep.tool(options))
  registry:register(Glob.tool(options))
  registry:register(Edit.tool(options))
  registry:register(Bash.tool(options))
  registry:register(Diagnostics.tool(options))
  return registry
end

--- A registry containing only the tools that cannot change anything.
---
--- This is vibe's plan phase: the agent has to be able to look around and
--- unable to act, and the way to guarantee the second half is to not hand it a
--- tool that can. Leaving `edit` and `bash` out is stronger than a policy that
--- refuses them, because there is nothing to refuse.
---
--- `on_plan` adds the `plan` tool, which records a declaration rather than doing
--- anything.
---
---@param options table
---   - root: string            Project root.
---   - on_plan: fun(plan)|nil  When given, registers the plan tool.
---@return table registry
function M.readonly(options)
  assert(type(options) == "table", "tools.readonly needs an options table")
  assert(options.root, "tools.readonly needs a root")

  local registry = Registry.new()
  registry:register(Read.tool(options))
  registry:register(Grep.tool(options))
  registry:register(Glob.tool(options))
  if type(options.on_plan) == "function" then
    registry:register(Plan.tool({ on_plan = options.on_plan }))
  end
  return registry
end

return M
