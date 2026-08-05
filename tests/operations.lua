local H = require("tests.helpers")
local Tracking = require("agent-smith.tracking")
local Visual = require("agent-smith.ops.visual")
local Search = require("agent-smith.ops.search")
local Vibe = require("agent-smith.ops.vibe")
local Tutorial = require("agent-smith.ops.tutorial")
local PromptWindow = require("agent-smith.window.prompt-window")
local PlanWindow = require("agent-smith.window.plan-window")
local Multi = require("agent-smith.ops.multi-file")
local Approval = require("agent-smith.window.approval-window")
local Window = require("agent-smith.window")
local Telescope = require("agent-smith.extensions.telescope")

local temp_root = H.temp_dir("operations")
local function state_for(provider)
  local state = { model = "test-model", md_files = {}, tracking = Tracking.new() }
  function state:tmp_dir() return temp_root end
  function state:active_provider() return provider end
  return state
end

local original_capture = PromptWindow.capture
local original_review = PlanWindow.review
local original_approve_all = Multi.approve_all
local original_approval = Approval.approve
local original_display = Window.display_full_screen_message
local original_search_results = Telescope.search_results

local ok, err = xpcall(function()
  -- Inline visual edit: real selection, streamed status text, imports, fence.
  local visual_project = H.project({ ["main.lua"] = "return old" })
  local visual_file = vim.fs.joinpath(visual_project, "main.lua")
  local visual_buffer = H.edit(visual_file)
  vim.bo[visual_buffer].filetype = "lua"
  vim.fn.setpos("'<", { 0, 1, 1, 0 })
  vim.fn.setpos("'>", { 0, 1, #"return old", 0 })

  local visual_provider = H.fake_provider(function(_, context, observer)
    H.assert_equal(context.operation, "visual", "visual operation")
    observer.on_stdout("Inspecting selected code")
    local marks = vim.api.nvim_buf_get_extmarks(visual_buffer, -1, 0, -1, { details = true })
    H.assert_match(vim.inspect(marks), "Agent output", "inline provider output")
    observer.on_complete("success", "```lua\nlocal dep = require('dep')\nreturn dep\n```")
  end)
  PromptWindow.capture = function(_, opts) opts.cb(true, "use dependency") end
  Visual.run(state_for(visual_provider))
  H.assert_equal(
    vim.api.nvim_buf_get_lines(visual_buffer, 0, -1, false),
    { "local dep = require('dep')", "return dep" },
    "visual replacement and import insertion"
  )

  -- Codebase search: provider path remaps from disposable workspace to source.
  local search_project = H.project({ ["main.lua"] = "local model_name = 'test'" })
  local search_file = vim.fs.joinpath(search_project, "main.lua")
  H.edit(search_file)
  local search_provider = H.fake_provider(function(_, context, observer)
    H.assert_equal(context.operation, "search", "search operation")
    observer.on_complete("success", context.cwd .. "/main.lua:1:7,1,model name")
  end)
  Search.run(state_for(search_provider), { additional_prompt = "find model name" })
  local qf = vim.fn.getqflist()
  H.assert_equal(#qf, 1, "search quickfix count")
  H.assert_equal(vim.api.nvim_buf_get_name(qf[1].bufnr), search_file, "search path remapping")
  H.assert_equal(qf[1].lnum, 1, "search line")
  vim.cmd("cclose")
  local picked
  Telescope.search_results = function(items)
    picked = items
    return true
  end
  Search.run(state_for(search_provider), { additional_prompt = "find model name" })
  H.assert_equal(#picked, 1, "search picker result count")
  H.assert_equal(picked[1].lnum, 1, "search picker result")
  Telescope.search_results = original_search_results

  -- Vibe: plan -> approval -> recreated sandbox -> scoped proposal.
  local vibe_project = H.project({ ["main.lua"] = "return 'source'" })
  local vibe_file = vim.fs.joinpath(vibe_project, "main.lua")
  H.edit(vibe_file)
  local phases = {}
  local plan_root
  local vibe_provider = H.fake_provider(function(_, context, observer)
    table.insert(phases, context.vibe_phase)
    if context.vibe_phase == "plan" then
      plan_root = context.cwd
      H.write(vim.fs.joinpath(plan_root, "stale-plan.md"), "discard me")
      observer.on_complete("success", [[<PLAN>
<EDIT_FILES>
<FILE>hello.md</FILE>
</EDIT_FILES>
<STEPS>
Create hello.md
</STEPS>
</PLAN>]])
      return
    end
    H.assert_equal(context.vibe_phase, "execute", "Vibe execution phase")
    assert(context.cwd ~= plan_root, "Vibe did not recreate sandbox before execution")
    assert(vim.uv.fs_stat(vim.fs.joinpath(context.cwd, "stale-plan.md")) == nil,
      "plan-phase mutation leaked into execution sandbox")
    H.write(vim.fs.joinpath(context.cwd, "hello.md"), "hello")
    H.write(vim.fs.joinpath(context.cwd, "ignored.md"), "ignored")
    observer.on_complete("success", "<VIBE_DONE>created hello</VIBE_DONE>")
  end)
  local proposed
  PlanWindow.review = function(plan, cb)
    H.assert_equal(plan.files, { "hello.md" }, "Vibe plan scope")
    cb(true)
  end
  Approval.approve = function(_, cb) cb("approve") end
  Multi.approve_all = function(changes, done)
    proposed = changes
    original_approve_all(changes, done)
  end
  Vibe.run(state_for(vibe_provider), { additional_prompt = "create hello" })
  H.assert_equal(phases, { "plan", "execute" }, "Vibe phase order")
  H.assert_equal(#proposed, 1, "Vibe approved scope filters proposals")
  H.assert_equal(proposed[1].path, vim.fs.joinpath(vibe_project, "hello.md"), "Vibe proposal path")
  H.assert_equal(proposed[1].content, "hello", "Vibe proposal content")
  H.assert_equal(H.read(vim.fs.joinpath(vibe_project, "hello.md")), "hello", "Vibe approved write")
  assert(vim.uv.fs_stat(vim.fs.joinpath(vibe_project, "ignored.md")) == nil,
    "Vibe applied out-of-scope write")

  -- Rejected plan never executes provider-side writes.
  local rejected = 0
  PlanWindow.review = function(_, cb) cb(false) end
  local reject_provider = H.fake_provider(function(_, context, observer)
    rejected = rejected + 1
    H.assert_equal(context.vibe_phase, "plan", "rejected Vibe should only plan")
    observer.on_complete("success", [[<PLAN><EDIT_FILES></EDIT_FILES><STEPS>Inspect only</STEPS></PLAN>]])
  end)
  Vibe.run(state_for(reject_provider), { additional_prompt = "inspect" })
  H.assert_equal(rejected, 1, "rejected Vibe executed implementation")

  -- Tutorial sends provider response to display window.
  local tutorial_lines
  Window.display_full_screen_message = function(lines) tutorial_lines = lines end
  PromptWindow.capture = function(_, opts) opts.cb(true, "teach module") end
  local tutorial_provider = H.fake_provider(function(_, context, observer)
    H.assert_equal(context.operation, "tutorial", "tutorial operation")
    observer.on_complete("success", "# Tutorial\nBody")
  end)
  Tutorial.run(state_for(tutorial_provider))
  H.assert_equal(tutorial_lines, { "# Tutorial", "Body" }, "tutorial display")

  H.cleanup(visual_project, search_project, vibe_project)
end, debug.traceback)

PromptWindow.capture = original_capture
PlanWindow.review = original_review
Multi.approve_all = original_approve_all
Approval.approve = original_approval
Window.display_full_screen_message = original_display
Telescope.search_results = original_search_results
H.cleanup(temp_root)
H.close_floats()
assert(ok, err)
print("operations tests passed")
