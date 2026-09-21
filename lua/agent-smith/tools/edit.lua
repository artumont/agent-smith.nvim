--- The edit tool: replace a range of lines in a file.
---
--- Buffer-native by default, deliberately. The edit lands in a Neovim buffer and
--- the buffer is left modified; nothing is written to disk. Accepting the change
--- is a save, rejecting it is a buffer-revert, and that is what makes the
--- approval story real rather than cosmetic. See
--- spec/decisions/0005-permission-model.md.
---
--- `write_through`, for vibe. In a vibe run the clone is the staging area, so the
--- buffer is not where a change waits for acceptance — `git diff` is. That
--- inverts the reason for being buffer-native, so the tool takes the mode's answer
--- instead of assuming one. It is not optional in that mode either: `bash` runs
--- against the clone's files, so an edit that stayed in a buffer would leave the
--- agent testing code it had not actually changed.
---
--- `allow_create`, also for vibe, because a plan may declare a file it will
--- create. Creation writes straight to disk rather than going through a buffer: a
--- fresh Neovim buffer always holds one empty line, which would land in the new
--- file as a stray blank line and would then be what a later `read` reported.
---
--- Undo grouping
---
--- Several edits in one turn must revert with a single `u`, and the next turn
--- must not. Neovim already merges consecutive buffer edits into one undo
--- block, so grouping a turn together is free; the work is in *breaking* the
--- block when a new turn starts. Without that break the user's next undo would
--- revert a turn they had already accepted.
---
--- Reassigning `'undolevels'` to itself is the way to force the break; there is
--- no API for it. Verified by observation, not assumed: edits one and two land
--- at the same `seq_cur` with no intervention, and at different ones after the
--- reassignment.
---
--- The turn boundary comes from `context.turn`, supplied by the loop. It is not
--- inferred, because inferring it would merge successive turns into one block as
--- soon as the user accepted one and started another.
---
--- Stale line numbers
---
--- Line numbers are the model's, taken from a previous `read`. If an earlier
--- edit in the same turn shifted them, a later edit lands in the wrong place.
--- `expect` is an optional guard: the model states the text it believes is in
--- the range, and the edit is refused if it does not match. Optional, because
--- it costs prompt tokens on every edit.

local Paths = require("agent-smith.tools.paths")
local Registry = require("agent-smith.tools.registry")

local M = {}

--- Split replacement text into buffer lines.
---
--- An empty string deletes the range. One trailing newline is dropped, because
--- "the replacement text" almost never means "and a final empty line"; a second
--- trailing newline does survive, so a deliberate blank last line is expressible.
local function to_lines(text)
  local body = text
  if body:sub(-1) == "\n" then
    body = body:sub(1, -2)
  end
  if body == "" then
    return {}
  end
  return vim.split(body, "\n", { plain = true })
end

--- The buffer for a path, loading it from disk if it is not open yet.
local function buffer_for(absolute)
  local buffer = vim.fn.bufnr(absolute)
  if buffer == -1 then
    buffer = vim.fn.bufadd(absolute)
  end
  if not vim.api.nvim_buf_is_loaded(buffer) then
    vim.fn.bufload(buffer)
  end
  return buffer
end

