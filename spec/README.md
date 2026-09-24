# agent-smith.nvim — design records

Design and decision records for the rewrite.

No implementation exists yet. These documents are the contract the code is
written against: when code and a record disagree, one of them is a bug.

## Why these exist

The previous implementation (4815 LOC, deleted on `refactor`) was architecturally
a reimplementation of [99](https://github.com/ThePrimeagen/99): shell out to an
AI CLI, parse the text response, apply it. Same provider list, same ops, same
`SKILL.md` rules.

That design has a hard control ceiling, and it was deleted deliberately. These
records exist so the reasoning survives and the same shape does not get rebuilt
by accident.

## Directory layout

| Path | Contents |
|---|---|
| `spec/` | Design and decision records (this directory) |
| `spec/decisions/` | One record per decision, numbered |
| `doc/` | Neovim help files, tagged for `:help` |
| `lua/agent-smith/` | Implementation |

## Status legend

| Status | Meaning |
|---|---|
| **Accepted** | Decided. Code is written against it. |
| **Proposed** | Recommended but not confirmed. Do not build on it yet. |
| **Superseded** | Replaced by a later record; kept for history. |
| **Open** | Question with no answer yet. |

## Decisions

| # | Title | Status |
|---|---|---|
| [0001](decisions/0001-own-the-agent-loop.md) | Own the agent loop and the tools | Accepted |
| [0002](decisions/0002-typed-event-contract.md) | A typed event contract is the core abstraction | Accepted |
| [0003](decisions/0003-two-modes-no-chat.md) | Two modes, no chat | Accepted |
| [0004](decisions/0004-bounded-edit-with-escalation.md) | Bounded edits with explicit escalation | Accepted |
| [0005](decisions/0005-permission-model.md) | Permission model: allow-by-default, blacklist as guardrail | Accepted |
| [0006](decisions/0006-sandbox-isolated-clone.md) | Sandbox via isolated clone, not git worktree | Accepted |
| [0007](decisions/0007-vibe-workflow.md) | Vibe workflow: plan, approve, execute, review | Accepted |
| [0008](decisions/0008-transport-openai-compatible-first.md) | First transport: OpenAI-compatible chat completions | Accepted |
| [0009](decisions/0009-linux-only-v1.md) | Linux only for v1 | Accepted |
| [0010](decisions/0010-integrated-providers-are-presets.md) | Integrated providers are presets, not transports | Accepted |
| [0011](decisions/0011-credentials-encrypted-at-rest.md) | Credentials are encrypted at rest | Accepted |
| [0012](decisions/0012-models-are-fetched-not-catalogued.md) | Models are fetched, not catalogued | Accepted |
| [0013](decisions/0013-usage-input-tokens-excludes-cached.md) | `input_tokens` means uncached prompt tokens | Accepted |
| [0014](decisions/0014-stalled-runs-are-aborted.md) | A stalled run is aborted on inactivity | Accepted |
| [0015](decisions/0015-the-event-stream-is-visible.md) | The event stream is visible | Accepted |
| [0016](decisions/0016-steering-is-delivered-on-the-next-turn.md) | A steer is delivered on the next turn | Accepted |

## Other documents

| Document | Contents |
|---|---|
| [architecture.md](architecture.md) | Module map, data flow, the two-modes model |
| [events.md](events.md) | Event schema: fields, invariants, `done` reasons |
| [providers.md](providers.md) | Base URLs, credentials, endpoint routing |
| [sandboxing.md](sandboxing.md) | Sandboxing investigation, machine probe, evaluation of options |
| [open-questions.md](open-questions.md) | Unresolved decisions, tracked deliberately |

## Conventions

- One decision per record. If a record needs an "and", it is two records.
- Record the **alternatives considered**, including the rejected ones. The
  rejection reasoning is the part that gets lost otherwise.
- Record the **cost**. A decision presented without its downside is marketing.
- Amend by writing a new record that supersedes the old one. Do not rewrite
  history in place.
