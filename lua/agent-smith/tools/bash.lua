--- The bash tool: run a command in a sandbox.
---
--- The sandbox is the boundary; the command blacklist is only a guardrail
--- against accidents. If bubblewrap is unavailable this tool refuses to run
--- rather than falling back to unsandboxed execution, because a silent
--- downgrade is worse than an unavailable tool. See
--- spec/decisions/0005-permission-model.md and
--- spec/decisions/0009-linux-only-v1.md.
---
--- The project is bound read-only unless `writable` is set. In inline mode that
--- means a stray write fails loudly; in vibe mode the isolated clone is the
--- writable path.
---
--- Known limitation: the sandbox sees the project *on disk*, so buffered edits
--- are not visible to a command any more than they are to grep.

local Paths = require("agent-smith.tools.paths")
local Registry = require("agent-smith.tools.registry")
local Bwrap = require("agent-smith.sandbox.bwrap")

local M = {}

M.DEFAULT_TIMEOUT_MS = 60000
M.MAX_OUTPUT_LINES = 400

local function truncate(output, max_lines)
  local lines = vim.split(output, "\n", { plain = true })
  if #lines <= max_lines then
    return output
  end
  local kept = {}
  for index = 1, max_lines do
    kept[index] = lines[index]
  end
  kept[#kept + 1] = ("... [%d more lines suppressed]"):format(#lines - max_lines)
  return table.concat(kept, "\n")
end

local function render(result, max_lines)
  local parts = {}

  if result.signal ~= nil and result.signal ~= 0 then
    parts[#parts + 1] = ("killed by signal %d"):format(result.signal)
  else
    parts[#parts + 1] = ("exit %s"):format(tostring(result.code))
  end

  local stdout = vim.trim(result.stdout or "")
  local stderr = vim.trim(result.stderr or "")

  if stdout ~= "" then
    parts[#parts + 1] = "stdout:\n" .. truncate(stdout, max_lines)
  end
  if stderr ~= "" then
    parts[#parts + 1] = "stderr:\n" .. truncate(stderr, max_lines)
  end
  if stdout == "" and stderr == "" then
    parts[#parts + 1] = "(no output)"
  end

  return table.concat(parts, "\n")
end

--- Build the bash tool bound to a project root.
---@param options table
---   - root: string            Project root, bound read-only unless writable.
---   - writable: string|nil    Path to bind read-write, i.e. the vibe clone.
---   - network: boolean|nil    Default false.
---   - timeout_ms: number|nil  Default one minute.
---@return table spec
function M.tool(options)
  local root = assert(options.root, "the bash tool needs a root")
  local writable = options.writable
  local network = options.network or false
  local default_timeout = options.timeout_ms or M.DEFAULT_TIMEOUT_MS
  local max_lines = options.max_output_lines or M.MAX_OUTPUT_LINES

  return {
    name = "bash",
    description = "Run a shell command in a sandbox with no network access. The project is read-only, so writes fail.",
    access = Registry.EXECUTE,
    parameters = {
      command = {
        type = "string",
        required = true,
        description = "Shell command to run via sh -c.",
      },
      cwd = {
        type = "string",
        description = "Working directory, relative to the project root. Defaults to the root.",
      },
      timeout_ms = {
        type = "number",
        description = "Kill the command after this many milliseconds.",
      },
    },
    locate = function(arguments)
      return { kind = Registry.EXECUTE, command = arguments.command }
    end,
    handler = function(arguments, context)
      if not Bwrap.available() then
        return Registry.error(
          "bubblewrap is not installed, so commands cannot be sandboxed; install bwrap rather than running unsandboxed"
        )
      end

      local cwd = root
      if arguments.cwd then
        cwd = Paths.resolve(root, arguments.cwd)
        if vim.fn.isdirectory(cwd) ~= 1 then
          return Registry.error(("%s is not a directory"):format(Paths.display(root, cwd)))
        end
      end

      local command = Bwrap.build({
        command = { "/bin/sh", "-c", arguments.command },
        root = root,
        writable = writable,
        network = network,
        cwd = cwd,
      })

      local timeout = arguments.timeout_ms or default_timeout

      vim.system(command, { text = true, timeout = timeout }, function(result)
        vim.schedule(function()
          -- A command returning non-zero is a result, not a tool failure: the
          -- model needs the output either way, and `exit N` says what happened.
          context.finish(Registry.ok(render(result, max_lines)))
        end)
      end)

      return nil
    end,
  }
end

return M
