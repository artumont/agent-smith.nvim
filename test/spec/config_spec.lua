return function(t)
  local Config = require("agent-smith.config")

  t.describe("config.validate", function()
    t.it("accepts the defaults", function()
      t.eq(Config.validate(Config.defaults), true)
    end)

    t.it("rejects a relative sandbox root", function()
      local config = vim.tbl_deep_extend("force", Config.defaults, { sandbox = { root = "sandbox" } })
      local ok, err = Config.validate(config)
      t.eq(ok, false)
      t.matches(err, "must be an absolute path")
    end)

    t.it("rejects an empty sandbox root", function()
      local config = vim.tbl_deep_extend("force", Config.defaults, { sandbox = { root = "" } })
      local ok = Config.validate(config)
      t.eq(ok, false)
    end)

    t.it("rejects a non-list blacklist", function()
      local config = vim.tbl_deep_extend("force", Config.defaults, { sandbox = { blacklist = {} } })
      t.eq(Config.validate(config), true, "an empty list is still a list")

      config.sandbox.blacklist = { rm = true }
      local ok, err = Config.validate(config)
      t.eq(ok, false)
      t.matches(err, "must be a list")
    end)

    t.it("rejects a non-boolean network flag", function()
      local config = vim.tbl_deep_extend("force", Config.defaults, { sandbox = { network = "no" } })
      t.eq(Config.validate(config), false)
    end)
  end)

  t.describe("config.resolve", function()
    t.it("returns the defaults when given nothing", function()
      t.eq(Config.resolve().sandbox.root, Config.defaults.sandbox.root)
    end)

    t.it("merges nested tables instead of replacing them", function()
      local config = Config.resolve({ sandbox = { network = true } })
      t.eq(config.sandbox.network, true)
      t.eq(config.sandbox.root, Config.defaults.sandbox.root, "siblings survive the merge")
    end)

    t.it("replaces lists wholesale", function()
      local config = Config.resolve({ sandbox = { blacklist = { "^%s*foo" } } })
      t.eq(config.sandbox.blacklist, { "^%s*foo" })
    end)

    t.it("does not mutate the defaults", function()
      Config.resolve({ sandbox = { network = true } })
      t.eq(Config.defaults.sandbox.network, false)
    end)

    t.it("raises on an invalid configuration", function()
      t.raises(function()
        Config.resolve({ sandbox = { root = "relative" } })
      end, "invalid configuration")
    end)
  end)
end
