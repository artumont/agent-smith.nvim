return function(t)
  local Base = require("agent-smith.transport.base")

  t.describe("transport.base: normalise_headers", function()
    t.it("accepts a list of { name, value }", function()
      local list = Base.normalise_headers({
        { name = "X-One", value = "1" },
        { name = "X-Two", value = "2" },
      })
      t.eq(#list, 2)
      t.eq(list[1].name, "X-One")
      t.eq(list[2].value, "2")
    end)

    t.it("accepts a map, in a stable order", function()
      -- Sorted, so the same declaration produces the same argv rather than
      -- whatever order pairs() happened to walk in.
      local list = Base.normalise_headers({ ["X-Zed"] = "z", ["X-Alpha"] = "a" })
      t.eq(#list, 2)
      t.eq(list[1].name, "X-Alpha")
      t.eq(list[2].name, "X-Zed")
    end)

    t.it("returns nothing for nothing", function()
      t.eq(#Base.normalise_headers(nil), 0)
      t.eq(#Base.normalise_headers("nonsense"), 0)
      t.eq(#Base.normalise_headers({}), 0)
    end)

    t.it("skips junk in a list rather than exploding later", function()
      local list = Base.normalise_headers({ "a string", { name = "X-Ok", value = "1" } })
      t.eq(#list, 1)
      t.eq(list[1].name, "X-Ok")
    end)
  end)

  t.describe("transport.base: build_command with extras", function()
    local function command_with(extra)
      return select(1, Base.build_command({
        base_url = "https://example.invalid/v1",
        endpoint = "/x",
        api_key = "the-secret",
        token_env = "AGENT_SMITH_TEST_KEY",
        headers = extra,
      }))
    end

    local function header_value(command, name)
      -- Plain prefix comparison, not a pattern: `-` is a lazy repetition quantifier
      -- in Lua patterns, so "X-Extra" as a pattern matches something else entirely.
      local prefix = name .. ": "
      for _, part in ipairs(command) do
        local text = tostring(part)
        if text:sub(1, #prefix) == prefix then
          return text:sub(#prefix + 1)
        end
      end
      return nil
    end

    t.it("carries them as their own argv entries", function()
      local command = command_with({ { name = "X-Extra", value = "yes" } })
      t.eq(header_value(command, "X-Extra"), "yes")
    end)

    t.it("still keeps the credential out of argv", function()
      -- The key goes through the environment for this reason, and it must stay
      -- that way however many headers are added.
      local command = command_with({ { name = "X-Extra", value = "yes" } })
      for _, part in ipairs(command) do
        t.eq(tostring(part):find("the-secret", 1, true), nil, "the key must not reach argv")
      end
    end)

    t.it("refuses a header name that could not be sent", function()
      t.raises(function()
        command_with({ { name = "Bad Name", value = "x" } })
      end, "invalid header name")

      t.raises(function()
        command_with({ { name = "Bad:Name", value = "x" } })
      end, "invalid header name")
    end)

    t.it("tolerates a value that is not a string", function()
      local command = command_with({ { name = "X-Number", value = 3 } })
      t.eq(header_value(command, "X-Number"), "3")
    end)
  end)

  t.describe("transport.base: extras reach the wire", function()
    --- A spawner that records the command instead of running it.
    local function capture()
      local record = { commands = {} }
      record.execute = function(command, options, on_exit)
        record.commands[#record.commands + 1] = command
        if options.stdout then
          options.stdout(nil, "")
        end
        vim.schedule(function()
          on_exit({ code = 0, stderr = "" })
        end)
        return { kill = function() end }
      end
      return record
    end

    local function send(options, request)
      local record = capture()
      local transport = Base.new({
        endpoint = "/x",
        options = vim.tbl_extend("force", {
          base_url = "https://example.invalid/v1",
          api_key = "the-secret",
          model = "m",
          execute = record.execute,
        }, options),
        build_request = function()
          return { model = "m" }
        end,
        receive = function()
          return false
        end,
        finish = function(_, emit)
          emit({ type = "done", reason = "complete" })
        end,
      })

      transport.run(request or { system = "", messages = {}, tools = {} }, function() end)
      t.settle(function()
        return #record.commands > 0
      end, 500)

      return record.commands[1]
    end

    local function has(command, name, value)
      for _, part in ipairs(command or {}) do
        if tostring(part) == ("%s: %s"):format(name, value) then
          return true
        end
      end
      return false
    end

    t.it("from the transport's declaration", function()
      local command = send({ extra_headers = { { name = "X-Declared", value = "d" } } })
      t.ok(has(command, "X-Declared", "d"))
    end)

    t.it("from the request, for a one-off", function()
      local command = send({}, {
        system = "",
        messages = {},
        tools = {},
        headers = { ["X-Per-Request"] = "r" },
      })
      t.ok(has(command, "X-Per-Request", "r"))
    end)

    t.it("alongside the session header the adapter already sends", function()
      local command = send({ session_header = "x-session", extra_headers = { ["X-Extra"] = "e" } }, {
        system = "",
        messages = {},
        tools = {},
        session = "abc",
      })
      t.ok(has(command, "x-session", "abc"))
      t.ok(has(command, "X-Extra", "e"))
    end)

    t.it("through a provider declaration and a caller, together", function()
      -- A provider may declare what its gateway wants; a caller may add more.
      local providers = require("agent-smith.providers")
      local record = capture()

      local transport = providers.transport_for({
        provider = {
          name = "Custom",
          base_url = "http://127.0.0.1:9/v1",
          headers = { ["X-Declared"] = "declared" },
        },
        model = "m",
        api_key = "k",
        headers = { { name = "X-Called", value = "called" } },
        execute = record.execute,
      })

      transport.run({ system = "", messages = {}, tools = {} }, function() end)
      t.settle(function()
        return #record.commands > 0
      end, 500)

      local command = record.commands[1]
      t.ok(has(command, "X-Declared", "declared"))
      t.ok(has(command, "X-Called", "called"))
    end)
  end)
end
