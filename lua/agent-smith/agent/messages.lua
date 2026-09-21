--- Conversation state.
---
--- A neutral record of what has been said, which a transport converts into
--- whatever its vendor expects at the wire. Keeping it neutral is the point:
--- an assistant message with text and tool calls, and a group of tool results,
--- are the two shapes every vendor has, spelled differently in each.
---
--- No compaction yet. What to drop when a conversation outgrows the window is
--- still open: see spec/open-questions.md Q8.

local Events = require("agent-smith.agent.events")

local M = {}

local Conversation = {}
Conversation.__index = Conversation

--- A new, empty conversation.
---
--- `id` identifies the conversation to the gateway, for cache routing. It is
--- optional because a conversation is usable without one; the transport simply
--- sends no session header.
---@param fields? table { system: string|nil, id: string|nil }
---@return table conversation
function M.new(fields)
  return setmetatable({
    system_prompt = (fields and fields.system) or "",
    identifier = fields and fields.id or nil,
    messages = {},
  }, Conversation)
end

--- This conversation's identity, or nil.
---@return string|nil
function Conversation:id()
  return self.identifier
end

--- The system prompt, kept separate from the message list because vendors
--- disagree about where it belongs.
---@return string
function Conversation:system()
  return self.system_prompt
end

--- Append something the user said.
function Conversation:append_user(content)
  assert(type(content) == "string" and content ~= "", "a user message needs content")
  self.messages[#self.messages + 1] = { role = "user", content = content }
end

--- Append an assistant turn.
---
--- `tool_uses` are full `tool_use` events; only the fields the wire needs are
--- kept, so a transport never has to know about event bookkeeping.
---@param parts table { text: string|nil, thinking: string|nil, tool_uses: table|nil }
function Conversation:append_assistant(parts)
  parts = parts or {}

  local message = {
    role = "assistant",
    content = parts.text or "",
    tool_uses = {},
  }
  if parts.thinking and parts.thinking ~= "" then
    message.thinking = parts.thinking
  end

  for _, tool_use in ipairs(parts.tool_uses or {}) do
    local valid, problem = Events.validate(tool_use)
    if not valid or tool_use.type ~= "tool_use" then
      error("append_assistant expects tool_use events: " .. tostring(problem), 0)
    end
    message.tool_uses[#message.tool_uses + 1] = {
      id = tool_use.id,
      name = tool_use.name,
      arguments = tool_use.arguments,
    }
  end

  self.messages[#self.messages + 1] = message
end

--- Append the results answering one assistant turn's tool calls.
---
--- Kept as one entry holding several results, because that is how the vendors
--- that group them work, and the ones that do not can split it.
---@param results table[] tool_result events
function Conversation:append_tool_results(results)
  assert(type(results) == "table" and #results > 0, "there are no results to append")

  local message = { role = "tool", results = {} }
  for _, result in ipairs(results) do
    local valid, problem = Events.validate(result)
    if not valid or result.type ~= "tool_result" then
      error("append_tool_results expects tool_result events: " .. tostring(problem), 0)
    end
    message.results[#message.results + 1] = {
      id = result.id,
      ok = result.ok,
      content = result.content,
      error = result.error,
    }
  end

  self.messages[#self.messages + 1] = message
end

--- The message list, as a new array.
---
--- A copy of the array, not of the entries: a transport reads them and must not
--- be able to reorder the conversation by mutating its own copy.
---@return table[]
function Conversation:list()
  local copy = {}
  for index, message in ipairs(self.messages) do
    copy[index] = message
  end
  return copy
end

--- How many entries the conversation holds.
function Conversation:length()
  return #self.messages
end

return M
