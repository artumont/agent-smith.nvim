--- Configuration defaults, merging and validation.
---
--- Option semantics are described in spec/architecture.md. Options that carry a
--- safety implication reference the decision record that justifies them.

local M = {}

M.defaults = {
  --- Register the :Smith command.
  commands = true,

  --- Register default keymaps.
  default_keymaps = true,

  sandbox = {
    --- Root for isolated clones. Must be absolute and outside the project.
    --- See spec/decisions/0006-sandbox-isolated-clone.md.
    root = vim.fs.joinpath(vim.fn.stdpath("cache"), "agent-smith", "sandbox"),

    --- Commands matching these Lua patterns are refused before execution.
    ---
    --- This is a guardrail against accidents, NOT a security boundary. Every
    --- entry is trivially bypassed by a shell. The boundary is the sandbox.
    --- See spec/decisions/0005-permission-model.md.
    blacklist = {
      "^%s*rm%s",
      "^%s*rm$",
      "^%s*mkfs",
      "^%s*dd%s",
      "^%s*shutdown",
      "^%s*reboot",
      "^%s*poweroff",
    },

    --- Allow network access inside the sandbox.
    --- See spec/open-questions.md Q2.
    network = false,
  },

  --- Where a run's status draws, relative to the selection.
  ---
  --- "above" puts it at the top of the work area, where the change begins.
  --- "below" puts it under the last selected line, so it never moves the lines
  --- being worked on as it appears.
  ---
  --- Both are defensible and it comes down to what the user is reading. Either
  --- way the status is anchored to the selection, so it cannot end up somewhere
  --- the user is not looking.
  ---
  --- Only inline has a selection to be above or below; vibe draws at the top of
  --- whatever buffer is current.
  progress = {
    position = "below",
  },

  --- Which provider preset to use, and which model.
  ---
  --- There is deliberately no default model: it depends on what the account can
  --- reach, and guessing one fails at request time with a vendor error rather
  --- than here. A call that needs a model says so.
  provider = nil,
  model = nil,

  --- Credential storage.
  ---
  --- Omitting either path uses agent-smith.auth.default_paths(), which keeps the
  --- decryption key in the data directory while the encrypted file sits in
  --- agent-smith's **own** config directory, `~/.config/agent-smith/`.
  ---
  --- That split is deliberate, and so is the location: the config tree is the one
  --- that tends to be symlinked into a dotfiles repository, but Neovim's own
  --- `~/.config/nvim` is the specific tree people commit. Putting the credential
  --- there would be the exact accident the encryption exists to prevent. See
  --- agent-smith.auth.
  auth = {},
}

--- Copy a value, deeply for tables.
---
--- Nested tables are copied rather than shared. Handing back the same `sandbox`
--- table that lives in `M.defaults` would mean a caller adding one blacklist
--- entry rewrites the defaults for every later `resolve()` in the process — the
--- kind of bug that shows up as a test passing alone and failing in a suite.
local function copy(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  return value
end

--- Recursively merge `overrides` into `base`, returning a new table.
---
--- Lists are replaced rather than merged, so overriding `blacklist` replaces it
--- wholesale instead of appending to the defaults.
local function merge(base, overrides)
  local merged = {}
  for key, value in pairs(base) do
    merged[key] = copy(value)
  end
  for key, value in pairs(overrides or {}) do
    if type(value) == "table" and type(merged[key]) == "table" and not vim.islist(value) then
      merged[key] = merge(merged[key], value)
    else
      merged[key] = copy(value)
    end
  end
  return merged
end

--- Check a resolved configuration.
---
---@param config table
---@return boolean ok
---@return string|nil error
function M.validate(config)
  if vim.fn.has("nvim-0.10") ~= 1 then
    return false, "Neovim 0.10 or newer is required (vim.json, vim.system)"
  end

  if type(config.commands) ~= "boolean" then
    return false, "commands must be a boolean"
  end
  if type(config.default_keymaps) ~= "boolean" then
    return false, "default_keymaps must be a boolean"
  end

  local sandbox = config.sandbox
  if type(sandbox) ~= "table" then
    return false, "sandbox must be a table"
  end
  if type(sandbox.root) ~= "string" or sandbox.root == "" then
    return false, "sandbox.root must be a non-empty string"
  end
  if sandbox.root:sub(1, 1) ~= "/" then
    return false, "sandbox.root must be an absolute path, got " .. sandbox.root
  end
  if type(sandbox.network) ~= "boolean" then
    return false, "sandbox.network must be a boolean"
  end
  if not vim.islist(sandbox.blacklist) then
    return false, "sandbox.blacklist must be a list of Lua patterns"
  end
  for index, pattern in ipairs(sandbox.blacklist) do
    if type(pattern) ~= "string" then
      return false, ("sandbox.blacklist[%d] must be a string"):format(index)
    end
  end

  local progress = config.progress
  if type(progress) ~= "table" then
    return false, "progress must be a table"
  end
  if progress.position ~= "above" and progress.position ~= "below" then
    return false,
      ('progress.position must be "above" or "below", got %s'):format(tostring(progress.position))
  end

  local auth = config.auth
  if type(auth) ~= "table" then
    return false, "auth must be a table"
  end

  for _, field in ipairs({ "file", "key_file" }) do
    local path = auth[field]
    if path ~= nil then
      if type(path) ~= "string" or path == "" then
        return false, ("auth.%s must be a non-empty string"):format(field)
      end
      if path:sub(1, 1) ~= "/" then
        return false, ("auth.%s must be an absolute path, got %s"):format(field, path)
      end
    end
  end

  if
    config.provider ~= nil
    and type(config.provider) ~= "string"
    and type(config.provider) ~= "table"
  then
    return false, "provider must be a preset name or a declaration table"
  end
  if config.model ~= nil and (type(config.model) ~= "string" or config.model == "") then
    return false, "model must be a non-empty string"
  end

  return true
end

--- Merge defaults with `opts` and validate the result.
---
--- Raises on an invalid configuration rather than returning one, because every
--- caller of this function needs a usable config to do anything at all.
---
---@param opts table|nil
---@return table config
function M.resolve(opts)
  local config = merge(M.defaults, opts)
  local ok, err = M.validate(config)
  if not ok then
    error("agent-smith: invalid configuration — " .. err, 0)
  end
  return config
end

return M
