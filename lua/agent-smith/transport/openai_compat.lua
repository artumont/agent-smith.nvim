--- OpenAI-compatible chat completions, streamed.
---
--- The first transport, for custom providers and for the open models on the
--- gateways (spec/decisions/0008-transport-openai-compatible-first.md).
--- GPT-family models are served on the Responses API and Claude models on
--- Anthropic Messages, which are separate adapters.
---
--- This file is **translation only**. The curl invocation, SSE framing, streaming
--- and cancellation live in agent-smith.transport.base. What is here is the wire
--- body and the mapping from stream chunks to typed events.
---
--- The one thing the base cannot do for us: **tool arguments stream as
--- fragments.** `delta.tool_calls[].function.arguments` arrives as partial JSON
--- across many chunks, keyed by index. The event schema promises the loop a
--- complete decoded table, so fragments are reassembled here and a `tool_use` is
--- emitted only once the stream ends.

local Base = require("agent-smith.transport.base")
local Events = require("agent-smith.agent.events")
local Json = require("agent-smith.json")

local M = {}

-- Re-exported so the harness knobs this adapter is configured by are reachable
-- from here without a second require.
M.TOKEN_ENV = Base.TOKEN_ENV
M.DEFAULT_TIMEOUT_MS = Base.DEFAULT_TIMEOUT_MS
M.DEFAULT_USER_AGENT = Base.DEFAULT_USER_AGENT

M.ENDPOINT = "/chat/completions"

--- Vendor finish reasons mapped onto the event schema's vocabulary.
local FINISH_REASONS = {
  stop = "complete",
  tool_calls = "tool_calls",
  length = "length",
  content_filter = "content_filter",
}

