# 0010. Integrated providers are presets, not transports

- Status: Accepted
- Date: 2026-09-21

## Context

[0008](0008-transport-openai-compatible-first.md) settled the first transport:
OpenAI-compatible chat completions, for custom providers. The maintainer then
chose the integrated provider set: **OpenCode Go**, **OpenCode Zen**, and
**Command Code** (GOAT plan) — three, and no others.

Investigating those three turned up something 0008 did not anticipate. They are
not one API each. They are gateways that serve different models on different
wire formats from the same base URL:

| Format | Serves |
|---|---|
| OpenAI Chat Completions | open models |
| OpenAI Responses | GPT-family models |
| Anthropic Messages | Claude models |

Command Code documents the routing rule explicitly, and sending a model to an
endpoint it is not served on is a `400 invalid_request_error`. So "OpenAI-
compatible" is true of the gateways as a *base URL shape*, and false as a
description of how to reach every model on them.

## Decision

**An integrated provider is a preset, not a transport.** It is a table entry:

- a base URL
- a credential lookup (env var, or the vendor's own credential file)
- a model catalogue recording, per model, which wire format serves it

Adding a fourth integrated provider stays a data change. It does not add code to
the loop, the tools, or the event schema.

**Model-to-format routing is data.** The catalogue carries it. A user picks a
model; the preset decides which adapter and which path that model needs. The
user should not have to know that `gpt-5.6-sol` needs `/responses` while
`glm-5.3` needs `/chat/completions`.

**Third-party credentials are read from the vendor's own store where one
exists.** OpenCode keeps its key in
`~/.local/share/opencode/auth.json`, which is the file OpenCode itself reads.
Using it means the OpenCode providers need no setup from anyone already signed
in.

**The key never goes in `argv`.** It is passed to `curl` through the child
process environment, because `argv` is world-readable via `ps` while a process's
environment is restricted to its owner. Verified by probe.

## Consequences

### Positive

- Three providers cost one table each, not one adapter each.
- The loop, the tools and the event schema stay vendor-neutral: they see typed
  events and never learn which format produced them.
- The catalogue is the only place that must be kept current, and it is
  data that a doc can be wrong about without the code being wrong.

### Negative / costs

- **Three adapters are still required in the end.** Chat completions alone
  reaches custom providers and the open models; GPT-family and Claude models
  need the other two. So the "one client covers everything" appeal of 0008 holds
  for custom providers and only partly for the gateways.
- The catalogue duplicates vendor data and will drift. Command Code offers
  `GET /models`; the OpenCode gateways do not, so their side is maintained by
  hand or derived from `opencode models`.
- A wrong catalogue entry fails at request time with a vendor `400` rather than
  at configuration time.

## Alternatives considered

**One adapter per vendor.** Rejected: three vendors × three formats is nine
adapters, and the formats are shared, not vendor-specific.

**Drive Zen and Go through the `opencode` CLI instead of HTTP.** Rejected. That
is the wrapper design [0001](0001-own-the-agent-loop.md) exists to replace: it
would restore the text-blob contract, hide tool calls, and put approval
downstream of a process that has already acted. It also cannot be sandboxed as
cleanly.

**Ship chat completions only, and never the other two formats.** Rejected, but
worth recording as the tempting option. It is simpler and it works for the open
models. It also makes Claude models unreachable on Command Code, which is a
large part of why someone would pick that provider — a catalogue that silently
cannot reach the best models is worse than a smaller catalogue that can.

**Infer the endpoint from the model name.** Rejected: it works until a vendor
renames something, and the failure mode is a confusing `400` rather than a
missing catalogue entry.

## Amendment, 2026-09-21

The model catalogue described above was implemented as a hardcoded table of ids
taken from published documentation, and measuring it showed why that was wrong:
CommandCode serves 55 of its 71 models on `/chat/completions`, and the table
refused almost all of them.

The list is now fetched from each provider instead
([0012](0012-models-are-fetched-not-catalogued.md)). That removes the "catalogue will
drift" cost recorded below, and leaves the rest of this decision intact: a
provider is a preset with a base URL, a credential, and a way of establishing
routing.

## Related

- [0001](0001-own-the-agent-loop.md)
- [0008](0008-transport-openai-compatible-first.md)
- [0012](0012-models-are-fetched-not-catalogued.md) — supersedes the catalogue part
- [../providers.md](../providers.md) — base URLs, credentials, routing table
