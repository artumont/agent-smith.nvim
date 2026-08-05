--- agent-smith/providers/init.lua
---
--- BaseProvider: the contract that all AI providers must implement.
---
--- Provider architecture:
--- Agent-Smith supports multiple AI CLI backends through a unified interface.
--- Each provider is a separate module that inherits from BaseProvider and
--- implements the required methods.
---
--- The contract (every provider MUST implement):
--- 1. _build_command(query, context) -> string[]  Build CLI command
--- 2. _get_provider_name() -> string              Human-readable name
--- 3. _get_default_model() -> string              Default model identifier
--- 4. fetch_models(callback)                      Optional model listing
---
--- Request lifecycle:
---   Provider:make_request(query, context, observer)
---     observer.on_start()
---     vim.system(command, callbacks...)
---       stdout -> observer.on_stdout(line)
---       stderr -> observer.on_stderr(line)
---       exit:
---         code != 0 -> observer.on_complete("failed", error)
---         code == 0 -> read tmp_file -> observer.on_complete("success", response)
---     Returns SystemObj (for cancellation via kill)
---
--- Important details:
--- - Temp file pattern: Providers that need to write output to files (opencode,
---   claude) write to the context's tmp_file. BaseProvider reads this file after
---   the process exits successfully. This is safe because vim.system() guarantees
---   the process has exited before calling the exit callback.
--- - Cancellation: The SystemObj returned by make_request() is stored in the
---   Prompt object. On cancel(), SIGTERM is sent to the process. The exit
---   callback checks is_cancelled() and discards the response.
--- - Error handling: Non-zero exit codes are treated as failures. The stderr
---   output is included in the error message. Providers should NOT throw errors -
---   they should return failed status via the observer.
--- - Once helper: The once wrapper ensures on_complete is called exactly once,
---   even if both stdout and stderr callbacks fire after process exit.

local M = {}

--- Base provider class. All providers inherit from this.
--- Implements the make_request() lifecycle. Providers only need to
--- implement the _build_command, _get_provider_name, and _get_default_model
--- methods. Providers may override fetch_models() for model discovery.
local BaseProvider = {}
BaseProvider.__index = BaseProvider

--- Ensure a function is only called once.
--- Used to prevent double-calling on_complete.
---@param fn function The function to wrap
---@return function Wrapped function that calls fn at most once
local function once(fn)
  local called = false
  return function(...)
    if called then return end
    called = true
    fn(...)
  end
end

--- Retrieve the AI's response from the temp file.
---
--- Read a response written to the optional temp file.
---
--- Most supported CLIs print their response to stdout. This fallback exists
--- for providers configured to write a response file instead.
---@param context table The Prompt object (has tmp_file field)
---@return string|nil response File contents, or nil when no file exists
function BaseProvider:_retrieve_response(context)
  local ok, result = pcall(vim.fn.readfile, context.tmp_file)
  if not ok then return nil end
  return table.concat(result, "\n")
end

--- Report unsupported model discovery unless a provider overrides this method.
---@param cb fun(models: string[]|nil, err: string|nil)
function BaseProvider:fetch_models(cb)
  cb(nil, self:_get_provider_name() .. " does not support model listing")
end

