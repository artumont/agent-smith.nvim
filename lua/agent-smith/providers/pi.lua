local Base = require("agent-smith.providers").BaseProvider
local P = setmetatable({}, { __index = Base })

local READ_ONLY_SYSTEM_PROMPT = [[You are a bounded read-only code assistant.
Follow the request's output contract exactly. Never edit, write, create, delete,
or rename files; Agent-Smith alone applies returned changes.]]

function P:_get_provider_name() return "Pi" end
-- Empty model means omit --model and let Pi use its configured default.
function P:_get_default_model() return "" end
function P:_build_command(q, c)
  local command = { "pi", "--print", "--no-session" }
  if c.operation ~= "vibe" or c.vibe_phase == "plan" then
    -- Prompt rules alone cannot stop an agent from calling mutating tools.
    -- Planning and non-Vibe operations consume text responses; Agent-Smith
    -- applies changes after the plan is approved.
    vim.list_extend(command, {
      "--tools", "read,grep,find,ls",
      "--system-prompt", READ_ONLY_SYSTEM_PROMPT,
    })
  end
  if c.model and c.model ~= "" then vim.list_extend(command, { "--model", c.model }) end
  table.insert(command, q)
  return command
end

local function parse_models(output)
  local models = {}
  for line in output:gmatch("[^\r\n]+") do
    line = line:gsub("\27%[[%d;]*m", "")
    local provider, model, _context, _max_output, thinking, images = line:match(
      "^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*$"
    )
    if provider and (thinking == "yes" or thinking == "no")
      and (images == "yes" or images == "no") then
      table.insert(models, provider .. "/" .. model)
    end
  end
  return models
end

function P:fetch_models(cb)
  vim.system({ "pi", "--list-models" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb(nil, "Failed to list Pi models")
        return
      end

      local models = parse_models(result.stdout or "")
      if #models == 0 then
        cb(nil, "Pi returned no available models")
        return
      end
      cb(models, nil)
    end)
  end)
end

return P
