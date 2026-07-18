--- agent-smith/ops/search.lua
---
--- Semantic search operation.
---
--- Flow:
--- 1. Open prompt window (or use additional_prompt)
--- 2. Build search instruction with output format
--- 3. Send to provider asynchronously
--- 4. Parse response into location entries
--- 5. Open results in a Telescope/fzf-lua fuzzy picker
--- 6. Fall back to quickfix when no fuzzy backend is installed
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

local function open_result(item)
  if vim.fn.filereadable(item.filename) ~= 1 then
    vim.notify("Search result file does not exist: " .. item.filename, vim.log.levels.WARN)
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
  pcall(vim.api.nvim_win_set_cursor, 0, {
    math.max(1, item.lnum or 1),
    math.max(0, (item.col or 1) - 1),
  })
  vim.cmd("normal! zz")
end

local function open_fuzzy_results(items)
  local backends = {
    "agent-smith.extensions.telescope",
    "agent-smith.extensions.fzf-lua",
  }
  for _, module in ipairs(backends) do
    local ok, backend = pcall(require, module)
    if ok and backend.search_results then
      local opened_ok, opened = pcall(backend.search_results, items, open_result)
      if opened_ok and opened then return true end
    end
  end
  return false
end

--- Run the search operation.
---
---@param state table Plugin state
---@param opts? table Options: { additional_prompt: string }
---@return nil
function M.run(state, opts)
  opts = opts or {}

  local function send(user)
    local context = Prompt.new(state, "search")
    context.cwd = vim.fs.root(context.full_path, ".git") or vim.fn.getcwd()
    Statusline.start(context, "Searching Codebase")
    context:start(user, {
      on_complete = function(status, response)
        Statusline.stop(context)
        if status ~= "success" then
          return vim.notify("Search failed: " .. status, vim.log.levels.ERROR)
        end

        local items = Qfix.parse(response, context.cwd)
        if #items == 0 then
          return vim.notify("No search results found")
        end

        vim.fn.setqflist({}, "r", {
          title = "Agent-Smith Search",
          items = items,
        })
        if not open_fuzzy_results(items) then
          vim.notify(
            "Fuzzy search picker unavailable; opening quickfix",
            vim.log.levels.INFO
          )
          vim.cmd("copen")
        end
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
