# 0011. Credentials are encrypted at rest, against accidental disclosure

- Status: Accepted
- Date: 2026-09-21

## Context

API keys have to be stored somewhere, and the obvious place — an `auth.json`
in the config directory — is the place most likely to be committed. Config
directories get symlinked into dotfiles repositories, and it is the config tree,
not the data tree, that receives that treatment. On this machine pi does
exactly that: `~/.pi/agent/settings.json` and `~/.pi/agent/skills` are symlinks
into `~/Documents/dotfiles/`. A plain `auth.json` beside them is one
`git add -A` from being published.

pi's own arrangement is a plain `auth.json` at mode `0600` in a `0700`
directory. That is a reasonable default against other *users* on the machine and
no protection at all against the repository case.

## Decision

Credentials live in an `auth.json` shaped like pi's — a provider-keyed object —
but encrypted at rest.

- **Cipher:** AES-256-CBC with PBKDF2 and a random salt per write, through
  `openssl`. Measured: the stored file contains neither the plaintext nor the
  key material, and two writes of the same value produce different ciphertext.
- **Key:** 32 random bytes in a separate file, mode `0600`.
- **Location:** the encrypted file in the *config* directory, the key in the
  *data* directory. **The split is the decision.** Putting them side by side
  would mean the encryption travels with the thing it is protecting, which is
  the entire failure mode being addressed.
- **Which config directory:** agent-smith's own, `~/.config/agent-smith/`, and not
  Neovim's. `stdpath("config")` is `~/.config/nvim`, which for many users *is* the
  tree under version control — so the file that is safe to commit only because it
  is encrypted would have been sitting in the one place most likely to be
  committed. Found the hard way: `auth_file` briefly pointed there, and the
  credential had to be moved out of a dotfiles-synced directory by hand. The
  split above still holds; this only says which config tree it means.
- **Envelope:** a small versioned JSON object, so a future crypto change fails
  with a clear message rather than an unexplained decrypt error.
- **`key_is_tracked()`** reports when the key file has ended up inside a git
  work tree anyway, because a user can always undo the split by hand.

**The threat model is accidental disclosure, and that is a deliberate limit.**
This does not stop anyone who can read the key file: two local files cannot,
without a passphrase. What it stops is a credential being swept into a commit, a
backup, or a pasted config. Stating the limit matters more than the encryption
itself, because a false sense of protection here is worse than none.

**CommandCode authenticates with a static Provider API key**, not by reusing
pi's OAuth tokens.

## Consequences

### Positive

- A config directory symlinked into a dotfiles repository can no longer leak the
  credential, which is the realistic accident.
- The stored artifact is recognisably not-a-secret at a glance, unlike a JSON
  file that looks like configuration until you read it.
- File permissions are tightened as well, so the local-user case is covered too.

### Negative / costs

- **`openssl` becomes a dependency** for anything that reads a credential. It is
  present on this machine (3.5.7) and near-universal on Linux, but it is a
  dependency that did not exist before.
- **Losing the key file means losing the credential.** There is no recovery, by
  construction, and no export path. Re-entering the key is the remedy.
- **Reading is blocking.** It runs once and is cached, but it must not be called
  from a fast event context, which is a constraint every caller inherits.
- The key is only as safe as the data directory. A user who symlinks *that* into
  a repository defeats it, which is why the tracked-key check exists.
- The base64 path has a sharp edge: `openssl`'s decoder needs a terminating
  newline and otherwise fails with `error reading input file`, which reads like
  a wrong key. Now handled, and commented where it bit.

## Alternatives considered

**Plain `auth.json` at `0600`, matching pi.** Rejected. It is what exists today,
and the observed dotfiles symlink shows the accident is realistic rather than
theoretical.

**An OS keyring.** Would be the right answer if available: no key file to
misplace, and the secret is protected by the login session. Rejected because
this machine has no keyring — no `secret-tool`/libsecret, no python `keyring`
module — and adding a dependency plus a D-Bus session requirement for
credential storage is a large cost for a plugin.

**A passphrase, with gpg-agent caching.** Real encryption: someone with the key
file still cannot read it without the passphrase. Rejected for friction, and
kept as the upgrade path. The envelope is versioned precisely so this can be
added later without discarding existing files.

**A machine-derived key.** No key file at all, derived from machine-id and uid.
Rejected: same weakness as a key file plus non-portability — copying a
configuration to another machine silently makes it unreadable.

**Reusing pi's CommandCode OAuth tokens.** Rejected. pi stores `refresh`,
`access` and `expires`, not a key, so this means implementing an OAuth refresh
flow and depending on another tool's token layout. CommandCode offers a static
Provider API key, which is also what their own API documentation describes.

## Related

- [../providers.md](../providers.md) — where each provider's credentials come from
- [0010](0010-integrated-providers-are-presets.md)
