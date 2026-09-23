return function(t)
  local Inline = require("agent-smith.modes.inline")
  local Events = require("agent-smith.agent.events")

  local counter = 0

  --- A temp project with one file, opened in a buffer, and a selection on it.
  local function fixture(lines, first, last)
    counter = counter + 1
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local name = ("file%d.lua"):format(counter)
    local path = vim.fs.joinpath(root, name)
    vim.fn.writefile(lines, path)

    -- bufadd + bufload, not create_buf + set_name: bufload will not reload a
    -- buffer that is already loaded, so a named-but-empty buffer would keep its
    -- single blank line and every mark would be out of range.
    local buffer = vim.fn.bufadd(path)
    vim.fn.bufload(buffer)

    vim.api.nvim_buf_set_mark(buffer, "<", first or 1, 0, {})
    vim.api.nvim_buf_set_mark(buffer, ">", last or #lines, 0, {})

    return { root = root, name = name, path = path, buffer = buffer }
  end

  local function buffer_lines(f)
    return vim.api.nvim_buf_get_lines(f.buffer, 0, -1, false)
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

  --- A UI that records what it was asked, and answers as told.
  local function ui(answers)
    answers = answers or {}
    local record = { prompts = 0, approvals = {}, notifications = {}, events = {} }

    record.ui = {
      -- The prompt is a window now, so it answers through a callback rather than
      -- returning. Calling it inline is what a scripted window does.
      prompt = function(done)
        record.prompts = record.prompts + 1
        done(answers.instruction)
      end,
      approve = function(permission)
        record.approvals[#record.approvals + 1] = permission
        return answers.approve == true
      end,
      notify = function(message)
        record.notifications[#record.notifications + 1] = message
      end,
      event = function(event)
        record.events[#record.events + 1] = event
      end,
      -- Records where the status was asked to draw, then declines: returning nil
      -- means no tracker, so nothing is drawn and no timer is started. The anchor
      -- is the thing under test here, so capturing it is enough.
      progress = function(fields)
        record.progress = fields
        return nil
      end,
    }

    return record
  end

  --- Run to completion and hand back everything observed.
  local function run(options)
    local results = {}
    local handle, err = Inline.run({
      buffer = options.buffer,
      range = options.range,
      root = options.root,
      instruction = options.instruction,
      transport = options.transport,
      ui = options.ui.ui,
      config = options.config,
      max_turns = options.max_turns,
      on_done = function(result)
        results[#results + 1] = result
      end,
    })

    t.settle(function()
      return #results > 0 or handle == nil
    end, 800)

    return { handle = handle, error = err, results = results, result = results[1], ui = options.ui }
  end

  local function edit_call(id, path, start_row, end_row, text)
    return Events.tool_use(id, "edit", {
      path = path,
      start_row = start_row,
      end_row = end_row,
      text = text,
    })
  end

  t.describe("inline: preconditions", function()
    t.it("needs a named buffer", function()
      local buffer = vim.api.nvim_create_buf(false, true)
      local _, err = Inline.run({ buffer = buffer, instruction = "do it", transport = fake({}) })
      t.matches(err, "has no file")
    end)

    t.it("needs a selection", function()
      local f = fixture({ "a", "b" })
      vim.api.nvim_buf_set_mark(f.buffer, "<", 0, 0, {})
      vim.api.nvim_buf_set_mark(f.buffer, ">", 0, 0, {})

      local _, err = Inline.run({ buffer = f.buffer, instruction = "do it", transport = fake({}) })
      t.matches(err, "no selection")
    end)

    t.it("needs a model when it has to build its own transport", function()
      local f = fixture({ "a", "b" })
      local _, err = Inline.run({ buffer = f.buffer, root = f.root, instruction = "do it" })
      t.matches(err, "no model configured")
    end)

    t.it("does nothing when the prompt is cancelled", function()
      local f = fixture({ "a", "b" })
      local record = ui({ instruction = nil })

      local outcome = run({
        buffer = f.buffer,
        root = f.root,
        transport = fake({}),
        ui = record,
      })

      t.eq(record.prompts, 1, "the prompt was shown and answered with nil")
      t.eq(#outcome.results, 0, "no request was made")
      t.ok(outcome.handle, "a session is still returned, it is just idle")
      t.eq(buffer_lines(f), { "a", "b" })
    end)

    t.it("treats whitespace as an empty instruction", function()
      local f = fixture({ "a", "b" })
      local _, err = Inline.run({
        buffer = f.buffer,
        root = f.root,
        instruction = "   ",
        transport = fake({}),
      })
      t.eq(err, "cancelled")
    end)
  end)

  t.describe("inline: the prompt", function()
    t.it("asks the UI when no instruction was given", function()
      local f = fixture({ "a", "b" })
      local record = ui({ instruction = "rename it" })
      f.transport = fake({})

      -- Instruction omitted, so ui.prompt is consulted.
      Inline.run({
        buffer = f.buffer,
        root = f.root,
        transport = f.transport,
        ui = record.ui,
      })

      t.eq(record.prompts, 1)
    end)

    t.it("does not ask when an instruction was given", function()
      local f = fixture({ "a", "b" })
      local record = ui({ instruction = "unused" })

      Inline.run({
        buffer = f.buffer,
        root = f.root,
        instruction = "rename it",
        transport = fake({}),
        ui = record.ui,
      })

      t.eq(record.prompts, 0)
    end)
  end)

  t.describe("inline: the message", function()
    t.it("tells the model the file, the range and the instruction", function()
      local f = fixture({ "one", "two", "three" }, 2, 3)
      local transport = fake({})
      local record = ui({ instruction = "unused" })

      local outcome = run({
        buffer = f.buffer,
        root = f.root,
        instruction = "swap them",
        transport = transport,
        ui = record,
      })
      t.ok(outcome.result)

      local sent = transport.requests[1]
      local message = sent.messages[1].content
      t.matches(message, "File: file%d+%.lua")
      t.matches(message, "Selected lines 2%-3")
      t.matches(message, "2| two")
      t.matches(message, "3| three")
      t.matches(message, "Instruction: swap them")
    end)

    t.it("sends the system prompt that states the bound", function()
      local f = fixture({ "a" })
      local transport = fake({})
      run({ buffer = f.buffer, root = f.root, instruction = "x", transport = transport, ui = ui() })

      t.matches(transport.requests[1].system, "only place you may write")
    end)

    t.it("identifies the conversation as inline", function()
      local f = fixture({ "a" })
      local transport = fake({})
      run({ buffer = f.buffer, root = f.root, instruction = "x", transport = transport, ui = ui() })

      local session = transport.requests[1].session
      t.ok(session, "a session id should be set for cache routing")
      t.not_ok(session == require("agent-smith.session").id({ root = f.root, mode = "vibe" }))
    end)
  end)

  t.describe("inline: editing", function()
    t.it("applies an edit inside the selection", function()
      local f = fixture({ "a", "b", "c" }, 2, 2)
      local transport = fake({
        { edit_call("call_1", f.path, 2, 2, "B"), Events.done("tool_calls") },
        { Events.text_delta("done"), Events.done("complete") },
      })

      local outcome = run({
        buffer = f.buffer,
        root = f.root,
        instruction = "capitalise",
        transport = transport,
        ui = ui(),
      })

      t.eq(outcome.result.ok, true)
      t.eq(buffer_lines(f), { "a", "B", "c" })
      t.eq(vim.fn.readfile(f.path), { "a", "b", "c" }, "nothing is written to disk")
    end)

    t.it("escalates an edit outside the selection and asks", function()
      local f = fixture({ "a", "b", "c", "d" }, 2, 2)
      local record = ui({ approve = false })
      local transport = fake({
        { edit_call("call_1", f.path, 4, 4, "D"), Events.done("tool_calls") },
        { Events.done("complete") },
      })

      local outcome = run({
        buffer = f.buffer,
        root = f.root,
        instruction = "change line 4",
        transport = transport,
        ui = record,
      })

      t.eq(#record.approvals, 1)
      t.matches(record.approvals[1].reason, "outside the selected range")
      t.eq(buffer_lines(f), { "a", "b", "c", "d" }, "a denied edit changes nothing")
      t.ok(outcome.result)
    end)

    t.it("applies the escalated edit when approved", function()
      local f = fixture({ "a", "b", "c", "d" }, 2, 2)
      local record = ui({ approve = true })
      local transport = fake({
        { edit_call("call_1", f.path, 4, 4, "D"), Events.done("tool_calls") },
        { Events.done("complete") },
      })

      run({
        buffer = f.buffer,
        root = f.root,
        instruction = "change line 4",
        transport = transport,
        ui = record,
      })

      t.eq(buffer_lines(f), { "a", "b", "c", "D" })
    end)

    t.it("escalates an edit to another file", function()
      local f = fixture({ "a" }, 1, 1)
      local other = vim.fs.joinpath(f.root, "other.lua")
      vim.fn.writefile({ "z" }, other)

      local record = ui({ approve = false })
      local transport = fake({
        { edit_call("call_1", other, 1, 1, "Z"), Events.done("tool_calls") },
        { Events.done("complete") },
      })

      run({
        buffer = f.buffer,
        root = f.root,
        instruction = "touch the other file",
        transport = transport,
        ui = record,
      })

      t.eq(#record.approvals, 1)
      t.matches(record.approvals[1].reason, "different file")
      t.eq(vim.fn.readfile(other), { "z" })
    end)

    t.it("reports the usage summary when it finishes", function()
      local f = fixture({ "a" }, 1, 1)
      local record = ui()
      local transport = fake({
        {
          Events.usage({ input_tokens = 10, cache_read_tokens = 90 }),
          Events.done("complete"),
        },
      })

      run({ buffer = f.buffer, root = f.root, instruction = "x", transport = transport, ui = record })

      t.ok(#record.notifications > 0, "the user should be told something")
      t.matches(record.notifications[#record.notifications], "90%% cache hit")
    end)

    t.it("says why when the run stopped badly", function()
      -- A failure that reports only its token usage tells the user nothing
      -- about what went wrong, which is exactly what a stall produces.
      local f = fixture({ "a" }, 1, 1)
      local record = ui()
      local transport = fake({
        {
          Events.usage({ input_tokens = 10 }),
          Events.error("the vendor fell over"),
        },
      })

      run({ buffer = f.buffer, root = f.root, instruction = "x", transport = transport, ui = record })

      local message = record.notifications[#record.notifications]
      t.matches(message, "10 in")
      t.matches(message, "the vendor fell over")
    end)

    t.it("passes max_turns through", function()
      local f = fixture({ "a" }, 1, 1)
      local transport = fake({
        { edit_call("c1", f.path, 1, 1, "A"), Events.done("tool_calls") },
        { edit_call("c2", f.path, 1, 1, "B"), Events.done("tool_calls") },
        { edit_call("c3", f.path, 1, 1, "C"), Events.done("tool_calls") },
      })

      local outcome = run({
        buffer = f.buffer,
        root = f.root,
        instruction = "loop",
        transport = transport,
        ui = ui(),
        max_turns = 2,
      })

      t.eq(outcome.result.reason, "max_turns")
      t.eq(transport.calls, 2)
    end)
  end)

  t.describe("inline: status position", function()
    --- A four-line file with lines 2-3 selected, so "above the first" and "below
    --- the last" are different anchors and the choice is observable.
    local function positioned(position)
      local f = fixture({ "one", "two", "three", "four" }, 2, 3)
      local record = ui()
      run({
        buffer = f.buffer,
        root = f.root,
        instruction = "do it",
        transport = fake({}),
        ui = record,
        config = position and { progress = { position = position } } or nil,
      })
      return record
    end

    t.it("draws above the selection's first line by default", function()
      local record = positioned(nil)
      t.eq(record.progress.row, 1, "selected line 2 is index 1")
      t.eq(record.progress.above, true)
    end)

    t.it("draws below the selection's last line when asked", function()
      local record = positioned("below")
      t.eq(record.progress.row, 2, "selected line 3 is index 2")
      t.eq(record.progress.above, false)
    end)

    t.it("accepts above explicitly", function()
      local record = positioned("above")
      t.eq(record.progress.row, 1)
      t.eq(record.progress.above, true)
    end)

    t.it("rejects an unknown position before prompting", function()
      local f = fixture({ "one", "two" }, 1, 1)
      local record = ui()
      local outcome = run({
        buffer = f.buffer,
        root = f.root,
        instruction = "do it",
        transport = fake({}),
        ui = record,
        config = { progress = { position = "middle" } },
      })

      t.eq(outcome.handle, nil)
      t.matches(outcome.error, "progress%.position")
      t.eq(record.progress, nil, "nothing should have been drawn")
      t.eq(record.prompts, 0, "the prompt should not have been reached")
    end)
  end)

  t.describe("inline: helpers", function()
    t.it("reads the selection in either direction", function()
      local f = fixture({ "a", "b", "c" })
      vim.api.nvim_buf_set_mark(f.buffer, "<", 3, 0, {})
      vim.api.nvim_buf_set_mark(f.buffer, ">", 1, 0, {})

      t.eq(Inline.selection_range(f.buffer), { start_row = 1, end_row = 3 })
    end)

    t.it("has no selection without marks", function()
      local buffer = vim.api.nvim_create_buf(false, true)
      t.eq(Inline.selection_range(buffer), nil)
    end)

    t.it("finds the project root from a git directory", function()
      local root = vim.fn.tempname()
      vim.fn.mkdir(vim.fs.joinpath(root, ".git"), "p")
      vim.fn.mkdir(vim.fs.joinpath(root, "src"), "p")
      local file = vim.fs.joinpath(root, "src", "a.lua")
      vim.fn.writefile({ "x" }, file)

      t.eq(Inline.project_root(file), root)
    end)
  end)
end
