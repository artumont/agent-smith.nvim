return function(t)
  local Progress = require("agent-smith.ui.progress")
  local Events = require("agent-smith.agent.events")

  --- A buffer to draw on, so extmarks have somewhere to live.
  local function scratch()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "line one", "line two", "line three" })
    return buffer
  end

  --- The extmarks progress is drawing with.
  local function marks(buffer)
    return vim.api.nvim_buf_get_extmarks(buffer, Progress.NAMESPACE, 0, -1, { details = true })
  end

  --- The virt_lines currently drawn, as plain strings.
  local function drawn(buffer)
    local found = marks(buffer)
    if #found == 0 then
      return nil
    end

    local lines = {}
    for _, virt_line in ipairs(found[1][4].virt_lines or {}) do
      lines[#lines + 1] = virt_line[1][1]
    end
    return lines
  end

  t.describe("progress.render", function()
    t.it("draws a frame and an action", function()
      local lines = Progress.render({ frame = 1, action = "reading a.lua" })
      t.eq(#lines, 1)
      t.matches(lines[1], "reading a%.lua")
      t.matches(lines[1], Progress.FRAMES[1])
    end)

    t.it("adds a second line for usage", function()
      local lines = Progress.render({ frame = 1, action = "editing a.lua", summary = "812 in, 42 out" })
      t.eq(#lines, 2)
      t.eq(lines[2], "812 in, 42 out")
    end)

    t.it("stays one line when there is no usage to report", function()
      -- A short run should not cost two lines for nothing.
      t.eq(#Progress.render({ frame = 1, action = "x", summary = nil }), 1)
      t.eq(#Progress.render({ frame = 1, action = "x", summary = "" }), 1)
      t.eq(#Progress.render({ frame = 1, action = "x", summary = "no usage reported" }), 1)
    end)

    t.it("says it is working before anything has happened", function()
      t.matches(Progress.render({ frame = 1 })[1], "working")
    end)

    t.it("draws no frame once finished", function()
      local lines = Progress.render({ frame = nil, action = "done" })
      t.eq(lines[1], "done", "a finished line should not spin")
    end)

    t.it("cycles the frame when given a larger index", function()
      t.eq(Progress.render({ frame = 3, action = "x" })[1]:sub(1, #Progress.FRAMES[3]), Progress.FRAMES[3])
    end)
  end)

  t.describe("progress.describe", function()
    local function action_for(name, arguments)
      return Progress.describe(Events.tool_use("c", name, arguments or {}))
    end

    t.it("names the file for a read", function()
      t.matches(action_for("read", { path = "/a/b/greet.lua" }), "reading greet%.lua")
    end)

    t.it("names the file and line for an edit", function()
      t.matches(action_for("edit", { path = "/a/greet.lua", start_row = 12 }), "editing greet%.lua:12")
    end)

    t.it("describes a search by its pattern", function()
      t.matches(action_for("grep", { pattern = "TODO" }), "searching for TODO")
      t.matches(action_for("glob", { pattern = "**/*.lua" }), "finding")
    end)

    t.it("shows the command for bash", function()
      t.matches(action_for("bash", { command = "ls -la" }), "running ls %-la")
    end)

    t.it("truncates a long command", function()
      local described = action_for("bash", { command = string.rep("x", 200) })
      t.ok(#described < 70, ("should stay short, got %d"):format(#described))
      t.matches(described, "…")
    end)

    t.it("falls back to the tool name", function()
      t.matches(action_for("something_new", {}), "calling something_new")
    end)

    t.it("ignores anything that is not a tool call", function()
      t.eq(Progress.describe(Events.text_delta("hi")), nil)
      t.eq(Progress.describe(nil), nil)
    end)
  end)

  t.describe("progress: drawing", function()
    t.it("draws the status under the anchor line by default", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })

      progress:action_for("editing greet.lua:2")

      local lines = drawn(buffer)
      t.ok(lines, "an extmark should exist")
      t.matches(lines[1], "editing greet%.lua:2")
      t.ok(marks(buffer)[1][4].virt_lines_above ~= true, "the default stays below")
    end)

    t.it("draws above the anchor line when asked", function()
      -- Above, so a status pinned to a selection starting at line 1 has
      -- somewhere to go: there is no line above it to hang from.
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, above = true, interval = 0, linger = 0 })

      progress:action_for("editing greet.lua:1")

      t.eq(marks(buffer)[1][4].virt_lines_above, true)
      t.matches(drawn(buffer)[1], "editing greet%.lua:1")
    end)

    t.it("keeps drawing above as it updates", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, above = true, interval = 0, linger = 0 })

      progress:action_for("reading a.lua")
      progress:action_for("editing b.lua:9")

      t.eq(#marks(buffer), 1, "updates reuse the one extmark")
      t.eq(marks(buffer)[1][4].virt_lines_above, true)
      t.matches(drawn(buffer)[1], "editing b%.lua:9")
    end)

    t.it("does not touch the buffer text", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })
      progress:action_for("editing")

      t.eq(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { "line one", "line two", "line three" })
      t.eq(vim.bo[buffer].modified, false, "virtual lines are not a modification")
    end)

    t.it("adds a usage line as events arrive", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })

      progress:event(Events.usage({ input_tokens = 812, cache_read_tokens = 48000 }))
      progress:event(Events.usage({ output_tokens = 42 }))

      local lines = drawn(buffer)
      t.eq(#lines, 2)
      t.matches(lines[2], "812 in")
      t.matches(lines[2], "48000 cached")
      t.matches(lines[2], "98%% cache hit")
    end)

    t.it("updates the action from a tool call", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })

      progress:event(Events.tool_use("c", "read", { path = "/x/loop.lua" }))
      t.matches(drawn(buffer)[1], "reading loop%.lua")

      progress:event(Events.tool_use("c", "bash", { command = "make test" }))
      t.matches(drawn(buffer)[1], "running make test")
    end)

    t.it("uses one extmark, so the lines cannot accumulate", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })

      for index = 1, 5 do
        progress:action_for("step " .. index)
      end

      t.eq(#vim.api.nvim_buf_get_extmarks(buffer, Progress.NAMESPACE, 0, -1, {}), 1)
      t.matches(drawn(buffer)[1], "step 5")
    end)

    t.it("clears on request", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })
      progress:action_for("editing")
      t.ok(drawn(buffer))

      progress:clear()
      t.eq(drawn(buffer), nil)
    end)

    t.it("survives a buffer that went away", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })
      vim.api.nvim_buf_delete(buffer, { force = true })

      t.eq(pcall(function()
        progress:action_for("editing")
        progress:clear()
      end), true)
    end)
  end)

  t.describe("progress: finishing", function()
    t.it("stops the spinner and shows the outcome", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })
      progress:start()
      progress:finish({ ok = true, summary = "100 in, 20 out" })

      local lines = drawn(buffer)
      t.eq(lines[1], "done")
      t.eq(lines[2], "100 in, 20 out")
      t.eq(progress.timer, nil, "the spinner should be stopped")
    end)

    t.it("says stopped when the run did not succeed", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })
      progress:finish({ ok = false, summary = "1 turn(s)" })

      t.eq(drawn(buffer)[1], "stopped")
    end)

    t.it("falls back to the usage it accumulated", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })
      progress:event(Events.usage({ input_tokens = 5 }))
      progress:finish({ ok = true })

      t.matches(drawn(buffer)[2], "5 in")
    end)

    t.it("clears immediately when the linger is zero", function()
      local buffer = scratch()
      local progress = Progress.new({ buffer = buffer, row = 0, interval = 0, linger = 0 })

      -- linger 0 means no deferred clear is scheduled; the caller clears.
      progress:finish({ ok = true })
      t.ok(drawn(buffer), "the outcome stays until something clears it")
      progress:clear()
      t.eq(drawn(buffer), nil)
    end)
  end)
end
