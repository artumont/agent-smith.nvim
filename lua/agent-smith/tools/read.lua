--- The read tool: read a file, or a range of one.
---
--- Prefers loaded buffer contents over disk, so that unsaved edits are visible
--- to the agent. That is the whole reason this tool exists rather than the
--- agent shelling out to cat.
---
--- Output is numbered, `N| text`, 1-indexed, because the line numbers are what
--- the edit tool addresses later. Truncation is reported rather than silent.

local Paths = require("agent-smith.tools.paths")
local Outline = require("agent-smith.outline")
local Registry = require("agent-smith.tools.registry")

local M = {}

M.DEFAULT_MAX_LINES = 2000

--- Lines from a loaded buffer whose name matches, or nil.
local function buffer_lines(absolute)
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) then
      local name = vim.api.nvim_buf_get_name(buffer)
      if name ~= "" and vim.fs.normalize(name) == absolute then
        return vim.api.nvim_buf_get_lines(buffer, 0, -1, false), buffer
      end
    end
  end
  return nil, nil
end

--- Build the read tool bound to a project root.
---@param options table { root: string, max_lines: number|nil }
---@return table spec
function M.tool(options)
  local root = assert(options.root, "the read tool needs a root")
  local max_lines = options.max_lines or M.DEFAULT_MAX_LINES

  return {
    name = "read",
    description = "Read a file as numbered lines (1-indexed). Prefers the unsaved buffer over disk.",
    access = Registry.READ,
    parameters = {
      path = {
        type = "string",
        required = true,
        description = "File path, relative to the project root or absolute.",
      },
      start_row = { type = "number", description = "First line to return, 1-indexed." },
      end_row = { type = "number", description = "Last line to return, inclusive." },
      outline = {
        type = "boolean",
        description = "Return a symbol outline with line ranges instead of contents. Use this first on a large file, then read the ranges you need.",
      },
    },
    locate = function(arguments)
      return { kind = Registry.READ, path = Paths.resolve(root, arguments.path) }
    end,
    handler = function(arguments)
      local absolute = Paths.resolve(root, arguments.path)
      local shown = Paths.display(root, absolute)

      if vim.fn.isdirectory(absolute) == 1 then
        return Registry.error(("%s is a directory"):format(shown))
      end

      local lines, buffer = buffer_lines(absolute)
      local unsaved = false

      if lines == nil then
        local ok, read = pcall(vim.fn.readfile, absolute)
        if not ok then
          return Registry.error(("cannot read %s: %s"):format(shown, tostring(read)))
        end
        lines = read
      else
        unsaved = buffer ~= nil and vim.bo[buffer].modified
      end

      -- Tiered read: the shape of the file first, then the ranges that matter.
      -- An outline is a few hundred bytes where the file may be tens of
      -- kilobytes, and a tool result is re-sent on every later turn.
      if arguments.outline then
        local outline = Outline.for_file({ path = absolute, lines = lines, buffer = buffer })
        return Registry.ok(Outline.render(outline, shown))
      end

      local total = #lines
      if total == 0 then
        return Registry.ok(("%s is empty%s"):format(shown, unsaved and " (unsaved buffer)" or ""))
      end

      local first = math.max(1, math.floor(arguments.start_row or 1))
      local last = math.min(total, math.floor(arguments.end_row or total))
      if first > total then
        return Registry.error(("start_row %d is past the end of %s, which has %d lines"):format(first, shown, total))
      end
      if last < first then
        return Registry.error(("end_row %d is before start_row %d"):format(last, first))
      end

      local truncated = false
      if last - first + 1 > max_lines then
        last = first + max_lines - 1
        truncated = true
      end

      local rendered = {}
      for row = first, last do
        rendered[#rendered + 1] = ("%d| %s"):format(row, lines[row])
      end

      if truncated then
        rendered[#rendered + 1] = ("... [truncated at %d lines; file has %d, next line is %d]"):format(
          max_lines,
          total,
          last + 1
        )
      end

      if unsaved then
        rendered[#rendered + 1] = "... [from the unsaved buffer, not disk]"
      end

      return Registry.ok(table.concat(rendered, "\n"))
    end,
  }
end

return M
