--- Command Code.
---
--- The Provider API. Unlike the OpenCode gateways it publishes routing, as
--- `supported_endpoints` on each entry of `GET /models`, so the fetched
--- catalogue is authoritative here and the rule below is only the offline
--- fallback.
---
--- Measured 2026-09-21: 71 models, of which 55 support `/chat/completions`,
--- 8 are `/messages` only, and 8 are `/chat/completions` only.

local Base = require("agent-smith.providers.base")

return Base.new({
  name = "Command Code",
  base_url = "https://api.commandcode.ai/provider/v1",

  env = "CMD_API_KEY",
  auth_key = "commandcode",

  -- Its documentation does not mention a session header.
  session_header = nil,

  -- The offline fallback, from the documentation: "Claude models answer on
  -- /v1/messages only." Without this a stale or absent catalogue would route a
  -- Claude model to an endpoint that refuses it.
  messages_prefixes = { "claude-" },
})
