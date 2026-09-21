return function(t)
  local Transport = require("agent-smith.transport.openai_compat")
  local Messages = require("agent-smith.agent.messages")
  local Loop = require("agent-smith.agent.loop")
  local Scope = require("agent-smith.agent.scope")
  local Registry = require("agent-smith.tools.registry")

  --- A process spawner that replays scripted output instead of running curl.
  local function scripted(chunks, result)
    local record = { commands = {}, envs = {}, stdins = {} }

    local function execute(command, opts, on_exit)
      record.commands[#record.commands + 1] = command
      record.envs[#record.envs + 1] = opts.env
      record.stdins[#record.stdins + 1] = opts.stdin

      for _, chunk in ipairs(chunks) do
        if opts.stdout then
          opts.stdout(nil, chunk)
        end
      end

      -- vim.system delivers stderr as it arrives, so mirror that rather than
      -- relying on result.stderr, which is nil when a callback is supplied.
      if result and result.stderr and opts.stderr then
        opts.stderr(nil, result.stderr)
      end

      vim.schedule(function()
        on_exit(result or { code = 0, stderr = "" })
      end)

      return {
        kill = function()
          record.killed = true
        end,
      }
    end

    return execute, record
  end

  --- scripted() returns two values, and a call in argument position expands to
  --- all of them: collect(scripted(...)) would pass the record as the second
  --- argument. Returning it through a parenthesised call truncates to one.
  local function spawner(chunks, result)
    return (scripted(chunks, result))
  end

  --- One SSE frame carrying a JSON payload.
  local function chunk(payload)
    local encoded = type(payload) == "string" and payload or vim.json.encode(payload)
    return "data: " .. encoded .. "\n\n"
  end

  local function base_options(execute)
    return {
      base_url = "https://example.invalid/v1",
      api_key = "test-key-not-a-secret",
      model = "test-model",
      execute = execute,
    }
  end

  --- Run the transport and collect events until it terminates.
  local function collect(execute, request)
    local events = {}
    local transport = Transport.new(base_options(execute))

    transport.run(request or { system = "", messages = {}, tools = {} }, function(event)
      events[#events + 1] = event
    end)

    t.settle(function()
      for _, event in ipairs(events) do
        if event.type == "done" or event.type == "error" then
          return true
        end
      end
      return false
    end)

    return events
  end

  local function types_of(events)
    local types = {}
    for _, event in ipairs(events) do
      types[#types + 1] = event.type
    end
    return types
  end

  t.describe("openai_compat: wire_request", function()
    local request = {
      system = "be brief",
      messages = {
        { role = "user", content = "hello" },
        {
          role = "assistant",
          content = "checking",
          tool_uses = { { id = "call_1", name = "read", arguments = { path = "/a.lua" } } },
        },
        {
          role = "tool",
          results = {
            { id = "call_1", ok = true, content = "file contents" },
            { id = "call_2", ok = false, error = "no such file" },
          },
        },
      },
      tools = {},
    }

    t.it("sets the model and asks for a stream", function()
      local body = Transport.wire_request({ model = "m" }, request)
      t.eq(body.model, "m")
      t.eq(body.stream, true)
    end)

    t.it("asks for usage in the stream by default", function()
      t.eq(Transport.wire_request({ model = "m" }, request).stream_options, { include_usage = true })
    end)

    t.it("can leave stream_options out", function()
      local body = Transport.wire_request({ model = "m", include_usage = false }, request)
      t.eq(body.stream_options, nil)
    end)

    t.it("turns the system prompt into a system message", function()
      local body = Transport.wire_request({ model = "m" }, request)
      t.eq(body.messages[1], { role = "system", content = "be brief" })
    end)

    t.it("omits the system message when there is no prompt", function()
      local body = Transport.wire_request({ model = "m" }, { system = "", messages = {}, tools = {} })
      t.eq(body.messages, {})
    end)

    t.it("encodes tool call arguments as a JSON string", function()
      local body = Transport.wire_request({ model = "m" }, request)
      local assistant = body.messages[3]
      t.eq(assistant.role, "assistant")
      t.eq(assistant.tool_calls[1].id, "call_1")
      t.eq(assistant.tool_calls[1].type, "function")
      t.eq(assistant.tool_calls[1]["function"].name, "read")
      t.eq(assistant.tool_calls[1]["function"].arguments, '{"path":"/a.lua"}')
    end)

    t.it("omits tool_calls on an assistant turn without any", function()
      local body = Transport.wire_request({ model = "m" }, {
        system = "",
        messages = { { role = "assistant", content = "hi", tool_uses = {} } },
        tools = {},
      })
      t.eq(body.messages[1].tool_calls, nil)
    end)

    t.it("splits grouped tool results into one message each", function()
      local body = Transport.wire_request({ model = "m" }, request)
      -- system, user, assistant, then two tool messages.
      t.eq(#body.messages, 5)
      t.eq(body.messages[4], { role = "tool", tool_call_id = "call_1", content = "file contents" })
      t.eq(body.messages[5].tool_call_id, "call_2")
    end)

    t.it("marks a failed tool result as an error in the content", function()
      local body = Transport.wire_request({ model = "m" }, request)
      t.eq(body.messages[5].content, "error: no such file")
    end)

    t.it("wraps tool schemas in the function shape", function()
      local schemas = {
        { name = "read", description = "Read a file.", parameters = { type = "object" } },
      }
      local body = Transport.wire_request({ model = "m" }, { system = "", messages = {}, tools = schemas })
      t.eq(body.tools[1].type, "function")
      t.eq(body.tools[1]["function"].name, "read")
      t.eq(body.tools[1]["function"].description, "Read a file.")
      t.eq(body.tools[1]["function"].parameters, { type = "object" })
    end)

    t.it("omits tools entirely when there are none", function()
      local body = Transport.wire_request({ model = "m" }, { system = "", messages = {}, tools = {} })
      t.eq(body.tools, nil)
    end)

    t.it("encodes empty tool arguments as an object, not a list", function()
      -- vim.json.encode({}) is [], and a vendor parses this field as an object.
      -- Every tool with no required arguments hits this path.
      local body = Transport.wire_request({ model = "m" }, {
        system = "",
        messages = {
          {
            role = "assistant",
            content = "",
            tool_uses = { { id = "call_1", name = "list", arguments = {} } },
          },
        },
        tools = {},
      })
      t.eq(body.messages[1].tool_calls[1]["function"].arguments, "{}")
    end)
  end)

  t.describe("openai_compat: build_command", function()
    local function command_for(overrides)
      local fields = {
        base_url = "https://example.invalid/v1",
        api_key = "test-key-not-a-secret",
        token_env = Transport.TOKEN_ENV,
      }
      for name, value in pairs(overrides or {}) do
        fields[name] = value
      end
      return Transport.build_command(fields)
    end

    t.it("posts to chat completions on the given base", function()
      local command = command_for()
      t.eq(command[1], "sh")
      t.matches(command[3], "https://example%.invalid/v1/chat/completions")
    end)

    t.it("does not double the slash on a trailing-slash base", function()
      local command = command_for({ base_url = "https://example.invalid/v1/" })
      t.eq(command[3]:find("v1//chat", 1, true), nil)
      t.matches(command[3], "v1/chat/completions")
    end)

    t.it("keeps the api key out of the argv", function()
      local command = command_for({ api_key = "super-secret-key" })
      for _, argument in ipairs(command) do
        t.eq(argument:find("super-secret-key", 1, true), nil, "the key must not appear in argv")
      end
      t.matches(command[3], "%$" .. Transport.TOKEN_ENV)
    end)

    t.it("returns the key in the environment", function()
      local _, env = command_for({ api_key = "super-secret-key" })
      t.eq(env[Transport.TOKEN_ENV], "super-secret-key")
    end)

    t.it("streams unbuffered and fails on an http error", function()
      local command = command_for()
      t.matches(command[3], "--no%-buffer")
      t.matches(command[3], "--fail%-with%-body")
    end)

    t.it("takes the body on stdin", function()
      t.matches(command_for()[3], "%-%-data%-binary @%-")
    end)

    t.it("passes extra headers as positional parameters, not interpolated", function()
      -- Interpolating a value into the script text would require escaping it.
      -- Passed as an argument it needs none, which matters because one of them
      -- is derived from a filesystem path.
      local command = command_for({ headers = { { name = "x-opencode-session", value = "smith-abc" } } })
      t.matches(command[3], '%-H "%$1"')
      t.eq(command[#command], "x-opencode-session: smith-abc")
      t.eq(command[3]:find("smith%-abc") ~= nil, false, "the value stays out of the script text")
    end)

    t.it("numbers several header placeholders in order", function()
      local command = command_for({
        headers = { { name = "A", value = "1" }, { name = "B", value = "2" } },
      })
      t.matches(command[3], '%-H "%$1"')
      t.matches(command[3], '%-H "%$2"')
      t.eq(command[#command - 1], "A: 1")
      t.eq(command[#command], "B: 2")
    end)

    t.it("refuses a header name it cannot trust", function()
      t.raises(function()
        command_for({ headers = { { name = "bad name; rm -rf /", value = "x" } } })
      end, "invalid header name")
    end)
  end)

  t.describe("openai_compat: request headers", function()
    local function headers_of(argv)
      local found = {}
      for _, argument in ipairs(argv) do
        local name = argument:match("^([%w%-]+): ")
        if name then
          found[name] = argument
        end
      end
      return found
    end

    t.it("identifies the client with a user agent", function()
      local execute, record = scripted({ chunk("[DONE]") })
      collect(execute)
      t.ok(headers_of(record.commands[1])["User-Agent"], "expected a User-Agent header")
    end)

    t.it("sends no session header unless one is configured", function()
      local execute, record = scripted({ chunk("[DONE]") })
      collect(execute)
      t.eq(headers_of(record.commands[1])["x-opencode-session"], nil)
    end)

    t.it("sends the session header when configured", function()
      local execute, record = scripted({ chunk("[DONE]") })
      local transport = Transport.new({
        base_url = "https://example.invalid/v1",
        api_key = "test-key-not-a-secret",
        model = "test-model",
        session_header = "x-opencode-session",
        execute = execute,
      })

      local events = {}
      transport.run({ system = "", messages = {}, tools = {}, session = "smith-abc" }, function(event)
        events[#events + 1] = event
      end)
      t.settle(function()
        return #events > 0
      end)

      t.eq(headers_of(record.commands[1])["x-opencode-session"], "x-opencode-session: smith-abc")
    end)

    t.it("omits the session header when the conversation has no id", function()
      local execute, record = scripted({ chunk("[DONE]") })
      local transport = Transport.new({
        base_url = "https://example.invalid/v1",
        api_key = "test-key-not-a-secret",
        model = "test-model",
        session_header = "x-opencode-session",
        execute = execute,
      })

      local events = {}
      transport.run({ system = "", messages = {}, tools = {} }, function(event)
        events[#events + 1] = event
      end)
      t.settle(function()
        return #events > 0
      end)

      t.eq(headers_of(record.commands[1])["x-opencode-session"], nil)
    end)
  end)

  t.describe("openai_compat: streaming", function()
    t.it("emits text deltas and a terminal done", function()
      local execute = scripted({
        chunk({ choices = { { delta = { role = "assistant", content = "ab" } } } }),
        chunk({ choices = { { delta = { content = "cd" } } } }),
        chunk({ choices = { { delta = {}, finish_reason = "stop" } } }),
        chunk("[DONE]"),
      })

      local events = collect(execute)
      t.eq(types_of(events), { "text_delta", "text_delta", "done" })
      t.eq(events[1].text, "ab")
      t.eq(events[2].text, "cd")
      t.eq(events[3].reason, "complete")
    end)

    t.it("maps length and content_filter reasons", function()
      local length = collect(spawner({
        chunk({ choices = { { delta = { content = "x" }, finish_reason = "length" } } }),
        chunk("[DONE]"),
      }))
      t.eq(length[#length].reason, "length")

      local filtered = collect(spawner({
        chunk({ choices = { { delta = {}, finish_reason = "content_filter" } } }),
        chunk("[DONE]"),
      }))
      t.eq(filtered[#filtered].reason, "content_filter")
    end)

    t.it("maps reasoning deltas to thinking", function()
      local events = collect(spawner({
        chunk({ choices = { { delta = { reasoning_content = "hmm" } } } }),
        chunk({ choices = { { delta = {}, finish_reason = "stop" } } }),
        chunk("[DONE]"),
      }))
      t.eq(types_of(events), { "thinking_delta", "done" })
      t.eq(events[1].text, "hmm")
    end)

    t.it("emits usage, dropping fields that are absent", function()
      local events = collect(spawner({
        chunk({
          choices = {},
          usage = {
            prompt_tokens = 11,
            completion_tokens = 4,
            prompt_tokens_details = { cached_tokens = 3 },
            completion_tokens_details = { reasoning_tokens = 2 },
          },
        }),
        chunk("[DONE]"),
      }))

      local usage
      for _, event in ipairs(events) do
        if event.type == "usage" then
          usage = event
        end
      end

      t.eq(usage.input_tokens, 11)
      t.eq(usage.output_tokens, 4)
      t.eq(usage.cache_read_tokens, 3)
      t.eq(usage.reasoning_tokens, 2)
    end)

    t.it("does not emit a usage event with no token fields", function()
      local events = collect(spawner({
        chunk({ choices = {}, usage = { something_else = 1 } }),
        chunk("[DONE]"),
      }))
      t.eq(types_of(events), { "done" })
    end)

    t.it("finalizes when the stream ends without a done sentinel", function()
      local events = collect(spawner({
        chunk({ choices = { { delta = { content = "truncated" } } } }),
      }))
      t.eq(types_of(events), { "text_delta", "done" })
    end)

    t.it("tolerates a chunk split mid-frame", function()
      local whole = chunk({ choices = { { delta = { content = "split" } } } })
      local events = collect(spawner({
        whole:sub(1, 12),
        whole:sub(13),
        chunk("[DONE]"),
      }))
      t.eq(types_of(events), { "text_delta", "done" })
      t.eq(events[1].text, "split")
    end)
  end)

  t.describe("openai_compat: tool calls", function()
    t.it("reassembles fragmented arguments and decodes them", function()
      local events = collect(spawner({
        chunk({
          choices = {
            { delta = { tool_calls = { { index = 0, id = "call_1", type = "function", ["function"] = { name = "read", arguments = "" } } } } },
          },
        }),
        chunk({
          choices = {
            { delta = { tool_calls = { { index = 0, ["function"] = { arguments = '{"path":' } } } } },
          },
        }),
        chunk({
          choices = {
            { delta = { tool_calls = { { index = 0, ["function"] = { arguments = '"/a.lua"}' } } } } },
          },
        }),
        chunk({ choices = { { delta = {}, finish_reason = "tool_calls" } } }),
        chunk("[DONE]"),
      }))

      t.eq(types_of(events), { "tool_use", "done" })
      t.eq(events[1].id, "call_1")
      t.eq(events[1].name, "read")
      t.eq(events[1].arguments, { path = "/a.lua" })
      t.eq(events[2].reason, "tool_calls")
    end)

    t.it("emits tool calls in index order", function()
      local events = collect(spawner({
        chunk({
          choices = {
            {
              delta = {
                tool_calls = {
                  { index = 1, id = "call_2", ["function"] = { name = "second", arguments = "{}" } },
                  { index = 0, id = "call_1", ["function"] = { name = "first", arguments = "{}" } },
                },
              },
            },
          },
        }),
        chunk("[DONE]"),
      }))

      t.eq(events[1].name, "first")
      t.eq(events[2].name, "second")
    end)

    t.it("treats empty arguments as an empty object", function()
      local events = collect(spawner({
        chunk({
          choices = {
            { delta = { tool_calls = { { index = 0, id = "call_1", ["function"] = { name = "list", arguments = "" } } } } },
          },
        }),
        chunk("[DONE]"),
      }))
      t.eq(events[1].arguments, {})
    end)

    t.it("fails when a tool call never gets an id", function()
      local events = collect(spawner({
        chunk({
          choices = {
            { delta = { tool_calls = { { index = 0, ["function"] = { name = "read", arguments = "{}" } } } } },
          },
        }),
        chunk("[DONE]"),
      }))

      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "incomplete")
    end)

    t.it("fails when arguments are not valid JSON", function()
      local events = collect(spawner({
        chunk({
          choices = {
            { delta = { tool_calls = { { index = 0, id = "call_1", ["function"] = { name = "read", arguments = "{not json" } } } } },
          },
        }),
        chunk("[DONE]"),
      }))

      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "not valid JSON")
    end)
  end)

  t.describe("openai_compat: failures", function()
    t.it("reports an error object arriving inside the stream", function()
      local events = collect(spawner({
        chunk({ error = { message = "rate limited", type = "rate_limit_error" } }),
      }))

      t.eq(types_of(events), { "error" })
      t.eq(events[1].message, "rate limited")
    end)

    t.it("reports a vendor error body when curl exits non-zero", function()
      local execute = scripted({ '{"error":{"message":"bad key","type":"authentication_error"}}' }, { code = 22 })
      local events = collect(execute)

      t.eq(types_of(events), { "error" })
      t.eq(events[1].message, "bad key")
    end)

    t.it("falls back to the curl exit code when there is no error body", function()
      local execute = scripted({}, { code = 7, stderr = "Could not resolve host" })
      local events = collect(execute)

      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "Could not resolve host")
    end)

    t.it("reports an undecodable chunk", function()
      local events = collect(spawner({ chunk("not json at all") }))
      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "could not decode")
    end)
  end)

  t.describe("openai_compat: request plumbing", function()
    t.it("sends the body over stdin and the key in the environment", function()
      local execute, record = scripted({ chunk("[DONE]") })
      collect(execute, {
        system = "sys",
        messages = { { role = "user", content = "hi" } },
        tools = {},
      })

      t.matches(record.stdins[1], '"model":"test%-model"')
      t.eq(record.envs[1][Transport.TOKEN_ENV], "test-key-not-a-secret")
    end)

    t.it("cancels by killing the process", function()
      local execute, record = scripted({})
      local transport = Transport.new(base_options(execute))

      -- Never emits a terminal event, so nothing finalizes on its own.
      local handle = transport.run({ system = "", messages = {}, tools = {} }, function() end)
      handle:cancel()

      t.eq(record.killed, true)
    end)
  end)

  t.describe("openai_compat: through the loop", function()
    t.it("drives a full request, tools and all", function()
      local scope_buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(scope_buffer, "/tmp/transport-project/scope.lua")
      local scope = Scope.inline({ buffer = scope_buffer, start_row = 1, end_row = 1000 })

      local registry = Registry.new()
      registry:register({
        name = "read",
        description = "Read a file.",
        access = "read",
        parameters = { path = { type = "string", required = true } },
        handler = function(arguments)
          return Registry.ok("contents of " .. arguments.path)
        end,
      })

      -- Call one asks for a tool; call two is the answer.
      local call = 0
      local scripts = {
        {
          chunk({
            choices = {
              {
                delta = {
                  tool_calls = {
                    { index = 0, id = "call_1", ["function"] = { name = "read", arguments = '{"path":"/tmp/transport-project/a.lua"}' } },
                  },
                },
              },
            },
          }),
          chunk({ choices = { { delta = {}, finish_reason = "tool_calls" } } }),
          chunk("[DONE]"),
        },
        {
          chunk({ choices = { { delta = { content = "It says: " } } } }),
          chunk({ choices = { { delta = { content = "contents of /tmp/transport-project/a.lua" } } } }),
          chunk({ choices = { { delta = {}, finish_reason = "stop" } } }),
          chunk("[DONE]"),
        },
      }

      local commands = {}

      local function execute(command, opts, on_exit)
        commands[#commands + 1] = command
        call = call + 1
        for _, piece in ipairs(scripts[call] or {}) do
          if opts.stdout then
            opts.stdout(nil, piece)
          end
        end
        vim.schedule(function()
          on_exit({ code = 0, stderr = "" })
        end)
        return { kill = function() end }
      end

      local transport = Transport.new(base_options(execute))
      local conversation = Messages.new({ system = "sys" })
      conversation:append_user("read the file")

      local result
      Loop.run({
        transport = transport,
        tools = registry,
        scope = scope,
        conversation = conversation,
        on_done = function(outcome)
          result = outcome
        end,
      })

      t.settle(function()
        return result ~= nil
      end)

      t.ok(result, "the loop should finish")
      t.eq(result.ok, true)
      t.eq(result.turns, 2)
      t.eq(result.reason, "complete")

      t.eq(#commands, 2, "one process per turn")
      t.matches(commands[1][3], "example%.invalid/v1/chat/completions")
      t.eq(commands[1][3]:find("test-key-not-a-secret", 1, true), nil, "the key stays out of argv")

      local messages = conversation:list()
      t.eq(messages[2].tool_uses[1].name, "read", "the assistant turn recorded the tool call")
      t.eq(messages[3].results[1].content, "contents of /tmp/transport-project/a.lua")
      t.eq(messages[4].content, "It says: contents of /tmp/transport-project/a.lua")
    end)
  end)
end
