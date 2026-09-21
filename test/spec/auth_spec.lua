return function(t)
  local Auth = require("agent-smith.auth")

  --- A store rooted in a fresh temp directory, with the two files in separate
  --- trees exactly as the defaults do.
  local function fresh_store()
    local root = vim.fn.tempname()
    return Auth.new({
      auth_file = vim.fs.joinpath(root, "config", "agent-smith", "auth.json"),
      key_file = vim.fs.joinpath(root, "data", "agent-smith", "auth.key"),
    }), root
  end

  --- A second store over the same two files.
  ---
  --- Reads go to disk rather than to the in-memory cache. Without this, a
  --- broken encrypt/decrypt round trip hides behind the cache: every read in a
  --- single-store test is served from memory and never touches the file.
  local function reopened(store)
    return Auth.new({ auth_file = store.auth_file, key_file = store.key_file })
  end

  local function read_raw(path)
    return table.concat(vim.fn.readfile(path), "\n")
  end

  local function mode_of(path)
    return vim.uv.fs_stat(path).mode % 512
  end

  if not Auth.openssl_available() then
    -- Encryption is the point of this module, so a missing tool is a real
    -- failure with a real message rather than a skipped test.
    t.it("reports that it cannot encrypt without openssl", function()
      local store = fresh_store()
      store.auth_file = vim.fs.joinpath(vim.fn.tempname(), "auth.json")
      local ok, err = store:set("opencode", "x")
      t.eq(ok, false)
      t.matches(err, "openssl is not installed")
    end)
  else
    t.describe("auth: round trip", function()
      t.it("stores and returns a key", function()
        local store = fresh_store()
        t.eq(store:set("opencode", "sk-test-value"), true)
        t.eq(reopened(store):get("opencode"), "sk-test-value")
      end)

      t.it("returns nil for a provider with no key", function()
        local store = fresh_store()
        local key, err = store:get("nobody")
        t.eq(key, nil)
        t.eq(err, nil, "an absent provider is not an error")
      end)

      t.it("decrypts on a second store instance", function()
        local store = fresh_store()
        store:set("commandcode", "cmd-secret")
        t.eq(reopened(store):get("commandcode"), "cmd-secret")
      end)

      t.it("keeps several providers apart on disk", function()
        local store = fresh_store()
        store:set("opencode", "one")
        store:set("commandcode", "two")
        t.eq(reopened(store):get("opencode"), "one")
        t.eq(reopened(store):get("commandcode"), "two")
      end)

      t.it("overwrites an existing key", function()
        local store = fresh_store()
        store:set("opencode", "first")
        store:set("opencode", "second")
        t.eq(reopened(store):get("opencode"), "second")
      end)

      t.it("lists providers in sorted order", function()
        local store = fresh_store()
        store:set("opencode", "one")
        store:set("anthropic", "two")
        t.eq(reopened(store):list(), { "anthropic", "opencode" })
      end)

      t.it("removes a provider", function()
        local store = fresh_store()
        store:set("opencode", "one")
        t.eq(store:remove("opencode"), true)
        t.eq(reopened(store):get("opencode"), nil)
        t.eq(reopened(store):list(), {})
      end)

      t.it("tolerates removing a provider that is not there", function()
        local store = fresh_store()
        t.eq(store:remove("absent"), true)
      end)

      t.it("starts empty when there is no file", function()
        local store = fresh_store()
        t.eq(store:list(), {})
      end)
    end)

    t.describe("auth: the file does not leak", function()
      t.it("never contains the plaintext key", function()
        -- This is the whole point: a config directory symlinked into a dotfiles
        -- repository must not be able to leak the credential into a commit.
        local store = fresh_store()
        store:set("opencode", "sk-live-do-not-leak-me")

        local raw = read_raw(store.auth_file)
        t.eq(raw:find("sk-live%-do-not-leak-me") ~= nil, false, "plaintext must not appear")
        t.eq(raw:find("do%-not%-leak") ~= nil, false)
      end)

      t.it("never contains the key material", function()
        local store = fresh_store()
        store:set("opencode", "some-value")

        local key_material = vim.trim(read_raw(store.key_file))
        t.ok(#key_material >= 32, "the key should be real key material")
        t.eq(read_raw(store.auth_file):find(key_material, 1, true) ~= nil, false)
      end)

      t.it("is still valid JSON, so tooling does not choke on it", function()
        local store = fresh_store()
        store:set("opencode", "value")

        local envelope = vim.json.decode(read_raw(store.auth_file))
        t.eq(envelope.version, Auth.ENVELOPE_VERSION)
        t.eq(envelope.cipher, Auth.CIPHER)
        t.eq(type(envelope.data), "string")
      end)

      t.it("produces different ciphertext for the same input", function()
        -- A fixed salt would make two stores with the same key produce
        -- identical files, leaking equality.
        local first, first_root = fresh_store()
        first:set("opencode", "same-value")
        local first_payload = vim.json.decode(read_raw(first.auth_file)).data

        local second = Auth.new({
          auth_file = vim.fs.joinpath(first_root, "other", "auth.json"),
          key_file = first.key_file,
        })
        second:set("opencode", "same-value")
        local second_payload = vim.json.decode(read_raw(second.auth_file)).data

        t.not_ok(first_payload == second_payload, "a random salt should differ per write")
      end)
    end)

    t.describe("auth: file permissions", function()
      t.it("creates the key file as 0600", function()
        local store = fresh_store()
        store:set("opencode", "value")
        t.eq(mode_of(store.key_file), tonumber("600", 8))
      end)

      t.it("creates the credential file as 0600", function()
        local store = fresh_store()
        store:set("opencode", "value")
        t.eq(mode_of(store.auth_file), tonumber("600", 8))
      end)
    end)

    t.describe("auth: failures", function()
      t.it("explains a missing key file instead of failing cryptically", function()
        local store = fresh_store()
        store:set("opencode", "value")
        os.remove(store.key_file)

        local reopened = Auth.new({ auth_file = store.auth_file, key_file = store.key_file })
        local key, err = reopened:get("opencode")
        t.eq(key, nil)
        t.matches(err, "no key file")
      end)

      t.it("rejects a wrong key with a decryption message", function()
        local store = fresh_store()
        store:set("opencode", "value")

        -- Someone else's key in the key file.
        vim.fn.writefile({ string.rep("deadbeef", 8) }, store.key_file, "b")

        local reopened = Auth.new({ auth_file = store.auth_file, key_file = store.key_file })
        local key, err = reopened:get("opencode")
        t.eq(key, nil)
        t.matches(err, "could not decrypt")
      end)

      t.it("refuses an envelope from a future version", function()
        local store = fresh_store()
        store:set("opencode", "value")

        local envelope = vim.json.decode(read_raw(store.auth_file))
        envelope.version = 99
        vim.fn.writefile({ vim.json.encode(envelope) }, store.auth_file, "b")

        local reopened = Auth.new({ auth_file = store.auth_file, key_file = store.key_file })
        local key, err = reopened:get("opencode")
        t.eq(key, nil)
        t.matches(err, "envelope version 99")
      end)

      t.it("rejects a file that is not an envelope", function()
        local store = fresh_store()
        store:set("opencode", "value")
        vim.fn.writefile({ "not json" }, store.auth_file, "b")

        local reopened = Auth.new({ auth_file = store.auth_file, key_file = store.key_file })
        local key, err = reopened:get("opencode")
        t.eq(key, nil)
        t.matches(err, "not a readable credential envelope")
      end)

      t.it("refuses an empty provider name", function()
        t.raises(function()
          fresh_store():set("", "value")
        end, "provider name")
      end)

      t.it("refuses an empty key", function()
        t.raises(function()
          fresh_store():set("opencode", "")
        end, "key is required")
      end)
    end)
  end

  t.describe("auth: default locations", function()
    local paths = Auth.default_paths()

    t.it("puts the encrypted file under the config directory", function()
      t.matches(paths.auth_file, "agent%-smith/auth%.json$")
    end)

    t.it("keeps the credential out of Neovim's own config directory", function()
      -- This tree is the one that gets committed, so an encrypted file here is one
      -- `git add -A` from being published. This is a regression that actually
      -- happened: auth_file briefly pointed at stdpath("config"), which put the
      -- credential inside the synced tree.
      local nvim_config = vim.fs.normalize(vim.fn.stdpath("config"))
      local auth_file = vim.fs.normalize(paths.auth_file)

      t.eq(vim.startswith(auth_file, nvim_config .. "/"), false, "credential must not live in " .. nvim_config)
    end)

    t.it("uses agent-smith's own sibling directory", function()
      -- Taking stdpath("config")'s parent rather than hardcoding ~/.config keeps
      -- $XDG_CONFIG_HOME working.
      local expected = vim.fs.joinpath(vim.fs.dirname(vim.fn.stdpath("config")), "agent-smith")
      t.eq(Auth.config_root(), expected)
      t.eq(paths.auth_file, vim.fs.joinpath(expected, "auth.json"))
    end)

    t.it("puts the key outside the config directory", function()
      -- The config tree is the one people symlink into a dotfiles repository.
      -- If the key lived there too, the encryption would travel with it.
      local config_dir = vim.fs.dirname(paths.auth_file)
      t.eq(vim.startswith(vim.fs.normalize(paths.key_file), vim.fs.normalize(config_dir) .. "/"), false)
    end)

    t.it("names the key file distinctly", function()
      t.not_ok(paths.auth_file == paths.key_file)
      t.matches(paths.key_file, "auth%.key$")
    end)
  end)

  t.describe("auth: git awareness", function()
    t.it("reports an untracked key in a plain directory", function()
      local store = fresh_store()
      local tracked = store:key_is_tracked()
      t.eq(tracked, false)
    end)

    t.it("notices a key inside a work tree", function()
      local store, root = fresh_store()
      vim.fn.mkdir(vim.fs.joinpath(root, ".git"), "p")

      local tracked, directory = store:key_is_tracked()
      t.eq(tracked, true)
      t.eq(directory, root)
    end)
  end)
end
