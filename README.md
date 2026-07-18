# agent-smith.nvim

Neovim AI agent built for control and power.

Agent-Smith provides bounded visual edits, structured multi-file changes with
approval, semantic search, tutorials, and sandboxed Vibe sessions.

Supports OpenCode, Claude Code, Cursor Agent, Gemini CLI, Kiro CLI, and
[pi](https://github.com/badlogic/pi-mono).

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "artumont/agent-smith.nvim",
  opts = {},
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "artumont/agent-smith.nvim",
  config = function()
    require("agent-smith").setup()
  end,
}
```

Completion integrations are optional. Install `nvim-cmp` or `blink.cmp` only if
you choose `completion.source = "cmp"` or `completion.source = "blink"`.

## Setup

```lua
local smith = require("agent-smith")

smith.setup({
  -- OpenCodeProvider is the default.
  provider = smith.Providers.OpenCodeProvider,

  -- Omit to use selected provider's default model.
  -- model = "provider/model",

  completion = {
    source = "native", -- "native" | "cmp" | "blink"
    custom_rules = {},
  },

  -- Context files discovered from current file toward git root.
  md_files = { "AGENTS.md" },

  -- Must be absolute, outside project, and allowed by provider permissions.
  tmp_dir = "/tmp/nvim/agent-smith",

  -- Default keymaps are enabled unless set to false.
  default_keymaps = true,
})
```

Default keymaps:

| Mode | Key | Operation |
|---|---|---|
| Visual | `<leader>as` | Visual edit |
| Visual | `<leader>aS` | Multi-file edit |
| Normal | `<leader>af` | Semantic search |
| Normal | `<leader>av` | Vibe mode |
| Normal | `<leader>ax` | Cancel all requests |

## Features

- **Visual Selection Edits**: Select code and provide instructions. The
  response replaces the selected range. Detected imports are routed to the
  file's import section.

- **Multi-File Edits**: Ask for changes across files using the structured
  `<FILE_CHANGE>` / `<CONTENT>` response format. Each proposed file opens in an
  approval window before it is written.

- **Semantic Search**: Ask a natural-language question and populate the
  quickfix list with parsed file, line, column, count, and note entries.

- **Sandboxed Vibe**: Run a two-phase workflow in a temporary project copy.
  The model first returns a plan and editable file scope. After plan approval,
  the sandbox is recreated from the original files, execution happens inside
  that sandbox, and only approved in-scope differences are offered for review.

- **Plan Review**: Review planned files and implementation steps before
  execution. Press `<CR>` to approve or `q`/`<Esc>` to cancel.

- **File Change Approval**: Review unified diffs or toggle to complete proposed
  content with `<Tab>`. Approve with `<CR>`, skip with `q`/`<Esc>`, or skip all
  remaining changes with `Q`.

- **New and Deleted Files in Vibe**: Vibe proposals can create, modify, or
  delete files. Changes outside the approved plan scope are ignored and
  reported.

- **Prompt References**: Type `#` for configured `SKILL.md` rules or `@` for
  project files. Selected references are resolved and injected into the prompt.

- **Project Context**: `AGENTS.md` and other configured markdown files are
  discovered from the current file toward the git root and added to prompts.

- **Completion Backends**: Use native Neovim completion, `nvim-cmp`, or
  `blink.cmp` for `#` and `@` prompt references.

- **Tutorial Generation**: Generate Markdown tutorials and display them in a
  split window.

- **Request Cancellation**: Stop all in-flight provider processes with
  `smith.stop_all_requests()`.

- **Request History**: Browse completed request logs with
  `smith.view_logs()`.

- **Statusline Component**: Expose the active request spinner and label through
  `smith.statusline()` and `smith.statusline_active()` for statusline plugins.

## Providers

| Provider | CLI | Status |
|---|---|---|
| `OpenCodeProvider` | `opencode` | Tested |
| `PiProvider` | `pi` | Tested |
| `ClaudeCodeProvider` | `claude` | Should work; unverified |
| `CursorAgentProvider` | `cursor-agent` | Should work; unverified |
| `GeminiCLIProvider` | `gemini` | Should work; unverified |
| `KiroProvider` | `kiro-cli` | Should work; unverified |

Only OpenCode and Pi have been tested so far. Other provider adapters are
implemented against the shared provider interface, but their current behavior
is not verified by the maintainers.

If you use another provider or platform, please verify the agent end to end
and open a pull request with any fixes, compatibility notes, and test details.
Contributions that improve support for untested providers are welcome.

Switch providers or models at runtime:

```lua
smith.set_provider(smith.Providers.PiProvider)
smith.set_model("provider/model")
```

If installed, Telescope and fzf-lua extensions also provide provider and model
selection pickers. Telescope pickers are available directly as:

```vim
:Telescope agent_smith providers
:Telescope agent_smith models
```

## Configuration

```lua
require("agent-smith").setup({
  -- Default: OpenCodeProvider
  provider = require("agent-smith").Providers.OpenCodeProvider,

  -- Default: selected provider's default model
  -- model = "provider/model",

  logger = {
    level = "warn",
    path = nil, -- Optional log file path
  },

  completion = {
    source = "native", -- "native" | "cmp" | "blink"
    custom_rules = {}, -- Directories containing named SKILL.md rules
  },

  md_files = { "AGENTS.md" },

  -- Sandbox root. Must be absolute and outside project.
  tmp_dir = "/tmp/nvim/agent-smith",

  default_keymaps = true,
})
```

## Lua API

Agent-Smith does not register `:AgentSmith...` Ex commands. Use the Lua API:

| Function | Description |
|---|---|
| `smith.setup(opts?)` | Initialize the plugin |
| `smith.visual(opts?)` | Edit the visual selection |
| `smith.multi_file(opts?)` | Request multi-file changes with approval |
| `smith.search(opts?)` | Search the project and populate quickfix |
| `smith.vibe(opts?)` | Run the sandboxed two-phase workflow |
| `smith.tutorial(opts?)` | Generate a tutorial in a split |
| `smith.stop_all_requests()` | Cancel in-flight requests |
| `smith.clear_previous_requests()` | Clear request history |
| `smith.set_model(model)` | Set the active model |
| `smith.get_model()` | Get the active model |
| `smith.set_provider(provider)` | Set the active provider |
| `smith.get_provider()` | Get the active provider |
| `smith.get_provider_name()` | Get the active provider name |
| `smith.view_logs()` | Browse request history |
| `smith.info()` | Show provider, model, and completed request count |
| `smith.statusline()` | Return statusline text |
| `smith.statusline_active()` | Return whether statusline text is active |

Search and Vibe accept `additional_prompt` to skip their prompt window:

```lua
smith.search({ additional_prompt = "Find all API endpoints" })
smith.vibe({ additional_prompt = "Analyze the authentication flow" })
```

## Extensions

Optional integrations:

- **Telescope**: Provider and model selection pickers.
- **fzf-lua**: Provider and model selection pickers.
- **Worker**: Track a work item and search or Vibe against remaining work.
- **Lualine**: Display `smith.statusline()` while requests are active.

Example lualine component:

```lua
{
  function() return require("agent-smith").statusline() end,
  cond = function()
    return require("agent-smith").statusline_active()
  end,
}
```

## Requirements

- Neovim >= 0.9
- One supported AI CLI available in `$PATH`
- Optional: `nvim-cmp`, `blink.cmp`, Telescope, or fzf-lua for integrations
