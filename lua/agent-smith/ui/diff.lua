--- Presenting a diff for review.
---
--- The last checkpoint before the real repository changes, so the decision has to
--- be made against the actual patch rather than a summary of it.
---
--- Three pieces, deliberately separate:
---
---   `files` and `summary` parse the patch, and `highlight_for` classifies a line.
---   All pure, so what the reader will see is testable without a window.
---   `decorate` turns that classification into highlights on a buffer.
---   `review` shows it and asks, which needs a window and so is not.
---
--- **Colour is set explicitly rather than left to `filetype=diff`.** The filetype's
--- syntax only takes effect when syntax highlighting is on, which is not something
--- this module gets to assume, and a diff rendered as undifferentiated text is
--- worse than useless: the reader ends up parsing every line's first character by
--- eye to work out what it is. Setting it here also means the colours are ours to
--- name, so they can be themed.

local Decide = require("agent-smith.ui.decide")

local M = {}

M.NAMESPACE = vim.api.nvim_create_namespace("agent-smith-diff")

--- The files a patch touches, in the order they appear.
---
--- Reads `diff --git a/x b/x` headers. Returns the `b/` side, which is the
--- destination path and so the one that matches what is on disk after applying.
---@param patch string
---@return string[]
function M.files(patch)
  local paths = {}
  if type(patch) ~= "string" then
    return paths
  end

  for line in patch:gmatch("[^\n]+") do
    local path = line:match("^diff %-%-git a/[^\t]+ b/(.+)$")
    if path then
      paths[#paths + 1] = path
    end
  end

  return paths
end

--- A one-line count, e.g. "3 files changed".
---@param patch string
---@return string
function M.summary(patch)
  local count = #M.files(patch)
  if count == 0 then
    return "no files changed"
  end
  if count == 1 then
    return "1 file changed"
  end
  return ("%d files changed"):format(count)
end

--- The highlight for one line of a unified diff, or nil for context.
---
--- Order matters. `+++` and `---` are the two file headers and start with the same
--- characters as an added and a removed line, so they are tested first — otherwise
--- every patch would open with one bogus green line and one bogus red one.
---@param line string
---@return string|nil highlight
function M.highlight_for(line)
  if type(line) ~= "string" then
    return nil
  end

  if line:match("^+++") or line:match("^%-%-%-") then
    return "AgentSmithDiffMeta"
  end
  if line:match("^%+") then
    return "AgentSmithDiffAdded"
  end
  if line:match("^%-") then
    return "AgentSmithDiffRemoved"
  end
  if line:match("^@@") then
    return "AgentSmithDiffHunk"
  end
  -- Headers and metadata: worth showing, not worth colouring like content.
  if
    line:match("^diff %-%-git")
    or line:match("^index ")
    or line:match("^new file")
    or line:match("^deleted file")
    or line:match("^similarity index")
    or line:match("^rename ")
    or line:match("^old mode")
    or line:match("^new mode")
    or line:match("^Binary files")
  then
    return "AgentSmithDiffMeta"
  end

  return nil
end

--- Colour a diff body, whole line at a time.
---
--- `default = true` on every group so a colorscheme that defines them wins.
---@param buffer integer
---@return integer buffer
function M.decorate(buffer)
  vim.api.nvim_set_hl(0, "AgentSmithDiffAdded", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithDiffRemoved", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithDiffHunk", { link = "DiffText", default = true })
  vim.api.nvim_set_hl(0, "AgentSmithDiffMeta", { link = "Comment", default = true })

  local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  for index, line in ipairs(lines) do
    local group = M.highlight_for(line)
    if group then
      pcall(vim.api.nvim_buf_add_highlight, buffer, M.NAMESPACE, group, index - 1, 0, -1)
    end
  end

  return buffer
end

--- What the window shows: any refusals, then the patch.
---
--- Refusals go in here rather than only in the closing message. Approving a diff
--- while believing the agent did everything in the plan would be approving
--- something that is not what happened, so the discrepancy belongs at the moment
--- of the decision.
---@param patch string
---@param fields table|nil { refusals: table[]|nil }
---@return string[]
function M.body(patch, fields)
  fields = fields or {}
  local lines = {}

  local refusals = fields.refusals or {}
  if #refusals > 0 then
    lines[#lines + 1] = ("%d write(s) were refused as out of plan, and are not in this diff:"):format(#refusals)
    for index, refusal in ipairs(refusals) do
      if index > 5 then
        lines[#lines + 1] = ("  ... and %d more"):format(#refusals - 5)
        break
      end
      lines[#lines + 1] = ("  %s"):format(refusal.path or "?")
    end
    lines[#lines + 1] = ""
  end

  for _, line in ipairs(vim.split(patch, "\n", { plain = true })) do
    lines[#lines + 1] = line
  end

  return lines
end

--- Show a patch and ask whether to apply it.
---
--- Asynchronous: the answer arrives through `decide`, because the question is a
--- window rather than a blocking prompt.
---@param patch string
---@param fields table|nil { root: string|nil, refusals: table[]|nil }
---@param decide fun(accepted: boolean)
---@return table handle { cancel = fun() }
function M.review(patch, fields, decide)
  assert(type(decide) == "function", "the diff review needs a decide callback")
  fields = fields or {}

  return Decide.ask({
    title = (" agent-smith diff (%s) "):format(M.summary(patch)),
    lines = M.body(patch, fields),
    filetype = "diff",
    decorate = M.decorate,
    max_height = vim.o.lines - 12,
    on_decision = decide,
  })
end

return M
