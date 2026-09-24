--- Who the model is talking as.
---
--- Every system prompt in this plugin starts here. The model does not otherwise know
--- what harness it is running inside, and the prompts it has seen most of belong to
--- other products: left alone it introduces itself as Claude Code, or offers a tool
--- that does not exist here because the one it was trained on had it. That is not a
--- cosmetic problem — a run that offers a tool it does not have and then reports
--- having used it is a run whose report cannot be trusted.
---
--- A module rather than a line copied into each prompt: there are three system
--- prompts (inline, plan, execute) and a fourth would have to remember. Each builds
--- its own body and calls `M.system` with it, so the shared part cannot drift and
--- the mode-specific part stays in the file that is about that mode.
---
--- Deliberately no version number in the text. The prompt prefix is what a gateway
--- caches ([0013](spec/decisions/0013-usage-input-tokens-excludes-cached.md)), and a
--- version that changes on release would invalidate every cached prefix — the whole
--- conversation re-read from scratch, on every release — for a fact the model has no
--- use for.

local M = {}

M.NAME = "agent-smith"
M.AUTHOR = "artumont"

--- The identity paragraph, as the opening of a system prompt.
---
--- Three claims, each for a failure that was observed or is one prompt away:
---
---   - what it is, so it does not have to guess and guess wrong;
---   - that it is not another product, because the guess it makes is Claude Code;
---   - that the tool list is closed, because an invented tool is worse than a
---     refusal: the model reports work it could not have done.
---@return string
function M.intro()
  return table.concat({
    ("You are %s, a Neovim plugin by %s that runs its own agent loop."):format(M.NAME, M.AUTHOR),
    "",
    "You are not Claude Code, and not any other coding agent or command-line tool:",
    "this is the whole of what you are running inside. The tools listed in this",
    "request are the only ones you have, whatever else your training suggests, so",
    "never offer, claim or report using one that is not listed — say that you cannot",
    "do it instead.",
  }, "\n")
end

--- A mode's own system prompt, behind the identity.
---
--- Identity first, body after it, one blank line between: the body is written as
--- instructions to follow, and instructions read as continuations of the sentence
--- before them.
---@param body string The mode's own system prompt.
---@return string
function M.system(body)
  if type(body) ~= "string" or body == "" then
    return M.intro()
  end
  return M.intro() .. "\n\n" .. body
end

return M
