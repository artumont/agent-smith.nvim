--- bubblewrap argv construction.
---
--- Everything here was checked against a real bwrap, because two details are
--- easy to get wrong and fail silently in the direction that matters:
---
---   1. Merged-/usr layouts. On Debian and friends `/bin`, `/sbin`, `/lib`,
---      `/lib64` and `/lib32` are symlinks into `/usr`. Binding `/usr` does not
---      create those symlinks, so `/bin/sh` does not exist inside the sandbox
---      and every command fails with "execvp /bin/sh: No such file or
---      directory". The links have to be recreated explicitly.
---
---   2. Network. Omitting `--share-net` does NOT unshare the network; bwrap
---      shares it by default. Only `--unshare-net` blocks it. Measured: curl
---      reached the network without the flag and was blocked with it, including
---      against a raw IP, so the block is real isolation and not a DNS
---      artefact.
---
--- See spec/decisions/0006-sandbox-isolated-clone.md and spec/sandboxing.md.

local M = {}

--- Bound read-only so that a toolchain can run in the sandbox.
M.SYSTEM_PATHS = { "/usr", "/etc" }

--- Candidates that are symlinks into /usr on a merged-/usr system.
M.SYMLINK_CANDIDATES = { "/bin", "/sbin", "/lib", "/lib64", "/lib32" }

--- Whether bubblewrap is usable here.
function M.available()
  return vim.fn.executable("bwrap") == 1
end

local function add_system_paths(command)
  for _, path in ipairs(M.SYSTEM_PATHS) do
    if vim.uv.fs_stat(path) then
      vim.list_extend(command, { "--ro-bind", path, path })
    end
  end

  for _, path in ipairs(M.SYMLINK_CANDIDATES) do
    local target = vim.uv.fs_readlink(path)
    if target then
      -- Recreate the link rather than binding the target onto this name:
      -- binding the resolved directory onto the symlink path did not work.
      vim.list_extend(command, { "--symlink", target, path })
    elseif vim.uv.fs_stat(path) then
      -- A non-merged system: a real directory, so bind it.
      vim.list_extend(command, { "--ro-bind", path, path })
    end
  end
end

--- Build the argv for one sandboxed command.
---
---@param options table
---   - command: string[]     Required. The command to run inside.
---   - root: string|nil      Project root, bound read-only.
---   - writable: string|nil  A path bound read-write. In vibe this is the
---                           isolated clone; in inline it is nil, so the project
---                           is read-only and a stray write fails loudly.
---   - network: boolean|nil  Default false, which unshares the network.
---   - cwd: string|nil       Working directory inside the sandbox.
---@return string[] argv
function M.build(options)
  assert(type(options) == "table", "bwrap.build needs an options table")
  assert(type(options.command) == "table" and #options.command > 0, "bwrap.build needs a command")

  local root = options.root and vim.fs.normalize(options.root) or nil
  local writable = options.writable and vim.fs.normalize(options.writable) or nil
  if root and writable and root == writable then
    -- The writable bind would win anyway, but emitting both is noise.
    root = nil
  end

  local command = { "bwrap" }
  add_system_paths(command)

  vim.list_extend(command, { "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp" })

  if root then
    vim.list_extend(command, { "--ro-bind", root, root })
  end
  if writable then
    vim.list_extend(command, { "--bind", writable, writable })
  end

  vim.list_extend(command, { "--unshare-pid", "--unshare-uts", "--unshare-ipc", "--die-with-parent" })

  if not options.network then
    vim.list_extend(command, { "--unshare-net" })
  end

  if options.cwd then
    vim.list_extend(command, { "--chdir", vim.fs.normalize(options.cwd) })
  end

  vim.list_extend(command, { "--" })
  vim.list_extend(command, options.command)

  return command
end

return M
