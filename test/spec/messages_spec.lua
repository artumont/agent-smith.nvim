return function(t)
  local Messages = require("agent-smith.agent.messages")
  local Events = require("agent-smith.agent.events")

  local function tool_use(id, name)
    return Events.tool_use(id, name, { path = "/a.lua" })
  end

  t.describe("messages: construction", function()
    t.it("starts empty with the given system prompt", function()
      local conversation = Messages.new({ system = "be brief" })
      t.eq(conversation:system(), "be brief")
      t.eq(conversation:length(), 0)
      t.eq(conversation:list(), {})
    end)

    t.it("tolerates no system prompt", function()
      t.eq(Messages.new():system(), "")
      t.eq(Messages.new({}):system(), "")
    end)
  end)

  t.describe("messages: user turns", function()
    t.it("appends a user message", function()
      local conversation = Messages.new()
      conversation:append_user("do the thing")
      t.eq(conversation:list(), { { role = "user", content = "do the thing" } })
    end)

    t.it("refuses an empty user message", function()
      t.raises(function()
        Messages.new():append_user("")
      end, "needs content")
    end)

    t.it("refuses a non-string user message", function()
      t.raises(function()
        Messages.new():append_user(nil)
      end, "needs content")
    end)
  end)

  t.describe("messages: assistant turns", function()
    t.it("appends text", function()
      local conversation = Messages.new()
      conversation:append_assistant({ text = "hello" })
      t.eq(conversation:list(), { { role = "assistant", content = "hello", tool_uses = {} } })
    end)

    t.it("keeps only the fields a transport needs from a tool call", function()
      local conversation = Messages.new()
      conversation:append_assistant({ tool_uses = { tool_use("call_1", "read") } })

      local message = conversation:list()[1]
      t.eq(message.tool_uses[1], { id = "call_1", name = "read", arguments = { path = "/a.lua" } })
    end)

    t.it("refuses something that is not a tool_use event", function()
      t.raises(function()
        Messages.new():append_assistant({ tool_uses = { { id = "x", name = "read", arguments = {} } } })
      end, "expects tool_use events")
    end)

    t.it("keeps thinking when present", function()
      local conversation = Messages.new()
      conversation:append_assistant({ text = "a", thinking = "because" })
      t.eq(conversation:list()[1].thinking, "because")
    end)

    t.it("omits thinking when empty", function()
      local conversation = Messages.new()
      conversation:append_assistant({ text = "a", thinking = "" })
      t.eq(conversation:list()[1].thinking, nil)
    end)

    t.it("defaults content to an empty string", function()
      local conversation = Messages.new()
      conversation:append_assistant({})
      t.eq(conversation:list()[1].content, "")
    end)
  end)

  t.describe("messages: tool results", function()
    t.it("groups results into one entry", function()
      local conversation = Messages.new()
      conversation:append_tool_results({
        Events.tool_result_ok("call_1", "contents"),
        Events.tool_result_error("call_2", "nope"),
      })

      local message = conversation:list()[1]
      t.eq(message.role, "tool")
      t.eq(#message.results, 2)
      t.eq(message.results[1], { id = "call_1", ok = true, content = "contents" })
      t.eq(message.results[2], { id = "call_2", ok = false, error = "nope" })
    end)

    t.it("refuses an empty result list", function()
      t.raises(function()
        Messages.new():append_tool_results({})
      end, "no results to append")
    end)

    t.it("refuses something that is not a tool_result", function()
      t.raises(function()
        Messages.new():append_tool_results({ { id = "x", ok = true } })
      end, "expects tool_result events")
    end)
  end)

  t.describe("messages: list", function()
    t.it("returns a copy of the array", function()
      local conversation = Messages.new()
      conversation:append_user("one")

      local listed = conversation:list()
      listed[2] = { role = "user", content = "injected" }

      t.eq(conversation:length(), 1, "the conversation is unaffected")
      t.eq(#conversation:list(), 1)
    end)

    t.it("preserves order", function()
      local conversation = Messages.new()
      conversation:append_user("one")
      conversation:append_assistant({ text = "two" })
      conversation:append_tool_results({ Events.tool_result_ok("call_1", "three") })

      local roles = {}
      for _, message in ipairs(conversation:list()) do
        roles[#roles + 1] = message.role
      end
      t.eq(roles, { "user", "assistant", "tool" })
    end)
  end)
end
