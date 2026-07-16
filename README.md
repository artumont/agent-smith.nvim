# agent-smith.nvim

Neovim AI agent built for control and power.

Agent-Smith keeps AI edits bounded to your visual selection. Multi-file edits are
proposed individually and require explicit approval. Supports OpenCode, Claude Code,
Cursor Agent, Gemini CLI, Kiro, and [pi](https://github.com/badlogic/pi-mono).

## Requirements

- Neovim >= 0.9
- One supported AI CLI available in `$PATH`

## Setup

```lua
{
  "artumont/agent-smith.nvim",
  config = function()
    local smith = require("agent-smith")
    smith.setup({
      -- Default: smith.Providers.OpenCodeProvider
      -- provider = smith.Providers.PiProvider,
      -- model = "provider/model",
      completion = { source = "native", custom_rules = {} },
      md_files = { "AGENTS.md" },
    })

    vim.keymap.set("v", "<leader>as", function() smith.visual() end)
    vim.keymap.set("v", "<leader>aS", function() smith.multi_file() end)
    vim.keymap.set("n", "<leader>af", function() smith.search() end)
    vim.keymap.set("n", "<leader>av", function() smith.vibe() end)
    vim.keymap.set("n", "<leader>ax", function() smith.stop_all_requests() end)
  end,
}
```

## Commands

- `visual()` — replace visual selection only.
- `multi_file()` — request structured changes, approve each file.
- `search()` — semantic search into quickfix list.
- `vibe()` — open-ended analysis into quickfix list.
- `stop_all_requests()` — cancel running provider processes.
- `view_logs()` — browse request history.

Use `#rule-name` to inject a configured `SKILL.md`; use `@path/to/file` to inject a
project file. `AGENTS.md` files are discovered from current file up to git root.
