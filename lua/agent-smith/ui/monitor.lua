--- A live view of the event stream, in a floating scratch buffer.
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
--- Presented as the same float as `ui/prompt.lua` (see `ui/float.lua`), and
--- entered, so scrolling and searching the log work. It first shipped as a split
--- instead, on the theory that reading a log wants a real window; in practice a
--- split rearranges the user's window layout for a run they may only want to
--- glance at, and a float holding a *real buffer* keeps the scrollback and search
--- that the split was for. The lesson is in the amendment to
--- spec/decisions/0015-the-event-stream-is-visible.md.
---
--- The log itself is still a buffer, not the window: events are recorded whether
--- or not the float is open, so opening it after a run that went wrong shows that
--- run rather than an empty window. Drawing is skipped while it is closed, and
--- flushed on open.
---
--- See spec/decisions/0015-the-event-stream-is-visible.md for what this surfaces
--- and why, and spec/decisions/0014-stalled-runs-are-aborted.md for the stall it is
--- meant to make legible.

local Float = require("agent-smith.ui.float")
local Prompt = require("agent-smith.ui.prompt")
local Usage = require("agent-smith.usage")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("agent-smith-monitor")

--- Buffer name, so the same monitor can be found again rather than duplicated.
M.BUFFER_NAME = "agent-smith://stream"

M.FILETYPE = "agent-smith-stream"

--- Desired float size. Enough for the header, a handful of tool calls and a
--- couple of usage lines; `ui/float.lua` clamps it to the editor and centres it.
M.WIDTH = 100
M.HEIGHT = 24

--- The hint on the bottom border, in the same shape `ui/prompt.lua` uses: formatted
--- chunks, so the keys and the descriptions take theme colours.
---
--- Carried here rather than left to the documentation because a key that only
--- exists in the help is a key nobody finds.
M.HINT = {
  { " s ", "Keyword" },
  { "to steer ", "Comment" },
  { "─", "FloatBorder" },
  { " q ", "Keyword" },
  { "to close ", "Comment" },
  { "─", "FloatBorder" },
  { " X ", "Keyword" },
  { "to cancel ", "Comment" },
  { "─", "FloatBorder" },
  { " <C-c> ", "Keyword" },
  { "to clear ", "Comment" },
}

--- Rows the steer input takes, of its own content.
M.STEER_HEIGHT = 2

--- Columns of the monitor's content the steer input gives up to its own frame:
--- one each side, plus the two the monitor's right and left columns need to stay
--- clear. Computed rather than guessed — an input one column too wide puts its
--- right border through the monitor's frame, which is the class of bug this
--- replaced.
M.STEER_INSET = 4

--- The steer input's z-index, above the log's default of 50: it is drawn over the
--- log's content, and which of two floats wins is otherwise down to the order they
--- happened to be created in.
M.STEER_ZINDEX = 60

--- The border hint. Pure, so the wording is testable without a window.
---@return table|string
function M.hint()
  return M.HINT
end

--- How many entries are kept. A long run is unbounded otherwise, and a monitor
--- that grows forever is a monitor that eventually leaks the whole session.
M.MAX_ENTRIES = 2000

--- Shown once entries start being dropped, so the log never looks complete when
--- it is not.
M.DROPPED_PREFIX = "···· %d earlier entries dropped ····"

--- How much of a text delta or command to show on one line. Wider than the float
--- is not useful — the line is clipped, not wrapped — and narrower than the float
--- wastes it.
M.CLIP_WIDTH = 90