--- Build a safe diagnostic message without exposing the user's prompt.
---@param context table Prompt context
---@param command string[] Provider command
---@param reason string Human-readable failure reason
---@param result? table vim.system result
---@param stderr? string Captured stderr
---@return string
local function failure_diagnostic(context, command, reason, result, stderr)
  local executable = command[1] or "<missing>"
  local provider = "<unknown>"
  local active = context._state and context._state:active_provider() or nil
  if active and active._get_provider_name then
    local ok, name = pcall(active._get_provider_name, active)
    if ok then provider = name end
  end

  local prompt_present = false
  for _, argument in ipairs(command) do
    if argument == context._assembled_query then
      prompt_present = true
      break
    end
  end

  local lines = {
    "Agent-Smith provider failure",
    "Cause: " .. reason,
    "Provider: " .. provider,
    "Model: " .. tostring(context.model or "<nil>"),
    string.format(
      "Executable: %s (%s)",
      executable,
      vim.fn.executable(executable) == 1 and "found" or "not found in PATH"
    ),
    "Working directory: " .. tostring(context.cwd or vim.fn.getcwd()),
    "Prompt argument: " .. (prompt_present and "present" or "MISSING"),
    "Argument count: " .. tostring(#command),
  }

  if result then
    table.insert(lines, "Exit code: " .. tostring(result.code))
    table.insert(lines, "Signal: " .. tostring(result.signal))
  end

  stderr = vim.trim((stderr or ""):gsub("\27%[[%d;]*m", ""))
  if stderr ~= "" then
    table.insert(lines, "stderr:")
    table.insert(lines, stderr)
  end

  table.insert(lines, "Prompt text: <redacted>")
  return table.concat(lines, "\n")
end

--- Protect the original project from provider-side writes on Linux. Provider
--- still gets a writable disposable copy as cwd. Bubblewrap only overlays the
--- original project read-only; credentials, caches, network, and host binaries
--- remain available to provider CLI.
---@param command string[] Provider command
---@param context table Prompt context
---@return string[] command Wrapped or original command
local function sandbox_command(command, context)
  local sandbox = context._sandbox
  if not sandbox or not sandbox.project_root or vim.fn.executable("bwrap") ~= 1 then
    return command
  end

  local wrapped = {
    "bwrap",
    "--die-with-parent",
    "--bind", "/", "/",
    "--ro-bind", sandbox.project_root, sandbox.project_root,
    "--chdir", context.cwd or sandbox.root,
    "--",
  }
  vim.list_extend(wrapped, command)
  return wrapped
end

--- Put delimited-response providers in their own Unix process group. Some
--- agent CLIs print their final response but keep helper processes or pipes
--- alive; killing the group closes those handles without leaking children.
local function process_group_command(command, context)
  if not context.response_terminator or vim.fn.has("win32") == 1
    or vim.fn.executable("setsid") ~= 1 then
    return command
  end
  context._provider_process_group = true
  local wrapped = { "setsid", "--wait" }
  vim.list_extend(wrapped, command)
  return wrapped
end

local function terminate_process(context, process)
  if not process then return end
  if context._provider_process_group and process.pid then
    local ok, result = pcall(vim.uv.kill, -process.pid, vim.uv.constants.SIGTERM)
    if ok and result == 0 then return end
  end
  pcall(process.kill, process, vim.uv.constants.SIGTERM)
end

--- Execute the provider CLI and handle the async response.
---
--- This is the main method that providers inherit. It:
--- 1. Calls observer.on_start()
--- 2. Spawns the provider process via vim.system()
--- 3. Routes stdout/stderr to observer callbacks
--- 4. On exit: reads temp file and calls on_complete
---
---@param query string The assembled prompt text
---@param context table The Prompt object
---@param observer table { on_start, on_stdout, on_stderr, on_complete }
---@return table SystemObj The running process (for cancellation)
function BaseProvider:make_request(query, context, observer)
  observer.on_start()

  local once_complete = once(function(status, text)
    observer.on_complete(status, text)
  end)

  -- Stored only for identity checks in diagnostics; diagnostic output always
  -- redacts prompt contents.
  context._assembled_query = query
  local command = self:_build_command(query, context)
  local extra_args = context._state and context._state.provider_extra_args or {}
  if #extra_args > 0 then
    vim.list_extend(command, extra_args)
  end
  command = sandbox_command(command, context)
  command = process_group_command(command, context)

  -- CLI providers normally print the final answer to stdout. Keep every
  -- chunk because vim.system() may stream one response across callbacks.
  local stdout = {}
  local stderr = {}
  local early_response
  local process
  local ok, proc = pcall(
    vim.system,
    command,
    {
      text = true,
      cwd = context.cwd,
      stdout = vim.schedule_wrap(function(err, data)
        -- Cancellation completes only from exit callback so sandbox and
        -- tracking remain alive until provider process has actually stopped.
        if context:is_cancelled() then return end
        if err and err ~= "" then table.insert(stderr, "stdout read error: " .. err) end
        if data then
          table.insert(stdout, data)
          observer.on_stdout(data)
          if context.response_terminator and not early_response then
            local response = table.concat(stdout, "")
            if response:find(context.response_terminator, 1, true) then
              early_response = response
              terminate_process(context, process)
            end
          end
        end
      end),
      stderr = vim.schedule_wrap(function(err, data)
        if context:is_cancelled() then return end
        if err and err ~= "" then table.insert(stderr, "stderr read error: " .. err) end
        if data then
          table.insert(stderr, data)
          observer.on_stderr(data)
        end
      end),
    },
    vim.schedule_wrap(function(obj)
      if context:is_cancelled() then
        once_complete("cancelled", "")
        return
      end

      if early_response then
        once_complete("success", early_response)
        return
      end

      if obj.code ~= 0 then
        once_complete("failed", failure_diagnostic(
          context,
          command,
          "provider process exited unsuccessfully",
          obj,
          table.concat(stderr, "")
        ))
        return
      end

      local response = table.concat(stdout, "")
      if vim.trim(response) == "" then
        response = self:_retrieve_response(context) or ""
      end
      if vim.trim(response) == "" then
        once_complete("failed", failure_diagnostic(
          context,
          command,
          "provider exited successfully but returned an empty response",
          obj,
          table.concat(stderr, "")
        ))
        return
      end
      once_complete("success", response)
    end)
  )

  if not ok then
    once_complete("failed", failure_diagnostic(
      context,
      command,
      "failed to start provider process",
      nil,
      tostring(proc)
    ))
    return nil
  end

  process = proc
  if early_response then terminate_process(context, process) end
  context:_set_process(proc)
  return proc
end

M.BaseProvider = BaseProvider

return M
