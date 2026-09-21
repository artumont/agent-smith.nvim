--- The OpenAI Responses API, streamed.
---
--- The second wire format. The GPT-family models on the gateways are served here
--- and *not* on chat completions, so without this they are unreachable
--- (spec/providers.md).
---
--- Shapes verified against a real client implementation rather than recalled:
--- the event names, the item shapes and the field names below were read out of
--- opencode's bundled code, which consumes this API, and cross-checked against
--- OpenAI's streaming guide. Where that was ambiguous the reader is permissive.
---
--- How it differs from chat completions, all of which matters:
---
---   - `input` instead of `messages`, and the system prompt is a top-level
---     `instructions` field rather than a message.
---   - Tool definitions are **flat**: name, description and parameters sit at the
---     top level, not nested under `function`.
---   - Tool calls are first-class items in the input, `function_call`, and their
---     results are `function_call_output` — not messages with a role.
---   - `arguments` is a JSON *string*, exactly as on chat completions.
---   - Stream events are typed on a `type` field, and text arrives as a `delta`
---     rather than inside `choices`.

local Base = require("agent-smith.transport.base")
local Events = require("agent-smith.agent.events")
local Json = require("agent-smith.json")

local M = {}

M.TOKEN_ENV = Base.TOKEN_ENV
M.DEFAULT_TIMEOUT_MS = Base.DEFAULT_TIMEOUT_MS
M.DEFAULT_USER_AGENT = Base.DEFAULT_USER_AGENT

M.ENDPOINT = "/responses"

--- Incomplete reasons that map onto the schema's vocabulary.
local INCOMPLETE_REASONS = {
  max_output_tokens = "length",
  content_filter = "content_filter",
}

--- Event types carrying reasoning, whichever name the vendor uses.
local REASONING_EVENTS = {
  ["response.reasoning_summary_text.delta"] = true,
  ["response.reasoning_text.delta"] = true,
  ["response.reasoning_summary.delta"] = true,
}

