local Base = require("agent-smith.providers").BaseProvider
local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "OpenCode" end
-- OpenCode ships this free model by default. Do not use the old
-- opencode/claude-sonnet-4-5 identifier: current OpenCode installs do not list it.
function P:_get_default_model() return "opencode/mimo-v2.5-free" end
function P:_build_command(query, context)
  -- Non-Vibe operations consume text responses and need no provider-side edits.
  -- Vibe execution writes only into its disposable project copy.
  local agent = context.operation == "vibe" and "build" or "plan"
  local command = { "opencode", "run", "--agent", agent, "-m", context.model }
  if context.cwd then vim.list_extend(command, { "--dir", context.cwd }) end
  table.insert(command, query)
  return command
end
function P:fetch_models(cb)
  vim.system({ "opencode", "models" }, { text = true }, function(r)
    vim.schedule(function()
      cb(r.code == 0 and vim.split(r.stdout, "\n", { trimempty = true }) or nil,
        r.code ~= 0 and "Failed to list OpenCode models" or nil)
    end)
  end)
end
return P
