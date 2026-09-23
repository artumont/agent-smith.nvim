--- A live view of the event stream, in a scratch buffer.
---
--- The status line says *what* is happening now: one action, two lines at most.
--- That is the right thing to look at while a run is behaving, and the wrong
--- thing to look at when it is not — a run that has stopped producing events is
--- indistinguishable, from a one-line status, from a run that is thinking hard.
--- There is nothing to compare against, so there is no way to tell a slow answer
--- from a hang.
---
--- This is the other surface: every event, in order, timestamped, with the time
--- each tool call took and how long the current one has been going. A stalled
--- command is then visible as a line that has been "running" for far longer than
--- it should be, with the model's own request above it.
---
--- Deliberately a buffer in a split rather than a float (ui/panel.lua is the
--- float). A monitor is read *after* something went wrong, which means
--- scrollback, search, and a buffer that outlives the run — none of which a
--- small non-focusable float can offer. It is also the one UI here that is
--- useful to read line by line, so it should behave like a buffer.
---
--- Events are recorded whether or not the window is open, so opening it after a
--- run that went wrong shows that run rather than an empty buffer. Drawing is
--- skipped while it is closed, and flushed on open.
---
--- See spec/decisions/0015-the-event-stream-is-visible.md for why this is a
--- buffer and not a float, and spec/decisions/0014-stalled-runs-are-aborted.md
--- for the stall this is meant to make legible.

local Usage = require("agent-smith.usage")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("agent-smith-monitor")

--- Buffer name, so the same monitor can be found again rather than duplicated.
M.BUFFER_NAME = "agent-smith://stream"

M.FILETYPE = "agent-smith-stream"

--- Rows of screen the split takes. Enough for the header, a few tool calls and
--- a couple of usage lines, without hiding the file the run is about.
M.HEIGHT = 14

--- How many entries are kept. A long run is unbounded otherwise, and a monitor
--- that grows forever is a monitor that eventually leaks the whole session.
M.MAX_ENTRIES = 2000

--- Shown once entries start being dropped, so the log never looks complete when
--- it is not.
M.DROPPED_PREFIX = "···· %d earlier entries dropped ····"

--- How much of a text delta or command to show on one line.
M.WIDTH = 72

M.SPINNER_MS = 90

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentSmithMonitorHeader", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorText", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorThinking", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorTool", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorUsage", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorDone", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorDim", { link = "NonText", default = true })
end

--- Collapse to one line and shorten it.
---
--- Deltas arrive as sentence fragments and commands arrive multi-line, and an
--- entry that wraps stops being scannable — which is the whole point of the
--- column of timestamps.
---@param text string
---@param width number|nil
---@return string
function M.oneline(text, width)
  local flat = tostring(text or ""):gsub("%s+", " ")
  flat = vim.trim(flat)

  local limit = width or M.WIDTH
  if vim.fn.strchars(flat) > limit then
    flat = vim.fn.strcharpart(flat, 0, limit) .. "…"
  end
  return flat
end

--- A duration as a short, human string.
---
--- Seconds under a minute, minutes and seconds above it: the interesting
--- question about a tool call is "is this still going", and "1m42s" answers it
--- where "102000 ms" does not.
---@param ms number
---@return string
function M.duration(ms)
  local seconds = math.max(math.floor((ms or 0) / 1000), 0)
  if seconds < 60 then
    return ("%ds"):format(seconds)
  end
  return ("%dm%02ds"):format(math.floor(seconds / 60), seconds % 60)
end

