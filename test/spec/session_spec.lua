return function(t)
  local Session = require("agent-smith.session")
  local Messages = require("agent-smith.agent.messages")

  t.describe("session.id", function()
    t.it("is stable for the same project and mode", function()
      -- Reopening Neovim inside the cache's lifetime should still land on the
      -- upstream that holds the prefix.
      local first = Session.id({ root = "/home/me/project", mode = "inline" })
      local second = Session.id({ root = "/home/me/project", mode = "inline" })
      t.eq(first, second)
    end)

    t.it("differs per mode", function()
      local inline = Session.id({ root = "/home/me/project", mode = "inline" })
      local vibe = Session.id({ root = "/home/me/project", mode = "vibe" })
      t.not_ok(inline == vibe, "inline and vibe should not share a cache")
    end)

    t.it("differs per project", function()
      local here = Session.id({ root = "/home/me/one", mode = "inline" })
      local there = Session.id({ root = "/home/me/two", mode = "inline" })
      t.not_ok(here == there)
    end)

    t.it("is shell-safe and short", function()
      -- It reaches a gateway through a header, so it must not need escaping and
      -- must not be a filesystem path.
      local id = Session.id({ root = "/home/me/a project with spaces", mode = "vibe" })
      t.matches(id, "^[%w%-]+$")
      t.ok(#id <= 32, ("id should be short, got %d chars"):format(#id))
    end)

    t.it("carries a recognisable prefix", function()
      t.matches(Session.id({ root = "/x", mode = "inline" }), "^" .. Session.PREFIX .. "%-")
    end)

    t.it("tolerates a missing mode or root", function()
      t.matches(Session.id({}), "^" .. Session.PREFIX .. "%-")
      t.matches(Session.id(), "^" .. Session.PREFIX .. "%-")
    end)

    t.it("distinguishes a defaulted mode from a named one", function()
      local bare = Session.id({ root = "/x" })
      local named = Session.id({ root = "/x", mode = "default" })
      t.eq(bare, named, "the fallback mode is literally named default")
    end)
  end)

  t.describe("messages: conversation identity", function()
    t.it("is nil unless given", function()
      t.eq(Messages.new():id(), nil)
      t.eq(Messages.new({}):id(), nil)
    end)

    t.it("returns the id it was given", function()
      t.eq(Messages.new({ id = "smith-abc" }):id(), "smith-abc")
    end)

    t.it("keeps the id alongside the system prompt", function()
      local conversation = Messages.new({ system = "be brief", id = "smith-abc" })
      t.eq(conversation:system(), "be brief")
      t.eq(conversation:id(), "smith-abc")
    end)
  end)
end
