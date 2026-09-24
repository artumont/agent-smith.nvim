--- Token usage accounting.
---
--- The number worth watching is not how many tokens were spent but how much of
--- the prompt was a cache hit. OpenCode Go's published request estimates assume
--- roughly 50,000–90,000 cached tokens against about 1,000 fresh ones, which is
--- the shape of an agent loop and also why a cache miss is expensive rather
--- than mildly annoying: every turn re-sends the whole prefix.
---
--- Cost is deliberately not computed here. It needs per-model prices, which
--- belong to the provider catalogue (spec/providers.md). This module reports
--- what was measured, so a cost table added later has something to multiply.

local Events = require("agent-smith.agent.events")

local M = {}

--- Add one usage event to a running total.
---
--- Only the schema's token fields are summed, and only when numeric, so a
--- vendor field nobody has seen before is ignored rather than invented.
---@param total table|nil Accumulator, created when nil.
---@param event table|nil A usage event, or anything else, which is ignored.
---@return table total
function M.add(total, event)
  total = total or {}
  if type(event) ~= "table" then
    return total
  end

  for _, field in ipairs(Events.token_fields) do
    local value = event[field]
    if type(value) == "number" and value >= 0 then
      total[field] = (total[field] or 0) + value
    end
  end

  return total
end

--- The share of prompt tokens served from cache.
---
--- `input_tokens` and `cache_read_tokens` are disjoint by contract, so the
--- prompt is their sum (spec/events.md). This is why the OpenAI-shaped
--- adapters subtract the cached count from the vendor's total before emitting
--- it: with a vendor total in `input_tokens` the cached prefix would be counted
--- twice and the rate could never exceed 50%.
---
--- Returns nil rather than zero when no prompt tokens were reported: "nothing
--- measured" and "measured, and it always missed" are different problems and a
--- zero would hide the first.
---@return number|nil fraction A value from 0 to 1.
function M.hit_rate(usage)
  usage = usage or {}
  local fresh = usage.input_tokens or 0
  local cached = usage.cache_read_tokens or 0
  local prompt = fresh + cached

  if prompt == 0 then
    return nil
  end
  return cached / prompt
end

--- A one-line summary, for a notification or a statusline.
---
--- Fields that were never reported are omitted rather than shown as zero, so the
--- line says what actually happened.
---@param usage table|nil
---@param options table|nil { turns: number|nil }
---@return string
function M.render(usage, options)
  options = options or {}
  usage = usage or {}

  local parts = {}

  if usage.input_tokens then
    parts[#parts + 1] = ("%d in"):format(usage.input_tokens)
  end
  if usage.cache_read_tokens then
    parts[#parts + 1] = ("%d cached"):format(usage.cache_read_tokens)
  end
  if usage.cache_write_tokens then
    parts[#parts + 1] = ("%d cache write"):format(usage.cache_write_tokens)
  end
  if usage.output_tokens then
    parts[#parts + 1] = ("%d out"):format(usage.output_tokens)
  end
  if usage.reasoning_tokens then
    parts[#parts + 1] = ("%d reasoning"):format(usage.reasoning_tokens)
  end

  local rate = M.hit_rate(usage)
  if rate then
    parts[#parts + 1] = ("%.0f%% cache hit"):format(rate * 100)
  end

  if options.turns then
    parts[#parts + 1] = ("%d turn(s)"):format(options.turns)
  end

  if #parts == 0 then
    return "no usage reported"
  end

  return table.concat(parts, ", ")
end

return M
