return function(t)
  local Scope = require("agent-smith.agent.scope")
  local Tools = require("agent-smith.tools")
  local Bwrap = require("agent-smith.sandbox.bwrap")

  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, "sub"), "p")
  vim.fn.writefile({ "on disk" }, vim.fs.joinpath(root, "probe.txt"))

  local scope_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(scope_buffer, vim.fs.joinpath(root, "scope.lua"))

  local function scope_with(overrides)
    local fields = { buffer = scope_buffer, start_row = 1, end_row = 1000 }
    for name, value in pairs(overrides or {}) do
      fields[name] = value
    end
    return Scope.inline(fields)
  end

  local registry = Tools.default({ root = root, timeout_ms = 5000 })

  local function run(arguments, scope)
    local record = { calls = 0 }
    registry:dispatch({ name = "bash", arguments = arguments }, scope or scope_with(), function(outcome)
      record.calls = record.calls + 1
      record.outcome = outcome
    end)

    if record.calls == 0 then
      t.settle(function()
        return record.calls > 0
      end, 20000)
    end

    t.ok(record.outcome, "bash produced no outcome")
    return record.outcome
  end

  if not Bwrap.available() then
    -- The tool must refuse rather than run unsandboxed, so this is a real
    -- assertion rather than a skipped test.
    t.it("refuses to run when bubblewrap is missing", function()
      local outcome = run({ command = "echo hi" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "bubblewrap is not installed")
    end)
  else
    t.describe("bash: execution", function()
      t.it("runs a command and returns stdout", function()
        local outcome = run({ command = "echo hello" })
        t.eq(outcome.ok, true)
        t.matches(outcome.content, "exit 0")
        t.matches(outcome.content, "hello")
      end)

      t.it("reports a non-zero exit code with its output", function()
        local outcome = run({ command = "echo oops >&2; exit 3" })
        t.eq(outcome.ok, true, "the tool worked even though the command failed")
        t.matches(outcome.content, "exit 3")
        t.matches(outcome.content, "oops")
      end)

      t.it("separates stdout from stderr", function()
        local outcome = run({ command = "echo out; echo err >&2" })
        t.matches(outcome.content, "stdout:")
        t.matches(outcome.content, "stderr:")
      end)

      t.it("says so when there is no output", function()
        local outcome = run({ command = "true" })
        t.matches(outcome.content, "%(no output%)")
      end)

      t.it("runs in the project root by default", function()
        local outcome = run({ command = "pwd" })
        t.matches(outcome.content, vim.pesc(root))
      end)

      t.it("honours cwd", function()
        local outcome = run({ command = "pwd", cwd = "sub" })
        t.matches(outcome.content, vim.pesc(vim.fs.joinpath(root, "sub")))
      end)

      t.it("refuses a cwd that is not a directory", function()
        local outcome = run({ command = "pwd", cwd = "probe.txt" })
        t.eq(outcome.ok, false)
        t.matches(outcome.error, "is not a directory")
      end)

      t.it("kills a command that outlives its timeout", function()
        local outcome = run({ command = "sleep 30", timeout_ms = 400 })
        t.eq(outcome.ok, true)
        t.matches(outcome.content, "killed by signal")
      end)
    end)

    t.describe("bash: sandbox boundary", function()
      t.it("cannot write to the project", function()
        -- The project is bound read-only, so a stray write fails loudly rather
        -- than being caught by the blacklist.
        local outcome = run({ command = "echo altered > probe.txt" })
        -- sh reports a redirection failure as 2, not 1.
        t.matches(outcome.content, "exit [1-9]")
        t.matches(outcome.content, "Read%-only file system")
        t.eq(vim.fn.readfile(vim.fs.joinpath(root, "probe.txt")), { "on disk" }, "disk is unchanged")
      end)

      t.it("cannot see the home directory", function()
        local outcome = run({ command = 'ls -d "$HOME" 2>&1 || echo HOME-HIDDEN' })
        t.matches(outcome.content, "HOME%-HIDDEN")
      end)

      t.it("has no network", function()
        local outcome = run({ command = "curl -s -m 3 -o /dev/null http://1.1.1.1 && echo OPEN || echo BLOCKED" })
        t.matches(outcome.content, "BLOCKED")
      end)

      t.it("cannot see host processes", function()
        local outcome = run({ command = 'ls /proc | grep -c "^[0-9]"' })
        local count = tonumber(outcome.content:match("\n(%d+)"))
        t.ok(count, "expected a count of visible processes")
        t.ok(count < 50, ("expected an isolated pid namespace, saw %d processes"):format(count))
      end)
    end)

    t.describe("bash: blacklist", function()
      t.it("refuses a blacklisted command before running it", function()
        local outcome = run({ command = "rm -rf /" }, scope_with({ blacklist = { "^%s*rm%s" } }))
        t.eq(outcome.ok, false)
        t.matches(outcome.error, "blacklist")
      end)

      t.it("runs a command the blacklist does not match", function()
        local outcome = run({ command = "echo fine" }, scope_with({ blacklist = { "^%s*rm%s" } }))
        t.eq(outcome.ok, true)
        t.matches(outcome.content, "fine")
      end)
    end)
  end
end
