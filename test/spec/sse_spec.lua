return function(t)
  local Sse = require("agent-smith.transport.sse")

  local function feed_all(chunks)
    local parser = Sse.new()
    local events = {}
    for _, chunk in ipairs(chunks) do
      for _, event in ipairs(parser:feed(chunk)) do
        events[#events + 1] = event
      end
    end
    return events, parser
  end

  t.describe("sse: complete events", function()
    t.it("parses one event", function()
      local events = feed_all({ "data: hello\n\n" })
      t.eq(#events, 1)
      t.eq(events[1].data, "hello")
      t.eq(events[1].event, nil)
    end)

    t.it("parses two events from one chunk", function()
      local events = feed_all({ "data: one\n\ndata: two\n\n" })
      t.eq(#events, 2)
      t.eq(events[1].data, "one")
      t.eq(events[2].data, "two")
    end)

    t.it("parses the done sentinel like any other payload", function()
      local events = feed_all({ "data: [DONE]\n\n" })
      t.eq(events[1].data, "[DONE]")
    end)

    t.it("reads the event name field", function()
      local events = feed_all({ "event: message\ndata: {}\n\n" })
      t.eq(events[1].event, "message")
      t.eq(events[1].data, "{}")
    end)

    t.it("keeps a payload that looks like JSON intact", function()
      local payload = '{"choices":[{"delta":{"content":"a: b\\n\\n"}}]}'
      local events = feed_all({ "data: " .. payload .. "\n\n" })
      t.eq(events[1].data, payload)
    end)
  end)

  t.describe("sse: framing", function()
    t.it("joins multiple data lines with newlines", function()
      local events = feed_all({ "data: line one\ndata: line two\n\n" })
      t.eq(events[1].data, "line one\nline two")
    end)

    t.it("strips one leading space but keeps the rest", function()
      local events = feed_all({ "data:  padded\n\n" })
      t.eq(events[1].data, " padded")
    end)

    t.it("accepts an empty data value", function()
      local events = feed_all({ "data:\n\n" })
      t.eq(#events, 1)
      t.eq(events[1].data, "")
    end)

    t.it("ignores comment lines", function()
      local events = feed_all({ ": keep-alive\n\n" })
      t.eq(#events, 0)
    end)

    t.it("ignores a block with only comments", function()
      local events = feed_all({ ": ping\ndata: real\n\n: other\n\n" })
      t.eq(#events, 1)
      t.eq(events[1].data, "real")
    end)

    t.it("handles CRLF line endings", function()
      local events = feed_all({ "data: one\r\n\r\ndata: two\r\n\r\n" })
      t.eq(#events, 2)
      t.eq(events[1].data, "one")
      t.eq(events[2].data, "two")
    end)

    t.it("handles a lone CR as a line ending", function()
      local events = feed_all({ "data: one\r\r" })
      t.eq(#events, 1)
      t.eq(events[1].data, "one")
    end)
  end)

  t.describe("sse: chunk boundaries", function()
    t.it("holds an incomplete event back", function()
      local events = feed_all({ "data: incomplete\n" })
      t.eq(#events, 0)
    end)

    t.it("completes an event split mid-payload", function()
      local events = feed_all({ "data: hel", "lo\n", "\n" })
      t.eq(#events, 1)
      t.eq(events[1].data, "hello")
    end)

    t.it("completes an event split inside the blank-line delimiter", function()
      local events = feed_all({ "data: hello\n", "\n" })
      t.eq(#events, 1)
      t.eq(events[1].data, "hello")
    end)

    t.it("does not confuse a CRLF split across chunks", function()
      local events = feed_all({ "data: hello\r", "\n\r\n" })
      t.eq(#events, 1)
      t.eq(events[1].data, "hello")
    end)

    t.it("splits a multi-event chunk at any boundary", function()
      local events = feed_all({ "data: a\n\ndata: ", "b\n\ndata: c\n\n" })
      t.eq(#events, 3)
      t.eq({ events[1].data, events[2].data, events[3].data }, { "a", "b", "c" })
    end)

    t.it("survives one byte at a time", function()
      local whole = "data: alpha\n\ndata: beta\n\n"
      local chunks = {}
      for index = 1, #whole do
        chunks[index] = whole:sub(index, index)
      end

      local events = feed_all(chunks)
      t.eq(#events, 2)
      t.eq({ events[1].data, events[2].data }, { "alpha", "beta" })
    end)

    t.it("treats an empty chunk as a no-op", function()
      local events = feed_all({ "", "data: x\n\n", "" })
      t.eq(#events, 1)
    end)
  end)

  t.describe("sse: pending", function()
    t.it("exposes an incomplete frame", function()
      local _, parser = feed_all({ "data: incomplete" })
      t.eq(parser:pending(), "data: incomplete")
    end)

    t.it("is empty once the event is delivered", function()
      local _, parser = feed_all({ "data: done\n\n" })
      t.eq(parser:pending(), "")
    end)

    t.it("exposes a non-SSE body, which is how an error object arrives", function()
      -- A JSON error body has no blank line, so nothing is ever emitted and the
      -- body is all that is left.
      local _, parser = feed_all({ '{"error":{"message":"bad key"}}' })
      t.matches(parser:pending(), "bad key")
    end)
  end)
end
