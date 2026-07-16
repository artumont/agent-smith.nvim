--- agent-smith/extensions/completions.lua
---
--- Completion framework for #rules and @files.
---
--- Architecture:
--- A registry of completion providers, each with:
--- - trigger: The character that activates it ("#" or "@")
--- - resolve: Function that converts a token to content
---
--- How it works:
--- 1. User types in prompt buffer
--- 2. Completion source (native/cmp/blink) detects trigger character
--- 3. Calls get_completions(trigger) to get suggestions
--- 4. User selects a completion
--- 5. On submit, parse() extracts all # and @ tokens from the prompt
--- 6. Each token is resolved to its content via the provider
--- 7. Resolved content is injected into the AI context
---
--- Registration:
--- Providers are registered during init():
--- - # -> resolves to SKILL.md content
--- - @ -> resolves to file content
---
--- Content injection:
--- The resolved content is added as references in the Prompt object.
--- The AI sees the file contents or rule definitions as part of its
--- context, without the user having to manually copy-paste them.

local M = {}

--- Registered completion providers keyed by trigger character.
---@type table<string, table>
M.providers = {}

--- Register a completion provider.
---
---@param provider table { trigger: string, resolve: function }
function M.register(provider)
  M.providers[provider.trigger] = provider
end

--- Parse a prompt text and resolve all # and @ references.
---
--- Extracts tokens like "#vim" or "@src/utils.lua" and resolves
--- them to their content using the registered providers.
---
---@param text string The user's prompt text
---@return table[] refs Array of { content: string }
function M.parse(text)
  local refs = {}

  for trigger, provider in pairs(M.providers) do
    -- Match trigger followed by non-whitespace
    local pattern = vim.pesc(trigger) .. "([^%s]+)"
    for token in text:gmatch(pattern) do
      local content = provider.resolve(token)
      if content then
        table.insert(refs, { content = content })
      end
    end
  end

  return refs
end

return M
