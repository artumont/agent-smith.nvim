--- The grep tool: search file contents.
---
--- Asynchronous: `vim.system` runs the search so a large repository does not
--- block the editor. The handler returns nil and answers through
--- `context.finish`.
---
--- Uses ripgrep when present and falls back to grep. Both emit the same
--- `path:line:text` shape, so the formatting below is shared.
---
--- Known limitation: this searches disk, so unsaved buffers are not visible to
--- it. The read tool handles that case; grep does not.

local Paths = require("agent-smith.tools.paths")
local Registry = require("agent-smith.tools.registry")

local M = {}

M.DEFAULT_MAX_RESULTS = 200

local function build_command(search_root, pattern, glob)
  if vim.fn.executable("rg") == 1 then
    -- --with-filename matters: given a single file, rg omits the path, and the
    -- renderer below needs path:line:text to be uniform.
    local command = { "rg", "--line-number", "--with-filename", "--no-heading", "--color=never", "--smart-case" }
    if glob then
      vim.list_extend(command, { "--glob", glob })
    end
    -- `--` so that a pattern beginning with a dash is not read as an option.
    vim.list_extend(command, { "--", pattern, search_root })
    return command
  end

  local command = { "grep", "-rn", "-I", "-H", "--color=never" }
  if glob then
    vim.list_extend(command, { "--include", glob })
  end
  vim.list_extend(command, { "--", pattern, search_root })
  return command
end

local function render(root, output, max_results)
  local rendered = {}
  local total = 0

  for line in output:gmatch("[^\n]+") do
    total = total + 1
    if total <= max_results then
      -- The search root is absolute in the output; show it relative.
      local path, row, text = line:match("^(.-):(%d+):(.*)$")
      if path then
        rendered[#rendered + 1] = ("%s:%s:%s"):format(Paths.display(root, path), row, text)
      else
        rendered[#rendered + 1] = line
      end
    end
  end

  if total > max_results then
    rendered[#rendered + 1] = ("... [%d more matches suppressed]"):format(total - max_results)
  end

  return table.concat(rendered, "\n")
end

--- Build the grep tool bound to a project root.
---@param options table { root: string, max_results: number|nil }
---@return table spec
function M.tool(options)
  local root = assert(options.root, "the grep tool needs a root")
  local default_max = options.max_results or M.DEFAULT_MAX_RESULTS

  return {
    name = "grep",
    description = "Search file contents with a regular expression. Returns path:line:text. Searches disk, not unsaved buffers.",
    access = Registry.READ,
    parameters = {
      pattern = {
        type = "string",
        required = true,
        description = "Regular expression to search for.",
      },
      path = {
        type = "string",
        description = "File or directory to search, relative to the project root. Defaults to the whole project.",
      },
      glob = { type = "string", description = 'Restrict to matching files, e.g. "*.lua".' },
      max_results = { type = "number", description = "Maximum matches to return." },
    },
    locate = function(arguments)
      return { kind = Registry.READ, path = Paths.resolve(root, arguments.path or ".") }
    end,
    handler = function(arguments, context)
      local search_root = Paths.resolve(root, arguments.path or ".")
      local command = build_command(search_root, arguments.pattern, arguments.glob)
      local max_results = arguments.max_results or default_max

      vim.system(command, { text = true }, function(result)
        vim.schedule(function()
          -- rg and grep both use 1 for "no matches" and 2 for an actual error.
          if result.code == 1 then
            context.finish(Registry.ok(("no matches for %q"):format(arguments.pattern)))
            return
          end

          if result.code ~= 0 then
            local stderr = vim.trim(result.stderr or "")
            context.finish(
              Registry.error(
                ("search failed (%s): %s"):format(tostring(result.code), stderr ~= "" and stderr or "no output")
              )
            )
            return
          end

          context.finish(Registry.ok(render(root, result.stdout or "", max_results)))
        end)
      end)

      return nil
    end,
  }
end

return M
