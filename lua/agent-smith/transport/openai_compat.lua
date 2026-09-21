--- OpenAI-compatible chat completions, streamed over SSE.
---
--- The first transport, for custom providers and for the open models on the
--- gateways. See spec/decisions/0008-transport-openai-compatible-first.md and
--- spec/decisions/0010-integrated-providers-are-presets.md. GPT-family models on
--- the gateways need `/responses` and Claude models need `/messages`; neither is
--- implemented yet.
---
--- Two details that are easy to get wrong and are handled here rather than left
--- to the loop:
---
---   - **Tool arguments stream as fragments.** `delta.tool_calls[].function.
---     arguments` arrives as partial JSON across many chunks, keyed by index.
---     The event schema promises the loop a complete decoded table, so the
---     fragments are reassembled and decoded here, and a `tool_use` is emitted
---     only once the stream ends.
---   - **The API key does not go in `argv`.** It is handed to `curl` through the
---     child process environment, because `argv` is world-readable via `ps` while
---     a process's environment is restricted to its owner. Verified by probe.
---
--- Assembling the request is a pure function (`wire_request`) so it can be
--- tested without a network, and the process spawn is injectable for the same
--- reason.

local Sse = require("agent-smith.transport.sse")
local Events = require("agent-smith.agent.events")
local Json = require("agent-smith.json")

local M = {}

--- Name of the environment variable the key is passed in. Fixed, so the shell
--- string never has to interpolate a secret.
M.TOKEN_ENV = "AGENT_SMITH_API_KEY"

M.DEFAULT_TIMEOUT_MS = 300000

--- Sent so the gateway sees a client that identifies itself, rather than a
--- generic HTTP library. OpenCode Go asks for this explicitly.
M.DEFAULT_USER_AGENT = "agent-smith.nvim"

--- Vendor finish reasons mapped onto the event schema's vocabulary.
local FINISH_REASONS = {
  stop = "complete",
  tool_calls = "tool_calls",
  length = "length",
  content_filter = "content_filter",
}

--- Flatten an error value into a string, whatever shape it arrived in.
local function error_message(err)
  if type(err) == "string" then
    return err
  end
  if type(err) == "table" then
    if type(err.message) == "string" then
      return err.message
    end
    local encoded = pcall(vim.json.encode, err)
    if encoded then
      return vim.json.encode(err)
    end
  end
  return tostring(err)
end

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

--- Wrap tool schemas in the shape chat completions expects.
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

