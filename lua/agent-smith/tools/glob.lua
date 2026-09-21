--- The glob tool: find files by name pattern.
---
--- Synchronous `vim.fn.glob`, which is fast enough for this and needs no
--- external process. Reports truncation rather than silently dropping results.

local Paths = require("agent-smith.tools.paths")
local Registry = require("agent-smith.tools.registry")

local M = {}

M.DEFAULT_MAX_RESULTS = 200

--- Build the glob tool bound to a project root.
---@param options table { root: string, max_results: number|nil }
---@return table spec
function M.tool(options)
  local root = assert(options.root, "the glob tool needs a root")
  local default_max = options.max_results or M.DEFAULT_MAX_RESULTS

  return {
    name = "glob",
    description = 'Find files by glob pattern, e.g. "**/*.lua" or "src/*.c". Returns paths relative to the project root.',
    access = Registry.READ,
    parameters = {
      pattern = { type = "string", required = true, description = "Glob pattern, e.g. **/*.lua." },
      max_results = { type = "number", description = "Maximum paths to return." },
    },
    locate = function(arguments)
      return { kind = Registry.READ, path = root }
    end,
    handler = function(arguments)
      local max_results = arguments.max_results or default_max

      -- joinpath keeps an absolute-looking pattern inside the root.
      local matches = vim.fn.glob(vim.fs.joinpath(root, arguments.pattern), false, true)
      table.sort(matches)

      local files = {}
      for _, match in ipairs(matches) do
        if vim.fn.filereadable(match) == 1 then
          files[#files + 1] = Paths.display(root, match)
        end
      end

      if #files == 0 then
        return Registry.ok(("no files match %q"):format(arguments.pattern))
      end

      local rendered = {}
      for index = 1, math.min(#files, max_results) do
        rendered[#rendered + 1] = files[index]
      end
      if #files > max_results then
        rendered[#rendered + 1] = ("... [%d more files suppressed]"):format(#files - max_results)
      end

      return Registry.ok(table.concat(rendered, "\n"))
    end,
  }
end

return M
