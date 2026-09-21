return function(t)
  local Provider = require("agent-smith.providers")
  local Auth = require("agent-smith.auth")

  local zen = Provider.presets.zen
  local go = Provider.presets.go
  local commandcode = Provider.presets.commandcode

  --- Set an environment variable for the duration of `body`, then restore it.
  local function with_env(name, value, body)
    local previous = vim.env[name]
    vim.env[name] = value
    local ok, err = pcall(body)
    vim.env[name] = previous
    if not ok then
      error(err, 0)
    end
  end

  --- A fresh cache directory, and no memory of a previous catalogue.
  local function fresh_cache()
    Provider.forget()
    return vim.fn.tempname()
  end

  --- A process spawner that answers with a fixed body.
  local function responder(body, code)
    local record = { calls = 0 }
    record.execute = function(command, options)
      record.calls = record.calls + 1
      record.command = command
      record.env = options.env
      return {
        wait = function()
          return { code = code or 0, stdout = body, stderr = code and "failed" or "" }
        end,
      }
    end
    return record
  end

  --- A store with nothing in it, rooted somewhere disposable.
  ---
  --- Tests must never consult the real store. This one used to: the "nothing to
  --- set" case passed no store at all, so it read whatever this machine had stored
  --- and started failing once a credential existed.
  local function empty_store()
    local root = vim.fn.tempname()
    return Auth.new({
      auth_file = vim.fs.joinpath(root, "config", "auth.json"),
      key_file = vim.fs.joinpath(root, "data", "auth.key"),
    })
  end

  local function store_with(name, key)
    local store = empty_store()
    store:set(name, key)
    return store
  end

  --- A models body in CommandCode's shape, which carries routing.
  local COMMANDCODE_BODY = [[
{"object":"list","data":[
 {"id":"claude-sonnet-5","object":"model","created":1,"owned_by":"command-code","name":"Claude Sonnet 5","context_length":1000000,"supported_endpoints":["/messages"]},
 {"id":"deepseek-v4-flash","object":"model","created":1,"owned_by":"command-code","name":"DeepSeek V4 Flash","context_length":128000,"supported_endpoints":["/chat/completions","/responses"]},
 {"id":"kimi-k3","object":"model","created":1,"owned_by":"command-code","supported_endpoints":["/chat/completions"]}
]}
]]

  --- A models body in the OpenCode shape, which carries no routing.
  local OPENCODE_BODY = [[
{"object":"list","data":[
 {"id":"kimi-k3","object":"model","created":1,"owned_by":"opencode"},
 {"id":"gpt-5.6-sol","object":"model","created":1,"owned_by":"opencode"},
 {"id":"glm-5.3","object":"model","created":1,"owned_by":"opencode"}
]}
]]

  t.describe("provider presets", function()
    t.it("have a name and a base URL without a trailing slash", function()
      for name, preset in pairs(Provider.presets) do
        t.eq(type(preset.name), "string", name .. " needs a name")
        t.eq(preset.base_url:sub(-1) ~= "/", true, name .. " should not end in a slash")
      end
    end)

    t.it("hardcode no model ids", function()
      -- The list is fetched. Only routing prefixes are declared, and only for
      -- gateways that publish no routing of their own.
      for name, preset in pairs(Provider.presets) do
        t.eq(preset.models, nil, name .. " should not carry a model list")
      end
    end)

    t.it("share one credential between Zen and Go", function()
      t.eq(zen.auth_key, go.auth_key)
      t.eq(zen.env, go.env)
    end)

    t.it("declare routing rules only where the vendor publishes none", function()
      t.ok(zen.responses_prefixes, "Zen publishes no routing, so it needs a rule")
      t.ok(go.responses_prefixes)
      t.ok(commandcode.messages_prefixes, "CommandCode's offline fallback")
      t.eq(zen.messages_prefixes, nil)
    end)
  end)

  t.describe("provider.parse", function()
    t.it("reads routing from supported_endpoints", function()
      local models = Provider.parse(COMMANDCODE_BODY)
      t.eq(#models, 3)

      local by_id = {}
      for _, model in ipairs(models) do
        by_id[model.id] = model
      end

      t.eq(by_id["claude-sonnet-5"].endpoints, { Provider.MESSAGES })
      t.eq(by_id["deepseek-v4-flash"].endpoints, { Provider.CHAT, Provider.RESPONSES })
      t.eq(by_id["kimi-k3"].endpoints, { Provider.CHAT })
      t.eq(by_id["claude-sonnet-5"].context_length, 1000000)
    end)

    t.it("leaves endpoints empty when the vendor publishes none", function()
      local models = Provider.parse(OPENCODE_BODY)
      t.eq(#models, 3)
      t.eq(models[1].endpoints, {}, "no routing is not the same as no routes")
    end)

    t.it("sorts by id", function()
      local models = Provider.parse(OPENCODE_BODY)
      local ids = {}
      for _, model in ipairs(models) do
        ids[#ids + 1] = model.id
      end
      t.eq(ids, { "glm-5.3", "gpt-5.6-sol", "kimi-k3" })
    end)

    t.it("ignores an endpoint path it does not recognise", function()
      local models = Provider.parse([[{"data":[{"id":"x","supported_endpoints":["/chat/completions","/embeddings"]}]}]])
      t.eq(models[1].endpoints, { Provider.CHAT })
    end)

    t.it("rejects a body that is not JSON", function()
      local models, err = Provider.parse("<html>nope</html>")
      t.eq(models, nil)
      t.matches(err, "did not return JSON")
    end)

    t.it("rejects an empty list", function()
      local models, err = Provider.parse([[{"object":"list","data":[]}]])
      t.eq(models, nil)
      t.matches(err, "listed no models")
    end)

    t.it("rejects an empty body", function()
      local models, err = Provider.parse("")
      t.eq(models, nil)
      t.matches(err, "returned nothing")
    end)
  end)

  t.describe("provider.choose_format", function()
    t.it("prefers chat completions when it is offered", function()
      -- It is the adapter that exists, so a model offering both should not be
      -- routed to one that does not.
      t.eq(Provider.choose_format({ endpoints = { Provider.CHAT, Provider.RESPONSES } }), Provider.CHAT)
      t.eq(Provider.choose_format({ endpoints = { Provider.MESSAGES, Provider.CHAT } }), Provider.CHAT)
    end)

    t.it("falls back in order when chat is not offered", function()
      t.eq(Provider.choose_format({ endpoints = { Provider.RESPONSES } }), Provider.RESPONSES)
      t.eq(Provider.choose_format({ endpoints = { Provider.MESSAGES } }), Provider.MESSAGES)
    end)

    t.it("is nil when nothing is recognised", function()
      t.eq(Provider.choose_format({ endpoints = {} }), nil)
      t.eq(Provider.choose_format({}), nil)
      t.eq(Provider.choose_format(nil), nil)
    end)
  end)

  t.describe("provider.format_for: rules", function()
    t.it("routes a GPT model on Zen to responses", function()
      local format, reason = Provider.format_for(zen, "gpt-5.6-sol", nil, { cache_directory = fresh_cache() })
      t.eq(format, Provider.RESPONSES)
      t.eq(reason, "rule")
    end)

    t.it("routes an open model on Zen to chat", function()
      local format, reason = Provider.format_for(zen, "glm-5.3", nil, { cache_directory = fresh_cache() })
      t.eq(format, Provider.CHAT)
      t.eq(reason, "rule")
    end)

    t.it("routes Claude on Command Code to messages without a catalogue", function()
      -- The documented rule, so a stale cache cannot mis-route a Claude model to
      -- an endpoint that will refuse it.
      local format, reason = Provider.format_for(commandcode, "claude-sonnet-5", nil, { cache_directory = fresh_cache() })
      t.eq(format, Provider.MESSAGES)
      t.eq(reason, "rule")
    end)

    t.it("lets an override win", function()
      local format, reason = Provider.format_for(zen, "glm-5.3", Provider.RESPONSES, { cache_directory = fresh_cache() })
      t.eq(format, Provider.RESPONSES)
      t.eq(reason, "override")
    end)
  end)

  t.describe("provider.format_for: fetched catalogue", function()
    t.it("uses published routing when it is available", function()
      local directory = fresh_cache()
      local record = responder(COMMANDCODE_BODY)
      Provider.fetch(commandcode, { api_key = "k", execute = record.execute, cache_directory = directory })

      local format, reason = Provider.format_for(commandcode, "deepseek-v4-flash", nil, { cache_directory = directory })
      t.eq(format, Provider.CHAT)
      t.eq(reason, "catalogue")
    end)

    t.it("reports a model the gateway serves only on messages", function()
      local directory = fresh_cache()
      local record = responder(COMMANDCODE_BODY)
      Provider.fetch(commandcode, { api_key = "k", execute = record.execute, cache_directory = directory })

      local format, reason = Provider.format_for(commandcode, "claude-sonnet-5", nil, { cache_directory = directory })
      t.eq(format, Provider.MESSAGES)
      t.eq(reason, "catalogue")
    end)

    t.it("falls back to the rule for a model the catalogue omits", function()
      local directory = fresh_cache()
      local record = responder(COMMANDCODE_BODY)
      Provider.fetch(commandcode, { api_key = "k", execute = record.execute, cache_directory = directory })

      local _, reason = Provider.format_for(commandcode, "something-new", nil, { cache_directory = directory })
      t.eq(reason, "rule")
    end)

    t.it("matches a prefixed model id against the catalogue", function()
      local directory = fresh_cache()
      local record = responder(OPENCODE_BODY)
      Provider.fetch(zen, { api_key = "k", execute = record.execute, cache_directory = directory })

      local models = Provider.catalogue(zen, { cache_directory = directory })
      local found = false
      for _, model in ipairs(models.models) do
        if model.id == "gpt-5.6-sol" then
          found = true
        end
      end
      t.eq(found, true)
    end)
  end)

  t.describe("provider.fetch", function()
    t.it("parses a response and records when it arrived", function()
      local record = responder(OPENCODE_BODY)
      local result = Provider.fetch(zen, { api_key = "k", execute = record.execute, cache_directory = fresh_cache() })

      t.eq(#result.models, 3)
      t.eq(type(result.fetched_at), "number")
      t.eq(result.credential_rejected, false)
      t.eq(record.calls, 1)
    end)

    t.it("asks the models path on the preset's base URL", function()
      local record = responder(OPENCODE_BODY)
      Provider.fetch(zen, { api_key = "k", execute = record.execute, cache_directory = fresh_cache() })
      t.matches(record.command[3], "opencode%.ai/zen/v1/models")
    end)

    t.it("keeps the credential out of the argv", function()
      local record = responder(OPENCODE_BODY)
      Provider.fetch(zen, { api_key = "super-secret", execute = record.execute, cache_directory = fresh_cache() })

      for _, argument in ipairs(record.command) do
        t.eq(argument:find("super-secret", 1, true), nil, "the key must not appear in argv")
      end
      t.eq(record.env["AGENT_SMITH_API_KEY"], "super-secret", "it travels in the environment")
    end)

    t.it("reads from the cache on a second call", function()
      local directory = fresh_cache()
      local first = responder(OPENCODE_BODY)
      Provider.fetch(zen, { api_key = "k", execute = first.execute, cache_directory = directory })

      local second = responder(OPENCODE_BODY)
      local result = Provider.fetch(zen, { api_key = "k", execute = second.execute, cache_directory = directory })

      t.eq(second.calls, 0, "the cache should have answered")
      t.eq(#result.models, 3)
    end)

    t.it("refetches when asked to refresh", function()
      local directory = fresh_cache()
      Provider.fetch(zen, { api_key = "k", execute = responder(OPENCODE_BODY).execute, cache_directory = directory })

      local second = responder(OPENCODE_BODY)
      Provider.fetch(zen, { api_key = "k", refresh = true, execute = second.execute, cache_directory = directory })
      t.eq(second.calls, 1)
    end)

    t.it("ignores a cache older than its ttl", function()
      local directory = fresh_cache()
      Provider.fetch(zen, { api_key = "k", execute = responder(OPENCODE_BODY).execute, cache_directory = directory })

      -- A negative ttl makes any entry stale without waiting.
      Provider.forget()
      t.eq(Provider.read_cache(zen, { cache_directory = directory, ttl_ms = -1 }), nil)
    end)

    t.it("drops a cache from another version", function()
      local directory = fresh_cache()
      local path = vim.fs.joinpath(directory, "models-" .. vim.fn.sha256(zen.name):sub(1, 12) .. ".json")
      vim.fn.mkdir(directory, "p")
      vim.fn.writefile({ vim.json.encode({ version = 99, fetched_at = vim.uv.now(), models = {} }) }, path, "b")

      t.eq(Provider.read_cache(zen, { cache_directory = directory }), nil)
    end)

    t.it("retries without the credential when one is rejected", function()
      -- Measured: Zen answers 401 to a key it dislikes on a list that is public.
      local directory = fresh_cache()
      local calls = 0
      local execute = function(_, options)
        calls = calls + 1
        return {
          wait = function()
            if options.env["AGENT_SMITH_API_KEY"] ~= "" then
              return { code = 22, stdout = '{"error":{"message":"Invalid credential"}}', stderr = "" }
            end
            return { code = 0, stdout = OPENCODE_BODY, stderr = "" }
          end,
        }
      end

      local result = Provider.fetch(zen, { api_key = "stale-key", execute = execute, cache_directory = directory })
      t.eq(calls, 2, "it should try again without the key")
      t.eq(result.credential_rejected, true)
      t.eq(#result.models, 3)
    end)

    t.it("reports a failure that survives the retry", function()
      local record = responder("nope", 22)
      local models, err = Provider.fetch(zen, { execute = record.execute, cache_directory = fresh_cache() })
      t.eq(models, nil)
      t.matches(err, "could not fetch models")
    end)

    t.it("reports a body it cannot parse", function()
      local record = responder("<html>", 0)
      local models, err = Provider.fetch(zen, { execute = record.execute, cache_directory = fresh_cache() })
      t.eq(models, nil)
      t.matches(err, "did not return JSON")
    end)

    t.it("caches under the default directory when none is given", function()
      t.matches(Provider.default_cache_directory(), "agent%-smith$")
    end)
  end)

  t.describe("provider.credential", function()
    t.it("prefers an explicit key", function()
      with_env("OPENCODE_API_KEY", "from-environment", function()
        t.eq(Provider.credential(zen, { api_key = "explicit" }), "explicit")
      end)
    end)

    t.it("falls back to the environment", function()
      with_env("OPENCODE_API_KEY", "from-environment", function()
        t.eq(Provider.credential(zen, {}), "from-environment")
      end)
    end)

    t.it("falls back to the store", function()
      with_env("OPENCODE_API_KEY", nil, function()
        t.eq(Provider.credential(zen, { store = store_with("opencode", "from-store") }), "from-store")
      end)
    end)

    t.it("explains what to set when there is nothing", function()
      with_env("OPENCODE_API_KEY", nil, function()
        local key, err = Provider.credential(zen, { store = empty_store() })
        t.eq(key, nil)
        t.matches(err, "OPENCODE_API_KEY")
        t.matches(err, "OpenCode Zen")
      end)
    end)
  end)

  t.describe("provider.transport_for", function()
    local function capture()
      local record = {}
      record.execute = function(_, options)
        record.stdin = options.stdin
        return { kill = function() end }
      end
      return record
    end

    t.it("builds a transport for a chat model", function()
      local transport, err = Provider.transport_for({
        provider = "zen",
        model = "glm-5.3",
        api_key = "k",
        cache_directory = fresh_cache(),
      })
      t.eq(err, nil)
      t.eq(type(transport.run), "function")
    end)

    t.it("serves a Command Code model that supports chat completions", function()
      -- 55 of its 71 models support it. A hardcoded catalogue refused these.
      local directory = fresh_cache()
      Provider.fetch(commandcode, {
        api_key = "k",
        execute = responder(COMMANDCODE_BODY).execute,
        cache_directory = directory,
      })

      local transport, err = Provider.transport_for({
        provider = "commandcode",
        model = "deepseek-v4-flash",
        api_key = "k",
        cache_directory = directory,
      })
      t.eq(err, nil)
      t.eq(type(transport.run), "function")
    end)

    t.it("serves a Claude model on messages now that the adapter exists", function()
      -- This used to be refused: Claude is served on /v1/messages only, so without
      -- the third adapter it was unreachable.
      local directory = fresh_cache()
      Provider.fetch(commandcode, {
        api_key = "k",
        execute = responder(COMMANDCODE_BODY).execute,
        cache_directory = directory,
      })

      local transport, err, detail = Provider.transport_for({
        provider = "commandcode",
        model = "claude-sonnet-5",
        api_key = "k",
        cache_directory = directory,
      })

      t.eq(err, nil)
      t.eq(type(transport.run), "function")
      t.eq(detail.format, Provider.MESSAGES)
    end)

    t.it("serves a GPT model on Zen now that responses exists", function()
      -- This used to be refused: the GPT-family models are not on chat
      -- completions, so without the second adapter they were unreachable.
      local transport, err, detail = Provider.transport_for({
        provider = "zen",
        model = "gpt-5.6-sol",
        api_key = "k",
        cache_directory = fresh_cache(),
      })
      t.eq(err, nil)
      t.eq(type(transport.run), "function")
      t.eq(detail.format, Provider.RESPONSES)
    end)

    t.it("sends the model id without the provider prefix", function()
      local record = capture()
      local transport = Provider.transport_for({
        provider = "zen",
        model = "opencode/glm-5.3",
        api_key = "k",
        execute = record.execute,
        cache_directory = fresh_cache(),
      })

      transport.run({ system = "", messages = {}, tools = {} }, function() end)
      t.matches(record.stdin, '"model":"glm%-5%.3"')
    end)

    t.it("accepts a custom provider with a base URL", function()
      local transport = Provider.transport_for({
        provider = { name = "Local", base_url = "http://127.0.0.1:11434/v1" },
        model = "llama3",
        api_key = "unused",
      })
      t.eq(type(transport.run), "function")
    end)

    t.it("reports an unknown provider", function()
      local transport, err = Provider.transport_for({ provider = "nope", model = "m", api_key = "k" })
      t.eq(transport, nil)
      t.matches(err, "unknown provider")
    end)

    t.it("requires a model", function()
      t.raises(function()
        Provider.transport_for({ provider = "zen", api_key = "k" })
      end, "needs a model")
    end)
  end)

  t.describe("provider.available", function()
    t.it("is ready with a credential", function()
      local ready, reason = Provider.available("zen", { api_key = "k" })
      t.eq(ready, true)
      t.eq(reason, "ready")
    end)

    t.it("is not ready without one", function()
      with_env("OPENCODE_API_KEY", nil, function()
        local ready, reason = Provider.available("zen", { store = store_with("nothing", "x") })
        t.eq(ready, false)
        t.matches(reason, "no credential")
      end)
    end)
  end)
end
