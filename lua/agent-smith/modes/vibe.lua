--- Vibe mode: plan, approve, execute, review.
---
--- Four phases, each a stopping point
--- (spec/decisions/0007-vibe-workflow.md):
---
---   1. plan     read-only; the agent investigates and calls `plan`
---   2. approve  the user sees the declared steps and file scope
---   3. execute  a fresh clone from current state, writes bounded to the plan
---   4. review   the clone's diff, applied to the real repository on approval
---
--- Two property of this shape are worth stating plainly, because they are the
--- reason the mode exists rather than being incidental:
---
--- **The plan is a checkable artifact.** Scope creep shows up as a deviation
--- from a plan the user read, not as a line in a diff nobody expected.
---
--- **Execution happens somewhere disposable.** The clone is created after
--- approval from the current committed state, so phase 3 starts clean and a bad
--- run costs a `rm -rf` on a cache directory.
---
--- Two consequences of the clone are load-bearing and were decided in ADR 0006:
--- it is a real clone and not a `git worktree`, because linked worktrees share
--- the parent's `hooks` and an agent with write access there can install one that
--- later runs outside any sandbox. And it is cloned from committed state, so the
--- user's dirty working tree is *not* carried over. That is a known limitation,
--- not an oversight: see spec/open-questions.md.
---
--- Notes on the enforcement rather than the flow:
---
--- Scope paths are resolved against the *clone*, not the process cwd, because
--- `Scope.normalize` resolves relative paths against the cwd and the cwd is never
--- the clone. Passing plan-relative paths straight through would build a scope
--- that matches nothing, and every write would be refused.
---
--- Refusals are recorded by wrapping the scope's `decide`. Doing it there means
--- the recording cannot be bypassed by a tool that forgets to report one, since
--- every tool call goes through that single method.

local Clone = require("agent-smith.sandbox.clone")
local Diff = require("agent-smith.ui.diff")
local Loop = require("agent-smith.agent.loop")
local Messages = require("agent-smith.agent.messages")
local Paths = require("agent-smith.tools.paths")
local Identity = require("agent-smith.agent.identity")
local Provider = require("agent-smith.providers")
local Scope = require("agent-smith.agent.scope")
local Session = require("agent-smith.session")
local Tools = require("agent-smith.tools")
local Usage = require("agent-smith.usage")

local M = {}

M.MODE = "vibe"

--- Turns allowed in the plan phase. Enough to look around, nowhere near enough
--- to wander: this phase is read-only and ends at a decision.
M.PLAN_MAX_TURNS = 12

--- Turns allowed in the execute phase. Generous, because this is the phase that
--- actually does the work and every write is bounded by the plan.
M.EXECUTE_MAX_TURNS = 30

--- The plan phase's body, behind the shared identity in `agent/identity.lua`.
M.PLAN_PROMPT = table.concat({
  "You are planning a change to a project before anyone is allowed to make it.",
  "",
  "You can read, search and list. You cannot write, and you cannot run commands:",
  "this phase exists to decide what to do, and a person has to approve the answer",
  "before any of it happens.",
  "",
  "Investigate enough to be specific about files and line numbers. Then call the",
  "`plan` tool exactly once.",
  "",
  "The `files` you list are enforced later. Anything written outside that list is",
  "refused and reported, so list every file you will need, including files you",
  "intend to create. Do not list files you only intend to read.",
  "",
  "After calling `plan`, stop.",
}, "\n")

--- The execute phase's body, behind the same identity.
M.EXECUTE_PROMPT = table.concat({
  "You are carrying out an approved plan in a throwaway clone of the project.",
  "",
  "The clone is the whole world: the paths you are given are inside it, and the",
  "real repository is not reachable from here.",
  "",
  "You may only modify the files named in the approved plan. A write outside that",
  "list is refused and reported to the user. If the plan turns out to be wrong,",
  "say so in your final message rather than working around the limit.",
  "",
  "Do not summarise your work step by step. Make the changes and stop.",
}, "\n")

--- The message that starts the plan phase.
---@return string
function M.plan_message(instruction)
  return table.concat({
    ("Request: %s"):format(instruction),
    "",
    "Work out how to satisfy it, then call `plan`.",
  }, "\n")
end

