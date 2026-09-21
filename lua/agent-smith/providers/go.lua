--- OpenCode Go.
---
--- The subscription tier on the same account as Zen, so it shares the credential
--- and the routing rule, and differs only in base URL.

local Base = require("agent-smith.providers.base")

return Base.new({
  name = "OpenCode Go",
  base_url = "https://opencode.ai/zen/go/v1",

  -- Go is a subscription on the Zen account: one sign-in covers both.
  env = "OPENCODE_API_KEY",
  auth_key = "opencode",

  session_header = "x-opencode-session",
  model_prefix = "opencode",

  -- Published endpoint table: Grok and the GPT family on /responses, the open
  -- models on /chat/completions.
  responses_prefixes = { "gpt-", "grok-" },
})
