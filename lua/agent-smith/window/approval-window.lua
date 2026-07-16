--- agent-smith/window/approval-window.lua
---
--- Neogit-inspired review panel for one proposed file change. Default view is
--- a unified diff with unchanged context. Tab toggles full proposed content.

local Window = require("agent-smith.window")

local M = {}
local namespace = vim.api.nvim_create_namespace("agent-smith.change-proposal")

local function ui_size()
  local ui = vim.api.nvim_list_uis()[1] or { width = 120, height = 40 }
  return math.floor(ui.width * 0.9), math.floor(ui.height * 0.78)
end

local function highlight_literal(buf, row, line, literal, group)
  local start_col = line:find(literal, 1, true)
  if start_col then
    vim.api.nvim_buf_add_highlight(buf, namespace, group, row, start_col - 1, start_col - 1 + #literal)
  end
end

local function diff_lines(change)
  local old = change.snapshot or ""
  local ok, diff = pcall(vim.diff, old, change.content, {
    result_type = "unified",
    ctxlen = 3,
    algorithm = "histogram",
  })
  if not ok then return nil end

  local from = change.snapshot == nil and "/dev/null" or change.path
  local lines = { "--- " .. from, "+++ " .. change.path }
  if diff == "" then
    table.insert(lines, "No textual changes proposed.")
  else
    vim.list_extend(lines, vim.split(vim.trim(diff), "\n", { plain = true }))
  end
  return lines
end

local function content_lines(change)
  return vim.split(change.content, "\n", { plain = true })
end

local function apply_highlights(buf, lines, first_content_row, is_new, mode)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 0, 0, -1)
  for _, key in ipairs({ "<CR>", "Tab", "q", "Q", "Esc" }) do
    highlight_literal(buf, 0, lines[1], key, "Special")
  end
  local action = is_new and "Create new file" or "Replace existing file"
  highlight_literal(buf, 2, lines[3], action, is_new and "String" or "WarningMsg")
  vim.api.nvim_buf_add_highlight(buf, namespace, "Directory", 2, #action + 2, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 4, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 5, 0, -1)

  for row = first_content_row, #lines - 1 do
    local line = lines[row + 1]
    if mode == "diff" then
      if line:sub(1, 3) == "+++" or line:sub(1, 3) == "---" then
        vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", row, 0, -1)
      elseif line:sub(1, 2) == "@@" then
        vim.api.nvim_buf_add_highlight(buf, namespace, "DiffText", row, 0, -1)
      elseif line:sub(1, 1) == "+" then
        vim.api.nvim_buf_add_highlight(buf, namespace, "DiffAdd", row, 0, -1)
      elseif line:sub(1, 1) == "-" then
        vim.api.nvim_buf_add_highlight(buf, namespace, "DiffDelete", row, 0, -1)
      end
    elseif is_new then
      vim.api.nvim_buf_add_highlight(buf, namespace, "DiffAdd", row, 0, -1)
    end
  end
end

--- Show a file change proposal for review.
---@param change table { path: string, content: string, snapshot?: string }
---@param cb function Callback: "approve" | "reject" | "reject_all"
function M.approve(change, cb)
  local is_new = change.snapshot == nil
  local action = is_new and "Create new file" or "Replace existing file"
  local mode = "diff"
  local width, height = ui_size()
  local win, buf = Window.create("", {}, {
    enter = true,
    width = width,
    height = height,
    border = "single",
    title = false,
  })
  vim.bo[buf].modifiable = true
  vim.bo[buf].bufhidden = "wipe"
  vim.wo[win].cursorline = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:Comment"

  local function render()
    local hint = "Hint:  <CR> apply  |  Tab toggle full content  |  q skip  |  Q skip all  |  Esc close"
    local body = mode == "diff" and diff_lines(change) or content_lines(change)
    if not body then
      mode = "full"
      body = content_lines(change)
    end
    local section = mode == "diff"
      and "Diff preview (context lines are unchanged)"
      or "Proposed complete file content"
    local lines = {
      hint,
      "",
      action .. ": " .. change.path,
      "",
      section,
      "────────────────────────────────────────────────────────────────────────",
      "",
    }
    vim.list_extend(lines, body)

    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    apply_highlights(buf, lines, 7, is_new, mode)
    vim.api.nvim_win_set_cursor(win, { math.min(8, #lines), 0 })
  end

  render()

  vim.keymap.set("n", "<Tab>", function()
    mode = mode == "diff" and "full" or "diff"
    render()
  end, { buffer = buf, nowait = true, desc = "Toggle diff and full proposal" })

  vim.keymap.set("n", "<CR>", function()
    Window.close(win)
    cb("approve")
  end, { buffer = buf, nowait = true, desc = "Apply proposed change" })

  local function reject()
    Window.close(win)
    cb("reject")
  end
  vim.keymap.set("n", "q", reject, { buffer = buf, nowait = true, desc = "Skip proposed change" })
  vim.keymap.set("n", "<Esc>", reject, { buffer = buf, nowait = true, desc = "Skip proposed change" })

  vim.keymap.set("n", "Q", function()
    Window.close(win)
    cb("reject_all")
  end, { buffer = buf, nowait = true, desc = "Skip all remaining changes" })
end

return M
