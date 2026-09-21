# 0003. Two modes, no chat

- Status: Accepted
- Date: 2026-09-20

## Context

Most in-editor agents take the form of a persistent chat panel: a conversation
buffer, a message history, streaming replies. That shape was considered and
rejected for v1.

The intended use is not conversation. It is *"change this code"* and *"do this
piece of work"*. A chat transcript in the editor is a second place to manage
state, and it competes with the buffer for attention rather than serving it.

## Decision

Two modes. No chat panel.

### Inline

Bounded edit driven by a visual selection.

- The agent may **read** the whole repository for context.
- The agent may only **edit** within the selected range.
- If it needs to write outside that range, it must ask
  ([0004](0004-bounded-edit-with-escalation.md)).

### Vibe

Multi-file work with a plan and a sandbox.

- Plan first, for approval.
- Execute second, sandboxed.
- Review the diff, then apply
  ([0007](0007-vibe-workflow.md)).

## Consequences

### Positive

- Neovim stays the primary surface. The buffer is where work happens.
- No transcript state to keep in sync with the buffer.
- Scope is explicit in inline mode, which is what makes permission boundaries
  meaningful in the first place.
- Both modes are terminal: they end in an accepted or rejected change, not in an
  open-ended conversation.

### Negative / costs

- Iterative back-and-forth is awkward. "Not quite, try again" needs a re-request
  rather than a follow-up message.
- Exploratory questions ("how does auth work here?") have no natural home. They
  fit a chat surface better than either mode. Not addressed in v1.
- Users arriving from chat-shaped agents will find it unfamiliar.

## Alternatives considered

**Chat buffer with an agent loop.** Rejected for v1. It is the shape that makes
an agent loop most obviously necessary, but it is not the shape this project
wants, and building it first would push the bounded-edit model into a corner.

**Inline only.** Rejected: multi-file work has no home, and forcing it through a
selection bound produces a bad out-of-bounds prompt storm.

**Chat as a base with inline ops layered on.** Rejected for v1 as the largest of
the three. Revisit only if the iterative-request limitation above becomes a real
complaint.

## Related

- [0004](0004-bounded-edit-with-escalation.md)
- [0007](0007-vibe-workflow.md)
