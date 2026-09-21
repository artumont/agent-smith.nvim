# 0005. Permission model: allow-by-default, blacklist as guardrail

- Status: Accepted
- Date: 2026-09-20

## Context

Tool calls need a policy. The initial proposal was **per-call approval with
reads auto-approved**. The rejected alternative in that proposal was an
**allowlist by tool and path**, with only `bash` and out-of-project paths
prompting.

The user chose a third thing: **everything allowed unless blacklisted** —
blacklisting risky commands such as `rm`.

## Decision

Policy is allow-by-default with a blacklist layered on top.

**But the blacklist is a guardrail against accidents, not a security boundary.**
This is not a caveat; it is the design. The actual boundary is the sandbox
([0006](0006-sandbox-isolated-clone.md)).

Why the blacklist cannot be a boundary — each of these gets past a `rm` regex:

```
sh -c 'rm -rf ...'        busybox rm         /bin/rm        \rm
r''m                      $IFS              find . -delete
git clean -fdx            truncate          mv x /dev/null
> file                    python3 -c 'import shutil; ...'
```

The threat model is not only a clumsy model. Repository content is
prompt-injectable: a malicious `README`, lockfile, or vendored script can
instruct the agent to exfiltrate or destroy. Against that, a string blacklist
provides nothing.

So the layering is:

| Layer | Purpose | Enforces what |
|---|---|---|
| Blacklist | stop obvious accidents | convenience |
| Scope check ([0004](0004-bounded-edit-with-escalation.md)) | stop unintended edits | edit blast radius |
| Buffer-native edits | nothing hits disk unaccepted | edit safety |
| OS sandbox ([0006](0006-sandbox-isolated-clone.md)) | contain `bash` | process safety |

## Consequences

### Positive

- Few prompts in normal use, which is the point.
- The honest layer does the work, so the number of prompts is not load-bearing
  for safety.
- Reads are unrestricted, which matches read tools being outside the bound in
  [0004](0004-bounded-edit-with-escalation.md).

### Negative / costs

- **The blacklist will give a false sense of safety.** This record exists mostly
  to prevent that. Anyone reading the config and concluding "`rm` is blocked, so
  I am safe" has the wrong model.
- Sandbox quality now carries the whole security story. `bash` outside a sandbox
  is effectively unrestricted.
- No per-path allowlist means a mistake inside the project is not caught by
  policy; it is caught by undo.

## Alternatives considered

**Per-call approval, reads auto.** Rejected by the user as too noisy. Worth
noting this is the model that gives the strongest guarantee at the cost of
interruption on every write.

**Allowlist by tool and path.** Rejected as the middle ground that pays the
prompt cost without the guarantee.

## Related

- [0004](0004-bounded-edit-with-escalation.md)
- [0006](0006-sandbox-isolated-clone.md)
- [0009](0009-linux-only-v1.md)
