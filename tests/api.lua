local H = require("tests.helpers")
local smith = require("agent-smith")
local Ops = require("agent-smith.ops")
local Select = require("agent-smith.window.select-window")
local Window = require("agent-smith.window")
local Logger = require("agent-smith.logger")
local Statusline = require("agent-smith.statusline")

assert(not pcall(smith.get_model), "public API must require setup")

local temp_root = H.temp_dir("api")
local calls = {}
local first = H.fake_provider(function() end)
function first:_get_default_model() return "first-model" end
function first:_get_provider_name() return "First" end
local second = H.fake_provider(function() end)
function second:_get_default_model() return "second-model" end
function second:_get_provider_name() return "Second" end

H.assert_equal(smith.setup({
  provider = first,
  tmp_dir = temp_root,
  default_keymaps = false,
  completion = { source = "native" },
}), smith, "setup chaining")
H.assert_equal(smith.get_model(), "first-model", "default model")
H.assert_equal(smith.get_provider(), first, "initial provider")
H.assert_equal(smith.get_provider_name(), "First", "initial provider name")
H.assert_equal(smith.set_model("manual-model"), smith, "set_model chaining")
H.assert_equal(smith.get_model(), "manual-model", "manual model")
H.assert_equal(smith.set_provider(second), smith, "set_provider chaining")
H.assert_equal(smith.get_provider(), second, "provider override")
H.assert_equal(smith.get_provider_name(), "Second", "provider override name")
H.assert_equal(smith.get_model(), "second-model", "provider resets model")
assert(not pcall(smith.set_provider, nil), "nil provider must fail")

local originals = {
  visual = Ops.visual.run,
  search = Ops.search.run,
  vibe = Ops.vibe.run,
  tutorial = Ops.tutorial.run,
  select = Select.select,
  display = Window.display_full_screen_message,
  logs = Logger.logs_by_id,
  notify = vim.notify,
}

local ok, err = xpcall(function()
  Ops.visual.run = function(state, opts)
    calls.visual = calls.visual or {}
    table.insert(calls.visual, { state = state, opts = opts })
  end
  Ops.search.run = function(state, opts) calls.search = { state = state, opts = opts } end
  Ops.vibe.run = function(state, opts) calls.vibe = { state = state, opts = opts } end
  Ops.tutorial.run = function(state, opts) calls.tutorial = { state = state, opts = opts } end

  smith.visual({ target = "selection" })
  smith.multi_file({ target = "files" })
  smith.search({ additional_prompt = "find" })
  smith.vibe({ additional_prompt = "build" })
  smith.tutorial({ topic = "tests" })
  H.assert_equal(calls.visual[1].opts.target, "selection", "visual dispatch")
  H.assert_equal(calls.visual[1].state, smith.__get_state(), "visual state")
  H.assert_equal(calls.visual[2].opts.target, "files", "multi_file dispatch")
  H.assert_equal(calls.visual[2].opts.multi_file, true, "multi_file flag")
  H.assert_equal(calls.search.opts.additional_prompt, "find", "search dispatch")
  H.assert_equal(calls.vibe.opts.additional_prompt, "build", "Vibe dispatch")
  H.assert_equal(calls.tutorial.opts.topic, "tests", "tutorial dispatch")

  local state = smith.__get_state()
  local cancelled = false
  state.tracking.stop_all_requests = function() cancelled = true end
  local notification
  vim.notify = function(message) notification = message end
  smith.stop_all_requests()
  assert(cancelled, "stop_all_requests did not delegate")
  H.assert_match(notification, "cancelled", "stop notification")

  state.tracking.history = { { operation = "search", summary = function() return "old query" end } }
  smith.clear_previous_requests()
  H.assert_equal(#state.tracking.history, 0, "history clearing")

  local logged
  Select.select = function(_, items, cb)
    H.assert_equal(items, { "search: old query" }, "log selection entries")
    cb(1)
  end
  Logger.logs_by_id = function() return { "request log" } end
  Window.display_full_screen_message = function(lines) logged = lines end
  state.tracking.history = {
    { xid = "request", operation = "search", summary = function() return "old query" end },
  }
  smith.view_logs()
  H.assert_equal(logged, { "request log" }, "log display")

  local status_context = { xid = "api-status" }
  Statusline.start(status_context, "Testing")
  assert(smith.statusline_active(), "statusline active")
  H.assert_match(smith.statusline(), "Testing", "statusline content")
  H.assert_equal(smith.statusline_color(), nil, "statusline color without matrix mode")
  Statusline.stop(status_context)
  assert(not smith.statusline_active(), "statusline stopped")

  local info
  vim.notify = function(message) info = message end
  smith.info()
  H.assert_match(info, "Second", "info provider")
  H.assert_match(info, "second-model", "info model")

  local progress_win = smith.progress()
  assert(vim.api.nvim_win_is_valid(progress_win), "public progress window")
  vim.api.nvim_win_close(progress_win, true)
end, debug.traceback)

Ops.visual.run = originals.visual
Ops.search.run = originals.search
Ops.vibe.run = originals.vibe
Ops.tutorial.run = originals.tutorial
Select.select = originals.select
Window.display_full_screen_message = originals.display
Logger.logs_by_id = originals.logs
vim.notify = originals.notify
H.cleanup(temp_root)
assert(ok, err)
print("api tests passed")
