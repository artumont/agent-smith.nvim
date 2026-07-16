--- agent-smith/ops/vibe-session.lua
---
--- Temporary project sandbox used by Vibe's plan and execution phases.
--- Original files are copied, never moved. Only approved diffs may later be
--- applied to the original project.

local Utils = require("agent-smith.utils")

local M = {}

local function join(root, relative)
  return vim.fs.joinpath(root, relative)
end

local function normalize_relative(path)
  path = vim.trim(path):gsub("\\", "/"):gsub("^%./", "")
  if path == "" or path:sub(1, 1) == "/" or path:match("^%a:/") then return nil end
  path = vim.fs.normalize(path)
  if path == "." or path == ".." or path:sub(1, 3) == "../" then return nil end
  return path
end

local function list_recursive(root, current, result)
  current = current or ""
  result = result or {}
  local dir = current == "" and root or join(root, current)
  local ok, iterator = pcall(vim.fs.dir, dir)
  if not ok or not iterator then return result end
  for name, kind in iterator do
    local relative = current == "" and name or (current .. "/" .. name)
    if name ~= ".git" and name ~= "node_modules" then
      if kind == "directory" then
        list_recursive(root, relative, result)
      elseif kind == "file" then
        table.insert(result, relative)
      end
    end
  end
  return result
end

local function project_files(root)
  if vim.uv.fs_stat(join(root, ".git")) then
    local files = vim.fn.systemlist({
      "git", "-C", root, "ls-files", "--cached", "--others", "--exclude-standard",
    })
    if vim.v.shell_error == 0 then return files end
  end
  return list_recursive(root)
end

local function copy_file(source, destination)
  vim.fn.mkdir(vim.fs.dirname(destination), "p")
  local ok, error_message = vim.uv.fs_copyfile(source, destination)
  if not ok then error("Unable to copy " .. source .. ": " .. tostring(error_message)) end
end

local function relative_to(path, root)
  path, root = vim.fs.normalize(path), vim.fs.normalize(root)
  local prefix = root:sub(-1) == "/" and root or (root .. "/")
  if path:sub(1, #prefix) ~= prefix then return nil end
  return path:sub(#prefix + 1)
end

--- Copy current project state into a unique temporary directory.
---@param current_file string Current original buffer path
---@param temp_root? string Configured provider-approved temporary root
---@return table session
function M.create(current_file, temp_root)
  local project_root = vim.fs.root(current_file ~= "" and current_file or vim.fn.getcwd(), ".git")
    or vim.fn.getcwd()
  temp_root = temp_root or (vim.fn.tempname():match("^(.*)/[^/]+$") or "/tmp")
  temp_root = vim.fn.fnamemodify(temp_root, ":p"):gsub("/$", "")
  local session_root = string.format(
    "%s/sessions/vibe-%d-%d",
    temp_root,
    os.time(),
    vim.uv.hrtime() % 1000000000
  )
  vim.fn.mkdir(session_root, "p")

  local snapshot = {}
  for _, relative in ipairs(project_files(project_root)) do
    relative = normalize_relative(relative)
    if relative then
      local source = join(project_root, relative)
      local stat = vim.uv.fs_stat(source)
      if stat and stat.type == "file" then
        copy_file(source, join(session_root, relative))
        snapshot[relative] = Utils.read_file(source)
      end
    end
  end

  -- Give agent harnesses an unambiguous project root. This repository is
  -- isolated metadata inside the sandbox and has no link to the original Git
  -- directory or worktree.
  vim.fn.system({ "git", "-C", session_root, "init", "--quiet" })

  local current_relative = relative_to(current_file, project_root)
  return {
    root = session_root,
    project_root = project_root,
    source_current_file = current_file,
    temp_root = temp_root,
    snapshot = snapshot,
    current_relative = current_relative,
    current_file = current_relative and join(session_root, current_relative)
      or join(session_root, ".agent-smith-context"),
  }
end

function M.cleanup(session)
  if session and session.root then vim.fn.delete(session.root, "rf") end
end

--- Discard any plan-phase sandbox mutations and copy originals again.
---@param session table
---@return table fresh_session
function M.recreate(session)
  local fresh = M.create(session.source_current_file, session.temp_root)
  M.cleanup(session)
  return fresh
end

--- Parse and validate model-requested edit scope.
---@param response string
---@return table|nil plan { raw, files, steps }
---@return string|nil error_message
function M.parse_plan(response)
  local raw = response:match("<PLAN>%s*(.-)%s*</PLAN>")
  if not raw then return nil, "Model did not return a <PLAN> block" end

  local files = {}
  local seen = {}
  local file_block = raw:match("<EDIT_FILES>%s*(.-)%s*</EDIT_FILES>") or ""
  for candidate in file_block:gmatch("<FILE>%s*(.-)%s*</FILE>") do
    local relative = normalize_relative(candidate)
    if not relative then return nil, "Unsafe or invalid planned path: " .. candidate end
    if not seen[relative] then
      seen[relative] = true
      table.insert(files, relative)
    end
  end
  local steps = vim.trim(raw:match("<STEPS>%s*(.-)%s*</STEPS>") or "")
  if steps == "" then return nil, "Plan did not include implementation steps" end
  return { raw = raw, files = files, steps = steps }, nil
end

local function current_files(session)
  local map = {}
  for _, relative in ipairs(list_recursive(session.root)) do
    map[relative] = Utils.read_file(join(session.root, relative))
  end
  return map
end

--- Build original-repository proposals only for plan-approved paths.
---@param session table
---@param approved_files string[]
---@return table[] proposals
---@return string[] unauthorized Paths changed outside approved scope
function M.collect_changes(session, approved_files)
  local after = current_files(session)
  local approved = {}
  for _, relative in ipairs(approved_files) do approved[relative] = true end

  local proposals = {}
  for _, relative in ipairs(approved_files) do
    local before, updated = session.snapshot[relative], after[relative]
    if before ~= updated then
      table.insert(proposals, {
        path = join(session.project_root, relative),
        content = updated or "",
        snapshot = before,
        delete = before ~= nil and updated == nil,
      })
    end
  end

  local unauthorized = {}
  local all = {}
  for relative in pairs(session.snapshot) do all[relative] = true end
  for relative in pairs(after) do all[relative] = true end
  for relative in pairs(all) do
    if not approved[relative] and session.snapshot[relative] ~= after[relative] then
      table.insert(unauthorized, relative)
    end
  end
  table.sort(unauthorized)
  return proposals, unauthorized
end

--- Convert sandbox absolute locations back to original project locations.
function M.remap_response(session, response)
  local escaped = session.root:gsub("([^%w])", "%%%1")
  return response:gsub(escaped, session.project_root)
end

return M
