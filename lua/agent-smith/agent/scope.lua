--- The scope object for a session: what the agent is allowed to touch.
---
--- Reads are not bounded. Writes are bounded by the mode:
---
---   inline  writes are confined to a range in one buffer, and an attempt
---           outside it escalates instead of failing
---   vibe    writes are confined to the set of paths in the approved plan, and
---           an attempt outside it is refused
---
--- Command execution is filtered by a blacklist that stops accidents and
--- nothing more. The boundary is the sandbox, not this object. See
--- spec/decisions/0005-permission-model.md.
---
--- See spec/decisions/0004-bounded-edit-with-escalation.md for why inline
--- escalates rather than denying, and spec/decisions/0007-vibe-workflow.md for
--- why vibe does the opposite.

local M = {}

local Scope = {}
Scope.__index = Scope

--- Make a path comparable.
---
--- Relative paths are resolved against the working directory so that a scope
--- built from a buffer name and a target built from a model-supplied path
--- compare correctly.
---@param path string
---@return string
function M.normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
end

local function normalize_rows(start_row, end_row)
  if start_row > end_row then
    return end_row, start_row
  end
  return start_row, end_row
end

--- A stable key for a target, so an approval can be matched to the exact thing
--- that was approved rather than to the tool in general.
---@return string
local function target_key(target)
  if target.kind == "write" then
    local range = target.range
    if range then
      return ("write:%s:%s-%s"):format(M.normalize(target.path), range.start_row, range.end_row)
    end
    return ("write:%s"):format(M.normalize(target.path))
  end
  if target.kind == "execute" then
    return "execute:" .. (target.command or "")
  end
  if target.kind == "read" then
    return "read:" .. M.normalize(target.path or "")
  end
  return "unknown:" .. tostring(target.kind)
end

M.target_key = target_key

--- A scope for an inline edit.
---
---@param fields table
---   - buffer: integer          Buffer the selection came from.
---   - start_row: integer       1-indexed, inclusive.
---   - end_row: integer         1-indexed, inclusive. May be below start_row.
---   - blacklist: string[]|nil  Lua patterns for refused commands.
---   - escalation: boolean|nil  Defaults to true.
---@return table scope
function M.inline(fields)
  assert(type(fields) == "table", "inline scope needs a fields table")
  assert(type(fields.buffer) == "number", "inline scope needs a buffer")
  assert(type(fields.start_row) == "number", "inline scope needs start_row")
  assert(type(fields.end_row) == "number", "inline scope needs end_row")

  local name = vim.api.nvim_buf_get_name(fields.buffer)
  if name == "" then
    error("inline scope needs a named buffer", 0)
  end

  local start_row, end_row = normalize_rows(fields.start_row, fields.end_row)

  return setmetatable({
    kind = "inline",
    buffer = fields.buffer,
    path = M.normalize(name),
    start_row = start_row,
    end_row = end_row,
    blacklist = fields.blacklist or {},
    escalation = fields.escalation ~= false,
    grants = {},
  }, Scope)
end

--- A scope for a vibe run.
---
---@param fields table
---   - paths: string[]          Paths in the approved plan.
---   - blacklist: string[]|nil  Lua patterns for refused commands.
---   - escalation: boolean|nil  Defaults to false: out-of-plan writes are
---                              refused and reported, not escalated.
---@return table scope
function M.vibe(fields)
  assert(type(fields) == "table", "vibe scope needs a fields table")
  assert(type(fields.paths) == "table", "vibe scope needs a paths list")

  local paths = {}
  for index, path in ipairs(fields.paths) do
    if type(path) ~= "string" or path == "" then
      error(("vibe scope paths[%d] must be a non-empty string"):format(index), 0)
    end
    paths[M.normalize(path)] = true
  end

  return setmetatable({
    kind = "vibe",
    paths = paths,
    blacklist = fields.blacklist or {},
    escalation = fields.escalation == true,
    grants = {},
  }, Scope)
end

