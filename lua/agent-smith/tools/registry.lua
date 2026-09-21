--- Tool registry: schemas, dispatch, and the policy pipeline.
---
--- A tool declares what it does and what it touches. The registry checks the
--- arguments, asks the scope whether the target is permitted, and only then
--- runs the handler. Tools therefore contain no permission logic of their own,
--- and there is one place to audit.
---
--- Outcomes
---
--- A handler produces an *outcome*, not an event:
---
---   { ok = true,  content = string }          the tool worked
---   { ok = false, error = string }            the tool failed or was refused
---   { needs_permission = { tool, reason, target } }
---
--- `needs_permission` never reaches a transport. The loop asks the user and
--- resolves it into a plain result first, which is why the event schema does
--- not carry it. See spec/events.md and
--- spec/decisions/0004-bounded-edit-with-escalation.md.
---
--- Handlers
---
--- A handler is called as `handler(arguments, context)`. It must either return
--- an outcome, or call `context.finish(outcome)` later. Exactly one of the two;
--- `finish` is idempotent, so returning after calling it is harmless. A handler
--- that does neither leaves the request hanging, which is the one way to write
--- a broken tool.

local Json = require("agent-smith.json")

local M = {}

--- Access level for a tool that only reads.
M.READ = "read"
--- Access level for a tool that writes. The scope bounds it.
M.WRITE = "write"
--- Access level for a tool that runs a command. The blacklist filters it.
M.EXECUTE = "execute"

local ACCESS_LEVELS = { [M.READ] = true, [M.WRITE] = true, [M.EXECUTE] = true }

--- Parameter types, named after their JSON Schema counterparts so that the
--- conversion to a model-facing schema is a pass-through.
---
--- "object" and "array" are ambiguous for an empty table, which Neovim treats
--- as a list. An empty table therefore satisfies both.
local PARAMETER_TYPES = {
  string = function(value)
    return type(value) == "string"
  end,
  number = function(value)
    return type(value) == "number"
  end,
  boolean = function(value)
    return type(value) == "boolean"
  end,
  object = function(value)
    return type(value) == "table" and (next(value) == nil or not vim.islist(value))
  end,
  array = function(value)
    return type(value) == "table" and vim.islist(value)
  end,
}

--- The tool worked.
---@param content string What the model should see.
function M.ok(content)
  return { ok = true, content = content }
end

--- The tool failed, or its target was refused.
---@param message string What the model should see.
function M.error(message)
  return { ok = false, error = message }
end

--- The tool needs consent before it can act.
---@param fields table { tool: string, reason: string, target: table }
function M.needs_permission(fields)
  return { needs_permission = fields }
end

--- Check an outcome. Catches a handler returning something malformed.
---@return boolean ok
---@return string|nil problem
function M.validate_outcome(outcome)
  if type(outcome) ~= "table" then
    return false, "outcome must be a table, got " .. type(outcome)
  end

  local permission = outcome.needs_permission
  if permission ~= nil then
    if outcome.ok ~= nil or outcome.error ~= nil or outcome.content ~= nil then
      return false, "an outcome cannot be both a result and a permission request"
    end
    if type(permission) ~= "table" then
      return false, "needs_permission must be a table"
    end
    if type(permission.tool) ~= "string" or permission.tool == "" then
      return false, "needs_permission.tool must be a non-empty string"
    end
    if type(permission.reason) ~= "string" or permission.reason == "" then
      return false, "needs_permission.reason must be a non-empty string"
    end
    return true
  end

  if type(outcome.ok) ~= "boolean" then
    return false, "outcome.ok must be a boolean"
  end

  if outcome.ok then
    if type(outcome.content) ~= "string" then
      return false, "a successful outcome needs a string content"
    end
    if outcome.error ~= nil then
      return false, "a successful outcome cannot carry an error"
    end
  else
    if type(outcome.error) ~= "string" then
      return false, "a failed outcome needs a string error"
    end
    if outcome.content ~= nil then
      return false, "a failed outcome cannot carry content"
    end
  end

  return true
end

