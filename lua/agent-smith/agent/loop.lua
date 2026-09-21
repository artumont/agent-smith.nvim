--- The agent loop.
---
--- Owns the turn loop: ask the transport, collect the stream, run the tools the
--- model asked for, feed the results back, repeat until the model stops or a
--- limit is hit. See spec/decisions/0001-own-the-agent-loop.md.
---
--- Transport interface
---
--- A transport is `{ run = function(request, on_event) -> handle }` where:
---
---   request = { system, messages, tools }
---   on_event(event)   typed events; exactly one terminal (done or error)
---   handle.cancel()   optional
---
--- Events may arrive after `run` returns, which is the normal case for a real
--- transport, and may also arrive fully synchronously, which is what the test
--- fake does. Both are handled: a turn that completes during `run` is processed
--- once `run` returns rather than re-entering the transport.
---
--- Permissions
---
--- A tool can answer `needs_permission` instead of running. The loop asks
--- `on_permission`, and on approval grants the target once in the scope and
--- re-dispatches the same call. With no `on_permission` the request is refused:
--- silence is not consent.

local Events = require("agent-smith.agent.events")

local M = {}

M.DEFAULT_MAX_TURNS = 10

local function to_tool_result(id, outcome)
  if outcome.needs_permission then
    -- Should not happen: the loop resolves permission requests before this.
    return Events.tool_result_error(id, "the tool still needs permission")
  end
  if outcome.ok then
    return Events.tool_result_ok(id, outcome.content)
  end
  return Events.tool_result_error(id, outcome.error)
end

