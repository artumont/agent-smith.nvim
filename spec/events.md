# Event schema

The concrete form of the typed event contract decided in
[decisions/0002-typed-event-contract.md](decisions/0002-typed-event-contract.md).

This document is the field-level reference. The decision record says *why* a
typed contract exists; this says *what* it is. The schema is expected to grow as
transports are added, which is why it lives here rather than inside the record.

Implementation: `lua/agent-smith/agent/events.lua`.
Tests: `test/spec/events_spec.lua`.

## Representation

Events are plain Lua tables. No metatables, no methods, no identity, no I/O.

```lua
{ type = "text_delta", text = "hello" }
```

- `type` is a required string and selects the variant.
- Fields not listed for a variant are **ignored**, not rejected. This is what
  allows a transport to be updated before this schema is.
- A table may be built directly or with a constructor. `Events.validate()` is
  the boundary check; constructors do not validate.

## Types

| `type` | Fields | Meaning |
|---|---|---|
| `text_delta` | `text: string` | Incremental assistant text |
| `thinking_delta` | `text: string` | Incremental reasoning, rendered distinctly |
| `tool_use` | `id: string`, `name: string`, `arguments: table` | The model requests a tool |
| `tool_result` | `id: string`, `ok: boolean`, then `content: string` **or** `error: string` | Our answer, fed back |
| `usage` | at least one of the token fields | Token accounting for a turn |
| `done` | `reason: string` | Terminates a stream |
| `error` | `message: string`, `detail: string?` | Terminates a stream with a cause |

### `tool_use`

`arguments` is the **complete, decoded** argument object. Reassembling partial
JSON as it streams is the transport's job; the loop must never see a
half-parsed argument table. `arguments` may be empty, since a tool may take no
parameters.

`id` and `name` must be non-empty. `id` is the correlation key: the matching
`tool_result` carries the same value.

### `tool_result`

Exactly one of `content` or `error` is present, selected by `ok`:

```lua
{ type = "tool_result", id = "call_1", ok = true,  content = "..." }
{ type = "tool_result", id = "call_1", ok = false, error = "..." }
```

This is what is sent back to the model. It is deliberately the *resolved*
outcome — see "Not part of this schema" below.

### `usage`

Token fields, all optional individually, non-negative numbers when present:

| Field | Notes |
|---|---|
| `input_tokens` | **Uncached** prompt tokens. See the note below |
| `output_tokens` | Generated tokens |
| `cache_read_tokens` | Anthropic `cache_read_input_tokens`, OpenAI cached prompt tokens |
| `cache_write_tokens` | Anthropic `cache_creation_input_tokens` |
| `reasoning_tokens` | Billed reasoning tokens, where the vendor separates them |

`input_tokens` and `cache_read_tokens` are **disjoint**: the prompt is
`input_tokens + cache_read_tokens`, and `cache_read_tokens` is never part of
`input_tokens`. That is what Anthropic reports natively, and it is what the
OpenAI-shaped adapters have to be converted into, because OpenAI's
`prompt_tokens` (chat completions) and `input_tokens` (Responses) are totals
that *include* the cached tokens. Reporting a vendor total as `input_tokens`
counts the cached prefix twice in `agent-smith.usage.hit_rate`, which caps the
reported rate at 50% no matter how well the prefix caches — the bug behind
[0013](decisions/0013-usage-input-tokens-excludes-cached.md).

At least one must be present. A `usage` event may occur **more than once** in a
single stream — Anthropic reports input tokens at message start and output
tokens at message end — so consumers sum across events rather than reading only
the last one.

### `done`

`reason` is one of:

| Reason | Meaning |
|---|---|
| `complete` | The model finished naturally |
| `tool_calls` | The model wants tools run. Not final: the loop executes them and continues |
| `length` | Output token limit reached |
| `content_filter` | Blocked by the vendor |
| `cancelled` | We aborted it |

`tool_calls` is still a `done` event because it terminates one stream, even
though the request as a whole continues.

## Invariants

1. Every event has a string `type` naming a known variant.
2. A stream ends with `done` or `error`. Neither appears mid-stream.
3. Required fields are present with the stated type.
4. No event carries a metatable.
5. Extra fields do not invalidate an event.

`Events.is_terminal(event)` reports invariant 2 for a single event.

## Not part of this schema

Tool *outcomes* are not events. In particular the `needs_permission` result
described in
[decisions/0004-bounded-edit-with-escalation.md](decisions/0004-bounded-edit-with-escalation.md)
never reaches a transport.

The flow is:

```text
tool refuses an out-of-bounds edit  ->  outcome { needs_permission = ... }
        loop asks the user            ->  approved or denied
        loop resolves the outcome     ->  tool_result { ok = true | false, ... }
        transport sends tool_result   ->  the model
```

A `tool_result` is therefore always resolved. The outcome type belongs to the
tools layer — it is defined in `lua/agent-smith/tools/registry.lua` — rather
than here, so that this schema stays exactly what crosses the transport
boundary.

## Versioning

Adding a variant or an optional field is a compatible change: unknown fields are
ignored, so an older consumer degrades rather than breaking.

Changing a required field, removing a variant, or changing the meaning of an
existing field is incompatible and needs a decision record superseding
[0002](decisions/0002-typed-event-contract.md).
