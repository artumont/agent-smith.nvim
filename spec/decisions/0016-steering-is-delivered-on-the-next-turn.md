# 0016. A steer is delivered on the next turn

- Status: **Accepted** — confirmed by the maintainer on 2026-09-22 (same
  session as this record's first draft).
- Date: 2026-09-22

## Context

[0015](0015-the-event-stream-is-visible.md) put the event stream in a window,
which made a run legible. Legible is half of it: the reason to watch a run is to
notice it going wrong *while* it can still be corrected, and the window had no way
to say anything back. Correcting a run that is heading the wrong way meant
`<leader>ax` and starting again — losing the work done so far, and the context the
model had accumulated.

So: somewhere to type a message to the run in flight (the monitor's `s`). The
question this record settles is what "sent" means, because the obvious
implementation is wrong in three separate ways.

- **A turn already streaming cannot be re-told.** The transport has been handed
  the messages and is mid-answer; there is no way to insert anything into it. Any
  message added while it streams can only arrive with a later request.
- **A steer usually arrives while a tool is running**, and the conversation at
  that moment is one assistant message holding `tool_use`s whose results have not
  been appended yet (the loop appends them when the tool answers). Putting a user
  message there — which is what appending on arrival does — produces
  `assistant(tool_calls)` → `user(text)` → `tool(results)`. Both wire formats
  reject that: a tool result has to follow the call it answers. Measured against
  the adapters, not guessed: the ordering is the one `Conversation` documents.
- **A steer can arrive as the model finishes.** Appended to the conversation and
  never sent, because the loop's next act is to stop. Accepted, logged, and
  silently dropped — indistinguishable, to the user, from a model ignoring them.

## Decision

**A steer is queued, flushed at the start of a turn, and extends the run by a
turn if it arrives as the model is stopping.**

Concretely, `handle:steer(text)` (loop):

1. Refuses (`false`) when the run has finished or was cancelled, or the text is
   blank. `false` is what lets a caller say "that was not sent" instead of
   pretending.
2. Otherwise queues it. Nothing is appended to the conversation yet.
3. The queue is flushed at the start of a turn, immediately before the request is
   built — which is after any tool results have been recorded, so the message
   lands where both wire formats allow a user turn.
4. A turn that ends with the model stopping *and* a non-empty queue does not end
   the run: it starts another turn, so what the user typed is answered rather
   than dropped. `max_turns` still bounds the run, and the count of steers that
   never left is reported in the result (`undelivered_steers`), which the monitor
   shows rather than leaving an unanswered line in the log.

## Consequences

### Positive

- What the user typed either reaches the model or is reported as not having
  reached it. There is no third outcome that looks like the model ignoring them.
- The conversation stays wire-valid by construction: the flush point is the one
  place the ordering is known to be right, instead of every arrival point having
  to reason about tool results.
- Steering composes with the rest of the loop for free — the steer is just a user
  message by the time anything else sees it, so prompt caching, compaction (when
  it exists) and the transports need to know nothing about it.

### Negative / costs

- **A steer can cost a turn.** A user who steers as the model is finishing gets
  another request they may not have intended, and it is billed. This is the
  deliberate trade against silently dropping the message; `<leader>ax` is how to
  stop the run instead, and the monitor shows the extra turn happening.
- **It is not an interruption.** A steer cannot stop a long tool or a long answer
  mid-flight; it applies from the next request. A user expecting "stop and go
  left" gets "go left at the next turn", which for a two-minute command is a real
  difference.
- Steering is refused, not queued, once the loop has finished — including between
  the phases of a vibe run, where there is no loop running at all. A user who
  wants to add something at that point has to do it in the next phase's prompt.
- Several steers arriving in one turn are flushed in order as consecutive user
  messages. Both wire formats accept consecutive user turns, but they are not
  merged, so the model sees them as separate messages.
- `undelivered_steers` is a count, not the text. Recovering what was lost means
  reading the monitor's log, which is why the steer input writes there before it
  knows whether the message was accepted.

## Alternatives considered

**Append on arrival.** The obvious implementation, and invalid — see the context.
It was written first and the test caught it, which is the reason the ordering note
is spelled out here.

**Interrupt the turn: cancel, deliver, restart.** This is what "steer" means in
some tools, and it is genuinely more responsive. Rejected because it discards the
answer in flight and re-sends the whole conversation, which is the expensive path
this plugin is otherwise careful about (see
[0013](0013-usage-input-tokens-excludes-cached.md)), and because it makes steering
destructive: the user cannot add a thought without throwing work away. Cancelling
already exists for that, and stays the explicit way to interrupt.

**Deliver only to a turn the model would have taken anyway.** Cheapest, no extra
turns. Rejected: it drops the message whenever the model was about to stop, which
is precisely when a user is most likely to be typing — they can see it is
finishing.

**A separate "continue with this message" API.** Keeps steering purely additive
and never extends a run. Rejected as two names for one user action, with the
distinction only visible in timing; and it leaves the drop case in place.

## Related

- [0002](0002-typed-event-contract.md) — why the steer is a plain user message at
  the boundary and not a new event type
- [0014](0014-stalled-runs-are-aborted.md) — the other thing watching a run in
  flight is for
- [0015](0015-the-event-stream-is-visible.md) — the window the steer input lives
  in, and the log it writes to
- [../architecture.md](../architecture.md) — the loop's handle and its inputs

## Amendment, 2026-09-22 — what a steer targets in a vibe run

One negative above is superseded: *"Steering is refused, not queued, once the loop
has finished — including between the phases of a vibe run, where there is no loop
running at all. A user who wants to add something at that point has to do it in the
next phase's prompt."* Between the phases of a vibe run a steer is now **held**, not
refused.

A vibe run is two conversations with checkpoints between them
([0007](0007-vibe-workflow.md)), and "no loop is running" is true for most of it:
the plan is being written, or it is sitting in a window waiting to be approved. A
steer typed there is not aimed at nothing — it is aimed at work that has not
started yet. Refusing it was treating "no loop" as "no run", which is what it
looks like from inside the loop and not what it looks like to the person typing.

So the target depends on the phase:

| Phase | Where the message goes |
|---|---|
| `plan` | Held. Handed to the executor as a note. |
| `approve` | Held. Handed to the executor as a note. |
| `execute` | The execute loop, as in the decision above. |
| `prompt`, `review` | Refused, and said so. Nothing is running, and nothing will. |

A held note is appended to the message that opens the execute phase, last and
stated as a requirement:

```text
Also required, added while this was being planned (1):
1. use a comma, not a full stop
```

The session is also marked finished when it ends, and the steer path checks that
before the phase. Without it, a **rejected** plan left the session in its `approve`
phase with no execution to come, and a steer after it was reported as held — the
exact accepted-and-never-delivered outcome the main decision exists to prevent.
Found by a test that asserted the refusal.

### Consequences of the amendment

- A message typed during planning is never lost, and never silently changes the
  plan: it is visible to the executor, and the monitor's log says `held for
  execution` so the user knows which phase it reached.
- **The planner does not see it.** A user who types something that contradicts the
  plan being written will not see the plan change; the plan approval checkpoint is
  where that gets caught, which is what the checkpoint is for. The alternative —
  both showing it to the planner and passing it on — duplicates the message in two
  conversations and lets the plan quietly diverge from the note.
- A note has no effect until execution starts, so its effect is separated in time
  from when it was typed. The log line is what connects them.
- Notes are per session and append-only, so a plan that is rejected and re-planned
  within one session would carry the earlier notes into the new execution. Rejection
  ends the session, so today this cannot happen; it becomes a question if a
  re-plan-in-place ever exists.
