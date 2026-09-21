--- OpenCode Zen.
---
--- A curated gateway over tested models. Its model list carries no routing of
--- its own, so a documented rule stands in: the GPT models are served on
--- `/responses`, everything else on `/chat/completions`
--- (spec/decisions/0012-models-are-fetched-not-catalogued.md).

local Base = require("agent-smith.providers.base")

return Base.new({
  name = "OpenCode Zen",
  base_url = "https://opencode.ai/zen/v1",

  -- OpenCode's own store, so signing in there is enough.
  env = "OPENCODE_API_KEY",
  auth_key = "opencode",

  -- Go asks clients for this so successive requests land on the upstream that
  -- already holds the cached prefix.
  session_header = "x-opencode-session",

  -- `opencode models` prints ids as "opencode/<id>"; the wire wants <id>.
  model_prefix = "opencode",

  -- The fallback, because this gateway publishes no per-model routing.
  responses_prefixes = { "gpt-" },
})