--- Build the argv and environment for one request.
---
--- The body goes over stdin rather than `argv`, so a large conversation cannot
--- hit an argument-length limit.
---
--- Header values are passed to the shell as positional parameters and referenced
--- as `$1`, `$2`…, never interpolated into the script text. That means no value
--- has to be escaped to be safe, which matters because one of them is derived
--- from a filesystem path.
---
---@param options table
---   - base_url: string
---   - api_key: string
---   - token_env: string
---   - headers: table[]|nil  Extra headers, each { name, value }.
---@return string[] command
---@return table env
function M.build_command(options)
  local headers = options.headers or {}

  local placeholders = {}
  for index = 1, #headers do
    placeholders[index] = (' -H "$' .. index .. '"')
  end

  local script = table.concat({
    "exec curl -sS -N --no-buffer --fail-with-body",
    " -X POST " .. string.format("%q", options.base_url:gsub("/+$", "") .. "/chat/completions"),
    ' -H "Content-Type: application/json"',
    -- The $ and the name must both be inside the quotes, or the shell treats
    -- the $ as literal and sends the variable name as the token.
    ' -H "Authorization: Bearer $' .. options.token_env .. '"',
    table.concat(placeholders),
    " --data-binary @-",
  })

  local command = { "sh", "-c", script, "agent-smith" }
  for _, header in ipairs(headers) do
    if type(header.name) ~= "string" or not header.name:match("^[%w%-]+$") then
      error("invalid header name: " .. tostring(header.name), 0)
    end
    command[#command + 1] = ("%s: %s"):format(header.name, tostring(header.value))
  end

  local env = { [options.token_env] = options.api_key }
  return command, env
end

--- Build a transport.
---@param options table
---   - base_url: string       Required, e.g. "https://opencode.ai/zen/v1".
---   - api_key: string        Required.
---   - model: string          Required.
---   - include_usage: boolean Default true.
---   - timeout_ms: number     Default five minutes.
---   - user_agent: string|nil Sent as User-Agent. Identifies the client rather
---                            than looking like a generic HTTP library.
---   - session_header: string|nil  Header name to carry request.session in, for
---                            a gateway that uses it for cache routing. OpenCode
---                            Zen and Go want `x-opencode-session`; leaving it
---                            nil sends nothing.
---   - execute: function|nil  Process spawner, default vim.system. Injectable
---                            so the streaming path is testable without a net.
---@return table transport { run = function(request, on_event) -> handle }
function M.new(options)
  assert(type(options) == "table", "the transport needs an options table")
  assert(type(options.base_url) == "string" and options.base_url ~= "", "the transport needs a base_url")
  assert(type(options.api_key) == "string" and options.api_key ~= "", "the transport needs an api_key")
  assert(type(options.model) == "string" and options.model ~= "", "the transport needs a model")

  local execute = options.execute or vim.system
  local timeout_ms = options.timeout_ms or M.DEFAULT_TIMEOUT_MS
  local user_agent = options.user_agent or M.DEFAULT_USER_AGENT
  local session_header = options.session_header

  local function run(request, on_event)
    local body = M.wire_request(options, request)

    local headers = { { name = "User-Agent", value = user_agent } }
    if session_header and type(request.session) == "string" and request.session ~= "" then
      headers[#headers + 1] = { name = session_header, value = request.session }
    end

    local command, env = M.build_command({
      base_url = options.base_url,
      api_key = options.api_key,
      token_env = M.TOKEN_ENV,
      headers = headers,
    })

    local parser = Sse.new()
    local pending = {}
    local raw = {}
    local stderr = {}
    local tool_calls = {}
    local finish_reason = nil

    local scheduled = false
    local finished = false
    local process = nil

    local function emit(event)
      on_event(event)
    end

    --- Emit the tool calls, then the terminal event. Idempotent.
    local function finalize()
      if finished then
        return
      end
      finished = true

      local indexes = {}
      for index in pairs(tool_calls) do
        indexes[#indexes + 1] = index
      end
      table.sort(indexes)

      for _, index in ipairs(indexes) do
        local call = tool_calls[index]

        if call.id == "" or call.name == "" then
          emit(
            Events.error(
              ("a tool call arrived incomplete: id=%q name=%q"):format(call.id, call.name)
            )
          )
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

      emit(Events.done(FINISH_REASONS[finish_reason] or "complete"))
    end

    local function handle_event(sse_event)
      if finished then
        return
      end

      local data = sse_event.data
      if data == "[DONE]" then
        finalize()
        return
      end

      local decoded, chunk = pcall(vim.json.decode, data)
      if not decoded then
        finished = true
        emit(Events.error(("could not decode a stream chunk: %s"):format(tostring(chunk))))
        return
      end

      if type(chunk) ~= "table" then
        -- Keep-alives sometimes arrive as a bare JSON value.
        return
      end

      if chunk.error then
        finished = true
        emit(Events.error(error_message(chunk.error)))
        return
      end

      if type(chunk.usage) == "table" then
        local usage = chunk.usage
        local fields = {}

        if type(usage.prompt_tokens) == "number" then
          fields.input_tokens = usage.prompt_tokens
        end
        if type(usage.completion_tokens) == "number" then
          fields.output_tokens = usage.completion_tokens
        end
        if type(usage.prompt_tokens_details) == "table"
          and type(usage.prompt_tokens_details.cached_tokens) == "number" then
          fields.cache_read_tokens = usage.prompt_tokens_details.cached_tokens
        end
        if type(usage.completion_tokens_details) == "table"
          and type(usage.completion_tokens_details.reasoning_tokens) == "number" then
          fields.reasoning_tokens = usage.completion_tokens_details.reasoning_tokens
        end

        -- Only emit if something numeric was actually present, since a usage
        -- event with no token field is invalid by construction.
        if next(fields) then
          emit(Events.usage(fields))
        end
      end

      local choice = chunk.choices and chunk.choices[1]
      if type(choice) ~= "table" then
        return
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
          local slot = tool_calls[index] or { id = "", name = "", arguments = "" }

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

          tool_calls[index] = slot
        end
      end

      if choice.finish_reason ~= nil then
        finish_reason = choice.finish_reason
      end
    end

    local function drain()
      scheduled = false
      if #pending == 0 then
        return
      end
      local chunk = table.concat(pending)
      pending = {}

      for _, sse_event in ipairs(parser:feed(chunk)) do
        handle_event(sse_event)
      end
    end

    local function on_stdout(_, data)
      if not data or data == "" then
        return
      end
      raw[#raw + 1] = data
      pending[#pending + 1] = data
      if not scheduled then
        scheduled = true
        vim.schedule(drain)
      end
    end

    local function on_stderr(_, data)
      if data then
        stderr[#stderr + 1] = data
      end
    end

    --- Explain a failed curl run, preferring a structured vendor error.
    local function explain_failure(result)
      local body = parser:pending()
      if body == "" then
        body = table.concat(raw)
      end

      local decoded, parsed = pcall(vim.json.decode, body)
      if decoded and type(parsed) == "table" and parsed.error then
        return error_message(parsed.error)
      end

      local message = vim.trim(table.concat(stderr))
      if message ~= "" then
        return ("curl exited %s: %s"):format(tostring(result.code), message)
      end

      return ("curl exited %s with no error detail"):format(tostring(result.code))
    end

    local function on_exit(result)
      vim.schedule(function()
        drain()
        if finished then
          return
        end
        if result.code ~= 0 then
          finished = true
          emit(Events.error(explain_failure(result)))
          return
        end
        finalize()
      end)
    end

    process = execute(command, {
      text = true,
      stdin = Json.encode(body),
      env = env,
      stdout = on_stdout,
      stderr = on_stderr,
      timeout = timeout_ms,
    }, on_exit)

    return {
      cancel = function()
        if process and type(process.kill) == "function" then
          pcall(function()
            process:kill("sigterm")
          end)
        end
      end,
    }
  end

  return { run = run }
end

return M
