local M = {}

local source = debug.getinfo(1, "S").source:gsub("^@", "")
M.root = vim.fs.dirname(vim.fs.dirname(assert(vim.uv.fs_realpath(source))))
vim.opt.runtimepath:append(M.root)

function M.assert_equal(actual, expected, message)
  assert(vim.deep_equal(actual, expected), string.format(
    "%s\nexpected: %s\nactual: %s",
    message or "values differ",
    vim.inspect(expected),
    vim.inspect(actual)
  ))
end

function M.assert_match(text, pattern, message)
  assert(tostring(text):find(pattern, 1, true), message or ("missing: " .. pattern))
end

function M.temp_dir(prefix)
  local path = vim.fn.tempname() .. "-" .. (prefix or "agent-smith")
  vim.fn.mkdir(path, "p")
  return path
end

function M.write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(vim.fn.writefile(vim.split(text, "\n", { plain = true }), path) == 0)
end

function M.read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

function M.project(files)
  local root = M.temp_dir("project")
  assert(vim.fn.system({ "git", "-C", root, "init", "--quiet" }) == "")
  for relative, text in pairs(files) do M.write(vim.fs.joinpath(root, relative), text) end
  assert(vim.fn.system({ "git", "-C", root, "add", "." }) == "")
  return root
end

function M.edit(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

function M.cleanup(...)
  for _, path in ipairs({ ... }) do
    if path then vim.fn.delete(path, "rf") end
  end
end

function M.fake_provider(handler)
  local provider = {}
  function provider:_get_default_model() return "test-model" end
  function provider:_get_provider_name() return "Test Provider" end
  function provider:make_request(query, context, observer)
    observer.on_start()
    return handler(query, context, observer) or { kill = function() end }
  end
  return provider
end

function M.close_floats()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
  end
end

return M
