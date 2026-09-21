--- Minimal test harness. No external dependency.
---
--- A spec file returns a function. The runner calls it with this module, and
--- the file registers tests through `describe` and `it`:
---
---   return function(t)
---     t.describe("config", function()
---       t.it("defaults are valid", function()
---         t.eq(Config.validate(Config.defaults), true)
---       end)
---     end)
---   end
---
--- The file exists because a dependency is not justified until there is more to
--- test than this can express.

local M = {}

local tests = {}
local group = nil

local function format(value)
  if type(value) == "string" then
    return string.format("%q", value)
  end
  if type(value) == "table" then
    return vim.inspect(value)
  end
  return tostring(value)
end

local function fail(message)
  error(message, 0)
end

--- Group the tests registered inside `fn`.
function M.describe(name, fn)
  local previous = group
  group = previous and (previous .. " › " .. name) or name
  fn()
  group = previous
end

--- Register a test.
function M.it(name, fn)
  tests[#tests + 1] = { group = group, name = name, fn = fn }
end

--- Assert that `value` is truthy.
function M.ok(value, message)
  if not value then
    fail(message or ("expected a truthy value, got " .. format(value)))
  end
end

--- Assert that `value` is falsy.
function M.not_ok(value, message)
  if value then
    fail(message or ("expected a falsy value, got " .. format(value)))
  end
end

--- Assert that `actual` deep-equals `expected`.
function M.eq(actual, expected, message)
  if not vim.deep_equal(actual, expected) then
    local prefix = message and (message .. ": ") or ""
    fail(prefix .. "expected " .. format(expected) .. ", got " .. format(actual))
  end
end

--- Assert that `value` is a string matching the Lua pattern `pattern`.
function M.matches(value, pattern, message)
  if type(value) ~= "string" or not value:match(pattern) then
    local prefix = message and (message .. ": ") or ""
    fail(prefix .. "expected " .. format(value) .. " to match " .. format(pattern))
  end
end

--- Assert that calling `fn` raises. Returns the error value.
---
---@param fn function
---@param pattern string|nil Lua pattern the error must match.
function M.raises(fn, pattern, message)
  local ok, err = pcall(fn)
  local prefix = message and (message .. ": ") or ""
  if ok then
    fail(prefix .. "expected an error, but the call succeeded")
  end
  if pattern and not tostring(err):match(pattern) then
    fail(prefix .. "expected an error matching " .. format(pattern) .. ", got " .. format(tostring(err)))
  end
  return err
end

--- Run every registered test.
---
--- Tests run in registration order, which is spec file order followed by
--- declaration order. A failing test does not stop the run.
---@return table result { total, passed, failed, failures }
function M.run()
  local result = { total = #tests, passed = 0, failed = 0, failures = {} }

  for _, test in ipairs(tests) do
    local label = test.group and (test.group .. " › " .. test.name) or test.name
    local ok, err = pcall(test.fn)
    if ok then
      result.passed = result.passed + 1
      print("ok    " .. label)
    else
      result.failed = result.failed + 1
      result.failures[#result.failures + 1] = label
      print("FAIL  " .. label)
      print("        " .. tostring(err):gsub("\n", "\n        "))
    end
  end

  return result
end

--- Pump the event loop until `predicate` returns true or the timeout expires.
---
--- Required by tests of asynchronous tools: `vim.wait` runs the loop, so a
--- `vim.system` callback scheduled during dispatch gets a chance to fire.
---@return boolean settled
function M.settle(predicate, timeout_ms)
  return vim.wait(timeout_ms or 5000, predicate, 5)
end

--- Forget every registered test. Used by the runner between spec files when a
--- filtered run needs a clean registry.
function M.reset()
  tests = {}
  group = nil
end

return M
