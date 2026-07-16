local Base = require("agent-smith.providers").BaseProvider; local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "Gemini CLI" end
function P:_get_default_model() return "auto" end
function P:_build_command(q, c) return { "gemini", "--approval-mode", "auto_edit", "--model", c.model, "--prompt", q } end
return P
