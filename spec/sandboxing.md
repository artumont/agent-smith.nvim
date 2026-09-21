# Sandboxing

Investigation backing [0006](decisions/0006-sandbox-isolated-clone.md) and
[0005](decisions/0005-permission-model.md).

## Two problems, not one

The word "sandbox" was doing two jobs. They have different solutions and should
not be conflated.

| | Threat | Failure looks like | Mechanism |
|---|---|---|---|
| **Edit safety** | the agent corrupts the working tree | unrelated files changed, work lost | throwaway clone, or buffer-native edits |
| **Process safety** | agent-authored `bash` does damage | `rm -rf`, exfiltration, host persistence | OS-level sandbox |

Edit safety we largely get for free, because we own the loop
([0001](decisions/0001-own-the-agent-loop.md)): edits go through
`nvim_buf_set_text`, so nothing reaches disk until accepted. Vibe redirects the
edit tool at a clone root instead.

Process safety needs a real sandbox. That is what the rest of this document
evaluates.

## Threat model

The model is **semi-trusted**. It is a frontier model following our prompt, but
the prompt includes repository content, and repository content is attacker
controlled in the general case — a malicious `README`, lockfile, vendored
script, or dependency can carry instructions. So the agent is a genuine threat
source, not merely a clumsy actor.

That is why [0005](decisions/0005-permission-model.md) refuses to treat a
command blacklist as a boundary.

## Machine probe

Recorded 2026-09-20. These are the facts the decision was made against.

```text
kernel            6.12.107+deb13-amd64
LSM stack         lockdown,capability,landlock,yama,apparmor,tomoyo,bpf,ipe,ima,evm
                  → landlock present; LSM stacking available (6.12+)
user namespaces   unprivileged_userns_clone = 1
                  user.max_user_namespaces = 1 (unlimited)
                    → bwrap works unprivileged

bwrap             /usr/bin/bwrap
systemd-run       /usr/bin/systemd-run
unshare           /usr/bin/unshare
nsenter           /usr/bin/nsenter
docker            /usr/bin/docker
firejail          MISSING
podman            MISSING
fuse-overlayfs    MISSING
proot             MISSING

/  and $HOME      ext4        → no btrfs/zfs snapshots, no cheap overlay
/tmp              tmpfs 16G   → throwaway dirs are cheap and RAM-backed
systemd user      running
```

Consequences that follow directly:

- ext4 rules out snapshot-based rollback. Overlayfs is available in-kernel but
  without a snapshot primitive the benefit is smaller than the complexity.
- `bwrap` + user namespaces + Landlock are all available and require no root.
- `docker` requires a root daemon; `podman` is absent.

## Options evaluated

| Option | Isolation | Unprivileged | Cost | Verdict |
|---|---|---|---|---|
| `git worktree` | **none** | yes | cheapest | rejected — see below |
| Directory copy | files only | yes | slow, no history | rejected |
| `git clone --local` | files + history | yes | cheap | **chosen** for edit safety |
| `bwrap` | namespaces, mounts | yes | low | **chosen** for process safety |
| Landlock | FS + network ACL | yes | low | deferred, second layer |
| seccomp-bpf | syscalls | yes | low | deferred |
| `systemd-run --user` | cgroup + sandbox props | yes | low | fallback if no `bwrap` |
| `firejail` | namespaces | setuid | low | unavailable here |
| Docker | full container | no (daemon) | high (~400ms cold) | rejected |
| Podman | rootless container | yes | medium | unavailable here |
| gVisor / Firecracker | syscall / microVM | no | very high | rejected — wrong scale |

## Why `git worktree` was rejected

This was the specific assumption the investigation overturned, and it is worth
recording because worktrees are the common recommendation for agent isolation.

Worktrees are **not** an isolation boundary. Linked worktrees share the
repository: refs, config, stash, and hooks. An agent with write access to a
worktree can install a `post-checkout` or `pre-commit` hook, which then executes
on the host the next time the user runs a git command — outside any sandbox, in
the user's real environment.

Worktrees solve concurrent agents colliding with each other. They do not solve
containment. A `clone --local` gets a genuinely separate `.git` for
approximately the same cost, so there is no reason to accept the shared-state
hole.

## The chosen stack

### Edit safety: isolated clone

```sh
git clone --local --no-hardlinks <repo> /tmp/smith/<id>
```

`--local` avoids network and full history transfer. `--no-hardlinks` is
deliberate: hardlinked clones share the object store with the parent, and the
aliasing is not worth the saving here.

The agent's edit tool targets the clone root. The real repository is not
reachable. Apply is `git diff` in the clone, reviewed, then applied.

### Process safety: bubblewrap

```sh
bwrap \
  --ro-bind /usr /usr \
  --ro-bind /etc /etc \
  --symlink usr/bin /bin \
  --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 \
  --symlink usr/sbin /sbin \
  --ro-bind <project> <project> \
  --bind <clone> <clone> \
  --proc /proc --dev /dev --tmpfs /tmp \
  --unshare-pid --unshare-uts --unshare-ipc --unshare-net \
  --die-with-parent \
  -- <command>
```

Notes on each flag:

- `--ro-bind` for system paths: a toolchain needs to run, but nothing outside
  the clone needs to change.
- `--symlink` to recreate the merged-/usr links. On Debian and friends `/bin`,
  `/sbin`, `/lib` and `/lib64` are symlinks into `/usr`, and binding `/usr`
  alone does **not** create them. Without these lines `/bin/sh` does not exist
  inside the sandbox and every command fails immediately. Binding the resolved
  target directory onto the symlink path was tried and does not work; the
  symlink has to be recreated.
- `--bind` on the clone: this is the only writable path.
- `--tmpfs /tmp`: build artifacts land in RAM and vanish.
- `--unshare-*`: the process cannot see or signal host processes.
- **`--unshare-net`**: this is what blocks the network, and it is required.
  Omitting `--share-net` does **not** unshare the network — bwrap shares it by
  default. Measured both ways: `curl` reached the network without this flag and
  was blocked with it, including against a raw IP, so the block is real
  isolation and not a DNS artefact. This was wrong in an earlier draft of this
document.
- `--die-with-parent`: no orphaned children when Neovim exits or the request is
  cancelled.
- `$HOME` is deliberately not bound. There is nothing in the user's home
  directory this needs; measured, `$HOME` is still set but the directory does
  not exist inside the sandbox.

### Deferred: Landlock + seccomp

Landlock adds unprivileged filesystem and network ACLs that stack with the LSM
stack already present, and seccomp filters syscalls. Codex CLI on Linux layers
`bwrap → Landlock → seccomp`, and that order is sensible. It is deferred until
the feature shapes settle, because a second enforcement layer constrains where
the sandbox boundary can sit.

## Known limitations

These are real and should be surfaced to the user, not hidden.

1. **No network breaks dependency installation.** `npm install`, `cargo fetch`,
   `go mod download`, `pip install` all fail inside the sandbox. A command that
   fails for this reason must be reported as such rather than as a generic
   failure. Mitigations under consideration in
   [open-questions.md](open-questions.md).
2. **The clone sees committed state, not the working tree.** Dirty files and
   unsaved buffers are not present unless explicitly carried over.
3. **`bwrap` is a hard dependency** for the `bash` tool.
4. **No seccomp yet**, so kernel attack surface is not reduced.
5. **Linux only** for v1 ([0009](decisions/0009-linux-only-v1.md)).
