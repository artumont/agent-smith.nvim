--- Minimal init for `make run`.
---
--- Launched as `nvim -u dev/init.lua`, which replaces the user's configuration
--- entirely. That keeps a manual session reproducible and free of interference
--- from other plugins, at the cost of not having your own keymaps available.
---
--- The plugin is loaded from this repository, so edits take effect on restart.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local root = vim.fs.dirname(vim.fs.dirname(script))

-- Prepend the runtimepath in Lua rather than with `--cmd "set rtp+=."`. An
-- rtp change made through --cmd does not propagate to package.path, so
-- require() would not find the plugin. The path is absolutised because the
-- session may be started from any directory.
vim.opt.runtimepath:prepend(root)

-- The default keymaps are registered under <leader>, which is unset in a clean
-- session.
vim.g.mapleader = ","

local smith = require("agent-smith")
smith.setup()

-- Deferred so the message lands after the UI exists.
vim.schedule(function()
  vim.notify(
    ("agent-smith %s — <leader>as inline, <leader>av vibe, :Smith info"):format(smith.version)
  )
end)