--- The header line. Pure.
---@param state table { frame: number|nil, action: string|nil, elapsed_ms: number|nil, summary: string|nil }
---@return string
function M.header(state)
  state = state or {}

  local parts = {}
  -- A frame index means still working; nil means the run is over and nothing
  -- should look like it is still turning. Written as a statement because
  -- `state.frame and ... or ""` cannot produce an empty string from frame 0.
  if state.frame then
    parts[#parts + 1] = require("agent-smith.ui.progress").FRAMES[state.frame] or ""
  end
  parts[#parts + 1] = state.action or "idle"
  if state.elapsed_ms then
    parts[#parts + 1] = M.duration(state.elapsed_ms)
  end
  if state.summary and state.summary ~= "no usage reported" then
    parts[#parts + 1] = state.summary
  end

  return table.concat(parts, "  ")
end

--- The lines an event contributes. Pure.
---
--- Returns records rather than strings so the caller can highlight by kind
--- without re-parsing its own output.
---@param event table A typed event.
---@return table[] { { text: string, kind: string } } Empty when there is nothing to show.
function M.entry(event)
  if type(event) ~= "table" then
    return {}
  end

  if event.type == "text_delta" then
    return { { kind = "text", label = "text", body = M.oneline(event.text) } }
  end

  if event.type == "thinking_delta" then
    return { { kind = "thinking", label = "think", body = M.oneline(event.text) } }
  end

  if event.type == "tool_use" then
    local arguments = event.arguments or {}
    -- The command or path, not the JSON: the description above it is already the
    -- human phrase, and this line is the detail that phrase hides.
    local detail = arguments.command or arguments.path or arguments.pattern or ""
    if detail == "" then
      return { { kind = "tool", text = ("tool    %s"):format(tostring(event.name)) } }
    end

    return {
      { kind = "tool", text = ("tool    %s"):format(tostring(event.name)) },
      { kind = "dim", text = ("        %s"):format(M.oneline(detail, M.WIDTH)) },
    }
  end

  if event.type == "usage" then
    return { { kind = "usage", text = ("usage   %s"):format(Usage.render(event)) } }
  end

  if event.type == "error" then
    return { { kind = "error", text = ("error   %s"):format(M.oneline(event.message)) } }
  end

  if event.type == "done" then
    return { { kind = "done", text = ("done    %s"):format(tostring(event.reason)) } }
  end

  return { { kind = "dim", text = ("other   %s"):format(tostring(event.type)) } }
end

local Monitor = {}
Monitor.__index = Monitor

--- The time to stamp an entry with, as "HH:MM:SS".
function Monitor:stamp()
  return os.date("%H:%M:%S", self.clock())
end

--- Append records, joining consecutive text deltas.
---
--- A delta per token would be a line per token. While the previous entry is a
--- delta of the same kind, deltas extend it instead of starting a new line, so a
--- streamed sentence reads as one line and a tool call still gets its own.
---
--- The accumulated body is kept separately from the rendered line, because the
--- rendered line is clipped to M.WIDTH and gluing clipped lines together would
--- lose everything past the first clip.
---@param records table[]
function Monitor:append(records)
  for _, record in ipairs(records) do
    if record.label then
      self:extend(record)
    else
      self:flush_text()
      record.stamp = self:stamp()
      self.entries[#self.entries + 1] = record
    end
  end

  while #self.entries > M.MAX_ENTRIES do
    table.remove(self.entries, 1)
    self.dropped = self.dropped + 1
  end
end

--- Add one delta to the running text entry, or start one.
---@param record table { kind: string, label: string, body: string }
function Monitor:extend(record)
  if self.text_entry and self.text_entry.kind ~= record.kind then
    self:flush_text()
  end

  if not self.text_entry then
    self.text_entry = {
      kind = record.kind,
      label = record.label,
      body = record.body,
      text = ("%s    %s"):format(record.label, record.body),
      stamp = self:stamp(),
    }
    self.entries[#self.entries + 1] = self.text_entry
    return
  end

  self.text_entry.body = vim.trim(self.text_entry.body .. " " .. record.body)
  self.text_entry.text = ("%s    %s"):format(self.text_entry.label, M.oneline(self.text_entry.body))
end

--- Stop extending the current text entry. The next delta starts a new one.
function Monitor:flush_text()
  self.text_entry = nil
end

--- Note that the current tool call is no longer running.
---
--- A tool result never reaches this module: the loop resolves outcomes into the
--- conversation and sends them back, so the next event is the model's reply.
--- "Returned" is therefore what can be said honestly — whether the command
--- succeeded is in the transcript the model sees, not here.
function Monitor:settle_running()
  local running = self.running
  if not running then
    return
  end

  self.entries[#self.entries + 1] = {
    kind = "dim",
    stamp = self:stamp(),
    text = ("        returned after %s"):format(M.duration(self:now() - running.started_ms)),
  }
  self.running = nil
end

--- Record one typed event.
function Monitor:event(event)
  if type(event) ~= "table" then
    return self
  end

  if self.done then
    -- A second run in the same session: say so rather than letting two runs read
    -- as one continuous stream.
    self.done = false
    self.turn = 0
    self.entries[#self.entries + 1] = { kind = "dim", stamp = self:stamp(), text = "" }
    self.entries[#self.entries + 1] = {
      kind = "header",
      stamp = self:stamp(),
      text = "···· new run ····",
    }
  end

  if not self.in_turn then
    self.turn = self.turn + 1
    self.in_turn = true
    self.turn_tools = {}
    self.entries[#self.entries + 1] = {
      kind = "header",
      stamp = self:stamp(),
      text = ("turn %d  request sent"):format(self.turn),
    }
  end

  self:settle_running()

  if event.type == "tool_use" then
    local description = require("agent-smith.ui.progress").describe(event)
    self.turn_tools[#self.turn_tools + 1] = description
    self.action = description
  elseif event.type == "usage" then
    Usage.add(self.usage, event)
    self.summary = Usage.render(self.usage)
  elseif event.type == "done" then
    self.in_turn = false
    -- `done` is the end of the *stream*, and the tools the turn asked for run
    -- immediately after it — not while their `tool_use` events were streaming.
    -- Starting the clock here is what makes a hung command show up as a growing
    -- elapsed time instead of a completed call.
    if #self.turn_tools > 0 then
      self.running = {
        description = table.concat(self.turn_tools, ", "),
        started_ms = self:now(),
      }
      self.turn_tools = {}
    end
  elseif event.type == "error" then
    self.in_turn = false
  end

  self:append(M.entry(event))
  self:draw()
  return self
end

--- Record the end of a run.
---
--- The loop's own result is the only place a stall appears — the transport never
--- reports one, because from the transport's side nothing is wrong: it simply
--- never answered. Saying so here is what turns "it hung" into a cause.
function Monitor:done_run(result)
  result = result or {}
  self:settle_running()
  self:flush_text()
  self.done = true
  self.in_turn = false
  self.turn_tools = {}

  local outcome = result.ok and "finished" or "stopped"
  local detail = result.error or result.reason or "?"
  self.done_action = outcome
  self.entries[#self.entries + 1] = {
    kind = result.ok and "done" or "error",
    stamp = self:stamp(),
    text = ("%s  %s"):format(outcome, M.oneline(detail)),
  }

  if result.summary then
    self.summary = result.summary
  end

  self:stop()
  self:draw()
  return self
end

--- Whether the window is on screen and still valid.
---@return boolean
function Monitor:has_window()
  return self.window ~= nil and vim.api.nvim_win_is_valid(self.window)
end

--- Whether the cursor was at the bottom before an update.
---
--- A log that yanks the cursor back to the tail while somebody reads scrollback
--- is worse than one that stops following: the reader loses their place on every
--- event. Following only happens when they were already at the end.
---@return boolean
function Monitor:pinned()
  if not self:has_window() then
    return false
  end
  local last = vim.api.nvim_buf_line_count(self.buffer)
  return vim.api.nvim_win_get_cursor(self.window)[1] >= last
end

--- The buffer's lines, with the stamps.
---@return string[]
function Monitor:lines()
  local lines = { M.header(self:header_state()) }
  if self.dropped > 0 then
    lines[#lines + 1] = M.DROPPED_PREFIX:format(self.dropped)
  end

  for _, entry in ipairs(self.entries) do
    if entry.stamp and entry.text ~= "" then
      lines[#lines + 1] = ("%s  %s"):format(entry.stamp, entry.text)
    else
      lines[#lines + 1] = entry.text
    end
  end

  return lines
end

--- What the header should say right now.
function Monitor:header_state()
  local state = { summary = self.summary }
  if self.done then
    state.action = self.done_action or "finished"
    return state
  end

  state.frame = self.frame
  if self.running then
    state.action = self.running.description
    state.elapsed_ms = self:now() - self.running.started_ms
  else
    state.action = self.action or "idle"
  end
  return state
end

--- Redraw, if there is somewhere to draw to.
function Monitor:draw()
  if not self:has_window() or not vim.api.nvim_buf_is_valid(self.buffer) then
    return self
  end

  local lines = self:lines()
  local pinned = self:pinned()

  pcall(vim.api.nvim_buf_set_lines, self.buffer, 0, -1, false, lines)
  -- The monitor is not a file and must never look like one that was edited.
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = self.buffer })

  pcall(vim.api.nvim_buf_clear_namespace, self.buffer, M.NAMESPACE, 0, -1)
  local row = 0
  pcall(vim.api.nvim_buf_add_highlight, self.buffer, M.NAMESPACE, "AgentSmithMonitorHeader", row, 0, -1)
  row = row + 1

  if self.dropped > 0 then
    pcall(vim.api.nvim_buf_add_highlight, self.buffer, M.NAMESPACE, "AgentSmithMonitorDim", row, 0, -1)
    row = row + 1
  end

  for _, entry in ipairs(self.entries) do
    local group = "AgentSmithMonitor" .. entry.kind:sub(1, 1):upper() .. entry.kind:sub(2)
    pcall(vim.api.nvim_buf_add_highlight, self.buffer, M.NAMESPACE, group, row, 0, -1)
    row = row + 1
  end

  if pinned then
    vim.api.nvim_win_call(self.window, function()
      vim.cmd("normal! Gzb")
    end)
  end

  return self
end

--- Start following the clock, for the elapsed time in the header.
function Monitor:start()
  if self.timer or self.closed then
    return self
  end

  self.timer = vim.uv.new_timer()
  self.timer:start(
    0,
    M.SPINNER_MS,
    vim.schedule_wrap(function()
      self.frame = (self.frame % #require("agent-smith.ui.progress").FRAMES) + 1
      self:draw()
    end)
  )
  return self
end

function Monitor:stop()
  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end
  return self
end

local function bind_buffer(buffer)
  vim.keymap.set("n", "q", function()
    M.get():close()
  end, { buffer = buffer, desc = "agent-smith: close the stream monitor" })

  vim.keymap.set("n", "X", function()
    -- Cancel through the public API rather than the handle: the monitor has no
    -- business holding a reference to a run, and this is the same path
    -- <leader>ax takes.
    local cancelled = require("agent-smith").cancel()
    if not cancelled then
      vim.notify("agent-smith: no run in flight", vim.log.levels.WARN)
    end
  end, { buffer = buffer, desc = "agent-smith: cancel the run" })

  vim.keymap.set("n", "<C-c>", function()
    M.get():clear()
  end, { buffer = buffer, desc = "agent-smith: clear the stream monitor" })
end

--- Open the monitor in a split, or focus it if it is already open.
---@return boolean ok
function Monitor:open()
  if self:has_window() then
    vim.api.nvim_set_current_win(self.window)
    self:draw()
    self:start()
    return true
  end

  -- Opened from a float (the inline prompt, a decision window) there is no
  -- window to split, and `:split` from a float is either a no-op or an error
  -- depending on the version. Anchor to a real window first.
  local anchor = nil
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      anchor = win
      break
    end
  end
  if anchor == nil then
    return false
  end
  vim.api.nvim_set_current_win(anchor)

  local opened = pcall(vim.cmd, "silent botright split")
  if not opened then
    return false
  end

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, self.buffer)
  pcall(vim.cmd, ("silent resize %d"):format(M.HEIGHT))

  self.window = win
  bind_buffer(self.buffer)
  self.closed = false
  self:draw()
  self:start()
  return true
end

--- Close the window. The buffer and its contents survive.
function Monitor:close()
  self:stop()
  if self:has_window() then
    pcall(vim.api.nvim_win_close, self.window, true)
  end
  self.window = nil
  return self
end

--- Open it if it is closed, close it if it is open.
function Monitor:toggle()
  if self:has_window() and vim.api.nvim_get_current_win() == self.window then
    return self:close()
  end
  self:open()
  return self
end

--- Throw the recorded stream away.
function Monitor:clear()
  self.entries = {}
  self.dropped = 0
  self.usage = {}
  self.summary = nil
  self.running = nil
  self.text_entry = nil
  self.turn_tools = {}
  self.in_turn = false
  self.turn = 0
  self:draw()
  return self
end

--- The process-wide monitor.
---
--- One per session on purpose: a run is a session-wide event, and a monitor per
--- run would show an empty buffer to somebody who opened it after the run that
--- went wrong. `:Smith monitor` and the keymap therefore name the same thing.
---@return table monitor
function M.get()
  if M.instance and vim.api.nvim_buf_is_valid(M.instance.buffer) then
    return M.instance
  end
  M.instance = M.new()
  return M.instance
end

--- Forget the singleton. For tests, which each want a fresh buffer.
function M.reset()
  if M.instance then
    M.instance:stop()
  end
  M.instance = nil
end

--- A monitor.
---@param fields table|nil
---   - clock: fun() -> number  Epoch seconds, for the stamps. Default os.time.
---   - now: fun() -> number    Monotonic milliseconds, for durations. Default vim.uv.now.
---@return table monitor
function M.new(fields)
  fields = fields or {}
  setup_highlights()

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "hide"
  vim.bo[buffer].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buffer, M.BUFFER_NAME)
  vim.bo[buffer].filetype = M.FILETYPE

  return setmetatable({
    buffer = buffer,
    window = nil,
    entries = {},
    dropped = 0,
    usage = {},
    summary = nil,
    action = nil,
    running = nil,
    text_entry = nil,
    turn_tools = {},
    frame = 1,
    turn = 0,
    in_turn = false,
    done = false,
    done_action = nil,
    closed = false,
    timer = nil,
    clock = fields.clock or os.time,
    now = fields.now or vim.uv.now,
  }, Monitor)
end

return M
