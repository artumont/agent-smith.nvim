# 0014. A stalled run is aborted on inactivity

- Status: **Accepted** — confirmed by the maintainer on 2026-09-22 (same
  session as this record's first draft).
- Date: 2026-09-22

## Context

[0001](0001-own-the-agent-loop.md) made the loop ours, which means a request that
never finishes is ours to notice. What was observed: a semi-complex plan ran, the
agent called `bash` for a command checking `go` and `python` versions, and the run
never came back. Nothing was wrong with the model or the gateway — the command
had stopped short of reporting a result, and the loop had nothing to do but wait.

The existing bounds do not cover this:

- `max_turns` bounds the number of model round trips, not the length of one.
- The bash tool's own `timeout_ms` (one minute by default) bounds the *command*,
  but a process that is killed without its callback firing leaves a tool call
  that never produces an outcome. `registry.lua` states the invariant plainly: a
  handler that neither returns nor calls `context.finish` leaves the request
  hanging. That is the one way to write a broken tool, and there is one.
- The transport's timeout bounds a request, and the loop handles a transport
  error. A transport that is simply silent is not an error to it.

So the only recovery was `<leader>ax`, by hand, by a user who had to guess
whether the run was hung or thinking. That guess is not reasonable to ask of
anybody: from the outside, a hung run and a slow one look identical.

## Decision

**The loop aborts a request that produces no event for `stall_timeout_ms`
(default 120000, `0` disables).**

- The budget is **inactivity, not duration**. Every event re-arms it, so a stream
  that keeps arriving is working however slow it is, and a long answer is never
  mistaken for a stall.
- Waiting on the **user** is not inactivity. The watchdog is disarmed while
  `on_permission` is pending, because a dialog has no deadline and aborting a run
  for the crime of asking would be worse than the bug.
- On firing, the in-flight transport is cancelled and the loop finishes with
  `reason = "stalled"` and an error naming what it was waiting on, e.g.
  `no activity for 120 s while running bash`.
- `result.cancelled` stays **false**: this is the loop giving up, not the user
  cancelling, and a caller has to be able to tell the two apart.

## Consequences

### Positive

- A hung run ends by itself, with a cause attached, instead of needing a human to
  guess and interrupt it.
- The failure is reported through the same path as every other one — `on_done` —
  so no UI, mode or test needs a second way to learn a run ended.
- A silent 30-second wait during a legitimate slow tool is still allowed; the
  budget is generous against the waits that actually happen (the bash tool's own
  default timeout is one minute).

### Negative / costs

- **A legitimately silent long-running tool is aborted.** A build or a test suite
  that runs for two minutes without printing anything trips the watchdog, and the
  run stops with an error. Raising `stall_timeout_ms` or passing a longer
  `timeout_ms` from the model are the answers; there is no way to distinguish
  "silent because it is working" from "silent because it is dead", which is
  precisely the ambiguity that makes the watchdog worth having.
- The timer is a `vim.uv` timer inside the loop, so the loop now depends on
  Neovim's event loop rather than only on its conversation and transports. It
  was already a Neovim plugin, but the boundary is a little blurrier.
- A tool that blocks the loop entirely — synchronously, without yielding — is not
  caught, because a `vim.uv` timer cannot fire while Neovim is blocked. Nothing
  in this codebase does that; anything that starts to would need this noted.
- `on_permission` that never answers is now the one unbounded wait, deliberately.
  It is bounded in practice by the user's patience and by `<leader>ax`.

## Alternatives considered

**No watchdog.** This is what was there, and it produced the observed hang. The
user becomes the timeout, and the user cannot tell a stall from a slow answer
without a second surface showing the stream ([0015](0015-the-event-stream-is-visible.md)).

**Ask the user when a run looks stalled.** Put a "still waiting, keep going?"
dialog up after the budget. Rejected because the loop is deliberately UI-agnostic
([0002](0002-typed-event-contract.md)): the only question it may ask is the one
it already asks, and adding a second callback for a second question makes the
loop's contract depend on a dialog existing. A caller that wants to extend the
deadline can run with a bigger budget.

**Bound each tool call instead of the whole loop.** Closer to the symptom, but it
only covers tools: a transport that opens a stream and then says nothing forever
is equally stuck, and it is the harder case to notice. Inactivity covers both
without knowing which one is at fault.

**Kill at the tool layer, in `bash`.** Already exists (`timeout_ms`) and was not
enough — see the context. A tool-level timeout cannot cover a tool that never
calls `context.finish`, nor the transports.

## Related

- [0001](0001-own-the-agent-loop.md) — the loop being ours is what makes this a
  decision rather than a vendor's setting
- [0002](0002-typed-event-contract.md) — why the watchdog reports through
  `on_done` rather than through a new event type
- [0015](0015-the-event-stream-is-visible.md) — the surface that makes a stall
  legible
- [../architecture.md](../architecture.md) — the loop and its inputs
