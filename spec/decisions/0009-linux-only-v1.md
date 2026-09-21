# 0009. Linux only for v1

- Status: Accepted
- Date: 2026-09-20

## Context

The sandbox design in [0006](0006-sandbox-isolated-clone.md) is built on
`bubblewrap`, Linux namespaces, and — later — Landlock and seccomp. None of
these exist on macOS or Windows.

Sandboxing is not a nice-to-have here. [0005](0005-permission-model.md) puts the
entire security story on the sandbox, and explicitly rejects the command
blacklist as a boundary. Shipping without a sandbox would mean shipping the
allow-by-default permission model with nothing under it.

## Decision

v1 targets Linux only. The plugin detects a non-Linux platform and refuses to
enable the `bash` tool, rather than degrading silently.

## Consequences

### Positive

- One sandbox implementation instead of three, at the point where the sandbox is
  the load-bearing safety mechanism.
- No platform-conditional permission semantics to reason about.
- Honest failure: a macOS user gets a clear "unsupported" rather than a
  silent downgrade to unsandboxed execution.

### Negative / costs

- Excludes macOS, which is a large segment of Neovim users.
- macOS would need a `seatbelt` / `sandbox-exec` SBPL implementation; Windows
  would need AppContainer or a restricted token. Both are real work, not ports.
- A future macOS port is not merely "add a backend" — it is a second security
  model that must be reasoned about separately.

## Alternatives considered

**Cross-platform from the start.** Rejected: three sandbox implementations is
three times the security surface, and the project is single-maintainer.

**Linux-first with a degraded mode elsewhere (no `bash`, edits only).** This is
close to what is decided, and is the likely shape of early non-Linux support:
the edit-safety path (buffer-native edits, and a clone in vibe) is
platform-neutral; only process safety is not.

## Related

- [0005](0005-permission-model.md)
- [0006](0006-sandbox-isolated-clone.md)
