# 0002. A typed event contract is the core abstraction

- Status: Accepted
- Date: 2026-09-20

## Context

The previous provider contract was string-shaped: `_build_command(query,
context) -> string[]`, then `observer.on_stdout(line)` and a final
`observer.on_complete("success", text)`.

That shape is the fatal smell. Once the response is an opaque string, nothing
downstream can distinguish "the model wants to read a file" from "the model
wrote prose about reading a file". Tool execution then has to be recovered by
parsing delimiters out of the text — which is what `<FILE_CHANGE>`/`<CONTENT>`
was doing.

## Decision

A single typed event schema is the interface between transports and everything
else. Transports translate vendor wire formats into it. The loop, the tools, the
permission layer, and the UI consume it and nothing else.

```text
text_delta       incremental assistant text
thinking_delta   incremental reasoning text, rendered distinctly
tool_use         { id, name, arguments } — the model requests a tool
tool_result      { id, ok, content | error } — our answer, fed back
usage            { input_tokens, output_tokens, ... } — per turn
done             terminal, with stop reason
error            terminal, with cause
```

Events are plain data. The module performs no I/O and holds no state.

The field-level schema — required fields, types, invariants and the `done`
reasons — is [events.md](../events.md). It is deliberately not duplicated here,
because the schema is expected to evolve as transports are added.

## Consequences

### Positive

- One place to reason about streaming, cancellation, and turn boundaries.
- Adding a vendor is a translation function, not a rewrite.
- The loop can be tested with a fake transport emitting scripted events, with no
  network and no model.
- Tool calls are first-class, so gating and scope enforcement have somewhere to
  attach.
- Usage events make cost observable, which is a stated goal of
  [0001](0001-own-the-agent-loop.md).

### Negative / costs

- The schema must be expressive enough for future transports. Anthropic's
  content blocks, OpenAI's `tool_calls`, and reasoning-token extensions do not
  map onto each other cleanly. The schema will need revisions.
- A field that only one vendor produces is a design smell to argue about rather
  than a thing to quietly add.

## Alternatives considered

**Keep the string contract and add a structured variant.** Rejected: two
contracts means the loop has two code paths, and the string one silently
degrades.

**Use the OpenAI wire format as the internal representation.** Rejected. It
would make one vendor's quirks structural, and it conflates "transport" with
"model". The internal schema should be ours.

## Related

- [0001](0001-own-the-agent-loop.md)
- [0008](0008-transport-openai-compatible-first.md)
- [events.md](../events.md) — the field-level schema
