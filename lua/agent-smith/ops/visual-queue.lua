--- Per-buffer FIFO queue for visual edit requests.
---
--- Requests against one buffer must run serially: each response can change line
--- positions used by later selections. Different buffers remain concurrent.

local queues = {}

local M = {}

---@param buffer number
---@param job fun(done: fun())
function M.enqueue(buffer, job)
  local queue = queues[buffer]
  if not queue then
    queue = { running = false, jobs = {} }
    queues[buffer] = queue
  end

  table.insert(queue.jobs, job)
  if queue.running then return end

  local function run_next()
    local next_job = table.remove(queue.jobs, 1)
    if not next_job then
      queue.running = false
      queues[buffer] = nil
      return
    end

    queue.running = true
    local completed = false
    next_job(function()
      if completed then return end
      completed = true
      run_next()
    end)
  end

  run_next()
end

return M
