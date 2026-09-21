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

  --- Credential storage.
  ---
  --- Omitting either path uses agent-smith.auth.default_paths(), which keeps the
  --- decryption key in the data directory while the encrypted file sits in the
  --- config directory. That split is deliberate: the config tree is the one that
  --- tends to be symlinked into a dotfiles repository. See agent-smith.auth.
  auth = {},
}

--- Recursively merge `overrides` into `base`, returning a new table.
---
--- Lists are replaced rather than merged, so overriding `blacklist` replaces it
--- wholesale instead of appending to the defaults.
local function merge(base, overrides)
  local merged = {}
  for key, value in pairs(base) do
    merged[key] = value
  end
  for key, value in pairs(overrides or {}) do
    if type(value) == "table" and type(merged[key]) == "table" and not vim.islist(value) then
      merged[key] = merge(merged[key], value)
    else
      merged[key] = value
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
