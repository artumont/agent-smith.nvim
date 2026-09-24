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

--- Hand module resolution back to the runtimepath.
---
--- `vim.loader.enable()` — Neovim's Lua byte-compilation cache, which many
--- configurations turn on — removes Neovim's runtimepath searcher and puts its own
--- in its place, ahead of every other searcher. That one keeps its own snapshot
--- of the runtimepath and rebuilds it only when a lookup *misses*, so a snapshot
--- taken while a cached copy was in front keeps resolving to it however the
--- runtimepath changes afterwards. Nothing else in this file can win against it.
--- Measured, not assumed: with the repository at runtimepath position 1, searcher
--- 2 answered with the cached directory's path.
---
--- Turning the cache off puts the runtimepath searcher back, which is the one the
--- cleanup above can affect. The cost is real: Lua loaded later in the session
--- comes from disk instead of the byte-compilation cache. It is also what a
--- session spent editing Lua wants — no compiled copy of a file being changed —
--- which is why this is acceptable here and would not be in the plugin itself.
---@return boolean disabled Whether the cache was on and is now off.
local function use_runtimepath_searcher()
  local ok, loader = pcall(require, "vim.loader")
  if not ok or not loader.enabled then
    return false
  end
  pcall(loader.disable)
  return true
end

--- Point a plugin manager's entry for this plugin at this checkout.
---
--- Taking the cached copy off the runtimepath is not enough when lazy.nvim is the
--- one that installed it. lazy inserts its own module searcher ahead of the
--- runtimepath one (`table.insert(package.loaders, 3, ...)`), and that searcher
--- resolves `require` from the directories in its **own** registry —
--- `lazy.core.config.spec.plugins[].dir`, via `Util.get_unloaded_rtp` — without
--- consulting the runtimepath for them. A checkout first on the runtimepath
--- therefore loses to the cache, and `make run` reports the cached copy's version
--- while looking like it is running this one. Measured rather than assumed:
--- `require("agent-smith")` resolved to
--- `~/.local/share/nvim/lazy/agent-smith.nvim` with the repository at
--- runtimepath position 1.
---
--- `plugin.dir` is read at require time, so writing it here — before anything
--- requires agent-smith — is enough. Deliberately not `plugin.dev`: lazy
--- recomputes `dir` from that on a plugin reload, and `dev = true` sends it
--- looking in lazy's own dev path, so a checkout that is not there would end up
--- with no directory at all. Setting `dev = true` in the plugin spec is the
--- supported way to make this stick across `:Lazy reload`.
---@return string[] redirected Plugin names that were pointed at this checkout.
local function point_manager_at_checkout()
  local ok, config = pcall(require, "lazy.core.config")
  if not ok or type(config.spec) ~= "table" or type(config.spec.plugins) ~= "table" then
    return {}
  end

  local redirected = {}
  for name, plugin in pairs(config.spec.plugins) do
    local directory = type(plugin.dir) == "string" and vim.fs.normalize(plugin.dir) or ""
    if directory ~= root and vim.fs.basename(directory):find("agent-smith", 1, true) then
      plugin.dir = root
      redirected[#redirected + 1] = name
    end
  end

  if #redirected > 0 then
    -- lazy memoises the unresolved-plugin directory list per top-level module,
    -- so the cached directory would keep being offered until this is dropped.
    pcall(function()
      require("lazy.core.util").unloaded_cache = {}
    end)
  end

  return redirected
end

--- The configuration your configuration already asked for.
---
--- lazy.nvim can load a plugin *during* `lazy.setup()` — both the spec's `config`
--- and the module it configures — which happens before this file takes the cached
--- copy off the path. Those choices would otherwise be applied to a module that
--- is then thrown away, and `make run` would silently run on this harness's
--- defaults while your configuration appeared to have no effect.
---
--- Read before `ignore_cached_copies` clears the loaded modules.
---@return table|nil config
local function inherited_config()
  local loaded = package.loaded["agent-smith"]
  if type(loaded) == "table" and type(loaded.config) == "table" then
    return loaded.config
  end
  return nil
end

--- Take every other copy of this plugin off the runtimepath.
---
--- Your configuration may well have agent-smith installed somewhere: lazy.nvim's
--- cache, a `pack/*/start` clone, a `--cmd "set rtp+=..."`. Since your config is
--- loaded first, that copy is on the runtimepath before this file runs, and it
--- would answer `require("agent-smith")` — so `make run` would exercise an older
--- checkout while looking like it was exercising this one.
---
--- This covers the plugin managers that resolve through the runtimepath. lazy.nvim
--- does not, which is what `point_manager_at_checkout` above is for; both run.
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
local inherited = inherited_config()
local ignored = ignore_cached_copies()
local redirected = point_manager_at_checkout()
vim.opt.runtimepath:prepend(root)
local via_runtimepath = use_runtimepath_searcher()

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
  -- Your configuration's own choice first, then this file's default: the
  -- environment is what `make run` says it is, so what your config asked for has
  -- to win over what the harness assumes. Both are still overridable from the
  -- environment, which is what a one-off run uses.
  provider = vim.env.AGENT_SMITH_PROVIDER
    or (inherited and inherited.provider)
    or "commandcode",
  model = vim.env.AGENT_SMITH_MODEL
    or (inherited and inherited.model)
    or "poolside/laguna-s-2.1-free",
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
  if #redirected > 0 then
    lines[#lines + 1] = ("pointed %s at this checkout"):format(table.concat(redirected, ", "))
  end
  if via_runtimepath then
    lines[#lines + 1] = "module cache off, so require() follows the runtimepath"
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
