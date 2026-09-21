--- Credential storage.
---
--- An `auth.json` shaped like pi's — `{ "<provider>": { type, key } }` — but
--- encrypted at rest with a separate key file.
---
--- The threat this addresses is **accidental** disclosure, not a determined
--- attacker. Config directories get symlinked into dotfiles repositories, and a
--- plain `auth.json` in one of those is committed by the next `git add -A`. This
--- machine's own pi config does exactly that: `~/.pi/agent/settings.json` is a
--- symlink into `~/Documents/dotfiles/`.
---
--- What this does and does not buy:
---
---   - Stops a credential being swept into a commit, a backup, or a pasted
---     config. Verified by test: the stored file contains neither the key
---     material nor the plaintext.
---   - Does **not** stop anyone who can read the key file. Someone with access
---     to both files has the credential, and no arrangement of two local files
---     changes that. A passphrase would, at the cost of a prompt.
---
--- The key file therefore lives in the *data* directory while the encrypted
--- file lives in the *config* directory. That split is the point: the config
--- tree is the one that gets symlinked into a repository. `key_is_tracked()`
--- reports when that has been undone anyway.
---
--- **Which** config directory matters, and it is not Neovim's. `stdpath("config")`
--- is `~/.config/nvim`, and that is precisely the tree people put under version
--- control — so a credential kept there is one `git add -A` from being published,
--- which is the whole problem. agent-smith therefore uses its own sibling
--- directory, `~/.config/agent-smith/`, while the key stays in the data tree.
--- See `M.config_root()`.

local M = {}

--- Bumped when the envelope or the crypto changes, so an old file fails with a
--- clear message rather than a confusing decrypt error.
M.ENVELOPE_VERSION = 1

M.CIPHER = "aes-256-cbc"
M.KDF = "pbkdf2"

--- Where the encrypted file lives: agent-smith's own config directory.
---
--- Beside Neovim's rather than inside it. `stdpath("config")` is `~/.config/nvim`
--- and that tree is routinely symlinked into a dotfiles repository — this
--- machine's is — so anything kept there is one `git add -A` away from being
--- published. Taking the parent keeps `$XDG_CONFIG_HOME` working instead of
--- hardcoding `~/.config`.
---@return string
function M.config_root()
  return vim.fs.joinpath(vim.fs.dirname(vim.fn.stdpath("config")), "agent-smith")
end

--- Where the two files live by default.
---
--- Deliberately in different trees. See the note at the top of this module.
---@return table paths { auth_file = string, key_file = string }
function M.default_paths()
  return {
    auth_file = vim.fs.joinpath(M.config_root(), "auth.json"),
    key_file = vim.fs.joinpath(vim.fn.stdpath("data"), "agent-smith", "auth.key"),
  }
end

--- Whether the tool this relies on is present.
function M.openssl_available()
  return vim.fn.executable("openssl") == 1
end

local function hex(bytes)
  return (bytes:gsub(".", function(byte)
    return ("%02x"):format(byte:byte())
  end))
end

--- Random key material.
---
--- Prefers Neovim's own random source; falls back to /dev/urandom, which is what
--- it is reading anyway.
local function random_hex(count)
  local ok, bytes = pcall(vim.uv.random, count)
  if ok and type(bytes) == "string" and #bytes == count then
    return hex(bytes)
  end

  local descriptor = vim.uv.fs_open("/dev/urandom", "r", 0)
  if not descriptor then
    return nil
  end
  local data = vim.uv.fs_read(descriptor, count, 0)
  vim.uv.fs_close(descriptor)
  if type(data) ~= "string" or #data ~= count then
    return nil
  end
  return hex(data)
end

