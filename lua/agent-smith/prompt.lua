--- agent-smith/prompt.lua
---
--- Manages the lifecycle of a single AI interaction (request).
---
--- A Prompt object is created for each operation (visual, search, vibe, tutorial).
--- It assembles the context window, manages state transitions, and coordinates
--- with the provider for async execution.
---
--- Lifecycle states:
---   ready -> requesting -> success
---                        -> failed
---                        -> cancelled
---
--- Request assembly and isolation:
--- 1. Read AGENTS.md files from original project hierarchy
--- 2. Copy project into unique disposable workspace under tmp_dir
--- 3. Assemble operation contract, user request, relative file reference,
---    resolved #rules/@files, and visual selection content
--- 4. Run provider from disposable workspace
--- 5. Remap response paths to original project and delete workspace
---
--- Potential pitfalls:
--- - Mark validity: Visual selection marks ('< and '>) are only valid
---   immediately after leaving visual mode. Range.from_visual_selection()
---   captures them at the right moment. If you call new() later, the
---   marks may be stale.
--- - Sandbox cost: Each non-Vibe request copies tracked plus untracked,
---   nonignored project files. Large repositories may increase startup time.
--- - Context window size: Large AGENTS.md files or many #rules can inflate
---   the context. There's no automatic truncation. Keep context files concise.
--- - Provider response format: Each provider returns raw text. The parsing
---   happens in the operation modules (visual, search, vibe). The Prompt
---   module doesn't parse responses.
--- - Cancellation safety: Calling cancel() while the provider is running
---   sends SIGTERM. The exit callback checks is_cancelled() and discards
---   the response. This is safe even if the process has already exited
---   (kill on dead PID is a no-op).

local id = require("agent-smith.id")
local Utils = require("agent-smith.utils")
local Prompts = require("agent-smith.prompts")
local Geo = require("agent-smith.geo")
local Sandbox = require("agent-smith.ops.vibe-session")

local M = {}
M.__index = M

--- Create a new Prompt for the given operation.
---
---@param state table The plugin state singleton
---@param operation string "visual" | "search" | "vibe" | "tutorial"
---@return table prompt The new Prompt object
function M.new(state, operation)
	local self = setmetatable({
		_state = state,
		xid = id(),
		operation = operation,
		state = "ready",
		-- Provider commands read the request-scoped model. Without this field,
		-- nil truncates command arrays at the model flag and drops the prompt.
		model = state.model,
		user_prompt = "",
		full_path = vim.api.nvim_buf_get_name(0),
		started_at = vim.uv.hrtime(),
		updated_at = vim.uv.hrtime(),
		progress = "Ready",
		output = {},
		agent_context = {},
		tmp_file = Utils.random_file(state:tmp_dir()),
		clean_ups = {},
		marks = {},
	}, M)

	-- Visual operations need the selection range captured immediately
	-- because the marks are only valid right after leaving visual mode
	if operation == "visual" then
		self.range = Geo.Range.from_visual_selection()
		self.buffer = vim.api.nvim_get_current_buf()
	end

	return self
end

--- Get a short summary of the prompt for display in lists.
---@return string First line, truncated to 80 chars
function M:summary()
	return self.user_prompt:gsub("\n.*", ""):sub(1, 80)
end

--- Update user-visible request phase.
---@param phase string
function M:set_progress(phase)
	self.progress = phase
	self.updated_at = vim.uv.hrtime()
end

--- Record bounded provider output for request-progress view.
---@param text string
function M:push_output(text)
	for line in text:gmatch("[^\r\n]+") do
		line = vim.trim(line):gsub("\27%[[%d;]*m", "")
		if line ~= "" then
			table.insert(self.output, vim.fn.strcharpart(line, 0, 200))
		end
	end
	while #self.output > 6 do table.remove(self.output, 1) end
	self.updated_at = vim.uv.hrtime()
end

--- Check if this request was cancelled.
---@return boolean
function M:is_cancelled()
	return self.state == "cancelled"
end

--- Check if this request reached a terminal state.
---@return boolean
function M:is_completed()
	return self.state == "success" or self.state == "failed" or self.state == "cancelled"
end

--- Store the running process handle (for cancellation).
---@param proc table vim.system() return value
function M:_set_process(proc)
	self._proc = proc
end

--- Cancel this request by killing the provider process.
---
--- Safe to call multiple times. If already completed, this is a no-op.
--- Sends SIGTERM (not SIGKILL) to allow graceful cleanup.
---
---@return nil
function M:cancel()
	if self:is_completed() then
		return
	end
	self.state = "cancelled"
	self:set_progress("Cancelling")
	if self._cancel_queued and self._cancel_queued() then return end
	if self._proc then
		pcall(self._proc.kill, self._proc, vim.uv.constants.SIGTERM)
	end
end

--- Add a text block to the agent context (assembled query).
---@param text string Content to include
function M:add_prompt_content(text)
	table.insert(self.agent_context, text)
end

