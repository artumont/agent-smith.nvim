# Open questions

Deliberately unresolved. Tracked here so they are visible rather than silently
decided by whoever writes the code first.

Each entry names the decision, why it is open, and what it blocks.

## Q1. Vendor for the first transport

**Status:** Proposed, not confirmed — [0008](decisions/0008-transport-openai-compatible-first.md)

**Open because:** depends on what the user has access to (API credits,
subscription, or a local model).

**Proposal:** OpenAI-compatible chat completions, because it covers the most
vendors and lets the whole loop be developed against a local model with no key
and no cost.

**Blocks:** task 3 (the first transport).

## Q2. Network policy inside the vibe sandbox

**Status:** Open

**Open because:** the sandbox ships with no network, which breaks every
dependency installer. The obvious fixes all have costs.

Candidates:

| Approach | Cost |
|---|---|
| Stay offline | vibe cannot build most projects from a fresh clone |
| Read-only mounts of `~/.npm`, `~/.cargo`, `~/.cache/pip` | partially works, cache shape varies per ecosystem |
| One-time install outside the sandbox before execution | user must know in advance what to install |
| Network-with-proxy allowlist | needs a proxy, and reintroduces exfiltration risk |

**Blocks:** nothing immediately; needed before vibe is usable on real projects.

## Q3. Batching escalation prompts

**Status:** Open — relates to [0004](decisions/0004-bounded-edit-with-escalation.md)

**Open because:** a change that legitimately spans five locations will produce
five separate prompts, which is the most likely reason a user turns the feature
off.

**Candidates:** present all pending escalations as one review, or allow a
scoped standing grant for the duration of a single request.

## Q4. Scope changes discovered during vibe execution

**Status:** Open — relates to [0007](decisions/0007-vibe-workflow.md)

**Open because:** [0007](decisions/0007-vibe-workflow.md) says writes outside the
approved plan are recorded and ignored. That is correct for summary, but if the
agent discovers mid-execution that the plan was wrong, the ignored work is
throwaway and the user pays for it twice.

**Candidates:** pause execution and re-plan for approval, or let the user extend
the scope once the deviation is visible.

## Q5. Carrying the working tree into the vibe clone

**Status:** Open — relates to [0006](decisions/0006-sandbox-isolated-clone.md)

**Open because:** the clone sees committed state. A user with unsaved buffers or
uncommitted work gets a vibe run against different code than what is on their
screen, which produces a diff that does not apply cleanly.

**Candidates:** carry dirty work in via `git stash`/`format-patch`, require a
clean tree before vibe, or snapshot buffers to disk first.

## Q6. The `grep`/`glob` implementation

**Status:** Open

**Open because:** `rg` is the obvious choice but is an external dependency, and
its output format must be parsed consistently for quickfix and for `tool_result`.

**Candidates:** require `rg`; use `rg` when present and fall back to
`vim.fn.glob` + `vim.fn.grep`; use built-in `vim.fs` + `vim.grep`.

## Q7. Conversation persistence

**Status:** Open

**Open because:** [0003](decisions/0003-two-modes-no-chat.md) removes the chat
panel, but request history and the ability to re-run a previous request are
separate concerns from a chat surface.

**Blocks:** nothing; needs an answer before logging is designed.

## Q8. Prompt-cache strategy

**Status:** Open

**Open because:** cache control is a stated motivation for owning the loop
([0001](decisions/0001-own-the-agent-loop.md)), but no strategy exists yet. It
depends on the transport ([0008](decisions/0008-transport-openai-compatible-first.md))
and on how context is assembled (`agent/messages.lua`).

**Blocks:** task 2 (context assembly) design.

---

## Q9. Are reads bounded to the repository?

**Status:** Open — relates to [0004](decisions/0004-bounded-edit-with-escalation.md)

**Open because:** [0004](decisions/0004-bounded-edit-with-escalation.md) says the
read tools are "unrestricted across the repository", which does not say whether
they are bound to the repository. The current implementation
(`agent/scope.lua`) takes the permissive reading: every read is allowed, and a
read of `/etc/passwd` or `~/.ssh/id_rsa` succeeds.

That interacts badly with the threat model in
[0005](decisions/0005-permission-model.md), which treats repository content as
attacker controlled. A read tool that can reach outside the project is an
exfiltration path: injected instructions in a `README` can ask the agent to read
`~/.ssh/id_rsa` and put its contents in a file that is then written back, or
simply into the conversation.

The write side is bounded twice over (scope, and buffer-native edits). The read
side is currently bounded by nothing.

**Candidates:**

| Approach | Cost |
|---|---|
| Leave unbounded | simplest, and probably wrong |
| Bound reads to the project root | breaks reading a global config or a dependency outside the tree |
| Bound by default, with an escalation for outside paths | needs a second escalation path, and reads are the case where a prompt is most annoying |
| Bound by default, allowlist for well-known paths | a new config surface |

**Blocks:** nothing mechanically. Should be settled before `bash` and the read
tools are considered done, because it changes what the tools may return.

## Q10. Is the agent's identity configurable?

**Status:** Open — no decision record yet.

**Open because:** `agent/identity.lua` writes the name, the author and the "not
Claude Code" line into every system prompt, and there is no way to change any of
it. A fork with a different name, or a user who wants the agent to introduce
itself differently, has to edit the plugin.

Against configuring it: the paragraph exists to stop a specific failure — a model
asserting a tool it does not have because it thinks it is another product — and a
setting invites the user to break that without knowing what it was for. The
tool-list sentence is load-bearing in a way a name is not.

**Candidates:**

| Approach | Cost |
|---|---|
| Leave it hardcoded | simplest, and a fork edits the file |
| `config.identity` replacing the whole paragraph | one string, and the load-bearing part is the user's to lose |
| `config.name` / `config.author`, paragraph fixed | keeps the guarantees, covers the likely want |
| No name at all: describe the situation, not the product | shortest prompt, and gives up on "do not claim to be Claude Code" |

**Blocks:** nothing. Worth settling before anyone forks it for the name alone.