--- Translate the neutral conversation into wire messages.
---
--- A tool-results entry becomes one wire message per result, because that is the
--- shape chat completions uses: results are not grouped there.
local function wire_messages(system, messages)
  local wire = {}

  if system and system ~= "" then
    wire[#wire + 1] = { role = "system", content = system }
  end

  for _, message in ipairs(messages) do
    if message.role == "user" then
      wire[#wire + 1] = { role = "user", content = message.content }
    elseif message.role == "assistant" then
      local entry = { role = "assistant", content = message.content }
      if #message.tool_uses > 0 then
        entry.tool_calls = {}
        for _, use in ipairs(message.tool_uses) do
          entry.tool_calls[#entry.tool_calls + 1] = {
            id = use.id,
            type = "function",
            ["function"] = {
              name = use.name,
              -- The wire wants arguments as a JSON string, not an object. An
              -- empty table must encode as {} rather than []: a vendor parses
              -- this field as an object.
              arguments = Json.encode_object(use.arguments),
            },
          }
        end
      end
      wire[#wire + 1] = entry
    elseif message.role == "tool" then
      for _, result in ipairs(message.results) do
        wire[#wire + 1] = {
          role = "tool",
          tool_call_id = result.id,
          content = result.ok and result.content or ("error: " .. tostring(result.error)),
        }
      end
    end
  end

  return wire
end

--- Wrap tool schemas in the shape chat completions expects: nested under
--- `function`, unlike the Responses API where the same fields sit at the top.
local function wire_tools(schemas)
  local tools = {}
  for _, schema in ipairs(schemas) do
    tools[#tools + 1] = {
      type = "function",
      ["function"] = {
        name = schema.name,
        description = schema.description,
        parameters = schema.parameters,
      },
    }
  end
  return tools
end

--- Build the request body. Pure: no I/O, no state.
---@return table body
function M.wire_request(options, request)
  local body = {
    model = options.model,
    messages = wire_messages(request.system, request.messages),
    stream = true,
  }

  -- Needed for usage on OpenAI proper; the gateways send it regardless. Kept
  -- switchable because a minimal compatible server may reject unknown fields.
  if options.include_usage ~= false then
    body.stream_options = { include_usage = true }
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

local function new_state()
  return { tool_calls = {}, finish_reason = nil }
end

--- Map one decoded chunk onto typed events.
---@return boolean terminal Unused: this adapter stops on [DONE] or exit.
local function receive(state, chunk, emit)
  if type(chunk.usage) == "table" then
    local usage = chunk.usage
    local fields = {}

    -- Read the cached count first. `prompt_tokens` is the *total* prompt size
    -- with the cached tokens a subset of it, but the schema's `input_tokens`
    -- means the uncached part. Reporting the total as `input_tokens` counts the
    -- cached prefix twice inside Usage.hit_rate, which then cannot exceed 50%
    -- however good the prefix caching is.
    local cached = 0
    if type(usage.prompt_tokens_details) == "table"
      and type(usage.prompt_tokens_details.cached_tokens) == "number" then
      cached = usage.prompt_tokens_details.cached_tokens
      fields.cache_read_tokens = cached
    end

    if type(usage.prompt_tokens) == "number" then
      fields.input_tokens = math.max(usage.prompt_tokens - cached, 0)
    end
    if type(usage.completion_tokens) == "number" then
      fields.output_tokens = usage.completion_tokens
    end
    if type(usage.completion_tokens_details) == "table"
      and type(usage.completion_tokens_details.reasoning_tokens) == "number" then
      fields.reasoning_tokens = usage.completion_tokens_details.reasoning_tokens
    end

    -- Only emit if something numeric was present: a usage event with no token
    -- field is invalid by construction.
    if next(fields) then
      emit(Events.usage(fields))
    end
  end

  local choice = chunk.choices and chunk.choices[1]
  if type(choice) ~= "table" then
    return false
  end

  local delta = choice.delta or {}

  if type(delta.content) == "string" and delta.content ~= "" then
    emit(Events.text_delta(delta.content))
  end

  local reasoning = delta.reasoning_content or delta.reasoning
  if type(reasoning) == "string" and reasoning ~= "" then
    emit(Events.thinking_delta(reasoning))
  end

  if type(delta.tool_calls) == "table" then
    for _, entry in ipairs(delta.tool_calls) do
      local index = entry.index or 0
      local slot = state.tool_calls[index] or { id = "", name = "", arguments = "" }

      if type(entry.id) == "string" and entry.id ~= "" then
        slot.id = entry.id
      end

      local fn = entry["function"]
      if type(fn) == "table" then
        if type(fn.name) == "string" and fn.name ~= "" then
          slot.name = fn.name
        end
        if type(fn.arguments) == "string" then
          -- Fragments, not a complete document.
          slot.arguments = slot.arguments .. fn.arguments
        end
      end

      state.tool_calls[index] = slot
    end
  end

  if choice.finish_reason ~= nil then
    state.finish_reason = choice.finish_reason
  end

  return false
end

--- Emit the reassembled tool calls, then the terminal event.
local function finish(state, emit)
  local indexes = {}
  for index in pairs(state.tool_calls) do
    indexes[#indexes + 1] = index
  end
  table.sort(indexes)

  for _, index in ipairs(indexes) do
    local call = state.tool_calls[index]

    if call.id == "" or call.name == "" then
      emit(Events.error(("a tool call arrived incomplete: id=%q name=%q"):format(call.id, call.name)))
      return
    end

    local arguments = {}
    if call.arguments ~= "" then
      local decoded, parsed = pcall(vim.json.decode, call.arguments)
      if not decoded or type(parsed) ~= "table" then
        emit(
          Events.error(
            ("tool call %q had arguments that are not valid JSON: %s"):format(call.name, call.arguments)
          )
        )
        return
      end
      arguments = parsed
    end

    emit(Events.tool_use(call.id, call.name, arguments))
  end

  emit(Events.done(FINISH_REASONS[state.finish_reason] or "complete"))
end

--- Build a transport.
---@param options table { base_url, api_key, model, include_usage?, session_header?,
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
