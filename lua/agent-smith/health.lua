--- :checkhealth agent-smith
---
--- Required and optional dependencies mirror the table in spec/architecture.md.

local Config = require("agent-smith.config")

local M = {}

local function executable(name)
  return vim.fn.executable(name) == 1
end

---@return table config The resolved configuration, or the defaults when the
--- plugin has not been set up. Health must work before setup() so that a broken
--- configuration is diagnosable.
local function current_config()
  local ok, smith = pcall(require, "agent-smith")
  if ok and smith.config then
    return smith.config
  end
  return Config.defaults
end

function M.check()
  vim.health.start("agent-smith")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10 or newer is required", { "vim.json and vim.system are unavailable" })
  end

  if vim.uv.os_uname().sysname == "Linux" then
    vim.health.ok("platform: Linux")
  else
    vim.health.warn("platform is not Linux; the bash tool is disabled", {
      "v1 targets Linux only: spec/decisions/0009-linux-only-v1.md",
    })
  end

  if executable("curl") then
    vim.health.ok("curl found (transport)")
  else
    vim.health.error("curl not found", { "Install curl; it carries the transport" })
  end

  if executable("git") then
    vim.health.ok("git found (sandbox clone)")
  else
    vim.health.warn("git not found; vibe mode is unavailable", { "Install git" })
  end

  if executable("bwrap") then
    vim.health.ok("bwrap found (process sandbox)")
  else
    vim.health.warn("bwrap not found; the bash tool is disabled", { "Install bubblewrap" })
  end

  if executable("rg") then
    vim.health.ok("ripgrep found (grep, glob)")
  else
    vim.health.info("ripgrep not found; grep falls back to slower built-ins")
  end

  local config = current_config()
  local valid, err = Config.validate(config)
  if valid then
    vim.health.ok("configuration valid")
  else
    vim.health.error("invalid configuration: " .. tostring(err))
  end

  if valid then
    local root = config.sandbox.root
    vim.fn.mkdir(root, "p")
    if vim.fn.isdirectory(root) == 1 then
      vim.health.ok("sandbox root writable: " .. root)
    else
      vim.health.error("sandbox root is not writable: " .. root)
    end

    local cwd = vim.uv.cwd() or ""
    if cwd ~= "" and vim.startswith(vim.fs.normalize(root), vim.fs.normalize(cwd) .. "/") then
      vim.health.warn("sandbox root is inside the current project", {
        "The sandbox exists to be outside the project: spec/decisions/0006-sandbox-isolated-clone.md",
      })
    end
  end
end

return M
