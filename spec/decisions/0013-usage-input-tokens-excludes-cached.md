# 0013. `input_tokens` means uncached prompt tokens

- Status: **Accepted** — confirmed by the maintainer on 2026-09-22 (same
  session as this record's first draft).
- Date: 2026-09-22

Amends the `usage` variant of [0002](0002-typed-event-contract.md); it does not
supersede it. No field is added or removed — one field's meaning is pinned down.

## Context

[0002](0002-typed-event-contract.md) gave the `usage` event a `cache_read_tokens`
field so a cache hit rate could be reported at all, and `agent-smith.usage`
computes it as

```lua
cached / (input_tokens + cached)
```

That arithmetic assumes the two fields are **disjoint**: `input_tokens` is what
was not cached and `cache_read_tokens` is what was. It is right for Anthropic,
which reports `input_tokens` as the uncached part with
`cache_read_input_tokens` beside it.

It is wrong for every OpenAI-shaped response, because there `prompt_tokens`
(chat completions) and `input_tokens` (Responses) are **totals that include the
cached ones**, with `prompt_tokens_details.cached_tokens` a subset of the same
number. Feeding the vendor total into `input_tokens` therefore counts the cached
prefix twice: a request with a 512-token prompt fully served from cache reports
`input_tokens = 512, cached = 512` and a rate of `512 / 1024` — **50%**.

That is not a rounding artefact, it is a ceiling: the reported rate of a perfect
cache is exactly 50%, and a genuinely good cache reads as a mediocre one. This
was observed on the gateways this plugin actually talks to, which are
OpenAI-shaped (spec/providers.md), where the reported hit rate never rose above
50% and was simultaneously the number the user is meant to watch when judging
whether prefix caching works.

## Decision

**`input_tokens` is the uncached part of the prompt. `cache_read_tokens` is the
cached part. They are disjoint, and the prompt is their sum.**

This is Anthropic's native shape and stays the schema's shape. Every adapter is
responsible for converting its vendor's shape into it:

- `transport/anthropic.lua` passes the vendor's fields through, because the
  vendor already means this.
- `transport/openai_compat.lua` emits `prompt_tokens - cached_tokens` as
  `input_tokens`, clamped at zero.
- `transport/responses.lua` does the same for `input_tokens - cached_tokens`.

`agent-smith.usage.hit_rate` is unchanged, because with disjoint fields it was
always correct.

## Consequences

### Positive

- The reported hit rate is the true cached share of the prompt, for every
  adapter, with no per-vendor arithmetic at the consumer.
- `input_tokens` keeps one meaning, so nothing downstream has to know which
  vendor a number came from.
- No field is added, so no consumer needs a new branch.

### Negative / costs

- **The reported `input_tokens` is no longer the vendor's own number.** Someone
  reconciling a status line against a vendor invoice or dashboard sees "8 in"
  where the dashboard says 11 prompt tokens. The total is still recoverable
  (`input + cached`), but the number on screen is no longer the one on the bill.
- Adapters must read the cached count *before* the total, since the conversion
  depends on both. Reordering that block silently reintroduces the 50% ceiling,
  which is why `test/spec/openai_compat_spec.lua` pins the all-cached case at a
  rate of 1 and the arithmetic is spelled out at both call sites.
- A vendor that reports a cached count *larger* than its total is clamped to
  zero rather than trusted. That shape has not been seen anywhere; clamping is
  chosen because a negative token count is nonsense and a malformed usage field
  should not stop a run.

## Alternatives considered

**Add a `prompt_tokens` field alongside `input_tokens`.** Keep the vendor total
as reported and let `hit_rate` prefer the total when present, falling back to
`input + cached`. This is a compatible schema addition and keeps the number on
screen equal to the number on the invoice, which is a real advantage. Rejected
because it leaves three overlapping prompt fields (`input_tokens`,
`prompt_tokens`, `cache_read_tokens`) whose relationship every future consumer
has to be told about, and it makes "which field do I read for a prompt size?"
depend on which vendor the event came from — the leak the transport boundary
exists to prevent ([0008](0008-transport-openai-compatible-first.md)).

**Fix it in `hit_rate` only.** Detect the overlap by comparing the fields, e.g.
treat `input_tokens` as a total when `cached <= input_tokens`. Rejected because
the comparison is satisfiable by both shapes — a vendor total of 512 with 512
cached and a disjoint pair of 512 uncached with 512 cached are indistinguishable
— so the heuristic would be wrong half the time and silently so.

**Report both rates.** Show a vendor-shaped rate and a disjoint one. Rejected as
two answers to one question: one of them is a bug in a different hat.

## Related

- [0002](0002-typed-event-contract.md) — the event contract this amends
- [0008](0008-transport-openai-compatible-first.md) — why the vendor default is
  OpenAI-shaped
- [0012](0012-models-are-fetched-not-catalogued.md) — the gateways and their
  publishing behaviour
- [../events.md](../events.md) — the field-level reference
- [../providers.md](../providers.md) — which endpoints answer in which shape
