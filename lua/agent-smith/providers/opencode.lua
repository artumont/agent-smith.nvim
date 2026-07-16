local Base = require("agent-smith.providers").BaseProvider
local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "OpenCode" end
-- OpenCode ships this free model by default. Do not use the old
-- opencode/claude-sonnet-4-5 identifier: current OpenCode installs do not list it.
function P:_get_default_model() return "opencode/mimo-v2.5-free" end
function P:_build_command(query, context)
  -- Agent-Smith applies visual and multi-file output itself. Discovery modes
  -- must never let OpenCode mutate project files, so use its read-only agent.
  local agent = (context.operation == "search" or context.operation == "vibe")
    and "compaction"
    or "build"
  return { "opencode", "run", "--agent", agent, "-m", context.model, query }
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
