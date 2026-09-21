return function(t)
  local Panel = require("agent-smith.ui.panel")
  local Events = require("agent-smith.agent.events")

  --- A scratch buffer that looks like a file the user is editing.
  local function scratch(name)
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "line one", "line two", "line three" })
    vim.api.nvim_buf_set_name(buffer, name or "scratch.lua")
    return buffer
  end

  local function lines_of(panel)
    return vim.api.nvim_buf_get_lines(panel.buffer, 0, -1, false)
  end

  local function config_of(panel)
    return vim.api.nvim_win_get_config(panel.window)
  end

  t.describe("panel.geometry", function()
    t.it("places the panel in each corner, inside a margin", function()
      -- Margins are not cosmetic: a float's border is drawn outside its content
      -- box, so a panel at row 0 has its top border off-screen, and one at the
      -- bottom is drawn over the command line unless the margin clears it.
      local size = { columns = 100, lines = 30, width = 40, height = 2 }
      local function at(corner)
        return Panel.geometry(corner, size.columns, size.lines, size.width, size.height)
      end

      t.eq(at("bottom-right").row, 24)
      t.eq(at("bottom-right").col, 58)
      t.eq(at("top-right").row, 1)
      t.eq(at("top-right").col, 58)
      t.eq(at("bottom-left").row, 24)
      t.eq(at("bottom-left").col, 1)
      t.eq(at("top-left").row, 1)
      t.eq(at("top-left").col, 1)
    end)

    t.it("keeps a bottom panel clear of the command line", function()
      -- `relative = "editor"` counts the command line and the status line, so a
      -- panel against the bottom edge covers them rather than sitting above them.
      local lines, height = 30, 2
      local geometry = Panel.geometry("bottom-right", 100, lines, 40, height)

      -- 0-indexed, and the panel's last row is its bottom border.
      local bottom_border = geometry.row + height
      t.ok(
        bottom_border < lines - vim.o.cmdheight,
        ("bottom border at %d must be above the command line at %d"):format(
          bottom_border,
          lines - vim.o.cmdheight
        )
      )
      t.ok(bottom_border <= lines - Panel.BOTTOM_MARGIN, "and clear by the whole margin")
    end)

    t.it("takes an explicit bottom margin, so a taller command line can ask", function()
      t.eq(Panel.geometry("bottom-right", 100, 30, 40, 2, 5).row, 22)
      t.eq(Panel.geometry("top-right", 100, 30, 40, 2, 5).row, 1, "the top ignores it")
    end)

    t.it("never places the panel off the top or left", function()
      -- A tiny editor must not produce a negative row or column.
      local geometry = Panel.geometry("bottom-right", 10, 3, 40, 2)
      t.ok(geometry.row >= 0, "row was " .. geometry.row)
      t.ok(geometry.col >= 0, "col was " .. geometry.col)
    end)

    t.it("follows a resized editor to the new corner", function()
      local before = Panel.geometry("bottom-right", 100, 30, 40, 2)
      local after = Panel.geometry("bottom-right", 120, 40, 40, 2)
      t.ok(after.row > before.row, "the panel should move down with the screen")
      t.ok(after.col > before.col, "and right")
    end)
  end)

  t.describe("panel: the window", function()
    t.it("opens a float in the corner with a title", function()
      local panel = Panel.new({ interval = 0, linger = 0, width = 40 })
      local config = config_of(panel)

      t.eq(config.relative, "editor")
      t.eq(config.width, 40)
      t.eq(config.border[1], "╭")
      t.matches(config.title[1][1], "agent%-smith")

      panel:clear()
    end)

    t.it("does not take focus", function()
      -- A status display that moves the cursor is worse than no status display.
      local before = vim.api.nvim_get_current_win()
      local panel = Panel.new({ interval = 0, linger = 0 })

      t.eq(vim.api.nvim_get_current_win(), before)
      t.eq(config_of(panel).focusable, false)
      t.eq(vim.api.nvim_get_current_win(), before, "opening must not enter the window")

      panel:clear()
    end)

    t.it("sits inside the editor bounds", function()
      local panel = Panel.new({ interval = 0, linger = 0, width = 40 })
      local config = config_of(panel)

      t.ok(config.row + config.height < vim.o.lines, "the panel should not run off the bottom")
      t.ok(config.col + config.width < vim.o.columns, "nor off the right")

      panel:clear()
    end)

    t.it("refuses a corner it does not know", function()
      t.raises(function()
        Panel.new({ corner = "middle" })
      end, "corner must be one of")
    end)

    t.it("accepts every corner it documents", function()
      for corner in pairs(Panel.CORNERS) do
        local panel = Panel.new({ corner = corner, interval = 0, linger = 0 })
        t.eq(config_of(panel).relative, "editor")
        panel:clear()
      end
    end)
  end)

  t.describe("panel: content", function()
    t.it("says it is working before anything has happened", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      t.matches(lines_of(panel)[1], "working")
      panel:clear()
    end)

    t.it("describes a tool call the same way inline does", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      panel:event(Events.tool_use("c", "edit", { path = "/a/greet.lua", start_row = 7 }))
      t.matches(lines_of(panel)[1], "editing greet%.lua:7")
      panel:clear()
    end)

    t.it("adds a usage line as events arrive", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      panel:event(Events.usage({ input_tokens = 812, cache_read_tokens = 48000 }))
      panel:event(Events.usage({ output_tokens = 42 }))

      local lines = lines_of(panel)
      t.eq(#lines, 2)
      t.matches(lines[2], "812 in")
      t.matches(lines[2], "98%% cache hit")
      panel:clear()
    end)

    t.it("grows for a wide line but never shrinks", function()
      -- Shrinking would make the panel twitch as the action text changes.
      local panel = Panel.new({ interval = 0, linger = 0, width = 24 })
      t.eq(config_of(panel).width, 24)

      panel:event(Events.tool_use("c", "bash", { command = string.rep("x", 60) }))
      local wide = config_of(panel).width
      t.ok(wide > 24, "expected growth, got " .. wide)

      panel:action_for("editing a.lua:1")
      t.eq(config_of(panel).width, wide, "a shorter line must not shrink the panel")

      panel:clear()
    end)

    t.it("draws no frame once finished", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      panel:finish({ ok = true, summary = "100 in, 20 out" })

      -- finish() with a zero linger closes, so the content is gone; what matters
      -- is that the panel did not keep spinning.
      t.eq(panel.closed, true)
    end)
  end)

  t.describe("panel: persistence", function()
    t.it("survives a buffer change, which virtual lines would not", function()
      -- The reason this surface exists: a vibe run edits a clone, and the user is
      -- free to move around while it works.
      local first = scratch("first.lua")
      local second = scratch("second.lua")
      vim.api.nvim_set_current_buf(first)

      local panel = Panel.new({ interval = 0, linger = 0 })
      panel:event(Events.tool_use("c", "read", { path = "/a/greet.lua" }))

      vim.api.nvim_set_current_buf(second)

      t.eq(vim.api.nvim_win_is_valid(panel.window), true, "the panel should still be on screen")
      t.matches(lines_of(panel)[1], "reading greet%.lua")

      panel:clear()
    end)

    t.it("leaves the buffer the user is in untouched", function()
      local buffer = scratch("mine.lua")
      vim.api.nvim_set_current_buf(buffer)
      local before = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)

      local panel = Panel.new({ interval = 0, linger = 0 })
      panel:event(Events.tool_use("c", "bash", { command = "make test" }))

      t.eq(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), before)
      t.eq(vim.bo[buffer].modified, false)
      t.not_ok(buffer == panel.buffer, "the panel owns its own buffer")

      panel:clear()
    end)

    t.it("reopens if the window was taken away", function()
      -- Closing a tabpage takes its floats with it; the run continues either way.
      local panel = Panel.new({ interval = 0, linger = 0 })
      local original = panel.window

      vim.api.nvim_win_close(original, true)
      t.eq(vim.api.nvim_win_is_valid(panel.window), false)

      panel:action_for("editing a.lua:1")
      t.ok(vim.api.nvim_win_is_valid(panel.window), "the panel should come back")

      panel:clear()
    end)
  end)

  t.describe("panel: the spinner", function()
    t.it("starts and stops a timer", function()
      local panel = Panel.new({ interval = 20, linger = 0 })
      panel:start()
      t.ok(panel.timer, "a timer should be running")

      panel:stop()
      t.eq(panel.timer, nil)
      panel:clear()
    end)

    t.it("advances the frame without moving the window", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      local config = config_of(panel)

      local first = lines_of(panel)[1]
      panel.frame = 3
      panel:draw()

      t.not_ok(lines_of(panel)[1] == first, "the frame should have changed")
      t.eq(config_of(panel).row, config.row, "the position must not drift")
      t.eq(config_of(panel).col, config.col)

      panel:clear()
    end)
  end)

  t.describe("panel: closing", function()
    t.it("closes immediately when the linger is zero", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      local window, buffer = panel.window, panel.buffer

      panel:finish({ ok = true })

      t.eq(panel.closed, true)
      t.eq(vim.api.nvim_win_is_valid(window), false)
      t.eq(vim.api.nvim_buf_is_valid(buffer), false)
    end)

    t.it("lingers to show the outcome, then closes", function()
      local panel = Panel.new({ interval = 0, linger = 40 })
      local window = panel.window

      panel:finish({ ok = true, summary = "100 in, 20 out" })
      t.eq(vim.api.nvim_win_is_valid(window), true, "it should stay for the linger")
      t.eq(lines_of(panel)[1], "done")
      t.matches(lines_of(panel)[2], "100 in")

      t.settle(function()
        return panel.closed
      end, 500)
      t.eq(vim.api.nvim_win_is_valid(window), false)
    end)

    t.it("says stopped when the run did not succeed", function()
      local panel = Panel.new({ interval = 0, linger = 40 })
      panel:finish({ ok = false, summary = "1 turn(s)" })
      t.eq(lines_of(panel)[1], "stopped")
      panel:clear()
    end)

    t.it("clears on request", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      local window, buffer = panel.window, panel.buffer

      panel:clear()

      t.eq(vim.api.nvim_win_is_valid(window), false)
      t.eq(vim.api.nvim_buf_is_valid(buffer), false)
    end)

    t.it("survives being cleared twice", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      panel:clear()
      t.eq(pcall(function()
        panel:clear()
        panel:draw()
        panel:action_for("nothing")
      end), true)
    end)

    t.it("survives the panel buffer being deleted underneath it", function()
      local panel = Panel.new({ interval = 0, linger = 0 })
      vim.api.nvim_buf_delete(panel.buffer, { force = true })

      t.eq(pcall(function()
        panel:action_for("editing a.lua:1")
        panel:clear()
      end), true)
    end)
  end)
end
