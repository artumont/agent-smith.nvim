return function(t)
  local Identity = require("agent-smith.agent.identity")
  local Inline = require("agent-smith.modes.inline")
  local Vibe = require("agent-smith.modes.vibe")

  --- Plain substring, not a pattern: the name has a hyphen in it, which is a
  --- quantifier in a Lua pattern, so `agent-smith` as a pattern matches `agensmith`.
  local function has(haystack, needle)
    return haystack:find(needle, 1, true) ~= nil
  end

  t.describe("identity.intro", function()
    t.it("says what it is, and who made it", function()
      local intro = Identity.intro()
      t.ok(has(intro, Identity.NAME), "names itself")
      t.ok(has(intro, Identity.AUTHOR), "and its author")
      t.ok(has(intro, "its own agent loop"))
    end)

    t.it("says what it is not", function()
      -- The guess a model makes when nothing tells it otherwise is Claude Code, and
      -- a run that offers a tool this plugin does not have — and then reports having
      -- used it — is a run whose report cannot be trusted.
      local intro = Identity.intro()
      t.ok(has(intro, "not Claude Code"))
      t.ok(has(intro, "only ones you have"), "and that the tool list is closed")
    end)
  end)

  t.describe("identity.system", function()
    t.it("puts the identity in front of a mode's own prompt", function()
      local text = Identity.system("Body.")
      t.ok(text:find(Identity.intro(), 1, true) == 1, "the identity goes first")
      t.matches(text, "Body%.")
      t.matches(text, "\n\nBody%.", "one blank line between them")
    end)

    t.it("handles a mode with no body of its own", function()
      t.eq(Identity.system(""), Identity.intro())
      t.eq(Identity.system(nil), Identity.intro())
    end)
  end)

  t.describe("identity: what the modes actually send", function()
    t.it("prefixes every system prompt in the codebase", function()
      -- There are three, one per phase. This is the test that notices a fourth
      -- being written without the identity, because the assertions below are on the
      -- mode's own prompt constant.
      for _, prompt in ipairs({ Inline.SYSTEM_PROMPT, Vibe.PLAN_PROMPT, Vibe.EXECUTE_PROMPT }) do
        local sent = Identity.system(prompt)
        t.ok(sent:find(Identity.intro(), 1, true) == 1)
        t.ok(sent:find(prompt, 1, true) == #Identity.intro() + 3, "the body follows it")
      end
    end)
  end)
end