--- Write a file with 0600 permissions, creating its directory.
local function write_private(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, err = pcall(vim.fn.writefile, { text }, path, "b")
  if not ok then
    return false, ("could not write %s: %s"):format(path, tostring(err))
  end
  vim.uv.fs_chmod(path, tonumber("600", 8))
  return true
end

local Store = {}
Store.__index = Store

--- Whether the key file sits inside a git work tree.
---
--- A heuristic: it walks up looking for `.git` rather than asking git, because
--- this runs on load and should not spawn a process. Being tracked by a *bare*
--- repository reached some other way is not detected, and does not matter.
---
---@return boolean tracked
---@return string|nil directory
function Store:key_is_tracked()
  local directory = vim.fs.dirname(self.key_file)
  while directory and directory ~= "/" do
    if vim.uv.fs_stat(vim.fs.joinpath(directory, ".git")) then
      return true, directory
    end
    local parent = vim.fs.dirname(directory)
    if parent == directory then
      break
    end
    directory = parent
  end
  return false, nil
end

--- Create or return the key, creating it on first use.
---@return boolean ok
---@return string|nil error
function Store:ensure_key()
  if vim.fn.filereadable(self.key_file) == 1 then
    return true, nil
  end

  local key = random_hex(32)
  if not key then
    return false, "could not obtain random key material"
  end

  return write_private(self.key_file, key)
end

local function openssl(command, input, key_file)
  local full = { "openssl", "enc" }
  vim.list_extend(full, command)
  vim.list_extend(full, { "-a", "-pass", "file:" .. key_file })

  -- openssl's base64 decoder needs a terminating newline. Without one the read
  -- fails with "error reading input file", which is indistinguishable from a
  -- wrong key and sent this down a decryption rabbit hole. Measured, not
  -- guessed: the same payload decrypts once a newline is appended.
  local terminated = input:sub(-1) == "\n" and input or (input .. "\n")

  local completed = vim.system(full, { text = true, stdin = terminated }):wait()
  return completed
end

--- Read and decrypt the credential file.
---
--- Blocking, by design: it runs once and the result is cached, and the
--- alternative is making every caller of `get` async for a ~10ms local
--- operation. Must not be called from a fast event context.
---@param reload boolean|nil Bypass the cache.
---@return table|nil credentials
---@return string|nil error
function Store:read(reload)
  if self.cache and not reload then
    return self.cache, nil
  end

  if vim.fn.filereadable(self.auth_file) ~= 1 then
    self.cache = {}
    return self.cache, nil
  end

  if not M.openssl_available() then
    return nil, "openssl is not installed, so the credential file cannot be decrypted"
  end
  if vim.fn.filereadable(self.key_file) ~= 1 then
    return nil,
      ("no key file at %s, so %s cannot be decrypted"):format(self.key_file, self.auth_file)
  end

  local ok, envelope = pcall(vim.json.decode, table.concat(vim.fn.readfile(self.auth_file), "\n"))
  if not ok or type(envelope) ~= "table" then
    return nil, ("%s is not a readable credential envelope"):format(self.auth_file)
  end
  if envelope.version ~= M.ENVELOPE_VERSION then
    return nil,
      ("%s has envelope version %s, expected %s"):format(
        self.auth_file,
        tostring(envelope.version),
        M.ENVELOPE_VERSION
      )
  end
  if type(envelope.data) ~= "string" then
    return nil, ("%s has no encrypted payload"):format(self.auth_file)
  end

  local completed = openssl({ "-d", "-" .. M.CIPHER, "-" .. M.KDF }, envelope.data, self.key_file)
  if completed.code ~= 0 then
    return nil,
      ("could not decrypt %s: %s"):format(self.auth_file, vim.trim(completed.stderr or "no output"))
  end

  local decoded, credentials = pcall(vim.json.decode, completed.stdout or "")
  if not decoded or type(credentials) ~= "table" then
    return nil, ("%s did not decrypt to a JSON object"):format(self.auth_file)
  end

  self.cache = credentials
  return credentials, nil
end

--- Encrypt and persist the credential table.
---@return boolean ok
---@return string|nil error
function Store:write(credentials)
  assert(type(credentials) == "table", "credentials must be a table")

  if not M.openssl_available() then
    return false, "openssl is not installed, so credentials cannot be encrypted"
  end

  local key_ok, key_error = self:ensure_key()
  if not key_ok then
    return false, key_error
  end

  local completed =
    openssl({ "-" .. M.CIPHER, "-" .. M.KDF, "-salt" }, vim.json.encode(credentials), self.key_file)
  if completed.code ~= 0 then
    return false,
      ("could not encrypt credentials: %s"):format(vim.trim(completed.stderr or "no output"))
  end

  -- openssl wraps base64 at 64 columns; collapse to one line for the envelope.
  local payload = vim.trim(completed.stdout or ""):gsub("%s+", "")
  local envelope = vim.json.encode({
    version = M.ENVELOPE_VERSION,
    cipher = M.CIPHER,
    kdf = M.KDF,
    data = payload,
  })

  local written, write_error = write_private(self.auth_file, envelope)
  if not written then
    return false, write_error
  end

  self.cache = credentials
  return true, nil
end

--- The key for one provider, or nil.
---@return string|nil key
---@return string|nil error
function Store:get(provider)
  local credentials, err = self:read()
  if not credentials then
    return nil, err
  end
  local entry = credentials[provider]
  if type(entry) ~= "table" or type(entry.key) ~= "string" or entry.key == "" then
    return nil, nil
  end
  return entry.key, nil
end

--- Store the key for one provider.
---@return boolean ok
---@return string|nil error
function Store:set(provider, key)
  assert(type(provider) == "string" and provider ~= "", "a provider name is required")
  assert(type(key) == "string" and key ~= "", "a key is required")

  local credentials, err = self:read()
  if not credentials then
    return false, err
  end

  credentials[provider] = { type = "api", key = key }
  return self:write(credentials)
end

--- Forget one provider.
---@return boolean ok
---@return string|nil error
function Store:remove(provider)
  local credentials, err = self:read()
  if not credentials then
    return false, err
  end
  if credentials[provider] == nil then
    return true, nil
  end
  credentials[provider] = nil
  return self:write(credentials)
end

--- Provider names with a stored key, sorted.
---@return string[]|nil names
---@return string|nil error
function Store:list()
  local credentials, err = self:read()
  if not credentials then
    return nil, err
  end
  local names = vim.tbl_keys(credentials)
  table.sort(names)
  return names
end

--- A store rooted at the given paths, or at the defaults.
---@param options table|nil { auth_file: string|nil, key_file: string|nil }
---@return table store
function M.new(options)
  local paths = M.default_paths()
  options = options or {}

  return setmetatable({
    auth_file = vim.fs.normalize(options.auth_file or paths.auth_file),
    key_file = vim.fs.normalize(options.key_file or paths.key_file),
    cache = nil,
  }, Store)
end

return M
