--- agent-smith.nvim — public API.
---
--- Two modes, no chat. See spec/decisions/0003-two-modes-no-chat.md.
--- The plugin owns the agent loop and the tools rather than wrapping a CLI and
--- parsing its output. See spec/decisions/0001-own-the-agent-loop.md.

local Config = require("agent-smith.config")

local M = {}

--- Plugin version. Pre-1.0 while the rewrite is in progress.
M.version = "0.2.0-dev"

--- Resolved configuration. Nil until setup() is called.
M.config = nil

local SUBCOMMANDS = { "info", "version" }

local function notify(message, level)
  vim.notify("agent-smith: " .. message, level or vim.log.levels.INFO)
end

--- Start an inline edit on the current selection.
---
--- Not implemented yet. See spec/decisions/0004-bounded-edit-with-escalation.md
--- for the intended behaviour.
function M.inline()
  notify("inline mode is not implemented yet", vim.log.levels.WARN)
end

--- Start a vibe run: plan, approve, execute, review.
---
--- Not implemented yet. See spec/decisions/0007-vibe-workflow.md.
function M.vibe()
  notify("vibe mode is not implemented yet", vim.log.levels.WARN)
end

--- Report the version and the resolved configuration.
function M.info()
  if not M.config then
    notify("not configured; call require('agent-smith').setup() first")
    return
  end
  notify(
    ("%s — sandbox %s — network %s"):format(
      M.version,
      M.config.sandbox.root,
      M.config.sandbox.network and "on" or "off"
    )
  )
end

local function handle_command(args)
  local subcommand = args.fargs[1]
  if subcommand == nil or subcommand == "info" then
    M.info()
  elseif subcommand == "version" then
    notify(M.version)
  else
    notify(
      ("unknown subcommand %q; expected one of: %s"):format(
        subcommand,
        table.concat(SUBCOMMANDS, ", ")
      ),
      vim.log.levels.ERROR
    )
  end
end

local function register_commands()
  vim.api.nvim_create_user_command("Smith", handle_command, {
    nargs = "*",
    desc = "agent-smith",
    complete = function(arg_lead)
      local matches = {}
      for _, name in ipairs(SUBCOMMANDS) do
        if name:sub(1, #arg_lead) == arg_lead then
          matches[#matches + 1] = name
        end
      end
      return matches
    end,
    force = true,
  })
end

local function register_keymaps()
  local maps = {
    { mode = "v", lhs = "<leader>as", rhs = M.inline, desc = "agent-smith inline edit" },
    { mode = "n", lhs = "<leader>av", rhs = M.vibe, desc = "agent-smith vibe" },
  }
  for _, map in ipairs(maps) do
    vim.keymap.set(map.mode, map.lhs, map.rhs, { desc = map.desc })
  end
end

--- Initialize the plugin.
---
---@param opts table|nil Configuration overrides; see agent-smith.config.
---@return table M The module table, for chaining.
function M.setup(opts)
  M.config = Config.resolve(opts)
  if M.config.commands then
    register_commands()
  end
  if M.config.default_keymaps then
    register_keymaps()
  end
  return M
end

return M
