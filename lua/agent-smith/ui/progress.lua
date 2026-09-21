--- A run's status, drawn as virtual lines above the selection.
---
--- Above, not below. The selection is the work area, so the status belongs at
--- its top edge: anchored to the *first* selected line it stays pinned to the
--- work as the buffer changes underneath it, and the eye finds it in the same
--- place on every run.
---
--- `virt_lines_above` rather than anchoring to the line before the selection,
--- because a selection starting at line 1 has no line above it to hang from.
---
--- At most two lines, because a status that grows with activity is a status that
--- ends up covering the code being edited:
---
---   ⠹ editing greet.lua:2
---   812 in, 48000 cached, 42 out, 98% cache hit
---
--- The second line only appears once there is usage to report, so a short run
--- costs one line and not two.
---
--- Drawn with a single extmark holding `virt_lines`, which matters for three
--- reasons: the buffer is never modified, so the text cannot be saved or undone;
--- it cannot be picked up by a `read` or an `edit`; and it disappears with one
--- call instead of being tracked as text.
---
--- The spinner is a timer updating that one extmark. `render` is pure so the
--- wording is testable without a timer or a window.

local Usage = require("agent-smith.usage")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("agent-smith-progress")

M.FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

M.INTERVAL_MS = 90

--- How long the finished state stays on screen before clearing.
M.LINGER_MS = 4000

--- How much of a command to show before truncating.
M.COMMAND_WIDTH = 40

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return "?"
  end
  return vim.fs.basename(path)
end

--- A short, human phrase for what the agent is doing.
---
--- Deliberately not the raw tool call: the point of the line is that a glance
--- says what is happening, and `edit({"end_row":2,...})` does not.
---@return string|nil description
function M.describe(event)
  if type(event) ~= "table" or event.type ~= "tool_use" then
    return nil
  end

  local args = event.arguments or {}

  if event.name == "read" then
    return ("reading %s"):format(basename(args.path))
  end
  if event.name == "edit" then
    return ("editing %s:%s"):format(basename(args.path), tostring(args.start_row or "?"))
  end
  if event.name == "grep" then
    return ("searching for %s"):format(tostring(args.pattern or "?"))
  end
  if event.name == "glob" then
    return ("finding %s"):format(tostring(args.pattern or "?"))
  end
  if event.name == "bash" then
    local command = tostring(args.command or "?")
    if #command > M.COMMAND_WIDTH then
      command = command:sub(1, M.COMMAND_WIDTH) .. "…"
    end
    return ("running %s"):format(command)
  end
  if event.name == "diagnostics" then
    return "checking diagnostics"
  end

  return ("calling %s"):format(tostring(event.name))
end

--- The lines to draw. Pure.
---@param state table { frame: number|nil, action: string|nil, summary: string|nil }
---@return string[]
function M.render(state)
  state = state or {}

  local frame = state.frame and (M.FRAMES[state.frame] or M.FRAMES[1]) or ""
  local lines = { vim.trim(("%s %s"):format(frame, state.action or "working")) }

  local summary = state.summary
  if type(summary) == "string" and summary ~= "" and summary ~= "no usage reported" then
    lines[#lines + 1] = summary
  end

  return lines
end

local Progress = {}
Progress.__index = Progress

--- Start the spinner.
function Progress:start()
  if self.timer or self.interval <= 0 then
    return self
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    self.interval,
    vim.schedule_wrap(function()
      self.frame = (self.frame % #M.FRAMES) + 1
      self:draw()
    end)
  )
  return self
end

function Progress:stop()
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
  return self
end

--- Redraw the two lines onto the one extmark.
function Progress:draw()
  if not vim.api.nvim_buf_is_valid(self.buffer) then
    return self
  end

  -- Written as a statement, not as `self.done and nil or self.frame`: that idiom
  -- cannot produce nil, because `true and nil` is falsy and falls through to the
  -- `or`. A finished status would keep drawing a spinner.
  local frame = nil
  if not self.done then
    frame = self.frame
  end

  local rendered = M.render({
    frame = frame,
    action = self.action,
    summary = self.summary,
  })

  local highlights = { "AgentSmithProgress", "AgentSmithUsage" }
  local virt_lines = {}
  for index, line in ipairs(rendered) do
    virt_lines[index] = { { line, highlights[math.min(index, #highlights)] } }
  end

  local options = { virt_lines = virt_lines }
  if self.above then
    options.virt_lines_above = true
  end
  if self.id then
    options.id = self.id
  end

  local ok, id =
    pcall(vim.api.nvim_buf_set_extmark, self.buffer, M.NAMESPACE, self.anchor, 0, options)
  if ok then
    self.id = id
  end
  return self
end

--- Set the current action and redraw.
function Progress:action_for(text)
  if text then
    self.action = text
    self:draw()
  end
  return self
end

--- Route one typed event into the status.
function Progress:event(event)
  if type(event) ~= "table" then
    return self
  end

  if event.type == "tool_use" then
    self:action_for(M.describe(event))
  elseif event.type == "usage" then
    Usage.add(self.usage, event)
    self.summary = Usage.render(self.usage)
    self:draw()
  elseif event.type == "text_delta" and not self.action then
    self:action_for("writing the change")
  end

  return self
end

--- Stop, show the outcome, then clear after a moment.
function Progress:finish(result)
  self:stop()
  self.done = true
  self.action = (result and result.ok) and "done" or "stopped"

  if result and result.summary then
    self.summary = result.summary
  elseif next(self.usage) then
    self.summary = Usage.render(self.usage)
  end

  self:draw()

  if self.linger > 0 then
    vim.defer_fn(function()
      self:clear()
    end, self.linger)
  end

  return self
end

--- Remove the lines and stop the timer.
function Progress:clear()
  self:stop()

  if self.id and vim.api.nvim_buf_is_valid(self.buffer) then
    pcall(vim.api.nvim_buf_del_extmark, self.buffer, M.NAMESPACE, self.id)
  end
  self.id = nil
  return self
end

--- A status display for a buffer.
---@param fields table
---   - buffer: number|nil  Defaults to the current buffer.
---   - row: number|nil     0-indexed anchor line; the lines draw below it.
---   - above: boolean|nil  Draw above the anchor line instead of below it.
---   - interval: number|nil Spinner interval, 0 to disable.
---   - linger: number|nil   How long the finished state stays.
---@return table progress
function M.new(fields)
  fields = fields or {}

  vim.api.nvim_set_hl(0, "AgentSmithProgress", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithUsage", { link = "Comment", default = true })

  return setmetatable({
    buffer = fields.buffer or vim.api.nvim_get_current_buf(),
    anchor = fields.row or 0,
    above = fields.above == true,
    interval = fields.interval ~= nil and fields.interval or M.INTERVAL_MS,
    linger = fields.linger ~= nil and fields.linger or M.LINGER_MS,
    frame = 1,
    usage = {},
    action = nil,
    summary = nil,
    id = nil,
    timer = nil,
    done = false,
  }, Progress)
end

return M
