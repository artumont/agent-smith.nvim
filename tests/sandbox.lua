local test_file = debug.getinfo(1, "S").source:gsub("^@", "")
local repo_root = vim.fs.dirname(vim.fs.dirname(assert(vim.uv.fs_realpath(test_file))))
vim.opt.runtimepath:append(repo_root)

if vim.fn.has("win32") == 1 then
  print("sandbox tests skipped on Windows")
  return
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  assert(vim.fn.writefile({ text }, path) == 0)
end

local function read(path)
  return table.concat(vim.fn.readfile(path), "\n")
end

local project = vim.fn.tempname() .. "%2repo"
local temp_root = vim.fn.tempname()
vim.fn.mkdir(project, "p")
vim.fn.mkdir(temp_root, "p")
vim.fn.system({ "git", "-C", project, "init", "--quiet" })
local original = vim.fs.joinpath(project, "main.lua")
write(original, "return 'original'")
vim.fn.system({ "git", "-C", project, "add", "main.lua" })
vim.cmd("edit " .. vim.fn.fnameescape(original))

local observed = { tracked = 0, completed = 0 }
local provider_sandbox
local provider = {}
function provider:make_request(_, context, observer)
  observer.on_start()
  assert(context.cwd ~= project, "provider cwd was original project")
  assert(read(vim.fs.joinpath(context.cwd, "main.lua")) == "return 'original'")
  write(vim.fs.joinpath(context.cwd, "main.lua"), "return 'provider mutation'")
  provider_sandbox = context.cwd
  observer.on_complete("success", provider_sandbox .. "/main.lua:1:1,1,match")
end

local state = {
  model = "",
  md_files = {},
  tracking = {
    track = function() observed.tracked = observed.tracked + 1 end,
    complete = function() observed.completed = observed.completed + 1 end,
  },
}
function state:tmp_dir() return temp_root end
function state:active_provider() return provider end

local Prompt = require("agent-smith.prompt")
local prompt = Prompt.new(state, "search")
prompt.cwd = project
prompt:start("find main", {
  on_complete = function(status, response)
    assert(status == "success")
    assert(response:find(project .. "/main.lua", 1, true), "sandbox path was not remapped")
  end,
})
assert(observed.tracked == 1 and observed.completed == 1)
assert(prompt.cwd == project, "original cwd was not restored")
assert(read(original) == "return 'original'", "request sandbox mutation escaped")
assert(vim.uv.fs_stat(provider_sandbox) == nil, "request sandbox was not cleaned")

local Session = require("agent-smith.ops.vibe-session")
local session = Session.create(original, temp_root, { prefix = "hard-test", snapshot = false })
assert(bit.band(assert(vim.uv.fs_stat(session.root)).mode, 511) == 448, "sandbox is not mode 0700")

local alias = vim.fn.tempname()
local inside = vim.fs.joinpath(project, "inside-tmp")
vim.fn.mkdir(inside, "p")
assert(vim.uv.fs_symlink(inside, alias))
local escaped, escape_error = pcall(Session.create, original, alias, {
  prefix = "escape", snapshot = false,
})
assert(
  not escaped and tostring(escape_error):find("outside", 1, true),
  "symlinked tmp_dir escaped project guard"
)
vim.fn.delete(alias)

local Base = require("agent-smith.providers").BaseProvider
if vim.fn.executable("bwrap") == 1 then
  local hard_provider = setmetatable({}, { __index = Base })
  function hard_provider:_get_provider_name() return "sandbox-test" end
  function hard_provider:_build_command()
    local source = vim.fn.shellescape(original)
    return {
      "sh", "-c",
      "if printf escaped > " .. source .. "; then exit 90; fi; "
        .. "printf sandbox > main.lua; printf ok",
    }
  end

  local done = false
  local result_status, result_text
  local context = {
    cwd = session.root,
    tmp_file = vim.fs.joinpath(session.root, ".response"),
    model = "",
    _sandbox = session,
    _state = state,
    is_cancelled = function() return false end,
    _set_process = function(self, proc) self.proc = proc end,
  }
  hard_provider:make_request("test", context, {
    on_start = function() end,
    on_stdout = function() end,
    on_stderr = function() end,
    on_complete = function(status, text)
      result_status, result_text, done = status, text, true
    end,
  })
  assert(vim.wait(5000, function() return done end), "hard sandbox request timed out")
  assert(result_status == "success", result_text)
  assert(result_text == "ok", "unexpected hard sandbox response: " .. tostring(result_text))
  assert(read(original) == "return 'original'", "Bubblewrap allowed original write")
  assert(read(vim.fs.joinpath(session.root, "main.lua")) == "sandbox", "sandbox write failed")
end
Session.cleanup(session)

