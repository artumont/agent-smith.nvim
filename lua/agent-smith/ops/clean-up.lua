--- agent-smith/ops/clean-up.lua
---
--- Cleanup and observer wrappers for request lifecycle.
---
--- Purpose:
--- Provides wrappers that ensure cleanup functions are called
--- when requests complete, regardless of success/failure/cancellation.
---
--- Observer pattern:
--- The make_observer wrapper adds cleanup execution to the
--- on_complete callback, ensuring resources are released.

local M = {}

--- Create a cleanup function wrapper.
---
---@param fn function The cleanup function to wrap
---@return table cleanup Object with run() method
function M.make_clean_up(fn)
  return { run = fn }
end

--- Create an observer with cleanup on completion.
---
--- Wraps the observer's on_complete to also execute cleanup functions
--- from the context's clean_ups list.
---
---@param context table The Prompt object
---@param observer table Original observer callbacks
---@return table wrapped_observer Observer with cleanup
function M.make_observer(context, observer)
  return {
    on_start = observer.on_start or function() end,
    on_stdout = observer.on_stdout or function() end,
    on_stderr = observer.on_stderr or function() end,
    on_complete = function(status, response)
      -- Call original on_complete
      if observer.on_complete then
        observer.on_complete(status, response)
      end
      -- Execute cleanup functions
      if context.clean_ups then
        for _, cleanup in ipairs(context.clean_ups) do
          if type(cleanup) == "function" then
            cleanup()
          elseif cleanup.run then
            cleanup.run()
          end
        end
      end
    end,
  }
end

return M
