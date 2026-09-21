return function(t)
  -- Set before any test runs so that keymap assertions are stable in headless
  -- Neovim, where mapleader is otherwise unset.
  vim.g.mapleader = ","

  local Smith = require("agent-smith")

  t.describe("setup", function()
    t.it("returns the module table", function()
      t.eq(Smith.setup(), Smith)
    end)

    t.it("exposes the resolved configuration", function()
      t.ok(Smith.config, "config is set after setup()")
      t.ok(Smith.config.sandbox, "sandbox defaults are present")
    end)

    t.it("registers the :Smith command", function()
      t.eq(vim.fn.exists(":Smith"), 2, "2 means a user command")
    end)

    t.it("registers the default keymaps", function()
      t.eq(vim.fn.maparg(",as", "v") ~= "", true, "visual inline keymap")
      t.eq(vim.fn.maparg(",av", "n") ~= "", true, "normal vibe keymap")
    end)

    t.it("can skip keymaps", function()
      local previous = vim.g.mapleader
      vim.g.mapleader = ",,"
      Smith.setup({ default_keymaps = false })
      t.eq(vim.fn.maparg(",,as", "v"), "")
      vim.g.mapleader = previous
    end)
  end)

  t.describe("api surface", function()
    t.it("exposes a version", function()
      t.matches(Smith.version, "^%d+%.%d+%.%d+")
    end)

    t.it("has callable mode entry points", function()
      -- The modes are not implemented yet, but the entry points exist so that
      -- keymaps and documentation do not need to change when they land.
      t.eq(type(Smith.inline), "function")
      t.eq(type(Smith.vibe), "function")
    end)

    t.it("does not raise when a mode is invoked", function()
      local ok = pcall(Smith.inline)
      t.eq(ok, true)
    end)
  end)
end
