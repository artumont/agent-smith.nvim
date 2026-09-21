--- The Anthropic Messages API, streamed.
---
--- The third wire format, and the only one that is not OpenAI-shaped at all. It
--- exists for the Claude models: on Command Code a Claude id is served on
--- `/v1/messages` and nowhere else, and sending one to chat completions is
--- refused outright — `must be called via /provider/v1/messages`. See
--- spec/providers.md.
---
--- How it differs, all of which matters:
---
---   - `max_tokens` is **required**. There is no server-side default, so a
---     request without it is rejected rather than defaulted.
---   - The system prompt is a top-level `system` field, not a message with a
---     role. That is why the neutral conversation keeps it separate.
---   - Tool definitions carry `input_schema` rather than `parameters`, and are
---     flat otherwise.
---   - A tool call is a `tool_use` content block whose `input` is a **decoded
---     object**, not a JSON string. Tool results are `tool_result` blocks inside a
---     **user** message, not messages with a `tool` role.
---   - Stream events are typed on `type` and arrive as `content_block_*` frames
---     carrying an `index` that correlates the deltas.
---   - Usage is split across two events: the input side on `message_start`, the
---     output total on `message_delta`.
---
--- Three things this adapter deliberately does not do, stated so nobody assumes
--- otherwise:
---
---   - **No `x-api-key` and no `anthropic-version` header.** It targets the
---     gateways, which authenticate with a bearer token; measured: the version
---     header is not required, and a request without it is answered the same as
---     one with it. A direct api.anthropic.com endpoint needs both, and the shared
---     harness emits only a bearer header.
---   - **Thinking blocks are not sent back.** The neutral conversation keeps the
---     thinking text but not its signature, and a `thinking` block without one is
---     rejected. Nothing requests thinking today, so this costs nothing now;
---     turning it on would mean carrying the signature through the conversation.
---   - **Prompt caching is not requested.** The cache counters are read when a
---     response reports them, but no `cache_control` markers are placed, so they
---     will normally be absent.

local Base = require("agent-smith.transport.base")
local Events = require("agent-smith.agent.events")
local Json = require("agent-smith.json")

local M = {}

M.TOKEN_ENV = Base.TOKEN_ENV
M.DEFAULT_TIMEOUT_MS = Base.DEFAULT_TIMEOUT_MS
M.DEFAULT_USER_AGENT = Base.DEFAULT_USER_AGENT

M.ENDPOINT = "/messages"

--- Sent when the caller does not choose a value, because the API requires one.
--- Well below every current model's ceiling: the point is to send something
--- valid, not to reserve the window.
M.DEFAULT_MAX_TOKENS = 8192

--- `stop_reason` translated into the schema's vocabulary.
---
--- Anything unlisted ends the turn, which is the safe reading: an unknown reason
--- means the model stopped, and looping on it would be worse than stopping.
M.STOP_REASONS = {
  end_turn = "complete",
  stop_sequence = "complete",
  tool_use = "tool_calls",
  max_tokens = "length",
  refusal = "content_filter",
}

