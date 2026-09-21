--- The typed event contract.
---
--- This module is the interface between transports and everything else. The
--- loop, the tools, the permission layer and the UI consume these events and
--- nothing else; a transport's only job is to translate a vendor wire format
--- into them.
---
--- See spec/decisions/0002-typed-event-contract.md for why this exists and
--- spec/events.md for the field-level schema.
---
--- The module is pure data. It performs no I/O, holds no state, and the tables
--- it returns carry no metatables.

local M = {}

--- Every event type, listed in the order they tend to appear in a stream.
M.types = {
  "text_delta",
  "thinking_delta",
  "tool_use",
  "tool_result",
  "usage",
  "done",
  "error",
}

--- Why a stream ended.
---
--- `tool_calls` is not a final state: the loop executes the requested tools and
--- continues. It is still a `done` event because it terminates one stream.
M.done_reasons = {
  "complete",
  "tool_calls",
  "length",
  "content_filter",
  "cancelled",
}

--- Token fields a usage event may carry. Exported so consumers can sum them
--- without duplicating the list.
M.token_fields = {
  "input_tokens",
  "output_tokens",
  "cache_read_tokens",
  "cache_write_tokens",
  "reasoning_tokens",
}

local REASON_SET = {}
for _, name in ipairs(M.done_reasons) do
  REASON_SET[name] = true
end

--- Incremental assistant text.
function M.text_delta(text)
  return { type = "text_delta", text = text }
end

--- Incremental reasoning text. Rendered distinctly from assistant text.
function M.thinking_delta(text)
  return { type = "thinking_delta", text = text }
end

--- The model requests a tool.
---
--- `arguments` must be the complete decoded argument object, never a partial
--- one. Reassembling streamed JSON is the transport's job.
---@param id string Correlation key, echoed by the matching tool_result.
---@param name string Tool name.
---@param arguments table Decoded arguments; may be empty.
function M.tool_use(id, name, arguments)
  return { type = "tool_use", id = id, name = name, arguments = arguments }
end

--- A tool succeeded.
---@param id string The tool_use id being answered.
---@param content string What the model should see.
function M.tool_result_ok(id, content)
  return { type = "tool_result", id = id, ok = true, content = content }
end

--- A tool failed, was denied, or is otherwise not usable.
---@param id string The tool_use id being answered.
---@param message string What the model should see.
function M.tool_result_error(id, message)
  return { type = "tool_result", id = id, ok = false, error = message }
end

--- Token accounting for a turn.
---
--- May appear more than once in a stream, because vendors report input and
--- output tokens at different points. Sum across events rather than reading the
--- last one.
---@param fields table Any subset of agent-smith.agent.events.token_fields.
function M.usage(fields)
  local event = { type = "usage" }
  for name, value in pairs(fields or {}) do
    event[name] = value
  end
  return event
end

--- Terminate a stream.
---@param reason string One of agent-smith.agent.events.done_reasons.
function M.done(reason)
  return { type = "done", reason = reason }
end

--- Terminate a stream with a cause.
---@param message string Human-readable failure.
---@param detail string|nil Optional machine-readable cause, e.g. "transport".
function M.error(message, detail)
  return { type = "error", message = message, detail = detail }
end

--- Whether an event terminates its stream.
---
--- `done` and `error` are terminal; nothing else is, including `tool_use`,
--- which the loop answers and continues past.
function M.is_terminal(event)
  return type(event) == "table" and (event.type == "done" or event.type == "error")
end

local function add(problems, message)
  problems[#problems + 1] = message
end

--- Check one field's presence and type.
---@param optional boolean|nil When true, a nil value is accepted.
local function field(event, name, kind, problems, optional)
  local value = event[name]
  if value == nil then
    if not optional then
      add(problems, ("missing required field '%s'"):format(name))
    end
  elseif type(value) ~= kind then
    add(problems, ("field '%s' must be %s, got %s"):format(name, kind, type(value)))
  end
end

local function non_empty(event, name, problems)
  if event[name] == "" then
    add(problems, ("field '%s' must not be empty"):format(name))
  end
end

local checks = {}

checks.text_delta = function(event, problems)
  field(event, "text", "string", problems)
end

checks.thinking_delta = checks.text_delta

checks.tool_use = function(event, problems)
  field(event, "id", "string", problems)
  field(event, "name", "string", problems)
  field(event, "arguments", "table", problems)
  non_empty(event, "id", problems)
  non_empty(event, "name", problems)
end

checks.tool_result = function(event, problems)
  field(event, "id", "string", problems)

  if type(event.ok) ~= "boolean" then
    add(problems, ("field 'ok' must be boolean, got %s"):format(type(event.ok)))
    return
  end

  if event.ok then
    field(event, "content", "string", problems)
    if event.error ~= nil then
      add(problems, "field 'error' is not allowed when ok is true")
    end
  else
    field(event, "error", "string", problems)
    if event.content ~= nil then
      add(problems, "field 'content' is not allowed when ok is false")
    end
  end
end

checks.usage = function(event, problems)
  local present = false
  for _, name in ipairs(M.token_fields) do
    local value = event[name]
    if value ~= nil then
      present = true
      if type(value) ~= "number" or value < 0 then
        add(problems, ("field '%s' must be a non-negative number, got %s"):format(name, tostring(value)))
      end
    end
  end
  if not present then
    add(problems, "at least one token field is required (" .. table.concat(M.token_fields, ", ") .. ")")
  end
end

checks.done = function(event, problems)
  field(event, "reason", "string", problems)
  if type(event.reason) == "string" and not REASON_SET[event.reason] then
    add(
      problems,
      ("field 'reason' must be one of %s, got %q"):format(table.concat(M.done_reasons, ", "), event.reason)
    )
  end
end

checks.error = function(event, problems)
  field(event, "message", "string", problems)
  field(event, "detail", "string", problems, true)
end

--- Check an event against the schema.
---
--- Fields the schema does not mention are ignored, which is what allows a
--- transport to be updated before this schema is.
---@param event any
---@return boolean ok
---@return string|nil problems Every problem found, joined with "; ".
function M.validate(event)
  if type(event) ~= "table" then
    return false, "event must be a table, got " .. type(event)
  end

  local kind = event.type
  if type(kind) ~= "string" then
    return false, "event.type must be a string, got " .. type(kind)
  end

  local check = checks[kind]
  if not check then
    return false,
      ("unknown event type %q; expected one of %s"):format(kind, table.concat(M.types, ", "))
  end

  local problems = {}
  check(event, problems)

  if #problems > 0 then
    return false, ("invalid %s event: %s"):format(kind, table.concat(problems, "; "))
  end

  return true
end

return M
