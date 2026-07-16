--- agent-smith/init.lua
---
--- Mr. Anderson, I’ve been expecting you…
---
--- This is the public API for Agent-Smith, a Neovim plugin for AI-assisted code editing.
---
--- Agent-Smith works by:
--- 1. Capturing a visual selection (or operating on search/vibe)
--- 2. Building a context window with: system prompts, AGENTS.md files, #rules, @files
--- 3. Shelling out to an AI CLI provider (opencode, claude, pi, etc.)
--- 4. Parsing the response and applying it (visual replace, quickfix, multi-file approval)
---
--- Key design decisions:
--- - Bounded editing: Visual edits only modify the selected region unless
---   explicitly using multi_file() which requires per-file approval.
--- - Provider agnostic: All AI CLIs implement the same BaseProvider interface.
---   Adding a new provider = one new file implementing 4 methods.
--- - Async non-blocking: All AI requests use vim.system() with callbacks.
---   The UI thread is never blocked.
---
--- Potential pitfalls:
--- - setup() must be called before any other function. The assertion in
---   configured() will fail with a clear message if you forget.
--- - Visual selection marks ('< and '>) are only valid right after leaving
---   visual mode. The plugin captures them immediately in Range.from_visual_selection().
--- - Provider processes can outlive the plugin if Neovim crashes. On normal exit,
---   VimLeavePre autocmd kills all in-flight requests.
--- - The state variable is module-local. Only one plugin instance can exist
---   per Neovim session (this is intentional - it's a singleton pattern).

local State = require("agent-smith.state")
local Logger = require("agent-smith.logger")
local Ops = require("agent-smith.ops")
local Select = require("agent-smith.window.select-window")
local Window = require("agent-smith.window")
local Statusline = require("agent-smith.statusline")
local UI = require("agent-smith.ui")

local M = {}
local state = nil -- Module-local singleton. One instance per Neovim session.

--- Available AI provider backends.
--- Each implements the BaseProvider interface from providers/init.lua.
---
--- Usage:
---   local smith = require("agent-smith")
---   smith.setup({ provider = smith.Providers.PiProvider })
M.Providers = {
	OpenCodeProvider = require("agent-smith.providers.opencode"),
	ClaudeCodeProvider = require("agent-smith.providers.claude"),
	CursorAgentProvider = require("agent-smith.providers.cursor"),
	GeminiCLIProvider = require("agent-smith.providers.gemini"),
	KiroProvider = require("agent-smith.providers.kiro"),
	PiProvider = require("agent-smith.providers.pi"),
}

--- Extension modules that can be accessed directly.
--- Worker provides work-item tracking for iterative development.
M.Extensions = { Worker = require("agent-smith.extensions.worker") }

--- Guard function: returns current state or errors if setup() not called.
--- All public functions that need state call this first.
local function configured()
	assert(state, "Call require('agent-smith').setup() first")
	return state
end

--- Initialize Agent-Smith plugin.
---
--- Must be called once before using any other function. Sets up:
--- - State singleton with provider, model, rules, tracking
--- - Extensions (completions, file references)
--- - Default keymaps (unless default_keymaps = false)
--- - VimLeavePre autocmd to kill in-flight requests on exit
---
---@param opts? table Configuration options:
---   - provider: BaseProvider (default: OpenCodeProvider)
---   - model: string (default: provider's default model)
---   - logger: { level: string, path?: string }
---   - completion: { source: "native"|"cmp"|"blink", custom_rules: string[] }
---   - md_files: string[] (context files to discover, default: {"AGENTS.md"})
---   - tmp_dir: string (temp file directory)
---   - default_keymaps: boolean (set false to disable default keymaps)
---@return table M The module table for chaining
function M.setup(opts)
	opts = opts or {}
	opts.provider = opts.provider or M.Providers.OpenCodeProvider

	state = State.new(opts)
	state.model = opts.model or opts.provider:_get_default_model()
	Logger:configure(opts.logger)
	UI.set_accent(state.matrix_mode)

	require("agent-smith.extensions").init(state)

	-- Default keymaps: visual edit, multi-file, search, vibe, cancel
	if opts.default_keymaps ~= false then
		vim.keymap.set("v", "<leader>as", function()
			M.visual()
		end, { desc = "Agent-Smith visual edit" })
		vim.keymap.set("v", "<leader>aS", function()
			M.multi_file()
		end, { desc = "Agent-Smith multi-file edit" })
		vim.keymap.set("n", "<leader>af", function()
			M.search()
		end, { desc = "Agent-Smith search" })
		vim.keymap.set("n", "<leader>av", function()
			M.vibe()
		end, { desc = "Agent-Smith vibe" })
		vim.keymap.set("n", "<leader>ax", function()
			M.stop_all_requests()
		end, { desc = "Agent-Smith cancel" })
	end

	-- Safety: kill all provider processes when Neovim exits
	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			M.stop_all_requests()
		end,
	})

	-- Show one self-contained floating choice after setup has finished.
	if not State.read_choice() and #vim.api.nvim_list_uis() > 0 then
		vim.schedule(function()
			require("agent-smith.window.first-run-window").open(function(choice)
				State.write_choice(choice)
				state.matrix_mode = choice == "red"
				UI.set_accent(state.matrix_mode)
			end)
		end)
	end

	return M
