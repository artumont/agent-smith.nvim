--- Telescope command integration for Agent-Smith pickers.
---
--- Commands:
---   :Telescope agent_smith providers
---   :Telescope agent_smith models

local pickers = require("agent-smith.extensions.telescope")

return require("telescope").register_extension({
  exports = {
    providers = pickers.select_provider,
    models = pickers.select_model,
  },
})
