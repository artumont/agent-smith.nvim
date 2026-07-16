local Base = require("agent-smith.providers").BaseProvider; local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "Kiro" end
function P:_get_default_model() return "claude-sonnet-4.5" end
function P:_build_command(q, c) return { "kiro-cli", "chat", "--no-interactive", "--model", c.model, "--trust-all-tools", q } end
return P
