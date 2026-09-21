--- Incremental Server-Sent Events parsing.
---
--- Fed arbitrary chunks, yields whole events. The framing rules that actually
--- bite in practice:
---
---   - A chunk splits anywhere, including mid-line and inside the blank-line
---     delimiter, so a buffer has to survive between feeds.
---   - Lines end with CRLF, LF or CR. Both CRLF and a lone CR are normalised.
---   - Several `data:` lines in one event are joined with newlines.
---   - A line beginning with `:` is a comment; vendors use it as keep-alive.
---   - An event ends at a blank line, which may not have arrived yet.

local M = {}

local Parser = {}
Parser.__index = Parser

--- Parse one complete block into an event, or nil when it carries no data.
local function parse_block(block)
  local name = nil
  local data = {}

  for line in block:gmatch("[^\n]+") do
    if line:sub(1, 1) ~= ":" then
      local field, value = line:match("^([^:]+):(.*)$")
      if field then
        -- One optional space after the colon is framing, not content.
        if value:sub(1, 1) == " " then
          value = value:sub(2)
        end
        if field == "event" then
          name = value
        elseif field == "data" then
          data[#data + 1] = value
        end
      end
    end
  end

  if #data == 0 then
    return nil
  end

  return { event = name, data = table.concat(data, "\n") }
end

--- A new parser.
---@return table parser
function M.new()
  return setmetatable({ buffer = "" }, Parser)
end

--- Feed a chunk and take back every event it completed.
---@param chunk string
---@return table[] events Each is { event = string|nil, data = string }.
function Parser:feed(chunk)
  self.buffer = (self.buffer .. chunk):gsub("\r\n", "\n"):gsub("\r", "\n")

  local events = {}
  while true do
    local boundary = self.buffer:find("\n\n", 1, true)
    if not boundary then
      break
    end
    local block = self.buffer:sub(1, boundary - 1)
    self.buffer = self.buffer:sub(boundary + 2)

    local parsed = parse_block(block)
    if parsed then
      events[#events + 1] = parsed
    end
  end

  return events
end

--- Whatever has arrived that is not yet a complete event.
---
--- Worth showing in an error when a stream dies mid-frame, and worth checking
--- when a non-SSE response body arrives: a JSON error object has no blank line
--- in it, so it sits here forever otherwise.
---@return string
function Parser:pending()
  return self.buffer
end

return M