--- Allow a target once, overriding the scope for a single use.
---
--- Used when the user approves an escalated request. The grant is consumed by
--- the next decision, so an approval cannot silently become a standing
--- permission. See spec/decisions/0004-bounded-edit-with-escalation.md.
---@param target table
function Scope:grant(target)
  self.grants[target_key(target)] = true
end

--- Whether a write target is inside the scope.
---
--- Reports the reason for a refusal rather than a bare boolean, because the
--- user sees that reason when the edit is escalated.
---@param target table { path: string, range: table|nil }
---@return boolean allowed
---@return string|nil reason
function Scope:allows_write(target)
  if self.kind == "vibe" then
    if self.paths[M.normalize(target.path)] then
      return true
    end
    return false, ("%s is not in the approved plan scope"):format(target.path)
  end

  -- inline
  local path = M.normalize(target.path)
  if path ~= self.path then
    return false, ("%s is a different file from the edited buffer"):format(target.path)
  end

  local range = target.range
  if range == nil then
    return false, "the edit does not declare a range"
  end

  if range.start_row < self.start_row or range.end_row > self.end_row then
    return false,
      ("lines %d-%d are outside the selected range %d-%d"):format(
        range.start_row,
        range.end_row,
        self.start_row,
        self.end_row
      )
  end

  return true
end

--- The blacklist pattern a command matches, or nil when it is not blocked.
---@param command string
---@return string|nil pattern
function Scope:blocked_command(command)
  for _, pattern in ipairs(self.blacklist) do
    if command:match(pattern) then
      return pattern
    end
  end
  return nil
end

--- Whether a read target is permitted.
---
--- Currently every read is allowed. Whether reads should be bounded to the
--- project is unresolved: see spec/open-questions.md Q9. This method exists so
--- that settling it is a change here and nowhere else -- reads already arrive
--- as targets, so the tools never need to change.
---@param target table The read target, carrying whatever path the tool states.
---@return boolean allowed
---@return string|nil reason
function Scope:allows_read(target)
  if type(target) ~= "table" then
    return false, "the read target has no fields"
  end
  return true
end

--- Decide whether a target may be acted on.
---
--- Reads are always allowed. A refused write either escalates or is denied,
--- depending on the mode. A blacklisted command is always denied: it is a
--- guardrail, and nothing escalates past it.
---
---@param target table { kind: "read"|"write"|"execute", ... }
---@return table decision
---   { kind = "allow" }
---   { kind = "deny", reason = string, target = table? }
---   { kind = "needs_permission", reason = string, target = table }
function Scope:decide(target)
  if type(target) ~= "table" or type(target.kind) ~= "string" then
    return { kind = "deny", reason = "the target has no kind" }
  end

  -- An approval is consumed by the decision it authorises. Checked before
  -- anything else, so an approved write is not re-escalated by the same rules
  -- that produced the request.
  local key = target_key(target)
  if self.grants[key] then
    self.grants[key] = nil
    return { kind = "allow" }
  end

  if target.kind == "read" then
    local allowed, reason = self:allows_read(target)
    if allowed then
      return { kind = "allow" }
    end
    return { kind = "deny", reason = reason, target = target }
  end

  if target.kind == "write" then
    if type(target.path) ~= "string" or target.path == "" then
      return { kind = "deny", reason = "the write target has no path" }
    end

    local allowed, reason = self:allows_write(target)
    if allowed then
      return { kind = "allow" }
    end

    if self.escalation then
      return { kind = "needs_permission", reason = reason, target = target }
    end
    return { kind = "deny", reason = reason, target = target }
  end

  if target.kind == "execute" then
    if type(target.command) ~= "string" then
      return { kind = "deny", reason = "the execute target has no command" }
    end

    local pattern = self:blocked_command(target.command)
    if pattern then
      return {
        kind = "deny",
        reason = ("the command matches the blacklist pattern %q"):format(pattern),
      }
    end
    return { kind = "allow" }
  end

  return { kind = "deny", reason = ("unknown target kind %q"):format(target.kind) }
end

return M
