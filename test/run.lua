--- Headless test runner.
---
---   nvim --headless -l test/run.lua [path-pattern]
---   make test                       (equivalent)
---
--- Spec files live in test/spec/, are discovered recursively, and are expected
--- to match *_spec.lua. Each one returns a function taking the harness, which
--- registers tests:
---
---   return function(t)
---     t.it("does a thing", function() ... end)
---   end
---
--- Exits non-zero when anything fails, so it is usable as a CI step.

local script = debug.getinfo(1, "S").source:sub(2)
local test_dir = vim.fs.dirname(script)
local root = vim.fs.dirname(test_dir)

-- The plugin's own modules are resolved through the runtimepath.
vim.opt.runtimepath:prepend(root)

-- The harness is a sibling of this script, outside lua/, so it needs an
-- explicit package.path entry.
package.path = test_dir .. "/?.lua;" .. package.path

local harness = require("harness")

-- An empty argument (make passes "" for an unset PATTERN) means "no filter".
local raw_pattern = _G.arg and _G.arg[1] or nil
local pattern = (raw_pattern ~= "" and raw_pattern) or nil

local function spec_files()
  -- vim.fs.find with a function predicate does not enumerate reliably here.
  -- vim.fn.glob with ** recurses and returns every match.
  local found = vim.fn.glob(vim.fs.joinpath(test_dir, "spec", "**", "*_spec.lua"), false, true)
  table.sort(found)
  return found
end

--- Load one spec file and let it register its tests.
---@return string|nil error Nil when the file loaded and registered cleanly.
local function load_spec(file)
  local chunk, load_err = loadfile(file)
  if not chunk then
    return load_err
  end

  local ok, register = pcall(chunk)
  if not ok then
    return register
  end

  if type(register) ~= "function" then
    return "spec file must return a function taking the harness, returned " .. type(register)
  end

  local registered, register_err = pcall(register, harness)
  if not registered then
    return register_err
  end

  return nil
end

local files = {}
for _, file in ipairs(spec_files()) do
  if not pattern or file:match(pattern) then
    files[#files + 1] = file
  end
end

print(("running %d spec file(s)"):format(#files))

-- A run that silently tests nothing looks identical to a passing run. Fail loudly.
if #files == 0 then
  print(pattern and ("no spec files match " .. pattern) or "no spec files found")
  vim.cmd("cquit 1")
end

local failed_to_load = {}

for _, file in ipairs(files) do
  local err = load_spec(file)
  if err then
    failed_to_load[#failed_to_load + 1] = file
    print("FAIL  " .. file)
    print("        " .. tostring(err):gsub("\n", "\n        "))
  end
end

print("")
local result = harness.run()
print("")
print(("%d passed, %d failed, %d total"):format(result.passed, result.failed, result.total))

if result.failed > 0 or #failed_to_load > 0 then
  vim.cmd("cquit 1")
end
