# 0007. Vibe workflow: plan, approve, execute, review

- Status: Accepted
- Date: 2026-09-20

## Context

Vibe mode exists for work that spans files: refactors, migrations, features.
[0006](0006-sandbox-isolated-clone.md) provides the containment. What remains is
the shape of the interaction.

The previous implementation ran a two-phase workflow in a copied temporary
project: plan, approve, recreate the sandbox, execute, review. That shape was
broadly right; what was wrong was the copy mechanism, the text protocol used to
express changes, and the fact that nothing below the approval gate was actually
constrained.

## Decision

Four phases. Each is a stopping point.

1. **Plan.** Read-only. The agent has `read`, `grep`, `glob` and returns a
   declared file scope plus ordered steps. No writes, no `bash`.
2. **Approve.** The user reviews the plan. Scope and steps are both visible.
   Rejection ends the request.
3. **Execute.** A fresh clone is created from current state. The agent runs with
   write and sandboxed `bash` inside it. Writes outside the approved plan scope
   are **recorded and ignored**, not applied, and reported to the user.
4. **Review and apply.** `git diff` in the clone is presented. On approval the
   diff is applied to the real repository. Rejection discards the clone.

Phases 3 and 4 are the only ones with side effects, and both are inside the
clone.

## Consequences

### Positive

- Two independent human checkpoints: before execution and before the real
  repository changes.
- The plan is a checkable artifact. Scope creep is visible as a plan deviation
  rather than as an unexplained diff.
- Because execution is in a clone, phase 3 can be generous with `bash` without
  risk to the working tree.
- The clone is disposable, so a bad run costs a `rm -rf` on `/tmp`.

### Negative / costs

- Two approval gates is friction for small changes. Vibe is the wrong tool for
  a one-line edit — inline exists for that.
- The plan can be wrong in a way execution exposes only later, at which point
  the approved scope is blocking work the agent now knows it needs. Handling
  that is open in [open-questions.md](../open-questions.md).
- Execution in a clone sees committed state, not the user's dirty working tree
  or unsaved buffers. Carrying those over is open.
- Cost: a plan request plus an execution request, so at minimum two model
  round trips.

## Alternatives considered

**Single-phase: execute directly in a sandbox, review at the end.** Rejected:
loses the pre-execution checkpoint, which is where a bad plan is cheapest to
catch.

**Plan and execute in the same clone without recreating it.** Rejected. The
earlier design recreated the sandbox from originals after plan approval, and
that is right: the execution sandbox should not be carrying state from a phase
whose only job was to think.

**No plan phase.** Rejected: the plan is what makes scope enforcement possible
in phase 3.

## Related

- [0003](0003-two-modes-no-chat.md)
- [0006](0006-sandbox-isolated-clone.md)
