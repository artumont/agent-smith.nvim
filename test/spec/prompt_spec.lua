return function(t)
  local Prompt = require("agent-smith.ui.prompt")

  --- Open a prompt and record what it submits.
  local function open()
    local record = { calls = 0 }
    local handle = Prompt.ask({
      prompt = " test ",
      on_submit = function(text)
        record.calls = record.calls + 1
        record.text = text
      end,
    })
    return handle, record
  end

  --- on_submit is deferred through vim.schedule, so the answer is not readable
  --- until the loop has run once.
  local function settled(record)
    t.settle(function()
      return record.calls > 0
    end, 500)
    return record
  end

  local function border(handle)
    local config = vim.api.nvim_win_get_config(handle.window)
    return config, config.footer or nil
  end

  --- The hint is a list of { text, highlight } chunks, which is the shape a
  --- floating window's border accepts. Flattened for assertions about wording.
  local function text_of(hint)
    local parts = {}
    for _, chunk in ipairs(hint or {}) do
      parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts)
  end

  t.describe("prompt.hint", function()
    t.it("names both keys", function()
      local text = text_of(Prompt.hint("n"))
      t.matches(text, ":w")
      t.matches(text, "q")
    end)

    t.it("returns one hint whatever the mode", function()
      -- Static by choice: a single border line rather than one per mode.
      t.eq(Prompt.hint("i"), Prompt.HINT_NORMAL)
      t.eq(Prompt.hint("v"), Prompt.HINT_NORMAL)
      t.eq(Prompt.hint(nil), Prompt.HINT_NORMAL)
    end)

    t.it("styles every chunk, so the border follows the theme", function()
      for _, chunk in ipairs(Prompt.HINT_NORMAL) do
        t.eq(type(chunk[1]), "string")
        t.eq(type(chunk[2]), "string")
      end
    end)
  end)

  t.describe("prompt: the window", function()
    t.it("opens a float with a title and the hint on the bottom border", function()
      local handle = open()
      local config, footer = border(handle)

      t.eq(config.relative, "editor")
      t.eq(config.footer_pos, "center")
      t.ok(footer, "the footer should be set")

      local text = text_of(footer)
      t.matches(text, ":w")
      t.matches(text, "q")

      handle.cancel()
    end)

    t.it("keeps the hint stable as the mode changes", function()
      local handle = open()
      local before = text_of(select(2, border(handle)))

      vim.api.nvim_exec_autocmds("InsertLeave", { buffer = handle.buffer })
      t.eq(text_of(select(2, border(handle))), before)

      vim.api.nvim_exec_autocmds("InsertEnter", { buffer = handle.buffer })
      t.eq(text_of(select(2, border(handle))), before)

      t.eq(before, text_of(Prompt.HINT_NORMAL))
      handle.cancel()
    end)

    t.it("keeps the given title", function()
      local handle = open()
      local config = vim.api.nvim_win_get_config(handle.window)
      t.matches(config.title[1][1], "test")
      handle.cancel()
    end)
  end)

  t.describe("prompt: closing", function()
    t.it("closes on q from normal mode", function()
      local handle, record = open()
      vim.api.nvim_feedkeys("q", "x", false)
      settled(record)

      t.eq(record.calls, 1)
      t.eq(record.text, nil, "q closes rather than submitting")
      t.eq(vim.api.nvim_win_is_valid(handle.window), false)
      t.eq(vim.api.nvim_buf_is_valid(handle.buffer), false)
    end)

    t.it("still closes on :q", function()
      local handle, record = open()
      -- Guarded: `:q` on a window that is somehow the last one would take the
      -- whole test run with it.
      pcall(vim.api.nvim_win_call, handle.window, function()
        vim.cmd("q")
      end)
      settled(record)

      t.eq(record.calls, 1)
      t.eq(record.text, nil)
    end)

    t.it("cancels through the handle", function()
      local handle, record = open()
      handle.cancel()
      settled(record)

      t.eq(record.calls, 1)
      t.eq(record.text, nil)
      t.eq(vim.api.nvim_win_is_valid(handle.window), false)
    end)

    t.it("submits what was typed on :w", function()
      local handle, record = open()
      vim.api.nvim_buf_set_lines(handle.buffer, 0, -1, false, { "add a comma", "to the greeting" })
      vim.cmd("write")
      settled(record)

      t.eq(record.calls, 1)
      t.eq(record.text, "add a comma\nto the greeting")
    end)

    t.it("treats an empty :w as a cancel", function()
      local _, record = open()
      vim.cmd("write")
      settled(record)

      t.eq(record.calls, 1)
      t.eq(record.text, nil)
    end)

    t.it("never answers twice", function()
      local handle, record = open()
      vim.api.nvim_buf_set_lines(handle.buffer, 0, -1, false, { "hi" })
      vim.cmd("write")
      handle.cancel()
      settled(record)

      t.eq(record.calls, 1)
    end)

    t.it("does not submit from insert mode, where q is a letter", function()
      local handle, record = open()
      -- Forcing the mode is not possible headlessly, so this asserts the mapping
      -- is normal-mode only by checking that insert mode has no other q mapping
      -- and that the normal-mode one is the only one registered.
      local maps = vim.api.nvim_buf_get_keymap(handle.buffer, "i")
      for _, map in ipairs(maps) do
        t.ok(map.lhs ~= "q", "q must not be mapped in insert mode")
      end

      local normal = {}
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(handle.buffer, "n")) do
        normal[map.lhs] = map
      end
      t.ok(normal["q"], "q should be mapped in normal mode")

      handle.cancel()
      settled(record)
    end)
  end)
end