--- Translate the neutral conversation into Responses input items.
---
--- Unlike chat completions this is a mixed list: role messages for prose, and
--- typed items for tool calls and their results.
local function wire_input(messages)
  local input = {}

  for _, message in ipairs(messages) do
    if message.role == "user" then
      input[#input + 1] = { role = "user", content = message.content }
    elseif message.role == "assistant" then
      if message.content ~= "" then
        input[#input + 1] = { role = "assistant", content = message.content }
      end
      for _, use in ipairs(message.tool_uses) do
        input[#input + 1] = {
          type = "function_call",
          call_id = use.id,
          name = use.name,
          arguments = Json.encode_object(use.arguments),
        }
      end
    elseif message.role == "tool" then
      for _, result in ipairs(message.results) do
        input[#input + 1] = {
          type = "function_call_output",
          call_id = result.id,
          output = result.ok and result.content or ("error: " .. tostring(result.error)),
        }
      end
    end
  end

  return input
end

--- Tool definitions are flat here, unlike chat completions where the same
--- fields are nested under `function`.
local function wire_tools(schemas)
  local tools = {}
  for _, schema in ipairs(schemas) do
    tools[#tools + 1] = {
      type = "function",
      name = schema.name,
      description = schema.description,
      parameters = schema.parameters,
    }
  end
  return tools
end

--- Build the request body. Pure: no I/O, no state.
---@return table body
function M.wire_request(options, request)
  local body = {
    model = options.model,
    input = wire_input(request.messages),
    stream = true,
    -- We keep the conversation ourselves, so there is no reason to ask the
    -- vendor to store it too: it costs nothing to omit and avoids leaving a
    -- transcript on their side. Switchable for anyone who wants server-side
    -- state.
    store = options.store == true,
  }

  if type(request.system) == "string" and request.system ~= "" then
    body.instructions = request.system
  end

  local tools = wire_tools(request.tools or {})
  if #tools > 0 then
    body.tools = tools
  end

  return body
end

--- Build the argv and environment for one request, on this adapter's endpoint.
---@return string[] command
---@return table env
function M.build_command(options)
  local fields = {}
  for key, value in pairs(options) do
    fields[key] = value
  end
  fields.endpoint = fields.endpoint or M.ENDPOINT
  return Base.build_command(fields)
end

--- Usage field names, accepting either documented shape.
---
--- The Responses API reports `input_tokens_details.cached_tokens`; some fields
--- also arrive flat. Being permissive costs nothing because the usage event
--- ignores fields it does not know.
local function usage_fields(usage)
  local fields = {}

  if type(usage.input_tokens) == "number" then
    fields.input_tokens = usage.input_tokens
  end
  if type(usage.output_tokens) == "number" then
    fields.output_tokens = usage.output_tokens
  end

  local cached = usage.cached_tokens
  if type(cached) ~= "number" and type(usage.input_tokens_details) == "table" then
    cached = usage.input_tokens_details.cached_tokens
  end
  if type(cached) == "number" then
    fields.cache_read_tokens = cached
  end

  local reasoning = usage.reasoning_tokens
  if type(reasoning) ~= "number" and type(usage.output_tokens_details) == "table" then
    reasoning = usage.output_tokens_details.reasoning_tokens
  end
  if type(reasoning) == "number" then
    fields.reasoning_tokens = reasoning
  end

  return fields
end

local function new_state()
  -- Keyed by output_index, because that is how the deltas correlate.
  return { calls = {}, incomplete = nil, emitted = false }
end

--- Emit a tracked call, once.
local function emit_call(state, index, emit)
  local call = state.calls[index]
  if not call or call.done then
    return true
  end

  -- Marked before emitting, so a later flush cannot report the same failure a
  -- second time: the call is finished either way.
  call.done = true

  if type(call.call_id) ~= "string" or call.call_id == "" or type(call.name) ~= "string" or call.name == "" then
    emit(Events.error(("a tool call arrived incomplete: id=%q name=%q"):format(
      tostring(call.call_id),
      tostring(call.name)
    )))
    return false
  end

  local arguments = {}
  if type(call.arguments) == "string" and call.arguments ~= "" then
    local decoded, parsed = pcall(vim.json.decode, call.arguments)
    if not decoded or type(parsed) ~= "table" then
      emit(
        Events.error(
          ("tool call %q had arguments that are not valid JSON: %s"):format(call.name, call.arguments)
        )
      )
      return false
    end
    arguments = parsed
  end

  state.emitted = true
  emit(Events.tool_use(call.call_id, call.name, arguments))
  return true
end

local function track(state, index, item)
  local call = state.calls[index]
  if not call then
    call = { arguments = "" }
    state.calls[index] = call
  end
  if type(item.call_id) == "string" then
    call.call_id = item.call_id
  end
  if type(item.name) == "string" then
    call.name = item.name
  end
  if type(item.arguments) == "string" and item.arguments ~= "" then
    call.arguments = item.arguments
  end
  return call
end

--- Map one decoded stream event onto typed events.
---@return boolean terminal True once the response has been reported complete.
local function receive(state, chunk, emit)
  local kind = chunk.type

  if kind == "response.output_text.delta" then
    if type(chunk.delta) == "string" and chunk.delta ~= "" then
      emit(Events.text_delta(chunk.delta))
    end
    return false
  end

  if REASONING_EVENTS[kind] then
    if type(chunk.delta) == "string" and chunk.delta ~= "" then
      emit(Events.thinking_delta(chunk.delta))
    end
    return false
  end

  if kind == "response.output_item.added" then
    local item = chunk.item
    if type(item) == "table" and item.type == "function_call" then
      track(state, chunk.output_index or 0, item)
    end
    return false
  end

  if kind == "response.function_call_arguments.delta" then
    local index = chunk.output_index or 0
    local call = state.calls[index] or track(state, index, {})
    if type(chunk.delta) == "string" then
      call.arguments = (call.arguments or "") .. chunk.delta
    end
    return false
  end

  if kind == "response.output_item.done" then
    local item = chunk.item
    if type(item) == "table" and item.type == "function_call" then
      -- Tracked, not emitted. Calls are flushed together when the response
      -- completes, so they come out in index order rather than arrival order.
      -- Nothing is lost by waiting: the loop only acts on them once `done`
      -- arrives.
      track(state, chunk.output_index or 0, item)
    end
    return false
  end

  if kind == "response.completed" or kind == "response.incomplete" then
    local response = chunk.response or {}

    if type(response.usage) == "table" then
      local fields = usage_fields(response.usage)
      if next(fields) then
        emit(Events.usage(fields))
      end
    end

    if type(response.incomplete_details) == "table" then
      state.incomplete = response.incomplete_details.reason
    end

    -- Flush in index order so the loop sees tool calls in the order asked for.
    local indexes = {}
    for index in pairs(state.calls) do
      indexes[#indexes + 1] = index
    end
    table.sort(indexes)
    for _, index in ipairs(indexes) do
      if not emit_call(state, index, emit) then
        return true
      end
    end

    local reason = "complete"
    if state.emitted then
      reason = "tool_calls"
    elseif INCOMPLETE_REASONS[state.incomplete] then
      reason = INCOMPLETE_REASONS[state.incomplete]
    end

    emit(Events.done(reason))
    return true
  end

  if kind == "response.failed" then
    local response = chunk.response or {}
    local error = response.error or {}
    emit(Events.error(Base.error_message(error)))
    return true
  end

  if kind == "error" then
    emit(Events.error(Base.error_message(chunk)))
    return true
  end

  -- Everything else is lifecycle noise: response.created, output_text.done,
  -- content_part.added, and whatever the vendor adds next.
  return false
end

--- Nothing is left over: the terminal event carries everything, and the base
--- calls this when the stream ends without one.
local function finish(state, emit)
  local indexes = {}
  for index in pairs(state.calls) do
    indexes[#indexes + 1] = index
  end
  table.sort(indexes)
  for _, index in ipairs(indexes) do
    if not emit_call(state, index, emit) then
      return
    end
  end

  emit(Events.done(state.emitted and "tool_calls" or INCOMPLETE_REASONS[state.incomplete] or "complete"))
end

--- Build a transport.
---@param options table { base_url, api_key, model, session_header?, user_agent?,
---   timeout_ms?, execute?, store? }
---@return table transport { run = function(request, on_event) -> handle }
function M.new(options)
  return Base.new({
    endpoint = M.ENDPOINT,
    options = options,
    build_request = M.wire_request,
    new_state = new_state,
    receive = receive,
    finish = finish,
  })
end

return M
