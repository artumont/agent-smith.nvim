--- The provider registry.
---
--- Providers are declarations; the behaviour lives in
--- agent-smith.providers.base. This module lists them and adds a resolving
--- facade, so a caller can pass a name, a provider, or a plain declaration with
--- a base_url and get the same behaviour either way.

local Base = require("agent-smith.providers.base")

local M = {}

M.CHAT = Base.CHAT
M.RESPONSES = Base.RESPONSES
M.MESSAGES = Base.MESSAGES

M.presets = {
  zen = require("agent-smith.providers.zen"),
  go = require("agent-smith.providers.go"),
  commandcode = require("agent-smith.providers.commandcode"),
}

--- Sorted preset names.
function M.names()
  local names = vim.tbl_keys(M.presets)
  table.sort(names)
  return names
end

--- A preset by name.
function M.get(name)
  return M.presets[name]
end

--- Resolve a name, a provider, or a plain declaration.
---
---@return table|nil provider
---@return string|nil error
function M.resolve(provider)
  if type(provider) == "string" then
    local found = M.presets[provider]
    if not found then
      return nil, ("unknown provider %q; known: %s"):format(provider, table.concat(M.names(), ", "))
    end
    return found
  end

  if type(provider) == "table" then
    -- Also covers a custom provider: a declaration with a base_url that is not
    -- one of the presets. Safe on a provider that already exists.
    local ok, value = pcall(Base.new, provider)
    if not ok then
      return nil, tostring(value)
    end
    return value
  end

  return nil, "a provider name or declaration is required"
end

--- A provider declared inline, for an OpenAI-compatible endpoint that is not a
--- preset: Ollama, vLLM, llama.cpp, an internal gateway.
function M.custom(fields)
  return Base.new(fields)
end

-- Facade. Each of these resolves its first argument, then delegates to the
-- provider, so a name works anywhere a provider does.

---@return table|nil result
---@return string|nil error
function M.fetch(provider, fields)
  local resolved, err = M.resolve(provider)
  if not resolved then
    return nil, err
  end
  return resolved:fetch(fields)
end

function M.catalogue(provider, fields)
  local resolved, err = M.resolve(provider)
  if not resolved then
    return nil, err
  end
  return resolved:catalogue(fields)
end

function M.read_cache(provider, fields)
  local resolved, err = M.resolve(provider)
  if not resolved then
    return nil, err
  end
  return resolved:read_cache(fields)
end

function M.format_for(provider, model, override, fields)
  local resolved, err = M.resolve(provider)
  if not resolved then
    return nil, err
  end
  return resolved:format_for(model, override, fields)
end

function M.credential(provider, fields)
  local resolved, err = M.resolve(provider)
  if not resolved then
    return nil, err
  end
  return resolved:credential(fields)
end

function M.available(provider, fields)
  local resolved, err = M.resolve(provider)
  if not resolved then
    return nil, err
  end
  return resolved:available(fields)
end

function M.wire_model(provider, model)
  local resolved, err = M.resolve(provider)
  if not resolved then
    return nil, err
  end
  return resolved:wire_model(model)
end

--- Build a transport. Takes the fields the provider method takes, plus
--- `provider`, which may be a name or a declaration.
function M.transport_for(fields)
  assert(type(fields) == "table", "transport_for needs a fields table")

  local resolved, err = M.resolve(fields.provider or "zen")
  if not resolved then
    return nil, err, nil
  end
  return resolved:transport_for(fields)
end

--- Parse a `GET /models` body with the default endpoint mapping.
function M.parse(body)
  return Base.parse(body)
end

M.choose_format = Base.choose_format
M.default_cache_directory = Base.default_cache_directory
M.forget = Base.forget

return M
