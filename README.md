# agent-smith.nvim

An AI agent for Neovim that **owns its own loop**: it talks to the model, runs
the tools, enforces what may be touched, and shows you what happened. It is not a
wrapper around a CLI agent.

Two modes, no chat. You select code and ask for a change, or you hand it a task
and approve a plan.

- **Inline** — edit one region of the current buffer.
- **Vibe** — plan, approve, execute in a disposable clone, review the diff.

> **Pre-1.0, and a rewrite in progress.** The whole implementation was replaced;
> nothing from the old CLI-wrapper version survives. Linux only for now.
> See [`spec/`](spec/) for the decisions and their reasoning.

## Requirements

| | |
|---|---|
| Neovim | **0.10 or newer** (`vim.json`, `vim.system`) |
| Platform | **Linux** — see [ADR 0009](spec/decisions/0009-linux-only-v1.md) |
| `curl` | **Required.** Carries every request. |
| `git` | Required for vibe; it is what the clone is made from. |
| `openssl` | Required to read or write a stored credential. |
| `bwrap` | Optional. Without it the `bash` tool is disabled. |
| `rg` | Optional. Without it `grep` and `glob` fall back to slower built-ins. |

Check all of that with `:checkhealth agent-smith`.

## Install

Nothing loads on its own — there is no `plugin/` directory — so `setup()` is
required.

```lua
{
  "artumont/agent-smith.nvim",
  config = function()
    require("agent-smith").setup({
      provider = "commandcode",
      model = "deepseek/deepseek-v4-flash",
    })
  end,
}
```

For working on the plugin itself, point at the checkout instead:

```lua
{ dir = "~/path/to/agent-smith.nvim", config = function() ... end }
```

## Setup

`provider` is a preset and `model` is an id the provider actually serves; neither
is guessed. **Models are fetched from the provider rather than catalogued**
([ADR 0012](spec/decisions/0012-models-are-fetched-not-catalogued.md)), so an id
that is wrong for your account fails with the vendor's own message.

```lua
require("agent-smith").setup({
  provider = "commandcode",              -- "commandcode" | "zen" | "go"
  model = "deepseek/deepseek-v4-flash",

  sandbox = {
    network = false,                     -- no network inside the sandbox
  },

  progress = {
    position = "below",                  -- "below" | "above", inline only
  },
})
```

### Credentials

The quickest way is the command. It asks, checks the key against the provider, and
stores it encrypted:

```vim
:Smith setup                 " asks which provider, then for the key
:Smith setup commandcode     " or name the provider up front
```

The key is typed hidden and never echoed. Nothing is written if the provider
rejects it, so a typo cannot replace a working credential with a broken one — and
where a gateway publishes its catalogue publicly there is nothing to check a key
against until a real request, which the command says rather than claiming it
verified anything.

Or export the provider's variable, which stores nothing at all:

```sh
export CMD_API_KEY="..."        # commandcode
export OPENCODE_API_KEY="..."   # zen and go share one credential
```

A variable takes precedence over the store, so a stale `export` in a shell profile
will quietly shadow a credential you stored later. `:Smith setup` warns when it
notices one.

Or call the store directly:

```lua
local store = require("agent-smith.auth").new()
store:set("commandcode", "your-key-here")
store:get("commandcode")   -- "your-key-here"
store:list()               -- { "commandcode" }
store:remove("commandcode")
```

Stored credentials are **encrypted at rest**, because a plain `auth.json` in a
config directory is one `git add -A` away from being published
([ADR 0011](spec/decisions/0011-credentials-encrypted-at-rest.md)). They land in
two files, deliberately in different trees:

```text
~/.config/agent-smith/auth.json              encrypted: an accidental commit is not a leak
~/.local/share/nvim/agent-smith/auth.key     the key; never commit this
```

The split is the decision. The encrypted file goes in a config tree because that
is where a credential belongs, but **not** Neovim's own `~/.config/nvim`, which
is the tree people put under version control. Losing the key means losing the
credential — there is no recovery and no export, by construction.

### Choosing a model or provider

`setup()` is where a provider and a model are written down, but neither has to be
typed to be changed:

```vim
:Smith model        " every model the provider serves, with its route
:Smith provider     " the presets, and whether each has a credential
```

The model list is the provider's own catalogue, so anything offered is routable by
construction, and each line says which API it answers on and how much context it
has.

Both choices apply to **the current session only** and are written nowhere. Your
configuration keeps meaning exactly what it says, and restarting Neovim goes back
to it. `:Smith info` marks a model that came from a picker with `(this session)`,
and both pickers offer a way back to what `setup()` configured.

Choosing a provider also checks the current model against it and opens the model
picker when it does not belong there — a model id only means anything against the
provider that serves it, so one command should not be able to leave you in a state
that cannot run.

## Use

### Inline — `<leader>as`

1. Select lines in visual mode.
2. `<leader>as` opens a prompt. Type an instruction, then `:w` to send it, `q` to
   close without sending.
3. A spinner appears at the **top of your selection** while it works.
4. The change lands in the **buffer, not on disk**. Save to accept it, `u` to
   revert the whole turn.

Writing is bounded to the selected lines. If a correct change needs somewhere
else, the agent asks rather than refusing or going ahead
([ADR 0004](spec/decisions/0004-bounded-edit-with-escalation.md)).

### Vibe — `<leader>av`

