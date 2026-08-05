--- Floating live view for queued and provider-running Agent-Smith requests.

local M = {}

local timer_interval = 250
local controls_namespace = vim.api.nvim_create_namespace("agent-smith.progress.controls")

local function highlight_control(buf, line, token)
	local start = line:find(token, 1, true)
	if not start then
		return
	end
	vim.api.nvim_buf_set_extmark(buf, controls_namespace, 1, start - 1, {
		end_col = start - 1 + #token,
		hl_group = "WarningMsg",
	})
end

local function elapsed(prompt)
	local seconds = math.floor((vim.uv.hrtime() - prompt.started_at) / 1000000000)
	return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function lines_for(prompt, queued)
	local state = queued and "Queued" or (prompt.progress or prompt.state)
	local lines = {
		string.format("[%s] %s  %s", state, prompt.operation, elapsed(prompt)),
		"  " .. (prompt:summary() ~= "" and prompt:summary() or "Waiting for instructions"),
	}
	if #prompt.output > 0 then
		table.insert(lines, "  Latest agent output:")
		for _, line in ipairs(prompt.output) do
			table.insert(lines, "    " .. line)
		end
	end
	return lines
end

--- Render current queue and provider work. Exported for headless tests.
---@param tracking table Tracking instance
---@return string[]
function M.lines(tracking)
	local lines = {
		"q / Esc close   r refresh   x cancel all",
		"",
	}
	local pending = tracking:pending()
	if #pending == 0 then
		table.insert(lines, "No queued or active Agent-Smith requests.")
		return lines
	end

	for index, prompt in ipairs(pending) do
		vim.list_extend(lines, lines_for(prompt, tracking.queued[prompt.xid] ~= nil))
		if index < #pending then
			table.insert(lines, "")
		end
	end
	return lines
end

---@param state table Plugin state
---@return number|nil win
function M.open(state)
	local tracking = state.tracking
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "agent-smith-progress"
	local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
	local width = math.min(100, math.max(52, math.floor(ui.width * 0.7)))
	local height = math.min(24, math.max(7, math.floor(ui.height * 0.55)))
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " Agent-Smith Progress ",
		title_pos = "center",
		width = width,
		height = height,
		row = math.floor((ui.height - height) / 2),
		col = math.floor((ui.width - width) / 2),
	})

	local function render()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.bo[buf].modifiable = true
		local lines = M.lines(tracking)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_clear_namespace(buf, controls_namespace, 0, -1)
		highlight_control(buf, lines[1], "q")
		highlight_control(buf, lines[1], "Esc")
		highlight_control(buf, lines[1], "r")
		highlight_control(buf, lines[1], "x")
		vim.bo[buf].modifiable = false
	end
	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "Close progress" })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf, nowait = true, desc = "Close progress" })
	vim.keymap.set("n", "r", render, { buffer = buf, nowait = true, desc = "Refresh progress" })
	vim.keymap.set("n", "x", function()
		tracking:stop_all_requests()
		render()
	end, { buffer = buf, nowait = true, desc = "Cancel all requests" })

	local function refresh()
		if not vim.api.nvim_win_is_valid(win) or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		render()
		vim.defer_fn(refresh, timer_interval)
	end
	render()
	vim.defer_fn(refresh, timer_interval)
	return win
end

return M
