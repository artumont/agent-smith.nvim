return function(t)
  local Onboard = require("agent-smith.onboard")

  --- A catalogue where the first entry cannot be chatted to, so the suggestion has
  --- something to prefer.
  local BODY = table.concat({
    '{"data":[',
    '{"id":"claude-sonnet-5","object":"model","owned_by":"x","supported_endpoints":["/messages"]},',
    '{"id":"deepseek-v4-flash","object":"model","owned_by":"x","supported_endpoints":["/chat/completions","/responses"]},',
    '{"id":"kimi-k3","object":"model","owned_by":"x"}',
    "]}",
  }, "")

  --- A vim.system stand-in that answers every models request the same way.
  local function responder(body)
    local record = { calls = 0 }
    local function execute()
      record.calls = record.calls + 1
      return {
        wait = function()
          return { code = 0, stdout = body, stderr = "" }
        end,
      }
    end
    return execute, record
  end

  --- A gateway that requires a key: the attempt with one fails, the retry without
  --- it succeeds. That is how `fetch` learns a credential was rejected.
  local function rejector(body)
    local record = { calls = 0 }
    local function execute()
      record.calls = record.calls + 1
      if record.calls == 1 then
        return {
          wait = function()
            return { code = 22, stdout = "", stderr = "401 unauthorized" }
          end,
        }
      end
      return {
        wait = function()
          return { code = 0, stdout = body, stderr = "" }
        end,
      }
    end
    return execute, record
  end

  --- A store that records what it was asked to do.
  local function fake_store(fields)
    fields = fields or {}
    local record = { sets = {}, removed = {} }
    return setmetatable(record, {
      __index = {
        get = function(_, name)
          return fields.credentials and fields.credentials[name] or nil
        end,
        set = function(_, name, key)
          record.sets[#record.sets + 1] = { name = name, key = key }
          if fields.fail then
            return false, "disk on fire"
          end
          return true
        end,
        remove = function(_, name)
          record.removed[#record.removed + 1] = name
          return true
        end,
        key_is_tracked = function()
          return fields.tracked == true, fields.tracked and "/somewhere" or nil
        end,
      },
    })
  end

  --- Run the flow with everything injected, and collect what it reported.
  local function run(fields)
    fields = fields or {}
    local record = { notifications = {}, results = {} }

    Onboard.run({
      provider = fields.provider,
      key = fields.key,
      store = fields.store or fake_store(),
      select = fields.select or function(items, _, on_choice)
        on_choice(items[fields.pick or 1])
      end,
      input = fields.input or function()
        return fields.typed
      end,
      notify = function(message, level)
        record.notifications[#record.notifications + 1] = { message = message, level = level }
      end,
      execute = fields.execute,
      cache_directory = fields.cache_directory or vim.fn.tempname(),
      on_done = function(ok, message, info)
        record.results[#record.results + 1] = { ok = ok, message = message, info = info }
      end,
    })

    t.settle(function()
      return #record.results > 0
    end, 500)

    record.ok = record.results[1] and record.results[1].ok
    record.message = record.results[1] and record.results[1].message
    record.info = record.results[1] and record.results[1].info
    record.all = table.concat(
      vim.tbl_map(function(entry)
        return entry.message
      end, record.notifications),
      "\n"
    )
    return record
  end

  t.describe("onboard.suggest_model", function()
    t.it("prefers a model that speaks chat completions", function()
      local models = {
        { id = "claude-sonnet-5", endpoints = { "messages" } },
        { id = "deepseek-v4-flash", endpoints = { "chat", "responses" } },
      }
      t.eq(Onboard.suggest_model(models), "deepseek-v4-flash")
    end)

    t.it("falls back to the first model when none publishes chat", function()
      local models = {
        { id = "claude-sonnet-5", endpoints = { "messages" } },
        { id = "claude-opus-5", endpoints = { "messages" } },
      }
      t.eq(Onboard.suggest_model(models), "claude-sonnet-5")
    end)

    t.it("accepts a model that publishes no routing at all", function()
      -- An entry with no endpoints is one whose routing is unknown, not one with
      -- no routes, so it is still worth suggesting.
      t.eq(Onboard.suggest_model({ { id = "kimi-k3", endpoints = {} } }), "kimi-k3")
    end)

    t.it("returns nothing rather than a broken id", function()
      t.eq(Onboard.suggest_model(nil), nil)
      t.eq(Onboard.suggest_model({}), nil)
      t.eq(Onboard.suggest_model({ { name = "no id here" } }), nil)
    end)
  end)

  t.describe("onboard.choices", function()
    t.it("offers every preset, and says which already have a credential", function()
      local choices = Onboard.choices(fake_store({ credentials = { commandcode = "stored" } }))
      t.eq(#choices, #require("agent-smith.providers").names())

      local by_name = {}
      for _, choice in ipairs(choices) do
        by_name[choice.name] = choice
      end
      t.ok(by_name.commandcode.has_credential, "commandcode has one")
      t.eq(by_name.zen.has_credential, false)
      t.matches(by_name.commandcode.label, "credential stored")
      t.matches(by_name.zen.label, "no credential")
    end)

    t.it("treats an unreadable store as simply having no credential", function()
      -- Failing the whole flow over a label would be wrong.
      local broken = setmetatable({}, {
        __index = {
          get = function()
            error("cannot decrypt")
          end,
        },
      })
      local choices = Onboard.choices(broken)
      t.eq(#choices, #require("agent-smith.providers").names())
      t.eq(choices[1].has_credential, false)
    end)
  end)

  t.describe("onboard.snippet", function()
    t.it("is a pasteable setup call", function()
      local snippet = Onboard.snippet("commandcode", "deepseek-v4-flash")
      t.matches(snippet, 'provider = "commandcode"')
      t.matches(snippet, 'model = "deepseek%-v4%-flash"')
      t.matches(snippet, "setup%(")
    end)

    t.it("leaves a placeholder when there is no model to suggest", function()
      t.matches(Onboard.snippet("zen", nil), "MODEL_ID")
    end)
  end)

  t.describe("onboard.key_prompt", function()
    t.it("names the environment variable, because that is a real alternative", function()
      local prompt = Onboard.key_prompt(require("agent-smith.providers").get("commandcode"))
      t.matches(prompt, "CMD_API_KEY")
      t.matches(prompt, "Command Code")
    end)
  end)

  t.describe("onboard.run", function()
    t.it("stores the key and prints a snippet", function()
      local store = fake_store()
      local execute = responder(BODY)
      local record = run({ provider = "commandcode", key = "  sk-test  ", store = store, execute = execute })

      t.eq(record.ok, true)
      -- Trimmed, because a pasted key arrives with whitespace more often than not.
      t.eq(store.sets[1].name, "commandcode")
      t.eq(store.sets[1].key, "sk-test")

      t.matches(record.all, "stored an encrypted credential")
      t.matches(record.all, 'provider = "commandcode"')
      -- The suggestion came from the live catalogue, not a hardcoded list.
      t.matches(record.all, "deepseek%-v4%-flash")
      t.eq(record.info.model, "deepseek-v4-flash")
    end)

    t.it("does not store a key the gateway rejected", function()
      local store = fake_store()
      local record = run({
        provider = "commandcode",
        key = "bad",
        store = store,
        execute = rejector(BODY),
      })

      t.eq(record.ok, false)
      t.eq(#store.sets, 0, "nothing should be written on a rejection")
      t.matches(record.message, "rejected that key")
    end)

    t.it("does not store anything when the provider cannot be reached", function()
      local store = fake_store()
      local failing = function()
        return {
          wait = function()
            return { code = 7, stdout = "", stderr = "could not resolve host" }
          end,
        }
      end

      local record = run({ provider = "commandcode", key = "k", store = store, execute = failing })
      t.eq(record.ok, false)
      t.eq(#store.sets, 0)
      t.matches(record.message, "could not reach")
    end)

    t.it("reports a store that refuses to write", function()
      local store = fake_store({ fail = true })
      local record = run({ provider = "commandcode", key = "k", store = store, execute = responder(BODY) })
      t.eq(record.ok, false)
      t.matches(record.message, "could not store")
    end)

    t.it("says the key could not be confirmed on a public catalogue", function()
      -- Command Code's model list is public, so a catalogue is returned whether or
      -- not the key is any good. Reporting that as verified would be a lie.
      local record = run({ provider = "commandcode", key = "k", execute = responder(BODY) })
      t.eq(record.ok, true)
      t.matches(record.all, "could not be confirmed")
    end)

    t.it("warns when an environment variable will shadow the stored key", function()
      -- Base:credential checks the environment first, so storing a key while a
      -- stale variable is exported changes nothing.
      local previous = vim.env.CMD_API_KEY
      vim.env.CMD_API_KEY = "from-the-environment"
      local record = run({ provider = "commandcode", key = "k", execute = responder(BODY) })
      if previous == nil then
        vim.env.CMD_API_KEY = nil
      else
        vim.env.CMD_API_KEY = previous
      end

      t.eq(record.ok, true, "it still stores; the warning is the point")
      t.matches(record.all, "takes precedence")
    end)

    t.it("warns when the key file is inside a git work tree", function()
      local record = run({
        provider = "commandcode",
        key = "k",
        store = fake_store({ tracked = true }),
        execute = responder(BODY),
      })
      t.matches(record.all, "git work tree")
    end)

    t.it("asks which provider when none was given", function()
      local store = fake_store()
      -- Seeded rather than nil so the shape is known, and overwritten by the picker.
      local asked = { items = {}, prompt = "" }

      local record = run({
        store = store,
        key = "k",
        execute = responder(BODY),
        -- The prompt goes to the picker, not to a notification, so it is recorded
        -- from there.
        select = function(items, options, on_choice)
          asked = { items = items, prompt = options.prompt }
          on_choice(items[1])
        end,
      })

      t.eq(record.ok, true)
      t.eq(#store.sets, 1, "one credential was stored")
      t.matches(asked.prompt, "which provider")
      t.eq(#asked.items, #require("agent-smith.providers").names(), "every preset is offered")
      t.eq(store.sets[1].name, "commandcode", "and the chosen one is the one stored")
    end)

    t.it("changes nothing when the picker is cancelled", function()
      local store = fake_store()
      local record = run({
        store = store,
        key = "k",
        select = function(_, _, on_choice)
          on_choice(nil)
        end,
      })

      t.eq(record.ok, false)
      t.eq(#store.sets, 0)
      t.matches(record.message, "cancelled")
    end)

    t.it("changes nothing when no key is typed", function()
      local store = fake_store()
      local record = run({ provider = "commandcode", typed = nil, store = store })

      t.eq(record.ok, false)
      t.eq(#store.sets, 0)
      t.matches(record.message, "no key entered")
    end)

    t.it("rejects an unknown provider", function()
      local record = run({ provider = "nope", key = "k" })
      t.eq(record.ok, false)
      t.matches(record.message, "no provider named")
    end)
  end)

  t.describe("onboard: the command", function()
    t.it("offers setup and model as subcommands", function()
      local smith = require("agent-smith")
      -- Isolated state, so a model picked on this machine cannot change what this
      -- test sees.
      smith.setup({ state = { path = vim.fs.joinpath(vim.fn.tempname(), "state.json") } })

      local completion = vim.fn.getcompletion("Smith ", "cmdline")
      t.ok(vim.tbl_contains(completion, "setup"), "expected setup in " .. vim.inspect(completion))
      t.ok(vim.tbl_contains(completion, "model"), "expected model in " .. vim.inspect(completion))
    end)

    t.it("exposes both flows on the public API", function()
      t.eq(type(require("agent-smith").onboard), "function")
      t.eq(type(require("agent-smith").choose_model), "function")
    end)
  end)

  t.describe("onboard.format_context", function()
    t.it("shortens a context window", function()
      t.eq(Onboard.format_context(1000000), "1M")
      t.eq(Onboard.format_context(128000), "128k")
      t.eq(Onboard.format_context(512), "512")
    end)

    t.it("returns nothing when there is nothing to say", function()
      t.eq(Onboard.format_context(nil), nil)
      t.eq(Onboard.format_context(0), nil)
      t.eq(Onboard.format_context("128k"), nil)
    end)
  end)

  t.describe("onboard.model_choices", function()
    local MODELS = {
      { id = "claude-sonnet-5", endpoints = { "messages" }, context_length = 1000000 },
      { id = "deepseek-v4-flash", endpoints = { "chat", "responses" }, context_length = 128000 },
      { id = "kimi-k3", endpoints = { "chat" } },
      { id = "", endpoints = {} },
      { name = "no id at all" },
    }

    t.it("puts the ones that can actually be chatted to first", function()
      -- Choosing a model that cannot be talked to is the most likely way to get a
      -- confusing failure, so the usable ones lead.
      local choices = Onboard.model_choices(MODELS, nil)
      t.eq(choices[1].id, "deepseek-v4-flash")
      t.eq(choices[2].id, "kimi-k3")
      t.eq(choices[3].id, "claude-sonnet-5")
    end)

    t.it("skips entries with no usable id", function()
      t.eq(#Onboard.model_choices(MODELS, nil), 3)
      t.eq(#Onboard.model_choices({}, nil), 0)
      t.eq(#Onboard.model_choices(nil, nil), 0)
    end)

    t.it("shows the route and the context window", function()
      local choices = Onboard.model_choices(MODELS, nil)
      t.matches(choices[1].label, "chat, responses")
      t.matches(choices[1].label, "128k")
      t.matches(choices[3].label, "messages")
      t.matches(choices[3].label, "1M")
    end)

    t.it("marks the current model", function()
      local by_id = {}
      for _, choice in ipairs(Onboard.model_choices(MODELS, "kimi-k3")) do
        by_id[choice.id] = choice
      end

      t.eq(by_id["kimi-k3"].is_current, true)
      t.matches(by_id["kimi-k3"].label, "%(current%)")
      t.eq(by_id["claude-sonnet-5"].is_current, false)
    end)
  end)

  t.describe("onboard.choose_model", function()
    --- Run the picker with everything injected, and collect what it reported.
    local function choose(fields)
      fields = fields or {}
      local record = { notifications = {}, results = {}, asked = {} }

      Onboard.choose_model({
        provider = fields.provider,
        config = fields.config or { provider = "commandcode", model = "configured" },
        session = fields.session,
        select = function(items, options, on_choice)
          record.asked[#record.asked + 1] = {
            items = items,
            prompt = options.prompt,
            format = options.format_item,
          }
          on_choice(fields.choose and items[fields.choose] or nil)
        end,
        notify = function(message)
          record.notifications[#record.notifications + 1] = message
        end,
        execute = fields.execute or responder(BODY),
        cache_directory = vim.fn.tempname(),
        refresh = true,
        on_done = function(ok, message, info)
          record.results[#record.results + 1] = { ok = ok, message = message, info = info }
        end,
      })

      t.settle(function()
        return #record.results > 0
      end, 500)

      record.ok = record.results[1] and record.results[1].ok
      record.message = record.results[1] and record.results[1].message
      record.info = record.results[1] and record.results[1].info
      record.all = table.concat(record.notifications, "\n")
      return record
    end

    t.it("reports the chosen model, for this session only", function()
      local record = choose({ choose = 1 })

      t.eq(record.ok, true)
      t.eq(record.info.model, "deepseek-v4-flash", "the first usable model")
      t.eq(record.info.provider, "commandcode", "and its provider travels with it")
      t.matches(record.all, "model set to deepseek%-v4%-flash")
      t.matches(record.all, "for this session")
      t.matches(record.all, "restarting Neovim goes back")
    end)

    t.it("says which provider the catalogue came from", function()
      local record = choose({ choose = 1 })
      t.matches(record.asked[1].prompt, "commandcode")
      t.matches(record.asked[1].format(record.asked[1].items[1]), "deepseek%-v4%-flash")
    end)

    t.it("offers a way back only when there is something to undo", function()
      t.eq(choose({ choose = 1 }).asked[1].items[1].clear, nil)
      t.eq(choose({ choose = 1, session = { model = "previous" } }).asked[1].items[1].clear, true)
    end)

    t.it("goes back to the configured model when asked", function()
      local record = choose({ choose = 1, session = { model = "previous" } })

      t.eq(record.ok, true)
      t.eq(record.info.cleared, true)
      t.matches(record.all, "configured model")
    end)

    t.it("changes nothing when the picker is cancelled", function()
      local record = choose({})
      t.eq(record.ok, false)
      t.eq(record.info, nil)
      t.matches(record.message, "unchanged")
    end)

    t.it("refuses without a provider to fetch a catalogue from", function()
      local record = choose({ config = {}, choose = 1 })
      t.eq(record.ok, false)
      t.matches(record.message, "Run :Smith setup first")
    end)

    t.it("reports a catalogue it cannot reach", function()
      local failing = function()
        return {
          wait = function()
            return { code = 7, stdout = "", stderr = "no route to host" }
          end,
        }
      end

      local record = choose({ execute = failing, choose = 1 })
      t.eq(record.ok, false)
      t.matches(record.message, "could not list the models")
    end)

    t.it("reports an empty catalogue the way the fetch does", function()
      -- The fetch already treats an empty list as a failure, so this path is not
      -- the one that reports it. The branch that checks for nothing choosable is
      -- reachable only when a list arrives with no usable ids in it, which
      -- model_choices covers directly.
      local record = choose({ execute = responder('{"data":[]}'), choose = 1 })
      t.eq(record.ok, false)
      t.matches(record.message, "listed no models")
    end)
  end)

  t.describe("onboard: a pick applies to the session and is not written down", function()
    --- Replace the pickers at their module boundary, so the commands' own paths run
    --- without a UI.
    ---
    --- Both of them. Stubbing only the one under test left the real picker reachable
    --- from the other, and a real `vim.ui.select` blocks on input — which hangs the
    --- whole suite rather than failing one test.
    local function stub_pick(info)
      local onboarding = require("agent-smith.onboard")
      local real_model = onboarding.choose_model
      local real_provider = onboarding.choose_provider

      local response = function(fields)
        fields.on_done(true, "stubbed", info)
      end

      onboarding.choose_model = response
      onboarding.choose_provider = response

      return function()
        onboarding.choose_model = real_model
        onboarding.choose_provider = real_provider
      end
    end

    t.it("applies the pick now, and leaves setup() alone", function()
      local smith = require("agent-smith")
      smith.setup({ provider = "zen", model = "configured-model" })

      local restore = stub_pick({ provider = "commandcode", model = "session-model" })
      smith.choose_model()
      restore()

      t.eq(smith.config.provider, "commandcode", "the session uses what was picked")
      t.eq(smith.config.model, "session-model")
      t.ok(smith.config.session, "and records that it came from a pick")
      t.eq(smith.resolved.model, "configured-model", "setup()'s resolution is untouched")

      smith.setup({ provider = "zen", model = "configured-model" })
      t.eq(smith.config.model, "configured-model", "a fresh session goes back")
      t.eq(smith.config.session, nil)

      smith.setup({})
    end)

    t.it("goes back on demand, inside the session", function()
      local smith = require("agent-smith")
      smith.setup({ provider = "zen", model = "configured-model" })

      local restore = stub_pick({ provider = "commandcode", model = "session-model" })
      smith.choose_model()
      restore()
      t.eq(smith.config.model, "session-model")

      restore = stub_pick({ cleared = true })
      smith.choose_model()
      restore()

      t.eq(smith.config.model, "configured-model")
      t.eq(smith.config.provider, "zen")
      t.eq(smith.config.session, nil)

      smith.setup({})
    end)

    t.it("keeps a chosen provider without discarding a chosen model", function()
      local smith = require("agent-smith")
      smith.setup({ provider = "zen", model = "configured-model" })

      local restore = stub_pick({ model = "session-model" })
      smith.choose_model()
      restore()

      restore = stub_pick({ provider = "commandcode", model = "session-model" })
      smith.choose_provider()
      restore()

      t.eq(smith.config.provider, "commandcode")
      t.eq(smith.config.model, "session-model", "the model picked earlier survives")

      smith.setup({})
    end)

    t.it("writes no state file anywhere", function()
      -- The point of the design: a pick is a detour for one session, not a second
      -- source of truth. This file existed while it was one.
      local path = vim.fs.joinpath(vim.fn.stdpath("data"), "agent-smith", "state.json")
      t.eq(vim.fn.filereadable(path), 0, "a pick must not be persisted")
    end)
  end)

  t.describe("onboard.choose_provider", function()
    --- Run the provider picker with everything injected.
    local function choose(fields)
      fields = fields or {}
      local record = { notifications = {}, results = {}, asked = {} }
      local calls = 0

      Onboard.choose_provider({
        config = fields.config or { provider = "zen", model = "kimi-k3" },
        session = fields.session,
        store = fields.store or fake_store(),
        select = function(items, options, on_choice)
          calls = calls + 1
          record.asked[calls] = { items = items, prompt = options.prompt }
          if calls == 1 then
            on_choice(fields.choose and items[fields.choose] or nil)
          else
            on_choice(items[fields.model_choose or 1])
          end
        end,
        notify = function(message)
          record.notifications[#record.notifications + 1] = message
        end,
        execute = fields.execute or responder(BODY),
        cache_directory = vim.fn.tempname(),
        refresh = true,
        on_done = function(ok, message, info)
          record.results[#record.results + 1] = { ok = ok, message = message, info = info }
        end,
      })

      t.settle(function()
        return #record.results > 0
      end, 800)

      record.ok = record.results[1] and record.results[1].ok
      record.message = record.results[1] and record.results[1].message
      record.info = record.results[1] and record.results[1].info
      record.all = table.concat(record.notifications, "\n")
      record.calls = calls
      return record
    end

    t.it("offers every preset and reports the choice", function()
      local record = choose({ choose = 1 })

      t.eq(record.ok, true)
      t.eq(#record.asked[1].items, #require("agent-smith.providers").names())
      t.matches(record.asked[1].prompt, "which provider")
      t.eq(record.info.provider, "commandcode", "the first preset by name")
      t.matches(record.all, "for this session")
    end)

    t.it("opens the model picker when the current model does not belong to it", function()
      -- A model id only means something against the provider that serves it, so a
      -- provider change can invalidate the model. One command should not be able to
      -- leave you in a state that cannot work.
      --
      -- Index 2, because the chained picker offers "go back" first — a provider just
      -- changed, so the way out belongs at the top.
      local record = choose({
        config = { provider = "zen", model = "not-served-here" },
        choose = 1,
        model_choose = 2,
      })

      t.eq(record.ok, true)
      t.eq(record.calls, 2, "the provider picker, then the model picker")
      t.matches(record.asked[2].prompt, "which model")
      t.eq(record.asked[2].items[1].clear, true, "the way back is offered first")
      t.eq(record.info.provider, "commandcode")
      t.eq(record.info.model, "deepseek-v4-flash", "a model the new provider actually serves")
    end)

    t.it("does not ask for a model when the current one belongs to it", function()
      local record = choose({ config = { provider = "zen", model = "kimi-k3" }, choose = 1 })
      t.eq(record.calls, 1)
      t.eq(record.info.served, true)
    end)

    t.it("warns when the chosen provider has no credential", function()
      local previous = vim.env.CMD_API_KEY
      vim.env.CMD_API_KEY = nil
      local record = choose({ choose = 1 })
      vim.env.CMD_API_KEY = previous

      t.matches(record.all, "No credential for it yet")
      t.matches(record.all, ":Smith setup")
    end)

    t.it("clears the session override", function()
      local record = choose({ choose = 1, session = { provider = "commandcode", model = "x" } })

      t.eq(record.ok, true)
      t.eq(record.info.cleared, true)
      t.matches(record.all, "configured provider")
    end)

    t.it("changes nothing when cancelled", function()
      local record = choose({})
      t.eq(record.ok, false)
      t.matches(record.message, "unchanged")
    end)
  end)
end
