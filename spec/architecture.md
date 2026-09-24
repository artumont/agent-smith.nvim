# Architecture

Companion to the decision records in [`decisions/`](decisions/). This document
describes the shape the code takes; the records explain why.

See [0001](decisions/0001-own-the-agent-loop.md) for the underlying decision to
own the loop and the tools.

## Module map

```text
lua/agent-smith/
  init.lua              public API, setup, keymaps
  config.lua            option defaults and validation
  health.lua            :checkhealth agent-smith
  auth.lua              encrypted credential storage
  json.lua              deterministic encoding for wire bodies
  session.lua           stable session id for prompt-cache routing
  usage.lua             token accounting and cache hit rate
  outline.lua           symbol outlines, for tiered reads

  providers/
    base.lua            the provider contract and all shared behaviour
    init.lua            registry and resolving facade
    zen.lua  go.lua     OpenCode gateways
    commandcode.lua     Command Code

  agent/
    identity.lua        who the model is told it is, in front of every prompt
    events.lua          typed event schema — the core contract
    loop.lua            turn loop, dispatch, stop conditions, cancel
    messages.lua        conversation state (compaction not designed yet)
    scope.lua           the scope/permission object for a session

  transport/
    base.lua            streaming harness shared by every adapter
    openai_compat.lua   chat completions
    responses.lua       the OpenAI Responses API
    anthropic.lua       (later) Anthropic Messages
    sse.lua             SSE line framing

  tools/
    init.lua            assembles the tool set, bound to a project root
    registry.lua        schema, dispatch, policy attachment
    paths.lua           root-relative path resolution and display
    read.lua            contents or an outline; prefers the buffer over disk
    grep.lua  glob.lua  repo-wide search, read-only
    edit.lua            scope-enforced; buffer-staged, or to disk in vibe
    plan.lua            the plan phase's structured output
    bash.lua            bwrap-wrapped, blacklist guardrail
    diagnostics.lua     LSP output as tool_result

  sandbox/
    clone.lua           isolated clone lifecycle
    bwrap.lua           sandbox argv construction

  modes/
    inline.lua          selection-bound edit flow
    vibe.lua            plan, approve, execute, review

  ui/
    float.lua           the centred float prompt and monitor are built from
    prompt.lua          instruction entry, in a floating buffer
    approval.lua        approving an escalated tool call
    progress.lua        run status as virtual lines, for inline
    panel.lua           run status as a floating corner panel, for vibe
    monitor.lua         the event stream, in a floating scratch buffer, and the
                        steer input docked along its bottom
    diff.lua            reviewing a patch before it is applied
```

## Data flow

```text
ui/modes ──prompt──> agent/loop ──request──> transport ──SSE──> model
                         ^                       │
                         │                       v
                         │                  agent/events
                         │                       │
                    tools/registry <────── tool_use
                         │
                    scope policy  (deny / allow / needs_permission)
                         │
                    tool_result ─────────> agent/loop ──> transport
```

The loop's only inputs and outputs are typed events
([0002](decisions/0002-typed-event-contract.md)). It has no knowledge of vendors
and no knowledge of Neovim buffers.

Each mode's system prompt is its own body behind the shared identity paragraph in
`agent/identity.lua`, which is what stops a model asserting a tool this plugin does
not have because it believes it is a different product. There are three prompts —
one per phase — so the identity is composed in one place rather than copied into
each.

Both modes tap the stream twice: once for the status display, and once for
[`ui/monitor.lua`](decisions/0015-the-event-stream-is-visible.md), which records
every event in a scratch buffer so a run can be read back after the fact. The
status says what is happening; the monitor is the evidence.

A turn that produces no event at all is a stall, and the loop aborts it rather
than waiting forever ([0014](decisions/0014-stalled-runs-are-aborted.md)). The
budget is inactivity, not duration, so a slow stream is never mistaken for a
hung one, and it is disarmed while a permission question is pending.

### Transport interface

A transport is one function:

```lua
-- { run = function(request, on_event) -> handle }
request   = { system: string, messages: table[], tools: table[] }
on_event  = function(event) end   -- typed events; one terminal (done | error)
handle    = { cancel = function() end }   -- optional
```

