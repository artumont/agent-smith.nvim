# 0006. Sandbox via isolated clone, not git worktree

- Status: Accepted
- Date: 2026-09-20

## Context

Vibe mode executes agent work that must not corrupt the working tree, and inline
mode runs agent-authored `bash`. Both need containment.

See [sandboxing.md](../sandboxing.md) for the full evaluation and the machine
probe. The relevant conclusions:

- The machine is `ext4`, so snapshot-based approaches (btrfs, ZFS, overlay with
  real snapshots) are unavailable.
- `bubblewrap`, `systemd-run`, `unshare` are present; user namespaces are
  enabled; Landlock is active in the LSM stack. `podman` is absent, `docker`
  requires a root daemon.
- **`git worktree` is not an isolation boundary.** Linked worktrees share the
  repository: refs, config, stash, and hooks. An agent with write access can
  install a `post-checkout` or `pre-commit` hook that later executes on the host,
  outside any sandbox. This is documented behaviour, not a corner case.

## Decision

Two mechanisms, matching the two distinct problems.

### Edit safety — isolated clone

`git clone --local --no-hardlinks <repo> <tmpdir>/smith/<id>`, under `/tmp`
(tmpfs). The agent's edits target the clone root. The real repository is not
reachable by the edit tool. Apply is a reviewed diff, not an in-place write.

### Process safety — bubblewrap

Agent-authored `bash` runs under `bwrap`:

```text
--ro-bind /usr /usr     --ro-bind /etc /etc
--symlink usr/bin /bin  --symlink usr/lib /lib
--symlink usr/lib64 /lib64  --symlink usr/sbin /sbin
--ro-bind <project> <project>      (read-only in inline mode)
--bind <clone> <clone>             (rw, vibe only)
--proc /proc  --dev /dev  --tmpfs /tmp
--unshare-pid  --unshare-uts  --unshare-ipc  --unshare-net
--die-with-parent
-- <command>
```

Two of these lines are not obvious and were verified against a real `bwrap`:

- **The `--symlink` lines are load-bearing.** On a merged-/usr system `/bin`,
  `/sbin`, `/lib` and `/lib64` are symlinks into `/usr`, and binding `/usr` does
  **not** create them. Without recreating the links, every command fails with
  `execvp /bin/sh: No such file or directory`.
- **`--unshare-net`, not the absence of `--share-net`.** Omitting `--share-net`
  does not unshare the network; bwrap shares it by default. Only `--unshare-net`
  blocks it.

No network in v1.

Landlock and seccomp are deferred as a second layer. Codex CLI on Linux is
bwrap → Landlock → seccomp, and that ordering is the sane one; the shapes should
settle first.

## Consequences

### Positive

- The real repository is not writable by the agent in either path.
- The failure mode of a bad run is a deleted `/tmp` directory.
- `git diff` in the clone is the review artifact, which is exactly what the
  apply step wants.
- `clone --local` is cheap: no network, no full copy of history over the wire.

### Negative / costs

- **No network breaks dependency installation.** `npm install`, `cargo fetch`,
  `go mod download` fail inside the sandbox. This is a real limitation and must
  be reported to the user rather than silently failing. Mitigations (read-only
  package cache mounts, one-time install outside the sandbox) are open in
  [open-questions.md](../open-questions.md).
- `--no-hardlinks` costs disk and time versus a hardlinked clone, deliberately,
  to avoid object-store aliasing with the parent.
- A clone is a copy of the repo, so the sandbox does not see uncommitted or
  unsaved work unless it is explicitly carried over.
- `bwrap` availability is a hard dependency.

## Alternatives considered

**`git worktree`.** Rejected. Shared `.git` is a documented escape path, and
this was the specific assumption the investigation overturned.

**Plain directory copy.** Rejected: loses history, so no diff review and no
targeted apply; slower; symlink and permission edge cases.

**Docker.** Rejected: root daemon, image management, ~400ms cold start, and
nothing gained over `bwrap` for this threat model.

**`systemd-run --user` with sandboxing properties.** Kept as the fallback where
`bwrap` is unavailable, but rejected as primary. It depends on a user systemd
session and its policy surface is less direct than an explicit argv.

**Run the vibe in-place and rely on git to undo.** Rejected: undo-first means the
damage happened, and it does not contain `bash` at all.

## Related

- [0005](0005-permission-model.md)
- [0007](0007-vibe-workflow.md)
- [sandboxing.md](../sandboxing.md)
