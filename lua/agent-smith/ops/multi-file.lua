--- agent-smith/ops/multi-file.lua
---
--- Multi-file edit protocol: parse AI responses and present each file change
--- for user approval before application.
---
--- Protocol format:
--- The AI outputs structured blocks like:
---   <FILE_CHANGE>/absolute/path/to/file.lua</FILE_CHANGE>
---   <CONTENT>
---   -- full replacement content for this file
---   </CONTENT>
---   <FILE_CHANGE>/absolute/path/to/other.lua</FILE_CHANGE>
---   <CONTENT>
---   -- content for another file
---   </CONTENT>
---
--- Why delimited text (not JSON)?
--- - All AI providers can output structured text; JSON requires specific prompting
--- - Simpler to parse in Lua (no json.decode dependency)
--- - More forgiving of minor formatting issues
--- - Matches the pattern established by 99's quickfix format
---
--- Staleness detection:
--- Before applying a change, we compare the file's current content against
--- what the AI likely saw (stored as "snapshot" when parsing). If the file
--- changed since the AI read it, we warn the user.
---
--- Edge case: If the file didn't exist when parsed, snapshot is nil and
--- staleness check is skipped (we can't compare against nothing).
---
--- Edge case: If two concurrent multi-file edits target the same file,
--- the second one will see the first one's changes as "staleness". This
--- is the correct behavior - the user should know the file changed.
---
--- Approval flow:
--- Changes are processed sequentially. For each:
--- 1. Show file path and content in approval window
--- 2. User presses <CR> (approve), q (reject), or Q (reject all)
--- 3. If approved: write file, increment applied count
--- 4. If rejected: skip, continue to next
--- 5. If reject_all: skip all remaining
--- After all changes: notify "Applied X of Y file changes"
---
--- Error handling:
--- - Malformed blocks (missing path, empty content) are silently skipped
--- - Files that don't exist: approval still works (file will be created)
--- - Files that aren't writable: write fails silently, applied count unaffected

local Approval = require("agent-smith.window.approval-window")

local M = {}

--- Parse multi-file changes from AI response text.
---
--- Extracts <FILE_CHANGE>...</FILE_CHANGE><CONTENT>...</CONTENT> blocks.
--- Each valid block becomes a change entry with path, content, and snapshot.
---
---@param text string The raw AI response
---@return table[] changes Array of { path, content, snapshot }
function M.parse(text)
  local changes = {}

  for path, content in text:gmatch(
    "<FILE_CHANGE>%s*(.-)%s*</FILE_CHANGE>%s*<CONTENT>%s*(.-)%s*</CONTENT>"
  ) do
    if vim.fs.isabspath(path) and content ~= "" then
      -- Snapshot current file content for staleness detection
      local ok, lines = pcall(vim.fn.readfile, path)
      table.insert(changes, {
        path = path,
        content = content,
        snapshot = ok and table.concat(lines, "\n") or nil,
      })
    end
  end

  return changes
end

--- Present all changes for sequential approval and apply approved ones.
---
--- Processes changes one at a time. Each gets its own approval window.
--- Supports approve (apply), reject (skip), and reject_all (skip remaining).
---
--- Staleness check: If the file has changed since the AI read it, we
--- ask the user to confirm before applying anyway.
---
---@param changes table[] Array of { path, content, snapshot }
---@param done function Callback: done(applied_count, total_count)
---@return nil
function M.approve_all(changes, done)
  local i = 1
  local applied = 0
  local reject_all = false

  local function next_change()
    local change = changes[i]
    if not change or reject_all then
      return done(applied, #changes)
    end

    Approval.approve(change, function(action)
      if action == "reject_all" then
        reject_all = true
      elseif action == "approve" then
        -- Staleness check: did the file change since the AI read it?
        local current = nil
        if vim.fn.filereadable(change.path) == 1 then
          current = table.concat(vim.fn.readfile(change.path), "\n")
        end

        if change.snapshot and current ~= change.snapshot then
          local choice = vim.fn.confirm(
            change.path .. " changed during approval. Apply anyway?",
            "&Yes\n&No"
          )
          if choice ~= 1 then
            i = i + 1
            return next_change()
          end
        end

        -- Apply the change
        local ok = pcall(
          vim.fn.writefile,
          vim.split(change.content, "\n", { plain = true }),
          change.path
        )
        if ok then applied = applied + 1 end
      end

      i = i + 1
      next_change()
    end)
  end

  next_change()
end

return M
