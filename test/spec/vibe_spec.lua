return function(t)
  local Vibe = require("agent-smith.modes.vibe")
  local Decide = require("agent-smith.ui.decide")
  local Diff = require("agent-smith.ui.diff")
  local Events = require("agent-smith.agent.events")
  local Tools = require("agent-smith.tools")

  local function run(command)
    return vim.system(command, { text = true }):wait()
  end

  --- A real repository, because vibe clones one and applies patches to it.
  --- Faking git here would test the fake.
  local function repo(files)
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    run({ "git", "init", "--quiet", root })

    for name, lines in pairs(files or {}) do
      local path = vim.fs.joinpath(root, name)
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile(lines, path)
    end

    run({ "git", "-C", root, "add", "-A" })
    run({
      "git",
      "-C",
      root,
      "-c",
      "user.email=test@example.com",
      "-c",
      "user.name=Test",
      "commit",
      "--quiet",
      "--message",
      "init",
    })
    return root
  end

  local function sandbox_root()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return path
  end

  --- A transport replaying one scripted event list per call.
  local function fake(script)
    local transport = { calls = 0, requests = {} }
    function transport.run(request, on_event)
      transport.calls = transport.calls + 1
      transport.requests[#transport.requests + 1] = request
      for _, event in ipairs(script[transport.calls] or { Events.done("complete") }) do
        on_event(event)
      end
      return { cancel = function() end }
    end
    return transport
  end

  --- The tool names offered on a given request.
  local function tools_on(transport, call)
    local names = {}
    for _, schema in ipairs(transport.requests[call].tools) do
      names[#names + 1] = schema.name
    end
    table.sort(names)
    return names
  end

  local function ui(answers)
    answers = answers or {}
    local record = { plans = {}, diffs = {}, notifications = {}, tools = {} }

    record.ui = {
      prompt = function(done)
        done(answers.instruction or "change it")
      end,
      approve_plan = function(plan, _, decide)
        record.plans[#record.plans + 1] = plan
        -- The window answers through a callback, so the fake does too. Calling it
        -- inline is what a scripted window does.
        decide(answers.plan ~= false)
      end,
      approve_diff = function(patch, fields, decide)
        record.diffs[#record.diffs + 1] = { patch = patch, fields = fields }
        decide(answers.diff ~= false)
      end,
      notify = function(message)
        record.notifications[#record.notifications + 1] = message
      end,
      event = function(event)
        if event.type == "tool_use" then
          record.tools[#record.tools + 1] = event.name
        end
      end,
    }

    return record
  end

  local function start(options)
    local results = {}
    local handle, err = Vibe.run({
      root = options.root,
      instruction = options.instruction or "change it",
      transport = options.transport,
      ui = options.ui.ui,
      config = options.config or { sandbox = { root = options.sandbox, blacklist = {} } },
      on_done = function(result)
        results[#results + 1] = result
      end,
    })

    t.settle(function()
      return #results > 0 or handle == nil
    end, 3000)

    return { handle = handle, error = err, results = results, result = results[1], ui = options.ui }
  end

  --- call 1 and 2 are the plan phase, 3 and 4 the execute phase.
  local function script(plan_arguments, edit_arguments)
    return {
      [1] = { Events.tool_use("p1", "plan", plan_arguments), Events.done("tool_calls") },
      [2] = { Events.done("complete") },
      [3] = { Events.tool_use("e1", "edit", edit_arguments), Events.done("tool_calls") },
      [4] = { Events.done("complete") },
    }
  end

  local PLAN = {
    summary = "add a comma to the greeting",
    steps = { "edit greet.lua" },
    files = { "greet.lua" },
  }

  t.describe("vibe: messages", function()
    t.it("tells the planner the request and to call plan", function()
      local message = Vibe.plan_message("add a comma")
      t.matches(message, "add a comma")
      t.matches(message, "`plan`")
    end)

    t.it("identifies itself in both phases, before anything else", function()
      -- Both conversations carry it: the plan phase and the execute phase are two
      -- requests to two different conversations, and only one of them knowing what
      -- it is talking as would be worse than neither.
      local root = repo({ ["greet.lua"] = { 'return "hello"' } })
      local sandbox = sandbox_root()
      local transport = fake(script(PLAN, {
        path = "greet.lua",
        start_row = 1,
        end_row = 1,
        text = 'return "hello,"',
      }))

      start({ root = root, transport = transport, ui = ui(), sandbox = sandbox })

      local intro = require("agent-smith.agent.identity").intro()
      t.ok(transport.requests[1].system:find(intro, 1, true) == 1, "the plan prompt")
      t.ok(transport.requests[3].system:find(intro, 1, true) == 1, "and the execute prompt")
      t.matches(transport.requests[1].system, "planning a change")
      t.matches(transport.requests[3].system, "approved plan")
    end)

    t.it("restates the approved plan as the contract", function()
      local message = Vibe.execution_message("add a comma", PLAN)
      t.matches(message, "add a comma")
      t.matches(message, "add a comma to the greeting")
      t.matches(message, "1%. edit greet%.lua")
      t.matches(message, "%- greet%.lua")
      t.matches(message, "Files you may modify %(1%)")
    end)

    t.it("survives a plan with no steps or files", function()
      local message = Vibe.execution_message("x", { summary = "y" })
      t.matches(message, "Files you may modify %(0%)")
    end)

    t.it("lists what the user added while the plan was being made", function()
      -- Nothing else carries these, so if this dropped them the message would be
      -- accepted and then never seen by anyone.
      local message = Vibe.execution_message("x", PLAN, { "use a comma", "and a space" })
      t.matches(message, "Also required, added while this was being planned %(2%)")
      t.matches(message, "1%. use a comma")
      t.matches(message, "2%. and a space")
      t.ok(message:find("Carry it out now", 1, true) > message:find("and a space", 1, true),
        "the notes come before the instruction to start")

      -- And an empty list changes nothing, which is what every other caller passes.
      t.eq(Vibe.execution_message("x", PLAN, {}), Vibe.execution_message("x", PLAN))
    end)
  end)

  t.describe("vibe: steering", function()    --- A transport the test drives, one request at a time. Steering happens while
    --- something is in flight, so the scripted fake — which answers everything at
    --- once — cannot test it.
    local function deferred()
      local transport = { calls = 0, requests = {}, emits = {} }
      function transport.run(request, on_event)
        transport.calls = transport.calls + 1
        transport.requests[#transport.requests + 1] = request
        transport.emits[transport.calls] = on_event
        return { cancel = function() end }
      end
      return transport
    end

    local function begin(root, sandbox, transport, record)
      return Vibe.run({
        root = root,
        instruction = "change it",
        transport = transport,
        ui = record.ui,
        config = { sandbox = { root = sandbox, blacklist = {} } },
      })
    end

    t.it("holds a steer typed while planning, and hands it to the executor", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"' } })
      local sandbox = sandbox_root()
      local transport = deferred()
      local record = ui()

      local handle = begin(root, sandbox, transport, record)
      t.ok(handle, "the run started")

      -- Still planning: there is no conversation that can act on it, and the plan
      -- is what the user is about to approve anyway.
      t.eq(handle:steer("use a comma, not a full stop"), "notes")
      t.not_ok(
        tostring(transport.requests[1].messages):find("not a full stop", 1, true),
        "the planner was not told"
      )

      -- The planner calls `plan`, then finishes; the fake approves it, so the
      -- execute phase is the one asking next.
      transport.emits[1](Events.tool_use("p1", "plan", PLAN))
      transport.emits[1](Events.done("tool_calls"))
      transport.emits[2](Events.done("complete"))

      t.eq(transport.calls, 3, "plan phase, then execute")
      local opening = transport.requests[3].messages[1]
      t.eq(opening.role, "user")
      t.matches(opening.content, "Also required, added while this was being planned %(1%)")
      t.matches(opening.content, "use a comma, not a full stop")

      -- And once execution is running the same key goes to that conversation, as
      -- an instruction with the context it is already holding.
      t.eq(handle:steer("also update the docs"), "queued")
      transport.emits[3](Events.done("complete"))

      local steered = transport.requests[4].messages
      t.eq(steered[#steered].role, "user")
      t.eq(steered[#steered].content, "also update the docs")

      handle:cancel()
    end)

    t.it("refuses a steer before there is a plan, and after execution ends", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"' } })
      local sandbox = sandbox_root()
      local transport = deferred()
      local record = ui({ plan = false })

      local handle = begin(root, sandbox, transport, record)
      transport.emits[1](Events.tool_use("p1", "plan", PLAN))
      transport.emits[1](Events.done("tool_calls"))
      transport.emits[2](Events.done("complete"))

      -- The plan was rejected, so the run is over with nothing left to steer.
      t.eq(handle:steer("one more thing"), false)
      t.eq(handle:steer("   "), false)
    end)
  end)

  t.describe("vibe: describe_plan", function()
    t.it("numbers the steps and counts the files", function()
      local text = Vibe.describe_plan({ summary = "s", steps = { "one", "two" }, files = { "a", "b", "c" } })
      t.matches(text, "1%. one")
      t.matches(text, "2%. two")
      t.matches(text, "Files it may modify %(3%)")
    end)
  end)

  t.describe("vibe: describe", function()
    local function describe(reason, extra)
      local result = { reason = reason, ok = true, summary = "10 in, 2 out" }
      for key, value in pairs(extra or {}) do
        result[key] = value
      end
      return Vibe.describe(result)
    end

    t.it("says what was applied", function()
      t.matches(describe("applied", { files = "2 file(s)" }), "applied 2 file%(s%)")
    end)

    t.it("distinguishes a discarding review from an empty run", function()
      t.matches(describe("discarded"), "discarded")
      t.matches(describe("no_changes"), "without changing anything")
    end)

    t.it("says a rejected plan never ran", function()
      t.matches(describe("rejected"), "nothing ran")
    end)

    t.it("falls back to the error", function()
      t.matches(describe("clone", { error = "disk on fire" }), "disk on fire")
    end)
  end)

  t.describe("vibe: the plan phase has no write tools", function()
    t.it("offers read, grep, glob and plan", function()
      local registry = Tools.readonly({ root = "/tmp", on_plan = function() end })
      t.eq(registry:names(), { "glob", "grep", "plan", "read" })
    end)

    t.it("omits plan when nobody is listening for one", function()
      t.eq(Tools.readonly({ root = "/tmp" }):names(), { "glob", "grep", "read" })
    end)

    t.it("gives the execute phase the write tools", function()
      t.eq(
        Tools.default({ root = "/tmp" }):names(),
        { "bash", "diagnostics", "edit", "glob", "grep", "read" }
      )
    end)
  end)

  t.describe("vibe: run", function()
    t.it("plans without write tools, then applies the reviewed diff", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"', "return greet" } })
      local sandbox = sandbox_root()
      local transport = fake(script(PLAN, {
        path = "greet.lua",
        start_row = 1,
        end_row = 1,
        text = 'return "hello,"',
      }))
      local record = ui()

      local outcome = start({ root = root, transport = transport, ui = record, sandbox = sandbox })

      t.ok(outcome.handle, outcome.error)
      t.eq(outcome.result.ok, true)
      t.eq(outcome.result.reason, "applied")
      t.eq(outcome.result.applied, true)

      -- The plan phase was handed no tool that can change anything, and the
      -- execute phase was.
      t.eq(tools_on(transport, 1), { "glob", "grep", "plan", "read" })
      t.eq(tools_on(transport, 3), { "bash", "diagnostics", "edit", "glob", "grep", "read" })

      -- The real repository changed, from a reviewed patch rather than a copy.
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "greet.lua"))[1], 'return "hello,"')

      -- The clone is gone.
      t.eq(vim.fn.readdir(sandbox), {})

      -- The plan reached the approval step unaltered.
      t.eq(record.plans[1].summary, PLAN.summary)
      t.eq(record.plans[1].files, { "greet.lua" })
    end)

    t.it("stops at a rejected plan without cloning anything", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"' } })
      local sandbox = sandbox_root()
      local transport = fake(script(PLAN, {}))
      local record = ui({ plan = false })

      local outcome = start({ root = root, transport = transport, ui = record, sandbox = sandbox })

      t.eq(outcome.result.ok, true)
      t.eq(outcome.result.reason, "rejected")
      t.eq(outcome.result.applied, false)
      -- Two calls: the plan and the turn that ends it. Nothing executed.
      t.eq(transport.calls, 2)
      t.eq(vim.fn.readdir(sandbox), {}, "no clone should exist")
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "greet.lua"))[1], 'return "hello"')
    end)

    t.it("refuses and records a write outside the approved plan", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"' }, ["other.lua"] = { "-- other" } })
      local sandbox = sandbox_root()
      local transport = fake(script(PLAN, {
        path = "other.lua",
        start_row = 1,
        end_row = 1,
        text = "-- rewritten",
      }))
      local record = ui()

      local outcome = start({ root = root, transport = transport, ui = record, sandbox = sandbox })

      t.eq(#outcome.result.refusals, 1, "the refusal should be recorded")
      t.matches(outcome.result.refusals[1].path, "other%.lua")
      t.matches(outcome.result.refusals[1].reason, "not in the approved plan")

      -- Refused means not applied: neither in the clone nor in the repository.
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "other.lua"))[1], "-- other")
      t.eq(outcome.result.reason, "no_changes")
      t.eq(vim.fn.readdir(sandbox), {})
    end)

    t.it("leaves the repository alone when the diff is discarded", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"' } })
      local sandbox = sandbox_root()
      local transport = fake(script(PLAN, {
        path = "greet.lua",
        start_row = 1,
        end_row = 1,
        text = 'return "nope"',
      }))
      local record = ui({ diff = false })

      local outcome = start({ root = root, transport = transport, ui = record, sandbox = sandbox })

      t.eq(outcome.result.ok, true)
      t.eq(outcome.result.reason, "discarded")
      t.eq(outcome.result.applied, false)
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "greet.lua"))[1], 'return "hello"')
      t.eq(vim.fn.readdir(sandbox), {})
      t.ok(record.diffs[1].patch ~= "", "the diff should have been shown before the decision")
    end)

    t.it("reports a run that ends without a plan", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"' } })
      local sandbox = sandbox_root()
      -- A model that answers with prose and ends the stream without planning.
      local transport = fake({
        [1] = { Events.text_delta("I would rather chat."), Events.done("complete") },
      })
      local record = ui()

      local outcome = start({ root = root, transport = transport, ui = record, sandbox = sandbox })

      t.eq(outcome.result.ok, false)
      t.eq(outcome.result.reason, "plan")
      t.matches(outcome.result.error, "without calling `plan`")
      t.eq(#record.plans, 0)
      t.eq(vim.fn.readdir(sandbox), {})
    end)

    t.it("refuses a root that is not a repository, before prompting", function()
      local plain = vim.fn.tempname()
      vim.fn.mkdir(plain, "p")
      local record = ui()

      local outcome = start({ root = plain, transport = fake({}), ui = record, sandbox = sandbox_root() })

      t.eq(outcome.handle, nil)
      t.matches(outcome.error, "not a git repository")
    end)

    t.it("carries the instructions the model was given in the execute phase", function()
      local root = repo({ ["greet.lua"] = { 'return "hello"' } })
      local transport = fake(script(PLAN, {
        path = "greet.lua",
        start_row = 1,
        end_row = 1,
        text = 'return "hello,"',
      }))

      start({ root = root, transport = transport, ui = ui(), sandbox = sandbox_root() })

      -- The execute request has to name the approved scope, because that list is
      -- what the scope is enforcing.
      local sent = transport.requests[3].messages
      local text = vim.inspect(sent)
      t.matches(text, "Files you may modify")
      t.matches(text, "greet%.lua")
    end)
  end)

  t.describe("vibe: the edit tool in disk mode", function()
    local Edit = require("agent-smith.tools.edit")
    local Scope = require("agent-smith.agent.scope")

    --- Run a handler once and hand back its outcome.
    --- Every branch of a handler must either return an outcome or call finish.
    ---@return table outcome
    local function call(tool, arguments)
      local outcome = nil
      local returned = tool.handler(arguments, {
        finish = function(result)
          outcome = result
        end,
        turn = 1,
      })
      return returned or outcome
    end

    t.it("writes to disk when asked, so bash sees the change", function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      local path = vim.fs.joinpath(root, "a.lua")
      vim.fn.writefile({ "one", "two" }, path)

      local scope = Scope.vibe({ paths = { path } })
      local decision = scope:decide({ kind = "write", path = path, range = { start_row = 1, end_row = 1 } })
      t.eq(decision.kind, "allow")

      local outcome = call(
        Edit.tool({ root = root, write_through = true }),
        { path = "a.lua", start_row = 1, end_row = 1, text = "ONE" }
      )

      t.eq(outcome.ok, true)
      t.matches(outcome.content, "written to disk")
      t.eq(vim.fn.readfile(path)[1], "ONE")
    end)

    t.it("leaves the disk alone by default", function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")
      local path = vim.fs.joinpath(root, "a.lua")
      vim.fn.writefile({ "one", "two" }, path)

      local outcome = call(Edit.tool({ root = root }), {
        path = "a.lua",
        start_row = 1,
        end_row = 1,
        text = "ONE",
      })

      t.eq(outcome.ok, true)
      t.matches(outcome.content, "unsaved")
      t.eq(vim.fn.readfile(path)[1], "one", "inline still stages in the buffer")
    end)

    t.it("creates a file the plan declared, with no stray blank line", function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")

      local outcome = call(Edit.tool({ root = root, write_through = true, allow_create = true }), {
        path = "nested/new.lua",
        start_row = 1,
        end_row = 0,
        text = "-- new\nreturn 1",
      })

      t.eq(outcome.ok, true, outcome.error)
      t.matches(outcome.content, "created")
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "nested/new.lua")), { "-- new", "return 1" })
    end)

    t.it("refuses to create one that was not declared", function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")

      local outcome = call(Edit.tool({ root = root }), {
        path = "nope.lua",
        start_row = 1,
        end_row = 0,
        text = "x",
      })

      t.eq(outcome.ok, false)
      t.matches(outcome.error, "does not exist")
    end)

    t.it("refuses to address lines of a file that does not exist", function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(root, "p")

      local outcome = call(Edit.tool({ root = root, write_through = true, allow_create = true }), {
        path = "nope.lua",
        start_row = 3,
        end_row = 5,
        text = "x",
      })

      t.eq(outcome.ok, false)
      t.matches(outcome.error, "empty")
    end)
  end)

  t.describe("diff: parsing and display", function()
    local PATCH = table.concat({
      "diff --git a/greet.lua b/greet.lua",
      "index 111..222 100644",
      "--- a/greet.lua",
      "+++ b/greet.lua",
      "@@ -1 +1 @@",
      '-return "hello"',
      '+return "hello,"',
      "diff --git a/src/deep.lua b/src/deep.lua",
      "--- a/src/deep.lua",
      "+++ b/src/deep.lua",
      "@@ -0,0 +1 @@",
      "+-- created",
    }, "\n")

    t.it("lists the files a patch touches", function()
      t.eq(Diff.files(PATCH), { "greet.lua", "src/deep.lua" })
    end)

    t.it("counts them for the dialog", function()
      t.eq(Diff.summary(PATCH), "2 files changed")
      t.eq(Diff.summary("diff --git a/x b/x\n"), "1 file changed")
      t.eq(Diff.summary(""), "no files changed")
    end)

    t.it("does not mistake content for a header", function()
      t.eq(Diff.files("+diff --git a/bogus b/bogus\n"), {})
      t.eq(Diff.files(nil), {})
    end)

    t.it("builds a read-only diff buffer", function()
      -- The body is what a decision window shows: highlights come from
      -- decorate(), and the window itself belongs to ui/decide.lua.
      local lines = Diff.body(PATCH)
      t.eq(#lines, 12)
      t.ok(lines[1]:match("^diff %-%-git"))
    end)

    t.it("says which lines were added and which were removed", function()
      -- Order matters: +++ and --- are file headers that start with the same
      -- characters as content, and colouring them as content would put a bogus
      -- green line and a bogus red line at the top of every patch.
      t.eq(Diff.highlight_for("+added"), "AgentSmithDiffAdded")
      t.eq(Diff.highlight_for("-removed"), "AgentSmithDiffRemoved")
      t.eq(Diff.highlight_for("+++ b/greet.lua"), "AgentSmithDiffMeta")
      t.eq(Diff.highlight_for("--- a/greet.lua"), "AgentSmithDiffMeta")
      t.eq(Diff.highlight_for("@@ -1 +1 @@"), "AgentSmithDiffHunk")
      t.eq(Diff.highlight_for("diff --git a/x b/x"), "AgentSmithDiffMeta")
      t.eq(Diff.highlight_for("index 111..222 100644"), "AgentSmithDiffMeta")
      -- Context is left alone.
      t.eq(Diff.highlight_for(" unchanged"), nil)
      t.eq(Diff.highlight_for(nil), nil)
    end)

    t.it("colours added lines green and removed lines red", function()
      local buffer = Diff.decorate(Decide.buffer({ lines = Diff.body(PATCH), filetype = "diff" }))

      local by_row = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, Diff.NAMESPACE, 0, -1, { details = true })) do
        by_row[mark[2]] = mark[4]
      end

      local function group(row)
        return by_row[row] and by_row[row].hl_group or nil
      end

      -- Row 5 is '-return "hello"', row 6 is '+return "hello,"'.
      t.eq(group(5), "AgentSmithDiffRemoved")
      t.eq(group(6), "AgentSmithDiffAdded")
      t.eq(group(11), "AgentSmithDiffAdded", "the added line in the second file")

      -- Whole-line, so a reader sees the line as added rather than having to find
      -- the plus. Neovim records this as a span to the start of the next line,
      -- not as an end column equal to the line's length — measured, not assumed.
      t.eq(by_row[6].end_row, 7)
      t.eq(by_row[6].end_col, 0)

      -- The file headers start with the same characters as content and must not be
      -- coloured like it, or every patch would open with a bogus green line and a
      -- bogus red one.
      t.eq(group(2), "AgentSmithDiffMeta", "--- a/greet.lua")
      t.eq(group(3), "AgentSmithDiffMeta", "+++ b/greet.lua")
      t.eq(group(0), "AgentSmithDiffMeta", "diff --git")
      t.eq(group(1), "AgentSmithDiffMeta", "index")

      t.eq(group(4), "AgentSmithDiffHunk")

      vim.api.nvim_buf_delete(buffer, { force = true })
    end)

    t.it("puts refusals in the body, where the decision is made", function()
      -- Approving a diff while believing the agent did everything in the plan
      -- would be approving something that is not what happened.
      local lines = Diff.body(PATCH, { refusals = { { path = "other.lua" } } })
      t.matches(lines[1], "refused as out of plan")
      t.matches(lines[2], "other%.lua")
      t.matches(lines[3], "^$")
    end)
  end)
end
