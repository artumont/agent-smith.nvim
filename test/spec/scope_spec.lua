return function(t)
  local Scope = require("agent-smith.agent.scope")

  -- A named buffer is required for an inline scope. Created once and reused.
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, "/repo/scope_spec.lua")

  local function inline(overrides)
    local fields = { buffer = buffer, start_row = 10, end_row = 20 }
    for name, value in pairs(overrides or {}) do
      fields[name] = value
    end
    return Scope.inline(fields)
  end

  t.describe("Scope.inline", function()
    t.it("allows a write inside the range", function()
      local decision = inline():decide({ kind = "write", path = "/repo/scope_spec.lua", range = { start_row = 12, end_row = 14 } })
      t.eq(decision.kind, "allow")
    end)

    t.it("allows a write exactly on the boundaries", function()
      local decision = inline():decide({ kind = "write", path = "/repo/scope_spec.lua", range = { start_row = 10, end_row = 20 } })
      t.eq(decision.kind, "allow")
    end)

    t.it("escalates a write below the range", function()
      local decision = inline():decide({ kind = "write", path = "/repo/scope_spec.lua", range = { start_row = 18, end_row = 25 } })
      t.eq(decision.kind, "needs_permission")
      t.matches(decision.reason, "lines 18%-25 are outside the selected range 10%-20")
    end)

    t.it("escalates a write above the range", function()
      local decision = inline():decide({ kind = "write", path = "/repo/scope_spec.lua", range = { start_row = 1, end_row = 11 } })
      t.eq(decision.kind, "needs_permission")
    end)

    t.it("escalates a write to another file", function()
      local decision = inline():decide({ kind = "write", path = "/repo/other.lua", range = { start_row = 12, end_row = 12 } })
      t.eq(decision.kind, "needs_permission")
      t.matches(decision.reason, "different file")
    end)

    t.it("escalates a write that declares no range", function()
      local decision = inline():decide({ kind = "write", path = "/repo/scope_spec.lua" })
      t.eq(decision.kind, "needs_permission")
      t.matches(decision.reason, "does not declare a range")
    end)

    t.it("hands the exact target back with the escalation", function()
      local target = { kind = "write", path = "/repo/other.lua", range = { start_row = 3, end_row = 4 } }
      local decision = inline():decide(target)
      t.eq(decision.target, target)
    end)

    t.it("normalises .. in the target path", function()
      local decision = inline():decide({
        kind = "write",
        path = "/repo/sub/../scope_spec.lua",
        range = { start_row = 12, end_row = 12 },
      })
      t.eq(decision.kind, "allow")
    end)

    t.it("accepts a reversed selection", function()
      local scope = inline({ start_row = 20, end_row = 10 })
      t.eq(scope.start_row, 10)
      t.eq(scope.end_row, 20)
      t.eq(scope:decide({ kind = "write", path = "/repo/scope_spec.lua", range = { start_row = 15, end_row = 15 } }).kind, "allow")
    end)

    t.it("raises for an unnamed buffer", function()
      local unnamed = vim.api.nvim_create_buf(false, true)
      t.raises(function()
        Scope.inline({ buffer = unnamed, start_row = 1, end_row = 2 })
      end, "needs a named buffer")
    end)

    t.it("raises when fields are missing", function()
      t.raises(function()
        Scope.inline({ buffer = buffer })
      end, "needs start_row")
    end)
  end)

  t.describe("Scope.vibe", function()
    local function vibe(overrides)
      local fields = { paths = { "/repo/a.lua", "/repo/b.lua" } }
      for name, value in pairs(overrides or {}) do
        fields[name] = value
      end
      return Scope.vibe(fields)
    end

    t.it("allows a write to an approved path", function()
      t.eq(vibe():decide({ kind = "write", path = "/repo/a.lua" }).kind, "allow")
    end)

    t.it("allows a write to an approved path with no range", function()
      t.eq(vibe():decide({ kind = "write", path = "/repo/b.lua" }).kind, "allow")
    end)

    t.it("refuses rather than escalating a write outside the plan", function()
      -- spec/decisions/0007: out-of-plan writes are recorded and ignored.
      local decision = vibe():decide({ kind = "write", path = "/repo/c.lua" })
      t.eq(decision.kind, "deny")
      t.matches(decision.reason, "not in the approved plan scope")
    end)

    t.it("escalates instead when escalation is asked for", function()
      local scope = vibe({ escalation = true })
      t.eq(scope:decide({ kind = "write", path = "/repo/c.lua" }).kind, "needs_permission")
    end)

    t.it("normalises approved paths", function()
      local scope = vibe({ paths = { "/repo/./a.lua" } })
      t.eq(scope:decide({ kind = "write", path = "/repo/a.lua" }).kind, "allow")
    end)

    t.it("raises for a non-string path", function()
      t.raises(function()
        Scope.vibe({ paths = { 42 } })
      end, "must be a non%-empty string")
    end)
  end)

  t.describe("reads", function()
    t.it("are allowed in both modes", function()
      t.eq(inline():decide({ kind = "read", path = "/etc/passwd" }).kind, "allow")
      t.eq(Scope.vibe({ paths = {} }):decide({ kind = "read", path = "/etc/passwd" }).kind, "allow")
    end)
  end)

  t.describe("command blacklist", function()
    local blacklist = { "^%s*rm%s", "^%s*shutdown" }

    t.it("denies a matching command", function()
      local decision = inline({ blacklist = blacklist }):decide({ kind = "execute", command = "rm -rf /" })
      t.eq(decision.kind, "deny")
      t.matches(decision.reason, "matches the blacklist pattern")
    end)

    t.it("allows a non-matching command", function()
      t.eq(inline({ blacklist = blacklist }):decide({ kind = "execute", command = "ls -la" }).kind, "allow")
    end)

    t.it("allows everything when the blacklist is empty", function()
      t.eq(inline():decide({ kind = "execute", command = "rm -rf /" }).kind, "allow")
    end)

    t.it("reports which pattern matched", function()
      t.eq(inline({ blacklist = blacklist }):blocked_command("rm -rf /"), "^%s*rm%s")
      t.eq(inline({ blacklist = blacklist }):blocked_command("ls"), nil)
    end)
  end)

  t.describe("decide: malformed targets", function()
    t.it("denies a non-table target", function()
      t.eq(inline():decide("write").kind, "deny")
    end)

    t.it("denies a target with no kind", function()
      t.eq(inline():decide({ path = "/repo/a.lua" }).kind, "deny")
    end)

    t.it("denies an unknown kind", function()
      local decision = inline():decide({ kind = "telepathy" })
      t.eq(decision.kind, "deny")
      t.matches(decision.reason, "unknown target kind")
    end)

    t.it("denies a write with no path", function()
      t.eq(inline():decide({ kind = "write" }).kind, "deny")
    end)

    t.it("denies an execute with no command", function()
      t.eq(inline():decide({ kind = "execute" }).kind, "deny")
    end)
  end)
end
