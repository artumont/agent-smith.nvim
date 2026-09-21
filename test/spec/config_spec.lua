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

    t.it("accepts both status positions", function()
      for _, position in ipairs({ "above", "below" }) do
        local config = vim.tbl_deep_extend("force", Config.defaults, { progress = { position = position } })
        t.eq(Config.validate(config), true, position)
      end
    end)

    t.it("rejects an unknown status position", function()
      local config = vim.tbl_deep_extend("force", Config.defaults, { progress = { position = "middle" } })
      local ok, err = Config.validate(config)
      t.eq(ok, false)
      t.matches(err, "progress%.position")
      t.matches(err, "above")
    end)

    t.it("rejects a position that is not a string", function()
      local config = vim.tbl_deep_extend("force", Config.defaults, { progress = { position = 1 } })
      t.eq(Config.validate(config), false)
    end)
  end)

  t.describe("config.resolve", function()
    t.it("returns the defaults when given nothing", function()
      t.eq(Config.resolve().sandbox.root, Config.defaults.sandbox.root)
    end)

    t.it("ships a status position the validator accepts", function()
      -- Deliberately not pinned to a specific value: which position is the
      -- default is a preference, and it has already been changed once. What has
      -- to hold is that the default is one the validator accepts, so a typo in
      -- the defaults fails here rather than at runtime.
      local position = Config.defaults.progress.position
      t.ok(position == "above" or position == "below", ("got %s"):format(tostring(position)))
      t.eq(Config.validate(Config.defaults), true)
    end)

    t.it("keeps a configured status position across the merge", function()
      -- Nested tables merge, so setting only the position must not drop the rest
      -- of the progress section.
      local config = Config.resolve({ progress = { position = "below" } })
      t.eq(config.progress.position, "below")
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

    t.it("hands back copies, so a caller cannot rewrite the defaults", function()
      -- resolve() used to share the defaults' own nested tables, so this grew
      -- the default blacklist for every later resolve() in the process.
      local before = #Config.defaults.sandbox.blacklist
      local config = Config.resolve()
      config.sandbox.blacklist[#config.sandbox.blacklist + 1] = "^tampered"
      t.eq(#Config.defaults.sandbox.blacklist, before, "the defaults must be untouched")
    end)

    t.it("does not share the defaults' tables at all", function()
      local config = Config.resolve()
      t.ok(config.sandbox ~= Config.defaults.sandbox, "sandbox should be a copy")
      t.ok(config.progress ~= Config.defaults.progress, "progress should be a copy")
    end)

    t.it("raises on an invalid configuration", function()
      t.raises(function()
        Config.resolve({ sandbox = { root = "relative" } })
      end, "invalid configuration")
    end)
  end)
end
