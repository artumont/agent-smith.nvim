# 0008. First transport: OpenAI-compatible chat completions

- Status: **Accepted** — confirmed by the maintainer on 2026-09-21, with one
  amendment. OpenAI-compatible chat completions first, for custom providers.
- Date: 2026-09-20

## Context

[0001](0001-own-the-agent-loop.md) established that we own the loop and that
model access is a transport ([0002](0002-typed-event-contract.md)). The first
transport to implement still has to be chosen.

An earlier framing of this question offered CLI wrappers as options. That was a
framing error: owning the loop means owning the streaming client, so CLI
wrappers are not candidates here. They remain interesting only as *additional*
transports, because subscription auth (Claude Max, Copilot) is unavailable to a
direct API client.

## Proposal

Implement **OpenAI-compatible `chat/completions` with `tool_calls`, streamed over
SSE** as the first transport.

Reasons:

- One client covers OpenAI, Ollama, vLLM, llama.cpp, Groq, OpenRouter, and most
  other vendors.
- The SSE format is the simplest of the major wire formats to parse.
- It permits the entire loop to be developed and tested against a **local model
  with no API key and no billing**, which matters because the first eight tasks
  should not require spending anything.

An Anthropic adapter follows once the loop works, at which point the event schema
([0002](0002-typed-event-contract.md)) has already been proven vendor-neutral.

## Consequences

### Positive

- Cheapest path to a working loop end to end.
- Broad vendor coverage from one adapter.
- Local models make tests hermetic and free.

### Negative / costs

- OpenAI's tool-calling shape becomes the reference shape, which risks it
  leaking past the transport boundary into the schema. The schema must stay
  ours.
- Local model tool-calling is materially weaker than frontier models, so early
  loop testing is against a weaker partner. Expect tool-call formatting bugs
  that a good model would not produce.
- Anthropic's content-block format does not map cleanly onto `tool_calls`;
  the second adapter is where the schema gets stress-tested.

## Alternatives considered

**Anthropic direct first.** The strongest control story — prompt caching and
exact cost accounting are most visible there. Deferred because it requires an
API key and billing to develop against, and it is not the widest coverage.

**`claude -p --output-format stream-json` first.** Rejected as the *first*
transport. It gives real typed `tool_use`/`tool_result` events and reuses an
existing subscription, but tool execution stays inside the CLI, so the
permission model in [0005](0005-permission-model.md) is only partially
enforceable. Viable later as an extra transport.

**`pi --mode json` / `--mode rpc` first.** Rejected for the same reason: one
adapter, many providers, but CLI-side tool execution.

**A local model transport as a test-only fixture.** Adopted implicitly — the
local path is useful for tests whether or not it is the headline vendor.

## Amendment, 2026-09-21

The proposal was confirmed for **custom providers**: a user-supplied base URL,
key and model, which is what Ollama, vLLM, llama.cpp and OpenRouter speak. Chat
completions is the right first target for that.

What this record did not anticipate: the integrated gateways do not expose one
API. OpenCode Zen and Go serve open models on `/chat/completions` and GPT-family
models on `/responses`, and CommandCode serves Claude models on `/messages`
only. Chat completions alone therefore reaches only part of the catalogue on the
very providers this record was written to support. See
[0010](0010-integrated-providers-are-presets.md).

## Related

- [0001](0001-own-the-agent-loop.md)
- [0002](0002-typed-event-contract.md)
- [0010](0010-integrated-providers-are-presets.md)
- [../providers.md](../providers.md) — base URLs, credentials, endpoint routing
