# 0004. Bounded edits with explicit escalation

- Status: Accepted
- Date: 2026-09-20

## Context

In inline mode the agent gets one instruction about a selection. The useful
question is what it is allowed to touch.

Two failure modes bracket the design space:

- **Too permissive**: the agent decides an edit needs to land somewhere else —
  a caller, an interface, an import — and does it silently. The user reviews one
  hunk and discovers five changed files.
- **Too restrictive**: the agent cannot write the change it was asked for,
  because the change genuinely requires touching a second location, and there is
  no way to say so.

## Decision

The selection range is a hard scope. The agent's edit tool enforces it.

- Read tools (`read`, `grep`, `glob`) are unrestricted across the repository.
  Context is not the thing being bounded.
- `edit` succeeds only within the selection range of the origin buffer.
- An out-of-bounds edit attempt does **not** fail silently and does **not**
  apply. It returns a `needs_permission` result carrying the reason and the
  exact target location.
- The UI surfaces that request, showing what will change and why. Approval
  applies that edit — still buffer-native, still inside the turn's single undo
  block.

Escalation is per-request and explicit. There is no standing "allow this file"
grant in v1.

## Consequences

### Positive

- The default is bounded, so the common case cannot surprise the user.
- The exception is legitimate, so the agent is not crippled when a change really
  does span a boundary.
- The reason is model-authored but user-reviewed. The user decides with the
  agent's justification in front of them rather than in a log.
- Because the escaped edit still lands in the same undo block, one `<u>` reverts
  the whole turn including the escalation.

### Negative / costs

- The prompt cost of a round trip per escalation. A change spanning five
  locations produces five prompts unless batched, which is a real annoyance and
  is left open in [open-questions.md](../open-questions.md).
- The model must be pushed to request rather than comply. Weaker models will
  either refuse to escalate or will try to write outside bounds and get a
  rejection they do not understand.
- A `needs_permission` result requires the loop to continue rather than stop,
  which is a real constraint on loop design
  ([0002](0002-typed-event-contract.md)).

## Alternatives considered

**Allow edits anywhere in the file.** Rejected: that is closer to "no bound" in
practice, since the file is usually the unit that matters.

**Allow edits anywhere in the repository, review at the end.** Rejected: this is
what vibe mode is, and it needs the sandbox for exactly this reason
([0006](0006-sandbox-isolated-clone.md)).

**Deny out-of-bounds edits outright.** Rejected: makes the agent unable to
complete work that legitimately spans boundaries, with no recourse.

## Related

- [0003](0003-two-modes-no-chat.md)
- [0005](0005-permission-model.md)
- [0006](0006-sandbox-isolated-clone.md)