--- Convert a tool's parameters into the model-facing JSON Schema.
---
--- `additionalProperties` is false because the registry rejects unknown
--- arguments; leaving the schema open would tell the model otherwise.
---@return table schema { name, description, parameters }
function M.to_json_schema(spec)
  local properties = {}
  local required = {}

  for name, definition in pairs(spec.parameters or {}) do
    local property = { type = definition.type }
    if definition.description then
      property.description = definition.description
    end
    if definition.enum then
      property.enum = definition.enum
    end
    if definition.items then
      property.items = { type = definition.items }
    end
    properties[name] = property
    if definition.required then
      required[#required + 1] = name
    end
  end

  table.sort(required)

  return {
    name = spec.name,
    description = spec.description,
    parameters = {
      type = "object",
      -- Marked so a tool with no parameters encodes as {} and not [], which is
      -- what a vendor expects for the properties object.
      properties = Json.object(properties),
      required = required,
      additionalProperties = false,
    },
  }
end

local function allowed_arguments(spec)
  local names = vim.tbl_keys(spec.parameters or {})
  if #names == 0 then
    return "none"
  end
  table.sort(names)
  return table.concat(names, ", ")
end

local function matches_type(value, expected)
  local check = PARAMETER_TYPES[expected]
  if not check then
    return false
  end
  return check(value)
end

--- Check the arguments a model produced against the tool's parameters.
---
--- Unknown arguments are rejected rather than ignored. A hallucinated or
--- misspelled parameter is a bug worth surfacing, and the error is fed back to
--- the model so it can correct itself.
local function validate_arguments(spec, arguments)
  if type(arguments) ~= "table" then
    return false, "arguments must be a table, got " .. type(arguments)
  end

  local parameters = spec.parameters or {}

  -- Unknown arguments are reported before missing ones. Given `{ pth = "/a" }`,
  -- "unknown argument 'pth'; this tool accepts: path" is actionable, whereas
  -- "missing required argument 'path'" sends the model guessing at a typo.
  local unknown = {}
  for name in pairs(arguments) do
    if parameters[name] == nil then
      unknown[#unknown + 1] = name
    end
  end
  if #unknown > 0 then
    table.sort(unknown)
    return false,
      ("unknown argument '%s'; this tool accepts: %s"):format(unknown[1], allowed_arguments(spec))
  end

  for name, definition in pairs(parameters) do
    local value = arguments[name]
    if value == nil then
      if definition.required then
        return false, ("missing required argument '%s'"):format(name)
      end
    else
      if not matches_type(value, definition.type) then
        return false,
          ("argument '%s' must be %s, got %s"):format(name, tostring(definition.type), type(value))
      end
      if definition.type == "string" and definition.required and value == "" and not definition.allow_empty then
        return false, ("argument '%s' must not be empty"):format(name)
      end
      if definition.enum then
        local found = false
        for _, allowed in ipairs(definition.enum) do
          if value == allowed then
            found = true
            break
          end
        end
        if not found then
          return false,
            ("argument '%s' must be one of %s"):format(name, table.concat(definition.enum, ", "))
        end
      end
      if definition.type == "array" and definition.items then
        for index, element in ipairs(value) do
          if not matches_type(element, definition.items) then
            return false,
              ("argument '%s'[%d] must be %s, got %s"):format(
                name,
                index,
                definition.items,
                type(element)
              )
          end
        end
      end
    end
  end

  return true
end

--- Check the target a tool's locate() produced.
local function validate_target(target)
  if type(target) ~= "table" then
    return false, "target must be a table, got " .. type(target)
  end

  if target.kind == M.READ then
    if target.path ~= nil and (type(target.path) ~= "string" or target.path == "") then
      return false, "a read target path must be a non-empty string"
    end
    if target.paths ~= nil then
      if not vim.islist(target.paths) then
        return false, "a read target paths must be a list"
      end
      for index, path in ipairs(target.paths) do
        if type(path) ~= "string" or path == "" then
          return false, ("a read target paths[%d] must be a non-empty string"):format(index)
        end
      end
    end
    return true
  end

  if target.kind == M.WRITE then
    if type(target.path) ~= "string" or target.path == "" then
      return false, "a write target needs a non-empty path"
    end
    if target.range ~= nil then
      if type(target.range) ~= "table" then
        return false, "a write target range must be a table"
      end
      if type(target.range.start_row) ~= "number" or type(target.range.end_row) ~= "number" then
        return false, "a write target range needs numeric start_row and end_row"
      end
    end
    return true
  end

  if target.kind == M.EXECUTE then
    if type(target.command) ~= "string" or target.command == "" then
      return false, "an execute target needs a non-empty command"
    end
    return true
  end

  return false, ("unknown target kind %q"):format(tostring(target.kind))
end

local function validate_spec(spec)
  if type(spec) ~= "table" then
    return "a tool spec must be a table"
  end
  if type(spec.name) ~= "string" or spec.name == "" then
    return "a tool spec needs a non-empty name"
  end
  if type(spec.description) ~= "string" or spec.description == "" then
    return ("tool %q needs a non-empty description"):format(spec.name)
  end
  if not ACCESS_LEVELS[spec.access] then
    return ("tool %q needs access to be one of read, write, execute"):format(spec.name)
  end
  if type(spec.handler) ~= "function" then
    return ("tool %q needs a handler function"):format(spec.name)
  end
  if spec.parameters ~= nil and type(spec.parameters) ~= "table" then
    return ("tool %q parameters must be a table"):format(spec.name)
  end
  if spec.access ~= M.READ and type(spec.locate) ~= "function" then
    return ("tool %q needs a locate function because its access is %s"):format(spec.name, spec.access)
  end
  for name, definition in pairs(spec.parameters or {}) do
    if type(definition) ~= "table" then
      return ("tool %q parameter %q must be a table"):format(spec.name, name)
    end
    if not PARAMETER_TYPES[definition.type] then
      return ("tool %q parameter %q has unknown type %s"):format(
        spec.name,
        name,
        tostring(definition.type)
      )
    end
    if definition.enum ~= nil and not vim.islist(definition.enum) then
      return ("tool %q parameter %q enum must be a list"):format(spec.name, name)
    end
    if definition.allow_empty ~= nil and type(definition.allow_empty) ~= "boolean" then
      return ("tool %q parameter %q allow_empty must be a boolean"):format(spec.name, name)
    end
  end
  return nil
end

local Registry = {}
Registry.__index = Registry

--- A new, empty registry.
---@return table registry
function M.new()
  return setmetatable({ tools = {} }, Registry)
end

--- Add a tool.
---
--- Raises on an invalid spec: this is a programming error, not something a
--- model can cause, so it should fail loudly at load time.
---@param spec table { name, description, access, parameters?, handler, locate? }
function Registry:register(spec)
  local problem = validate_spec(spec)
  if problem then
    error("agent-smith: " .. problem, 0)
  end
  if self.tools[spec.name] then
    error(("agent-smith: tool %q is already registered"):format(spec.name), 0)
  end
  self.tools[spec.name] = spec
end

--- Look up a tool.
function Registry:get(name)
  return self.tools[name]
end

--- Registered tool names, sorted.
function Registry:names()
  local names = vim.tbl_keys(self.tools)
  table.sort(names)
  return names
end

--- The model-facing schema for every registered tool.
---@return table[]
function Registry:schemas()
  local schemas = {}
  for _, name in ipairs(self:names()) do
    schemas[#schemas + 1] = M.to_json_schema(self.tools[name])
  end
  return schemas
end

--- Run one tool call through validation, policy, and the handler.
---
--- `on_done` is called exactly once, and may be called synchronously (before
--- this function returns) for a tool that does not need to wait.
---
---@param call table { name: string, arguments: table }
---@param scope table From agent-smith.agent.scope.
---@param on_done fun(outcome: table)
---@param options table|nil { turn: any } Opaque turn token handed to the handler.
---   Tools that group their side effects — the edit tool's undo blocks — need to
---   know which turn they are in, and only the loop knows that.
function Registry:dispatch(call, scope, on_done, options)
  assert(type(on_done) == "function", "dispatch needs an on_done callback")

  local name = call and call.name
  local spec = name and self.tools[name]
  if not spec then
    on_done(M.error(("unknown tool %q; available: %s"):format(tostring(name), table.concat(self:names(), ", "))))
    return
  end

  local arguments = call.arguments or {}
  local arguments_ok, arguments_problem = validate_arguments(spec, arguments)
  if not arguments_ok then
    on_done(M.error(("invalid arguments for %s: %s"):format(spec.name, arguments_problem)))
    return
  end

  -- A read tool may declare a locate() to state what it touches, which is what
  -- lets read policy be decided rather than assumed. It is optional because a
  -- read that names no path has nothing to check.
  local target
  if spec.locate then
    local located, located_target = pcall(spec.locate, arguments)
    if not located then
      on_done(M.error(("could not determine the target for %s: %s"):format(spec.name, tostring(located_target))))
      return
    end
    local target_ok, target_problem = validate_target(located_target)
    if not target_ok then
      on_done(M.error(("invalid target for %s: %s"):format(spec.name, target_problem)))
      return
    end
    target = located_target
  else
    target = { kind = spec.access }
  end

  local decision = scope:decide(target)
  if decision.kind == "deny" then
    on_done(M.error(decision.reason))
    return
  end
  if decision.kind == "needs_permission" then
    on_done(M.needs_permission({ tool = spec.name, reason = decision.reason, target = decision.target }))
    return
  end

  local finished = false
  local function finish(outcome)
    if finished then
      return
    end
    finished = true

    local outcome_ok, outcome_problem = M.validate_outcome(outcome)
    if not outcome_ok then
      on_done(M.error(("tool %s returned a malformed outcome: %s"):format(spec.name, outcome_problem)))
      return
    end

    on_done(outcome)
  end

  local called, returned = pcall(spec.handler, arguments, { finish = finish, turn = options and options.turn })
  if not called then
    finish(M.error(("tool %s failed: %s"):format(spec.name, tostring(returned))))
    return
  end

  -- A handler that went asynchronous returns nil and calls finish later.
  if returned ~= nil then
    finish(returned)
  end
end

return M
