return function(t)
  local Scope = require("agent-smith.agent.scope")
  local Tools = require("agent-smith.tools")

  -- A throwaway project to point the tools at.
  local root = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(root, "src"), "p")
  vim.fn.writefile({ "line one", "line two", "line three" }, vim.fs.joinpath(root, "src", "a.lua"))
  vim.fn.writefile({ "-- TODO: fix this" }, vim.fs.joinpath(root, "src", "b.lua"))
  vim.fn.writefile({ "nothing here" }, vim.fs.joinpath(root, "src", "c.txt"))

  local scope_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(scope_buffer, vim.fs.joinpath(root, "scope.lua"))
  local scope = Scope.inline({ buffer = scope_buffer, start_row = 1, end_row = 1000 })

  local function registry_with(overrides)
    local options = { root = root }
    for name, value in pairs(overrides or {}) do
      options[name] = value
    end
    return Tools.default(options)
  end

  local default_registry = registry_with()

  --- Dispatch and return the outcome, pumping the loop for asynchronous tools.
  local function call(registry, name, arguments)
    local record = { calls = 0 }
    registry:dispatch({ name = name, arguments = arguments }, scope, function(outcome)
      record.calls = record.calls + 1
      record.outcome = outcome
    end)

    if record.calls == 0 then
      t.settle(function()
        return record.calls > 0
      end)
    end

    t.ok(record.outcome, ("%s produced no outcome"):format(name))
    return record.outcome
  end

  local function call_default(name, arguments)
    return call(default_registry, name, arguments)
  end

  t.describe("read", function()
    t.it("returns numbered lines", function()
      local outcome = call_default("read", { path = "src/a.lua" })
      t.eq(outcome.ok, true)
      t.eq(outcome.content, "1| line one\n2| line two\n3| line three")
    end)

    t.it("respects a row range", function()
      local outcome = call_default("read", { path = "src/a.lua", start_row = 2, end_row = 3 })
      t.eq(outcome.content, "2| line two\n3| line three")
    end)

    t.it("accepts an absolute path", function()
      local outcome = call_default("read", { path = vim.fs.joinpath(root, "src", "a.lua") })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "1| line one")
    end)

    t.it("truncates and says so", function()
      local small = registry_with({ max_lines = 2 })
      local outcome = call(small, "read", { path = "src/a.lua" })
      t.eq(outcome.ok, true)
      t.eq(outcome.content, "1| line one\n2| line two\n... [truncated at 2 lines; file has 3, next line is 3]")
    end)

    t.it("reports a missing file", function()
      local outcome = call_default("read", { path = "src/missing.lua" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "cannot read src/missing.lua")
    end)

    t.it("refuses a directory", function()
      local outcome = call_default("read", { path = "src" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "is a directory")
    end)

    t.it("reports a start_row past the end", function()
      local outcome = call_default("read", { path = "src/a.lua", start_row = 99 })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "past the end")
    end)

    t.it("reports an empty file", function()
      vim.fn.writefile({}, vim.fs.joinpath(root, "empty.lua"))
      local outcome = call_default("read", { path = "empty.lua" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "is empty")
    end)

    t.it("prefers an unsaved buffer over disk", function()
      local path = vim.fs.joinpath(root, "buffered.lua")
      vim.fn.writefile({ "on disk" }, path)

      -- A scratch buffer (nvim_create_buf(false, true)) is buftype=nofile, and
      -- Neovim does not track 'modified' on those, so it could never report an
      -- unsaved edit. This mirrors a real file buffer.
      local buffer = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buffer, path)
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "in buffer" })

      t.eq(vim.bo[buffer].modified, true, "editing a file buffer marks it modified")

      local outcome = call_default("read", { path = "buffered.lua" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "1| in buffer")
      t.matches(outcome.content, "unsaved buffer")
    end)

    t.it("rejects an empty path before reading", function()
      local outcome = call_default("read", { path = "" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "must not be empty")
    end)

    t.it("returns an outline instead of contents when asked", function()
      vim.fn.writefile(
        { "local function helper()", "end", "", "function M.run()", "end" },
        vim.fs.joinpath(root, "src", "outline.lua")
      )

      local outcome = call_default("read", { path = "src/outline.lua", outline = true })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "outline%.lua")
      t.matches(outcome.content, "helper")
      t.matches(outcome.content, "M%.run")
      t.matches(outcome.content, "approximate", "no server is attached, so this is the heuristic")
      t.matches(outcome.content, "start_row")
    end)

    t.it("an outline is far smaller than the file", function()
      -- Realistic proportions: functions with bodies, not three-line stubs.
      -- The saving comes from replacing bodies with one line each.
      local lines = {}
      for index = 1, 100 do
        lines[#lines + 1] = ("local function generated_%d()"):format(index)
        for step = 1, 10 do
          lines[#lines + 1] = ("  local step_%d = %d"):format(step, step)
        end
        lines[#lines + 1] = "end"
      end
      vim.fn.writefile(lines, vim.fs.joinpath(root, "src", "big.lua"))

      local outline = call_default("read", { path = "src/big.lua", outline = true })
      local contents = call_default("read", { path = "src/big.lua" })

      t.eq(outline.ok, true)
      t.eq(contents.ok, true)
      t.ok(
        #outline.content * 4 < #contents.content,
        ("outline %d bytes vs contents %d"):format(#outline.content, #contents.content)
      )
    end)

    t.it("refuses an outline for a language it cannot summarise", function()
      vim.fn.writefile({ "whatever" }, vim.fs.joinpath(root, "src", "thing.xyz"))
      local outcome = call_default("read", { path = "src/thing.xyz", outline = true })
      t.eq(outcome.ok, true, "an unavailable outline is not a failed tool")
      t.matches(outcome.content, "no outline available")
    end)
  end)

  t.describe("grep", function()
    t.it("finds a match with file, line and text", function()
      local outcome = call_default("grep", { pattern = "TODO" })
      t.eq(outcome.ok, true)
      t.eq(outcome.content, "src/b.lua:1:-- TODO: fix this")
    end)

    t.it("reports no matches without failing", function()
      local outcome = call_default("grep", { pattern = "zzzznotpresent" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "no matches")
    end)

    t.it("reports a bad pattern as an error", function()
      local outcome = call_default("grep", { pattern = "[" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "search failed")
    end)

    t.it("restricts the search to a path", function()
      local outcome = call_default("grep", { pattern = "line", path = "src/a.lua" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "src/a.lua:1:line one")
    end)

    t.it("restricts the search by glob", function()
      local matching = call_default("grep", { pattern = "nothing", glob = "*.txt" })
      t.eq(matching.ok, true)
      t.matches(matching.content, "src/c.txt:1:nothing here")

      local excluded = call_default("grep", { pattern = "nothing", glob = "*.lua" })
      t.matches(excluded.content, "no matches")
    end)

    t.it("caps results and says how many were suppressed", function()
      local outcome = call_default("grep", { pattern = "line", max_results = 1 })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "suppressed")
    end)
  end)

  t.describe("glob", function()
    t.it("finds files by pattern", function()
      local outcome = call_default("glob", { pattern = "**/*.lua" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "src/a.lua")
      t.matches(outcome.content, "src/b.lua")
    end)

    t.it("does not return directories", function()
      local outcome = call_default("glob", { pattern = "**/*" })
      t.not_ok(outcome.content:match("src/$"), "directories should be filtered out")
    end)

    t.it("keeps an absolute pattern inside the root", function()
      local outcome = call_default("glob", { pattern = "/etc/*" })
      t.eq(outcome.ok, true)
      t.eq(outcome.content:match("no files match") ~= nil, true)
    end)

    t.it("reports no matches without failing", function()
      local outcome = call_default("glob", { pattern = "**/*.rs" })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "no files match")
    end)

    t.it("caps results and says how many were suppressed", function()
      local outcome = call_default("glob", { pattern = "**/*", max_results = 1 })
      t.eq(outcome.ok, true)
      t.matches(outcome.content, "suppressed")
    end)
  end)

  t.describe("tool set", function()
    t.it("registers the available tools", function()
      t.eq(default_registry:names(), { "bash", "diagnostics", "edit", "glob", "grep", "read" })
    end)

    t.it("describes every tool for the model", function()
      local schemas = default_registry:schemas()
      t.eq(#schemas, 6)
      for _, schema in ipairs(schemas) do
        t.ok(schema.description ~= "", schema.name .. " needs a description")
        t.eq(schema.parameters.additionalProperties, false)
      end
    end)

    t.it("reports a genuinely unknown tool", function()
      local outcome = call_default("rm", {})
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "unknown tool")
    end)
  end)
end