Four phases, each of them a stopping point
([ADR 0007](spec/decisions/0007-vibe-workflow.md)):

1. **Plan.** Read-only. The agent investigates and declares the steps and every
   file it intends to modify.
2. **Approve.** The plan opens in a window. `a` accepts, `d` denies.
3. **Execute.** A fresh clone is made from committed state and the work happens
   there. Writes outside the approved file list are **refused and recorded**.
4. **Review.** The diff opens, coloured, with any refusals listed above it. `a`
   applies it to your repository, `d` discards the clone.

`<leader>ax` stops a run in flight.

Because execution happens in a clone, **vibe does not see your uncommitted
changes** — it works from what is committed
([open question](spec/open-questions.md)).

### While a run is going

Vibe shows a **floating panel in the corner of the screen**, so it stays visible
while you scroll or switch files. Inline draws inside the buffer, at the
selection, because that is where you are already looking. Either way it stays
under two lines and tells you the latest action and the token usage, including
the cache hit rate.

### Keys

| Key | Mode | Does |
|---|---|---|
| `<leader>as` | visual | Inline edit on the selection |
| `<leader>av` | normal | Vibe run |
| `<leader>ax` | normal | Cancel the run in flight |
| `:Smith info` | | Version, provider, model, sandbox state |
| `:Smith setup` | | Store a credential, interactively |
| `:Smith model` | | Pick a model, for this session |
| `:Smith provider` | | Pick a provider, for this session |
| `:Smith version` | | Version only |
| `:checkhealth agent-smith` | | Dependencies and configuration |

Inside the prompt: `:w` sends, `q` or `:q` closes. Inside a decision window: `a`
accepts, `d` denies, `q` or `<Esc>` denies.

## Options

| Option | Default | |
|---|---|---|
| `commands` | `true` | Register `:Smith`. |
| `default_keymaps` | `true` | Register the three keymaps above. |
| `provider` | `nil` | Preset name, or a table with a `base_url`. |
| `model` | `nil` | Required for any run; there is no default on purpose. |
| `sandbox.root` | `stdpath("cache")/agent-smith/sandbox` | Where clones are made. Must be absolute and outside the project. |
| `sandbox.network` | `false` | Allow network access inside the sandbox. |
| `sandbox.blacklist` | `rm`, `mkfs`, `dd`, `shutdown`, … | Lua patterns refused before execution. **A guardrail, not a boundary.** |
| `progress.position` | `"below"` | Inline status above or below the selection. |
| `auth.file` | `~/.config/agent-smith/auth.json` | Encrypted credentials. |
| `auth.key_file` | `~/.local/share/nvim/agent-smith/auth.key` | Decryption key. |

## What is actually enforced

Four independent layers, deliberately redundant
([ADR 0005](spec/decisions/0005-permission-model.md)):

| Layer | Enforces | Trust level |
|---|---|---|
| Scope | Which paths and ranges may be written | Policy, in-process |
| Blacklist | Obvious accidents in commands | **Guardrail only** — trivially bypassed by a shell |
| `bwrap` | Filesystem and network reachable by commands | Boundary, kernel-enforced |
| Isolated clone | What a vibe run can reach at all | Boundary, and disposable |

The honest summary: the sandbox is the boundary, and the permission rules are
there to catch mistakes and keep you informed. Do not read the blacklist as
security.

## Providers

All three are **presets** — a base URL, a credential and a routing rule — not
separate transports ([ADR 0010](spec/decisions/0010-integrated-providers-are-presets.md)).
Models are fetched, so this table does not go stale:

| Preset | Base URL | Credential | Session header |
|---|---|---|---|
| `zen` | `opencode.ai/zen/v1` | `OPENCODE_API_KEY` | `x-opencode-session` |
| `go` | `opencode.ai/zen/go/v1` | `OPENCODE_API_KEY` | `x-opencode-session` |
| `commandcode` | `api.commandcode.ai/provider/v1` | `CMD_API_KEY` | none |

Three wire formats are implemented: `/chat/completions`, `/responses` (the
GPT-family models on Zen and Go), and `/messages` (Claude on Command Code). A
model is routed by what the provider publishes in its `supported_endpoints`.

**Verification status, stated plainly:**

- **`/chat/completions`** — verified end to end against a live provider.
- **`/responses`** — implemented and tested against the documented protocol, but
  never exercised against a live vendor.
- **`/messages`** — the same, and it cannot currently be verified here: every
  Claude model returns `MODEL_NOT_IN_PLAN` on the account this was developed
  with. The routing itself is real — sending a Claude id to `/chat/completions`
  is refused with `must be called via /provider/v1/messages`.

Details in [`spec/providers.md`](spec/providers.md).

## Development

```sh
make test     # headless test suite
make run      # Neovim with your config, plus the plugin
make run-clean  # the plugin alone, for when your config is the problem
make help     # list targets
```

`make run` loads your real configuration first and then the repository, so the
plugin is exercised against the environment it will actually run in. There is no
`plugin/` directory, so `setup()` must be called; `dev/init.lua` does it for you.

Tests are headless Lua spec files under `test/spec/`, run with no plugins loaded.

## Documentation

The reasoning lives in [`spec/`](spec/), not here. Start at
[`spec/README.md`](spec/README.md) for the decision index, or read
[`spec/architecture.md`](spec/architecture.md) for the module map and data flow.

```vim
:help agent-smith
```

## License

GPL-3.0. See [LICENSE](LICENSE).