--- Turn one neutral message into the wire shape, or nil to drop it.
---
--- Dropping matters: an assistant turn with neither text nor tool calls would
--- encode as empty content, which the API rejects. Omitting it is better than
--- sending a request that cannot be parsed.
---@return table|nil message
local function wire_message(message)
  if message.role == "user" then
    return { role = "user", content = message.content }
  end

  if message.role == "assistant" then
    local content = {}
    if type(message.content) == "string" and message.content ~= "" then
      content[#content + 1] = { type = "text", text = message.content }
    end
    for _, use in ipairs(message.tool_uses or {}) do
      content[#content + 1] = {
        type = "tool_use",
        id = use.id,
        name = use.name,
        -- An object even when empty. `input` is not a JSON string here, and an
        -- unmarked empty table would encode as [] where the API wants {}.
        input = Json.object(use.arguments or {}),
      }
    end
    if #content == 0 then
      return nil
    end
    return { role = "assistant", content = content }
  end

  if message.role == "tool" then
    -- A user message holding the results, which is where the API expects them.
    local content = {}
    for _, result in ipairs(message.results or {}) do
      content[#content + 1] = {
        type = "tool_result",
        tool_use_id = result.id,
        content = result.ok and result.content or ("error: " .. tostring(result.error)),
        is_error = not result.ok,
      }
    end
    if #content == 0 then
      return nil
    end
    return { role = "user", content = content }
  end

  return nil
end

local function wire_messages(messages)
  local wire = {}
  for _, message in ipairs(messages) do
    local converted = wire_message(message)
    if converted then
      wire[#wire + 1] = converted
    end
  end
  return wire
end

--- Flat, with `input_schema` where every other vendor says `parameters`.
local function wire_tools(schemas)
  local tools = {}
  for _, schema in ipairs(schemas) do
    tools[#tools + 1] = {
      name = schema.name,
      description = schema.description,
      input_schema = schema.parameters,
    }
  end
  return tools
end

--- Build the request body. Pure: no I/O, no state.
---@return table body
function M.wire_request(options, request)
  local body = {
    model = options.model,
    -- Required, unlike every comparable field on the other adapters.
    max_tokens = options.max_tokens or M.DEFAULT_MAX_TOKENS,
    messages = wire_messages(request.messages),
    stream = true,
  }

  if type(request.system) == "string" and request.system ~= "" then
    body.system = request.system
  end

  local tools = wire_tools(request.tools or {})
  if #tools > 0 then
    body.tools = tools
    -- Every tool here was already offered by the loop, and prose remains a valid
    -- answer, so the choice stays with the model.
    body.tool_choice = { type = "auto" }
  end

  return body
end

--- Usage field names.
---
--- Anthropic names the cache counters differently from everyone else, and reports
--- no separate reasoning count: thinking tokens are counted as output.
local function usage_fields(usage)
  local fields = {}

  if type(usage.input_tokens) == "number" then
    fields.input_tokens = usage.input_tokens
  end
  if type(usage.output_tokens) == "number" then
    fields.output_tokens = usage.output_tokens
  end
  if type(usage.cache_read_input_tokens) == "number" then
    fields.cache_read_tokens = usage.cache_read_input_tokens
  end
  if type(usage.cache_creation_input_tokens) == "number" then
    fields.cache_write_tokens = usage.cache_creation_input_tokens
  end

  return fields
end

local function new_state()
  -- Keyed by content-block index, which is what the deltas reference.
  return { calls = {}, stop_reason = nil, emitted = false }
end

--- Emit a tracked tool call, once.
---@return boolean ok False when the call was malformed, which is terminal.
local function emit_call(state, index, emit)
  local call = state.calls[index]
  if not call or call.done then
    return true
  end

  -- Marked before emitting, so a later flush cannot report the same failure
  -- twice: either way the call is finished.
  call.done = true

  if type(call.id) ~= "string" or call.id == "" or type(call.name) ~= "string" or call.name == "" then
    emit(
      Events.error(("a tool call arrived incomplete: id=%q name=%q"):format(tostring(call.id), tostring(call.name)))
    )
    return false
  end

  -- Assembled from `input_json_delta` fragments, so it is a JSON string built up
  -- across several events rather than an object delivered whole.
  local arguments = {}
  if type(call.json) == "string" and call.json ~= "" then
    local decoded, parsed = pcall(vim.json.decode, call.json)
    if not decoded or type(parsed) ~= "table" then
      emit(Events.error(("tool call %q had arguments that are not valid JSON: %s"):format(call.name, call.json)))
      return false
    end
    arguments = parsed
  end

  state.emitted = true
  emit(Events.tool_use(call.id, call.name, arguments))
  return true
end

--- The `done` reason for the state so far.
---
--- A call that was actually emitted wins over the vendor's stop reason. If a tool
--- was requested the loop has to run it whichever reason arrived, and a truncated
--- stream reports no reason at all — so without this a cut-off stream would report
--- a plain completion and the call would sit unrun.
---
--- Declared above its callers deliberately: a Lua `local function` is not hoisted,
--- so defining it further down would leave the call sites reading a nil global.
---@return string
local function terminal_reason(state)
  if state.emitted then
    return "tool_calls"
  end
  return M.STOP_REASONS[state.stop_reason] or "complete"
end

--- Map one decoded stream event onto typed events.
---@return boolean terminal True once the message has been reported complete.
local function receive(state, chunk, emit)
  local kind = chunk.type

  if kind == "message_start" then
    local message = chunk.message or {}
    if type(message.usage) == "table" then
      local fields = usage_fields(message.usage)
      -- The output count here is a placeholder — the API sends 1, because nothing
      -- has been generated yet — and the real total arrives on message_delta.
      -- Reporting both would add the placeholder to the total.
      fields.output_tokens = nil
      if next(fields) then
        emit(Events.usage(fields))
      end
    end
    return false
  end

  if kind == "content_block_start" then
    local block = chunk.content_block
    if type(block) == "table" and block.type == "tool_use" then
      state.calls[chunk.index or 0] = {
        id = block.id,
        name = block.name,
        -- The start frame carries `input: {}`; the arguments arrive as
        -- partial_json deltas, so that field is deliberately not read here.
        json = "",
      }
    end
    return false
  end

  if kind == "content_block_delta" then
    local delta = chunk.delta or {}

    if delta.type == "text_delta" then
      if type(delta.text) == "string" and delta.text ~= "" then
        emit(Events.text_delta(delta.text))
      end
    elseif delta.type == "thinking_delta" then
      if type(delta.thinking) == "string" and delta.thinking ~= "" then
        emit(Events.thinking_delta(delta.thinking))
      end
    elseif delta.type == "input_json_delta" then
      local call = state.calls[chunk.index or 0]
      if call and type(delta.partial_json) == "string" then
        call.json = call.json .. delta.partial_json
      end
    end

    -- signature_delta, citations_delta and whatever comes next carry nothing the
    -- event schema has a place for.
    return false
  end

  if kind == "content_block_stop" then
    -- Emitted per block rather than all at the end, unlike the Responses adapter:
    -- blocks arrive strictly in order here, so there is no ordering problem to
    -- solve by waiting.
    return not emit_call(state, chunk.index or 0, emit)
  end

  if kind == "message_delta" then
    local delta = chunk.delta or {}
    if type(delta.stop_reason) == "string" then
      state.stop_reason = delta.stop_reason
    end
    if type(chunk.usage) == "table" then
      local fields = usage_fields(chunk.usage)
      if next(fields) then
        emit(Events.usage(fields))
      end
    end
    return false
  end

  if kind == "message_stop" then
    -- Flush anything a truncated stream never closed, so a cut-off response still
    -- reports the calls it assembled rather than losing them silently.
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

    emit(Events.done(terminal_reason(state)))
    return true
  end

  if kind == "error" then
    emit(Events.error(Base.error_message(chunk.error or chunk)))
    return true
  end

  -- `ping`, and whatever else the vendor adds: nothing to report.
  return false
end

--- The stream ended without a terminal event, so report what was assembled.
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

  emit(Events.done(terminal_reason(state)))
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

--- Build a transport.
---@param options table { base_url, api_key, model, max_tokens?, session_header?,
---   user_agent?, timeout_ms?, execute? }
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
