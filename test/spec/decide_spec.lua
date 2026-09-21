return function(t)
  local Decide = require("agent-smith.ui.decide")

  --- What a decision came out as, or nil while it has not answered.
  local function ask(fields)
    local record = { calls = 0 }
    record.handle = Decide.ask({
      title = fields.title,
      lines = fields.lines or { "one", "two", "three" },
      filetype = fields.filetype,
      decorate = fields.decorate,
      max_height = fields.max_height,
      on_decision = function(accepted)
        record.calls = record.calls + 1
        record.accepted = accepted
      end,
    })
    return record
  end

  --- on_decision is deferred through vim.schedule.
  local function settled(record)
    t.settle(function()
      return record.calls > 0
    end, 500)
    return record
  end

  --- The footer is a list of { text, highlight } chunks, which is the shape a
  --- border accepts; the whole list is one line.
  local function footer(handle)
    local config = vim.api.nvim_win_get_config(handle.window)
    local parts = {}
    for _, chunk in ipairs(config.footer) do
      parts[#parts + 1] = chunk[1]
    end
    return table.concat(parts)
  end

  local function press(handle, key)
    vim.api.nvim_set_current_win(handle.window)
    vim.api.nvim_feedkeys(key, "x", false)
  end

  t.describe("decide.size", function()
    t.it("fits the body, within a minimum and a maximum", function()
      t.eq(Decide.size({ "short" }, 200, 60, 24).width, Decide.MIN_WIDTH)
      t.ok(Decide.size({ string.rep("x", 90) }, 200, 60, 24).width <= Decide.MAX_WIDTH)
    end)

    t.it("caps the height so a long body scrolls instead of overgrowing", function()
      local lines = {}
      for index = 1, 200 do
        lines[index] = "line " .. index
      end
      t.eq(Decide.size(lines, 200, 60, 10).height, 10)
    end)

    t.it("never asks for more room than the editor has", function()
      local size = Decide.size({ string.rep("x", 200) }, 40, 10)
      t.ok(size.width <= 40, "width was " .. size.width)
      t.ok(size.height <= 10, "height was " .. size.height)
    end)
  end)

  t.describe("decide.geometry", function()
    t.it("centres the window", function()
      local geometry = Decide.geometry(100, 30, 40, 10)
      t.eq(geometry.col, 30)
      t.eq(geometry.row, 9)
    end)

    t.it("stays on screen in a tiny editor", function()
      local geometry = Decide.geometry(20, 5, 40, 10)
      t.ok(geometry.row >= 0)
      t.ok(geometry.col >= 0)
    end)
  end)

  t.describe("decide.buffer", function()
    t.it("holds the body and is not editable", function()
      local buffer = Decide.buffer({ lines = { "a", "b" }, filetype = "diff" })
      t.eq(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), { "a", "b" })
      t.eq(vim.bo[buffer].modifiable, false)
      t.eq(vim.bo[buffer].filetype, "diff")
      t.eq(vim.bo[buffer].buftype, "nofile")
      vim.api.nvim_buf_delete(buffer, { force = true })
    end)
  end)

  t.describe("decide: the window", function()
    t.it("opens a float with the title and a footer naming both keys", function()
      local record = ask({ title = " agent-smith plan " })
      local config = vim.api.nvim_win_get_config(record.handle.window)

      t.eq(config.relative, "editor")
      t.eq(config.title[1][1], " agent-smith plan ")

      local text = footer(record.handle)
      t.matches(text, "a")
      t.matches(text, "accept")
      t.matches(text, "d")
      t.matches(text, "deny")

      record.handle.cancel()
      settled(record)
    end)

    t.it("uses distinct keys, which is the whole reason it exists", function()
      -- vim.fn.confirm derives the accelerator from the first letter of the
      -- label, so "&Run" and "&Reject" were both r. These cannot collide.
      t.not_ok(Decide.ACCEPT_KEY == Decide.DENY_KEY)
      t.eq(Decide.ACCEPT_KEY, "a")
      t.eq(Decide.DENY_KEY, "d")
    end)

    t.it("is entered, so a long body can be scrolled", function()
      local record = ask({})
      t.eq(vim.api.nvim_get_current_win(), record.handle.window)
      t.eq(vim.wo.cursorline, true)
      record.handle.cancel()
      settled(record)
    end)
  end)

  t.describe("decide: answering", function()
    t.it("accepts on a", function()
      local record = ask({})
      press(record.handle, "a")
      settled(record)
      t.eq(record.calls, 1)
      t.eq(record.accepted, true)
    end)

    t.it("denies on d", function()
      local record = ask({})
      press(record.handle, "d")
      settled(record)
      t.eq(record.calls, 1)
      t.eq(record.accepted, false)
    end)

    t.it("accepts an upper-case key too", function()
      local record = ask({})
      press(record.handle, "A")
      settled(record)
      t.eq(record.accepted, true)
    end)

    t.it("denies on q, escape, and the handle", function()
      for _, key in ipairs({ "q", "\27" }) do
        local record = ask({})
        press(record.handle, key)
        settled(record)
        t.eq(record.accepted, false, "key " .. vim.inspect(key))
      end

      local record = ask({})
      record.handle.cancel()
      settled(record)
      t.eq(record.accepted, false)
    end)

    t.it("denies when the window goes away unasked", function()
      -- Closing without answering must not read as consent.
      local record = ask({})
      vim.api.nvim_win_close(record.handle.window, true)
      settled(record)
      t.eq(record.calls, 1)
      t.eq(record.accepted, false)
    end)

    t.it("closes the window once answered", function()
      local record = ask({})
      local window, buffer = record.handle.window, record.handle.buffer

      press(record.handle, "a")
      settled(record)

      t.eq(vim.api.nvim_win_is_valid(window), false)
      t.eq(vim.api.nvim_buf_is_valid(buffer), false)
    end)

    t.it("never answers twice", function()
      local record = ask({})
      press(record.handle, "a")
      record.handle.cancel()
      settled(record)
      t.eq(record.calls, 1)
    end)

    t.it("runs decorate so the body can be coloured", function()
      local decorated = false
      local record = ask({
        decorate = function(buffer)
          decorated = true
          t.eq(vim.api.nvim_buf_get_lines(buffer, 0, 1, false)[1], "one")
        end,
      })

      t.eq(decorated, true)
      record.handle.cancel()
      settled(record)
    end)
  end)
end
