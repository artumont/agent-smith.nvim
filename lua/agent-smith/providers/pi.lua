local Base = require("agent-smith.providers").BaseProvider; local P = setmetatable({}, { __index = Base })
function P:_get_provider_name() return "Pi" end
function P:_get_default_model() return "auto" end
function P:_build_command(q, c)
  local command = { "pi", "--print", "--no-session" }
  if c.model and c.model ~= "" then vim.list_extend(command, { "--model", c.model }) end
  table.insert(command, q); return command
end
return P
