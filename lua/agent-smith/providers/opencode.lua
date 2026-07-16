local Base = require("agent-smith.providers").BaseProvider
local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "OpenCode" end
function P:_get_default_model() return "opencode/claude-sonnet-4-5" end
function P:_build_command(query, context) return { "opencode", "run", "--agent", "build", "-m", context.model, query } end
function P:fetch_models(cb)
  vim.system({ "opencode", "models" }, { text = true }, function(r)
    vim.schedule(function()
      cb(r.code == 0 and vim.split(r.stdout, "\n", { trimempty = true }) or nil,
        r.code ~= 0 and "Failed to list OpenCode models" or nil)
    end)
  end)
end
return P
