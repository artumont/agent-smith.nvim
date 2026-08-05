--- agent-smith/ops/visual.lua
---
--- Visual selection code replacement operation.
---
--- Flow:
--- 1. Capture visual selection -> Prompt object with Range
--- 2. Open floating prompt window for user input
--- 3. Show status indicator ("implementing...")
--- 4. Assemble context and send to provider asynchronously
--- 5. On response:
---    - If multi_file mode: parse FILE_CHANGE blocks, present for approval
---    - Otherwise: extract imports -> place at file top -> replace selection body
---
--- Import handling:
--- The AI response may contain import statements that belong at the top of
--- the file, not inside the visual selection. The imports/detector module
--- handles this automatically:
--- 1. Response is classified into imports[] and body[]
--- 2. Imports are inserted at the file's import section boundary
--- 3. Body replaces the visual selection
---
--- This is the "import exception" to the bounded editing scope principle.
--- Without it, adding a new dependency would require a separate manual step.
---
--- Multi-file mode:
--- When multi_file option is set, the AI is instructed to output structured
--- <FILE_CHANGE>/<CONTENT> blocks instead of plain code. Each block is
--- presented to the user for approval via the approval window.
---
--- Potential pitfalls:
--- - Selection validity: The visual selection marks are captured in
---   Prompt.new(). If the user modifies the buffer before the AI response
---   arrives, the marks may be invalid. The replace_text() call will fail
---   gracefully in this case.
--- - Empty response: If the AI returns an empty response, we notify the
---   user and do not modify the buffer. This prevents accidental deletions.
--- - Provider errors: Provider failures (non-zero exit, crashes) result
---   in "failed" status. We show an error notification and do not modify
---   the buffer.
--- - Concurrent edits: Requests for same buffer run FIFO. Their selection
---   anchors move with earlier edits, so each response applies in order.

local Prompt = require("agent-smith.prompt")
local Imports = require("agent-smith.imports.detector")
local Multi = require("agent-smith.ops.multi-file")
local Response = require("agent-smith.ops.response")
local Queue = require("agent-smith.ops.visual-queue")
local Statusline = require("agent-smith.statusline")

local M = {}

--- Run the visual edit operation.
---
---@param state table The plugin state singleton
---@param opts? table Options: { multi_file: boolean }
---@return nil
function M.run(state, opts)
  opts = opts or {}
  local context = Prompt.new(state, "visual")

  -- Guard: must have a visual selection
  if not context.range or context.range:to_text() == "" then
    if context.range then context.range:clear() end
    vim.notify("Agent-Smith: select code first", vim.log.levels.WARN)
    return
  end

  -- Open prompt window and wait for user input
  require("agent-smith.window.prompt-window").capture("Visual", {
    cb = function(ok, user)
      if not ok or vim.trim(user) == "" then
        context.range:clear()
        return
      end

      -- Bracket the selection with inline status lines, like 99. The top
      -- extmark renders above the first selected row; the bottom one renders
      -- below the final selected row. Both move with buffer edits.
      local start_row, _, end_row = context.range:_api_positions()
      if not start_row then
        return vim.notify("Agent-Smith: visual selection is no longer valid", vim.log.levels.WARN)
      end
      local InlineStatus = require("agent-smith.window.status-window")
      local top_status = InlineStatus.new("Implementing", {
        buffer = context.buffer,
        row = start_row,
        col = 0,
        above = true,
        show_output = true,
      })
      local bottom_status = InlineStatus.new("Implementing", {
        buffer = context.buffer,
        row = end_row,
        col = 0,
        above = false,
      })
      top_status:start()
      bottom_status:start()
      context:set_progress("Queued implementation")
      state.tracking:queue(context)
      Statusline.start(context, "Implementing")

      local finished = false
      local done_callback
      local function finish()
        if finished then return end
        finished = true
        context._cancel_queued = nil
        top_status:stop()
        bottom_status:stop()
        Statusline.stop(context)
        context.range:clear()
        if done_callback then done_callback() end
      end

      -- Keep status visible for queued work too. Statusline counts all visual
      -- requests as "Implementing (n)" while this buffer drains FIFO.
      local cancel_queued
      context._cancel_queued = function()
        if not cancel_queued or not cancel_queued() then return false end
        state.tracking:complete(context)
        finish()
        return true
      end
      cancel_queued = Queue.enqueue(context.buffer, function(done)
        done_callback = done
        context._cancel_queued = nil
        context:set_progress("Preparing implementation")
        context:start(user, {
          on_stdout = function(line)
            top_status:push(line)
            bottom_status:push(line)
          end,
          on_complete = function(status, response)
            if status ~= "success" then
              local details = vim.trim(response or "")
              local message = "Agent-Smith request " .. status
              if details ~= "" then message = message .. ":\n" .. details end
              vim.notify(message, vim.log.levels.ERROR)
              return finish()
            end

            -- Multi-file mode: wait for approval before next same-buffer job.
            if opts.multi_file then
              local changes = Multi.parse(response)
              if #changes == 0 then
                vim.notify("No valid multi-file changes returned", vim.log.levels.WARN)
                return finish()
              end
              return Multi.approve_all(changes, function(applied, total)
                vim.notify(string.format("Applied %d of %d file changes", applied, total))
                finish()
              end)
            end

            if vim.trim(response) == "" then
              vim.notify("Agent-Smith returned empty response", vim.log.levels.WARN)
              return finish()
            end

            -- Normalize fenced output defensively. Malformed or empty fenced
            -- responses must never replace the selection.
            local normalized, validation_error = Response.normalize_replacement(response)
            if not normalized then
              vim.notify(
                "Agent-Smith rejected provider response: " .. validation_error,
                vim.log.levels.WARN
              )
              return finish()
            end

            local ft = vim.bo[context.buffer].filetype
            local imports, body = Imports.extract(normalized, ft)
            local body_text = table.concat(body, "\n")
            if vim.trim(body_text) == "" then
              vim.notify("Agent-Smith rejected empty replacement", vim.log.levels.WARN)
              return finish()
            end

            local selected_text = context.range:to_text()
            if selected_text == "" then
              vim.notify(
                "Agent-Smith: selection changed before response arrived; edit was not applied",
                vim.log.levels.WARN
              )
              return finish()
            end

            if body_text == selected_text and #imports == 0 then
              vim.notify("Agent-Smith returned no changes", vim.log.levels.INFO)
              return finish()
            end

            -- Replace first so a stale range cannot leave import-only changes.
            if not context.range:replace_text(body) then
              vim.notify(
                "Agent-Smith: selection changed before response arrived; edit was not applied",
                vim.log.levels.WARN
              )
              return finish()
            end
            Imports.insert(context.buffer, imports, ft)
            finish()
          end,
        })
      end)
    end,
  })
end

return M
