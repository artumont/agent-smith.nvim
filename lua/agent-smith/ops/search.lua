--- agent-smith/ops/search.lua
---
--- Semantic search operation.
---
--- Flow:
--- 1. Open prompt window (or use additional_prompt)
--- 2. Build search instruction with output format
--- 3. Send to provider asynchronously
--- 4. Parse response into quickfix entries
--- 5. Populate quickfix list
---
--- Response format:
--- The AI must output lines like:
---   /path/to/file.lua:24:8,3,Some notes about this location
---
--- The parser (qfix-helpers.lua) extracts:
--- - filename: absolute path
--- - lnum: line number (1-based)
--- - col: column number (1-based)
--- - end_lnum: lnum + count - 1
--- - text: the note
---
--- Error handling:
--- - Empty response: "No search results found" notification
--- - Parse failure: Empty quickfix list (no error)
--- - Provider failure: Error notification with status

local Prompt = require("agent-smith.prompt")
local Qfix = require("agent-smith.ops.qfix-helpers")
local Statusline = require("agent-smith.statusline")

local M = {}

--- Run the search operation.
---
---@param state table Plugin state
---@param opts? table Options: { additional_prompt: string }
---@return nil
function M.run(state, opts)
  opts = opts or {}

  local function send(user)
    local context = Prompt.new(state, "search")
    Statusline.start(context, "Searching Codebase")
    context:start(user, {
      on_complete = function(status, response)
        Statusline.stop(context)
        if status ~= "success" then
          return vim.notify("Search failed: " .. status, vim.log.levels.ERROR)
        end

        local items = Qfix.parse(response)
        if #items == 0 then
          return vim.notify("No search results found")
        end

        vim.fn.setqflist({}, "r", {
          title = "Agent-Smith Search",
          items = items,
        })
        vim.cmd("copen")
      end,
    })
  end

  if opts.additional_prompt then
    send(opts.additional_prompt)
  else
    require("agent-smith.window.prompt-window").capture("Search", {
      cb = function(ok, text)
        if ok and vim.trim(text) ~= "" then
          send(text)
        end
      end,
    })
  end
end

return M