--- Add resolved references (#rules, @files) to the agent context.
---@param refs table[] Array of { content: string }
function M:add_references(refs)
	for _, ref in ipairs(refs) do
		table.insert(self.agent_context, ref.content)
	end
end

--- Discover and inject AGENTS.md (or configured md_files) from directory hierarchy.
---
--- Walks from the current file's directory up to the git root (or cwd),
--- collecting matching markdown files at each level. This enables
--- hierarchical project context without repeating rules.
---
--- Potential issue: If a file is in a directory outside the git root
--- (e.g., a symlink), the walk stops at the git root. Files above
--- the root won't be discovered.
function M:_read_md_files()
	local root = self.cwd or vim.fs.root(self.full_path, ".git") or vim.fn.getcwd()
	local dir = vim.fs.dirname(self.full_path)

	while dir and dir:sub(1, #root) == root do
		for _, name in ipairs(self._state.md_files) do
			local text = Utils.read_file(vim.fs.joinpath(dir, name))
			if text then
				table.insert(self.agent_context, text)
			end
		end
		if dir == root then
			break
		end
		dir = vim.fs.dirname(dir)
	end
end

--- Create disposable project copy for non-Vibe requests. Vibe owns its
--- two-phase sandbox lifecycle and sets _sandbox itself.
---@return boolean ok
---@return string|nil error_message
function M:_prepare_sandbox()
	if self.operation == "vibe" or self.skip_sandbox or self._sandbox then return true, nil end

	local ok, session = pcall(Sandbox.create, self.full_path, self._state:tmp_dir(), {
		prefix = "request",
		snapshot = false,
	})
	if not ok then return false, tostring(session) end

	self._sandbox = session
	self._source_cwd = self.cwd or session.project_root
	self.cwd = session.root
	self.file_reference = session.current_relative or "."
	self.tmp_file = vim.fs.joinpath(session.root, ".agent-smith-response-" .. self.xid)
	return true, nil
end

function M:_cleanup_sandbox()
	if not self._sandbox or self.operation == "vibe" then return end
	Sandbox.cleanup(self._sandbox)
	self._sandbox = nil
	self.cwd = self._source_cwd or self.cwd
	self._source_cwd = nil
end

--- Start the request: assemble context and send to provider.
---
--- This is the main entry point that kicks off the async AI request.
--- It assembles the full context window and hands it to the provider.
---
---@param user_prompt string The developer's instructions
---@param observer table Callbacks: { on_stdout, on_complete }
---@return nil
function M:start(user_prompt, observer)
	if self:is_cancelled() then
		self._state.tracking:complete(self)
		observer.on_complete("cancelled", "")
		return
	end

	self.user_prompt = user_prompt
	self:_read_md_files()
	self.state = "requesting"
	if self.operation ~= "vibe" then self:set_progress("Preparing sandbox") end
	self._state.tracking:track(self)

	local sandbox_ok, sandbox_error = self:_prepare_sandbox()
	if not sandbox_ok then
		self.state = "failed"
		self:set_progress("Sandbox setup failed")
		self._state.tracking:complete(self)
		observer.on_complete("failed", "Unable to create request sandbox: " .. sandbox_error)
		return
	end

	-- Build operation-specific instruction. Multi-phase workflows may supply
	-- an explicit contract through context.instruction.
	local instruction = self.instruction
	if instruction then
		-- Keep the supplied phase-specific contract.
	elseif self.operation == "visual" then
		instruction = Prompts.visual(self.range)
	elseif self.operation == "search" then
		instruction = Prompts.search()
	else
		instruction = Prompts.vibe()
	end

	-- Assemble context pieces
	self:add_prompt_content(Prompts.wrap(instruction, user_prompt))
	self:add_prompt_content("<FILE>" .. (self.file_reference or self.full_path) .. "</FILE>")

	-- Resolve #rules and @files from the user prompt
	self:add_references(require("agent-smith.extensions.completions").parse(user_prompt))

	-- Final query is all context pieces joined
	local query = table.concat(self.agent_context, "\n")
	local provider = assert(self._state:active_provider(), "Agent-Smith provider not configured")

	-- Text-response operations must finish after provider output goes idle. Some
	-- agent CLIs leave helper pipes open after their final answer, otherwise
	-- keeping search, visual edits, and tutorials stuck in "Working".
	if self.operation ~= "vibe" and not self.response_idle_timeout_ms then
		self.response_idle_timeout_ms = 2000
	end

	-- Send to provider (async, non-blocking)
	provider:make_request(query, self, {
		on_start = function()
			if self.operation ~= "vibe" then self:set_progress("Working") end
		end,
		on_stdout = function(line)
			self:push_output(line)
			if observer.on_stdout then
				observer.on_stdout(line)
			end
		end,
		on_stderr = function(line)
			-- Provider CLIs often report permission prompts, tool activity, and
			-- progress on stderr. Keep it visible in the progress view.
			self:push_output(line)
		end,
		on_complete = function(status, response)
			self:set_progress(status == "success" and "Finished" or status)
			if self._sandbox then
				response = Sandbox.remap_response(self._sandbox, response or "")
			end
			self:_cleanup_sandbox()
			self.state = status
			self._state.tracking:complete(self)
			observer.on_complete(status, response)
		end,
	})
end

return M
