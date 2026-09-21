--- The diagnostics tool: report LSP diagnostics.
---
--- This is the tool that closes the loop. Without it the agent edits blind; with
--- it, a change that breaks a type produces feedback the model can act on in the
--- same request.
---
--- Diagnostics only exist for buffers Neovim has open, since they come from
--- language servers attached to buffers. A path that is not open has nothing to
--- report, which is reported as such rather than as an empty success.

local Paths = require("agent-smith.tools.paths")
local Registry = require("agent-smith.tools.registry")

local M = {}

M.DEFAULT_MAX_RESULTS = 100

--- Severity names, lowest number is most severe, matching vim.diagnostic.
M.SEVERITIES = { "error", "warning", "information", "hint" }

local SEVERITY_NUMBER = { error = 1, warning = 2, information = 3, hint = 4 }
local SEVERITY_NAME = { "ERROR", "WARN", "INFO", "HINT" }

--- Paths of every buffer Neovim has open.
local function open_buffer_paths()
  local paths = {}
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" then
        paths[#paths + 1] = vim.fs.normalize(name)
      end
    end
  end
  return paths
end

--- Build the diagnostics tool bound to a project root.
---@param options table { root: string, max_results: number|nil }
---@return table spec
function M.tool(options)
  local root = assert(options.root, "the diagnostics tool needs a root")
  local default_max = options.max_results or M.DEFAULT_MAX_RESULTS

  return {
    name = "diagnostics",
    description = "Get LSP diagnostics for open buffers. Use after editing to check for errors.",
    access = Registry.READ,
    parameters = {
      path = { type = "string", description = "Limit to one open file, relative to the project root." },
      severity = {
        type = "string",
        enum = M.SEVERITIES,
        description = "Least severe level to include. Defaults to warning.",
      },
      max_results = { type = "number", description = "Maximum diagnostics to return." },
    },
    locate = function(arguments)
      if arguments.path then
        return { kind = Registry.READ, path = Paths.resolve(root, arguments.path) }
      end
      return { kind = Registry.READ, paths = open_buffer_paths() }
    end,
    handler = function(arguments)
      local threshold = SEVERITY_NUMBER[arguments.severity or "warning"]
      local max_results = arguments.max_results or default_max

      local buffers = {}
      if arguments.path then
        local absolute = Paths.resolve(root, arguments.path)
        local buffer = vim.fn.bufnr(absolute)
        if buffer == -1 or not vim.api.nvim_buf_is_loaded(buffer) then
          return Registry.error(
            ("%s is not open, so it has no diagnostics; only open buffers do"):format(
              Paths.display(root, absolute)
            )
          )
        end
        buffers = { buffer }
      else
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(buffer) then
            buffers[#buffers + 1] = buffer
          end
        end
      end

      local found = {}
      for _, buffer in ipairs(buffers) do
        local name = vim.api.nvim_buf_get_name(buffer)
        if name ~= "" then
          for _, diagnostic in ipairs(vim.diagnostic.get(buffer)) do
            if diagnostic.severity <= threshold then
              found[#found + 1] = {
                path = Paths.display(root, name),
                row = diagnostic.lnum + 1,
                col = diagnostic.col + 1,
                severity = SEVERITY_NAME[diagnostic.severity] or "UNKNOWN",
                message = diagnostic.message,
                source = diagnostic.source,
                code = diagnostic.code,
              }
            end
          end
        end
      end

      if #found == 0 then
        return Registry.ok(
          ("no diagnostics at or above %s"):format(arguments.severity or "warning")
        )
      end

      table.sort(found, function(left, right)
        if left.path ~= right.path then
          return left.path < right.path
        end
        if left.row ~= right.row then
          return left.row < right.row
        end
        return left.col < right.col
      end)

      local rendered = {}
      for index = 1, math.min(#found, max_results) do
        local entry = found[index]
        local suffix = entry.source and (" [%s]"):format(entry.source) or ""
        rendered[#rendered + 1] = ("%s:%d:%d: %s: %s%s"):format(
          entry.path,
          entry.row,
          entry.col,
          entry.severity,
          entry.message,
          suffix
        )
      end

      if #found > max_results then
        rendered[#rendered + 1] = ("... [%d more suppressed]"):format(#found - max_results)
      end

      return Registry.ok(table.concat(rendered, "\n"))
    end,
  }
end

return M
