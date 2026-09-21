--- Stable session identity for prompt-cache routing.
---
--- OpenCode Go asks clients to send a session id per conversation, "so we can
--- optimize routing and prompt caching". The cache lives upstream for a few
--- minutes, so the id's job is to keep successive requests on the upstream that
--- already holds the prefix rather than spreading them across providers that
--- each pay to cold-read it.
---
--- Keyed on the project root and the mode rather than generated fresh per
--- conversation, so restarting Neovim inside the cache's lifetime still lands on
--- the same id. That is a deliberate trade: a fresh id per conversation would be
--- more precise about what "a conversation" is, and would also mean a restart
--- always pays for the prefix again.

local M = {}

M.PREFIX = "smith"

--- A session id for a project and mode.
---
--- Hashed because the id is built from a filesystem path: it has to be short,
--- stable, and free of anything that needs escaping wherever it is used.
---@param fields? table { root: string|nil, mode: string|nil }
---@return string
function M.id(fields)
  fields = fields or {}
  local root = vim.fs.normalize(fields.root or vim.uv.cwd() or ".")
  local mode = fields.mode or "default"

  return ("%s-%s"):format(M.PREFIX, vim.fn.sha256(root .. "|" .. mode):sub(1, 16))
end

return M
