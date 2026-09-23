--- agent-smith.nvim — public API.
---
--- Two modes, no chat. See spec/decisions/0003-two-modes-no-chat.md.
--- The plugin owns the agent loop and the tools rather than wrapping a CLI and
--- parsing its output. See spec/decisions/0001-own-the-agent-loop.md.

local Config = require("agent-smith.config")

local M = {}

M.version = "0.2.0"

--- Resolved configuration. Nil until setup() is called.
M.config = nil

local SUBCOMMANDS = { "info", "model", "monitor", "provider", "setup", "version" }

local function notify(message, level)
  vim.notify("agent-smith: " .. message, level or vim.log.levels.INFO)
end

--- The in-flight request, so it can be cancelled.
local active = nil

--- Start an inline edit on the current selection.
---
--- Reads the visual marks immediately, because they are only reliable right
--- after leaving visual mode. Returns the loop handle, or nil and a reason.
---@param options table|nil Passed through to agent-smith.modes.inline.
---@return table|nil handle
function M.inline(options)
  local Inline = require("agent-smith.modes.inline")

  local fields = {}
  for key, value in pairs(options or {}) do
    fields[key] = value
  end
  fields.config = M.config

  local handle, err = Inline.run(fields)
  if not handle then
    -- Cancelling the prompt is a normal outcome, not something to warn about.
    if err ~= "cancelled" then
      notify(tostring(err), vim.log.levels.WARN)
    end
    return nil
  end

  active = handle
  return handle
end

--- Start a vibe run: plan, approve, execute, review.
---
--- Returns the session handle, or nil and a reason. See
--- spec/decisions/0007-vibe-workflow.md and agent-smith.modes.vibe.
---@param options table|nil Passed through to agent-smith.modes.vibe.
---@return table|nil handle
function M.vibe(options)
  local Vibe = require("agent-smith.modes.vibe")

  local fields = {}
  for key, value in pairs(options or {}) do
    fields[key] = value
  end
  fields.config = M.config

  local handle, err = Vibe.run(fields)
  if not handle then
    if err ~= "cancelled" then
      notify(tostring(err), vim.log.levels.WARN)
    end
    return nil
  end

  active = handle
  return handle
end

--- Configure a credential, interactively.
---
--- The first thing a new user has to do, and the one thing `setup()` cannot take,
--- so it gets a command rather than a paragraph in the README. Omit the provider to
--- be asked which one.
---
--- Reports through notifications rather than returning, because the flow is
--- asynchronous: `vim.ui.select` may be a floating picker, so the answer arrives
--- through a callback. See agent-smith.onboard.
---@param provider string|nil Skip the provider picker.
function M.onboard(provider)
  require("agent-smith.onboard").run({ provider = provider })
end

--- The provider and model chosen with a picker, for this session only.
---
--- Deliberately not written anywhere. `setup()` is where a choice is written down;
--- a picker that outlived the session would mean editing your configuration,
--- restarting, and watching nothing change — the exact confusion a pick is meant to
--- spare you. A pick is a detour for one session, not a second source of truth.
M.session = nil

--- A resolved configuration with this session's choice applied.
---
--- `M.resolved` is left untouched, so dropping the session choice restores exactly
--- what `setup()` said without resolving anything again.
---@param resolved table
---@return table config
local function with_session(resolved)
  if not M.session then
    return resolved
  end

  local applied = {}
  for key, value in pairs(resolved) do
    applied[key] = value
  end
  if M.session.provider then
    applied.provider = M.session.provider
  end
  if M.session.model then
    applied.model = M.session.model
  end
  applied.session = M.session

  return applied
end

--- Adopt what a picker reported, for the rest of the session.
---
--- `info.cleared` means the user asked to go back, so the session choice is dropped
--- and `setup()` applies again. Anything else updates the half that changed, which
--- keeps a provider pick from discarding a model already chosen in this session.
local function adopt(info)
  if not M.resolved or type(info) ~= "table" then
    return
  end

  if info.cleared then
    M.session = nil
  elseif info.provider or info.model then
    M.session = {
      provider = info.provider or (M.session and M.session.provider),
      model = info.model or (M.session and M.session.model),
    }
  else
    return
  end

  M.config = with_session(M.resolved)
end

--- Choose a model from the provider's catalogue, interactively.
---
--- The choice applies to this session and is not remembered: `setup()` stays the
--- only place a model is written down.
---@param provider string|nil Defaults to the configured provider.
function M.choose_model(provider)
  require("agent-smith.onboard").choose_model({
    provider = provider or (M.config and M.config.provider),
    config = M.config or {},
    session = M.session,
    on_done = function(ok, _, info)
      if ok then
        adopt(info)
      end
    end,
  })
end

--- Choose which provider to use, interactively.
---
--- Remembers the choice for this session the same way `choose_model` does, and
--- opens the model picker when the current model does not belong to the provider
--- chosen.
function M.choose_provider()
  require("agent-smith.onboard").choose_provider({
    config = M.config or {},
    session = M.session,
    on_done = function(ok, _, info)
      if ok then
        adopt(info)
      end
    end,
  })
end

--- Show what the agent is doing, event by event, in a split.
---
--- The status line says what is happening now; this is the other half — every
--- event, timestamped, with how long each tool call took. It is what makes a run
--- that has stopped moving distinguishable from one that is thinking hard, since
--- from a one-line status the two look identical.
---
--- Toggles, so the same key closes it again. Inside the monitor: `q` closes it,
--- `X` cancels the run, `<C-c>` clears the log. See agent-smith.ui.monitor.
---@return table monitor
function M.monitor()
  local monitor = require("agent-smith.ui.monitor").get()
  monitor:toggle()
  return monitor
end

--- Stop the in-flight request, if there is one.
---@return boolean cancelled
function M.cancel()
  if active and type(active.cancel) == "function" then
    active.cancel(active)
    active = nil
    return true
  end
  return false
end

--- Report the version and the resolved configuration.
function M.info()
  if not M.config then
    notify("not configured; call require('agent-smith').setup() first")
    return
  end

  -- Says where the model came from, because a remembered pick overrides setup()
  -- and an override nobody can see is indistinguishable from configuration being
  -- ignored.
  local model = M.config.model or "no model"
  if M.config.session then
    model = model .. " (this session)"
  end

  notify(
    ("%s — %s %s — sandbox %s — network %s"):format(
      M.version,
      M.config.provider or "no provider",
      model,
      M.config.sandbox.root,
      M.config.sandbox.network and "on" or "off"
    )
  )
end

local function handle_command(args)
  local subcommand = args.fargs[1]
  if subcommand == nil or subcommand == "info" then
    M.info()
  elseif subcommand == "model" then
    M.choose_model(args.fargs[2])
  elseif subcommand == "provider" then
    M.choose_provider()
  elseif subcommand == "monitor" then
    M.monitor()
  elseif subcommand == "setup" then
    M.onboard(args.fargs[2])
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
    { mode = "n", lhs = "<leader>ax", rhs = M.cancel, desc = "agent-smith cancel" },
    { mode = "n", lhs = "<leader>am", rhs = M.monitor, desc = "agent-smith stream monitor" },
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
  -- Kept, so a pick made during the session can be re-applied without re-reading
  -- any configuration.
  M.resolved = Config.resolve(opts)

  -- A fresh setup() is a fresh start: any pick from earlier in the session is
  -- dropped, so reloading a configuration is not answered with a stale override.
  M.session = nil
  M.config = with_session(M.resolved)

  if M.config.commands then
    register_commands()
  end
  if M.config.default_keymaps then
    register_keymaps()
  end
  return M
end

return M
