--- The streaming harness shared by every OpenAI-shaped adapter.
---
--- An adapter declares four things and inherits everything else:
---
---   endpoint       path appended to the base URL
---   build_request  request table to wire body (pure, so it is testable)
---   receive        one decoded stream event to typed events
---   finish         emit whatever is still pending, then the terminal event
---
--- The base owns what each adapter would otherwise copy: the curl invocation,
--- streaming stdout, SSE framing, JSON decoding, error extraction and
--- cancellation. That plumbing is where adapters drift apart on error handling,
--- so it exists once.
---
--- Two details carried over from the chat adapter and kept here deliberately:
---
---   - **The credential never goes in `argv`.** It is passed through the child
---     process environment, because `argv` is world-readable via `ps` while a
---     process's environment is restricted to its owner. Verified by probe.
---   - **Extra headers are positional parameters, not interpolated.** They reach
---     the shell as `$1`, `$2`…, so no value has to be escaped to be safe.

local Sse = require("agent-smith.transport.sse")
local Events = require("agent-smith.agent.events")
local Json = require("agent-smith.json")

local M = {}

--- Fixed, so the shell string never has to interpolate a secret.
M.TOKEN_ENV = "AGENT_SMITH_API_KEY"

M.DEFAULT_TIMEOUT_MS = 300000

--- Sent so a gateway sees a client that identifies itself rather than a generic
--- HTTP library. OpenCode Go asks for this explicitly.
M.DEFAULT_USER_AGENT = "agent-smith.nvim"

--- Flatten an error value into a string, whatever shape it arrived in.
function M.error_message(err)
  if type(err) == "string" then
    return err
  end
  if type(err) == "table" then
    if type(err.message) == "string" then
      return err.message
    end
    local ok, encoded = pcall(vim.json.encode, err)
    if ok then
      return encoded
    end
  end
  return tostring(err)
end

--- Normalise declared headers into the list of `{ name, value }` that
--- `build_command` wants.
---
--- Two shapes are accepted, because both are natural to write by hand:
---
---     { { name = "X-Thing", value = "1" } }   -- a list
---     { ["X-Thing"] = "1" }                  -- a map
---
--- A map is sorted, so the same declaration produces the same argv every time
--- rather than whatever order `pairs` happened to walk in.
---@param headers table|nil
---@return table[] { name, value }
function M.normalise_headers(headers)
  if type(headers) ~= "table" then
    return {}
  end

  local list = {}

  if vim.islist(headers) then
    for _, header in ipairs(headers) do
      if type(header) == "table" then
        list[#list + 1] = { name = header.name, value = header.value }
      end
    end
    return list
  end

  local names = vim.tbl_keys(headers)
  table.sort(names)
  for _, name in ipairs(names) do
    list[#list + 1] = { name = name, value = headers[name] }
  end

  return list
end

--- Build the argv and environment for one request.
---
--- The body goes over stdin, so a large conversation cannot hit an
--- argument-length limit.
---
---@param options table { base_url, api_key, token_env, endpoint, headers? }
---@return string[] command
---@return table env
function M.build_command(options)
  local headers = options.headers or {}
  local url = options.base_url:gsub("/+$", "") .. options.endpoint

  local placeholders = {}
  for index = 1, #headers do
    placeholders[index] = (' -H "$' .. index .. '"')
  end

  local script = table.concat({
    "exec curl -sS -N --no-buffer --fail-with-body",
    " -X POST " .. string.format("%q", url),
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

  return command, { [options.token_env] = options.api_key }
end

--- Build an adapter from a declaration.
---
---@param declaration table
---   - endpoint: string                  Required, e.g. "/chat/completions".
---   - build_request: fun(options, request) -> table
---   - new_state: fun() -> table|nil     Per-run accumulator.
---   - receive: fun(state, event, emit) -> boolean  True once terminal.
---   - finish: fun(state, emit)          Emit pending events and the terminal.
---   - options: table                    base_url, api_key, model, session_header,
---                                       user_agent, include_usage, execute,
---                                       timeout_ms.
---@return table transport { run = fun(request, on_event) -> handle }
function M.new(declaration)
  assert(type(declaration) == "table", "a transport needs a declaration")
  assert(type(declaration.endpoint) == "string", "a transport needs an endpoint")
  assert(type(declaration.build_request) == "function", "a transport needs build_request")
  assert(type(declaration.receive) == "function", "a transport needs receive")
  assert(type(declaration.finish) == "function", "a transport needs finish")

  local options = declaration.options
  assert(type(options) == "table", "a transport needs an options table")
  assert(type(options.base_url) == "string" and options.base_url ~= "", "a transport needs a base_url")
  assert(type(options.api_key) == "string" and options.api_key ~= "", "a transport needs an api_key")
  assert(type(options.model) == "string" and options.model ~= "", "a transport needs a model")

  local execute = options.execute or vim.system
  local timeout_ms = options.timeout_ms or M.DEFAULT_TIMEOUT_MS
  local user_agent = options.user_agent or M.DEFAULT_USER_AGENT
  local session_header = options.session_header

  local function run(request, on_event)
    local state = declaration.new_state and declaration.new_state() or {}

    local body = declaration.build_request(options, request)

    local headers = { { name = "User-Agent", value = user_agent } }
    if session_header and type(request.session) == "string" and request.session ~= "" then
      headers[#headers + 1] = { name = session_header, value = request.session }
    end

    -- Anything else a gateway wants, from the transport's own declaration and then
    -- from the request. These reach the shell as positional parameters like the
    -- session header, so no value has to be escaped to be safe.
    --
    -- Note what that means: header values are visible in the process list, unlike
    -- the credential, which is passed through the environment for exactly that
    -- reason. Extras are for values that are not secrets.
    for _, header in ipairs(M.normalise_headers(options.extra_headers)) do
      headers[#headers + 1] = header
    end
    for _, header in ipairs(M.normalise_headers(request.headers)) do
      headers[#headers + 1] = header
    end

    local command, env = M.build_command({
      base_url = options.base_url,
      api_key = options.api_key,
      token_env = M.TOKEN_ENV,
      endpoint = declaration.endpoint,
      headers = headers,
    })

    local parser = Sse.new()
    local pending = {}
    local raw = {}
    local stderr = {}
    local scheduled = false
    local ended = false
    local process = nil

    local function emit(event)
      on_event(event)
    end

    --- Emit anything the adapter has not yet emitted, then stop.
    local function finalize()
      if ended then
        return
      end
      ended = true
      declaration.finish(state, emit)
    end

    local function handle_event(sse_event)
      if ended then
        return
      end

      local data = sse_event.data
      if data == "[DONE]" then
        finalize()
        return
      end

      local decoded, chunk = pcall(vim.json.decode, data)
      if not decoded then
        ended = true
        emit(Events.error(("could not decode a stream chunk: %s"):format(tostring(chunk))))
        return
      end

      if type(chunk) ~= "table" then
        -- Keep-alives occasionally arrive as a bare JSON value.
        return
      end

      if chunk.error then
        ended = true
        emit(Events.error(M.error_message(chunk.error)))
        return
      end

      if declaration.receive(state, chunk, emit) then
        ended = true
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

    --- Explain a failed run, preferring a structured vendor error.
    local function explain_failure(result)
      local pending_body = parser:pending()
      if pending_body == "" then
        pending_body = table.concat(raw)
      end

      local decoded, parsed = pcall(vim.json.decode, pending_body)
      if decoded and type(parsed) == "table" and parsed.error then
        return M.error_message(parsed.error)
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
        if ended then
          return
        end
        if result.code ~= 0 then
          ended = true
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
