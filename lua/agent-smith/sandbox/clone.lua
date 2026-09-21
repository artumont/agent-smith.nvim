--- Isolated clones for vibe runs.
---
--- ADR 0006 chose a clone over a `git worktree`, and the reason is worth
--- repeating here because worktrees are the common recommendation:
---
---   **A worktree is not an isolation boundary.** Linked worktrees share the
---   repository — refs, config, stash and `hooks` — so an agent with write
---   access there can install a `post-checkout` hook that later executes on the
---   host, outside any sandbox. A clone gets its own `.git` for about the same
---   cost, so there is no reason to accept that.
---
--- `--no-hardlinks` is deliberate. A hardlinked clone shares its object store
--- with the parent, and the aliasing is not worth the saving when the whole point
--- is that the parent cannot be reached.
---
--- The lifecycle is create, work, review, apply or discard. Only `apply` touches
--- the real repository, and it does so from a reviewed patch rather than by
--- copying files back.
---
--- Blocking, not async: a `--local` clone does no network work, and a vibe run
--- already stops to ask the user twice. Noted rather than hidden, because a
--- large repository on a slow disk would make it noticeable.

local M = {}

--- Prefix for clone directories, so stale ones can be found and swept.
M.PREFIX = "smith-"

local counter = 0

--- A filesystem-safe unique id.
local function new_id()
  counter = counter + 1

  local ok, bytes = pcall(vim.uv.random, 4)
  local suffix
  if ok and type(bytes) == "string" then
    suffix = (bytes:gsub(".", function(byte)
      return ("%02x"):format(byte:byte())
    end))
  else
    suffix = ("%08x"):format(vim.uv.hrtime() % 0xffffffff)
  end

  return ("%s-%02d"):format(suffix, counter)
end

--- Where clones live by default.
function M.default_root()
  return vim.fs.joinpath(vim.fn.stdpath("cache"), "agent-smith", "sandbox")
end

local function run(command)
  return vim.system(command, { text = true }):wait()
end

--- Whether a path is a git work tree.
function M.is_repository(path)
  local completed = run({ "git", "-C", path, "rev-parse", "--git-dir" })
  return completed.code == 0
end

--- Clone `fields.root` into a fresh directory.
---
---@param fields table
---   - root: string           Required. The repository to copy.
---   - sandbox_root: string|nil  Where clones live; defaults to the cache dir.
---   - id: string|nil         For tests, so a directory is predictable.
---@return table|nil clone { id, directory, root }
---@return string|nil error
function M.create(fields)
  assert(type(fields) == "table", "clone.create needs a fields table")

  local root = fields.root
  if type(root) ~= "string" or root == "" then
    return nil, "clone.create needs a root"
  end

  if not M.is_repository(root) then
    return nil, ("%s is not a git repository, so there is nothing to clone"):format(root)
  end

  local sandbox_root = fields.sandbox_root or M.default_root()
  local id = fields.id or new_id()
  local directory = vim.fs.joinpath(sandbox_root, M.PREFIX .. id)

  if vim.fn.isdirectory(directory) == 1 then
    return nil, ("%s already exists"):format(directory)
  end

  vim.fn.mkdir(sandbox_root, "p")

  local completed = run({
    "git",
    "clone",
    "--local",
    "--no-hardlinks",
    "--quiet",
    root,
    directory,
  })

  if completed.code ~= 0 then
    return nil,
      ("could not clone %s: %s"):format(root, vim.trim(completed.stderr or "no output"))
  end

  return {
    id = id,
    directory = directory,
    root = root,
    sandbox_root = sandbox_root,
  }
end

--- Remove a clone.
---@return boolean removed
function M.discard(clone)
  if type(clone) ~= "table" or type(clone.directory) ~= "string" then
    return false
  end
  if vim.fn.isdirectory(clone.directory) ~= 1 then
    return true
  end

  local ok = vim.fn.delete(clone.directory, "rf") == 0
  return ok
end

--- Remove every clone under a sandbox root.
---
--- For the case a previous session could not clean up after itself: Neovim
--- crashing leaves the directory behind, and nothing else knows to remove it.
---@return number removed
function M.sweep(sandbox_root)
  sandbox_root = sandbox_root or M.default_root()

  local removed = 0
  local handle = vim.uv.fs_scandir(sandbox_root)
  if not handle then
    return removed
  end

  while true do
    local name, kind = vim.uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if kind == "directory" and vim.startswith(name, M.PREFIX) then
      if vim.fn.delete(vim.fs.joinpath(sandbox_root, name), "rf") == 0 then
        removed = removed + 1
      end
    end
  end

  return removed
end

--- Whether the agent changed anything.
function M.changed(clone)
  local completed = run({ "git", "-C", clone.directory, "status", "--porcelain" })
  return completed.code == 0 and vim.trim(completed.stdout or "") ~= ""
end

--- The patch representing everything the agent did.
---
--- Everything is staged first, because a plain `git diff` shows tracked
--- modifications only — a file the agent created would be invisible, and a new
--- file is exactly the kind of change that needs review.
---
--- Note the limit: staging respects `.gitignore`, so a file the agent created
--- that is ignored will not appear in the patch.
---
---@return string|nil patch Empty string when nothing changed.
---@return string|nil error
function M.diff(clone)
  local staged = run({ "git", "-C", clone.directory, "add", "-A" })
  if staged.code ~= 0 then
    return nil, ("could not stage the clone: %s"):format(vim.trim(staged.stderr or "no output"))
  end

  local completed = run({ "git", "-C", clone.directory, "diff", "--cached", "--no-color" })
  if completed.code ~= 0 then
    return nil, ("could not diff the clone: %s"):format(vim.trim(completed.stderr or "no output"))
  end

  return completed.stdout or "", nil
end

--- Apply a patch to the real repository.
---
--- Applied from a patch rather than by copying files, so what lands is exactly
--- what was reviewed.
---
---@param patch string
---@param target string The repository to apply to.
---@return boolean ok
---@return string|nil error
function M.apply(patch, target)
  if type(patch) ~= "string" or patch == "" then
    return true, nil
  end

  local completed = vim.system(
    { "git", "-C", target, "apply", "--whitespace=nowarn", "-" },
    { text = true, stdin = patch }
  ):wait()

  if completed.code ~= 0 then
    return false, ("could not apply the patch: %s"):format(vim.trim(completed.stderr or "no output"))
  end
  return true, nil
end

return M
