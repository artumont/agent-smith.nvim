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
--- methods.
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

  local command = self:_build_command(query, context)
  local extra_args = context._state and context._state.provider_extra_args or {}
  if #extra_args > 0 then
    vim.list_extend(command, extra_args)
  end

  -- CLI providers normally print the final answer to stdout. Keep every
  -- chunk because vim.system() may stream one response across callbacks.
  local stdout = {}
  local stderr = {}
  local proc = vim.system(
    command,
    {
      text = true,
      stdout = vim.schedule_wrap(function(err, data)
        if context:is_cancelled() then
          once_complete("cancelled", "")
          return
        end
        if not err and data then
          table.insert(stdout, data)
          observer.on_stdout(data)
        end
      end),
      stderr = vim.schedule_wrap(function(err, data)
        if context:is_cancelled() then
          once_complete("cancelled", "")
          return
        end
        if not err and data then
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

      if obj.code ~= 0 then
        local details = vim.trim(table.concat(stderr, ""))
        local error_text = string.format("Provider exit code: %d", obj.code)
        if details ~= "" then error_text = error_text .. "\n" .. details end
        once_complete("failed", error_text)
        return
      end

      local response = table.concat(stdout, "")
      if vim.trim(response) == "" then
        response = self:_retrieve_response(context) or ""
      end
      once_complete("success", response)
    end)
  )

  context:_set_process(proc)
  return proc
end

M.BaseProvider = BaseProvider

return M
