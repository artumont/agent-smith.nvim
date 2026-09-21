--- The provider contract.
---
--- A provider is a *declaration*, not an implementation: a base URL, where its
--- credential comes from, and how to find out which wire format serves a model.
--- All the behaviour lives here, so adding a provider is a new file of fields
--- (spec/decisions/0010-integrated-providers-are-presets.md).
---
--- The model list is fetched, not written down. All three gateways expose an
--- OpenAI-shaped `GET /models`, measured:
---
---   api.commandcode.ai/provider/v1/models   71 models, with supported_endpoints
---   opencode.ai/zen/v1/models               6.2KB of { id, object, created, owned_by }
---   opencode.ai/zen/go/v1/models            3.1KB, same shape
---
--- CommandCode publishes routing per model, so for it the fetched catalogue is
--- authoritative. Zen and Go publish none, so for those a narrow documented rule
--- stands in and is labelled as a rule
--- (spec/decisions/0012-models-are-fetched-not-catalogued.md).
---
--- Two details worth knowing before changing anything here:
---
---   - The lists are public: all three answered without a credential. One is
---     still sent first, and a rejected credential is retried without, because a
---     stale key should not block reading a public catalogue. Measured: a key Zen
---     rejects turns a 200 into `401 Invalid credential`.
---   - Fetching is blocking and cached, and is never done from the request path.
---     A network call mid-keystroke is not acceptable, so a request decides from
---     cache or from the rules.

local Auth = require("agent-smith.auth")
local Transport = require("agent-smith.transport.openai_compat")
-- The harness itself, not an adapter: normalise_headers lives there, and the
-- adapters re-export only the fields they happen to need.
local TransportBase = require("agent-smith.transport.base")

local M = {}

M.CHAT = "chat"
M.RESPONSES = "responses"
M.MESSAGES = "messages"

--- Wire formats with an adapter behind them, by module.
---
--- Adding the Anthropic Messages adapter is an entry here, not a change to the
--- request path.
local ADAPTERS = {
  [M.CHAT] = "agent-smith.transport.openai_compat",
  [M.RESPONSES] = "agent-smith.transport.responses",
  [M.MESSAGES] = "agent-smith.transport.anthropic",
}

--- Public so an adapter can be registered from outside, and so a caller can ask
--- what is available.
M.adapters = ADAPTERS

--- Which adapter a format needs, for an error message worth reading.
local FORMAT_ADAPTER = {
  [M.CHAT] = "the OpenAI chat completions adapter",
  [M.RESPONSES] = "the OpenAI Responses adapter",
  [M.MESSAGES] = "the Anthropic Messages adapter",
}

--- Endpoint path to format, as published in a vendor's `supported_endpoints`.
local ENDPOINT_FORMATS = {
  ["/chat/completions"] = M.CHAT,
  ["/responses"] = M.RESPONSES,
  ["/messages"] = M.MESSAGES,
}

M.CACHE_VERSION = 1
M.DEFAULT_TTL_MS = 24 * 60 * 60 * 1000
M.FETCH_TIMEOUT_MS = 15000

--- Fields a provider file must declare.
M.REQUIRED = { "name", "base_url" }

--- Fields a provider file may declare, and what each one does:
---
---   env                 Environment variable holding the credential.
---   auth_key            Key in agent-smith's own store.
---   session_header      Header for prompt-cache routing, where the vendor
---                       documents one.
---   model_prefix        Prefix the vendor's own CLI prints but the wire does
---                       not want, e.g. "opencode".
---   responses_prefixes  Model id prefixes served on /responses. Only for a
---                       gateway that publishes no routing of its own.
---   messages_prefixes   Model id prefixes served on /messages only.
---   user_agent          Overrides the transport's default.
---   headers             Extra request headers: a list of `{ name, value }` or a
---                       map of name to value. For a gateway that wants something
---                       this client has no opinion about. Values reach argv, so
---                       they are for things that are not secrets.
M.DECLARABLE = {
  "env",
  "auth_key",
  "session_header",
  "model_prefix",
  "responses_prefixes",
  "messages_prefixes",
  "user_agent",
  "models_path",
  "headers",
}

