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
---
--- Stalls
---
--- A request with no event for `stall_timeout_ms` is aborted, so a command that
--- never comes back cannot hang the run forever. The budget is *inactivity*, not
--- total duration: a stream that keeps dribbling tokens is working, however slow
--- it is, and streaming a long answer is not a stall. Waiting on the user — a
--- permission question — is not a stall either, so the timer is disarmed while
--- `on_permission` is pending.
--- See spec/decisions/0014-stalled-runs-are-aborted.md.

local Events = require("agent-smith.agent.events")
local Usage = require("agent-smith.usage")

local M = {}

M.DEFAULT_MAX_TURNS = 10

--- How long the loop tolerates no activity at all before giving up.
---
--- Two minutes is chosen against the stall it is meant to catch: a sandboxed
--- command whose process died without its callback ever firing, which leaves a
--- tool call that will never produce a result. Every legitimate wait is either
--- shorter (the bash tool's own default timeout is one minute) or keeps
--- producing events. Set `stall_timeout_ms` to 0 to disable the watchdog.
M.DEFAULT_STALL_TIMEOUT_MS = 120000

--- A budget as whole seconds, with a decimal only when it is not whole.
---
--- `120 s` reads better than `120.0 s`, and a sub-second budget — which only a
--- test or a deliberately impatient caller configures — would otherwise be
--- reported as `0 s`, saying nothing about how long it actually waited.
---@param ms number
---@return string
function M.format_seconds(ms)
  if ms % 1000 == 0 then
    return ("%d s"):format(ms / 1000)
  end
  return ("%.1f s"):format(ms / 1000)
end

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
---   - stall_timeout_ms: number|nil  Inactivity budget. Default 120000, 0 disables.
---@return table handle { cancel = fun(), steer = fun(text) -> boolean }
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
  local stall_timeout_ms = options.stall_timeout_ms
  if stall_timeout_ms == nil then
    stall_timeout_ms = M.DEFAULT_STALL_TIMEOUT_MS
  end

  local state = { finished = false, cancelled = false, usage = {}, activity = "running", pending = {}, steered = 0 }
  local handle = {}
  local turn = 0
  local transport_handle = nil
  local in_run = false
  local deferred = false
  local stall_timer = nil

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

  -- Declared before `finish`, which disarms the watchdog: a `local function`
  -- written after it would be a different (later, global-shadowing) binding and
  -- `finish` would call a global that is always nil.
  local disarm_stall

  local function finish(result)
    if state.finished then
      return
    end
    state.finished = true
    disarm_stall()
    result.usage = state.usage
    result.cancelled = state.cancelled
    result.turns = turn
    -- Steers that reached the model, and steers the run ended before it could
    -- deliver — the second is what makes a dropped message visible instead of
    -- silent.
    result.steered = state.steered
    result.undelivered_steers = #state.pending
    -- Rendered here so a caller has something to show without reimplementing
    -- the arithmetic. Cost is not included: that needs per-model prices.
    result.summary = Usage.render(state.usage, { turns = turn })
    on_done(result)
  end

  local next_turn
  local dispatch_tools

  --- Stop the watchdog, if one is armed.
  disarm_stall = function()
    if stall_timer then
      stall_timer:stop()
      if not stall_timer:is_closing() then
        stall_timer:close()
      end
      stall_timer = nil
    end
  end

  --- The watchdog fired: nothing has moved for the whole budget.
  ---
  --- The in-flight transport is stopped rather than left to deliver into a
  --- finished run. `cancelled` is deliberately left alone, because this is not
  --- the user cancelling — the caller needs to be able to tell the two apart.
  local function on_stall()
    if state.finished then
      return
    end

    if transport_handle and type(transport_handle.cancel) == "function" then
      pcall(transport_handle.cancel, transport_handle)
    end

    finish({
      ok = false,
      reason = "stalled",
      error = ("no activity for %s while %s"):format(
        M.format_seconds(stall_timeout_ms),
        state.activity
      ),
    })
  end

  --- Arm, or re-arm, the inactivity budget.
  ---
  --- Called for every event as well as before every request, because what is
  --- being watched is silence, and any event is proof of progress. A budget of
  --- zero or less disables the watchdog entirely.
  local function arm_stall(activity)
    state.activity = activity or state.activity

    if not stall_timeout_ms or stall_timeout_ms <= 0 then
      return
    end
    if stall_timer then
      stall_timer:stop()
    else
      stall_timer = vim.uv.new_timer()
    end
    stall_timer:start(stall_timeout_ms, 0, vim.schedule_wrap(on_stall))
  end

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

    if #state.pending > 0 then
      -- The user had something to add while this turn was streaming, so answer it
      -- rather than stopping on them. `max_turns` still bounds the run, and
      -- whatever never made it is counted in the result.
      next_turn()
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

    arm_stall(("running %s"):format(tool_use.name))

    registry:dispatch(tool_use, scope, function(outcome)
      if state.finished then
        return
      end

      if not outcome.needs_permission then
        record(outcome)
        return
      end

      local permission = outcome.needs_permission

      -- A question put to the user has no deadline. The watchdog would
      -- otherwise abort a run while somebody reads the dialog.
      disarm_stall()

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
        arm_stall(("running %s"):format(tool_use.name))
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

    -- Anything steered while the previous turn ran goes in here, as the last user
    -- message before the request. See `handle:steer` for why it waits until now.
    if #state.pending > 0 then
      for _, message in ipairs(state.pending) do
        conversation:append_user(message)
      end
      state.steered = state.steered + #state.pending
      state.pending = {}
    end

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

      -- Any event, of any kind, is proof the run is still moving.
      arm_stall()

      on_event(event)

      if event.type == "text_delta" then
        current.text = current.text .. event.text
      elseif event.type == "thinking_delta" then
        current.thinking = current.thinking .. event.text
      elseif event.type == "tool_use" then
        current.tool_uses[#current.tool_uses + 1] = event
      elseif event.type == "usage" then
        Usage.add(state.usage, event)
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
    arm_stall("waiting for the model")
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

  --- Say something to the model while the run is in flight.
  ---
  --- The message is **queued**, and flushed when the next request is built:
  ---
  ---   - Not delivered to the turn already streaming. The transport has been told
  ---     what the prompt is and is mid-answer; steering means "take this into
  ---     account from here on", and cancelling is what an interruption is.
  ---   - Not delivered at the moment it arrives. A steer usually arrives while a
  ---     tool is running, and the conversation at that point is one assistant
  ---     message holding `tool_use`s whose results have not been appended yet.
  ---     Appending a user message there would put it between the tool calls and
  ---     their results, which neither wire format accepts: results must follow the
  ---     calls they answer. Flushing at the start of a turn puts it after them.
  ---   - Not droppable either. A steer that arrives as the model stops would
  ---     otherwise be lost silently, having been accepted and logged, so a pending
  ---     steer makes the run continue for one more turn (`max_turns` still bounds
  ---     it). What the user typed reaches the model, or the run ends because it ran
  ---     out of turns, and the count of what never arrived is in the result.
  ---@param text string
  ---@return boolean accepted False when the run is over or the text is blank.
  function handle:steer(text)
    if state.finished or state.cancelled then
      return false
    end
    if type(text) ~= "string" then
      return false
    end

    local message = vim.trim(text)
    if message == "" then
      return false
    end

    state.pending[#state.pending + 1] = message
    return true
  end

  next_turn()

  return handle
end

return M
