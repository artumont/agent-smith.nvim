return function(t)
  local Scope = require("agent-smith.agent.scope")
  local Registry = require("agent-smith.tools.registry")

  local read_buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(read_buffer, "/repo/registry_spec.lua")

  local function inline_scope(overrides)
    local fields = { buffer = read_buffer, start_row = 1, end_row = 100 }
    for name, value in pairs(overrides or {}) do
      fields[name] = value
    end
    return Scope.inline(fields)
  end

  --- Collect the single outcome a dispatch produces.
  local function recorder()
    local record = { calls = 0, outcome = nil }
    local function on_done(outcome)
      record.calls = record.calls + 1
      record.outcome = outcome
    end
    return record, on_done
  end

  local function read_tool(overrides)
    local spec = {
      name = "read",
      description = "Read a file.",
      access = "read",
      parameters = { path = { type = "string", required = true } },
      handler = function(arguments)
        return Registry.ok("contents of " .. arguments.path)
      end,
    }
    for name, value in pairs(overrides or {}) do
      spec[name] = value
    end
    return spec
  end

  local function write_tool(overrides)
    local spec = {
      name = "edit",
      description = "Edit a file.",
      access = "write",
      parameters = {
        path = { type = "string", required = true },
        start_row = { type = "number", required = true },
        end_row = { type = "number", required = true },
      },
      locate = function(arguments)
        return {
          kind = "write",
          path = arguments.path,
          range = { start_row = arguments.start_row, end_row = arguments.end_row },
        }
      end,
      handler = function()
        return Registry.ok("edited")
      end,
    }
    for name, value in pairs(overrides or {}) do
      spec[name] = value
    end
    return spec
  end

  local function execute_tool(overrides)
    local spec = {
      name = "bash",
      description = "Run a command.",
      access = "execute",
      parameters = { command = { type = "string", required = true } },
      locate = function(arguments)
        return { kind = "execute", command = arguments.command }
      end,
      handler = function()
        return Registry.ok("ran it")
      end,
    }
    for name, value in pairs(overrides or {}) do
      spec[name] = value
    end
    return spec
  end

  local function registry_with(...)
    local registry = Registry.new()
    for _, spec in ipairs({ ... }) do
      registry:register(spec)
    end
    return registry
  end

  t.describe("register", function()
    t.it("accepts a valid spec", function()
      local registry = registry_with(read_tool())
      t.eq(registry:names(), { "read" })
    end)

    t.it("raises for an invalid spec", function()
      t.raises(function()
        registry_with({ name = "", description = "x", access = "read", handler = function() end })
      end, "non%-empty name")
    end)

    t.it("requires a description", function()
      t.raises(function()
        registry_with({ name = "x", access = "read", handler = function() end })
      end, "non%-empty description")
    end)

    t.it("requires a known access level", function()
      t.raises(function()
        registry_with({ name = "x", description = "d", access = "sudo", handler = function() end })
      end, "read, write, execute")
    end)

    t.it("requires a handler", function()
      t.raises(function()
        registry_with({ name = "x", description = "d", access = "read" })
      end, "handler function")
    end)

    t.it("requires locate for a write tool", function()
      t.raises(function()
        registry_with({ name = "x", description = "d", access = "write", handler = function() end })
      end, "locate function")
    end)

    t.it("requires locate for an execute tool", function()
      t.raises(function()
        registry_with({ name = "x", description = "d", access = "execute", handler = function() end })
      end, "locate function")
    end)

    t.it("rejects an unknown parameter type", function()
      t.raises(function()
        registry_with(read_tool({ parameters = { path = { type = "float" } } }))
      end, "unknown type")
    end)

    t.it("rejects an enum that is not a list", function()
      t.raises(function()
        registry_with(read_tool({ parameters = { path = { type = "string", enum = { a = 1 } } } }))
      end, "enum must be a list")
    end)

    t.it("refuses a duplicate name", function()
      t.raises(function()
        registry_with(read_tool(), read_tool())
      end, "already registered")
    end)

    t.it("sorts names", function()
      local registry = registry_with(read_tool(), write_tool(), execute_tool())
      t.eq(registry:names(), { "bash", "edit", "read" })
    end)
  end)

  t.describe("to_json_schema", function()
    t.it("describes required arguments", function()
      local schema = Registry.to_json_schema(write_tool())
      t.eq(schema.name, "edit")
      t.eq(schema.parameters.type, "object")
      t.eq(schema.parameters.required, { "end_row", "path", "start_row" })
    end)

    t.it("closes the schema, matching the argument check", function()
      t.eq(Registry.to_json_schema(read_tool()).parameters.additionalProperties, false)
    end)

    t.it("passes descriptions and enums through", function()
      local schema = Registry.to_json_schema(
        read_tool({ parameters = {
          mode = { type = "string", enum = { "lines", "bytes" }, description = "How to count." },
        } })
      )
      t.eq(schema.parameters.properties.mode.enum, { "lines", "bytes" })
      t.eq(schema.parameters.properties.mode.description, "How to count.")
    end)

    t.it("describes array items", function()
      local schema = Registry.to_json_schema(
        read_tool({ parameters = { paths = { type = "array", items = "string", required = true } } })
      )
      t.eq(schema.parameters.properties.paths.type, "array")
      t.eq(schema.parameters.properties.paths.items.type, "string")
    end)

    t.it("produces a schema per registered tool, in name order", function()
      local schemas = registry_with(read_tool(), execute_tool()):schemas()
      t.eq({ schemas[1].name, schemas[2].name }, { "bash", "read" })
    end)
  end)

  t.describe("dispatch: dispatch-level failures", function()
    t.it("reports an unknown tool", function()
      local record, on_done = recorder()
      registry_with(read_tool()):dispatch({ name = "nope", arguments = {} }, inline_scope(), on_done)
      t.eq(record.calls, 1)
      t.eq(record.outcome.ok, false)
      t.matches(record.outcome.error, "unknown tool")
    end)

    t.it("reports a missing required argument", function()
      local record, on_done = recorder()
      registry_with(read_tool()):dispatch({ name = "read", arguments = {} }, inline_scope(), on_done)
      t.matches(record.outcome.error, "missing required argument 'path'")
    end)

    t.it("reports a wrongly typed argument", function()
      local record, on_done = recorder()
      registry_with(read_tool()):dispatch({ name = "read", arguments = { path = 42 } }, inline_scope(), on_done)
      t.matches(record.outcome.error, "must be string, got number")
    end)

    t.it("reports an unknown argument and lists what is accepted", function()
      local record, on_done = recorder()
      registry_with(read_tool()):dispatch({ name = "read", arguments = { pth = "/a" } }, inline_scope(), on_done)
      t.matches(record.outcome.error, "unknown argument 'pth'")
      t.matches(record.outcome.error, "accepts: path")
    end)

    t.it("enforces an enum", function()
      local record, on_done = recorder()
      local registry = registry_with(read_tool({ parameters = { path = { type = "string", required = true, enum = { "/a", "/b" } } } }))
      registry:dispatch({ name = "read", arguments = { path = "/c" } }, inline_scope(), on_done)
      t.matches(record.outcome.error, "must be one of /a, /b")
    end)

    t.it("enforces array element types", function()
      local record, on_done = recorder()
      local registry = registry_with(read_tool({ parameters = { paths = { type = "array", items = "string", required = true } } }))
      registry:dispatch({ name = "read", arguments = { paths = { "/a", 7 } } }, inline_scope(), on_done)
      t.matches(record.outcome.error, "'paths'%[2%] must be string, got number")
    end)

    t.it("treats missing arguments as an empty table", function()
      local record, on_done = recorder()
      local registry = registry_with(read_tool({
        parameters = {},
        handler = function()
          return Registry.ok("ran with no arguments")
        end,
      }))
      registry:dispatch({ name = "read" }, inline_scope(), on_done)
      t.eq(record.outcome.ok, true)
      t.eq(record.outcome.content, "ran with no arguments")
    end)
  end)

  t.describe("dispatch: policy", function()
    t.it("runs a read tool without asking locate", function()
      local record, on_done = recorder()
      local registry = registry_with(read_tool())
      registry:dispatch({ name = "read", arguments = { path = "/repo/a.lua" } }, inline_scope(), on_done)
      t.eq(record.outcome.ok, true)
      t.eq(record.outcome.content, "contents of /repo/a.lua")
    end)

    t.it("escalates an out-of-range write instead of running the handler", function()
      local ran = false
      local record, on_done = recorder()
      local registry = registry_with(write_tool({ handler = function()
        ran = true
        return Registry.ok("edited")
      end }))
      registry:dispatch(
        { name = "edit", arguments = { path = "/repo/registry_spec.lua", start_row = 200, end_row = 201 } },
        inline_scope(),
        on_done
      )
      t.eq(record.outcome.needs_permission ~= nil, true)
      t.eq(record.outcome.needs_permission.tool, "edit")
      t.matches(record.outcome.needs_permission.reason, "outside the selected range")
      t.eq(ran, false, "the handler must not run")
    end)

    t.it("denies a blacklisted command instead of running the handler", function()
      local ran = false
      local record, on_done = recorder()
      local registry = registry_with(execute_tool({ handler = function()
        ran = true
        return Registry.ok("ran it")
      end }))
      registry:dispatch(
        { name = "bash", arguments = { command = "rm -rf /" } },
        inline_scope({ blacklist = { "^%s*rm%s" } }),
        on_done
      )
      t.eq(record.outcome.ok, false)
      t.matches(record.outcome.error, "blacklist")
      t.eq(ran, false)
    end)

    t.it("refuses an out-of-plan write in a vibe scope", function()
      local record, on_done = recorder()
      local registry = registry_with(write_tool())
      local scope = Scope.vibe({ paths = { "/repo/approved.lua" } })
      registry:dispatch({ name = "edit", arguments = { path = "/repo/other.lua", start_row = 1, end_row = 2 } }, scope, on_done)
      t.eq(record.outcome.ok, false)
      t.matches(record.outcome.error, "not in the approved plan scope")
    end)

    t.it("reports an invalid target from a misbehaving locate", function()
      local record, on_done = recorder()
      local registry = registry_with(write_tool({ locate = function()
        return { kind = "write" }
      end }))
      registry:dispatch({ name = "edit", arguments = { path = "/a", start_row = 1, end_row = 1 } }, inline_scope(), on_done)
      t.matches(record.outcome.error, "invalid target for edit")
    end)

    t.it("reports a locate that raises", function()
      local record, on_done = recorder()
      local registry = registry_with(write_tool({ locate = function()
        error("locate exploded")
      end }))
      registry:dispatch({ name = "edit", arguments = { path = "/a", start_row = 1, end_row = 1 } }, inline_scope(), on_done)
      t.matches(record.outcome.error, "locate exploded")
    end)
  end)

  t.describe("dispatch: handler lifecycle", function()
    t.it("delivers a returned outcome synchronously", function()
      local record, on_done = recorder()
      registry_with(read_tool()):dispatch({ name = "read", arguments = { path = "/a" } }, inline_scope(), on_done)
      t.eq(record.calls, 1)
      t.eq(record.outcome.ok, true)
    end)

    t.it("delivers an outcome from an asynchronous handler", function()
      local record, on_done = recorder()
      local later
      local registry = registry_with(read_tool({ handler = function(_, context)
        later = context.finish
        return nil
      end }))
      registry:dispatch({ name = "read", arguments = { path = "/a" } }, inline_scope(), on_done)
      t.eq(record.calls, 0, "nothing yet: the handler went asynchronous")
      later(Registry.ok("eventually"))
      t.eq(record.calls, 1)
      t.eq(record.outcome.content, "eventually")
    end)

    t.it("ignores a second finish", function()
      local record, on_done = recorder()
      local first
      local registry = registry_with(read_tool({ handler = function(_, context)
        first = context.finish
        return nil
      end }))
      registry:dispatch({ name = "read", arguments = { path = "/a" } }, inline_scope(), on_done)
      first(Registry.ok("one"))
      first(Registry.ok("two"))
      t.eq(record.calls, 1)
      t.eq(record.outcome.content, "one")
    end)

    t.it("keeps the returned outcome when the handler also calls finish", function()
      local record, on_done = recorder()
      local registry = registry_with(read_tool({ handler = function(_, context)
        context.finish(Registry.ok("from finish"))
        return Registry.ok("from return")
      end }))
      registry:dispatch({ name = "read", arguments = { path = "/a" } }, inline_scope(), on_done)
      t.eq(record.calls, 1)
      t.eq(record.outcome.content, "from finish")
    end)

    t.it("turns a raising handler into an error outcome", function()
      local record, on_done = recorder()
      local registry = registry_with(read_tool({ handler = function()
        error("handler exploded")
      end }))
      registry:dispatch({ name = "read", arguments = { path = "/a" } }, inline_scope(), on_done)
      t.eq(record.outcome.ok, false)
      t.matches(record.outcome.error, "handler exploded")
    end)

    t.it("rejects a malformed outcome", function()
      local record, on_done = recorder()
      local registry = registry_with(read_tool({ handler = function()
        return { ok = true }
      end }))
      registry:dispatch({ name = "read", arguments = { path = "/a" } }, inline_scope(), on_done)
      t.eq(record.outcome.ok, false)
      t.matches(record.outcome.error, "malformed outcome")
    end)

    t.it("leaves the request hanging when a handler does neither", function()
      -- Documented footgun: returning nil without calling finish means on_done
      -- never fires. Asserted so the contract is explicit rather than implied.
      local record, on_done = recorder()
      local registry = registry_with(read_tool({ handler = function() end }))
      registry:dispatch({ name = "read", arguments = { path = "/a" } }, inline_scope(), on_done)
      t.eq(record.calls, 0)
    end)
  end)

  t.describe("validate_outcome", function()
    t.it("accepts the three shapes", function()
      t.eq(Registry.validate_outcome(Registry.ok("x")), true)
      t.eq(Registry.validate_outcome(Registry.error("x")), true)
      t.eq(
        Registry.validate_outcome(Registry.needs_permission({ tool = "edit", reason = "out of range" })),
        true
      )
    end)

    t.it("rejects a non-table", function()
      t.eq(Registry.validate_outcome("ok"), false)
    end)

    t.it("rejects a permission request mixed with a result", function()
      local mixed = { needs_permission = { tool = "edit", reason = "r" }, ok = true, content = "x" }
      local ok, problem = Registry.validate_outcome(mixed)
      t.eq(ok, false)
      t.matches(problem, "cannot be both")
    end)

    t.it("requires a reason on a permission request", function()
      local ok, problem = Registry.validate_outcome({ needs_permission = { tool = "edit" } })
      t.eq(ok, false)
      t.matches(problem, "reason")
    end)

    t.it("rejects a success with no content", function()
      t.eq(Registry.validate_outcome({ ok = true }), false)
    end)

    t.it("rejects a failure with no error", function()
      t.eq(Registry.validate_outcome({ ok = false }), false)
    end)

    t.it("rejects a success carrying an error", function()
      t.eq(Registry.validate_outcome({ ok = true, content = "x", error = "y" }), false)
    end)

    t.it("rejects a non-boolean ok", function()
      t.eq(Registry.validate_outcome({ ok = "yes", content = "x" }), false)
    end)
  end)
end