local memory = {}

local Base = {}

--- Build a provider from a declaration.
---
--- Safe to call on a provider that already exists: fields are copied and the
--- metatable is set, so resolving an instance is idempotent.
---@return table provider
function M.new(declaration)
  assert(type(declaration) == "table", "a provider needs a declaration table")
  for _, field in ipairs(M.REQUIRED) do
    if type(declaration[field]) ~= "string" or declaration[field] == "" then
      error(("a provider needs a %s"):format(field), 0)
    end
  end

  local provider = setmetatable({}, { __index = Base })
  for key, value in pairs(declaration) do
    provider[key] = value
  end
  return provider
end

M.extend = M.new

-- ---------------------------------------------------------------------------
-- Declaration accessors
-- ---------------------------------------------------------------------------

function Base:models_path()
  return self.declared_models_path or "/models"
end

function Base:endpoint_formats()
  return ENDPOINT_FORMATS
end

--- The model id as the vendor expects it.
---
--- Accepts the prefixed form a vendor CLI prints so a user can paste what they
--- were shown without having to know the prefix is not part of the id.
function Base:wire_model(model)
  local prefix = self.model_prefix
  if prefix and vim.startswith(model, prefix .. "/") then
    return model:sub(#prefix + 2)
  end
  return model
end

-- ---------------------------------------------------------------------------
-- Credentials
-- ---------------------------------------------------------------------------

--- In order: an explicit key, the provider's environment variable, the store.
---@return string|nil key
---@return string|nil error
function Base:credential(fields)
  fields = fields or {}

  if type(fields.api_key) == "string" and fields.api_key ~= "" then
    return fields.api_key, nil
  end

  if self.env then
    local from_environment = vim.env[self.env]
    if type(from_environment) == "string" and from_environment ~= "" then
      return from_environment, nil
    end
  end

  if self.auth_key then
    local store = fields.store or Auth.new()
    local stored, store_error = store:get(self.auth_key)
    if stored then
      return stored, nil
    end
    if store_error then
      return nil, store_error
    end
  end

  return nil,
    ("no credential for %s; set %s or store one for %q"):format(
      self.name,
      self.env or "an environment variable",
      self.auth_key or self.name
    )
end

-- ---------------------------------------------------------------------------
-- The model catalogue
-- ---------------------------------------------------------------------------

--- Normalise one entry from a vendor's list.
---
--- `supported_endpoints` is present on CommandCode and absent on the OpenCode
--- gateways, so an entry with no endpoints is a model whose routing is *unknown*
--- rather than a model with no routes.
local function normalise(entry, formats)
  local endpoints = {}

  if type(entry.supported_endpoints) == "table" then
    for _, path in ipairs(entry.supported_endpoints) do
      local format = formats[path]
      if format then
        endpoints[#endpoints + 1] = format
      end
    end
  end

  return {
    id = entry.id,
    name = entry.name,
    context_length = entry.context_length,
    endpoints = endpoints,
  }
end

--- Parse a `GET /models` body using an endpoint mapping.
---@return table[]|nil models
---@return string|nil error
function M.parse(body, formats)
  formats = formats or ENDPOINT_FORMATS

  if type(body) ~= "string" or body == "" then
    return nil, "the models endpoint returned nothing"
  end

  local decoded, parsed = pcall(vim.json.decode, body)
  if not decoded or type(parsed) ~= "table" then
    return nil, "the models endpoint did not return JSON"
  end

  local list = parsed.data or parsed
  if type(list) ~= "table" then
    return nil, "the models endpoint returned no list"
  end

  local models = {}
  for _, entry in ipairs(list) do
    if type(entry) == "table" and type(entry.id) == "string" then
      models[#models + 1] = normalise(entry, formats)
    end
  end

  if #models == 0 then
    return nil, "the models endpoint listed no models"
  end

  table.sort(models, function(left, right)
    return left.id < right.id
  end)
  return models
end

--- Parse using this provider's endpoint mapping, which a provider may extend.
function Base:parse(body)
  return M.parse(body, self:endpoint_formats())
end

function Base:cache_file(fields)
  local directory = (fields and fields.cache_directory) or M.default_cache_directory()
  local digest = vim.fn.sha256(self.name):sub(1, 12)
  return vim.fs.joinpath(directory, ("models-%s.json"):format(digest))
end

--- Read the disk cache, if it is present and fresh enough.
---
--- `fields.cache_directory` and `fields.ttl_ms` are injectable so tests do not
--- read or write the real cache.
---@return table|nil cached
function Base:read_cache(fields)
  fields = fields or {}
  local path = self:cache_file(fields)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local decoded, cached = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not decoded or type(cached) ~= "table" or cached.version ~= M.CACHE_VERSION then
    return nil
  end
  if type(cached.fetched_at) ~= "number" or type(cached.models) ~= "table" then
    return nil
  end

  if (vim.uv.now() - cached.fetched_at) > (fields.ttl_ms or M.DEFAULT_TTL_MS) then
    return nil
  end
  return cached
end

function Base:write_cache(models, fields)
  local path = self:cache_file(fields or {})
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  pcall(
    vim.fn.writefile,
    { vim.json.encode({ version = M.CACHE_VERSION, fetched_at = vim.uv.now(), models = models }) },
    path,
    "b"
  )
end

--- The argv and environment for a models request.
---
--- The credential goes through the environment like every other request, so it
--- stays out of `argv`, which is world-readable.
function Base:models_command(fields)
  local url = self.base_url:gsub("/+$", "") .. self:models_path()

  local authorization = ""
  if fields.api_key then
    authorization = ' -H "Authorization: Bearer $' .. Transport.TOKEN_ENV .. '"'
  end

  local script = "exec curl -sS -N --fail-with-body -X GET "
    .. string.format("%q", url)
    .. authorization

  return { "sh", "-c", script, "agent-smith" }, { [Transport.TOKEN_ENV] = fields.api_key or "" }
end

--- Fetch the model list. Blocking, and cached on disk.
---
--- `fields.execute` is injectable so this is testable without a network.
---@return table|nil result { models, fetched_at, credential_rejected }
---@return string|nil error
function Base:fetch(fields)
  fields = fields or {}

  local cached = (not fields.refresh) and self:read_cache(fields)
  if cached then
    memory[self.name] = cached
    return cached, nil
  end

  local execute = fields.execute or vim.system
  local key = select(1, self:credential(fields))
  local credential_rejected = false

  local function attempt(api_key)
    local command, env = self:models_command({ api_key = api_key })
    return execute(command, { text = true, env = env, timeout = M.FETCH_TIMEOUT_MS }):wait()
  end

  local completed = attempt(key)
  if completed.code ~= 0 and key then
    -- The lists are public. A key a gateway rejects should not stop us reading a
    -- public catalogue, so try once without it and say what happened.
    local retried = attempt(nil)
    if retried.code == 0 then
      credential_rejected = true
      completed = retried
    end
  end

  if completed.code ~= 0 then
    return nil,
      ("could not fetch models from %s: %s"):format(
        self.name,
        vim.trim(completed.stderr or "no output")
      )
  end

  local models, parse_error = self:parse(completed.stdout)
  if not models then
    return nil, parse_error
  end

  local result = {
    models = models,
    fetched_at = vim.uv.now(),
    credential_rejected = credential_rejected,
  }

  self:write_cache(models, fields)
  memory[self.name] = result
  return result, nil
end

--- A catalogue already in hand: memory first, then a fresh disk cache.
---
--- Never fetches. The request path uses this, so a keystroke never waits on a
--- network call.
---@return table|nil result
function Base:catalogue(fields)
  if memory[self.name] then
    return memory[self.name]
  end
  local cached = self:read_cache(fields or {})
  if cached then
    memory[self.name] = cached
  end
  return memory[self.name]
end

-- ---------------------------------------------------------------------------
-- Routing
-- ---------------------------------------------------------------------------

--- The best format for a catalogue entry.
---
--- Chat completions is preferred when it is offered, because that is the adapter
--- that exists; a model offering only /messages can still be described
--- accurately and refused.
---@return string|nil format
function M.choose_format(entry)
  if type(entry) ~= "table" or type(entry.endpoints) ~= "table" then
    return nil
  end
  for _, format in ipairs({ M.CHAT, M.RESPONSES, M.MESSAGES }) do
    for _, offered in ipairs(entry.endpoints) do
      if offered == format then
        return format
      end
    end
  end
  return nil
end

local function starts_with_any(id, prefixes)
  for _, prefix in ipairs(prefixes or {}) do
    if vim.startswith(id, prefix) then
      return true
    end
  end
  return false
end

--- The format implied by the provider's documented rules.
---
--- Only for a gateway that publishes no routing of its own. Zen and Go are in
--- that position; CommandCode falls back here only when no catalogue is cached.
---@return string format
---@return string reason
function Base:ruled_format(model)
  local id = self:wire_model(model)

  if starts_with_any(id, self.messages_prefixes) then
    return M.MESSAGES, "rule"
  end
  if starts_with_any(id, self.responses_prefixes) then
    return M.RESPONSES, "rule"
  end
  return M.CHAT, "rule"
end

--- Which wire format serves a model.
---
--- Preference order: an explicit override, then the fetched catalogue, then the
--- documented rule. The reason comes back so a caller can tell an authoritative
--- answer from a fallback.
---@return string format
---@return string reason "override", "catalogue" or "rule"
function Base:format_for(model, override, fields)
  if override and override ~= "" then
    return override, "override"
  end

  local catalogue = self:catalogue(fields)
  if catalogue then
    local id = self:wire_model(model)
    for _, entry in ipairs(catalogue.models) do
      if entry.id == id then
        local format = M.choose_format(entry)
        if format then
          return format, "catalogue"
        end
      end
    end
  end

  return self:ruled_format(model)
end

-- ---------------------------------------------------------------------------
-- Transports
-- ---------------------------------------------------------------------------

--- Build a transport for a model.
---@return table|nil transport
---@return string|nil error
---@return table|nil detail { format, reason }
function Base:transport_for(fields)
  fields = fields or {}
  assert(type(fields.model) == "string" and fields.model ~= "", "transport_for needs a model")

  local format, reason = self:format_for(fields.model, fields.format, fields)

  local adapter_module = ADAPTERS[format]
  if not adapter_module then
    return nil,
      ('%s is served on the %s API, which is not implemented yet; %s is required. Set format = "%s" only if that is wrong.'):format(
        fields.model,
        format,
        FORMAT_ADAPTER[format] or "an adapter",
        M.CHAT
      ),
      { format = format, reason = reason }
  end

  local key, key_error = self:credential(fields)
  if not key then
    return nil, key_error, { format = format, reason = reason }
  end

  local base_url = fields.base_url or self.base_url
  if type(base_url) ~= "string" or base_url == "" then
    return nil, ("no base URL for %s"):format(self.name), nil
  end

  return require(adapter_module).new({
    base_url = base_url,
    api_key = key,
    model = self:wire_model(fields.model),
    session_header = fields.session_header ~= nil and fields.session_header or self.session_header,
    user_agent = fields.user_agent or self.user_agent,
    -- A provider may declare headers a gateway wants, and a caller may add more.
    -- Declared first, so a caller's entry of the same name comes later and wins.
    extra_headers = vim.list_extend(
      TransportBase.normalise_headers(self.headers),
      TransportBase.normalise_headers(fields.headers)
    ),
    execute = fields.execute,
  }),
    nil,
    { format = format, reason = reason, base_url = base_url }
end

--- Whether the provider could be used at all, without building anything.
---@return boolean ready
---@return string reason
function Base:available(fields)
  local key = select(1, self:credential(fields or {}))
  if not key then
    return false, ("no credential for %s"):format(self.name)
  end
  return true, "ready"
end

-- ---------------------------------------------------------------------------
-- Shared state
-- ---------------------------------------------------------------------------

--- Where cached catalogues live by default.
function M.default_cache_directory()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "agent-smith")
end

--- Forget in-memory catalogues. For tests, and for an explicit refresh.
function M.forget()
  memory = {}
end

M.Base = Base

return M
