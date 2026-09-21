return function(t)
  local Clone = require("agent-smith.sandbox.clone")

  --- A real repository with one committed file.
  local function repository()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")

    vim.fn.system({ "git", "init", "--quiet", root })
    vim.fn.system({ "git", "-C", root, "config", "user.email", "test@example.invalid" })
    vim.fn.system({ "git", "-C", root, "config", "user.name", "Test" })
    vim.fn.writefile({ "line one", "line two" }, vim.fs.joinpath(root, "a.lua"))
    vim.fn.system({ "git", "-C", root, "add", "-A" })
    vim.fn.system({ "git", "-C", root, "commit", "--quiet", "-m", "init" })

    return root
  end

  local function sandbox()
    local directory = vim.fn.tempname()
    vim.fn.mkdir(directory, "p")
    return directory
  end

  --- A clone of a fresh repository, in its own sandbox.
  local function cloned()
    local root = repository()
    local clone = Clone.create({ root = root, sandbox_root = sandbox() })
    return clone, root
  end

  t.describe("clone.create", function()
    t.it("copies the repository's contents", function()
      local clone = cloned()
      t.eq(vim.fn.filereadable(vim.fs.joinpath(clone.directory, "a.lua")), 1)
      t.eq(vim.fn.readfile(vim.fs.joinpath(clone.directory, "a.lua")), { "line one", "line two" })
    end)

    t.it("gives the clone its own git directory", function()
      -- The whole reason ADR 0006 chose a clone over a worktree: a worktree's
      -- .git is a *file* pointing at the parent's, and that shared repository is
      -- what makes a worktree not an isolation boundary.
      local clone, root = cloned()

      local clone_git = vim.fs.joinpath(clone.directory, ".git")
      t.eq(vim.fn.isdirectory(clone_git), 1, "a clone has a real .git directory, not a pointer")
      t.eq(vim.fn.filereadable(clone_git), 0)

      t.not_ok(
        vim.fs.normalize(clone_git) == vim.fs.normalize(vim.fs.joinpath(root, ".git")),
        "the clone must not share the parent's git directory"
      )
    end)

    t.it("puts clones under the prefix so they can be swept", function()
      local clone = cloned()
      t.matches(vim.fs.basename(clone.directory), "^" .. Clone.PREFIX)
    end)

    t.it("creates a distinct directory each time", function()
      local root = repository()
      local directory = sandbox()
      local first = Clone.create({ root = root, sandbox_root = directory })
      local second = Clone.create({ root = root, sandbox_root = directory })

      t.not_ok(first.directory == second.directory)
      t.eq(vim.fn.isdirectory(first.directory), 1)
      t.eq(vim.fn.isdirectory(second.directory), 1)
    end)

    t.it("accepts an id, so a directory is predictable", function()
      local root = repository()
      local clone = Clone.create({ root = root, sandbox_root = sandbox(), id = "fixed" })
      t.eq(vim.fs.basename(clone.directory), Clone.PREFIX .. "fixed")
    end)

    t.it("refuses a directory that is not a repository", function()
      local plain = vim.fn.tempname()
      vim.fn.mkdir(plain, "p")

      local clone, err = Clone.create({ root = plain, sandbox_root = sandbox() })
      t.eq(clone, nil)
      t.matches(err, "not a git repository")
    end)

    t.it("refuses to reuse an existing directory", function()
      local root = repository()
      local directory = sandbox()
      Clone.create({ root = root, sandbox_root = directory, id = "taken" })

      local clone, err = Clone.create({ root = root, sandbox_root = directory, id = "taken" })
      t.eq(clone, nil)
      t.matches(err, "already exists")
    end)

    t.it("requires a root", function()
      local clone, err = Clone.create({ sandbox_root = sandbox() })
      t.eq(clone, nil)
      t.matches(err, "needs a root")
    end)

    t.it("defaults its sandbox under the cache directory", function()
      t.matches(Clone.default_root(), "agent%-smith/sandbox$")
    end)
  end)

  t.describe("clone.changed", function()
    t.it("is false for a fresh clone", function()
      local clone = cloned()
      t.eq(Clone.changed(clone), false)
    end)

    t.it("is true after an edit", function()
      local clone = cloned()
      vim.fn.writefile({ "line one", "CHANGED" }, vim.fs.joinpath(clone.directory, "a.lua"))
      t.eq(Clone.changed(clone), true)
    end)

    t.it("is true for a new file", function()
      local clone = cloned()
      vim.fn.writefile({ "new" }, vim.fs.joinpath(clone.directory, "b.lua"))
      t.eq(Clone.changed(clone), true)
    end)
  end)

  t.describe("clone.diff", function()
    t.it("is empty when nothing changed", function()
      local clone = cloned()
      t.eq(Clone.diff(clone), "")
    end)

    t.it("shows an edit", function()
      local clone = cloned()
      vim.fn.writefile({ "line one", "CHANGED" }, vim.fs.joinpath(clone.directory, "a.lua"))

      local patch = Clone.diff(clone)
      t.matches(patch, "a%.lua")
      t.matches(patch, "%-line two")
      t.matches(patch, "%+CHANGED")
    end)

    t.it("shows a file the agent created", function()
      -- A plain `git diff` would miss this: a new file is untracked, and a new
      -- file is exactly the kind of change that needs review.
      local clone = cloned()
      vim.fn.writefile({ "brand new" }, vim.fs.joinpath(clone.directory, "created.lua"))

      local patch = Clone.diff(clone)
      t.matches(patch, "created%.lua")
      t.matches(patch, "%+brand new")
      t.matches(patch, "new file")
    end)

    t.it("shows a file the agent deleted", function()
      local clone = cloned()
      vim.fn.delete(vim.fs.joinpath(clone.directory, "a.lua"))

      local patch = Clone.diff(clone)
      t.matches(patch, "a%.lua")
      t.matches(patch, "deleted")
    end)

    t.it("can be called twice without changing its answer", function()
      local clone = cloned()
      vim.fn.writefile({ "line one", "CHANGED" }, vim.fs.joinpath(clone.directory, "a.lua"))
      t.eq(Clone.diff(clone), Clone.diff(clone))
    end)
  end)

  t.describe("clone.apply", function()
    t.it("writes the change into the repository", function()
      local clone, root = cloned()
      vim.fn.writefile({ "line one", "CHANGED" }, vim.fs.joinpath(clone.directory, "a.lua"))

      local ok, err = Clone.apply(Clone.diff(clone), root)
      t.eq(err, nil)
      t.eq(ok, true)
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "a.lua")), { "line one", "CHANGED" })
    end)

    t.it("creates a file the agent created", function()
      local clone, root = cloned()
      vim.fn.writefile({ "brand new" }, vim.fs.joinpath(clone.directory, "created.lua"))

      t.eq(Clone.apply(Clone.diff(clone), root), true)
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "created.lua")), { "brand new" })
    end)

    t.it("is a no-op for an empty patch", function()
      local _, root = cloned()
      local ok, err = Clone.apply("", root)
      t.eq(ok, true)
      t.eq(err, nil)
    end)

    t.it("leaves the repository alone when the patch is rejected", function()
      local _, root = cloned()
      local patch = table.concat({
        "--- a/a.lua",
        "+++ b/a.lua",
        "@@ -1,1 +1,1 @@",
        "-a line that was never there",
        "+replacement",
      }, "\n") .. "\n"

      local ok, err = Clone.apply(patch, root)
      t.eq(ok, false)
      t.matches(err, "could not apply")
      t.eq(vim.fn.readfile(vim.fs.joinpath(root, "a.lua")), { "line one", "line two" })
    end)
  end)

  t.describe("clone.discard and sweep", function()
    t.it("removes the directory", function()
      local clone = cloned()
      t.eq(Clone.discard(clone), true)
      t.eq(vim.fn.isdirectory(clone.directory), 0)
    end)

    t.it("does nothing for a directory already gone", function()
      local clone = cloned()
      vim.fn.delete(clone.directory, "rf")
      t.eq(Clone.discard(clone), true)
    end)

    t.it("refuses anything that is not a clone", function()
      t.eq(Clone.discard(nil), false)
      t.eq(Clone.discard({}), false)
    end)

    t.it("sweeps stale clones and leaves everything else", function()
      local directory = sandbox()
      vim.fn.mkdir(vim.fs.joinpath(directory, Clone.PREFIX .. "stale"), "p")
      vim.fn.mkdir(vim.fs.joinpath(directory, Clone.PREFIX .. "older"), "p")
      vim.fn.mkdir(vim.fs.joinpath(directory, "not-a-clone"), "p")

      t.eq(Clone.sweep(directory), 2)
      t.eq(vim.fn.isdirectory(vim.fs.joinpath(directory, Clone.PREFIX .. "stale")), 0)
      t.eq(vim.fn.isdirectory(vim.fs.joinpath(directory, "not-a-clone")), 1, "unrelated directories stay")
    end)

    t.it("sweeping a directory that does not exist is not an error", function()
      t.eq(Clone.sweep(vim.fs.joinpath(vim.fn.tempname(), "missing")), 0)
    end)
  end)

  t.describe("clone.is_repository", function()
    t.it("recognises a repository", function()
      t.eq(Clone.is_repository(repository()), true)
    end)

    t.it("rejects a plain directory", function()
      local plain = vim.fn.tempname()
      vim.fn.mkdir(plain, "p")
      t.eq(Clone.is_repository(plain), false)
    end)
  end)
end
