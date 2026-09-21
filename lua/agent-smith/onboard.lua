--- Interactive configuration: a credential, or a model.
---
--- Two flows that share one shape: choose something from a picker, act on the
--- choice, report what happened. `run` stores a credential; `choose_model` picks a
--- model and remembers it.
---
--- `setup()` takes configuration but no credential, so before this the only way to
--- store one was to call the auth store from Lua. That is fine once you know the
--- API and unpleasant when you do not, which is the wrong shape for the very first
--- thing a new user has to do.
---
--- Four decisions worth stating, because they are what make it a flow rather than
--- a prompt:
---
--- **The key is checked before it is stored.** A stored key that does not work is
--- worse than none, because it fails later, somewhere unrelated, with the vendor
--- talking about a model rather than about the credential. The check reuses the
--- model fetch, which already distinguishes "the gateway rejected this key" from
--- "the catalogue is unreachable" — so it costs no new request logic.
---
--- **A rejected key is not stored.** Nothing is written on failure, so a typo
--- leaves any previous credential alone instead of replacing it with a broken one.
---
--- **What could not be checked is said out loud.** Command Code's model list is
--- public, so its gateway returns a catalogue whether or not the key is any good,
--- and there is nothing to tell a good key from a bad one until a real request.
--- Reporting that as verified would be a lie, so the flow says it could not tell.
---
--- **A credential in the environment shadows the store.** `Base:credential` checks
--- the environment first, so storing a key while a stale variable is exported
--- changes nothing at all. That is exactly the kind of silent no-op a setup flow
--- should surface, so it does.

local Auth = require("agent-smith.auth")
local Providers = require("agent-smith.providers")

local M = {}

--- How each wire format is named in a picker, where "chat" reads better than
--- "chat completions" and fits on a line.
local ROUTES = {
  [Providers.CHAT] = "chat",
  [Providers.RESPONSES] = "responses",
  [Providers.MESSAGES] = "messages",
}

--- Whether a model speaks the chat-completions shape.
---
--- Preferred for a suggestion because every preset serves it. An entry with no
--- endpoints publishes no routing at all rather than no routes, so it is worth
--- suggesting too — see the note in providers/base.lua.
local function usable(model)
  local endpoints = model.endpoints or {}
  if #endpoints == 0 then
    return true
  end
  for _, endpoint in ipairs(endpoints) do
    if endpoint == Providers.CHAT then
      return true
    end
  end
  return false
end

--- A model id to put in the setup snippet, or nil.
---
--- Prefers one on chat completions, then falls back to whatever is first, so the
--- suggestion is useful even when a catalogue publishes no routing.
---@param models table|nil The fetch result's model list.
---@return string|nil
function M.suggest_model(models)
  if type(models) ~= "table" then
    return nil
  end

  local first = nil
  for _, model in ipairs(models) do
    if type(model) == "table" and type(model.id) == "string" and model.id ~= "" then
      first = first or model.id
      if usable(model) then
        return model.id
      end
    end
  end

  return first
end

--- The providers to offer, with whether each already has a credential.
---
--- One entry per preset, so the list cannot go stale as providers are added.
---@param store table|nil Defaults to the real store.
---@return table[] { name, label, has_credential }
function M.choices(store)
  store = store or Auth.new()

  local choices = {}
  for _, name in ipairs(Providers.names()) do
    local preset = Providers.get(name)

    -- A store that cannot be read is reported elsewhere; here it only means "no
    -- credential", and failing the whole flow over a label would be wrong.
    local has_credential = false
    if preset.auth_key then
      local ok, stored = pcall(function()
        return store:get(preset.auth_key)
      end)
      has_credential = ok and stored ~= nil and stored ~= ""
    end

    choices[#choices + 1] = {
      name = name,
      label = ("%s — %s"):format(preset.name, has_credential and "credential stored" or "no credential"),
      has_credential = has_credential,
    }
  end

  return choices
end

--- The `setup()` call to paste, with the provider and a suggested model.
---@return string
function M.snippet(name, model)
  return table.concat({
    'require("agent-smith").setup({',
    ('  provider = %q,'):format(name),
    ('  model = %q,'):format(model or "MODEL_ID"),
    "})",
  }, "\n")
end

