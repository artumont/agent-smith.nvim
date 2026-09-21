return function(t)
  local Loop = require("agent-smith.agent.loop")
  local Events = require("agent-smith.agent.events")
  local Messages = require("agent-smith.agent.messages")
  local Scope = require("agent-smith.agent.scope")
  local Registry = require("agent-smith.tools.registry")

  -- A scope that permits reads and, by default, nothing else.
  local scope = Scope.vibe({ paths = {} })

  --- A transport that replays one scripted list of events per call.
  local function fake(script)
    local transport = { calls = 0 }

    function transport.run(request, on_event)
      transport.calls = transport.calls + 1
      transport.last_request = request

      local events = script[transport.calls]
      if events == nil then
        local terminal = Events.error(("the fake ran out of script on call %d"):format(transport.calls))
        on_event(terminal)
        return {}
      end

      for _, event in ipairs(events) do
        on_event(event)
      end

      return {
        cancel = function()
          transport.cancelled = true
        end,
      }
    end

    return transport
  end

  --- A transport whose stream stays open until the test drives it.
  local function open_transport()
    local transport = { calls = 0 }
    function transport.run(_, on_event)
      transport.calls = transport.calls + 1
      transport.emit = on_event
      return { cancel = function() transport.cancelled = true end }
    end
    return transport
  end

  local function registry_with(handler, overrides)
    local registry = Registry.new()
    local spec = {
      name = "echo",
      description = "Echo a value.",
      access = "read",
      parameters = { value = { type = "string", required = true } },
      handler = handler or function(arguments)
        return Registry.ok("echoed " .. arguments.value)
      end,
    }
    for name, value in pairs(overrides or {}) do
      spec[name] = value
    end
    registry:register(spec)
    return registry
  end

  --- Run a fresh conversation to completion and return everything observed.
  local function run(options)
    local conversation = options.conversation or Messages.new({ system = "system prompt" })
    local record = { events = {}, results = {}, permissions = {} }

    local handle = Loop.run({
      transport = options.transport,
      tools = options.tools or registry_with(),
      scope = options.scope or scope,
      conversation = conversation,
      max_turns = options.max_turns,
      on_event = function(event)
        record.events[#record.events + 1] = event
      end,
      on_permission = options.on_permission,
      on_done = function(result)
        record.results[#record.results + 1] = result
      end,
    })

    record.handle = handle
    record.conversation = conversation
    record.result = record.results[1]
    return record
  end

  local function tool_event(id, name, arguments)
    return Events.tool_use(id, name, arguments or { value = "x" })
  end

  --- The last tool result recorded in the conversation.
  local function last_tool_result(conversation)
    local messages = conversation:list()
    for index = #messages, 1, -1 do
      if messages[index].role == "tool" then
        local results = messages[index].results
        return results[#results]
      end
    end
    return nil
  end

  t.describe("loop: a plain turn", function()
    t.it("finishes once the model stops", function()
      local transport = fake({
        { Events.text_delta("hi "), Events.text_delta("there"), Events.done("complete") },
      })

      local record = run({ transport = transport })
      t.eq(#record.results, 1, "on_done fires exactly once")
      t.eq(record.result.ok, true)
      t.eq(record.result.reason, "complete")
      t.eq(record.result.turns, 1)
      t.eq(transport.calls, 1)
    end)

    t.it("records the assistant turn", function()
      local transport = fake({ { Events.text_delta("hello"), Events.done("complete") } })
      local record = run({ transport = transport })

      local message = record.conversation:list()[1]
      t.eq(message.role, "assistant")
      t.eq(message.content, "hello", "deltas are joined")
    end)

    t.it("sums usage across the stream", function()
      local transport = fake({
        {
          Events.usage({ input_tokens = 10 }),
          Events.text_delta("x"),
          Events.usage({ output_tokens = 4, cache_read_tokens = 2 }),
          Events.done("complete"),
        },
      })

      local record = run({ transport = transport })
      t.eq(record.result.usage, { input_tokens = 10, output_tokens = 4, cache_read_tokens = 2 })
    end)

    t.it("forwards every event to the caller", function()
      local transport = fake({
        { Events.text_delta("a"), Events.thinking_delta("b"), Events.done("complete") },
      })

      local record = run({ transport = transport })
      local kinds = {}
      for _, event in ipairs(record.events) do
        kinds[#kinds + 1] = event.type
      end
      t.eq(kinds, { "text_delta", "thinking_delta", "done" })
    end)

    t.it("passes a length stop through", function()
      local transport = fake({ { Events.text_delta("cut off"), Events.done("length") } })
      local record = run({ transport = transport })
      t.eq(record.result.ok, true)
      t.eq(record.result.reason, "length")
    end)
  end)

  t.describe("loop: the request", function()
    t.it("sends the system prompt, messages and tool schemas", function()
      local transport = fake({ { Events.done("complete") } })
      run({ transport = transport })

      local request = transport.last_request
      t.eq(request.system, "system prompt")
      t.eq(request.messages, {})
      t.eq(#request.tools, 1)
      t.eq(request.tools[1].name, "echo")
    end)
  end)

  t.describe("loop: tool calls", function()
    t.it("runs a tool and continues", function()
      local ran = {}
      local transport = fake({
        { tool_event("call_1", "echo"), Events.done("tool_calls") },
        { Events.text_delta("done"), Events.done("complete") },
      })

      local record = run({
        transport = transport,
        tools = registry_with(function(arguments)
          ran[#ran + 1] = arguments.value
          return Registry.ok("tool said " .. arguments.value)
        end),
      })

      t.eq(transport.calls, 2, "the loop goes round again")
      t.eq(ran, { "x" })
      t.eq(record.result.ok, true)
      t.eq(record.result.turns, 2)
    end)

    t.it("records the assistant turn before the tool results", function()
      local transport = fake({
        { Events.text_delta("let me check"), tool_event("call_1", "echo"), Events.done("tool_calls") },
        { Events.done("complete") },
      })

      local record = run({ transport = transport })
      local roles = {}
      for _, message in ipairs(record.conversation:list()) do
        roles[#roles + 1] = message.role
      end
      t.eq(roles, { "assistant", "tool", "assistant" })
      t.eq(record.conversation:list()[1].tool_uses[1].id, "call_1")
    end)

    t.it("feeds the result back", function()
      local transport = fake({
        { tool_event("call_1", "echo"), Events.done("tool_calls") },
        { Events.done("complete") },
      })

      local record = run({ transport = transport })
      t.eq(last_tool_result(record.conversation), { id = "call_1", ok = true, content = "echoed x" })
    end)

    t.it("runs several tools in order", function()
      local order = {}
      local transport = fake({
        {
          tool_event("call_1", "echo", { value = "one" }),
          tool_event("call_2", "echo", { value = "two" }),
          Events.done("tool_calls"),
        },
        { Events.done("complete") },
      })

      run({
        transport = transport,
        tools = registry_with(function(arguments)
          order[#order + 1] = arguments.value
          return Registry.ok("ok")
        end),
      })

      t.eq(order, { "one", "two" })
    end)

    t.it("reports a failing tool to the model without stopping", function()
      local transport = fake({
        { tool_event("call_1", "echo"), Events.done("tool_calls") },
        { Events.text_delta("recovered"), Events.done("complete") },
      })

      local record = run({
        transport = transport,
        tools = registry_with(function()
          return Registry.error("the tool broke")
        end),
      })

      t.eq(record.result.ok, true, "a failing tool is not a failing request")
      t.eq(last_tool_result(record.conversation).ok, false)
      t.eq(last_tool_result(record.conversation).error, "the tool broke")
    end)

    t.it("turns a raising tool into an error result", function()
      local transport = fake({
        { tool_event("call_1", "echo"), Events.done("tool_calls") },
        { Events.done("complete") },
      })

      local record = run({
        transport = transport,
        tools = registry_with(function()
          error("boom")
        end),
      })

      t.eq(last_tool_result(record.conversation).ok, false)
      t.matches(last_tool_result(record.conversation).error, "boom")
    end)

    t.it("reports an unknown tool to the model", function()
      local transport = fake({
        { tool_event("call_1", "rm"), Events.done("tool_calls") },
        { Events.done("complete") },
      })

      local record = run({ transport = transport })
      t.matches(last_tool_result(record.conversation).error, "unknown tool")
    end)

    t.it("finishes without dispatching when a turn names no tools", function()
      local transport = fake({ { Events.text_delta("nothing to do"), Events.done("tool_calls") } })
      local record = run({ transport = transport })
      t.eq(record.result.ok, true)
      t.eq(transport.calls, 1)
    end)
  end)

  t.describe("loop: permissions", function()
    local write_buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(write_buffer, "/tmp/loop-project/a.lua")

    local function write_tools(handler)
      local registry = Registry.new()
      registry:register({
        name = "edit",
        description = "Edit a file.",
        access = "write",
        parameters = { path = { type = "string", required = true } },
        locate = function(arguments)
          return { kind = "write", path = arguments.path, range = { start_row = 1, end_row = 1 } }
        end,
        handler = handler or function()
          return Registry.ok("edited")
        end,
      })
      return registry
    end

    local function inline_scope()
      return Scope.inline({ buffer = write_buffer, start_row = 1, end_row = 1 })
    end

    local function permission_script()
      return fake({
        {
          Events.tool_use("call_1", "edit", { path = "/tmp/loop-project/b.lua" }),
          Events.done("tool_calls"),
        },
        { Events.done("complete") },
      })
    end

    t.it("asks before running an escalated tool", function()
      local asked = {}
      local ran = false

      run({
        transport = permission_script(),
        tools = write_tools(function()
          ran = true
          return Registry.ok("edited")
        end),
        scope = inline_scope(),
        on_permission = function(permission, decide)
          asked[#asked + 1] = permission
          decide(true)
        end,
      })

      t.eq(#asked, 1)
      t.eq(asked[1].tool, "edit")
      t.matches(asked[1].reason, "different file")
      t.eq(ran, true)
    end)

    t.it("runs the tool after approval and reports success", function()
      local record = run({
        transport = permission_script(),
        tools = write_tools(),
        scope = inline_scope(),
        on_permission = function(_, decide)
          decide(true)
        end,
      })

      t.eq(last_tool_result(record.conversation).ok, true)
      t.eq(last_tool_result(record.conversation).content, "edited")
    end)

    t.it("does not run the tool when the user refuses", function()
      local ran = false
      local record = run({
        transport = permission_script(),
        tools = write_tools(function()
          ran = true
          return Registry.ok("edited")
        end),
        scope = inline_scope(),
        on_permission = function(_, decide)
          decide(false)
        end,
      })

      t.eq(ran, false)
      t.eq(last_tool_result(record.conversation).ok, false)
      t.matches(last_tool_result(record.conversation).error, "denied")
    end)

    t.it("refuses rather than assuming consent when nobody can be asked", function()
      local ran = false
      local record = run({
        transport = permission_script(),
        tools = write_tools(function()
          ran = true
          return Registry.ok("edited")
        end),
        scope = inline_scope(),
      })

      t.eq(ran, false)
      t.matches(last_tool_result(record.conversation).error, "denied")
    end)

    t.it("grants only the approved target", function()
      local scope_used = inline_scope()
      local ran = 0

      run({
        transport = permission_script(),
        tools = write_tools(function()
          ran = ran + 1
          return Registry.ok("edited")
        end),
        scope = scope_used,
        on_permission = function(_, decide)
          decide(true)
        end,
      })

      -- The grant was consumed by the approved call, so the same target is
      -- escalated again rather than silently allowed from now on.
      local decision = scope_used:decide({
        kind = "write",
        path = "/tmp/loop-project/b.lua",
        range = { start_row = 1, end_row = 1 },
      })
      t.eq(ran, 1)
      t.eq(decision.kind, "needs_permission", "the grant is one-shot")
    end)
  end)

  t.describe("loop: failure and limits", function()
    t.it("fails on a transport error event", function()
      local transport = fake({ { Events.error("the vendor fell over") } })
      local record = run({ transport = transport })
      t.eq(record.result.ok, false)
      t.eq(record.result.error, "the vendor fell over")
      t.eq(record.result.reason, "error")
    end)

    t.it("fails when the transport emits a malformed event", function()
      local transport = fake({ { { type = "text_delta" }, Events.done("complete") } })
      local record = run({ transport = transport })
      t.eq(record.result.ok, false)
      t.matches(record.result.error, "invalid event")
    end)

    t.it("fails when the transport raises", function()
      local transport = {
        run = function()
          error("transport exploded")
        end,
      }
      local record = run({ transport = transport })
      t.eq(record.result.ok, false)
      t.matches(record.result.error, "transport failed")
    end)

    t.it("stops at max_turns", function()
      -- A model that asks for a tool forever must not loop forever.
      local transport = fake({
        { tool_event("call_1", "echo"), Events.done("tool_calls") },
        { tool_event("call_2", "echo"), Events.done("tool_calls") },
        { tool_event("call_3", "echo"), Events.done("tool_calls") },
        { tool_event("call_4", "echo"), Events.done("tool_calls") },
      })

      local record = run({ transport = transport, max_turns = 3 })
      t.eq(record.result.ok, false)
      t.eq(record.result.reason, "max_turns")
      t.eq(record.result.turns, 3)
      t.eq(transport.calls, 3)
    end)

    t.it("ignores events after the terminal one", function()
      local transport = fake({
        { Events.text_delta("kept"), Events.done("complete"), Events.text_delta("ignored") },
      })

      local record = run({ transport = transport })
      t.eq(record.conversation:list()[1].content, "kept")
    end)
  end)

  t.describe("loop: cancellation", function()
    t.it("stops an in-flight request", function()
      local transport = open_transport()
      local record = run({ transport = transport })

      t.eq(#record.results, 0, "the request is still open")
      record.handle:cancel()

      t.eq(#record.results, 1)
      -- Read from results, not record.result: this helper snapshots the result
      -- when the run starts, and for an async request it does not exist yet.
      t.eq(record.results[1].cancelled, true)
      t.eq(record.results[1].ok, false)
      t.eq(transport.cancelled, true, "the transport is told to stop")
    end)

    t.it("ignores events that arrive after cancelling", function()
      local transport = open_transport()
      local record = run({ transport = transport })
      record.handle:cancel()

      transport.emit(Events.text_delta("too late"))
      t.eq(#record.results, 1)
      t.eq(record.results[1].cancelled, true)
    end)

    t.it("is a no-op once the request has finished", function()
      local transport = fake({ { Events.done("complete") } })
      local record = run({ transport = transport })

      record.handle:cancel()
      t.eq(#record.results, 1)
      t.eq(record.result.cancelled, false)
      t.eq(record.result.ok, true)
    end)
  end)
end
