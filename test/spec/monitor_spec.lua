return function(t)
  local Monitor = require("agent-smith.ui.monitor")
  local Events = require("agent-smith.agent.events")
  local Float = require("agent-smith.ui.float")
  local Prompt = require("agent-smith.ui.prompt")

  --- A monitor on a clock the test drives, so elapsed times are exact.
  local function fresh()
    local state = { epoch = 1712345678, ms = 0 }
    local monitor = Monitor.new({
      clock = function()
        return state.epoch
      end,
      now = function()
        return state.ms
      end,
    })
    return monitor, state
  end

  --- The lines the monitor would draw. Not the buffer: while the window is
  --- closed nothing is drawn, and that is deliberate.
  local function view(monitor)
    return monitor:lines()
  end

  --- What is actually in the buffer right now.
  local function drawn(monitor)
    return vim.api.nvim_buf_get_lines(monitor.buffer, 0, -1, false)
  end

  local function last(monitor)
    local lines = view(monitor)
    return lines[#lines]
  end

  local function discard(monitor)
    vim.api.nvim_buf_delete(monitor.buffer, { force = true })
  end

  local STAMP = os.date("%H:%M:%S", 1712345678)

  t.describe("monitor.duration", function()
    t.it("counts seconds below a minute and minutes above it", function()
      -- The question about a tool call is "is this still going", and 1m42s
      -- answers it where 102000 does not.
      t.eq(Monitor.duration(0), "0s")
      t.eq(Monitor.duration(1500), "1s")
      t.eq(Monitor.duration(59000), "59s")
      t.eq(Monitor.duration(102000), "1m42s")
      t.eq(Monitor.duration(-5), "0s")
    end)
  end)

  t.describe("monitor.oneline", function()
    t.it("collapses whitespace so an entry stays on one row", function()
      t.eq(Monitor.oneline("sh -c\n  'go version'\n\n"), "sh -c 'go version'")
    end)

    t.it("shortens rather than wrapping", function()
      t.eq(Monitor.oneline(string.rep("x", 200), 10), "xxxxxxxxxx…")
    end)
  end)

  t.describe("monitor.header", function()
    t.it("shows the spinner, the action and the usage", function()
      local header = Monitor.header({
        frame = 3,
        action = "running bash",
        summary = "8 in, 3 cached, 27% cache hit",
      })
      t.matches(header, "running bash")
      t.matches(header, "27%% cache hit")
    end)

    t.it("does not spin once the run is over", function()
      local header = Monitor.header({ action = "finished", summary = "1 turn(s)" })
      t.eq(header:find("⠋", 1, true), nil, "no frame, nothing turning")
      t.eq(header, "finished  1 turn(s)")
    end)

    t.it("omits the placeholder usage line", function()
      t.eq(Monitor.header({ action = "idle", summary = "no usage reported" }), "idle")
    end)
  end)

  t.describe("monitor.entry", function()
    t.it("spells a tool call and its detail on two lines", function()
      local entry = Monitor.entry(Events.tool_use("c1", "bash", { command = "go version" }))
      t.eq(entry[1], { kind = "tool", text = "tool    bash" })
      t.eq(entry[2].kind, "dim")
      t.matches(entry[2].text, "go version")
    end)

    t.it("renders usage through the shared accounting", function()
      local entry = Monitor.entry(Events.usage({ input_tokens = 8, cache_read_tokens = 3 }))
      t.eq(entry[1].kind, "usage")
      t.matches(entry[1].text, "3 cached")
      t.matches(entry[1].text, "27%% cache hit")
    end)

    t.it("records errors and done reasons", function()
      t.matches(Monitor.entry(Events.error("the vendor fell over"))[1].text, "the vendor fell over")
      t.matches(Monitor.entry(Events.done("tool_calls"))[1].text, "tool_calls")
    end)

    t.it("shows a type it does not know about rather than dropping it", function()
      local entry = Monitor.entry({ type = "whatever" })
      t.eq(entry[1].kind, "dim")
      t.matches(entry[1].text, "whatever")
    end)
  end)

  t.describe("monitor: recording a run", function()
    t.it("opens with a turn heading and joins streamed text", function()
      local monitor = fresh()
      monitor:event(Events.text_delta("Let me "))
      monitor:event(Events.text_delta("check the toolchain."))

      local lines = view(monitor)
      t.eq(lines[1], Monitor.header({ frame = 1, action = "idle" }), "the header is first")
      t.eq(lines[2], STAMP .. "  turn 1  request sent")
      t.matches(lines[3], "text    Let me check the toolchain%.")
      t.eq(#lines, 3, "header, turn heading, one joined text line — a delta per token would be a line per token")
      discard(monitor)
    end)

    t.it("starts the clock when the tools run, not when they are requested", function()
      -- The tool calls stream before `done`, and the tools run after it. Timing
      -- the request would report a hung command as having returned instantly.
      local monitor, state = fresh()
      monitor:event(Events.tool_use("c1", "bash", { command = "go version; python3 -V" }))
      monitor:event(Events.done("tool_calls"))

      state.ms = 102000
      local header = monitor:header_state()
      t.eq(header.action, "running go version; python3 -V")
      t.eq(Monitor.duration(header.elapsed_ms), "1m42s")

      -- The next turn's first event is proof the command came back.
      monitor:event(Events.text_delta("Both are installed."))
      t.matches(table.concat(view(monitor), "\n"), "returned after 1m42s")
      t.eq(monitor.running, nil)
      discard(monitor)
    end)

    t.it("reports a stall with the loop's own reason", function()
      local monitor, state = fresh()
      monitor:event(Events.tool_use("c1", "bash", { command = "go version" }))
      monitor:event(Events.done("tool_calls"))

      state.ms = 120000
      monitor:done_run({
        ok = false,
        reason = "stalled",
        error = "no activity for 120 s while running bash",
      })

      t.eq(
        last(monitor),
        STAMP .. "  stopped  no activity for 120 s while running bash"
      )
      t.matches(table.concat(view(monitor), "\n"), "returned after 2m00s")
      t.eq(monitor.done, true)
      discard(monitor)
    end)

    t.it("marks a new run rather than joining it to the last one", function()
      local monitor = fresh()
      monitor:event(Events.done("complete"))
      monitor:done_run({ ok = true, reason = "complete" })

      monitor:event(Events.text_delta("second run"))
      local text = table.concat(view(monitor), "\n")
      t.matches(text, "new run")
      t.matches(text, "turn 1  request sent", "turn numbering starts again")
      discard(monitor)
    end)

    t.it("sums usage across a run and renders it in the header", function()
      local monitor = fresh()
      monitor:event(Events.usage({ input_tokens = 8, cache_read_tokens = 3 }))
      monitor:event(Events.usage({ output_tokens = 4 }))

      t.eq(monitor:header_state().summary, "8 in, 3 cached, 4 out, 27% cache hit")
      discard(monitor)
    end)

    t.it("caps the log and says how much it dropped", function()
      local monitor = fresh()
      -- The first entry is the turn heading, so the log holds 2006 records for
      -- 2005 events and drops the six oldest.
      for index = 1, Monitor.MAX_ENTRIES + 5 do
        monitor:event(Events.usage({ input_tokens = index }))
      end

      t.eq(#monitor.entries, Monitor.MAX_ENTRIES)
      t.eq(monitor.dropped, 6)
      t.matches(view(monitor)[2], "6 earlier entries dropped")
      discard(monitor)
    end)

    t.it("forgets everything on clear", function()
      local monitor = fresh()
      monitor:event(Events.usage({ input_tokens = 8 }))
      monitor:event(Events.text_delta("hello"))
      monitor:clear()

      t.eq(monitor.entries, {})
      t.eq(monitor.usage, {})
      t.eq(#view(monitor), 1, "only the header is left")
      discard(monitor)
    end)
  end)

  t.describe("monitor: wired into the modes", function()
    t.it("records through both default UIs", function()
      -- The modes' own UIs feed the monitor, so a run is in the log whether or
      -- not anybody opened it — which is the whole point of reading it after a
      -- run went wrong.
      for _, mode in ipairs({ "agent-smith.modes.inline", "agent-smith.modes.vibe" }) do
        Monitor.reset()
        local ui = require(mode).default_ui()
        ui.event(Events.text_delta("from " .. mode))
        ui.done({ ok = false, reason = "stalled", error = "no activity for 120 s" })

        local monitor = Monitor.get()
        local text = table.concat(monitor:lines(), "\n")
        -- The mode name has punctuation in it, all of it magic in a Lua pattern.
        t.matches(text, "from " .. mode:gsub("(%p)", "%%%1"))
        t.matches(text, "stopped")
        t.matches(text, "no activity for 120 s")

        Monitor.reset()
        discard(monitor)
      end
    end)
  end)

  --- The border hint as text, flattened for assertions about wording.
  local function footer_text(monitor)
    local parts = {}
    for _, chunk in ipairs(vim.api.nvim_win_get_config(monitor.window).footer or {}) do
      parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts)
  end

  t.describe("monitor: steering", function()
    --- A real run, steerable through the public API.
    ---
    --- Not a spy on `Smith.steer`: the point is that the input reaches the model,
    --- so the test drives an actual inline run with a transport that answers when
    --- the test says so, and reads the requests it was sent.
    local function running_run()
      local Smith = require("agent-smith")
      local Inline = require("agent-smith.modes.inline")

      local buffer = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buffer, "/tmp/monitor-steer/a.lua")
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local x = 1" })

      local transport = { requests = {} }
      function transport.run(request, on_event)
        transport.requests[#transport.requests + 1] = request
        transport.emit = on_event
        return { cancel = function() end }
      end

      local handle = Smith.inline({
        buffer = buffer,
        range = { start_row = 1, end_row = 1 },
        root = "/tmp/monitor-steer",
        instruction = "do something",
        transport = transport,
        ui = {
          notify = function() end,
          approve = function()
            return false
          end,
          progress = function()
            return nil
          end,
        },
      })

      return { handle = handle, transport = transport, ui = Inline.default_ui }
    end

    --- Submit whatever is in the steer input, the way `:w` does.
    local function submit(monitor, text)
      vim.api.nvim_buf_set_lines(monitor.steer_handle.buffer, 0, -1, false, { text })
      vim.api.nvim_exec_autocmds("BufWriteCmd", { buffer = monitor.steer_handle.buffer })
      t.settle(function()
        return monitor.steer_handle == nil
      end, 500)
    end

    t.it("says when a steer is being held for execution", function()
      -- A note that reaches the executor and not the planner looks identical to one
      -- that reached nothing, unless the log says which it is.
      local monitor = fresh()
      monitor:steered("use a comma, not a full stop", "notes")

      t.matches(
        table.concat(view(monitor), "\n"),
        "steer   held for execution — use a comma, not a full stop"
      )
      discard(monitor)
    end)

    t.it("docks a bordered input inside the bottom of the float", function()
      local monitor = fresh()
      monitor:open()
      monitor:steer()

      local input = vim.api.nvim_win_get_config(monitor.steer_handle.window)
      local log = vim.api.nvim_win_get_config(monitor.window)
      local expected = Monitor.steer_geometry(log)

      t.eq(input.relative, "editor")
      t.eq({ input.row, input.col, input.width, input.height },
        { expected.row, expected.col, expected.width, expected.height })
      t.eq(input.height, Monitor.STEER_HEIGHT)
      t.eq(input.border[1], "╭", "a real border, not a table of empty strings")
      t.ok(input.zindex > log.zindex, "drawn over the log")
      t.eq(vim.api.nvim_get_current_win(), monitor.steer_handle.window, "ready to type in")

      -- The whole frame — border included — lives inside the monitor's content
      -- box. This is the regression: a top-only border built from empty strings
      -- still reserves its cells, so the input's empty left border sat on the
      -- monitor's own left border column and occluded it.
      t.ok(input.row - 1 >= log.row, "the top border is inside the log's content")
      t.ok(input.col - 1 >= log.col, "so is the left one")
      t.ok(input.row + input.height + 1 <= log.row + log.height - 1, "and the bottom")
      t.ok(input.col + input.width + 1 <= log.col + log.width - 1, "and the right")

      monitor:close()
      discard(monitor)
    end)

    t.it("sends what was typed with :w, and it reaches the conversation", function()
      local run = running_run()
      local monitor = fresh()
      monitor:open()
      monitor:steer()

      submit(monitor, "also check the tests")

      t.matches(table.concat(view(monitor), "\n"), "steer   also check the tests")
      t.eq(vim.api.nvim_win_is_valid(monitor.window), true, "the log stays open")
      t.eq(vim.api.nvim_get_current_win(), monitor.window, "and takes the cursor back")

      -- The model sees it: the run goes on to another turn, whose request ends
      -- with what was typed into the input.
      run.transport.emit(Events.done("complete"))
      local messages = run.transport.requests[#run.transport.requests].messages
      t.eq(messages[#messages].role, "user")
      t.eq(messages[#messages].content, "also check the tests")

      run.transport.emit(Events.done("complete"))
      require("agent-smith").cancel()

      monitor:close()
      discard(monitor)
    end)

    t.it("keeps a refused steer in the log rather than losing it", function()
      -- A refusal looks identical to a model ignoring the user unless it is said
      -- out loud, and the text has to survive so it can be sent again.
      require("agent-smith").cancel()

      local monitor = fresh()
      monitor:open()
      monitor:steer()

      submit(monitor, "too late for this one")

      local text = table.concat(view(monitor), "\n")
      t.matches(text, "not sent, the run is over")
      t.matches(text, "too late for this one")

      monitor:close()
      discard(monitor)
    end)

    t.it("abandons on cancel without sending anything", function()
      local monitor = fresh()
      monitor:open()
      monitor:steer()

      local input = monitor.steer_handle.buffer
      vim.api.nvim_buf_set_lines(input, 0, -1, false, { "never mind" })
      monitor.steer_handle.cancel()

      t.not_ok(table.concat(view(monitor), "\n"):find("never mind", 1, true), "nothing logged")
      t.eq(vim.api.nvim_win_is_valid(monitor.steer_handle.window), false, "the input is closed")

      -- The prompt answers through vim.schedule, so the monitor's own reference is
      -- dropped a tick later. `steer()` tolerates that by checking the window.
      t.settle(function()
        return monitor.steer_handle == nil
      end, 500)
      t.eq(monitor.steer_handle, nil)

      monitor:close()
      discard(monitor)
    end)

    t.it("stays docked when the monitor is redrawn", function()
      -- The log redraws on every event and re-places its own float; the input has
      -- to be moved by the same arithmetic or it drifts off the bottom.
      local monitor = fresh()
      monitor:open()
      monitor:steer()

      monitor:draw()
      local input = vim.api.nvim_win_get_config(monitor.steer_handle.window)
      local expected = Monitor.steer_geometry(vim.api.nvim_win_get_config(monitor.window))
      t.eq(input.row, expected.row)
      t.eq(input.width, expected.width)

      monitor:close()
      discard(monitor)
    end)

    t.it("closes the input along with the monitor", function()
      local monitor = fresh()
      monitor:open()
      monitor:steer()
      local input = monitor.steer_handle.window

      monitor:close()
      t.eq(vim.api.nvim_win_is_valid(input), false)
      t.eq(monitor.steer_handle, nil)
      discard(monitor)
    end)

    t.it("focuses the input instead of opening a second one", function()
      local monitor = fresh()
      monitor:open()
      monitor:steer()
      local first = monitor.steer_handle.window

      vim.api.nvim_set_current_win(monitor.window)
      monitor:steer()

      t.eq(monitor.steer_handle.window, first)
      t.eq(vim.api.nvim_get_current_win(), first)

      monitor:close()
      discard(monitor)
    end)
  end)

  t.describe("monitor.steer_geometry", function()
    t.it("fits a bordered box inside the window it docks in", function()
      -- Given a monitor at row 2, col 3, 80 wide and 20 tall: two columns go to
      -- the input's own border, and the box sits against the bottom of the
      -- content with one row of border above and below it.
      local at = Monitor.steer_geometry({ row = 2, col = 3, width = 80, height = 20 })
      t.eq(at, { row = 18, col = 5, width = 76, height = 2 })

      -- Border included, all four edges are within the monitor's content box:
      -- nothing is asked for that belongs to the monitor's frame.
      local log = { row = 2, col = 3, width = 80, height = 20 }
      t.ok(at.row - 1 >= log.row)
      t.ok(at.col - 1 >= log.col)
      t.ok(at.row + at.height + 1 <= log.row + log.height - 1)
      t.ok(at.col + at.width + 1 <= log.col + log.width - 1)
    end)

    t.it("never docks above the top of a short window", function()
      local at = Monitor.steer_geometry({ row = 0, col = 0, width = 40, height = 3 }, 2)
      t.eq(at.row, 0, "clamped to the window's own first row")
      t.eq(at.height, 2)
    end)

    t.it("never wider than the window it docks in", function()
      -- A box that ignores the arithmetic is drawn through the monitor's frame,
      -- which is worse than a narrow input.
      local at = Monitor.steer_geometry({ row = 0, col = 0, width = 20, height = 10 })
      t.eq(at.width, 16)
      t.ok(at.col - 1 >= 0)
      t.ok(at.col + at.width + 1 <= 19)
    end)
  end)

  t.describe("monitor: the window", function()
    t.it("opens a float like the prompt, with its keys on the border", function()
      -- The shape is shared with ui/prompt.lua on purpose (ui/float.lua): a
      -- centred float carrying its own keys, because a key that only exists in
      -- the help is a key nobody finds.
      local monitor = fresh()
      t.eq(monitor:open(), true)

      local config = vim.api.nvim_win_get_config(monitor.window)
      t.eq(config.relative, "editor")
      t.eq(config.style, "minimal")
      t.eq(config.footer_pos, "center")
      t.eq(config.title_pos, "left")
      t.matches(config.title[1][1], "stream")

      local footer = footer_text(monitor)
      t.matches(footer, " s ")
      t.matches(footer, " q ")
      t.matches(footer, " X ")
      t.matches(footer, "<C%-c>")

      -- Redrawing reconfigures the float (that is how a resize is followed), and
      -- reconfiguring must not drop the title or the hint.
      monitor:draw()
      t.eq(footer_text(monitor), footer, "the hint survives a redraw")
      t.matches(vim.api.nvim_win_get_config(monitor.window).title[1][1], "stream")

      -- Its own size, not the prompt's: a log needs more rows than an instruction.
      local geometry = Float.geometry(vim.o.columns, vim.o.lines, Monitor.WIDTH, Monitor.HEIGHT)
      t.eq(config.width, geometry.width)
      t.eq(config.height, geometry.height)
      t.ok(config.width > Prompt.WIDTH, "wider than the prompt window")
      t.ok(config.height > Prompt.HEIGHT, "and taller")
      -- Neovim resolves a named border into its characters; the corner is enough
      -- to say it is a bordered box.
      t.eq(config.border[1], "╭")

      -- Inside the editor, border included.
      t.ok(config.row + config.height + 1 <= vim.o.lines, "the bottom border fits")
      t.ok(config.col + config.width + 1 <= vim.o.columns, "and the right one")

      monitor:close()
      discard(monitor)
    end)

    t.it("records while closed and flushes when opened", function()
      -- The point of the whole thing: it is read after a run went wrong, so it
      -- has to hold that run whether or not anybody was watching.
      local monitor = fresh()
      monitor:event(Events.text_delta("recorded while closed"))

      t.eq(monitor:has_window(), false)
      t.eq(table.concat(drawn(monitor), "\n"):find("recorded", 1, true), nil, "nothing drawn yet")
      t.matches(table.concat(view(monitor), "\n"), "recorded while closed")

      t.eq(monitor:open(), true)
      t.eq(monitor:has_window(), true)
      t.matches(table.concat(drawn(monitor), "\n"), "recorded while closed")
      t.eq(vim.api.nvim_buf_get_name(monitor.buffer), Monitor.BUFFER_NAME)
      t.eq(vim.bo[monitor.buffer].buftype, "nofile")

      monitor:close()
      t.eq(monitor:has_window(), false)
      t.eq(vim.api.nvim_buf_is_valid(monitor.buffer), true, "closing keeps the log")

      -- The buffer-local keys are bound where they are useful.
      local keys = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(monitor.buffer, "n")) do
        keys[map.lhs] = true
      end
      t.ok(keys.q, "q closes the monitor")
      t.ok(keys.X, "X cancels the run")
      t.ok(keys.s, "s opens the steer input")
      t.eq(vim.fn.hlexists("AgentSmithMonitorTool"), 1)
      discard(monitor)
    end)

    t.it("toggles from the monitor window and back", function()
      local monitor = fresh()

      monitor:toggle()
      t.eq(vim.api.nvim_get_current_win(), monitor.window, "an entered float, so the log scrolls")
      t.eq(vim.api.nvim_win_get_config(monitor.window).relative, "editor")

      monitor:toggle()
      t.eq(monitor:has_window(), false)

      monitor:toggle()
      t.eq(monitor:has_window(), true)
      monitor:close()
      discard(monitor)
    end)

    t.it("does not rewrite a log that has not changed", function()
      -- The spinner calls draw() eleven times a second. Rewriting every line,
      -- re-applying a highlight per entry and reconfiguring both windows each time
      -- measured 3.9 ms per tick at 2000 entries, almost all of it redrawing
      -- identical text; a tick now writes at most one line.
      local monitor = fresh()
      for index = 1, 50 do
        monitor:event(Events.usage({ input_tokens = index }))
      end
      monitor:open()
      monitor:draw()

      local after_first = vim.api.nvim_buf_get_changedtick(monitor.buffer)
      for _ = 1, 5 do
        monitor:draw()
      end
      t.eq(vim.api.nvim_buf_get_changedtick(monitor.buffer), after_first, "nothing to redraw")

      -- An entry does change it, and only then.
      monitor:event(Events.usage({ input_tokens = 1 }))
      t.ok(vim.api.nvim_buf_get_changedtick(monitor.buffer) > after_first)

      discard(monitor)
    end)

    t.it("hands out one monitor per session", function()      Monitor.reset()
      local first = Monitor.get()
      t.eq(Monitor.get(), first, "the same object, so the log is not duplicated")

      Monitor.reset()
      local second = Monitor.get()
      t.not_ok(second == first)
      t.eq(vim.api.nvim_buf_is_valid(first.buffer), true, "the old buffer is left alone")

      Monitor.reset()
      discard(first)
      discard(second)
    end)
  end)
end
