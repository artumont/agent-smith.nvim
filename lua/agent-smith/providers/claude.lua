local Base = require("agent-smith.providers").BaseProvider; local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "Claude Code" end
function P:_get_default_model() return "claude-sonnet-4-5" end
function P:_build_command(q, c) return { "claude", "--dangerously-skip-permissions", "--model", c.model, "--print", q } end
function P:fetch_models(cb) cb({ "claude-opus-4-6", "claude-sonnet-4-5", "claude-haiku-4-5" }, nil) end
return P
