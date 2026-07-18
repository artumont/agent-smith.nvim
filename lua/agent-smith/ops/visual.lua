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
--- - Concurrent edits: If the user starts another edit while one is in
---   flight, both may try to modify the same buffer. This is a known
---   limitation. The user can cancel the first edit before starting a new one.

local Prompt = require("agent-smith.prompt")
local Imports = require("agent-smith.imports.detector")
local Multi = require("agent-smith.ops.multi-file")
local Response = require("agent-smith.ops.response")
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
    vim.notify("Agent-Smith: select code first", vim.log.levels.WARN)
    return
  end

  -- Open prompt window and wait for user input
  require("agent-smith.window.prompt-window").capture("Visual", {
    cb = function(ok, user)
      if not ok or vim.trim(user) == "" then return end

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
      })
      local bottom_status = InlineStatus.new("Implementing", {
        buffer = context.buffer,
        row = end_row,
        col = 0,
        above = false,
      })
      top_status:start()
      bottom_status:start()
      Statusline.start(context, "Implementing")

      context:start(user, {
        on_stdout = function(line)
          top_status:push(line)
          bottom_status:push(line)
        end,
        on_complete = function(status, response)
          top_status:stop()
          bottom_status:stop()
          Statusline.stop(context)

          if status ~= "success" then
            local details = vim.trim(response or "")
            local message = "Agent-Smith request " .. status
            if details ~= "" then message = message .. ":\n" .. details end
            return vim.notify(message, vim.log.levels.ERROR)
          end

          -- Multi-file mode: parse and present each file change
          if opts.multi_file then
            local changes = Multi.parse(response)
            if #changes == 0 then
              return vim.notify(
                "No valid multi-file changes returned",
                vim.log.levels.WARN
              )
            end
            return Multi.approve_all(changes, function(applied, total)
              vim.notify(
                string.format("Applied %d of %d file changes", applied, total)
              )
            end)
          end

          -- Single-file mode: replace visual selection
          if vim.trim(response) == "" then
            return vim.notify(
              "Agent-Smith returned empty response",
              vim.log.levels.WARN
            )
          end

          -- Models sometimes ignore the code-only rule and emit ```lua fences.
          -- Remove a complete outer fence before import detection or replacement.
          response = Response.unwrap_code_fence(response)

          -- Extract imports and code body
          local ft = vim.bo[context.buffer].filetype
          local imports, body = Imports.extract(response, ft)

          -- Insert imports at file's import section
          Imports.insert(context.buffer, imports, ft)

          -- Replace the visual selection with the code body. Marks can become
          -- invalid if the buffer changed while the request was running.
          if not context.range:replace_text(body) then
            vim.notify(
              "Agent-Smith: selection changed before response arrived; edit was not applied",
              vim.log.levels.WARN
            )
          end
        end,
      })
    end,
  })
end

return M
