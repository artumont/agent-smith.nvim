--- Development init for `make run`.
---
--- Loads **your real configuration first**, then this repository on top, so the
--- plugin is exercised against the environment it will actually run in: your
--- leader key, your plugins, your options. A clean-room init is easier to reason
--- about and hides every integration problem until release.
---
--- Any copy of agent-smith your configuration installs — lazy.nvim's cache, a
--- `pack/*/start` clone — is taken off the runtimepath before this repository is
--- loaded, because a stale checkout answering `require("agent-smith")` is the
--- exact confusion `make run` exists to prevent. See `ignore_cached_copies` below.
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

local root = vim.fs.normalize(repository_root())

local clean = vim.env.AGENT_SMITH_CLEAN == "1"

--- Take every other copy of this plugin off the runtimepath.
---
--- Your configuration may well have agent-smith installed somewhere: lazy.nvim's
--- cache, a `pack/*/start` clone, a `--cmd "set rtp+=..."`. Since your config is
--- loaded first, that copy is on the runtimepath before this file runs, and it
--- would answer `require("agent-smith")` — so `make run` would exercise an older
--- checkout while looking like it was exercising this one.
---
--- Prepending the repository is not enough on its own. `package.loaded` may
--- already hold the cached module from something your config required, and a
--- plugin manager that loads the plugin lazily prepends its own directory when it
--- does so, putting the cached copy back in front afterwards. Hence: called once
--- before the prepend below, and again once startup has settled.
---
--- Only directories whose name contains "agent-smith" are touched, and never this
--- checkout, so the rest of your runtimepath is left alone.
---@return string[] removed Paths taken off the runtimepath.
local function ignore_cached_copies()
  local removed = {}

  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    local normalized = vim.fs.normalize(path)
    if normalized ~= root and vim.fs.basename(normalized):find("agent-smith", 1, true) then
      removed[#removed + 1] = path
    end
  end

  if #removed == 0 then
    return removed
  end

  vim.opt.runtimepath:remove(removed)

  -- The loaded modules go with the path, or the cached copy stays in memory,
  -- keeps answering every require, and the runtimepath edit accomplishes nothing.
  for name in pairs(package.loaded) do
    if name == "agent-smith" or name:sub(1, 12) == "agent-smith." then
      package.loaded[name] = nil
    end
  end

  return removed
end

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
local ignored = ignore_cached_copies()
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

--- Whether the module that answered `require` is this checkout.
---
--- The whole point of dropping the cached copies is that this one runs, so it is
--- checked rather than assumed: a silent wrong-copy load is indistinguishable from
--- `make run` seeing stale behaviour, which is the failure being fixed.
---@return string|nil path Where the loaded module came from, when that is not this checkout.
local function loaded_from_elsewhere()
  local source = debug.getinfo(smith.setup, "S").source:sub(2)
  source = vim.fs.normalize(source)
  if source:sub(1, #root) == root then
    return nil
  end
  return source
end

--- Drop the copies again, remembering everything taken off so far.
---
--- A plugin manager that loads plugin definitions later — on VeryLazy, on a
--- keymap — prepends its own directory at that point, and `setup()` may run then
--- too. Anything it puts back before this repository answered a require has to go,
--- or the cached copy answers the next one.
local function ignore_again()
  for _, path in ipairs(ignore_cached_copies()) do
    if not vim.tbl_contains(ignored, path) then
      ignored[#ignored + 1] = path
    end
  end
end

-- Both events fire at most once, and an autocmd that never matches costs
-- nothing, so a configuration that has no plugin manager pays only for the
-- listener it never triggers.
vim.api.nvim_create_autocmd("User", {
  pattern = { "LazyDone", "VeryLazy" },
  callback = ignore_again,
})

vim.schedule(function()
  ignore_again()

  local lines = {
    ("agent-smith %s — %s"):format(smith.version, clean and "clean config" or "your config"),
  }
  if #ignored > 0 then
    lines[#lines + 1] = ("ignoring the installed copy at %s"):format(table.concat(ignored, ", "))
  end

  local elsewhere = loaded_from_elsewhere()
  if elsewhere then
    lines[#lines + 1] = (
      "loaded from %s, not this checkout — remove agent-smith from your plugin list"
    ):format(elsewhere)
    vim.notify(table.concat(lines, "\n"), vim.log.levels.ERROR)
    return
  end

  vim.notify(table.concat(lines, "\n"))
end)
