return function(t)
  local Monitor = require("agent-smith.ui.monitor")
  local Events = require("agent-smith.agent.events")

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

  t.describe("monitor: the window", function()
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
      t.eq(vim.fn.hlexists("AgentSmithMonitorTool"), 1)
      discard(monitor)
    end)

    t.it("toggles from the monitor window and back", function()
      local monitor = fresh()

      monitor:toggle()
      t.eq(vim.api.nvim_get_current_win(), monitor.window)

      monitor:toggle()
      t.eq(monitor:has_window(), false)

      monitor:toggle()
      t.eq(monitor:has_window(), true)
      monitor:close()
      discard(monitor)
    end)

    t.it("hands out one monitor per session", function()
      Monitor.reset()
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
