local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local repo_root = vim.fs.dirname(vim.fs.dirname(assert(vim.uv.fs_realpath(test_file))))
vim.opt.runtimepath:append(repo_root)

local Tracking = require("agent-smith.tracking")
local Progress = require("agent-smith.window.progress-window")
local Queue = require("agent-smith.ops.visual-queue")

local function prompt(xid, operation, summary)
  local p = {
    xid = xid,
    operation = operation,
    started_at = vim.uv.hrtime(),
    progress = "Working",
    output = {},
  }
  function p:summary() return summary end
  function p:cancel() self.cancelled = true end
  return p
end

local tracking = Tracking.new()
local queued = prompt("queued", "visual", "Extract helper")
local active = prompt("active", "vibe", "Update auth flow")
active.progress = "Planning Vibe"
active.output = { "Reading auth.lua", "Checking tests" }

tracking:queue(queued)
tracking:track(active)
local lines = Progress.lines(tracking)
local output = table.concat(lines, "\n")
assert(output:find("[Queued] visual", 1, true), "queued request missing")
assert(output:find("[Planning Vibe] vibe", 1, true), "Vibe phase missing")
assert(output:find("Latest agent output:", 1, true), "agent output header missing")
assert(output:find("Checking tests", 1, true), "agent output missing")

tracking:stop_all_requests()
assert(queued.cancelled and active.cancelled, "stop_all did not cancel queued and active requests")
tracking:complete(queued)
tracking:complete(active)
assert(#tracking:pending() == 0, "completed requests remain pending")
assert(#tracking.history == 2, "completed requests not retained in history")
assert(
  table.concat(Progress.lines(tracking), "\n"):find("No queued or active", 1, true),
  "empty progress state missing"
)
local progress_win = Progress.open({ tracking = tracking })
assert(progress_win and vim.api.nvim_win_is_valid(progress_win), "progress window did not open")
vim.api.nvim_win_close(progress_win, true)

local first_done
local ran_cancelled_job = false
Queue.enqueue(0, function(done) first_done = done end)
local cancel_second = Queue.enqueue(0, function() ran_cancelled_job = true end)
assert(cancel_second(), "queued visual job was not removable")
first_done()
assert(not ran_cancelled_job, "cancelled visual job ran after queue advanced")

local Status = require("agent-smith.window.status-window")
local buffer = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "selected code" })
local status = Status.new("Implementing", {
  buffer = buffer,
  row = 0,
  above = true,
  show_output = true,
})
status:start()
status:push("Inspecting dependencies\nFound config")
local marks = vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })
local rendered = vim.inspect(marks)
assert(rendered:find("Agent output", 1, true), "inline output separator missing")
assert(rendered:find("Found config", 1, true), "latest inline output missing")
status:stop()

print("progress tests passed")
