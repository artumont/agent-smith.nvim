--- agent-smith/extensions/blink.lua
---
--- Blink.cmp v1 source for Agent-Smith prompt buffers.
--- Provides #skill and @project-file completion only in agent-smith-prompt.

local M = {}

local function state()
  local ok, smith = pcall(require, "agent-smith")
  if not ok then return nil end
  return smith.__get_state()
end

--- Return the active # or @ token immediately before Blink's cursor.
---@param context table blink.cmp context
---@return string|nil trigger
---@return string|nil query
---@return number|nil start_col LSP 0-based character offset
local function token_at_cursor(context)
  local prefix = context.line:sub(1, context.cursor[2])
  local trigger, query = prefix:match("([#@])([^%s]*)$")
  if not trigger then return nil end
  return trigger, query, context.cursor[2] - #query - 1
end

local function text_edit(context, start_col, new_text)
  return {
    newText = new_text,
    range = {
      start = { line = context.cursor[1] - 1, character = start_col },
      ["end"] = { line = context.cursor[1] - 1, character = context.cursor[2] },
    },
  }
end

--- Blink creates this source from sources.providers.agent_smith.
---@param _opts table Provider options
---@return table source
function M.new(_opts)
  return setmetatable({}, { __index = M })
end

--- Never offer Agent-Smith references in normal editing buffers.
---@return boolean
function M:enabled()
  return vim.bo.filetype == "agent-smith-prompt"
end

---@return string[]
function M:get_trigger_characters()
  return { "#", "@" }
end

---@param context table blink.cmp context
---@param callback fun(response: table)
function M:get_completions(context, callback)
  local trigger, _, start_col = token_at_cursor(context)
  local plugin_state = state()
  if not trigger or not plugin_state then
    callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
    return
  end

  local items = {}
  if trigger == "#" then
    for _, rule in ipairs(plugin_state.rules or {}) do
      table.insert(items, {
        label = "#" .. rule.name,
        kind = vim.lsp.protocol.CompletionItemKind.Keyword,
        detail = "Agent-Smith skill: " .. rule.path,
        textEdit = text_edit(context, start_col, "#" .. rule.name),
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      })
    end
  else
    local Files = require("agent-smith.extensions.files")
    for _, file in ipairs(Files.items()) do
      table.insert(items, {
        label = "@" .. file.label,
        kind = vim.lsp.protocol.CompletionItemKind.File,
        detail = "Agent-Smith project file: " .. file.label,
        textEdit = text_edit(context, start_col, "@" .. file.label),
        insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
      })
    end
  end

  callback({
    items = items,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  })
end

--- Register reference resolvers used when the prompt is submitted.
---@param plugin_state table Agent-Smith state
function M.init(plugin_state)
  require("agent-smith.extensions.native").init(plugin_state)
end

--- Blink owns prompt-buffer completion; no omnifunc setup required.
function M.init_for_buffer(_) end

return M