--- The prompt shown while asking for a key.
---
--- Names the environment variable as well, because that is a legitimate way to do
--- this and the flow should not pretend its own store is the only one.
function M.key_prompt(preset)
  local how = ("paste the API key for %s (hidden)"):format(preset.name)
  if preset.env then
    return ("agent-smith: %s, or set %s and cancel: "):format(how, preset.env)
  end
  return ("agent-smith: %s: "):format(how)
end

local function default_select(items, options, on_choice)
  vim.ui.select(items, options, on_choice)
end

local function default_input(prompt)
  local value = vim.fn.inputsecret(prompt)
  if value == "" then
    return nil
  end
  return value
end

--- The one exit both flows use: the same thing to the user and to the caller.
---@return fun(ok: boolean, message: string|nil, info: table|nil)
local function reporter(fields)
  local notify = fields.notify
    or function(message, level)
      vim.notify(message, level or vim.log.levels.INFO)
    end

  return function(ok, message, info)
    if message then
      notify(message, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
    end
    if fields.on_done then
      fields.on_done(ok, message, info)
    end
  end
end

--- A context window, shortened: 1000000 becomes "1M", 128000 becomes "128k".
---@param length number|nil
---@return string|nil
function M.format_context(length)
  if type(length) ~= "number" or length <= 0 then
    return nil
  end
  if length >= 1000000 then
    return ("%gM"):format(length / 1000000)
  end
  if length >= 1000 then
    return ("%gk"):format(length / 1000)
  end
  return tostring(length)
end

--- The models to offer, best first.
---
--- Ordered by whether the model speaks chat completions and then alphabetically.
--- Usable first because every preset serves that shape, so the top of the list is
--- where a working choice is; alphabetical within each group so the order does not
--- shuffle between fetches.
---
--- The route and the context window are in the label because a model id alone does
--- not say whether it can be talked to, and choosing one that cannot is the most
--- likely way to get a confusing failure.
---@param models table|nil The fetch result's model list.
---@param current string|nil Marked in the label.
---@return table[] { id, label, usable, is_current }
function M.model_choices(models, current)
  local choices = {}

  for _, model in ipairs(models or {}) do
    if type(model) == "table" and type(model.id) == "string" and model.id ~= "" then
      local routes = {}
      for _, endpoint in ipairs(model.endpoints or {}) do
        routes[#routes + 1] = ROUTES[endpoint] or endpoint
      end

      local details = {}
      if #routes > 0 then
        details[#details + 1] = table.concat(routes, ", ")
      end
      local context = M.format_context(model.context_length)
      if context then
        details[#details + 1] = context
      end

      local label = model.id
      if #details > 0 then
        label = label .. "  —  " .. table.concat(details, " · ")
      end
      if model.id == current then
        label = label .. "   (current)"
      end

      choices[#choices + 1] = {
        id = model.id,
        label = label,
        usable = usable(model),
        is_current = model.id == current,
      }
    end
  end

  table.sort(choices, function(a, b)
    if a.usable ~= b.usable then
      return a.usable
    end
    return a.id < b.id
  end)

  return choices
end

--- The fetch fields both pickers pass through, so a test can inject either flow
--- the same way.
local function fetch_fields(fields)
  return {
    execute = fields.execute,
    cache_directory = fields.cache_directory,
    refresh = fields.refresh,
  }
end

--- The entry that undoes a session override.
---
--- Offered by both pickers, because an override that can only be undone by
--- restarting Neovim is worse than no picker at all. It restores both halves at
--- once: a model id only means anything against the provider that serves it, so
--- they are a single choice, not two.
local function clear_entry()
  return {
    clear = true,
    label = "— go back to what setup() configured —",
  }
end

--- Choose a model from the provider's catalogue and remember it.
---
--- The list is the provider's own, so anything offered is routable by
--- construction, which is the whole reason to pick from it rather than type an id.
--- It comes from the on-disk catalogue cache when there is one, so opening the
--- picker is not a network round trip every time.
---
---@param fields table|nil
---   - provider: string|nil        Defaults to the configured provider.
---   - config: table|nil           The resolved configuration.
---   - session: table|nil          This session's override, offered up for undo.
---   - select: fun(items, opts, on_choice)|nil
---   - notify: fun(message, level)|nil
---   - execute: fun|nil            For the catalogue fetch, for tests.
---   - cache_directory: string|nil For the catalogue fetch, for tests.
---   - refresh: boolean|nil        Ignore the catalogue cache.
---   - on_done: fun(ok, message, info)|nil
---@return nil
function M.choose_model(fields)
  fields = fields or {}
  local finish = reporter(fields)
  local pick = fields.select or default_select

  local config = fields.config or {}
  local provider = fields.provider or config.provider
  if not provider then
    return finish(
      false,
      "agent-smith: no provider is configured, so there is no catalogue to choose from. Run :Smith setup first."
    )
  end

  local result, fetch_error = Providers.fetch(provider, fetch_fields(fields))
  if not result then
    return finish(
      false,
      ("agent-smith: could not list the models for %s — %s"):format(tostring(provider), tostring(fetch_error))
    )
  end

  local choices = M.model_choices(result.models, fields.current or config.model)
  if #choices == 0 then
    return finish(false, ("agent-smith: %s published no models to choose from"):format(tostring(provider)))
  end

  -- A way back, offered only when there is something to undo. A session override
  -- should not be a one-way door either.
  if fields.session then
    table.insert(choices, 1, clear_entry())
  end

  pick(choices, {
    prompt = ("agent-smith: which model on %s?"):format(tostring(provider)),
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if not choice then
      return finish(false, "agent-smith: cancelled, so the model is unchanged")
    end

    if choice.clear then
      return finish(true, "agent-smith: back to the configured model, for this session.", { cleared = true })
    end

    finish(
      true,
      table.concat({
        ("agent-smith: model set to %s on %s, for this session."):format(choice.id, tostring(provider)),
        "  setup() is untouched, and restarting Neovim goes back to it.",
      }, "\n"),
      { provider = provider, model = choice.id }
    )
  end)
end

--- Choose which provider to use, and remember it.
---
--- Wider than the model picker and deliberately so: choosing a provider can
--- invalidate the current model, because a model id only means something against
--- the provider that serves it. Rather than leave that to fail at request time,
--- the model is checked against the new catalogue and the model picker is opened
--- when it does not belong there. One command should not be able to leave you in a
--- state that cannot work.
---
---@param fields table|nil
---   - config: table|nil           The resolved configuration.
---   - picked: table|nil           The existing pick, offered up for undo.
---   - store: table|nil            Injected, for credential status and tests.
---   - state_path: string|nil      Injected, for tests.
---   - select: fun(items, opts, on_choice)|nil
---   - notify: fun(message, level)|nil
---   - execute: fun|nil            For the catalogue fetch, for tests.
---   - cache_directory: string|nil For the catalogue fetch, for tests.
---   - refresh: boolean|nil        Ignore the catalogue cache.
---   - on_done: fun(ok, message, info)|nil
---@return nil
function M.choose_provider(fields)
  fields = fields or {}
  local finish = reporter(fields)
  local pick = fields.select or default_select
  local config = fields.config or {}
  local store = fields.store or Auth.new()

  local choices = M.choices(store)
  if fields.session then
    table.insert(choices, 1, clear_entry())
  end

  pick(choices, {
    prompt = "agent-smith: which provider?",
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if not choice then
      return finish(false, "agent-smith: cancelled, so the provider is unchanged")
    end

    if choice.clear then
      return finish(true, "agent-smith: back to the configured provider, for this session.", { cleared = true })
    end

    local name = choice.name
    local preset = Providers.get(name)

    -- The catalogue answers two questions at once: whether this provider can be
    -- talked to at all, and whether the current model belongs to it.
    local result = Providers.fetch(name, fetch_fields(fields))

    local served = nil
    if result then
      served = false
      for _, model in ipairs(result.models or {}) do
        if model.id == config.model then
          served = true
          break
        end
      end
    end

    -- The current model is not on the new provider, so pick one now rather than
    -- leaving a run to fail later with a routing error.
    if served == false then
      return M.choose_model({
        provider = name,
        config = { provider = name, model = config.model },
        session = { provider = name, model = config.model },
        store = store,
        select = fields.select,
        notify = fields.notify,
        execute = fields.execute,
        cache_directory = fields.cache_directory,
        refresh = fields.refresh,
        on_done = finish,
      })
    end

    local lines = {
      ("agent-smith: provider set to %s, for this session."):format(name),
      "  setup() is untouched, and restarting Neovim goes back to it.",
    }

    if not choice.has_credential and preset and preset.env and not (vim.env[preset.env] and vim.env[preset.env] ~= "") then
      lines[#lines + 1] = ("  No credential for it yet: run :Smith setup %s before a run will work."):format(name)
    end

    if served == nil then
      lines[#lines + 1] = "  Its models could not be listed, so the current model was not checked against it."
    end

    finish(true, table.concat(lines, "\n"), { provider = name, model = config.model, served = served })
  end)
end

--- Run the flow.
---
--- Asynchronous, because `vim.ui.select` is: a user's picker may be a floating
--- picker rather than a blocking list, so the choice arrives through a callback.
---
---@param fields table|nil
---   - provider: string|nil         Skip the picker.
---   - key: string|nil              Skip the secret prompt.
---   - store: table|nil             Injected, for tests.
---   - select: fun(items, opts, on_choice)|nil
---   - input: fun(prompt) -> string|nil
---   - notify: fun(message, level)|nil
---   - execute: fun|nil             For the model fetch, for tests.
---   - cache_directory: string|nil  For the model fetch, for tests.
---   - on_done: fun(ok, message, info)|nil
---@return nil
function M.run(fields)
  fields = fields or {}

  local notify = fields.notify
    or function(message, level)
      vim.notify(message, level or vim.log.levels.INFO)
    end
  local pick = fields.select or default_select
  local ask = fields.input or default_input
  local store = fields.store or Auth.new()
  local finish = reporter(fields)

  --- Step 2 onward: a provider has been chosen.
  local function with_provider(name)
    local preset = Providers.get(name)
    if not preset then
      return finish(false, ("agent-smith: no provider named %q"):format(tostring(name)))
    end

    local key = fields.key
    if key == nil then
      key = ask(M.key_prompt(preset))
      if key == nil or vim.trim(key) == "" then
        return finish(false, "agent-smith: no key entered, so nothing was changed")
      end
    end
    key = vim.trim(key)

    -- Checking, not just fetching: the same call answers both questions, and a
    -- refresh so a cached catalogue cannot stand in for a live answer.
    notify(("agent-smith: checking the key against %s…"):format(preset.name), vim.log.levels.INFO)

    local result, fetch_error = Providers.fetch(name, {
      api_key = key,
      refresh = true,
      execute = fields.execute,
      cache_directory = fields.cache_directory,
    })

    if not result then
      return finish(
        false,
        ("agent-smith: could not reach %s, so nothing was stored — %s"):format(preset.name, tostring(fetch_error))
      )
    end

    if result.credential_rejected then
      return finish(
        false,
        ("agent-smith: %s rejected that key, so nothing was stored. Check it and try again."):format(preset.name)
      )
    end

    local stored, store_error = store:set(preset.auth_key or name, key)
    if not stored then
      return finish(false, ("agent-smith: could not store the credential — %s"):format(tostring(store_error)))
    end

    local model = M.suggest_model(result.models)
    local lines = {
      ("agent-smith: stored an encrypted credential for %s."):format(preset.name),
    }

    -- Said plainly rather than dressed up as a pass: a public catalogue cannot
    -- distinguish a good key from a bad one.
    if #(result.models or {}) > 0 and (preset.auth_key == "commandcode") then
      lines[#lines + 1] = "  The model list is public, so the key itself could not be confirmed here."
      lines[#lines + 1] = "  The first request will be the real test."
    end

    if preset.env and vim.env[preset.env] and vim.env[preset.env] ~= "" then
      lines[#lines + 1] = ("  Note: %s is set in your environment and takes precedence over the store."):format(
        preset.env
      )
      lines[#lines + 1] = "  Unset it, or the stored credential will not be used."
    end

    local tracked, directory = store:key_is_tracked()
    if tracked then
      lines[#lines + 1] = ("  Warning: the key file is inside the git work tree at %s."):format(tostring(directory))
      lines[#lines + 1] = "  Move it, or that repository will carry the key that decrypts your credentials."
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Next, put this in your config:"
    for _, line in ipairs(vim.split(M.snippet(name, model), "\n", { plain = true })) do
      lines[#lines + 1] = "    " .. line
    end

    finish(true, table.concat(lines, "\n"), { provider = name, model = model })
  end

  -- Step 1: which provider.
  if fields.provider then
    return with_provider(fields.provider)
  end

  local choices = M.choices(store)
  pick(choices, {
    prompt = "agent-smith: which provider?",
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if not choice then
      return finish(false, "agent-smith: cancelled")
    end
    with_provider(choice.name)
  end)
end

return M
