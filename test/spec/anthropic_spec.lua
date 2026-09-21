return function(t)
  local Anthropic = require("agent-smith.transport.anthropic")

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
      model = "claude-test",
      execute = execute,
    }
    for name, value in pairs(overrides or {}) do
      fields[name] = value
    end
    return fields
  end

  local function collect(execute, request, overrides)
    local events = {}
    local transport = Anthropic.new(options(execute, overrides))

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

  local function only(events, kind)
    for _, typed in ipairs(events) do
      if typed.type == kind then
        return typed
      end
    end
    return nil
  end

  --- The body actually sent, decoded.
  local function sent(record)
    return vim.json.decode(record.stdins[1])
  end

  local function request_with(messages, extra)
    local request = { system = "", messages = messages, tools = {} }
    for key, value in pairs(extra or {}) do
      request[key] = value
    end
    return request
  end

  t.describe("anthropic: wire_request", function()
    t.it("always sends max_tokens, because the API requires it", function()
      -- Not optional here, unlike every other adapter. A request without it is
      -- rejected rather than defaulted by the server.
      local body = Anthropic.wire_request({ model = "m" }, request_with({}))
      t.eq(body.max_tokens, Anthropic.DEFAULT_MAX_TOKENS)
    end)

    t.it("lets the caller choose max_tokens", function()
      local body = Anthropic.wire_request({ model = "m", max_tokens = 128 }, request_with({}))
      t.eq(body.max_tokens, 128)
    end)

    t.it("asks for a stream", function()
      t.eq(Anthropic.wire_request({ model = "m" }, request_with({})).stream, true)
    end)

    t.it("puts the system prompt at the top level, not in the messages", function()
      local body = Anthropic.wire_request({ model = "m" }, request_with({}, { system = "be brief" }))
      t.eq(body.system, "be brief")

      for _, message in ipairs(body.messages) do
        t.ok(message.role ~= "system", "the system prompt must not be a message")
      end
    end)

    t.it("omits the system field when there is no prompt", function()
      t.eq(Anthropic.wire_request({ model = "m" }, request_with({})).system, nil)
    end)

    t.it("sends a user message as plain content", function()
      local body = Anthropic.wire_request({ model = "m" }, request_with({
        { role = "user", content = "hello" },
      }))
      t.eq(body.messages[1].role, "user")
      t.eq(body.messages[1].content, "hello")
    end)

    t.it("splits an assistant turn into content blocks", function()
      local body = Anthropic.wire_request({ model = "m" }, request_with({
        {
          role = "assistant",
          content = "looking",
          tool_uses = {
            { id = "toolu_1", name = "read", arguments = { path = "a.lua" } },
          },
        },
      }))

      local message = body.messages[1]
      t.eq(message.role, "assistant")
      t.eq(#message.content, 2)
      t.eq(message.content[1].type, "text")
      t.eq(message.content[1].text, "looking")

      -- `input` is a decoded object here, not a JSON string.
      t.eq(message.content[2].type, "tool_use")
      t.eq(message.content[2].id, "toolu_1")
      t.eq(message.content[2].name, "read")
      t.eq(message.content[2].input.path, "a.lua")
    end)

    t.it("sends tool results inside a user message", function()
      -- The API has no `tool` role: results are blocks in a user turn.
      local body = Anthropic.wire_request({ model = "m" }, request_with({
        {
          role = "tool",
          results = {
            { id = "toolu_1", ok = true, content = "file contents" },
            { id = "toolu_2", ok = false, error = "no such file" },
          },
        },
      }))

      local message = body.messages[1]
      t.eq(message.role, "user")
      t.eq(#message.content, 2)
      t.eq(message.content[1].type, "tool_result")
      t.eq(message.content[1].tool_use_id, "toolu_1")
      t.eq(message.content[1].content, "file contents")
      t.eq(message.content[1].is_error, false)
      t.eq(message.content[2].is_error, true)
      t.matches(message.content[2].content, "no such file")
    end)

    t.it("drops an assistant turn that would be empty", function()
      -- Empty content is rejected by the API, so it is better not to send it.
      local body = Anthropic.wire_request({ model = "m" }, request_with({
        { role = "assistant", content = "", tool_uses = {} },
        { role = "user", content = "still here" },
      }))
      t.eq(#body.messages, 1)
      t.eq(body.messages[1].content, "still here")
    end)

    t.it("drops a tool message with no results", function()
      local body = Anthropic.wire_request({ model = "m" }, request_with({
        { role = "tool", results = {} },
        { role = "user", content = "next" },
      }))
      t.eq(#body.messages, 1)
    end)

    t.it("sends tools with input_schema rather than parameters", function()
      local schemas = {
        {
          name = "read",
          description = "Read a file",
          parameters = { type = "object", properties = { path = { type = "string" } }, required = { "path" } },
        },
      }
      local body = Anthropic.wire_request({ model = "m" }, request_with({}, { tools = schemas }))

      t.eq(#body.tools, 1)
      t.eq(body.tools[1].name, "read")
      t.eq(body.tools[1].description, "Read a file")
      t.eq(body.tools[1].input_schema.type, "object")
      t.eq(body.tools[1].input_schema.required[1], "path")
      t.eq(body.tools[1].parameters, nil, "parameters is the OpenAI spelling")
      t.eq(body.tool_choice.type, "auto")
    end)

    t.it("omits tools and tool_choice when there are none", function()
      local body = Anthropic.wire_request({ model = "m" }, request_with({}))
      t.eq(body.tools, nil)
      t.eq(body.tool_choice, nil)
    end)
  end)

  t.describe("anthropic: build_command", function()
    t.it("posts to the messages path", function()
      local command = Anthropic.build_command({
        base_url = "https://example.invalid/v1",
        api_key = "k",
        token_env = Anthropic.TOKEN_ENV,
      })
      t.matches(command[3], "https://example%.invalid/v1/messages")
      t.eq(command[3]:find("chat/completions", 1, true), nil)
      t.eq(command[3]:find("/responses", 1, true), nil)
    end)
  end)

  t.describe("anthropic: streaming", function()
    t.it("maps text deltas to text", function()
      local events = collect(spawner({
        event({ type = "message_start", message = { usage = {} } }),
        event({ type = "content_block_start", index = 0, content_block = { type = "text", text = "" } }),
        event({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "ab" } }),
        event({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "cd" } }),
        event({ type = "content_block_stop", index = 0 }),
        event({ type = "message_delta", delta = { stop_reason = "end_turn" }, usage = {} }),
        event({ type = "message_stop" }),
      }))

      t.eq(types_of(events), { "text_delta", "text_delta", "done" })
      t.eq(events[1].text, "ab")
      t.eq(events[2].text, "cd")
      t.eq(events[3].reason, "complete")
    end)

    t.it("maps thinking deltas to thinking", function()
      local events = collect(spawner({
        event({ type = "content_block_delta", index = 0, delta = { type = "thinking_delta", thinking = "hmm" } }),
        event({ type = "message_stop" }),
      }))
      t.eq(types_of(events), { "thinking_delta", "done" })
      t.eq(events[1].text, "hmm")
    end)

    t.it("reads the input side of usage from message_start", function()
      local events = collect(spawner({
        event({
          type = "message_start",
          message = {
            usage = { input_tokens = 100, output_tokens = 1, cache_read_input_tokens = 900 },
          },
        }),
        event({ type = "message_stop" }),
      }))

      local usage = only(events, "usage")
      t.eq(usage.input_tokens, 100)
      t.eq(usage.cache_read_tokens, 900)
      -- The output count on this event is a placeholder, and the real total
      -- arrives later. Reporting both would add the placeholder to the total.
      t.eq(usage.output_tokens, nil, "the placeholder must not be reported")
    end)

    t.it("reads the output total from message_delta", function()
      local events = collect(spawner({
        event({ type = "message_start", message = { usage = { input_tokens = 10 } } }),
        event({ type = "message_delta", delta = { stop_reason = "end_turn" }, usage = { output_tokens = 42 } }),
        event({ type = "message_stop" }),
      }))

      local usages = {}
      for _, typed in ipairs(events) do
        if typed.type == "usage" then
          usages[#usages + 1] = typed
        end
      end
      t.eq(#usages, 2)
      t.eq(usages[1].input_tokens, 10)
      t.eq(usages[2].output_tokens, 42)
    end)

    t.it("maps the cache counters to the schema's names", function()
      local events = collect(spawner({
        event({
          type = "message_start",
          message = {
            usage = {
              input_tokens = 5,
              cache_read_input_tokens = 80,
              cache_creation_input_tokens = 20,
            },
          },
        }),
        event({ type = "message_stop" }),
      }))

      local usage = only(events, "usage")
      t.eq(usage.cache_read_tokens, 80)
      t.eq(usage.cache_write_tokens, 20)
    end)

    t.it("ignores pings and unknown events", function()
      local events = collect(spawner({
        event({ type = "ping" }),
        event({ type = "future_thing", whatever = true }),
        event({ type = "content_block_delta", index = 0, delta = { type = "signature_delta", signature = "sig" } }),
        event({ type = "message_stop" }),
      }))
      t.eq(types_of(events), { "done" })
    end)

    t.it("maps every stop reason onto the schema's vocabulary", function()
      local cases = {
        { "end_turn", "complete" },
        { "stop_sequence", "complete" },
        { "tool_use", "tool_calls" },
        { "max_tokens", "length" },
        { "refusal", "content_filter" },
        -- An unknown reason means the model stopped, so the turn ends rather
        -- than looping on something nobody has seen before.
        { "pause_turn", "complete" },
        { "who_knows", "complete" },
      }

      for _, case in ipairs(cases) do
        local events = collect(spawner({
          event({ type = "message_delta", delta = { stop_reason = case[1] }, usage = {} }),
          event({ type = "message_stop" }),
        }))
        t.eq(only(events, "done").reason, case[2], case[1])
      end
    end)

    t.it("reports an error event as terminal", function()
      local events = collect(spawner({
        event({ type = "error", error = { type = "overloaded_error", message = "Overloaded" } }),
      }))
      t.eq(types_of(events), { "error" })
      t.eq(events[1].message, "Overloaded")
    end)

    t.it("surfaces a vendor error body when curl fails", function()
      local events = collect(spawner({}, {
        code = 22,
        stderr = "",
        stdout = "",
      }))

      -- Nothing to read in the body, so the failure is reported rather than
      -- silently completing.
      t.eq(types_of(events), { "error" })
    end)
  end)

  t.describe("anthropic: tool calls", function()
    t.it("reassembles fragmented arguments and decodes them", function()
      local events = collect(spawner({
        event({
          type = "content_block_start",
          index = 0,
          content_block = { type = "tool_use", id = "toolu_1", name = "read", input = {} },
        }),
        event({ type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = '{"path":' } }),
        event({ type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = '"/a.lua"}' } }),
        event({ type = "content_block_stop", index = 0 }),
        event({ type = "message_delta", delta = { stop_reason = "tool_use" }, usage = {} }),
        event({ type = "message_stop" }),
      }))

      t.eq(types_of(events), { "tool_use", "done" })
      t.eq(events[1].id, "toolu_1")
      t.eq(events[1].name, "read")
      t.eq(events[1].arguments.path, "/a.lua")
      t.eq(events[2].reason, "tool_calls")
    end)

    t.it("treats a call with no argument deltas as empty input", function()
      local events = collect(spawner({
        event({
          type = "content_block_start",
          index = 0,
          content_block = { type = "tool_use", id = "toolu_9", name = "diagnostics", input = {} },
        }),
        event({ type = "content_block_stop", index = 0 }),
        event({ type = "message_stop" }),
      }))

      t.eq(events[1].type, "tool_use")
      t.eq(vim.tbl_count(events[1].arguments), 0)
    end)

    t.it("emits several calls in block order", function()
      local events = collect(spawner({
        event({
          type = "content_block_start",
          index = 0,
          content_block = { type = "tool_use", id = "toolu_a", name = "read", input = {} },
        }),
        event({ type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = "{}" } }),
        event({ type = "content_block_stop", index = 0 }),
        event({
          type = "content_block_start",
          index = 1,
          content_block = { type = "tool_use", id = "toolu_b", name = "grep", input = {} },
        }),
        event({ type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = "{}" } }),
        event({ type = "content_block_stop", index = 1 }),
        event({ type = "message_stop" }),
      }))

      t.eq(types_of(events), { "tool_use", "tool_use", "done" })
      t.eq(events[1].id, "toolu_a")
      t.eq(events[2].id, "toolu_b")
    end)

    t.it("interleaves text and a tool call", function()
      local events = collect(spawner({
        event({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "let me look" } }),
        event({ type = "content_block_stop", index = 0 }),
        event({
          type = "content_block_start",
          index = 1,
          content_block = { type = "tool_use", id = "toolu_1", name = "read", input = {} },
        }),
        event({ type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = "{}" } }),
        event({ type = "content_block_stop", index = 1 }),
        event({ type = "message_stop" }),
      }))

      t.eq(types_of(events), { "text_delta", "tool_use", "done" })
    end)

    t.it("flushes a call the stream never closed", function()
      -- A truncated stream still reports what it assembled, rather than losing
      -- the call and reporting an empty turn.
      local events = collect(spawner({
        event({
          type = "content_block_start",
          index = 0,
          content_block = { type = "tool_use", id = "toolu_1", name = "read", input = {} },
        }),
        event({ type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = '{"path":"x"}' } }),
      }))

      t.eq(types_of(events), { "tool_use", "done" })
      t.eq(events[1].arguments.path, "x")
      t.eq(events[2].reason, "tool_calls")
    end)

    t.it("reports a call that arrived without an id or name", function()
      local events = collect(spawner({
        event({ type = "content_block_start", index = 0, content_block = { type = "tool_use", input = {} } }),
        event({ type = "content_block_stop", index = 0 }),
      }))

      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "incomplete")
    end)

    t.it("reports arguments that are not valid JSON", function()
      local events = collect(spawner({
        event({
          type = "content_block_start",
          index = 0,
          content_block = { type = "tool_use", id = "toolu_1", name = "read", input = {} },
        }),
        event({ type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = "{oops" } }),
        event({ type = "content_block_stop", index = 0 }),
      }))

      t.eq(types_of(events), { "error" })
      t.matches(events[1].message, "not valid JSON")
    end)

    t.it("emits a call only once, even if the stream both closes and stops", function()
      local events = collect(spawner({
        event({
          type = "content_block_start",
          index = 0,
          content_block = { type = "tool_use", id = "toolu_1", name = "read", input = {} },
        }),
        event({ type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = "{}" } }),
        event({ type = "content_block_stop", index = 0 }),
        event({ type = "message_stop" }),
      }))

      local calls = 0
      for _, typed in ipairs(events) do
        if typed.type == "tool_use" then
          calls = calls + 1
        end
      end
      t.eq(calls, 1)
    end)
  end)

  t.describe("anthropic: request plumbing", function()
    t.it("sends the body over stdin", function()
      local execute, record = scripted({
        event({ type = "message_stop" }),
      })

      collect(execute, request_with({ { role = "user", content = "hi" } }, { system = "sys" }))

      t.eq(#record.stdins, 1)
      local body = sent(record)
      t.eq(body.system, "sys")
      t.eq(body.model, "claude-test")
      t.eq(body.messages[1].content, "hi")
    end)

    t.it("encodes empty tool arguments as an object, not an array", function()
      -- `input` is parsed as an object, so [] would be malformed.
      local execute, record = scripted({ event({ type = "message_stop" }) })

      collect(execute, request_with({
        {
          role = "assistant",
          content = "",
          tool_uses = { { id = "toolu_1", name = "diagnostics", arguments = {} } },
        },
      }))

      t.ok(record.stdins[1]:find('"input":{}', 1, true), "expected {} for empty arguments")
    end)

    t.it("does not put the credential in argv", function()
      local execute, record = scripted({ event({ type = "message_stop" }) })
      collect(execute, request_with({}))

      for _, part in ipairs(record.commands[1]) do
        t.eq(tostring(part):find("test-key-not-a-secret", 1, true), nil, "the key must not reach argv")
      end
    end)
  end)
end
