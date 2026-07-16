--- agent-smith/ops/init.lua
---
--- Operation module registry.
---
--- Centralizes access to all operations:
--- - visual: Visual selection code replacement
--- - search: Semantic search → quickfix
--- - vibe: Open-ended analysis → quickfix
--- - tutorial: Tutorial generation
--- - multi_file: Multi-file edit with approval

return {
  visual = require("agent-smith.ops.visual"),
  search = require("agent-smith.ops.search"),
  vibe = require("agent-smith.ops.vibe"),
  tutorial = require("agent-smith.ops.tutorial"),
  multi_file = require("agent-smith.ops.multi-file"),
}