if vim.fn.executable("setsid") == 1 then
  local plan_provider = setmetatable({}, { __index = Base })
  function plan_provider:_get_provider_name() return "plan-test" end
  function plan_provider:_build_command()
    return {
      "sh", "-c",
      "printf '<PLAN><EDIT_FILES></EDIT_FILES><STEPS>noop</STEPS></PLAN>'; sleep 10",
    }
  end
  local plan_done = false
  local plan_status, plan_response
  local plan_started = vim.uv.hrtime()
  local plan_context = {
    cwd = temp_root,
    tmp_file = vim.fs.joinpath(temp_root, ".plan-response"),
    model = "",
    response_terminator = "</PLAN>",
    _state = state,
    is_cancelled = function() return false end,
    _set_process = function(self, proc) self.proc = proc end,
  }
  plan_provider:make_request("test", plan_context, {
    on_start = function() end,
    on_stdout = function() end,
    on_stderr = function() end,
    on_complete = function(status, response)
      plan_status, plan_response, plan_done = status, response, true
    end,
  })
  assert(vim.wait(1500, function() return plan_done end), "plan terminator request timed out")
  assert(plan_status == "success", "plan terminator status was " .. tostring(plan_status))
  assert(plan_response:find("</PLAN>", 1, true), "plan terminator response was truncated")
  assert((vim.uv.hrtime() - plan_started) / 1e6 < 1500, "plan waited for CLI shutdown")

  local idle_provider = setmetatable({}, { __index = Base })
  function idle_provider:_get_provider_name() return "idle-test" end
  function idle_provider:_build_command()
    return { "sh", "-c", "printf 'Created hello.md'; sleep 10" }
  end
  local idle_done = false
  local idle_status, idle_response
  local idle_started = vim.uv.hrtime()
  local idle_context = {
    cwd = temp_root,
    tmp_file = vim.fs.joinpath(temp_root, ".idle-response"),
    model = "",
    response_idle_timeout_ms = 100,
    _state = state,
    is_cancelled = function() return false end,
    _set_process = function(self, proc) self.proc = proc end,
  }
  idle_provider:make_request("test", idle_context, {
    on_start = function() end,
    on_stdout = function() end,
    on_stderr = function() end,
    on_complete = function(status, response)
      idle_status, idle_response, idle_done = status, response, true
    end,
  })
  assert(vim.wait(1500, function() return idle_done end), "idle response request timed out")
  assert(idle_status == "success", "idle response status was " .. tostring(idle_status))
  assert(idle_response == "Created hello.md", "idle response content changed")
  assert((vim.uv.hrtime() - idle_started) / 1e6 < 1500, "idle response waited for CLI shutdown")
end

local execute_prompt = require("agent-smith.prompts").vibe_execute("plan", { "hello.md" })
assert(execute_prompt:find("</VIBE_DONE>", 1, true), "Vibe execution prompt lacks completion marker")

local failed_source = vim.fs.joinpath(project, "copy-failure.txt")
write(failed_source, "secret")
vim.fn.system({ "git", "-C", project, "add", "copy-failure.txt" })
local real_copyfile = vim.uv.fs_copyfile
vim.uv.fs_copyfile = function(source, destination)
  if source == failed_source then return nil, "forced copy failure" end
  return real_copyfile(source, destination)
end
local copied, copy_error = pcall(Session.create, original, temp_root, {
  prefix = "rollback", snapshot = false,
})
vim.uv.fs_copyfile = real_copyfile
assert(not copied and tostring(copy_error):find("Unable to copy", 1, true), "copy failure was not reported")
local sessions_dir = vim.fs.joinpath(temp_root, "sessions")
if vim.uv.fs_stat(sessions_dir) then
  for name in vim.fs.dir(sessions_dir) do
    assert(not name:find("rollback", 1, true), "partial sandbox was not rolled back")
  end
end

local cancel_provider = setmetatable({}, { __index = Base })
function cancel_provider:_get_provider_name() return "cancel-test" end
function cancel_provider:_build_command()
  return { "sh", "-c", "trap '' TERM; printf first; sleep 0.2; printf second; sleep 0.3" }
end
local cancelled = false
local cancel_done = false
local cancel_status
local cancel_started = vim.uv.hrtime()
local cancel_context = {
  cwd = temp_root,
  tmp_file = vim.fs.joinpath(temp_root, ".cancel-response"),
  model = "",
  _state = state,
  is_cancelled = function() return cancelled end,
  _set_process = function(self, proc) self.proc = proc end,
}
cancel_provider:make_request("test", cancel_context, {
  on_start = function() end,
  on_stdout = function() end,
  on_stderr = function() end,
  on_complete = function(status)
    cancel_status, cancel_done = status, true
  end,
})
vim.defer_fn(function()
  cancelled = true
  cancel_context.proc:kill(vim.uv.constants.SIGTERM)
end, 50)
assert(vim.wait(3000, function() return cancel_done end), "cancel request timed out")
local cancel_elapsed_ms = (vim.uv.hrtime() - cancel_started) / 1e6
assert(cancel_status == "cancelled", "cancel status was " .. tostring(cancel_status))
assert(cancel_elapsed_ms >= 350, "cancel completed before process exit")

local pi = require("agent-smith.providers.pi")
local pi_search = table.concat(pi:_build_command("q", { operation = "search", model = "" }), " ")
local pi_plan = table.concat(pi:_build_command("q", {
  operation = "vibe", vibe_phase = "plan", model = "",
}), " ")
local pi_vibe = table.concat(pi:_build_command("q", {
  operation = "vibe", vibe_phase = "execute", model = "",
}), " ")
assert(pi_search:find("--tools read,grep,find,ls", 1, true), "Pi search is not read-only")
assert(pi_plan:find("--tools read,grep,find,ls", 1, true), "Pi Vibe plan is not read-only")
assert(not pi_vibe:find("--tools", 1, true), "Pi Vibe execution cannot edit sandbox")

local opencode = require("agent-smith.providers.opencode")
local oc_search = table.concat(opencode:_build_command("q", {
  operation = "search", model = "test", cwd = temp_root,
}), " ")
local oc_vibe = table.concat(opencode:_build_command("q", {
  operation = "vibe", model = "test", cwd = temp_root,
}), " ")
assert(oc_search:find("--agent plan", 1, true), "OpenCode search does not use plan agent")
assert(oc_vibe:find("--agent build", 1, true), "OpenCode Vibe cannot edit sandbox")

vim.fn.delete(project, "rf")
vim.fn.delete(temp_root, "rf")
print("sandbox tests passed")
