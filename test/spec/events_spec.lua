return function(t)
  local Events = require("agent-smith.agent.events")

  t.describe("constructors", function()
    t.it("produce valid events", function()
      local events = {
        Events.text_delta("hello"),
        Events.thinking_delta("hmm"),
        Events.tool_use("call_1", "read", { path = "a.lua" }),
        Events.tool_result_ok("call_1", "contents"),
        Events.tool_result_error("call_1", "no such file"),
        Events.usage({ input_tokens = 10, output_tokens = 4 }),
        Events.done("complete"),
        Events.error("transport died", "transport"),
      }
      for _, event in ipairs(events) do
        local ok, err = Events.validate(event)
        t.eq(ok, true, ("%s should be valid: %s"):format(tostring(event.type), tostring(err)))
      end
    end)

    t.it("return fresh tables rather than a shared one", function()
      t.not_ok(Events.text_delta("x") == Events.text_delta("x"))
    end)

    t.it("attach no metatable", function()
      t.eq(getmetatable(Events.tool_use("id", "read", {})), nil)
    end)

    t.it("accept an empty argument table", function()
      t.eq(Events.validate(Events.tool_use("call_1", "list", {})), true)
    end)

    t.it("copy usage fields instead of aliasing the input", function()
      local fields = { input_tokens = 5 }
      Events.usage(fields)
      t.eq(fields.type, nil)
    end)
  end)

  t.describe("validate: structural", function()
    t.it("rejects a non-table", function()
      t.eq(Events.validate(nil), false)
      t.eq(Events.validate("text_delta"), false)
    end)

    t.it("reports why a non-table was rejected", function()
      local _, err = Events.validate(nil)
      t.matches(err, "must be a table")
    end)

    t.it("rejects a missing type", function()
      local ok, err = Events.validate({ text = "hi" })
      t.eq(ok, false)
      t.matches(err, "event.type must be a string")
    end)

    t.it("rejects an unknown type", function()
      local ok, err = Events.validate({ type = "telepathy" })
      t.eq(ok, false)
      t.matches(err, "unknown event type")
    end)

    t.it("ignores fields the schema does not mention", function()
      local event = Events.text_delta("hi")
      event.vendor_extra = { nested = true }
      t.eq(Events.validate(event), true)
    end)
  end)

  t.describe("validate: text events", function()
    t.it("rejects a missing text", function()
      local ok, err = Events.validate({ type = "text_delta" })
      t.eq(ok, false)
      t.matches(err, "missing required field 'text'")
    end)

    t.it("rejects a non-string text", function()
      local ok, err = Events.validate({ type = "thinking_delta", text = 42 })
      t.eq(ok, false)
      t.matches(err, "field 'text' must be string, got number")
    end)
  end)

  t.describe("validate: tool_use", function()
    t.it("rejects missing arguments", function()
      local ok, err = Events.validate({ type = "tool_use", id = "a", name = "read" })
      t.eq(ok, false)
      t.matches(err, "missing required field 'arguments'")
    end)

    t.it("rejects an empty id", function()
      local ok, err = Events.validate({ type = "tool_use", id = "", name = "read", arguments = {} })
      t.eq(ok, false)
      t.matches(err, "field 'id' must not be empty")
    end)

    t.it("rejects an empty name", function()
      local ok, err = Events.validate({ type = "tool_use", id = "a", name = "", arguments = {} })
      t.eq(ok, false)
      t.matches(err, "field 'name' must not be empty")
    end)
  end)

  t.describe("validate: tool_result", function()
    t.it("rejects a non-boolean ok", function()
      local ok, err = Events.validate({ type = "tool_result", id = "a" })
      t.eq(ok, false)
      t.matches(err, "field 'ok' must be boolean")
    end)

    t.it("requires content when ok is true", function()
      local ok, err = Events.validate({ type = "tool_result", id = "a", ok = true })
      t.eq(ok, false)
      t.matches(err, "missing required field 'content'")
    end)

    t.it("requires error when ok is false", function()
      local ok, err = Events.validate({ type = "tool_result", id = "a", ok = false })
      t.eq(ok, false)
      t.matches(err, "missing required field 'error'")
    end)

    t.it("rejects error alongside content when ok is true", function()
      local ok, err = Events.validate({
        type = "tool_result",
        id = "a",
        ok = true,
        content = "fine",
        error = "also this",
      })
      t.eq(ok, false)
      t.matches(err, "field 'error' is not allowed when ok is true")
    end)

    t.it("rejects content alongside error when ok is false", function()
      local ok, err = Events.validate({
        type = "tool_result",
        id = "a",
        ok = false,
        content = "stale",
        error = "broke",
      })
      t.eq(ok, false)
      t.matches(err, "field 'content' is not allowed when ok is false")
    end)

    t.it("accepts empty content", function()
      t.eq(Events.validate(Events.tool_result_ok("a", "")), true)
    end)
  end)

  t.describe("validate: usage", function()
    t.it("rejects an event carrying no token field", function()
      local ok, err = Events.validate({ type = "usage" })
      t.eq(ok, false)
      t.matches(err, "at least one token field is required")
    end)

    t.it("rejects a negative count", function()
      local ok, err = Events.validate({ type = "usage", input_tokens = -1 })
      t.eq(ok, false)
      -- The dash must be escaped: as a Lua pattern, '-' is a lazy quantifier.
      t.matches(err, "non%-negative number")
    end)

    t.it("rejects a non-numeric count", function()
      t.eq(Events.validate({ type = "usage", output_tokens = "10" }), false)
    end)

    t.it("accepts any subset of the token fields", function()
      t.eq(Events.validate({ type = "usage", output_tokens = 7 }), true)
      t.eq(Events.validate({ type = "usage", cache_read_tokens = 0 }), true)
      t.eq(Events.validate({ type = "usage", reasoning_tokens = 12 }), true)
    end)

    t.it("accepts zero", function()
      t.eq(Events.validate({ type = "usage", input_tokens = 0, output_tokens = 0 }), true)
    end)

    t.it("exposes the token field list for consumers", function()
      t.eq(Events.token_fields, {
        "input_tokens",
        "output_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "reasoning_tokens",
      })
    end)
  end)

  t.describe("validate: terminators", function()
    t.it("rejects an unknown done reason", function()
      local ok, err = Events.validate({ type = "done", reason = "vibes" })
      t.eq(ok, false)
      t.matches(err, "field 'reason' must be one of")
    end)

    t.it("accepts every documented done reason", function()
      for _, reason in ipairs(Events.done_reasons) do
        t.eq(Events.validate(Events.done(reason)), true, reason)
      end
    end)

    t.it("requires an error message", function()
      local ok, err = Events.validate({ type = "error" })
      t.eq(ok, false)
      t.matches(err, "missing required field 'message'")
    end)

    t.it("treats error.detail as optional", function()
      t.eq(Events.validate(Events.error("boom")), true)
    end)

    t.it("rejects a non-string error.detail", function()
      t.eq(Events.validate(Events.error("boom", 7)), false)
    end)
  end)

  t.describe("is_terminal", function()
    t.it("is true for done and error", function()
      t.eq(Events.is_terminal(Events.done("complete")), true)
      t.eq(Events.is_terminal(Events.error("boom")), true)
    end)

    t.it("is false for deltas and tool traffic", function()
      t.eq(Events.is_terminal(Events.text_delta("hi")), false)
      t.eq(Events.is_terminal(Events.thinking_delta("hi")), false)
      t.eq(Events.is_terminal(Events.tool_use("a", "read", {})), false)
      t.eq(Events.is_terminal(Events.tool_result_ok("a", "x")), false)
      t.eq(Events.is_terminal(Events.usage({ input_tokens = 1 })), false)
    end)

    t.it("is false for a non-table", function()
      t.eq(Events.is_terminal(nil), false)
      t.eq(Events.is_terminal("done"), false)
    end)

    t.it("agrees with validate on every terminal reason", function()
      for _, reason in ipairs(Events.done_reasons) do
        local event = Events.done(reason)
        t.eq(Events.is_terminal(event) and Events.validate(event), true, reason)
      end
    end)
  end)
end