end

--- Start a visual selection edit.
---
--- Captures the current visual selection, prompts for instructions, and asks
--- the AI to replace only that selection. Imports detected in the response
--- are routed to the file's import section automatically.
---
--- Flow:
--- 1. Capture visual selection -> Range object
--- 2. Open floating prompt window
--- 3. User types instructions, presses :w to submit
--- 4. Build context (AGENTS.md, #rules, @files, system prompt)
--- 5. Shell out to provider asynchronously
--- 6. On response: extract imports -> place at file top -> replace selection body
---
---@param opts? table Optional overrides:
---   - multi_file: boolean (use multi-file protocol instead)
---@return nil
function M.visual(opts)
	return Ops.visual.run(configured(), opts)
end

--- Start a multi-file edit with per-file approval.
---
--- Like visual() but uses the multi-file protocol where the AI outputs
--- structured <FILE_CHANGE>/<CONTENT> blocks for each file. Each block
--- is presented to the user for approval before application.
---
--- IMPORTANT: This function requires the AI to understand the multi-file
--- output format. The system prompt includes instructions for this, but
--- not all models handle it equally well.
---
---@param opts? table Optional overrides
---@return nil
function M.multi_file(opts)
	opts = opts or {}
	opts.multi_file = true
	return M.visual(opts)
end

--- Run a semantic search across the project.
---
--- Sends a natural language query to the AI, which scans the codebase and
--- returns structured locations (file:line:col,count,note). Results are
--- populated into the quickfix list.
---
--- The AI must follow a strict output format for search results. If the
--- response doesn't match the expected format, no quickfix entries are created.
---
---@param opts? table Optional:
---   - additional_prompt: string (skip prompt window, use this directly)
---@return nil
function M.search(opts)
	return Ops.search.run(configured(), opts)
end

--- Run vibe mode: open-ended AI analysis.
---
--- Similar to search() but for broader codebase operations. The AI performs
--- whatever action was requested and reports what it did via quickfix entries.
---
---@param opts? table Optional:
---   - additional_prompt: string (skip prompt window, use this directly)
---@return nil
function M.vibe(opts)
	return Ops.vibe.run(configured(), opts)
end

--- Start a tutorial generation request.
---
--- The AI creates a tutorial based on the prompt, which is displayed in
--- a split window. Tutorial output must be valid Markdown with a title
--- on the first line.
---
---@param opts? table Optional overrides
---@return nil
function M.tutorial(opts)
	return Ops.tutorial.run(configured(), opts)
end

--- Cancel all in-flight requests.
---
--- Sends SIGTERM to all running provider processes. Responses in progress
--- are discarded. This is safe to call multiple times.
---
---@return nil
function M.stop_all_requests()
	if state then
		state.tracking:stop_all_requests()
		vim.notify("Agent-Smith requests cancelled")
	end
end

--- Clear request history.
---
---@return nil
function M.clear_previous_requests()
	configured().tracking:clear_history()
end

--- Set the active model for subsequent requests.
---
---@param model string Model identifier (provider-specific)
---@return table M For chaining: smith.set_model("x").set_provider(y)
function M.set_model(model)
	configured().model = model
	return M
end

--- Get the current model identifier.
---@return string
function M.get_model()
	return configured().model
end

--- Set the active provider (also resets model to provider default).
---
---@param provider table A provider from M.Providers
---@return table M For chaining
function M.set_provider(provider)
	assert(provider, "Unknown provider")
	configured().provider_override = provider
	configured().model = provider:_get_default_model()
	return M
end

--- Get the currently active provider (override or default).
---@return table
function M.get_provider()
	return configured():active_provider()
end

--- Get the name of the current provider.
---@return string
function M.get_provider_name()
	return M.get_provider():_get_provider_name()
end

--- View past request history in a selectable list.
---
--- Opens a floating window showing all completed requests. Select one
--- to view its full logs. Useful for debugging failed requests.
---
---@return nil
function M.view_logs()
	local items = configured().tracking.history
	Select.select(
		"Request History",
		vim.tbl_map(function(p)
			return p.operation .. ": " .. p:summary()
		end, items),
		function(index)
			local p = index and items[index]
			if p then
				Window.display_full_screen_message(Logger:logs_by_id(p.xid) or { "No logs for request" })
			end
		end
	)
end

--- Show current plugin status.
---
---@return nil
--- Return animated request text for lualine or another statusline plugin.
--- Add `function() return require("agent-smith").statusline() end` as a
--- lualine component. Returns an empty string while no tracked status runs.
---@return string
function M.statusline()
	return Statusline.component()
end

--- Return whether an Agent-Smith statusline indicator is active.
---@return boolean
function M.statusline_active()
	return Statusline.is_active()
end

function M.info()
	vim.notify(
		string.format(
			"Agent-Smith: %s (%s), %d requests",
			M.get_provider_name(),
			M.get_model(),
			configured().tracking:completed()
		)
	)
end

--- Internal: get state singleton (for testing/extensions).
---@return table
function M.__get_state()
	return state
end

return M