--- Build the edit tool bound to a project root.
---@param options table
---   - root: string             Project root.
---   - write_through: boolean|nil  Write each edit to disk. For vibe.
---   - allow_create: boolean|nil   Permit a path that does not exist yet.
---@return table spec
function M.tool(options)
  local root = assert(options.root, "the edit tool needs a root")
  local write_through = options.write_through == true
  local allow_create = options.allow_create == true

  local description = "Replace a range of lines in a file."
  if write_through then
    description = description .. " The change is written to disk immediately."
  else
    description = description
      .. " Applies to an unsaved buffer; nothing is written to disk until the file is saved."
  end
  if allow_create then
    description = description .. " A path that does not exist is created."
  end

  -- Undo grouping state. Reset whenever the turn changes.
  local last_turn = nil
  local last_buffer = nil

  return {
    name = "edit",
    description = description,
    access = Registry.WRITE,
    parameters = {
      path = {
        type = "string",
        required = true,
        description = "File path, relative to the project root or absolute.",
      },
      start_row = {
        type = "number",
        required = true,
        description = "First line to replace, 1-indexed, inclusive. May be one past the last line to append.",
      },
      end_row = {
        type = "number",
        required = true,
        description = "Last line to replace, inclusive. Use start_row - 1 to insert without replacing anything.",
      },
      text = {
        type = "string",
        required = true,
        allow_empty = true,
        description = "Replacement text. An empty string deletes the range.",
      },
      expect = {
        type = "string",
        description = "Optional guard: the text the range is believed to hold. The edit is refused if it does not match.",
      },
    },
    locate = function(arguments)
      return {
        kind = Registry.WRITE,
        path = Paths.resolve(root, arguments.path),
        range = { start_row = arguments.start_row, end_row = arguments.end_row },
      }
    end,
    handler = function(arguments, context)
      local absolute = Paths.resolve(root, arguments.path)
      local shown = Paths.display(root, absolute)
      local start_row = math.floor(arguments.start_row)
      local end_row = math.floor(arguments.end_row)

      if vim.fn.filereadable(absolute) ~= 1 then
        if not allow_create then
          -- Creating files is a plan-level concern, not a line-range edit.
          return Registry.error(("%s does not exist"):format(shown))
        end

        -- A file the plan declared. It is empty, so an insertion is the only
        -- edit that can refer to lines that exist; anything else names lines
        -- that are not there.
        if not (start_row == 1 and end_row == 0) then
          return Registry.error(
            ("%s does not exist yet, so it is empty; create it with start_row 1 and end_row 0"):format(shown)
          )
        end

        local replacement = to_lines(arguments.text)
        local parent = vim.fs.dirname(absolute)
        local made = vim.fn.mkdir(parent, "p")
        if made == 0 and vim.fn.isdirectory(parent) ~= 1 then
          return Registry.error(("could not create the directory %s"):format(parent))
        end

        local wrote, write_error = pcall(vim.fn.writefile, replacement, absolute)
        if not wrote then
          return Registry.error(("could not create %s: %s"):format(shown, tostring(write_error)))
        end

        return Registry.ok(("%s: created with %d line(s)"):format(shown, #replacement))
      end

      if end_row < start_row - 1 then
        return Registry.error(
          ("end_row %d is before start_row %d; use start_row - 1 to insert"):format(end_row, start_row)
        )
      end

      local buffer = buffer_for(absolute)
      local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
      local total = #lines

      if start_row < 1 or start_row > total + 1 then
        return Registry.error(
          ("start_row %d is outside %s, which has %d lines"):format(start_row, shown, total)
        )
      end
      if end_row > total then
        return Registry.error(("end_row %d is past the end of %s, which has %d lines"):format(end_row, shown, total))
      end

      local removed = end_row - start_row + 1
      if removed < 0 then
        removed = 0
      end

      local current = vim.api.nvim_buf_get_lines(buffer, start_row - 1, end_row, false)
      local current_text = table.concat(current, "\n")

      if arguments.expect ~= nil and arguments.expect ~= current_text then
        return Registry.error(
          ("%s:%d-%d does not hold the expected text; refusing to edit a stale range\n--- expected ---\n%s\n--- found ---\n%s"):format(
            shown,
            start_row,
            end_row,
            arguments.expect,
            current_text
          )
        )
      end

      local replacement = to_lines(arguments.text)

      local continuing_turn = context.turn ~= nil
        and last_turn ~= nil
        and context.turn == last_turn
        and last_buffer == buffer

      vim.api.nvim_buf_call(buffer, function()
        if last_buffer == buffer and not continuing_turn then
          -- Force a new undo block, so the previous turn stays separately
          -- revertible. See the note at the top of this module.
          vim.o.undolevels = vim.o.undolevels
        end
        vim.api.nvim_buf_set_lines(buffer, start_row - 1, end_row, false, replacement)
      end)

      last_turn = context.turn
      last_buffer = buffer

      -- After the buffer, so a write failure leaves the buffer showing what was
      -- intended and the caller hears about it, rather than the two silently
      -- disagreeing.
      if write_through then
        local wrote, write_error = pcall(vim.api.nvim_buf_call, buffer, function()
          -- noautocmd because a filetype or formatter autocommand must not get
          -- to rewrite what the model asked for.
          vim.cmd("silent noautocmd write!")
        end)
        if not wrote then
          return Registry.error(("%s: the edit applied but could not be written: %s"):format(shown, tostring(write_error)))
        end
      end

      local new_total = total - removed + #replacement
      local action = removed == 0 and ("inserted %d line(s) at line %d"):format(#replacement, start_row)
        or ("replaced lines %d-%d (%d) with %d line(s)"):format(start_row, end_row, removed, #replacement)

      local state = write_through and "written to disk" or "unsaved"
      return Registry.ok(
        ("%s: %s; buffer now has %d lines and is %s"):format(shown, action, new_total, state)
      )
    end,
  }
end

return M
