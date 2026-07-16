local Base = require("agent-smith.providers").BaseProvider; local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "Cursor Agent" end
function P:_get_default_model() return "sonnet-4.5" end
function P:_build_command(q, c) return { "cursor-agent", "--trust", "--force", "--model", c.model, "--print", q } end
return P
