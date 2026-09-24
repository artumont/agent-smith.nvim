--- Inline mode: edit one region of one file.
---
--- The flow is selection, instruction, agent, buffer. There is no chat surface
--- and no separate apply step, which follows from decisions already made:
---
---   - Edits are bounded to the selection. An attempt outside it escalates
---     rather than failing, and the user is asked
---     (spec/decisions/0004-bounded-edit-with-escalation.md).
---   - Writes are allow-by-default inside the selection, and land in the buffer
---     rather than on disk, so a whole turn reverts with one `u`
---     (spec/decisions/0005-permission-model.md).
---
--- Together those mean the "preview" is the buffer itself and acceptance is
--- saving. A separate review pane would be a second copy of the same text.
---
--- The UI is injected, and the prompt is callback-based because it is a window
--- rather than a blocking question. That makes `run` asynchronous once the user
--- is asked: it returns a session handle immediately, and the work starts when
--- the answer arrives. A session whose preconditions fail returns nil and a
--- reason without ever opening a prompt.

local Loop = require("agent-smith.agent.loop")
local Messages = require("agent-smith.agent.messages")
local Monitor = require("agent-smith.ui.monitor")
local Paths = require("agent-smith.tools.paths")
local Provider = require("agent-smith.providers")
local Scope = require("agent-smith.agent.scope")
local Session = require("agent-smith.session")
local Tools = require("agent-smith.tools")

local M = {}

M.MODE = "inline"

--- Where the status can draw, relative to the selection.
M.POSITIONS = { above = true, below = true }

--- Used when the configuration says nothing.
M.DEFAULT_POSITION = "above"

--- What the model is told about the situation it is in.
---
--- Short on purpose. The tool schemas already describe the tools, and the
--- permission system enforces the bound, so the prompt only has to stop the
--- model from being surprised by either.
M.SYSTEM_PROMPT = table.concat({
  "You are editing one region of one file inside a running Neovim.",
  "",
  "The selected lines are the only place you may write. If a correct change needs",
  "a second location, attempt it anyway: the request is escalated to the user with",
  "your reason, and they decide. Do not silently narrow the change to fit.",
  "",
  "Reading is not restricted. Read whatever else you need before editing.",
  "",
  "Line numbers in read output are the numbers edit expects. Prefer the smallest",
  "change that satisfies the request, and do not summarise the change back: make",
  "it, and say nothing beyond a sentence if something needs flagging.",
}, "\n")

--- The selected range of a buffer, from the visual marks.
---@return table|nil range { start_row, end_row } 1-indexed, inclusive.
function M.selection_range(buffer)
  buffer = buffer or vim.api.nvim_get_current_buf()

  local first = vim.api.nvim_buf_get_mark(buffer, "<")
  local last = vim.api.nvim_buf_get_mark(buffer, ">")
  if first[1] == 0 or last[1] == 0 then
    return nil
  end

  local start_row, end_row = first[1], last[1]
  if start_row > end_row then
    start_row, end_row = end_row, start_row
  end
  return { start_row = start_row, end_row = end_row }
end

--- The project root for a file: the git work tree containing it, or the cwd.
function M.project_root(path)
  return vim.fs.root(path, { ".git" }) or vim.uv.cwd()
end

--- The message describing the work.
local function user_message(shown_path, range, lines, instruction)
  local numbered = {}
  for index, line in ipairs(lines) do
    numbered[index] = ("%d| %s"):format(range.start_row + index - 1, line)
  end

  return table.concat({
    ("File: %s"):format(shown_path),
    ("Selected lines %d-%d:"):format(range.start_row, range.end_row),
    "```",
    table.concat(numbered, "\n"),
    "```",
    "",
    ("Instruction: %s"):format(instruction),
  }, "\n")
end

--- The real UI.
---
--- `prompt` is asynchronous and takes a callback; `progress` returns a status
--- display or nil. Both are what a test replaces.
function M.default_ui()
  local approval = require("agent-smith.ui.approval")
  local prompt = require("agent-smith.ui.prompt")
  local progress = require("agent-smith.ui.progress")

  return {
    prompt = function(done)
      return prompt.ask({ prompt = "agent-smith", on_submit = done })
    end,
    approve = function(permission)
      return approval.decide(permission)
    end,
    notify = function(message, level)
      vim.notify(message, level or vim.log.levels.INFO)
    end,
    -- The event stream, recorded for the monitor whether or not it is on screen.
    -- Every run feeds it, and `:Smith monitor` / <leader>am is what opens it.
    event = function(event)
      Monitor.get():event(event)
    end,
    done = function(result)
      Monitor.get():done_run(result)
    end,
    progress = function(fields)
      return progress.new(fields)
    end,
  }
end

