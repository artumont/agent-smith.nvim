# Providers

Where the model actually comes from. The decision behind this split is
[decisions/0010](decisions/0010-integrated-providers-are-presets.md); this
document is the reference table.

> **Not yet verified.** The base URLs, endpoint paths and model-to-format split
> below come from the vendors' own documentation. No request has been made
> against any of them from this codebase. Expect the first live call to correct
> something here.

## Two kinds of provider

**Custom** — the user supplies a base URL, a key and a model. Speaks OpenAI chat
completions. This covers Ollama, vLLM, llama.cpp, LM Studio, OpenRouter, and any
other OpenAI-compatible endpoint. It is the default and needs no code.

**Integrated** — a preset: a known base URL, a known place to find the
credential, and a model catalogue recording which wire format each model needs.
Adding one is a table entry, not a transport.

v1 implements exactly three: **OpenCode Go**, **OpenCode Zen**, and **Command
Code** (the GOAT plan).

## Three wire formats, and why

The gateways do not expose one API. Each model is served on one of three, and
sending a model to an endpoint it is not served on is rejected with a `400`:

| Format | Path | Serves |
|---|---|---|
| OpenAI Chat Completions | `/chat/completions` | custom providers; open models on the gateways |
| OpenAI Responses | `/responses` | GPT-family models on the gateways |
| Anthropic Messages | `/messages` | Claude models on Command Code |

Command Code states the routing rule outright:

> OpenAI and open models answer on `/v1/chat/completions`, and most of them on
> `/v1/responses` as well. Claude models answer on `/v1/messages` only.

So model-to-format routing is **data**, carried in the catalogue, rather than
something the user has to know or the transport has to guess.

Only the first format is implemented so far. Custom providers and the open
models work today; GPT and Claude models on the gateways do not, and will fail
until the other two adapters exist.

## Integrated providers

### OpenCode Zen

| | |
|---|---|
| Base URL | `https://opencode.ai/zen/v1` |
| Chat Completions | open models |
| Responses | GPT-family models |
| Credential | `~/.local/share/opencode/auth.json` → `["opencode"].key` |
| Env override | `OPENCODE_API_KEY` |

### OpenCode Go

| | |
|---|---|
| Base URL | `https://opencode.ai/zen/go/v1` |
| Chat Completions | open models |
| Responses | GPT-family models |
| Credential | the same Zen key; Go is a subscription on the Zen account |

Go and Zen share an account and a key, so they share a credential lookup and
differ only in base URL and catalogue.

### Command Code (GOAT plan)

| | |
|---|---|
| Base URL | `https://api.commandcode.ai/provider/v1` |
| Chat Completions | OpenAI and open models |
| Responses | most OpenAI and open models |
| Messages | Claude models only |
| Model list | `GET /models`, live |
| Credential | `CMD_API_KEY`, generated in Studio; same key as the CLI |
| Optional | `x-cmd-zdr: 1` requests zero data retention. A model with no ZDR-capable upstream **fails** with `422` rather than falling back |

## Credential lookup

In order:

1. an explicit key in configuration
2. the provider's environment variable
3. agent-smith's own store, `auth.json`, encrypted at rest

The store and its explicit limits are
[decisions/0011](decisions/0011-credentials-encrypted-at-rest.md).

Importing a key another tool already holds is a possible convenience, not
implemented. OpenCode's `~/.local/share/opencode/auth.json` would suit it — a
plain `{ "opencode": { "type": "api", "key": "..." } }`. pi's would not: it
holds `commandcode` as OAuth tokens with an expiry (`refresh`, `access`,
`expires`) rather than a key, so reusing it would mean implementing a refresh
flow and depending on pi's token layout.

The key is passed to `curl` through the child process environment rather than
through `argv`, because `argv` is world-readable in `ps` while a process's
environment is restricted to its owner. The residual exposure is that the same
user can read `/proc/<pid>/environ`.

## Caching

Prompt caching is vendor-side and gateway-mediated: we cannot turn it on. What we
can do is fail to break it, because the gateways' own numbers assume it.

OpenCode Go's usage table prices it explicitly — `Input | Output | Cached Read |
Cached Write` — so a cached read is several times cheaper than fresh input (GLM-5.3:
`$1.40 / $4.40 / $0.26 / -`). More telling are their estimated tokens per request:

```text
GLM-5.3      700 input, 52,000 cached, 150 output
Kimi K3    1,050 input, 76,500 cached, 300 output
LongCat-2    920 input, 88,900 cached, 200 output
```

That shape is a large stable prefix re-sent every turn, which is exactly what an
agent loop produces. Uncached, that request bills 52,000 input tokens instead of
700.

Three things we control:

1. **Prefix byte-stability.** The cacheable prefix is system prompt, tool schemas
   and prior messages. Any byte change invalidates it from that point on, so
   volatile content — current buffer, cursor, diagnostics — belongs at the end,
   never in the prefix.
   Request bodies are encoded by `agent-smith/json.lua` rather than
   `vim.json.encode`, because object key order there follows table iteration
   order: sorting the keys before inserting them was measured to make no
   difference, so the object is emitted directly with keys sorted.
2. **Session identity.** OpenCode Go asks clients to send `x-opencode-session`
   per conversation "so we can optimize routing and prompt caching" — the same id
   keeps requests on the upstream holding the cache. Ours is keyed on the project
   root and the mode (`agent-smith/session.lua`), so restarting Neovim inside the
   cache's lifetime still lands on the same upstream. A fresh id per conversation
   would be more precise about what a conversation is, and would also mean every
   restart pays for the prefix again.
3. **Turn count.** Every turn re-sends the whole prefix, so one turn with three
   tool calls is much cheaper than three turns with one.

One interaction worth knowing: Anthropic's cache expires in about five minutes.
The escalation flow stops mid-turn to wait for a human, so someone who ponders a
permission prompt for six minutes loses the cache before the next turn.

Usage reporting is the thing to build next: `cache_read_tokens` and
`cache_write_tokens` are already carried on the `usage` event and summed by the
loop, but nothing surfaces them yet, and a cost strategy that cannot be measured
is guesswork.

## Streaming

Every gateway supports `stream: true` with SSE, and all three report token usage
at the end of a stream without opt-in:

- Chat Completions: a final `usage` chunk (Command Code); OpenAI proper requires
  `stream_options.include_usage`
- Responses: usage on the terminal `response.completed` event
- Anthropic Messages: usage in `message_delta`
