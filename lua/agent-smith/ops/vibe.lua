--- agent-smith/ops/vibe.lua
---
--- Vibe mode: open-ended AI analysis with quickfix output.
---
--- Difference from search:
--- - Search: Find specific locations matching a description
--- - Vibe: Perform an action and report what was done/found
---
--- Both use the same quickfix output format, but vibe is more open-ended.
---
--- Use cases:
--- - "Analyze all error handling patterns in this project"
--- - "Review recent commits and summarize changes"
--- - "Find potential bugs in the auth module"
--- - "Check for missing tests in the API layer"
---
--- Response format:
--- Same as search: /path/to/file:line:col,count,note

local Prompt = require("agent-smith.prompt")
local Qfix = require("agent-smith.ops.qfix-helpers")

local M = {}
local results_namespace = vim.api.nvim_create_namespace("agent-smith.vibe-results")

--- Configure the Quickfix window opened for Vibe results.
---
--- Vibe returns code locations, not multi-file approval proposals. The normal
--- Quickfix list keeps standard location navigation while this header explains
--- what is being displayed and makes closing it discoverable.
local function configure_results_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "quickfix" then
      local header = " Agent-Smith Vibe Results "
      local controls = " <CR> open location   q / Esc close "
      -- Winbars can be hidden by user UI configuration. Virtual lines keep
      -- this header and its controls visible inside the Quickfix buffer.
      vim.api.nvim_buf_set_extmark(buf, results_namespace, 0, 0, {
        virt_lines_above = true,
        virt_lines = {
          { { header, "Title" } },
          { { controls, "Comment" } },
          { { "", "Normal" } },
        },
      })
      vim.wo[win].winbar = header .. "|" .. controls
      vim.keymap.set("n", "q", function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      end, { buffer = buf, nowait = true, desc = "Close Agent-Smith Vibe results" })
      vim.keymap.set("n", "<Esc>", function()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      end, { buffer = buf, nowait = true, desc = "Close Agent-Smith Vibe results" })
      return
    end
  end
end

--- Run the vibe operation.
---
---@param state table Plugin state
---@param opts? table Options: { additional_prompt: string }
---@return nil
function M.run(state, opts)
  opts = opts or {}

  local function send(user)
    local context = Prompt.new(state, "vibe")
    local Statusline = require("agent-smith.statusline")
    Statusline.start(context, "Vibing")
    context:start(user, {
      on_complete = function(status, response)
        Statusline.stop(context)
        if status ~= "success" then
          return vim.notify("Vibe failed: " .. status, vim.log.levels.ERROR)
        end

        local items = Qfix.parse(response)
        if #items > 0 then
          vim.fn.setqflist({}, "r", {
            title = "Agent-Smith Vibe",
            items = items,
          })
          vim.cmd("copen")
          configure_results_window()
        else
          vim.notify("Vibe completed without locations")
        end
      end,
    })
  end

  if opts.additional_prompt then
    send(opts.additional_prompt)
  else
    require("agent-smith.window.prompt-window").capture("Vibe", {
      cb = function(ok, text)
        if ok and vim.trim(text) ~= "" then
          send(text)
        end
      end,
    })
  end
end

return M
