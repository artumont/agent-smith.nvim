local H = require("tests.helpers")
local Utils = require("agent-smith.utils")
local Time = require("agent-smith.time")
local next_id = require("agent-smith.id")
local Response = require("agent-smith.ops.response")
local Qfix = require("agent-smith.ops.qfix-helpers")
local Imports = require("agent-smith.imports.detector")
local Prompts = require("agent-smith.prompts")
local Session = require("agent-smith.ops.vibe-session")
local Multi = require("agent-smith.ops.multi-file")
local Approval = require("agent-smith.window.approval-window")
local CleanUp = require("agent-smith.ops.clean-up")
local Marks = require("agent-smith.ops.marks")
local Geo = require("agent-smith.geo")
local Completions = require("agent-smith.extensions.completions")
local Throbber = require("agent-smith.ops.throbber")
local Search = require("agent-smith.ops.search")
local State = require("agent-smith.state")
local Worker = require("agent-smith.extensions.worker")

local root = H.temp_dir("core")
local ok, err = xpcall(function()
  -- Utilities, time, IDs, and request cleanup helpers.
  local original = { nested = { value = 1 } }
  local copied = Utils.copy(original)
  copied.nested.value = 2
  H.assert_equal(original.nested.value, 1, "deep copy")
  assert(Time.now() > 0, "high-resolution time")
  assert(next_id() < next_id(), "monotonic request IDs")
  local file = vim.fs.joinpath(root, "nested", "value.txt")
  assert(Utils.write_file(file, "value"), "write utility")
  H.assert_equal(Utils.read_file(file), "value", "read utility")
  local cleanup_count = 0
  local observer = CleanUp.make_observer({ clean_ups = {
    CleanUp.make_clean_up(function() cleanup_count = cleanup_count + 1 end),
    function() cleanup_count = cleanup_count + 1 end,
  } }, { on_complete = function(status, response)
    H.assert_equal(status, "success", "cleanup status")
    H.assert_equal(response, "done", "cleanup response")
  end })
  observer.on_complete("success", "done")
  H.assert_equal(cleanup_count, 2, "cleanup execution")

  -- Response, import, quickfix, and prompt contracts.
  local code, response_error = Response.normalize_replacement("```lua\nreturn 1\n```")
  H.assert_equal(code, "return 1", "fenced response")
  H.assert_equal(response_error, nil, "fenced response error")
  local bad = Response.normalize_replacement("```lua\nreturn 1")
  H.assert_equal(bad, nil, "unmatched fence rejection")
  local imports, body = Imports.extract("local dep = require('dep')\nreturn dep", "lua")
  H.assert_equal(imports, { "local dep = require('dep')" }, "Lua import extraction")
  H.assert_equal(body, { "return dep" }, "Lua body extraction")
  local import_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(import_buffer, 0, -1, false, { "return dep" })
  Imports.insert(import_buffer, imports, "lua")
  H.assert_equal(vim.api.nvim_buf_get_lines(import_buffer, 0, -1, false), {
    "local dep = require('dep')", "return dep",
  }, "import insertion")
  local qf = Qfix.parse("main.lua:2:3,2,match\nmissing.lua:1:1,1,new", root)
  H.assert_equal(#qf, 2, "quickfix parser")
  H.assert_equal(qf[1].filename, vim.fs.joinpath(root, "main.lua"), "relative quickfix path")
  H.assert_equal(qf[1].end_lnum, 3, "quickfix range")
  H.assert_match(qf[2].text, "[missing file]", "missing quickfix marker")
  H.assert_equal(Qfix.parse_ripgrep("main.lua:2:3:model_name", root), {
    { filename = vim.fs.joinpath(root, "main.lua"), lnum = 2, col = 3, end_lnum = 2, text = "model_name" },
  }, "ripgrep quickfix parser")
  H.assert_match(Prompts.search(), "<RG_PATTERNS>", "search pattern contract")
  H.assert_equal(Search.parse_patterns("<RG_PATTERNS><PATTERN>\\bmodel_name\\b</PATTERN></RG_PATTERNS>"),
    { "\\bmodel_name\\b" }, "search pattern parsing")
  H.assert_equal(Search.parse_patterns("not patterns"), {}, "missing search pattern rejection")
  H.assert_match(Prompts.vibe_plan(), "<PLAN>", "Vibe plan contract")
  H.assert_match(Prompts.vibe_execute("plan", { "main.lua" }), "</VIBE_DONE>", "Vibe completion contract")
  H.assert_match(Prompts.wrap("rules", "request"), "<USER_REQUEST>", "prompt wrapper")

  -- Sandbox plan parsing and scoped diff collection.
  local parsed, parse_error = Session.parse_plan([[<PLAN>
<EDIT_FILES><FILE>main.lua</FILE></EDIT_FILES>
<STEPS>Update main</STEPS>
</PLAN>]])
  assert(parsed and not parse_error, "plan parsing")
  H.assert_equal(parsed.files, { "main.lua" }, "plan file scope")
  local unsafe = Session.parse_plan([[<PLAN><EDIT_FILES><FILE>../escape</FILE></EDIT_FILES><STEPS>x</STEPS></PLAN>]])
  H.assert_equal(unsafe, nil, "unsafe plan path rejection")
  local project = H.project({ ["main.lua"] = "old", ["keep.lua"] = "keep" })
  local source = vim.fs.joinpath(project, "main.lua")
  local sandbox = Session.create(source, root, { prefix = "core", snapshot = true })
  H.write(vim.fs.joinpath(sandbox.root, "main.lua"), "new")
  H.write(vim.fs.joinpath(sandbox.root, "unexpected.lua"), "ignored")
  local proposals, unauthorized = Session.collect_changes(sandbox, { "main.lua" })
  H.assert_equal(#proposals, 1, "scoped proposal count")
  H.assert_equal(proposals[1].content, "new", "scoped proposal content")
  H.assert_equal(unauthorized, { "unexpected.lua" }, "unauthorized sandbox change")
  H.assert_equal(Session.remap_response(sandbox, sandbox.root .. "/main.lua"), source, "sandbox path remap")
  Session.cleanup(sandbox)

  -- Multi-file parse and approval behavior with real files and mocked UI.
  local original_approve = Approval.approve
  local actions = { "approve", "approve" }
  local action_index = 0
  Approval.approve = function(_, cb)
    action_index = action_index + 1
    cb(actions[action_index])
  end
  local replacement = vim.fs.joinpath(project, "main.lua")
  local created = vim.fs.joinpath(project, "created.lua")
  local changes = Multi.parse(string.format(
    "<FILE_CHANGE>%s</FILE_CHANGE><CONTENT>replaced</CONTENT>\n<FILE_CHANGE>%s</FILE_CHANGE><CONTENT>created</CONTENT>",
    replacement, created
  ))
  local applied, total
  Multi.approve_all(changes, function(count, all) applied, total = count, all end)
  H.assert_equal({ applied, total }, { 2, 2 }, "multi-file approval totals")
  H.assert_equal(H.read(replacement), "replaced", "multi-file replacement")
  H.assert_equal(H.read(created), "created", "multi-file creation")
  Approval.approve = original_approve

  -- Completion registration, marks/ranges, and spinner animation.
  Completions.providers = {}
  Completions.register({ trigger = "#", resolve = function(token) return "rule:" .. token end })
  H.assert_equal(Completions.parse("use #lua"), { { content = "rule:lua" } }, "completion resolution")
  local mark_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(mark_buffer, 0, -1, false, { "alpha", "beta" })
  local point = Geo.Point.new(mark_buffer, 1, 1)
  local mark = Marks.mark_point(mark_buffer, point)
  assert(mark:is_valid(), "created mark validity")
  H.assert_equal(mark:point().col, 1, "mark point")
  mark:delete()
  assert(not mark:is_valid(), "deleted mark validity")
  local range = Geo.Range.new(mark_buffer, Geo.Point.new(mark_buffer, 1, 0), Geo.Point.new(mark_buffer, 1, 4))
  H.assert_equal(range:to_text(), "alpha", "range text")
  assert(range:replace_text({ "omega" }), "range replacement")
  H.assert_equal(vim.api.nvim_buf_get_lines(mark_buffer, 0, 1, false), { "omega" }, "range buffer update")
  range:clear()
  local spinner = Throbber.new()
  H.assert_equal(spinner:next(), "⠋", "spinner first frame")
  H.assert_equal(spinner:next(), "⠙", "spinner second frame")

  -- State and work-item extension configuration.
  local rules = vim.fs.joinpath(root, "rules")
  H.write(vim.fs.joinpath(rules, "lua", "SKILL.md"), "Lua rules")
  local state_provider = { _get_default_model = function() return "default" end }
  local plugin_state = State.new({
    provider = state_provider,
    tmp_dir = root,
    completion = { custom_rules = { rules } },
  })
  H.assert_equal(plugin_state:tmp_dir(), root, "state temp root")
  H.assert_equal(plugin_state:active_provider(), state_provider, "state provider")
  H.assert_equal(plugin_state.rules[1].name, "lua", "custom rule discovery")
  Worker.set_work({ description = "Cover operations" })
  H.assert_equal(Worker.current_work_item, "Cover operations", "worker work item")

  -- Provider adapters expose commands/default models without real CLIs.
  local adapter_context = { model = "chosen", cwd = root, operation = "search" }
  for _, module in ipairs({ "claude", "cursor", "gemini", "kiro", "opencode", "pi" }) do
    local adapter = require("agent-smith.providers." .. module)
    assert(adapter:_get_provider_name() ~= "", module .. " provider name")
    assert(type(adapter:_get_default_model()) == "string", module .. " provider model")
    local command = adapter:_build_command("request", adapter_context)
    H.assert_equal(command[#command], "request", module .. " provider query")
  end
  local claude_models
  require("agent-smith.providers.claude"):fetch_models(function(models) claude_models = models end)
  assert(#claude_models > 0, "Claude model listing")

  H.cleanup(project)
end, debug.traceback)

H.cleanup(root)
assert(ok, err)
print("core tests passed")
