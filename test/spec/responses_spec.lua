return function(t)
  local Responses = require("agent-smith.transport.responses")

  --- A process spawner that replays scripted SSE output instead of running curl.
  local function scripted(chunks, result)
    local record = { commands = {}, stdins = {} }

    local function execute(command, options, on_exit)
      record.commands[#record.commands + 1] = command
      record.stdins[#record.stdins + 1] = options.stdin

      for _, chunk in ipairs(chunks) do
        if options.stdout then
          options.stdout(nil, chunk)
        end
      end

      if result and result.stderr and options.stderr then
        options.stderr(nil, result.stderr)
      end

      vim.schedule(function()
        on_exit(result or { code = 0, stderr = "" })
      end)

      return { kill = function() end }
    end

    return execute, record
  end

  --- scripted() returns two values; wrapping truncates to the spawner.
  local function spawner(chunks, result)
    return (scripted(chunks, result))
  end

  --- One SSE frame carrying a JSON payload.
  local function event(payload)
    local encoded = type(payload) == "string" and payload or vim.json.encode(payload)
    return "data: " .. encoded .. "\n\n"
  end

  local function options(execute, overrides)
    local fields = {
      base_url = "https://example.invalid/v1",
      api_key = "test-key-not-a-secret",
      model = "gpt-test",
      execute = execute,
    }
    for name, value in pairs(overrides or {}) do
      fields[name] = value
    end
    return fields
  end

  local function collect(execute, request, overrides)
    local events = {}
    local transport = Responses.new(options(execute, overrides))

    transport.run(request or { system = "", messages = {}, tools = {} }, function(typed)
      events[#events + 1] = typed
    end)

    t.settle(function()
      for _, typed in ipairs(events) do
        if typed.type == "done" or typed.type == "error" then
          return true
        end
      end
      return false
    end)

    return events
  end

  local function types_of(events)
    local kinds = {}
    for _, typed in ipairs(events) do
      kinds[#kinds + 1] = typed.type
    end
    return kinds
  end

  t.describe("responses: wire_request", function()
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

    t.it("uses input rather than messages", function()
      local body = Responses.wire_request({ model = "m" }, request)
      t.eq(type(body.input), "table")
      t.eq(body.messages, nil)
      t.eq(body.stream, true)
    end)

    t.it("puts the system prompt in instructions, not a message", function()
      local body = Responses.wire_request({ model = "m" }, request)
      t.eq(body.instructions, "be brief")
      for _, item in ipairs(body.input) do
        t.not_ok(item.role == "system", "there should be no system message")
      end
    end)

    t.it("omits instructions when there is no system prompt", function()
      local body = Responses.wire_request({ model = "m" }, { system = "", messages = {}, tools = {} })
      t.eq(body.instructions, nil)
    end)

    t.it("keeps tool calls as typed items alongside the prose", function()
      local body = Responses.wire_request({ model = "m" }, request)
      -- user, assistant prose, function_call, then two results.
      t.eq(#body.input, 5)
      t.eq(body.input[2], { role = "assistant", content = "checking" })
      t.eq(body.input[3].type, "function_call")
      t.eq(body.input[3].call_id, "call_1")
      t.eq(body.input[3].name, "read")
      t.eq(body.input[3].arguments, '{"path":"/a.lua"}')
    end)

    t.it("sends tool results as function_call_output", function()
      local body = Responses.wire_request({ model = "m" }, request)
      t.eq(body.input[4], { type = "function_call_output", call_id = "call_1", output = "file contents" })
      t.eq(body.input[5].output, "error: no such file")
    end)

    t.it("omits an empty assistant message", function()
      local body = Responses.wire_request({ model = "m" }, {
        system = "",
        messages = {
          { role = "assistant", content = "", tool_uses = { { id = "c", name = "read", arguments = {} } } },
        },
        tools = {},
      })
      t.eq(#body.input, 1, "only the function_call item")
      t.eq(body.input[1].type, "function_call")
    end)

    t.it("defines tools flat, not nested under function", function()
      local schemas = { { name = "read", description = "Read.", parameters = { type = "object" } } }
      local body = Responses.wire_request({ model = "m" }, { system = "", messages = {}, tools = schemas })
      t.eq(body.tools[1].type, "function")
      t.eq(body.tools[1].name, "read")
      t.eq(body.tools[1].description, "Read.")
      t.eq(body.tools[1].parameters, { type = "object" })
      t.eq(body.tools[1]["function"], nil, "that nesting belongs to chat completions")
    end)

    t.it("omits tools entirely when there are none", function()
      local body = Responses.wire_request({ model = "m" }, { system = "", messages = {}, tools = {} })
      t.eq(body.tools, nil)
    end)

    t.it("does not ask the vendor to store the conversation by default", function()
      t.eq(Responses.wire_request({ model = "m" }, request).store, false)
    end)

    t.it("stores when asked", function()
      t.eq(Responses.wire_request({ model = "m", store = true }, request).store, true)
    end)
  end)

  t.describe("responses: build_command", function()
    t.it("posts to the responses path", function()
      local command = Responses.build_command({
        base_url = "https://example.invalid/v1",
        api_key = "k",
        token_env = Responses.TOKEN_ENV,
      })
      t.matches(command[3], "https://example%.invalid/v1/responses")
      t.eq(command[3]:find("chat/completions", 1, true), nil)
    end)
  end)

  t.describe("responses: streaming", function()
    t.it("maps output_text deltas to text", function()
      local events = collect(spawner({
        event({ type = "response.created" }),
        event({ type = "response.output_text.delta", delta = "ab" }),
        event({ type = "response.output_text.delta", delta = "cd" }),
        event({ type = "response.output_text.done", text = "abcd" }),
        event({ type = "response.completed", response = {} }),
      }))

      t.eq(types_of(events), { "text_delta", "text_delta", "done" })
      t.eq(events[1].text, "ab")
      t.eq(events[2].text, "cd")
      t.eq(events[3].reason, "complete")
    end)

    t.it("maps reasoning deltas to thinking", function()
      local events = collect(spawner({
        event({ type = "response.reasoning_summary_text.delta", delta = "hmm" }),
        event({ type = "response.completed", response = {} }),
      }))
      t.eq(types_of(events), { "thinking_delta", "done" })
    end)

    t.it("reads usage from the completed event", function()
      local events = collect(spawner({
        event({ type = "response.output_text.delta", delta = "hi" }),
        event({
          type = "response.completed",
          response = {
            usage = {
              input_tokens = 1000,
              output_tokens = 20,
              input_tokens_details = { cached_tokens = 900 },
              output_tokens_details = { reasoning_tokens = 5 },
            },
          },
        }),
      }))

      local usage
      for _, typed in ipairs(events) do
        if typed.type == "usage" then
          usage = typed
        end
      end
      -- 1000 total, 900 of them cached: the schema's `input_tokens` is the
      -- 100 that were not. See transport/responses.lua.
      t.eq(usage.input_tokens, 100)
      t.eq(usage.output_tokens, 20)
      t.eq(usage.cache_read_tokens, 900)
      t.eq(usage.reasoning_tokens, 5)
    end)

    t.it("accepts flat cache and reasoning fields too", function()
      local events = collect(spawner({
        event({
          type = "response.completed",
          response = { usage = { input_tokens = 8, cached_tokens = 7, reasoning_tokens = 8 } },
        }),
      }))
      t.eq(events[1].input_tokens, 1)
      t.eq(events[1].cache_read_tokens, 7)
      t.eq(events[1].reasoning_tokens, 8)
    end)

    t.it("ignores lifecycle events it does not act on", function()
      local events = collect(spawner({
        event({ type = "response.in_progress" }),
        event({ type = "response.content_part.added" }),
        event({ type = "response.output_text.annotation.added" }),
        event({ type = "response.completed", response = {} }),
      }))
      t.eq(types_of(events), { "done" })
    end)

    t.it("reports an incomplete response as a length stop", function()
      local events = collect(spawner({
        event({
          type = "response.incomplete",
          response = { incomplete_details = { reason = "max_output_tokens" } },
        }),
      }))
      t.eq(types_of(events), { "done" })
      t.eq(events[1].reason, "length")
    end)
  end)

  t.describe("responses: tool calls", function()
    t.it("reassembles fragmented arguments and decodes them", function()
      local events = collect(spawner({
        event({
          type = "response.output_item.added",
          output_index = 0,
          item = { type = "function_call", call_id = "call_1", name = "read", arguments = "" },
        }),
        event({ type = "response.function_call_arguments.delta", output_index = 0, delta = '{"path":' }),
        event({ type = "response.function_call_arguments.delta", output_index = 0, delta = '"/a.lua"}' }),
        event({
          type = "response.completed",
          response = {},
        }),
      }))

      t.eq(types_of(events), { "tool_use", "done" })
      t.eq(events[1].id, "call_1")
      t.eq(events[1].name, "read")
      t.eq(events[1].arguments, { path = "/a.lua" })
      t.eq(events[2].reason, "tool_calls")
    end)

    t.it("emits the tool call when the item completes", function()
      local events = collect(spawner({
        event({
          type = "response.output_item.added",
          output_index = 0,
          item = { type = "function_call", call_id = "call_1", name = "read", arguments = "" },
        }),
        event({
          type = "response.output_item.done",
          output_index = 0,
          item = { type = "function_call", call_id = "call_1", name = "read", arguments = '{"path":"/a"}' },
        }),
        event({ type = "response.completed", response = {} }),
      }))

      t.eq(types_of(events), { "tool_use", "done" })
      t.eq(events[2].reason, "tool_calls")
    end)

    t.it("works when no output_item.added arrived first", function()
      -- Some intermediates only emit the arguments deltas.
      local events = collect(spawner({
        event({
          type = "response.output_item.done",
          output_index = 0,
          item = { type = "function_call", call_id = "call_9", name = "glob", arguments = '{"pattern":"*"}' },
        }),
        event({ type = "response.completed", response = {} }),
      }))

      t.eq(types_of(events), { "tool_use", "done" })
      t.eq(events[1].name, "glob")
      t.eq(events[1].arguments, { pattern = "*" })
    end)

    t.it("emits several calls in index order", function()
      local events = collect(spawner({
        event({
          type = "response.output_item.done",
          output_index = 1,
          item = { type = "function_call", call_id = "second", name = "b", arguments = "{}" },
        }),
        event({
          type = "response.output_item.done",
          output_index = 0,
          item = { type = "function_call", call_id = "first", name = "a", arguments = "{}" },
        }),
        event({ type = "response.completed", response = {} }),
      }))

      t.eq(events[1].name, "a")
      t.eq(events[2].name, "b")
    end)

    t.it("treats empty arguments as an empty object", function()
      local events = collect(spawner({
        event({
          type = "response.output_item.done",
          output_index = 0,
          item = { type = "function_call", call_id = "c", name = "list", arguments = "" },
        }),
        event({ type = "response.completed", response = {} }),
      }))
      t.eq(events[1].arguments, {})
    end)

    t.it("fails when a tool call never gets a call id", function()
      local events = collect(spawner({
        event({
          type = "response.output_item.done",
          output_index = 0,
          item = { type = "function_call", name = "read", arguments = "{}" },
        }),
        event({ type = "response.completed", response = {} }),
      }))
      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "incomplete")
    end)

    t.it("fails when arguments are not valid JSON", function()
      local events = collect(spawner({
        event({
          type = "response.output_item.done",
          output_index = 0,
          item = { type = "function_call", call_id = "c", name = "read", arguments = "{nope" },
        }),
        event({ type = "response.completed", response = {} }),
      }))
      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "not valid JSON")
    end)
  end)

  t.describe("responses: failures and endings", function()
    t.it("reports a failed response", function()
      local events = collect(spawner({
        event({ type = "response.failed", response = { error = { message = "model unavailable" } } }),
      }))
      t.eq(types_of(events), { "error" })
      t.eq(events[1].message, "model unavailable")
    end)

    t.it("reports a bare error event", function()
      local events = collect(spawner({
        event({ type = "error", message = "rate limited", code = "rate_limit" }),
      }))
      t.eq(types_of(events), { "error" })
      t.eq(events[1].message, "rate limited")
    end)

    t.it("reports a vendor error body when curl exits non-zero", function()
      local execute = scripted({ '{"error":{"message":"bad key"}}' }, { code = 22 })
      local events = collect(execute)
      t.eq(types_of(events), { "error" })
      t.eq(events[1].message, "bad key")
    end)

    t.it("finishes when the stream ends without a completed event", function()
      -- The base calls finish(), which must still produce a terminal event or
      -- the loop would wait forever.
      local events = collect(spawner({
        event({ type = "response.output_text.delta", delta = "cut off" }),
      }))
      t.eq(types_of(events), { "text_delta", "done" })
      t.eq(events[2].reason, "complete")
    end)

    t.it("flushes a tool call that never saw a completed event", function()
      local events = collect(spawner({
        event({
          type = "response.output_item.done",
          output_index = 0,
          item = { type = "function_call", call_id = "c", name = "read", arguments = "{}" },
        }),
      }))
      t.eq(types_of(events), { "tool_use", "done" })
    end)

    t.it("reports an undecodable chunk", function()
      local events = collect(spawner({ event("not json at all") }))
      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "could not decode")
    end)
  end)

  t.describe("responses: request plumbing", function()
    t.it("sends the body on stdin and the key in the environment", function()
      local execute, record = scripted({ event({ type = "response.completed", response = {} }) })
      collect(execute, { system = "sys", messages = {}, tools = {} })

      t.matches(record.stdins[1], '"model":"gpt%-test"')
      t.eq(record.commands[1][1], "sh")
      for _, argument in ipairs(record.commands[1]) do
        t.eq(argument:find("test-key-not-a-secret", 1, true), nil, "the key stays out of argv")
      end
    end)

    t.it("sends the session header when configured", function()
      local execute, record = scripted({ event({ type = "response.completed", response = {} }) })
      collect(
        execute,
        { system = "", messages = {}, tools = {}, session = "smith-abc" },
        { session_header = "x-opencode-session" }
      )

      local found
      for _, argument in ipairs(record.commands[1]) do
        if argument:match("^x%-opencode%-session: ") then
          found = argument
        end
      end
      t.eq(found, "x-opencode-session: smith-abc")
    end)
  end)
end
