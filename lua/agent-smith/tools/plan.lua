--- The plan tool: phase 1 of a vibe run, as a structured artifact.
---
--- ADR 0007 rejected the previous implementation's text protocol for expressing
--- changes. The same reasoning applies to the plan itself: a plan that arrives
--- as prose has to be parsed to be enforced, and the parse is the bug. A tool
--- call is already structured, already validated by the registry, and already
--- recorded in the conversation as the exact call the model made.
---
--- `access = READ` is honest rather than convenient. The call touches nothing —
--- it records a declaration — so the registry's policy pipeline has nothing to
--- decide. Declaring it WRITE would demand a `locate` naming a target that does
--- not exist.
---
--- The handler does not decide anything either. It hands the plan to whoever
--- registered it and returns; approval, containment and applying are the mode's
--- business, not the tool's.

local Registry = require("agent-smith.tools.registry")

local M = {}

M.NAME = "plan"

--- A tool spec that records a plan instead of acting on it.
---
---@param options table { on_plan: fun(plan: table) } Required.
---@return table spec
function M.tool(options)
  options = options or {}
  assert(type(options.on_plan) == "function", "the plan tool needs an on_plan callback")

  return {
    name = M.NAME,
    description = "Record the plan for approval. Call exactly once, after investigating. "
      .. "Does not modify anything.",
    access = Registry.READ,
    parameters = {
      summary = {
        type = "string",
        required = true,
        description = "One sentence describing the change.",
      },
      steps = {
        type = "array",
        items = "string",
        required = true,
        description = "The ordered steps you will take, one action each.",
      },
      files = {
        type = "array",
        items = "string",
        required = true,
        description = "Every file you will modify, as paths relative to the project root, "
          .. "including files you will create. Files you only intend to read do not belong here.",
      },
    },
    handler = function(arguments)
      options.on_plan({
        summary = arguments.summary,
        steps = arguments.steps,
        files = arguments.files,
      })
      return Registry.ok("the plan is recorded; stop here and end the turn")
    end,
  }
end

return M
