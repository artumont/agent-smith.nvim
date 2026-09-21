--- Development init for `make run`.
---
--- Loads **your real configuration first**, then this repository on top, so the
--- plugin is exercised against the environment it will actually run in: your
--- leader key, your plugins, your options. A clean-room init is easier to reason
--- about and hides every integration problem until release.
---
---   make run                      your config, plus agent-smith
---   make run-clean                agent-smith alone, for when your config is
---                                 the thing that is broken
---
--- Launched as `nvim -u dev/init.lua`, which *replaces* $MYVIMRC, so your init
--- is sourced explicitly below rather than by Neovim.

--- The repository root, from this file's own location, so the session can be
--- started from anywhere.
local function repository_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(source, ":p")))
end

local root = repository_root()

local clean = vim.env.AGENT_SMITH_CLEAN == "1"

--- Find the user's own init, whichever form it takes.
local function user_init()
  local config = vim.fn.stdpath("config")
  for _, candidate in ipairs({ "init.lua", "init.vim" }) do
    local path = vim.fs.joinpath(config, candidate)
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
  return nil
end

if not clean then
  local path = user_init()

  if path then
    -- $MYVIMRC still points at this file, and plugins read it to work out which
    -- configuration is running. Point it at the real one for the duration.
    local previous = vim.env.MYVIMRC
    vim.env.MYVIMRC = path

    local ok, err = pcall(dofile, path)
    if not ok then
      -- A broken configuration should not take the plugin down with it: report
      -- it and carry on, because `make run-clean` exists for exactly this.
      vim.notify(
        ("agent-smith dev: your config failed to load — %s"):format(tostring(err)),
        vim.log.levels.ERROR
      )
    end

    vim.env.MYVIMRC = previous
  else
    vim.notify(
      "agent-smith dev: no user config found at " .. vim.fn.stdpath("config"),
      vim.log.levels.WARN
    )
  end
end

-- Prepended *after* the user's configuration, not before.
--
-- lazy.nvim recomputes the runtimepath while it sets up, and that drops anything
-- prepended earlier: with the prepend above the config load, `require(
-- "agent-smith")` failed with "module not found" because the repository was no
-- longer on the path. Verified by running both orders.
--
-- In Lua rather than via `--cmd "set rtp+=."`: an rtp change made through --cmd
-- does not propagate to package.path either.
vim.opt.runtimepath:prepend(root)

-- Deliberately not setting mapleader: the point is that the default keymaps
-- resolve against *your* leader, not one this file picked.
--
-- `deepseek/deepseek-v4-flash` is the default because it is the one that keeps
-- working. Both free models are unusable in practice right now, and each says so
-- in its own words when you try it:
--
--   inclusionai/ling-3.0-flash-sante:free   429 "used all 100 free requests for
--                                           today", a daily quota
--   poolside/laguna-s-2.1-free              429 "upstream temporarily
--                                           unavailable"
--
-- Override with the environment:
--
--   AGENT_SMITH_MODEL=deepseek/deepseek-v4.1-flash make run
--
-- The credential lives in agent-smith's own encrypted store, put there from pi's
-- CommandCode sign-in. It is an OAuth access token, so it will eventually need
-- replacing with a key generated in CommandCode's Studio.
--
-- The inline status position is only set here when the environment asks for it,
-- so that the module's own default is what applies otherwise. Hardcoding a
-- fallback here would silently shadow config.lua, and then changing the default
-- there would appear to do nothing under `make run`:
--
--   AGENT_SMITH_POSITION=below make run
--   AGENT_SMITH_POSITION=above make run
local smith = require("agent-smith")
local options = {
  provider = vim.env.AGENT_SMITH_PROVIDER or "commandcode",
  model = vim.env.AGENT_SMITH_MODEL or "poolside/laguna-s-2.1-free",
}

if vim.env.AGENT_SMITH_POSITION and vim.env.AGENT_SMITH_POSITION ~= "" then
  options.progress = { position = vim.env.AGENT_SMITH_POSITION }
end

smith.setup(options)

vim.schedule(function()
  vim.notify(
    ("agent-smith %s — %s"):format(smith.version, clean and "clean config" or "your config")
  )
end)
