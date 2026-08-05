---
--- AI-planned ripgrep codebase search.
---
--- Provider converts natural-language request into small regex set. Local
--- ripgrep performs all file inspection, so provider never scans project.

local Prompt = require("agent-smith.prompt")
local Qfix = require("agent-smith.ops.qfix-helpers")
local Statusline = require("agent-smith.statusline")

local M = {}

local function open_result(item)
  if vim.fn.filereadable(item.filename) ~= 1 then
    vim.notify("Search result file does not exist: " .. item.filename, vim.log.levels.WARN)
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
  pcall(vim.api.nvim_win_set_cursor, 0, {
    math.max(1, item.lnum or 1),
    math.max(0, (item.col or 1) - 1),
  })
  vim.cmd("normal! zz")
end

local function open_fuzzy_results(items)
  local backends = {
    "agent-smith.extensions.telescope",
    "agent-smith.extensions.fzf-lua",
  }
  for _, module in ipairs(backends) do
    local ok, backend = pcall(require, module)
    if ok and backend.search_results then
      local opened_ok, opened = pcall(backend.search_results, items, open_result)
      if opened_ok and opened then return true end
    end
  end
  return false
end

--- Extract bounded one-line ripgrep regexes from provider response.
---@param response string
---@return string[] patterns
function M.parse_patterns(response)
  local block = response:match("<RG_PATTERNS>%s*(.-)%s*</RG_PATTERNS>")
  if not block then return {} end

  local patterns = {}
  for pattern in block:gmatch("<PATTERN>%s*(.-)%s*</PATTERN>") do
    pattern = vim.trim(pattern)
    if pattern ~= "" and #pattern <= 500 then
      table.insert(patterns, pattern)
      if #patterns == 8 then break end
    end
  end
  return patterns
end

local function project_root()
  local path = vim.api.nvim_buf_get_name(0)
  return (path ~= "" and vim.fs.root(path, ".git")) or vim.fn.getcwd()
end

local function show_results(context, result)
  Statusline.stop(context)

  if result.code == 1 then
    return vim.notify("No search results found")
  end
  if result.code ~= 0 then
    local detail = vim.trim(result.stderr or result.stdout or "ripgrep failed")
    return vim.notify("Search failed: " .. detail, vim.log.levels.ERROR)
  end

  local items = Qfix.parse_ripgrep(result.stdout or "", context.search_root)
  if #items == 0 then return vim.notify("No search results found") end

  vim.fn.setqflist({}, "r", {
    title = "Agent-Smith Search",
    items = items,
  })
  if not open_fuzzy_results(items) then
    vim.notify("Fuzzy search picker unavailable; opening quickfix", vim.log.levels.INFO)
    vim.cmd("copen")
  end
end

local function run_ripgrep(context, patterns)
  local command = {
    "rg",
    "--vimgrep",
    "--pcre2",
    "--glob", "!.git",
    "--glob", "!node_modules",
    "--max-count", "25",
  }
  for _, pattern in ipairs(patterns) do
    table.insert(command, "-e")
    table.insert(command, pattern)
  end
  table.insert(command, ".")

  local ok, err = pcall(vim.system, command, { cwd = context.search_root, text = true }, function(result)
    vim.schedule(function() show_results(context, result) end)
  end)
  if not ok then
    Statusline.stop(context)
    vim.notify("Search failed: " .. err, vim.log.levels.ERROR)
  end
end

--- Ask provider for patterns, then search locally with ripgrep.
---@param state table Plugin state
---@param opts? table Options: { additional_prompt: string }
---@return nil
function M.run(state, opts)
  opts = opts or {}

  local function send(user)
    local context = Prompt.new(state, "search")
    local planner_dir = vim.fs.joinpath(state:tmp_dir(), "search-pattern-" .. context.xid)
    if vim.fn.mkdir(planner_dir, "p") == 0 and vim.fn.isdirectory(planner_dir) == 0 then
      return vim.notify("Search failed: unable to create pattern workspace", vim.log.levels.ERROR)
    end
    context.cwd = planner_dir
    context.search_root = project_root()
    context.file_reference = "."
    context.skip_sandbox = true
    Statusline.start(context, "Planning Search")
    context:start(user, {
      on_complete = function(status, response)
        vim.fn.delete(planner_dir, "rf")
        if status ~= "success" then
          Statusline.stop(context)
          return vim.notify("Search failed: " .. status, vim.log.levels.ERROR)
        end

        local patterns = M.parse_patterns(response)
        if #patterns == 0 then
          Statusline.stop(context)
          return vim.notify("Search failed: provider returned no ripgrep patterns", vim.log.levels.ERROR)
        end

        Statusline.start(context, "Searching Codebase")
        run_ripgrep(context, patterns)
      end,
    })
  end

  if opts.additional_prompt then
    send(opts.additional_prompt)
  else
    require("agent-smith.window.prompt-window").capture("Search", {
      cb = function(ok, text)
        if ok and vim.trim(text) ~= "" then send(text) end
      end,
    })
  end
end

return M