--- The message that starts the execute phase: the approved plan, restated as
--- the contract the scope is enforcing.
---
--- `notes` are what the user typed while this was being planned or while it waited
--- to be approved (see `session:steer`). They go in last and are stated as
--- requirements rather than as background: they are the most recent thing the user
--- said, and they were said with the plan in hand.
---@param instruction string
---@param plan table { summary, steps, files }
---@param notes string[]|nil
---@return string
function M.execution_message(instruction, plan, notes)
  local steps = {}
  for index, step in ipairs(plan.steps or {}) do
    steps[index] = ("%d. %s"):format(index, step)
  end

  local files = {}
  for index, file in ipairs(plan.files or {}) do
    files[index] = ("- %s"):format(file)
  end

  local lines = {
    ("Request: %s"):format(instruction),
    "",
    ("Approved plan: %s"):format(plan.summary or "(no summary)"),
    table.concat(steps, "\n"),
    "",
    ("Files you may modify (%d):"):format(#files),
    table.concat(files, "\n"),
  }

  if notes and #notes > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("Also required, added while this was being planned (%d):"):format(#notes)
    for index, note in ipairs(notes) do
      lines[#lines + 1] = ("%d. %s"):format(index, note)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Carry it out now."

  return table.concat(lines, "\n")
end

--- The plan as the user reads it before approving.
---@return string
function M.describe_plan(plan)
  -- No "Run this plan?" heading: the decision window's footer already says which
  -- keys accept and deny, so a question in the body would be asking twice.
  local lines = {
    plan.summary or "(no summary)",
    "",
    "Steps:",
  }
  for index, step in ipairs(plan.steps or {}) do
    lines[#lines + 1] = ("  %d. %s"):format(index, step)
  end

  local files = plan.files or {}
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("Files it may modify (%d):"):format(#files)
  for _, file in ipairs(files) do
    lines[#lines + 1] = ("  %s"):format(file)
  end

  return table.concat(lines, "\n")
end

--- The plan as the lines a decision window shows.
---@return string[]
function M.plan_lines(plan)
  return vim.split(M.describe_plan(plan), "\n", { plain = true })
end

--- A line describing how a run ended.
---@param result table
---@return string
function M.describe(result)
  local usage = result.summary and (" (%s)"):format(result.summary) or ""

  if result.reason == "applied" then
    return ("applied %s to the working tree%s"):format(result.files or "changes", usage)
  end
  if result.reason == "discarded" then
    return ("diff discarded; the clone was removed%s"):format(usage)
  end
  if result.reason == "no_changes" then
    return ("the agent finished without changing anything%s"):format(usage)
  end
  if result.reason == "rejected" then
    return "the plan was rejected; nothing ran"
  end

  return result.error or "the run did not finish"
end

--- Read-only tools plus `plan`.
---
--- The plan tool is registered here rather than in `tools/init.lua` because it
--- only means anything inside this mode.
local function plan_registry(root, on_plan)
  return Tools.readonly({ root = root, on_plan = on_plan })
end

--- The UI a real run uses.
function M.default_ui()
  local decide = require("agent-smith.ui.decide")
  local diff = require("agent-smith.ui.diff")
  local panel = require("agent-smith.ui.panel")
  local prompt = require("agent-smith.ui.prompt")

  return {
    prompt = function(done)
      return prompt.ask({ prompt = "agent-smith vibe", on_submit = done })
    end,
    approve_plan = function(plan, _, decide_plan)
      return decide.ask({
        title = " agent-smith plan ",
        lines = M.plan_lines(plan),
        filetype = "markdown",
        max_height = vim.o.lines - 12,
        on_decision = decide_plan,
      })
    end,
    approve_diff = function(patch, fields, decide_diff)
      return diff.review(patch, fields, decide_diff)
    end,
    -- A corner panel rather than virtual lines, because a vibe run has no buffer
    -- it owns. See ui/panel.lua.
    progress = function(fields)
      return panel.new(fields)
    end,
    notify = function(message, level)
      vim.notify(message, level or vim.log.levels.INFO)
    end,
    -- The event stream, recorded for the monitor whether or not it is on screen.
    -- Both phases feed it, so the plan phase's reads are in the log too.
    event = function(event)
      require("agent-smith.ui.monitor").get():event(event)
    end,
    done = function(result)
      require("agent-smith.ui.monitor").get():done_run(result)
    end,
  }
end

--- The status display for a run that edits files outside any buffer.
---
--- A panel pinned to a corner of the screen rather than virtual lines. Inline can
--- draw inside the buffer because the selection is the work area and the user is
--- looking at it. Vibe edits a clone and the user may scroll or switch files while
--- it runs, so a buffer-bound status would either scroll out of sight or sit in a
--- buffer nobody is looking at. See ui/panel.lua.
local function live_progress(ui)
  if not ui.progress then
    return nil
  end

  local tracker = ui.progress({})
  if tracker and tracker.start then
    tracker:start()
  end
  return tracker
end

--- Start a vibe run.
---
--- Returns immediately, because the prompt is a window. Preconditions —
--- configuration and a repository to clone — are checked synchronously and
--- reported as a return value, so a caller is not told about them through a
--- notification after the fact.
---
---@param options table
---   - instruction: string|nil   Skips the prompt when given.
---   - root: string|nil          Repository to work in.
---   - provider: string|table|nil
---   - model: string|nil
---   - config: table|nil         Resolved agent-smith configuration.
---   - transport: table|nil      Injected, for tests.
---   - ui: table|nil             Injected, for tests.
---   - plan_max_turns: number|nil
---   - execute_max_turns: number|nil
---   - on_done: fun(result)|nil
---@return table|nil session { cancel = fun() }
---@return string|nil error
function M.run(options)
  options = options or {}

  local ui = options.ui or M.default_ui()
  local config = options.config or {}

  local root = options.root or vim.fs.root(vim.uv.cwd() or ".", { ".git" }) or vim.uv.cwd()
  if not Clone.is_repository(root) then
    return nil, ("%s is not a git repository, so there is nothing to clone"):format(tostring(root))
  end

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

  local sandbox = config.sandbox or {}
  local session = { cancelled = false, prompt = nil, loop = nil, clone = nil, phase = "prompt", notes = {} }

  -- A vibe run is two conversations, not one: the plan phase and the execute
  -- phase each start from their own system prompt and message list. The user
  -- pays for both, and planning is often the larger half because that is where
  -- the files get read, so reporting only the execute phase would understate the
  -- cost of exactly the mode whose selling point is that it stops to think.
  local totals = { usage = {}, turns = 0 }

  local function record(loop_result)
    if type(loop_result) ~= "table" then
      return
    end
    Usage.add(totals.usage, loop_result.usage)
    totals.turns = totals.turns + (loop_result.turns or 0)
  end

  --- Say something to the model while a phase is in flight.
  ---
  --- Where it goes depends on which phase. Before execution there is no conversation
  --- that can act on the message — the plan is still being written, or it is waiting
  --- to be approved — so it is held and handed to the executor as a note. Once
  --- execution is running it goes to that loop, which queues it into the
  --- conversation in flight.
  ---
  --- A note is deliberately **not** shown to the planner. The plan is approved by
  --- the user before anything runs, so a note that contradicts it is caught at that
  --- checkpoint rather than by the phase that is already finished writing.
  ---
  --- Checked against `finished` before the phase, because a rejection leaves the
  --- session in its `approve` phase with no execution to come: holding a note there
  --- would be a message accepted and then never delivered, which is the failure this
  --- whole path exists to avoid.
  ---@param text string
  ---@return string|boolean "queued" when a loop took it, "notes" when it is held
  ---   for execution, false when there is nothing it can reach.
  function session:steer(text)
    if self.finished or type(text) ~= "string" or vim.trim(text) == "" then
      return false
    end

    if self.phase == "plan" or self.phase == "approve" then
      self.notes[#self.notes + 1] = vim.trim(text)
      return "notes"
    end

    if self.phase == "execute" and self.loop and type(self.loop.steer) == "function" then
      return self.loop:steer(text) and "queued" or false
    end

    -- "prompt" has no run yet, and "review" has none left.
    return false
  end

  function session:cancel()
    self.cancelled = true
    if self.prompt and type(self.prompt.cancel) == "function" then
      self.prompt.cancel()
    end
    -- A decision window left open would hold a question nobody can finish, and
    -- its answer would arrive at a run that has already stopped. Cancelling it
    -- denies, which the checkpoint handlers ignore because the session is
    -- cancelled by then.
    if self.decision and type(self.decision.cancel) == "function" then
      self.decision.cancel()
    end
    if self.loop and type(self.loop.cancel) == "function" then
      self.loop.cancel(self.loop)
    end
    if self.clone then
      Clone.discard(self.clone)
      self.clone = nil
    end
    self.prompt = nil
    self.decision = nil
    self.loop = nil
    return true
  end

  --- The single exit. Cleanup happens here so no path can leak a clone.
  local function finish(result)
    result.phase = result.phase or session.phase
    result.plan = result.plan or session.plan
    result.refusals = result.refusals or {}

    -- Read by `session:steer`: a finished run has no request left to carry a
    -- message, and the phase alone does not say so — a rejected plan leaves the
    -- session in `approve` with nothing to come.
    session.finished = true
    -- Every phase's cost, not just the last one's.
    result.summary = Usage.render(totals.usage, { turns = totals.turns })
    result.turns = totals.turns
    result.usage = totals.usage

    if session.clone then
      Clone.discard(session.clone)
      session.clone = nil
    end

    if ui.notify then
      ui.notify(
        ("agent-smith: %s"):format(M.describe(result)),
        result.ok and vim.log.levels.INFO or vim.log.levels.WARN
      )
    end

    if options.on_done then
      options.on_done(result)
    end
  end

  local approve, execute, review

  --- Phase 4. The clone's diff, then apply or discard.
  review = function(clone, refusals, loop_result)
    session.phase = "review"

    local patch, diff_error = Clone.diff(clone)
    if not patch then
      return finish({
        ok = false,
        phase = "review",
        reason = "diff",
        error = diff_error,
        refusals = refusals,
        summary = loop_result and loop_result.summary,
      })
    end

    if patch == "" then
      -- Nothing to review is a real outcome, and it is worth saying so plainly:
      -- "no changes" is often a sign the plan was misunderstood.
      return finish({
        ok = loop_result == nil or loop_result.ok ~= false,
        phase = "review",
        reason = "no_changes",
        applied = false,
        refusals = refusals,
        error = loop_result and loop_result.error or nil,
        summary = loop_result and loop_result.summary,
      })
    end

    local file_count = #Diff.files(patch)

    --- The single answer to the diff checkpoint, and the apply that follows it.
    local function decided(accepted)
      if session.cancelled then
        return
      end
      session.decision = nil

      if not accepted then
        return finish({
          ok = true,
          phase = "review",
          reason = "discarded",
          applied = false,
          refusals = refusals,
          files = ("%d file(s)"):format(file_count),
          summary = loop_result and loop_result.summary,
        })
      end

      local applied, apply_error = Clone.apply(patch, root)
      if not applied then
        return finish({
          ok = false,
          phase = "apply",
          reason = "apply",
          applied = false,
          error = ("could not apply the diff to %s: %s"):format(root, tostring(apply_error)),
          refusals = refusals,
          summary = loop_result and loop_result.summary,
        })
      end

      return finish({
        ok = true,
        phase = "review",
        reason = "applied",
        applied = true,
        refusals = refusals,
        files = ("%d file(s)"):format(file_count),
        summary = loop_result and loop_result.summary,
      })
    end

    -- Same reasoning as the plan checkpoint: with nobody to ask, the diff is the
    -- thing the run was for, so it is applied rather than discarded.
    if not ui.approve_diff then
      return decided(true)
    end

    session.decision = ui.approve_diff(patch, { root = root, clone = clone, refusals = refusals }, decided)
  end

  --- Phase 3. Fresh clone, writes bounded to the approved plan.
  execute = function(plan)
    session.phase = "execute"

    local clone, clone_error = Clone.create({
      root = root,
      sandbox_root = sandbox.root,
    })
    if not clone then
      return finish({
        ok = false,
        phase = "execute",
        reason = "clone",
        error = clone_error,
      })
    end
    session.clone = clone

    -- Absolute, inside the clone. See the note at the top of this file.
    local paths = {}
    for index, file in ipairs(plan.files or {}) do
      paths[index] = Paths.resolve(clone.directory, file)
    end

    local scope = Scope.vibe({ paths = paths, blacklist = sandbox.blacklist or {} })

    -- Recording at the one method every tool call passes through, so a refusal
    -- cannot go unreported because a tool forgot to mention it.
    local refusals = {}
    local decide = scope.decide
    scope.decide = function(this, target)
      local decision = decide(this, target)
      if decision.kind == "deny" and type(target) == "table" and target.kind == "write" then
        refusals[#refusals + 1] = { path = target.path, reason = decision.reason }
      end
      return decision
    end

    local conversation = Messages.new({
      system = Identity.system(M.EXECUTE_PROMPT),
      id = Session.id({ root = root, mode = "vibe-execute" }),
    })
    conversation:append_user(M.execution_message(session.instruction, plan, session.notes))

    local tracker = live_progress(ui)

    session.loop = Loop.run({
      transport = transport,
      tools = Tools.default({
        root = clone.directory,
        writable = clone.directory,
        network = sandbox.network == true,
        -- The clone is the staging area, so edits go to disk and not to a
        -- buffer waiting to be saved. `bash` needs it too: a test run has to see
        -- the changes it is testing. `allow_create` because a plan may declare a
        -- file that does not exist yet.
        write_through = true,
        allow_create = true,
      }),
      scope = scope,
      conversation = conversation,
      max_turns = options.execute_max_turns or M.EXECUTE_MAX_TURNS,
      stall_timeout_ms = config.stall_timeout_ms,
      on_event = function(event)
        if tracker then
          tracker:event(event)
        end
        if ui.event then
          ui.event(event)
        end
      end,
      on_permission = function(_, decide_permission)
        -- Nothing should escalate here: vibe refuses instead of escalating, by
        -- design (ADR 0007 against ADR 0004). This is the defensive path, and it
        -- refuses rather than approving: the user approved a plan, not a tool
        -- call, so agreeing to one here would be agreeing to something they were
        -- never shown.
        decide_permission(false)
      end,
      on_done = function(result)
        if tracker then
          tracker:finish(result)
        end
        if ui.done then
          ui.done(result)
        end
        record(result)
        if session.cancelled then
          return
        end
        -- Reviewed even when the loop stopped badly: a half-finished run that
        -- changed files still has a diff worth showing, and the user is the one
        -- who should decide whether it is worth keeping.
        review(clone, refusals, result)
      end,
    })
  end

  --- Phase 2. The user reads the plan.
  ---
  --- Asynchronous, because the plan is shown in a window: the answer arrives
  --- through `decide` rather than as a return value.
  approve = function(plan, loop_result)
    session.phase = "approve"

    --- The single answer to the plan checkpoint.
    local function decided(accepted)
      if session.cancelled then
        return
      end
      session.decision = nil

      if not accepted then
        return finish({
          ok = true,
          phase = "approve",
          reason = "rejected",
          applied = false,
          summary = loop_result and loop_result.summary,
        })
      end

      execute(plan)
    end

    -- No asker means nobody to ask. The plan is the model's own proposal and the
    -- scope is what bounds it, so proceeding is the only option that leaves the
    -- mode usable when the UI is injected; the window is the check in a real run.
    if not ui.approve_plan then
      return decided(true)
    end

    session.decision = ui.approve_plan(plan, { root = root }, decided)
  end

  --- Phase 1. Read-only investigation that must end in a plan.
  local function plan(instruction)
    session.phase = "plan"

    local captured = nil
    local conversation = Messages.new({
      system = Identity.system(M.PLAN_PROMPT),
      id = Session.id({ root = root, mode = "vibe-plan" }),
    })
    conversation:append_user(M.plan_message(instruction))

    local tracker = live_progress(ui)

    session.loop = Loop.run({
      transport = transport,
      tools = plan_registry(root, function(captured_plan)
        captured = captured_plan
      end),
      -- Read-only tools, so this scope is never asked about a write. Empty
      -- paths is the statement that nothing is writable during planning.
      scope = Scope.vibe({ paths = {}, blacklist = sandbox.blacklist or {} }),
      conversation = conversation,
      max_turns = options.plan_max_turns or M.PLAN_MAX_TURNS,
      stall_timeout_ms = config.stall_timeout_ms,
      on_event = function(event)
        if tracker then
          tracker:event(event)
        end
        if ui.event then
          ui.event(event)
        end
      end,
      on_done = function(result)
        if tracker then
          tracker:finish(result)
        end
        if ui.done then
          ui.done(result)
        end
        record(result)
        if session.cancelled then
          return
        end

        -- A captured plan is what this phase was for. It counts even if the
        -- loop went on to hit its turn limit afterwards, which is a model being
        -- chatty rather than a run that failed.
        if captured then
          session.plan = captured
          return approve(captured, result)
        end

        finish({
          ok = false,
          phase = "plan",
          reason = "plan",
          error = result.error or "the agent finished without calling `plan`, so there is nothing to approve",
          summary = result.summary,
        })
      end,
    })
  end

  local function start(instruction)
    if session.cancelled then
      return
    end
    session.instruction = instruction
    plan(instruction)
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

return M
