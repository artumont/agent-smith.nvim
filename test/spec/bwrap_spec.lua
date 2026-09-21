return function(t)
  local Bwrap = require("agent-smith.sandbox.bwrap")

  --- Index of a flag in an argv, or nil.
  local function index_of(argv, flag)
    for index, value in ipairs(argv) do
      if value == flag then
        return index
      end
    end
    return nil
  end

  --- Whether `flag value` appears as a consecutive pair anywhere in the argv.
  ---
  --- Scanning every occurrence matters: add_system_paths emits --ro-bind before
  --- the project's, so checking only the first would test the wrong mount.
  local function has_pair(argv, flag, value)
    for index, entry in ipairs(argv) do
      if entry == flag and argv[index + 1] == value then
        return true
      end
    end
    return false
  end

  t.describe("bwrap.build", function()
    t.it("starts with bwrap and ends with -- before the command", function()
      local argv = Bwrap.build({ command = { "echo", "hi" } })
      t.eq(argv[1], "bwrap")
      t.eq(argv[#argv - 2], "--")
      t.eq(argv[#argv - 1], "echo")
      t.eq(argv[#argv], "hi")
    end)

    t.it("recreates the merged-/usr symlinks", function()
      -- Without these, /bin/sh does not exist inside the sandbox at all.
      local argv = Bwrap.build({ command = { "true" } })
      local link = index_of(argv, "--symlink")
      t.ok(link ~= nil, "expected at least one --symlink")

      local destinations = {}
      for index, value in ipairs(argv) do
        if value == "--symlink" then
          destinations[argv[index + 2]] = argv[index + 1]
        end
      end

      if vim.uv.fs_readlink("/bin") then
        t.eq(destinations["/bin"], vim.uv.fs_readlink("/bin"))
      end
      if vim.uv.fs_readlink("/lib") then
        t.eq(destinations["/lib"], vim.uv.fs_readlink("/lib"))
      end
    end)

    t.it("mounts proc, dev and a tmpfs /tmp", function()
      local argv = Bwrap.build({ command = { "true" } })
      t.ok(has_pair(argv, "--proc", "/proc"))
      t.ok(has_pair(argv, "--dev", "/dev"))
      t.ok(has_pair(argv, "--tmpfs", "/tmp"))
    end)

    t.it("unshares the network by default", function()
      -- Measured: omitting --share-net does not unshare the network. Only
      -- --unshare-net does.
      t.ok(index_of(Bwrap.build({ command = { "true" } }), "--unshare-net") ~= nil)
    end)

    t.it("keeps the network when asked", function()
      local argv = Bwrap.build({ command = { "true" }, network = true })
      t.eq(index_of(argv, "--unshare-net"), nil)
    end)

    t.it("isolates processes and dies with its parent", function()
      local argv = Bwrap.build({ command = { "true" } })
      t.ok(index_of(argv, "--unshare-pid") ~= nil)
      t.ok(index_of(argv, "--unshare-uts") ~= nil)
      t.ok(index_of(argv, "--unshare-ipc") ~= nil)
      t.ok(index_of(argv, "--die-with-parent") ~= nil)
    end)

    t.it("binds the root read-only and no writable path", function()
      local argv = Bwrap.build({ command = { "true" }, root = "/tmp/project" })
      t.ok(has_pair(argv, "--ro-bind", "/tmp/project"))
      t.eq(index_of(argv, "--bind"), nil)
    end)

    t.it("binds the writable path read-write", function()
      local argv = Bwrap.build({ command = { "true" }, root = "/tmp/project", writable = "/tmp/clone" })
      t.ok(has_pair(argv, "--ro-bind", "/tmp/project"))
      t.ok(has_pair(argv, "--bind", "/tmp/clone"))
    end)

    t.it("does not bind the same path twice when root is writable", function()
      local argv = Bwrap.build({ command = { "true" }, root = "/tmp/clone", writable = "/tmp/clone" })
      t.ok(has_pair(argv, "--bind", "/tmp/clone"))
      t.eq(has_pair(argv, "--ro-bind", "/tmp/clone"), false)
    end)

    t.it("changes directory when asked", function()
      local argv = Bwrap.build({ command = { "true" }, cwd = "/tmp/project" })
      t.ok(has_pair(argv, "--chdir", "/tmp/project"))
    end)

    t.it("puts --chdir before the -- separator", function()
      local argv = Bwrap.build({ command = { "true" }, cwd = "/tmp/project" })
      t.ok(index_of(argv, "--chdir") < index_of(argv, "--"))
    end)

    t.it("raises without a command", function()
      t.raises(function()
        Bwrap.build({})
      end, "needs a command")
    end)

    t.it("raises when the command is empty", function()
      t.raises(function()
        Bwrap.build({ command = {} })
      end, "needs a command")
    end)
  end)

  t.describe("bwrap.available", function()
    t.it("reports whether bwrap is installed", function()
      t.eq(Bwrap.available(), vim.fn.executable("bwrap") == 1)
    end)
  end)
end