--- Start an inline edit.
---
--- Returns immediately. Preconditions are checked synchronously, so a caller
--- gets nil and a reason for those; everything after the instruction arrives
--- through `on_done`.
---
---@param options table
---   - instruction: string|nil  Skips the prompt when given.
---   - buffer: number|nil       Defaults to the current buffer.
---   - range: table|nil         Defaults to the visual selection.
---   - root: string|nil         Defaults to the git work tree or cwd.
---   - provider: string|table|nil
---   - model: string|nil
---   - config: table|nil        Resolved agent-smith configuration.
---   - transport: table|nil     Injected, for tests.
---   - ui: table|nil            Injected, for tests.
---   - max_turns: number|nil
---   - on_done: fun(result)|nil
---@return table|nil session { cancel = fun() }
---@return string|nil error
function M.run(options)
  options = options or {}

  local buffer = options.buffer or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buffer)
  if name == "" then
    return nil, "the buffer has no file, so there is nothing to edit"
  end

  local range = options.range or M.selection_range(buffer)
  if not range then
    return nil, "no selection: select some lines first"
  end

  local root = options.root or M.project_root(name)
  local ui = options.ui or M.default_ui()
  local config = options.config or {}

  -- Resolved before the prompt, deliberately: a configuration problem should be
  -- reported now rather than after the user has typed an instruction.
  local transport = options.transport
  if not transport then
    local model = options.model or config.model
    if type(model) ~= "string" or model == "" then
      return nil, "no model configured; pass model in setup() or to this call"
    end

    local built, build_error = Provider.transport_for({
      provider = options.provider or config.provider or "zen",
      model = model,
      format = options.format,
    })
    if not built then
      return nil, build_error
    end
    transport = built
  end

  -- Where the status draws, also resolved before the prompt. Both positions work
  -- — above marks where the work area begins, below stays clear of the code that
  -- precedes the selection — so it is the user's choice rather than a correctness
  -- question. Either way it is anchored to the selection and not to the viewport,
  -- so it cannot end up somewhere the user is not already looking.
  local position = config.progress and config.progress.position or M.DEFAULT_POSITION
  if not M.POSITIONS[position] then
    return nil,
      ("progress.position must be one of %s, got %q"):format(
        table.concat(vim.tbl_keys(M.POSITIONS), ", "),
        tostring(position)
      )
  end

  -- 0-indexed. virt_lines draw below the line they are attached to, which is why
  -- "below" needs both a different line and virt_lines_above left off.
  local anchor, above = range.start_row - 1, true
  if position == "below" then
    anchor, above = range.end_row - 1, false
  end

  local session = { cancelled = false, prompt = nil, loop = nil }

  function session:cancel()
    self.cancelled = true
    if self.prompt and type(self.prompt.cancel) == "function" then
      self.prompt.cancel()
    end
    if self.loop and type(self.loop.cancel) == "function" then
      self.loop.cancel(self.loop)
    end
    self.prompt = nil
    self.loop = nil
    return true
  end

  --- Say something to the model while the run is in flight.
  ---
  --- Forwarded to the loop, which only accepts it while it is still running — so
  --- a steer that arrives after the loop finished is refused by the same rule as one
  --- for a run that never started, rather than being quietly held.
  ---@return string|boolean "queued" when the loop took it, false when it could not.
  function session:steer(text)
    if self.loop and type(self.loop.steer) == "function" then
      return self.loop:steer(text) and "queued" or false
    end
    return false
  end

  --- Everything after the instruction is known.
  local function start(instruction)
    if session.cancelled then
      return
    end

    local lines = vim.api.nvim_buf_get_lines(buffer, range.start_row - 1, range.end_row, false)

    local conversation = Messages.new({
      system = M.SYSTEM_PROMPT,
      id = Session.id({ root = root, mode = M.MODE }),
    })
    conversation:append_user(user_message(Paths.display(root, name), range, lines, instruction))

    local scope = Scope.inline({
      buffer = buffer,
      start_row = range.start_row,
      end_row = range.end_row,
      -- The blacklist is a guardrail that sits on top of the sandbox, not a
      -- boundary: spec/decisions/0005-permission-model.md.
      blacklist = (config.sandbox and config.sandbox.blacklist) or {},
    })

    -- No writable path: inline mode edits buffers, so a command that writes to
    -- the project should fail loudly rather than quietly succeed.
    local registry = Tools.default({ root = root, writable = nil })

    local tracker = ui.progress and ui.progress({ buffer = buffer, row = anchor, above = above })
    if tracker and tracker.start then
      tracker:start()
    end

    session.loop = Loop.run({
      transport = transport,
      tools = registry,
      scope = scope,
      conversation = conversation,
      max_turns = options.max_turns,
      stall_timeout_ms = config.stall_timeout_ms,
      on_event = function(event)
        if tracker then
          tracker:event(event)
        end
        if ui.event then
          ui.event(event)
        end
      end,
      on_permission = function(permission, decide)
        decide(ui.approve(permission) == true)
      end,
      on_done = function(result)
        if tracker then
          tracker:finish(result)
        end
        if ui.done then
          ui.done(result)
        end
        if ui.notify and result.summary then
          -- The cause goes in the same line as the cost. A run that stopped
          -- badly and reports only its token usage tells the user nothing about
          -- what went wrong, which is exactly the case a stall produces.
          local message = result.summary
          if not result.ok and result.error then
            message = ("%s — %s"):format(message, result.error)
          end
          ui.notify(
            ("agent-smith: %s"):format(message),
            result.ok and vim.log.levels.INFO or vim.log.levels.WARN
          )
        end
        if options.on_done then
          options.on_done(result)
        end
      end,
    })
  end

  if options.instruction ~= nil then
    if vim.trim(options.instruction) == "" then
      return nil, "cancelled"
    end
    start(options.instruction)
  else
    session.prompt = ui.prompt(function(text)
      session.prompt = nil
      if session.cancelled then
        return
      end
      if type(text) ~= "string" or vim.trim(text) == "" then
        return
      end
      start(text)
    end)
  end

  return session, nil
end

--- Start an inline edit on the visual selection.
---
--- The entry point for a keymap: reads the marks immediately, because they are
--- only reliable right after leaving visual mode.
function M.visual(options)
  return M.run(options)
end

return M
