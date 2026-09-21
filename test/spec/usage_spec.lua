return function(t)
  local Usage = require("agent-smith.usage")
  local Events = require("agent-smith.agent.events")
  local Loop = require("agent-smith.agent.loop")
  local Messages = require("agent-smith.agent.messages")
  local Scope = require("agent-smith.agent.scope")

  t.describe("usage.add", function()
    t.it("sums the schema's token fields", function()
      local total = Usage.add(nil, Events.usage({ input_tokens = 10, output_tokens = 4 }))
      Usage.add(total, Events.usage({ input_tokens = 5, cache_read_tokens = 30 }))

      t.eq(total, { input_tokens = 15, output_tokens = 4, cache_read_tokens = 30 })
    end)

    t.it("creates the accumulator when given nil", function()
      t.eq(Usage.add(nil, Events.usage({ output_tokens = 1 })), { output_tokens = 1 })
    end)

    t.it("ignores anything that is not a table", function()
      t.eq(Usage.add(nil, nil), {})
      t.eq(Usage.add(nil, "nonsense"), {})
    end)

    t.it("ignores fields outside the schema", function()
      local total = Usage.add(nil, { input_tokens = 3, some_vendor_field = 99 })
      t.eq(total, { input_tokens = 3 })
    end)

    t.it("ignores a non-numeric or negative count", function()
      local total = Usage.add(nil, { input_tokens = "10", output_tokens = -5, cache_read_tokens = 7 })
      t.eq(total, { cache_read_tokens = 7 })
    end)

    t.it("accepts zero", function()
      t.eq(Usage.add(nil, { input_tokens = 0 }), { input_tokens = 0 })
    end)
  end)

  t.describe("usage.hit_rate", function()
    t.it("is the cached share of the prompt", function()
      t.eq(Usage.hit_rate({ input_tokens = 1000, cache_read_tokens = 52000 }), 52 / 53)
    end)

    t.it("is nil when nothing was reported", function()
      -- "nothing measured" and "measured, and it always missed" are different
      -- problems, and a zero would hide the first.
      t.eq(Usage.hit_rate({}), nil)
      t.eq(Usage.hit_rate(nil), nil)
      t.eq(Usage.hit_rate({ output_tokens = 10 }), nil)
    end)

    t.it("is zero when the prompt was never cached", function()
      t.eq(Usage.hit_rate({ input_tokens = 500 }), 0)
    end)

    t.it("ignores output tokens in the denominator", function()
      t.eq(Usage.hit_rate({ input_tokens = 0, cache_read_tokens = 100, output_tokens = 9000 }), 1)
    end)
  end)

  t.describe("usage.render", function()
    t.it("reports the fields that were measured", function()
      -- Chosen so the rate is exact: 49000/50000 rounds to 98 either way.
      local text = Usage.render({ input_tokens = 1000, cache_read_tokens = 49000, output_tokens = 150 })
      t.matches(text, "1000 in")
      t.matches(text, "49000 cached")
      t.matches(text, "150 out")
      -- %% because % is the escape character in a Lua pattern.
      t.matches(text, "98%% cache hit")
    end)

    t.it("omits fields that were not measured", function()
      -- A missing field shown as zero would misreport the request.
      local text = Usage.render({ input_tokens = 10 })
      t.eq(text:find("cached", 1, true), nil)
      t.eq(text:find("out", 1, true), nil)
      t.eq(text, "10 in, 0% cache hit")
    end)

    t.it("includes the turn count when given one", function()
      t.matches(Usage.render({ input_tokens = 1 }, { turns = 3 }), "3 turn%(s%)")
    end)

    t.it("says so when nothing was reported", function()
      t.eq(Usage.render(nil), "no usage reported")
      t.eq(Usage.render({}), "no usage reported")
    end)

    t.it("mentions cache writes when the vendor charges for them", function()
      t.matches(Usage.render({ cache_write_tokens = 900 }), "900 cache write")
    end)
  end)

  t.describe("usage in the loop", function()
    t.it("surfaces a rendered summary on the result", function()
      local transport = {
        run = function(_, on_event)
          on_event(Events.usage({ input_tokens = 100, cache_read_tokens = 900 }))
          on_event(Events.usage({ output_tokens = 20 }))
          on_event(Events.done("complete"))
          return {}
        end,
      }

      local result
      local scope_buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(scope_buffer, "/tmp/usage-project/a.lua")

      Loop.run({
        transport = transport,
        tools = require("agent-smith.tools.registry").new(),
        scope = Scope.inline({ buffer = scope_buffer, start_row = 1, end_row = 10 }),
        conversation = Messages.new({ system = "s" }),
        on_done = function(outcome)
          result = outcome
        end,
      })

      t.ok(result, "the loop should finish")
      t.eq(result.usage, { input_tokens = 100, cache_read_tokens = 900, output_tokens = 20 })
      t.matches(result.summary, "100 in")
      t.matches(result.summary, "900 cached")
      t.matches(result.summary, "90%% cache hit")
      t.matches(result.summary, "1 turn%(s%)")
    end)
  end)
end
