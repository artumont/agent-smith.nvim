# 0001. Own the agent loop and the tools

- Status: Accepted
- Date: 2026-09-20

## Context

The project goal is a Neovim agent built for **full control**.

The previous implementation wrapped AI CLIs. It built a command
(`opencode run --agent build -m <model> <prompt>`), ran it through
`vim.system()`, and parsed free text out of stdout. The provider layer exposed
four methods, and the entire conversation with the model was one string in, one
string out.

That design has a hard ceiling that no amount of tuning fixes:

- **No tool-call interception.** A `--print` invocation returns one blob after
  the model has already acted. You cannot see, gate, or modify a tool call.
- **No per-turn cost or token visibility.** You cannot budget or detect a
  runaway loop.
- **No compaction control.** The CLI chooses its own context window policy.
- **No prompt-cache control.** The largest cost lever is internal to the CLI.
- **Disk is not the buffer.** The CLI edits the filesystem. Neovim's truth is
  the buffer. Unsaved edits and agent edits fight permanently.
- **Undo is broken.** Applying an agent's file write via reload is not a single
  undoable action.
- **LSP feedback is invisible.** The agent cannot see diagnostics, so it cannot
  self-correct.

## Decision

Own the agent loop. Own the tools. The conversation state machine, tool
dispatch, permission gating, context assembly, and UI are all implemented here.

Model access becomes a **transport** — an adapter that carries tokens between a
model vendor and the loop. A transport is not an agent. It has no opinions about
tools, permissions, or turns.

## Consequences

### Positive

- Tool calls are visible, gatable, and modifiable before they take effect.
- Cost and token usage are measurable per turn.
- Compaction and prompt-cache policy are ours.
- Edits can be applied buffer-natively, so a whole turn reverts with one `<u>`.
- LSP diagnostics can be fed back as `tool_result`, closing the loop.
- The behaviour is not at the mercy of an external CLI's release cycle.

### Negative / costs

- We own streaming, tool schemas, retry, context management, and cancellation.
- Provider breadth is now our work, not the CLI's.
- Solo-maintainer parity with mature agents is a long project. Scope discipline
  matters more than feature count.

## Alternatives considered

**Keep wrapping CLIs, add structured output.** Rejected as a *final* design —
it recovers tool-call visibility (`claude -p --output-format stream-json`,
`pi --mode json`) but not cost control, cache control, compaction, or
buffer-native editing. It also cannot fix the authorization problem below.

**Wrap CLIs as the only design.** Rejected. The wrapper cannot guarantee its own
approval gate. `providers/claude.lua` invoked
`claude --dangerously-skip-permissions`, meaning the CLI below the gate had
already written to disk before the plugin's approval window appeared. An
approval flow layered above a process that has already acted is not an approval
flow.

## Related

- [0002](0002-typed-event-contract.md) — what the loop consumes
- [0008](0008-transport-openai-compatible-first.md) — what carries tokens
