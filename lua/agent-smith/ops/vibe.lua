--- agent-smith/ops/vibe.lua
---
--- Two-phase sandboxed Vibe workflow:
--- 1. Copy current project state into a temporary session.
--- 2. Ask model for plan and editable file scope.
--- 3. User approves plan.
--- 4. Model executes only inside sandbox.
--- 5. Agent-Smith diffs sandbox and original, then asks approval per file.

local Prompt = require("agent-smith.prompt")
local Prompts = require("agent-smith.prompts")
local Qfix = require("agent-smith.ops.qfix-helpers")
local Multi = require("agent-smith.ops.multi-file")
local Session = require("agent-smith.ops.vibe-session")
local PlanWindow = require("agent-smith.window.plan-window")
local Statusline = require("agent-smith.statusline")

local M = {}
local results_namespace = vim.api.nvim_create_namespace("agent-smith.vibe-results")

local function configure_results_window()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].buftype == "quickfix" then
      local header = " Agent-Smith Vibe Results "
      local controls = " <CR> open location   q / Esc close "
      vim.api.nvim_buf_set_extmark(buf, results_namespace, 0, 0, {
        virt_lines_above = true,
        virt_lines = {
          { { header, "Title" } },
          { { controls, "Comment" } },
          { { "", "Normal" } },
        },
      })
      vim.wo[win].winbar = header .. "|" .. controls
      local function close()
        if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
      end
      vim.keymap.set("n", "q", close, {
        buffer = buf, nowait = true, desc = "Close Agent-Smith Vibe results",
      })
      vim.keymap.set("n", "<Esc>", close, {
        buffer = buf, nowait = true, desc = "Close Agent-Smith Vibe results",
      })
      return
    end
  end
end

local function request_context(state, session, instruction, progress, phase)
  local context = Prompt.new(state, "vibe")
  context.cwd = session.root
  context.full_path = session.current_file
  -- BaseProvider uses this metadata to mount original project read-only when
  -- Bubblewrap is available. Vibe still owns cleanup and diff collection.
  context._sandbox = session
  -- Providers should use paths relative to cwd. Exposing the absolute temp path
  -- can trigger external-directory permission checks in agent harnesses.
  context.file_reference = session.current_relative or "."
  context.instruction = instruction
  context.vibe_phase = phase
  context:set_progress(progress)
  return context
end

local function failure(label, session, status, response)
  Session.cleanup(session)
  local details = vim.trim(response or "")
  local message = label .. " " .. status
  if details ~= "" then message = message .. ":\n" .. details end
  vim.notify(message, vim.log.levels.ERROR)
end

local function show_analysis_results(session, response)
  response = Session.remap_response(session, response)
  local items = Qfix.parse(response)
  Session.cleanup(session)
  if #items == 0 then
    vim.notify("Vibe completed without sandbox changes or locations:\n" .. vim.trim(response), vim.log.levels.INFO)
    return
  end
  vim.fn.setqflist({}, "r", { title = "Agent-Smith Vibe", items = items })
  vim.cmd("copen")
  configure_results_window()
end

local function execute_plan(state, session, user, plan)
  local context = request_context(
    state,
    session,
    Prompts.vibe_execute(plan.raw, plan.files),
    "Executing Vibe",
    "execute"
  )
  Statusline.start(context, "Executing Vibe")
  context:start(user, {
    on_complete = function(status, response)
      Statusline.stop(context)
      if status ~= "success" then
        failure("Vibe execution", session, status, response)
        return
      end

      local proposals, unauthorized = Session.collect_changes(session, plan.files)
      if #unauthorized > 0 then
        vim.notify(
          "Agent-Smith ignored sandbox changes outside approved scope:\n- "
            .. table.concat(unauthorized, "\n- "),
          vim.log.levels.WARN
        )
      end

      if #proposals == 0 then
        show_analysis_results(session, response)
        return
      end

      Multi.approve_all(proposals, function(applied, total)
        Session.cleanup(session)
        vim.notify(string.format("Applied %d of %d sandboxed Vibe changes", applied, total))
      end)
    end,
  })
end

local function start_session(state, user)
  local ok, session = pcall(Session.create, vim.api.nvim_buf_get_name(0), state:tmp_dir())
  if not ok then
    vim.notify("Unable to create Vibe sandbox: " .. tostring(session), vim.log.levels.ERROR)
    return
  end

  local context = request_context(state, session, Prompts.vibe_plan(), "Planning Vibe", "plan")
  Statusline.start(context, "Planning Vibe")
  context:start(user, {
    on_complete = function(status, response)
      Statusline.stop(context)
      if status ~= "success" then
        failure("Vibe planning", session, status, response)
        return
      end

      local plan, parse_error = Session.parse_plan(response)
      if not plan then
        failure("Vibe planning failed", session, "invalid response", parse_error .. "\n\n" .. response)
        return
      end

      PlanWindow.review(plan, function(approved)
        if not approved then
          Session.cleanup(session)
          return
        end
        local refresh_ok, fresh_session = pcall(Session.recreate, session)
        if not refresh_ok then
          Session.cleanup(session)
          vim.notify("Unable to refresh Vibe sandbox: " .. tostring(fresh_session), vim.log.levels.ERROR)
          return
        end
        execute_plan(state, fresh_session, user, plan)
      end)
    end,
  })
end

---@param state table Plugin state
---@param opts? table Options: { additional_prompt: string }
function M.run(state, opts)
  opts = opts or {}
  if opts.additional_prompt then
    start_session(state, opts.additional_prompt)
    return
  end

  require("agent-smith.window.prompt-window").capture("Vibe", {
    cb = function(ok, text)
      if ok and vim.trim(text) ~= "" then start_session(state, text) end
    end,
  })
end

return M