--- Run a request to completion.
---
--- Returns a handle immediately. For a synchronous transport the whole request
--- may have already finished by the time it is returned.
---
---@param options table
---   - transport: table        Required. See the transport interface above.
---   - tools: table            Required. A registry from agent-smith.tools.
---   - scope: table            Required. From agent-smith.agent.scope.
---   - conversation: table     Required. From agent-smith.agent.messages.
---   - on_event: fun(event)    Every valid event, for the UI to render.
---   - on_permission: fun(permission, decide)  decide(approved: boolean)
---   - on_done: fun(result)    result = { ok, error?, reason?, turns, usage, cancelled }
---   - max_turns: number|nil   Model round trips. Default 10.
---@return table handle { cancel = fun() }
function M.run(options)
  assert(type(options) == "table", "loop.run needs an options table")
  local transport = assert(options.transport, "the loop needs a transport")
  local registry = assert(options.tools, "the loop needs a tool registry")
  local scope = assert(options.scope, "the loop needs a scope")
  local conversation = assert(options.conversation, "the loop needs a conversation")

  -- Zero-argument fallbacks would make the analyser treat every call to these
  -- as passing a redundant argument, so the fallbacks take one.
  local on_event = options.on_event or function(_) end
  local on_done = options.on_done or function(_) end
  local on_permission = options.on_permission
  local max_turns = options.max_turns or M.DEFAULT_MAX_TURNS

  local state = { finished = false, cancelled = false, usage = {} }
  local handle = {}
  local turn = 0
  local transport_handle = nil
  local in_run = false
  local deferred = false

  ---@class SmithTurn
  ---@field text string
  ---@field thinking string
  ---@field tool_uses table[]
  ---@field error string|nil
  ---@field reason string|nil
  ---@field ended boolean

  --- The turn in flight. Kept typed and non-nil so that reading its fields does
  --- not read as a nil dereference.
  ---@type SmithTurn
  local turn_state = { text = "", thinking = "", tool_uses = {}, ended = true }

  local function finish(result)
    if state.finished then
      return
    end
    state.finished = true
    result.usage = state.usage
    result.cancelled = state.cancelled
    result.turns = turn
    on_done(result)
  end

  local function accumulate_usage(event)
    for _, field in ipairs(Events.token_fields) do
      local value = event[field]
      if type(value) == "number" then
        state.usage[field] = (state.usage[field] or 0) + value
      end
    end
  end

  local next_turn
  local dispatch_tools

  --- Handle a stream that has ended: record the turn and decide what is next.
  local function advance()
    if state.finished then
      return
    end
    if in_run then
      -- The transport completed synchronously. Come back once it has returned,
      -- rather than re-entering it from inside its own call.
      deferred = true
      return
    end

    local current = turn_state

    if current.error then
      finish({ ok = false, error = current.error, reason = "error" })
      return
    end

    conversation:append_assistant({
      text = current.text,
      thinking = current.thinking,
      tool_uses = current.tool_uses,
    })

    if state.cancelled or current.reason == "cancelled" then
      finish({ ok = false, error = "cancelled", reason = "cancelled" })
      return
    end

    if #current.tool_uses > 0 then
      dispatch_tools(current.tool_uses, 1, {})
      return
    end

    finish({ ok = true, reason = current.reason or "complete" })
  end

  --- Run each requested tool in order, then start the next turn.
  dispatch_tools = function(tool_uses, index, results)
    if state.finished then
      return
    end

    local tool_use = tool_uses[index]
    if tool_use == nil then
      conversation:append_tool_results(results)
      next_turn()
      return
    end

    local function record(outcome)
      if state.finished then
        return
      end
      results[#results + 1] = to_tool_result(tool_use.id, outcome)
      dispatch_tools(tool_uses, index + 1, results)
    end

    registry:dispatch(tool_use, scope, function(outcome)
      if state.finished then
        return
      end

      if not outcome.needs_permission then
        record(outcome)
        return
      end

      local permission = outcome.needs_permission

      local function resolve(approved)
        if state.finished then
          return
        end
        if not approved then
          results[#results + 1] = Events.tool_result_error(
            tool_use.id,
            ("the user denied this: %s"):format(permission.reason)
          )
          dispatch_tools(tool_uses, index + 1, results)
          return
        end

        -- Grant exactly this target once, then run the same call again.
        scope:grant(permission.target)
        registry:dispatch(tool_use, scope, record, { turn = turn })
      end

      if on_permission then
        on_permission(permission, resolve)
      else
        resolve(false)
      end
    end, { turn = turn })
  end

  --- Ask the transport for one turn.
  next_turn = function()
    if state.finished then
      return
    end
    if state.cancelled then
      finish({ ok = false, error = "cancelled", reason = "cancelled" })
      return
    end

    if turn >= max_turns then
      -- The check runs before incrementing, so `turn` stays at the number of
      -- turns that actually ran instead of over-reporting by one.
      finish({
        ok = false,
        reason = "max_turns",
        error = ("stopped after %d turns without finishing"):format(max_turns),
      })
      return
    end

    turn = turn + 1

    local current = { text = "", thinking = "", tool_uses = {}, error = nil, reason = nil, ended = false }
    turn_state = current

    local function on_stream_event(event)
      if state.finished or state.cancelled or current.ended then
        return
      end

      local valid, problem = Events.validate(event)
      if not valid then
        -- A malformed event is a transport bug. Failing loudly beats guessing.
        current.ended = true
        current.error = "transport emitted an invalid event: " .. tostring(problem)
        advance()
        return
      end

      on_event(event)

      if event.type == "text_delta" then
        current.text = current.text .. event.text
      elseif event.type == "thinking_delta" then
        current.thinking = current.thinking .. event.text
      elseif event.type == "tool_use" then
        current.tool_uses[#current.tool_uses + 1] = event
      elseif event.type == "usage" then
        accumulate_usage(event)
      elseif event.type == "done" then
        current.ended = true
        current.reason = event.reason
        advance()
      elseif event.type == "error" then
        current.ended = true
        current.error = event.message
        advance()
      end
    end

    local request = {
      system = conversation:system(),
      messages = conversation:list(),
      tools = registry:schemas(),
      -- Lets a transport carry conversation identity to a gateway that uses it
      -- for prompt-cache routing. Nil when the conversation has no id.
      session = conversation:id(),
    }

    in_run = true
    local called, result = pcall(transport.run, request, on_stream_event)
    in_run = false

    if not called then
      finish({ ok = false, error = "transport failed: " .. tostring(result), reason = "transport" })
      return
    end

    transport_handle = result

    if deferred then
      deferred = false
      advance()
    end
  end

  --- Stop the request. In-flight tool and transport work is abandoned.
  function handle:cancel()
    if state.finished then
      return
    end
    state.cancelled = true
    if transport_handle and type(transport_handle.cancel) == "function" then
      pcall(transport_handle.cancel, transport_handle)
    end
    finish({ ok = false, error = "cancelled", reason = "cancelled" })
  end

  next_turn()

  return handle
end

return M
