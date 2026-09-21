--- Asking the user to approve an escalated tool call.
---
--- The built-in confirm prompt is modal and keyboard-driven, which is what this
--- needs: a decision with a reason attached, no window to manage, and a default
--- that is safe.
---
--- **Escape, Ctrl-C and a closed prompt all deny**, because `confirm` returns 0
--- for each. Defaulting the highlighted answer to Deny means a user who hits
--- Enter without reading also denies. Consent should require an action, not the
--- absence of one.
---
--- Modes take this through their `ui` field, so a test never calls it.

local M = {}

M.ALLOW = 1
M.DENY = 2

--- Ask about one permission request.
---@param permission table { tool, reason, target }
---@return boolean approved
function M.decide(permission)
  local lines = {
    ("%s wants to go outside the selection:"):format(permission.tool or "the agent"),
    "",
    ("  %s"):format(permission.reason or "no reason given"),
  }

  local choice = vim.fn.confirm(table.concat(lines, "\n"), "&Allow\n&Deny", M.DENY, "Question")
  return choice == M.ALLOW
end

return M
