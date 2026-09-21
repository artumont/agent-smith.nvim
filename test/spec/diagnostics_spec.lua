return function(t)
  local Scope = require("agent-smith.agent.scope")
  local Tools = require("agent-smith.tools")

  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")

  local namespace = vim.api.nvim_create_namespace("agent-smith-diagnostics-spec")
  local counter = 0

  --- A named buffer in the temp root with the given diagnostics set on it.
  local function buffer_with(diagnostics)
    counter = counter + 1
    local name = ("diag%d.lua"):format(counter)
    local path = vim.fs.joinpath(root, name)

    local buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buffer, path)
    vim.diagnostic.set(namespace, buffer, diagnostics)

    return { name = name, path = path, buffer = buffer }
  end

  local scope_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(scope_buffer, vim.fs.joinpath(root, "scope.lua"))
  local scope = Scope.inline({ buffer = scope_buffer, start_row = 1, end_row = 1000 })

  local registry = Tools.default({ root = root })

  local function run(arguments)
    local record = { calls = 0 }
    registry:dispatch({ name = "diagnostics", arguments = arguments }, scope, function(outcome)
      record.calls = record.calls + 1
      record.outcome = outcome
    end)
    return record.outcome
  end

  local function diagnostic(lnum, severity, message, source)
    return { lnum = lnum, col = 0, severity = severity, message = message, source = source or "test" }
  end

  t.describe("diagnostics: formatting", function()
    t.it("renders path:line:col with the severity and message", function()
      buffer_with({ diagnostic(9, vim.diagnostic.severity.ERROR, "undefined variable") })

      local outcome = run({ path = "diag1.lua" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "diag1%.lua:10:1: ERROR: undefined variable %[test%]")
    end)

    t.it("is 1-indexed, unlike the API", function()
      buffer_with({ diagnostic(0, vim.diagnostic.severity.ERROR, "first line") })
      local outcome = run({ path = "diag2.lua" })
      t.matches(outcome.content, "diag2%.lua:1:1:")
    end)

    t.it("sorts by file, then line, then column", function()
      buffer_with({
        diagnostic(20, vim.diagnostic.severity.ERROR, "later"),
        diagnostic(1, vim.diagnostic.severity.ERROR, "earlier"),
      })
      local outcome = run({ path = "diag3.lua" })
      local first = outcome.content:find("earlier", 1, true)
      local second = outcome.content:find("later", 1, true)
      t.ok(first < second, "expected the earlier line first")
    end)
  end)

  t.describe("diagnostics: filtering", function()
    t.it("excludes information and hints by default", function()
      buffer_with({
        diagnostic(0, vim.diagnostic.severity.ERROR, "bad"),
        diagnostic(1, vim.diagnostic.severity.WARN, "worse"),
        diagnostic(2, vim.diagnostic.severity.INFO, "note"),
        diagnostic(3, vim.diagnostic.severity.HINT, "nit"),
      })

      local outcome = run({ path = "diag4.lua" })
      t.matches(outcome.content, "bad")
      t.matches(outcome.content, "worse")
      t.eq(outcome.content:find("note", 1, true), nil)
      t.eq(outcome.content:find("nit", 1, true), nil)
    end)

    t.it("includes everything at hint level", function()
      buffer_with({
        diagnostic(0, vim.diagnostic.severity.ERROR, "bad"),
        diagnostic(3, vim.diagnostic.severity.HINT, "nit"),
      })

      local outcome = run({ path = "diag5.lua", severity = "hint" })
      t.matches(outcome.content, "bad")
      t.matches(outcome.content, "nit")
    end)

    t.it("narrows to errors only", function()
      buffer_with({
        diagnostic(0, vim.diagnostic.severity.ERROR, "bad"),
        diagnostic(1, vim.diagnostic.severity.WARN, "worse"),
      })

      local outcome = run({ path = "diag6.lua", severity = "error" })
      t.matches(outcome.content, "bad")
      t.eq(outcome.content:find("worse", 1, true), nil)
    end)

    t.it("rejects an unknown severity", function()
      local outcome = run({ severity = "catastrophic" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "must be one of")
    end)
  end)

  t.describe("diagnostics: scope of the query", function()
    t.it("reports when there is nothing to report", function()
      buffer_with({})
      local outcome = run({ path = "diag7.lua" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "no diagnostics")
    end)

    t.it("refuses a file that is not open", function()
      local missing = vim.fs.joinpath(root, "never-opened.lua")
      vim.fn.writefile({ "-- x" }, missing)

      local outcome = run({ path = "never-opened.lua" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "is not open")
    end)

    t.it("caps results and says how many were suppressed", function()
      local many = {}
      for index = 1, 10 do
        many[#many + 1] = diagnostic(index, vim.diagnostic.severity.ERROR, ("problem %d"):format(index))
      end
      buffer_with(many)

      local outcome = run({ path = "diag8.lua", max_results = 3 })
      t.matches(outcome.content, "7 more suppressed")
    end)

    t.it("does not leak diagnostics from other buffers when narrowed", function()
      buffer_with({ diagnostic(0, vim.diagnostic.severity.ERROR, "in the first file") })
      buffer_with({ diagnostic(0, vim.diagnostic.severity.ERROR, "in the second file") })

      local outcome = run({ path = "diag9.lua" })
      t.matches(outcome.content, "in the first file")
      t.eq(outcome.content:find("in the second file", 1, true), nil)
    end)
  end)
end