M.SPINNER_MS = 90

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AgentSmithMonitorHeader", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorText", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorThinking", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorTool", { link = "Special", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorUsage", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorDone", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithMonitorSteer", { link = "Title", default = true })
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

  local limit = width or M.CLIP_WIDTH
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
      { kind = "dim", text = ("        %s"):format(M.oneline(detail, M.CLIP_WIDTH)) },
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

--- Where the docked steer input sits: a bordered box inside the bottom of the
--- monitor's content box.
---
--- A bordered box, and **not** a top-only border. The first version passed a border
--- table with empty strings everywhere but the top edge, which Neovim still
--- reserves cells for: the input's empty *left* border sat on the monitor's own
--- left border column and occluded it, and the input's text landed one column in.
--- Measured on a real screen before and after. Fitting a real border inside the
--- content box asks for no cell that belongs to the monitor's frame.
---
--- Rows are found from the bottom, so a taller log does not move the input while a
--- taller *window* does.
---@param geometry table The monitor's own float rect { row, col, width, height }.
---@param height number|nil Rows of input. Defaults to M.STEER_HEIGHT.
---@return table at { row, col, width, height } Content rect, for `ui/float.lua`.
function M.steer_geometry(geometry, height)
  local content_height = height or M.STEER_HEIGHT

  -- One row per border edge, so the input's frame lands on log lines rather than
  -- on the monitor's top or bottom border.
  local box_height = content_height + 2

  -- M.STEER_INSET accounts for both of the input's border columns and both of the
  -- monitor's edge columns. Never wider than what is left: on a narrow monitor a
  -- box that ignores the arithmetic would be drawn through the frame, which is
  -- worse than a narrow input.
  local width = math.max(geometry.width - M.STEER_INSET, 1)

  return {
    row = math.max(geometry.row + geometry.height - box_height, geometry.row),
    col = geometry.col + 2,
    width = width,
    height = content_height,
  }
end

local Monitor = {}
Monitor.__index = Monitor

--- The time to stamp an entry with, as "HH:MM:SS".
function Monitor:stamp()
  return os.date("%H:%M:%S", self.clock())
end

--- Append records, joining consecutive text deltas.
---
--- Add one entry, and note that the rendered body is stale.
---
--- Every append goes through here so the render cache cannot be wrong: the body is
--- only rebuilt when this revision has moved.
---@param record table
---@return table record
function Monitor:append_entry(record)
  self.entries[#self.entries + 1] = record
  self.revision = self.revision + 1
  return record
end

--- A delta per token would be a line per token. While the previous entry is a
--- delta of the same kind, deltas extend it instead of starting a new line, so a
--- streamed sentence reads as one line and a tool call still gets its own.
---
--- The accumulated body is kept separately from the rendered line, because the
--- rendered line is clipped to M.CLIP_WIDTH and gluing clipped lines together would
--- lose everything past the first clip.
---@param records table[]
function Monitor:append(records)
  for _, record in ipairs(records) do
    if record.label then
      self:extend(record)
    else
      self:flush_text()
      record.stamp = self:stamp()
      self:append_entry(record)
    end
  end

  while #self.entries > M.MAX_ENTRIES do
    table.remove(self.entries, 1)
    self.dropped = self.dropped + 1
    self.revision = self.revision + 1
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
    self:append_entry(self.text_entry)
    return
  end

  self.text_entry.body = vim.trim(self.text_entry.body .. " " .. record.body)
  self.text_entry.text = ("%s    %s"):format(self.text_entry.label, M.oneline(self.text_entry.body))
  self.revision = self.revision + 1
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

  self:append_entry({
    kind = "dim",
    stamp = self:stamp(),
    text = ("        returned after %s"):format(M.duration(self:now() - running.started_ms)),
  })
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
    self:append_entry({ kind = "dim", stamp = self:stamp(), text = "" })
    self:append_entry({
      kind = "header",
      stamp = self:stamp(),
      text = "···· new run ····",
    })
  end

  if not self.in_turn then
    self.turn = self.turn + 1
    self.in_turn = true
    self.turn_tools = {}
    self:append_entry({
      kind = "header",
      stamp = self:stamp(),
      text = ("turn %d  request sent"):format(self.turn),
    })
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
  self:append_entry({
    kind = result.ok and "done" or "error",
    stamp = self:stamp(),
    text = ("%s  %s"):format(outcome, M.oneline(detail)),
  })

  if result.summary then
    self.summary = result.summary
  end

  -- A steer the run ended before delivering is said out loud. Otherwise the log
  -- shows the user's message with no reply after it, which reads as the model
  -- ignoring them rather than as a message that never left.
  if (result.undelivered_steers or 0) > 0 then
    self:append_entry({
      kind = "error",
      stamp = self:stamp(),
      text = ("%d steer(s) never left — the run ended first"):format(result.undelivered_steers),
    })
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

--- Record what the user steered, and what became of it.
---
--- Three outcomes, and the log has to tell them apart: the message is on its way to
--- the model, it is being held until there is a request that can carry it (a vibe
--- run that is still planning), or nothing took it. Text that was not delivered is
--- kept in the log rather than only reported in a notification — a notification
--- disappears, and a line in the buffer can be yanked back out and sent again,
--- which is the difference between a lost message and an inconvenient one.
---@param text string
---@param status string|boolean "queued", "notes", or false.
function Monitor:steered(text, status)
  self:flush_text()

  local kind, line = "steer", ("steer   %s"):format(M.oneline(text))
  if status == "notes" then
    -- Said out loud, because a message that influenced the *execution* and not the
    -- plan looks identical to one that influenced nothing until the plan is read.
    line = ("steer   held for execution — %s"):format(M.oneline(text))
  elseif not status then
    kind = "error"
    line = ("not sent, the run is over — %s"):format(M.oneline(text))
  end

  self:append_entry({ kind = kind, stamp = self:stamp(), text = line })
  self:draw()
  return self
end

--- Open the steer input along the bottom of the float.
---
--- The input is `ui/prompt.lua` — type, `:w` to send, `q` to abandon — docked,
--- because "type here and `:w` sends it" is one behaviour and should not exist
--- twice. Where the text goes is `handle:steer` in the loop: it is queued and
--- reaches the model with the next request, extending the run by a turn if the
--- model was already finishing
--- (spec/decisions/0016-steering-is-delivered-on-the-next-turn.md).
---
--- Opened whether or not a run is in flight. A message that cannot be delivered
--- has to say so; refusing to open the input would leave the user wondering
--- whether the keybind worked.
---@return boolean ok
function Monitor:steer()
  if not self:has_window() then
    return false
  end

  if self.steer_handle and vim.api.nvim_win_is_valid(self.steer_handle.window) then
    -- Already typing: focus what is there rather than stacking a second box.
    vim.api.nvim_set_current_win(self.steer_handle.window)
    return true
  end

  self.steer_handle = Prompt.ask({
    prompt = " agent-smith steer ",
    at = M.steer_geometry(vim.api.nvim_win_get_config(self.window)),
    on_submit = function(text)
      self.steer_handle = nil
      if text == nil then
        return
      end
      self:steered(text, require("agent-smith").steer(text))
    end,
  })

  self:place_steer()
  return true
end

--- Re-dock the steer input, after the monitor moved or the editor resized.
---
--- Called on creation and on every draw: the input is positioned *relative to the
--- monitor's rect*, so a resize that moves the monitor has to move it too, and
--- `Float.place` would only re-centre it.
function Monitor:place_steer()
  if not self.steer_handle or not vim.api.nvim_win_is_valid(self.steer_handle.window) then
    return self
  end

  local at = M.steer_geometry(vim.api.nvim_win_get_config(self.window))
  pcall(vim.api.nvim_win_set_config, self.steer_handle.window, {
    relative = "editor",
    row = at.row,
    col = at.col,
    width = at.width,
    height = at.height,
    zindex = M.STEER_ZINDEX,
  })
  return self
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

--- The body lines (everything under the header), rendered.
---
--- Cached, because a spinner tick asks for this eleven times a second and the
--- answer only changes when an entry does. Measured before this existed, at 2000
--- entries: 0.15 ms to re-render the lines, 0.56 ms to write them and 1.9 ms to
--- re-apply a highlight per line — 4 ms of work per tick, almost all of it
--- rewriting text that had not changed.
---@return string[] lines
---@return string[] kinds One per line, for highlighting.
function Monitor:body()
  if self.body_cache and self.body_revision == self.revision and self.body_dropped == self.dropped then
    return self.body_cache, self.body_kinds
  end

  local lines, kinds = {}, {}
  if self.dropped > 0 then
    lines[#lines + 1] = M.DROPPED_PREFIX:format(self.dropped)
    kinds[#kinds + 1] = "dim"
  end

  for _, entry in ipairs(self.entries) do
    if entry.stamp and entry.text ~= "" then
      lines[#lines + 1] = ("%s  %s"):format(entry.stamp, entry.text)
    else
      lines[#lines + 1] = entry.text
    end
    kinds[#kinds + 1] = entry.kind
  end

  self.body_cache, self.body_kinds = lines, kinds
  self.body_revision, self.body_dropped = self.revision, self.dropped
  return lines, kinds
end

--- The buffer's lines, with the stamps. Header first, then the body.
---@return string[]
function Monitor:lines()
  local lines = { M.header(self:header_state()) }
  for _, line in ipairs(self:body()) do
    lines[#lines + 1] = line
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
---
--- Split into what actually changed, because this is what the spinner calls: eleven
--- times a second it used to rewrite every line, re-apply a highlight per entry and
--- reconfigure both floating windows — telling the UI the screen had changed when
--- nothing had. A tick that only moves the spinner now touches one line.
function Monitor:draw()
  if not self:has_window() or not vim.api.nvim_buf_is_valid(self.buffer) then
    return self
  end

  -- Read before writing anything: it compares the cursor to the last line.
  local pinned = self:pinned()

  self:draw_header()
  self:draw_body()
  -- The monitor is not a file and must never look like one that was edited.
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = self.buffer })

  if pinned then
    vim.api.nvim_win_call(self.window, function()
      vim.cmd("normal! Gzb")
    end)
  end

  self:place()
  return self
end

--- Write the header, when it has changed at all.
---
--- The spinner makes it change every tick, which is the one line a tick is allowed
--- to cost.
function Monitor:draw_header()
  local line = M.header(self:header_state())
  if line == self.drawn_header then
    return self
  end
  self.drawn_header = line

  pcall(vim.api.nvim_buf_set_lines, self.buffer, 0, 1, false, { line })
  pcall(vim.api.nvim_buf_clear_namespace, self.buffer, M.NAMESPACE, 0, 1)
  pcall(vim.api.nvim_buf_add_highlight, self.buffer, M.NAMESPACE, "AgentSmithMonitorHeader", 0, 0, -1)
  return self
end

--- Write the body, from the first line that differs.
---
--- The common cases are one appended entry and one entry's text getting longer, so
--- starting from the first difference — not from the top — is what makes an event
--- cost one line instead of the whole log.
function Monitor:draw_body()
  local lines, kinds = self:body()

  -- The revision is what every change bumps, so an unmoved revision means the
  -- rendered body cannot differ — including the last line, which deltas extend.
  if self.drawn_revision == self.revision and self.drawn_dropped == self.dropped then
    return self
  end

  local written = self.drawn_body_lines

  local from
  if self.drawn_dropped ~= self.dropped or #lines < written then
    -- A trimmed log shifts every line up, and a shrunken one has nothing in common.
    from = 1
  elseif #lines > written then
    from = written + 1
  else
    -- Same length: only the last entry can have changed, because that is the only
    -- entry deltas ever extend.
    from = math.max(written, 1)
  end

  local slice = {}
  for index = from, #lines do
    slice[#slice + 1] = lines[index]
  end
  -- Body line `index` is buffer row `index`: the header is row 0.
  pcall(vim.api.nvim_buf_set_lines, self.buffer, from, -1, false, slice)

  for index = from, #lines do
    pcall(vim.api.nvim_buf_clear_namespace, self.buffer, M.NAMESPACE, index, index + 1)
    local kind = kinds[index]
    local group = "AgentSmithMonitor" .. kind:sub(1, 1):upper() .. kind:sub(2)
    pcall(vim.api.nvim_buf_add_highlight, self.buffer, M.NAMESPACE, group, index, 0, -1)
  end

  self.drawn_body_lines = #lines
  self.drawn_dropped = self.dropped
  self.drawn_revision = self.revision
  return self
end

--- Put the windows where they belong, when that has changed.
---
--- Reconfiguring a float tells the UI the screen changed, so doing it unconditionally
--- on every tick was asking for a redraw eleven times a second to move a window to
--- where it already was. Both windows are placed from the editor's size, so that is
--- what decides whether there is anything to do.
function Monitor:place()
  local key = ("%dx%d"):format(vim.o.columns, vim.o.lines)
  if key ~= self.placed_key then
    self.placed_key = key
    Float.place(self.window, M.WIDTH, M.HEIGHT)
    -- The steer input is docked to the monitor's rect, so it moves with it.
    self:place_steer()
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

  vim.keymap.set("n", "s", function()
    M.get():steer()
  end, { buffer = buffer, desc = "agent-smith: steer the run" })

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

--- Open the monitor as a float, or focus it if it is already open.
---@return boolean ok
function Monitor:open()
  if self:has_window() then
    vim.api.nvim_set_current_win(self.window)
    self:draw()
    self:start()
    return true
  end

  -- `Float.open` raises when Neovim refuses the window, which is a real
  -- possibility on a tiny editor; a monitor that cannot be shown is not worth
  -- taking the session down for.
  local opened, window = pcall(Float.open, {
    buffer = self.buffer,
    width = M.WIDTH,
    height = M.HEIGHT,
    title = " agent-smith stream ",
    footer = M.hint(),
  })
  if not opened then
    return false
  end

  self.window = window
  self.closed = false

  -- One entry per line, clipped rather than continued: columns of timestamps are
  -- what makes the log scannable, and a wrapped entry destroys them.
  vim.wo[window].wrap = false
  vim.wo[window].number = false

  -- The window was just opened at the current size, so the first draw has nothing
  -- to place. Without this every open would reconfigure it once for no reason.
  self.placed_key = ("%dx%d"):format(vim.o.columns, vim.o.lines)

  bind_buffer(self.buffer)
  self:draw()
  self:start()
  return true
end

--- Close the window. The buffer and its contents survive.
---
--- A float holds a nofile buffer with `bufhidden = hide`, so closing is only ever
--- about the window: the log has to outlive it, which is the whole reason it is
--- recorded whether or not anybody is looking. A steer input still open is
--- abandoned with it, since there is nothing left to steer.
function Monitor:close()
  self:stop()
  if self.steer_handle and type(self.steer_handle.cancel) == "function" then
    self.steer_handle.cancel()
  end
  self.steer_handle = nil
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
  -- Through the revision, not by clearing the caches: the cache is what decides
  -- what to rewrite, and this is a change like any other.
  self.revision = self.revision + 1
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

  local monitor = setmetatable({
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
    -- Render caches. See `body`, `draw_header` and `draw_body`: they are what keep a
    -- spinner tick from rewriting a log that has not changed.
    revision = 0,
    body_cache = nil,
    body_kinds = nil,
    body_revision = nil,
    body_dropped = nil,
    drawn_header = nil,
    drawn_body_lines = 0,
    drawn_dropped = 0,
    drawn_revision = nil,
    placed_key = nil,
    clock = fields.clock or os.time,
    now = fields.now or vim.uv.now,
  }, Monitor)

  -- A finished monitor has no spinner to redraw it, so a terminal resize would
  -- leave it centred where the middle of the screen used to be. The draw itself
  -- re-places the window; all this does is ask for one. Buffer-local autocmds are
  -- not an option: VimResized is about the editor, not about a buffer.
  -- One augroup for the process, not one per instance: the monitor is a session
  -- singleton, and `clear = true` means a new instance takes over the previous
  -- one's autocmd rather than leaving it behind to redraw a buffer nobody has.
  local group = vim.api.nvim_create_augroup("agent-smith-monitor", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      monitor:draw()
    end,
  })

  return monitor
end

return M
