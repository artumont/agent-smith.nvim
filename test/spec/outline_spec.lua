return function(t)
  local Outline = require("agent-smith.outline")

  --- Run `body` with `vim.lsp` stubbed, always restoring the real functions.
  ---
  --- There is no language server in a headless test, so the LSP path is driven
  --- through the two functions the module actually calls.
  local function with_lsp(clients, responder, body)
    local real_get_clients = vim.lsp.get_clients
    local real_request_sync = vim.lsp.buf_request_sync

    vim.lsp.get_clients = function()
      return clients
    end
    vim.lsp.buf_request_sync = responder

    local ok, err = pcall(body)

    vim.lsp.get_clients = real_get_clients
    vim.lsp.buf_request_sync = real_request_sync

    if not ok then
      error(err, 0)
    end
  end

  local function capable_client()
    return { server_capabilities = { documentSymbolProvider = true } }
  end

  --- A DocumentSymbol-shaped response: nested, with `range`.
  local function document_symbols()
    return {
      {
        name = "outer",
        kind = 12,
        range = { start = { line = 4 }, ["end"] = { line = 20 } },
        children = {
          { name = "inner", kind = 6, range = { start = { line = 6 }, ["end"] = { line = 9 } } },
        },
      },
    }
  end

  t.describe("outline.from_heuristic", function()
    local lua_lines = {
      "local M = {}",                     -- 1
      "",                                 -- 2
      "local function helper(a)",         -- 3
      "  return a",                       -- 4
      "end",                              -- 5
      "",                                 -- 6
      "function M.run(options)",          -- 7
      "  return options",                 -- 8
      "end",                              -- 9
      "",                                 -- 10
      "local result = helper(1)",         -- 11
    }

    t.it("finds declarations with their line numbers", function()
      local symbols = Outline.from_heuristic("a.lua", lua_lines)
      local names = {}
      for _, symbol in ipairs(symbols) do
        names[#names + 1] = symbol.name .. "@" .. symbol.row
      end
      t.eq(names, { "M@1", "helper@3", "M.run@7", "result@11" })
    end)

    t.it("labels kinds", function()
      local symbols = Outline.from_heuristic("a.lua", lua_lines)
      t.eq(symbols[1].kind, "variable")
      t.eq(symbols[2].kind, "function")
      t.eq(symbols[4].kind, "variable")
    end)

    t.it("infers an end row from the next declaration", function()
      -- A line pattern sees where a declaration starts and never where it ends.
      local symbols = Outline.from_heuristic("a.lua", lua_lines)
      t.eq(symbols[2].row, 3)
      t.eq(symbols[2].end_row, 6, "the line before the next declaration")
      t.eq(symbols[4].end_row, #lua_lines, "the last one runs to the end")
    end)

    t.it("reads python declarations", function()
      local symbols = Outline.from_heuristic("a.py", {
        "class Thing:",              -- 1
        "    def method(self):",     -- 2
        "        pass",              -- 3
        "def free():",               -- 4
        "    pass",                  -- 5
      })
      t.eq(symbols[1].name, "Thing")
      t.eq(symbols[1].kind, "class")
      t.eq(symbols[2].name, "method")
      t.eq(symbols[3].name, "free")
    end)

    t.it("reads go declarations including methods", function()
      local symbols = Outline.from_heuristic("a.go", {
        "package main",                      -- 1
        "func main() {",                     -- 2
        "}",                                 -- 3
        "func (s *Server) Handle() {",       -- 4
        "}",                                 -- 5
        "type Thing struct {",               -- 6
      })
      local names = {}
      for _, symbol in ipairs(symbols) do
        names[#names + 1] = symbol.name .. ":" .. symbol.kind
      end
      t.eq(names, { "main:function", "Handle:method", "Thing:struct" })
    end)

    t.it("reports an unsupported extension rather than guessing", function()
      local symbols, reason = Outline.from_heuristic("a.xyz", { "whatever" })
      t.eq(symbols, nil)
      t.matches(reason, "no outline support for %.xyz")
    end)

    t.it("reports when nothing matched", function()
      local symbols, reason = Outline.from_heuristic("a.lua", { "-- just a comment" })
      t.eq(symbols, nil)
      t.matches(reason, "no declarations matched")
    end)
  end)

  t.describe("outline.from_lsp", function()
    t.it("refuses without a buffer", function()
      local symbols, reason = Outline.from_lsp(nil)
      t.eq(symbols, nil)
      t.matches(reason, "no buffer")
    end)

    t.it("reports when no server is attached", function()
      with_lsp({}, function()
        error("should not be called")
      end, function()
        local symbols, reason = Outline.from_lsp(0)
        t.eq(symbols, nil)
        t.matches(reason, "no server provides documentSymbol")
      end)
    end)

    t.it("ignores a server that cannot list symbols", function()
      with_lsp({ { server_capabilities = {} } }, function()
        error("should not be called")
      end, function()
        local symbols, reason = Outline.from_lsp(0)
        t.eq(symbols, nil)
        t.matches(reason, "no server provides documentSymbol")
      end)
    end)

    t.it("flattens nested document symbols", function()
      with_lsp({ capable_client() }, function()
        return { [1] = { result = document_symbols() } }
      end, function()
        local symbols = Outline.from_lsp(0)

        t.eq(symbols[1].name, "outer")
        t.eq(symbols[1].kind, "function")
        t.eq(symbols[1].row, 5, "LSP lines are 0-indexed")
        t.eq(symbols[1].end_row, 21)
        t.eq(symbols[1].depth, 0)

        t.eq(symbols[2].name, "inner")
        t.eq(symbols[2].kind, "method")
        t.eq(symbols[2].row, 7)
        t.eq(symbols[2].depth, 1, "children are one level deeper")
      end)
    end)

    t.it("reads the older flat symbol shape too", function()
      with_lsp({ capable_client() }, function()
        return {
          [1] = {
            result = {
              { name = "flat", kind = 5, location = { range = { start = { line = 2 }, ["end"] = { line = 8 } } } },
            },
          },
        }
      end, function()
        local symbols = Outline.from_lsp(0)
        t.eq(symbols[1].name, "flat")
        t.eq(symbols[1].kind, "class")
        t.eq(symbols[1].row, 3)
        t.eq(symbols[1].end_row, 9)
      end)
    end)

    t.it("sorts symbols by line", function()
      with_lsp({ capable_client() }, function()
        return {
          [1] = {
            result = {
              { name = "second", kind = 12, range = { start = { line = 9 }, ["end"] = { line = 10 } } },
              { name = "first", kind = 12, range = { start = { line = 1 }, ["end"] = { line = 2 } } },
            },
          },
        }
      end, function()
        local symbols = Outline.from_lsp(0)
        t.eq({ symbols[1].name, symbols[2].name }, { "first", "second" })
      end)
    end)

    t.it("reports a server that returns nothing", function()
      with_lsp({ capable_client() }, function()
        return { [1] = { result = {} } }
      end, function()
        local symbols, reason = Outline.from_lsp(0)
        t.eq(symbols, nil)
        t.matches(reason, "no symbols")
      end)
    end)

    t.it("survives a failing request", function()
      with_lsp({ capable_client() }, function()
        error("the server exploded")
      end, function()
        local symbols, reason = Outline.from_lsp(0)
        t.eq(symbols, nil)
        t.matches(reason, "request failed")
      end)
    end)
  end)

  t.describe("outline.for_file", function()
    t.it("prefers the language server", function()
      with_lsp({ capable_client() }, function()
        return { [1] = { result = document_symbols() } }
      end, function()
        local outline = Outline.for_file({ path = "/tmp/a.lua", lines = { "function y()" }, buffer = 0 })
        t.eq(outline.source, "lsp")
        t.eq(outline.symbols[1].name, "outer")
      end)
    end)

    t.it("falls back to the heuristic and records why", function()
      with_lsp({}, function()
        error("should not be called")
      end, function()
        local outline = Outline.for_file({ path = "/tmp/a.lua", lines = { "function y()" }, buffer = 0 })
        t.eq(outline.source, "heuristic")
        t.eq(outline.symbols[1].name, "y")
        t.matches(outline.note, "documentSymbol", "the fallback reason is kept")
      end)
    end)

    t.it("reports none when neither source works", function()
      with_lsp({}, function()
        error("should not be called")
      end, function()
        local outline = Outline.for_file({ path = "/tmp/a.xyz", lines = { "whatever" }, buffer = nil })
        t.eq(outline.source, "none")
        t.eq(outline.symbols, {})
        t.ok(outline.note and outline.note ~= "")
      end)
    end)

    t.it("works with no buffer at all", function()
      local outline = Outline.for_file({ path = "/tmp/a.lua", lines = { "function y()" } })
      t.eq(outline.source, "heuristic")
    end)
  end)

  t.describe("outline.render", function()
    local function symbol(name, row, end_row, depth)
      return { name = name, kind = "function", row = row, end_row = end_row, depth = depth or 0 }
    end

    t.it("gives line ranges, which is what the model asks for next", function()
      local text = Outline.render({ source = "lsp", symbols = { symbol("run", 5, 20) } }, "src/a.lua")
      t.matches(text, "src/a%.lua")
      t.matches(text, "5%-20")
      t.matches(text, "run")
      t.matches(text, "function")
      t.matches(text, "start_row")
    end)

    t.it("marks a heuristic outline as approximate", function()
      local text = Outline.render({ source = "heuristic", symbols = { symbol("x", 1, 2) } }, "a.lua")
      t.matches(text, "approximate")
    end)

    t.it("marks an lsp outline as exact", function()
      local text = Outline.render({ source = "lsp", symbols = { symbol("x", 1, 2) } }, "a.lua")
      t.eq(text:find("approximate", 1, true), nil)
    end)

    t.it("indents nested symbols", function()
      local text = Outline.render({ source = "lsp", symbols = { symbol("inner", 3, 4, 1) } }, "a.lua")
      t.matches(text, "    inner")
    end)

    t.it("caps the number of symbols", function()
      local symbols = {}
      for index = 1, 10 do
        symbols[index] = symbol("s" .. index, index, index)
      end
      local text = Outline.render({ source = "lsp", symbols = symbols, max_symbols = 3 }, "a.lua")
      t.matches(text, "7 more symbols suppressed")
    end)

    t.it("explains when there is no outline", function()
      local text = Outline.render(
        { source = "none", symbols = {}, note = "no outline support for .xyz files" },
        "a.xyz"
      )
      t.matches(text, "no outline available")
      t.matches(text, "%.xyz")
    end)
  end)
end