Events may arrive after `run` returns — the normal case for a real transport —
or entirely synchronously, which is what the test fake does. Both are handled: a
turn that completes during `run` is processed once `run` returns, rather than
re-entering the transport from inside its own call.

Nothing else is required of a transport. It has no opinion about tools,
permissions or turns, which is what keeps vendor quirks inside the adapter.

A tool may answer `needs_permission` instead of running. The loop asks the
caller, and on approval grants that exact target once in the scope and
re-dispatches the same call. With nobody to ask, the request is refused:
silence is not consent.

### Steering

The handle's other verb is `steer(text)`: a message for the model while the run is
in flight, which the monitor's `s` input sends. It is **queued**, not appended on
arrival, and flushed at the start of the next turn — after any tool results, which
is the only place in the conversation a user message is valid mid-run. A steer
that arrives as the model stops gives the run one more turn rather than being
dropped, `max_turns` still bounds it, and what never left is counted in the
result. See [0016](decisions/0016-steering-is-delivered-on-the-next-turn.md).

## The two modes

Both modes are terminal: they end in an accepted or rejected change.

| | Inline | Vibe |
|---|---|---|
| Trigger | visual selection | explicit command |
| Read scope | whole repo | whole repo |
| Write scope | selection range, escalation outside | approved plan scope |
| Side effects | buffer only until accepted | isolated clone |
| `bash` | sandboxed, read-only project | sandboxed, rw clone, no network |
| Checkpoints | escalation prompts | plan approval, diff approval |
| Apply | buffer edit, single undo | reviewed diff into real repo |

Inline is [0003](decisions/0003-two-modes-no-chat.md) +
[0004](decisions/0004-bounded-edit-with-escalation.md).
Vibe is [0007](decisions/0007-vibe-workflow.md).

## Layering of safety

Four independent layers, deliberately redundant
([0005](decisions/0005-permission-model.md)):

| Layer | Enforces | Trust level |
|---|---|---|
| Command blacklist | no obvious accidents | convenience only |
| Scope check | edit blast radius | real, for edits |
| Buffer-native edits | nothing on disk unaccepted | real, for edits |
| OS sandbox | containment of `bash` | real, for processes |

The first layer is the one that must not be mistaken for a boundary.

## Testing strategy

Run the suite with `make test`, or directly with `nvim --headless -l test/run.lua`.
An optional Lua pattern filters spec files by path. The runner exits non-zero on
failure, and fails loudly when no spec files are found, so a silent empty run
cannot be mistaken for a passing one.

`make run` starts Neovim with the plugin loaded from a clean configuration
(`dev/init.lua`), which is the fastest way to exercise it by hand. `make` with
no target lists every task.

- `agent/events.lua` is pure data, so it is unit tested directly.
- Asynchronous tools are tested with `t.settle`, which pumps the event loop so
  a `vim.system` callback gets a chance to fire. Without it an async handler
  looks identical to a handler that never finishes.
- Transports are tested against **recorded fixture streams** in
  `test/fixtures/*.jsonl`, not against vendor documentation. Live calls are a
  separate, optional smoke test.
- The loop is tested with a fake transport emitting scripted events; no network,
  no model, no cost.
- Tools are tested against headless buffers, asserting content **and** that one
  `<u>` reverts a whole turn.
- The sandbox is tested by asserting that a write outside the clone fails and
  that a network call fails.

## Dependencies

| Dependency | Why | Required |
|---|---|---|
| Neovim >= 0.10 | `vim.json`, `vim.system`, `vim.uv` | yes |
| `curl` | SSE transport (`-N --no-buffer`) | yes |
| `git` | isolated clone, diff, apply | yes for vibe |
| `bwrap` | process sandbox | yes for `bash` |
| `rg` | `grep`/`glob` | preferred, with a fallback |

Linux only for v1: [0009](decisions/0009-linux-only-v1.md).
Sandbox rationale and machine probe: [sandboxing.md](sandboxing.md).
