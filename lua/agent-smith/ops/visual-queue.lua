--- Per-buffer FIFO queue for visual edit requests.
---
--- Requests against one buffer must run serially: each response can change line
--- positions used by later selections. Different buffers remain concurrent.

local queues = {}

local M = {}

---@param buffer number
---@param job fun(done: fun())
---@return fun(): boolean cancel Removes job when still queued
function M.enqueue(buffer, job)
  local queue = queues[buffer]
  if not queue then
    queue = { running = false, jobs = {} }
    queues[buffer] = queue
  end

  local entry = { job = job }
  table.insert(queue.jobs, entry)

  local function cancel()
    for index, candidate in ipairs(queue.jobs) do
      if candidate == entry then
        table.remove(queue.jobs, index)
        if not queue.running and #queue.jobs == 0 then queues[buffer] = nil end
        return true
      end
    end
    return false
  end

  if queue.running then return cancel end

  local function run_next()
    local next_entry = table.remove(queue.jobs, 1)
    if not next_entry then
      queue.running = false
      queues[buffer] = nil
      return
    end

    queue.running = true
    local completed = false
    next_entry.job(function()
      if completed then return end
      completed = true
      run_next()
    end)
  end

  run_next()
  return cancel
end

return M
