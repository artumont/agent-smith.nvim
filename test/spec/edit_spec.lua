return function(t)
  local Scope = require("agent-smith.agent.scope")
  local Tools = require("agent-smith.tools")

  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")

  local counter = 0

  --- Write a file into the temp project and return its name and absolute path.
  local function make_file(lines)
    counter = counter + 1
    local name = ("file%d.lua"):format(counter)
    local path = vim.fs.joinpath(root, name)
    vim.fn.writefile(lines, path)
    return name, path
  end

  --- An inline scope over `path`, permitting writes within [first, last].
  local function scope_for(path, first, last)
    local buffer = vim.fn.bufnr(path)
    if buffer == -1 then
      buffer = vim.fn.bufadd(path)
      vim.fn.bufload(buffer)
    end
    return Scope.inline({ buffer = buffer, start_row = first or 1, end_row = last or 10000 })
  end

  local function fixture(lines, first, last)
    local name, path = make_file(lines)
    return {
      registry = Tools.default({ root = root }),
      scope = scope_for(path, first, last),
      name = name,
      path = path,
    }
  end

  local function run(f, arguments, turn)
    local record = { calls = 0 }
    f.registry:dispatch({ name = "edit", arguments = arguments }, f.scope, function(outcome)
      record.calls = record.calls + 1
      record.outcome = outcome
    end, { turn = turn or "turn-1" })
    return record.outcome
  end

  local function buffer_lines(f)
    return vim.api.nvim_buf_get_lines(vim.fn.bufnr(f.path), 0, -1, false)
  end

  local function disc_lines(f)
    return vim.fn.readfile(f.path)
  end

  local function undo(f)
    vim.api.nvim_buf_call(vim.fn.bufnr(f.path), function()
      pcall(vim.cmd, "undo")
    end)
  end

  t.describe("edit: applying", function()
    t.it("replaces a single line", function()
      local f = fixture({ "a", "b", "c" })
      local outcome = run(f, { path = f.name, start_row = 2, end_row = 2, text = "B" })
      t.eq(outcome.ok, true)
      t.eq(buffer_lines(f), { "a", "B", "c" })
    end)

    t.it("replaces a multi-line range with several lines", function()
      local f = fixture({ "a", "b", "c", "d" })
      run(f, { path = f.name, start_row = 2, end_row = 3, text = "one\ntwo\nthree" })
      t.eq(buffer_lines(f), { "a", "one", "two", "three", "d" })
    end)

    t.it("deletes a range with empty text", function()
      local f = fixture({ "a", "b", "c" })
      run(f, { path = f.name, start_row = 2, end_row = 3, text = "" })
      t.eq(buffer_lines(f), { "a" })
    end)

    t.it("inserts above a line when end_row is start_row - 1", function()
      local f = fixture({ "a", "b" })
      run(f, { path = f.name, start_row = 1, end_row = 0, text = "new" })
      t.eq(buffer_lines(f), { "new", "a", "b" })
    end)

    t.it("appends past the last line", function()
      local f = fixture({ "a", "b" })
      run(f, { path = f.name, start_row = 3, end_row = 2, text = "c" })
      t.eq(buffer_lines(f), { "a", "b", "c" })
    end)

    t.it("drops one trailing newline", function()
      local f = fixture({ "a", "b" })
      run(f, { path = f.name, start_row = 1, end_row = 1, text = "A\n" })
      t.eq(buffer_lines(f), { "A", "b" })
    end)

    t.it("keeps a deliberate blank last line", function()
      local f = fixture({ "a", "b" })
      run(f, { path = f.name, start_row = 1, end_row = 1, text = "A\n\n" })
      t.eq(buffer_lines(f), { "A", "", "b" })
    end)

    t.it("reports the resulting line count", function()
      local f = fixture({ "a", "b", "c" })
      local outcome = run(f, { path = f.name, start_row = 1, end_row = 2, text = "only" })
      t.matches(outcome.content, "buffer now has 2 lines")
      t.matches(outcome.content, "unsaved")
    end)
  end)

  t.describe("edit: buffer-native", function()
    t.it("does not write to disk", function()
      local f = fixture({ "a", "b", "c" })
      run(f, { path = f.name, start_row = 1, end_row = 1, text = "A" })
      t.eq(disc_lines(f), { "a", "b", "c" }, "disk is untouched")
      t.eq(vim.bo[vim.fn.bufnr(f.path)].modified, true, "the buffer is modified")
    end)

    t.it("loads a buffer for a file that is not open", function()
      local f = fixture({ "a", "b" })
      local before = vim.fn.bufnr(f.path)
      t.ok(before ~= -1, "the fixture scope already opened it")
      run(f, { path = f.name, start_row = 2, end_row = 2, text = "B" })
      t.eq(buffer_lines(f), { "a", "B" })
    end)
  end)

  t.describe("edit: range validation", function()
    t.it("refuses a file that does not exist", function()
      -- The scope has to approve the path, or the refusal comes from the scope
      -- and the existence check is never reached.
      local f = fixture({ "a" })
      local missing = vim.fs.joinpath(root, "nope.lua")
      local scope = Scope.vibe({ paths = { missing } })
      local record = { calls = 0 }
      f.registry:dispatch(
        { name = "edit", arguments = { path = "nope.lua", start_row = 1, end_row = 1, text = "x" } },
        scope,
        function(outcome)
          record.calls = record.calls + 1
          record.outcome = outcome
        end,
        { turn = "turn-1" }
      )
      t.eq(record.outcome.ok, false)
      t.matches(record.outcome.error, "does not exist")
    end)

    t.it("refuses an inverted range beyond the insert form", function()
      local f = fixture({ "a", "b", "c" })
      local outcome = run(f, { path = f.name, start_row = 3, end_row = 1, text = "x" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "use start_row %- 1 to insert")
    end)

    t.it("refuses a start_row past the end", function()
      local f = fixture({ "a" })
      local outcome = run(f, { path = f.name, start_row = 5, end_row = 5, text = "x" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "outside")
    end)

    t.it("refuses an end_row past the end", function()
      local f = fixture({ "a", "b" })
      local outcome = run(f, { path = f.name, start_row = 1, end_row = 9, text = "x" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "past the end")
    end)

    t.it("refuses an empty path before touching anything", function()
      local f = fixture({ "a" })
      local outcome = run(f, { path = "", start_row = 1, end_row = 1, text = "x" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "must not be empty")
    end)
  end)

  t.describe("edit: staleness guard", function()
    t.it("refuses when expect does not match", function()
      local f = fixture({ "a", "b", "c" })
      local outcome = run(f, { path = f.name, start_row = 2, end_row = 2, text = "X", expect = "wrong" })
      t.eq(outcome.ok, false)
      t.matches(outcome.error, "does not hold the expected text")
      t.eq(buffer_lines(f), { "a", "b", "c" }, "the buffer is untouched")
    end)

    t.it("shows both expected and found text", function()
      local f = fixture({ "a", "b" })
      local outcome = run(f, { path = f.name, start_row = 1, end_row = 1, text = "X", expect = "zzz" })
      t.matches(outcome.error, "--- expected ---")
      t.matches(outcome.error, "--- found ---")
    end)

    t.it("proceeds when expect matches", function()
      local f = fixture({ "a", "b" })
      local outcome = run(f, { path = f.name, start_row = 1, end_row = 1, text = "A", expect = "a" })
      t.eq(outcome.ok, true)
      t.eq(buffer_lines(f), { "A", "b" })
    end)

    t.it("matches a multi-line range with newlines", function()
      local f = fixture({ "a", "b", "c" })
      local outcome = run(f, { path = f.name, start_row = 1, end_row = 2, text = "x", expect = "a\nb" })
      t.eq(outcome.ok, true)
    end)

    t.it("treats an empty range as the empty string", function()
      local f = fixture({ "a" })
      local outcome = run(f, { path = f.name, start_row = 1, end_row = 0, text = "x", expect = "" })
      t.eq(outcome.ok, true)
      t.eq(buffer_lines(f), { "x", "a" })
    end)
  end)

  t.describe("edit: undo grouping", function()
    t.it("reverts two edits of one turn with a single undo", function()
      local f = fixture({ "a", "b", "c" })
      run(f, { path = f.name, start_row = 1, end_row = 1, text = "A" }, "turn-1")
      run(f, { path = f.name, start_row = 3, end_row = 3, text = "C" }, "turn-1")
      t.eq(buffer_lines(f), { "A", "b", "C" })

      undo(f)
      t.eq(buffer_lines(f), { "a", "b", "c" }, "one undo must revert the whole turn")
    end)

    t.it("reverts an inserted range and its replacement together", function()
      local f = fixture({ "a", "b", "c", "d" })
      run(f, { path = f.name, start_row = 1, end_row = 0, text = "zero" }, "turn-1")
      run(f, { path = f.name, start_row = 3, end_row = 3, text = "B" }, "turn-1")
      run(f, { path = f.name, start_row = 5, end_row = 5, text = "" }, "turn-1")
      t.eq(buffer_lines(f), { "zero", "a", "B", "c" })

      undo(f)
      t.eq(buffer_lines(f), { "a", "b", "c", "d" }, "all three edits revert together")
    end)

    t.it("keeps separate turns in separate undo blocks", function()
      local f = fixture({ "a", "b", "c" })
      run(f, { path = f.name, start_row = 1, end_row = 1, text = "A" }, "turn-1")
      run(f, { path = f.name, start_row = 3, end_row = 3, text = "C" }, "turn-2")
      t.eq(buffer_lines(f), { "A", "b", "C" })

      undo(f)
      t.eq(buffer_lines(f), { "A", "b", "c" }, "only the second turn reverts")
      undo(f)
      t.eq(buffer_lines(f), { "a", "b", "c" })
    end)

    t.it("does not group edits from an unidentified turn", function()
      local f = fixture({ "a", "b" })
      local function dispatch_no_turn(arguments)
        f.registry:dispatch({ name = "edit", arguments = arguments }, f.scope, function() end)
      end

      dispatch_no_turn({ path = f.name, start_row = 1, end_row = 1, text = "A" })
      dispatch_no_turn({ path = f.name, start_row = 2, end_row = 2, text = "B" })
      t.eq(buffer_lines(f), { "A", "B" })

      undo(f)
      t.eq(buffer_lines(f), { "A", "b" }, "without a turn token each edit stands alone")
    end)
  end)

  t.describe("edit: scope enforcement", function()
    t.it("escalates a write outside the selected range", function()
      local f = fixture({ "a", "b", "c", "d", "e" }, 2, 3)
      local outcome = run(f, { path = f.name, start_row = 4, end_row = 5, text = "X" })

      t.eq(outcome.ok, nil)
      t.ok(outcome.needs_permission ~= nil, "expected a permission request")
      t.eq(outcome.needs_permission.tool, "edit")
      t.eq(outcome.needs_permission.target.path, f.path)
      t.eq(outcome.needs_permission.target.range, { start_row = 4, end_row = 5 })
      t.matches(outcome.needs_permission.reason, "outside the selected range 2%-3")
      t.eq(buffer_lines(f), { "a", "b", "c", "d", "e" }, "the buffer is untouched")
    end)

    t.it("allows a write inside the selected range", function()
      local f = fixture({ "a", "b", "c", "d", "e" }, 2, 3)
      local outcome = run(f, { path = f.name, start_row = 2, end_row = 3, text = "X" })
      t.eq(outcome.ok, true)
      t.eq(buffer_lines(f), { "a", "X", "d", "e" })
    end)

    t.it("escalates a write to another file", function()
      local f = fixture({ "a" }, 1, 1)
      local other_name, other_path = make_file({ "z" })
      local outcome = run(f, { path = other_name, start_row = 1, end_row = 1, text = "Z" })

      t.ok(outcome.needs_permission ~= nil)
      t.matches(outcome.needs_permission.reason, "different file")
      t.eq(vim.fn.readfile(other_path), { "z" })
    end)

    t.it("allows an approved path in a vibe scope", function()
      local f = fixture({ "a", "b" })
      local scope = Scope.vibe({ paths = { f.path } })
      local record = { calls = 0 }
      f.registry:dispatch({ name = "edit", arguments = { path = f.name, start_row = 1, end_row = 1, text = "A" } }, scope, function(outcome)
        record.calls = record.calls + 1
        record.outcome = outcome
      end)
      t.eq(record.outcome.ok, true)
      t.eq(buffer_lines(f), { "A", "b" })
    end)

    t.it("refuses an unapproved path in a vibe scope", function()
      local f = fixture({ "a", "b" })
      local scope = Scope.vibe({ paths = { vim.fs.joinpath(root, "elsewhere.lua") } })
      local record = { calls = 0 }
      f.registry:dispatch({ name = "edit", arguments = { path = f.name, start_row = 1, end_row = 1, text = "A" } }, scope, function(outcome)
        record.calls = record.calls + 1
        record.outcome = outcome
      end)
      t.eq(record.outcome.ok, false)
      t.matches(record.outcome.error, "not in the approved plan scope")
      t.eq(buffer_lines(f), { "a", "b" }, "the buffer is untouched")
    end)
  end)
end
