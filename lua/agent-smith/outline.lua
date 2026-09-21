--- Symbol outlines, for reading a file's shape before its contents.
---
--- The point is cost. An outline of a 900-line file is a few hundred bytes where
--- the file is tens of kilobytes, so the model can ask for the two ranges it
--- actually needs instead of the whole thing. The gateways bill a large cached
--- prefix per turn, so a tool result that arrives once and is re-sent every turn
--- afterwards is the expensive kind.
---
--- Two sources, tried in order of fidelity:
---
---   1. **lsp** — `textDocument/documentSymbol` from an attached server. Exact,
---      and free: no embedding model, no index, nothing to go stale.
---   2. **heuristic** — line patterns per language. Crude, and labelled as such
---      in the output so nobody mistakes it for a real parser.
---
--- Deliberately not a vector index. For code, structural retrieval is exact
--- where embeddings are approximate, and the model edits from what `read`
--- returns, so approximation in this path costs correctness.
---
--- Treesitter would be a third source, better than the heuristic and worse than
--- a server that is already running. Left out until it earns its place.

local M = {}

M.DEFAULT_MAX_SYMBOLS = 200

M.LSP_TIMEOUT_MS = 2000

--- LSP SymbolKind numbers, as far as they are worth naming.
local SYMBOL_KINDS = {
  [1] = "file",
  [2] = "module",
  [3] = "namespace",
  [4] = "package",
  [5] = "class",
  [6] = "method",
  [7] = "property",
  [8] = "field",
  [9] = "constructor",
  [10] = "enum",
  [11] = "interface",
  [12] = "function",
  [13] = "variable",
  [14] = "constant",
  [22] = "enum member",
  [23] = "struct",
  [24] = "event",
  [26] = "type parameter",
}

--- Line patterns per language, used only when no server is available.
---
--- One pattern per declaration form, most specific first. These are a fallback
--- and are reported as such, not a parser.
local HEURISTICS = {
  lua = {
    { "^%s*local%s+function%s+([%w_%.:]+)", "function" },
    { "^%s*function%s+([%w_%.:]+)", "function" },
    { "^%s*local%s+([%w_]+)%s*=%s*function", "function" },
    { "^%s*([%w_]+)%s*=%s*function", "function" },
    { "^%s*local%s+([%w_]+)%s*=", "variable" },
  },
  python = {
    { "^%s*async%s+def%s+([%w_]+)", "function" },
    { "^%s*def%s+([%w_]+)", "function" },
    { "^%s*class%s+([%w_]+)", "class" },
  },
  javascript = {
    { "^%s*export%s+default%s+function%s+([%w_$]+)", "function" },
    { "^%s*export%s+function%s+([%w_$]+)", "function" },
    { "^%s*async%s+function%s+([%w_$]+)", "function" },
    { "^%s*function%s+([%w_$]+)", "function" },
    { "^%s*export%s+class%s+([%w_$]+)", "class" },
    { "^%s*class%s+([%w_$]+)", "class" },
    { "^%s*export%s+const%s+([%w_$]+)", "constant" },
    { "^%s*const%s+([%w_$]+)%s*=%s*%(?[%w_$,\\s]*%)?%s*=>", "function" },
  },
  go = {
    { "^func%s+%([^)]*%)%s*([%w_]+)", "method" },
    { "^func%s+([%w_]+)", "function" },
    { "^type%s+([%w_]+)%s+struct", "struct" },
    { "^type%s+([%w_]+)%s+interface", "interface" },
    { "^type%s+([%w_]+)", "type" },
  },
  rust = {
    { "^%s*pub%s+async%s+fn%s+([%w_]+)", "function" },
    { "^%s*pub%s+fn%s+([%w_]+)", "function" },
    { "^%s*async%s+fn%s+([%w_]+)", "function" },
    { "^%s*fn%s+([%w_]+)", "function" },
    { "^%s*pub%s+struct%s+([%w_]+)", "struct" },
    { "^%s*struct%s+([%w_]+)", "struct" },
    { "^%s*pub%s+enum%s+([%w_]+)", "enum" },
    { "^%s*enum%s+([%w_]+)", "enum" },
    { "^%s*impl%s+([%w_<>%s_:]+)", "impl" },
    { "^%s*pub%s+trait%s+([%w_]+)", "trait" },
    { "^%s*trait%s+([%w_]+)", "trait" },
  },
  sh = {
    { "^%s*function%s+([%w_%-]+)", "function" },
    { "^%s*([%w_%-]+)%s*%(%)%s*{", "function" },
  },
}

local EXTENSIONS = {
  lua = "lua",
  py = "python",
  js = "javascript",
  jsx = "javascript",
  mjs = "javascript",
  ts = "javascript",
  tsx = "javascript",
  go = "go",
  rs = "rust",
  sh = "sh",
  bash = "sh",
}

--- Flatten an LSP documentSymbol result.
---
--- Servers answer in one of two shapes: `DocumentSymbol[]`, which nests via
--- `children` and carries `range`, or the older flat `SymbolInformation[]`,
--- which carries `location.range`. Both are handled because which one arrives
--- depends on the server.
local function flatten(result, symbols, depth)
  for _, symbol in ipairs(result) do
    local range = symbol.range or (symbol.location and symbol.location.range)
    if range then
      symbols[#symbols + 1] = {
        name = symbol.name,
        kind = SYMBOL_KINDS[symbol.kind] or ("kind " .. tostring(symbol.kind)),
        row = range.start.line + 1,
        -- `end` is a keyword in Lua, so the field needs indexing syntax.
        end_row = range["end"].line + 1,
        depth = depth,
      }
    end
    if type(symbol.children) == "table" then
      flatten(symbol.children, symbols, depth + 1)
    end
  end
end

--- Symbols from an attached language server, or nil and a reason.
---@return table[]|nil symbols
---@return string|nil reason
function M.from_lsp(buffer)
  if type(buffer) ~= "number" then
    return nil, "no buffer"
  end
  if type(vim.lsp) ~= "table" or type(vim.lsp.buf_request_sync) ~= "function" then
    return nil, "no lsp support"
  end

  local capable = false
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buffer })) do
    if client.server_capabilities and client.server_capabilities.documentSymbolProvider then
      capable = true
      break
    end
  end
  if not capable then
    return nil, "no server provides documentSymbol"
  end

  local requested, responses = pcall(vim.lsp.buf_request_sync, buffer, "textDocument/documentSymbol", {
    textDocument = vim.lsp.util.make_text_document_params(buffer),
  }, M.LSP_TIMEOUT_MS)

  if not requested then
    return nil, "the documentSymbol request failed"
  end
  if type(responses) ~= "table" then
    return nil, "no server answered"
  end

  local symbols = {}
  for _, response in pairs(responses) do
    if type(response.result) == "table" then
      flatten(response.result, symbols, 0)
    end
  end

  if #symbols == 0 then
    return nil, "the server returned no symbols"
  end

  table.sort(symbols, function(left, right)
    return left.row < right.row
  end)
  return symbols
end

--- Symbols guessed from line patterns, or nil and a reason.
---@return table[]|nil symbols
---@return string|nil reason
function M.from_heuristic(path, lines)
  local extension = vim.fn.fnamemodify(path, ":e"):lower()
  local language = EXTENSIONS[extension]
  if not language then
    return nil, ("no outline support for .%s files"):format(extension ~= "" and extension or "unknown")
  end

  local patterns = HEURISTICS[language]
  if not patterns then
    return nil, ("no outline support for %s"):format(language)
  end

  local starts = {}
  for index, line in ipairs(lines) do
    for _, entry in ipairs(patterns) do
      local name = line:match(entry[1])
      if name then
        starts[#starts + 1] = { name = name, kind = entry[2], row = index, depth = 0 }
        break
      end
    end
  end

  if #starts == 0 then
    return nil, "no declarations matched"
  end

  -- A pattern sees where a declaration starts and never where it ends, so the
  -- end is inferred as the line before the next one. Approximate, and the
  -- output says so.
  for index, symbol in ipairs(starts) do
    local following = starts[index + 1]
    symbol.end_row = following and (following.row - 1) or #lines
  end

  return starts
end

--- The best outline available for a file.
---
---@param options table
---   - path: string          Used for the extension and for the heuristic.
---   - lines: string[]       File contents, for the heuristic.
---   - buffer: number|nil    A loaded buffer, if there is one. Only a buffer can
---                           have a language server attached.
---@return table outline { source: string, symbols: table[], note: string|nil }
function M.for_file(options)
  assert(type(options) == "table", "outline.for_file needs options")
  assert(type(options.path) == "string", "outline.for_file needs a path")

  local symbols, lsp_reason = M.from_lsp(options.buffer)
  if symbols then
    return { source = "lsp", symbols = symbols }
  end

  local heuristic, heuristic_reason = M.from_heuristic(options.path, options.lines or {})
  if heuristic then
    return { source = "heuristic", symbols = heuristic, note = lsp_reason }
  end

  return {
    source = "none",
    symbols = {},
    note = ("%s; %s"):format(tostring(lsp_reason), tostring(heuristic_reason)),
  }
end

--- Render an outline for a model to read.
---
--- The line ranges are the point: they are what a follow-up `read` asks for.
---@param outline table From for_file.
---@param shown_path string Path as the model should see it.
---@return string
function M.render(outline, shown_path)
  if outline.source == "none" or #outline.symbols == 0 then
    return ("%s: no outline available (%s)"):format(shown_path, outline.note or "unknown reason")
  end

  local max_symbols = outline.max_symbols or M.DEFAULT_MAX_SYMBOLS

  local parts = {
    ("%s — %d symbol(s), via %s%s"):format(
      shown_path,
      #outline.symbols,
      outline.source,
      outline.source == "heuristic" and ", approximate" or ""
    ),
  }

  for index = 1, math.min(#outline.symbols, max_symbols) do
    local symbol = outline.symbols[index]
    parts[#parts + 1] = ("  %d-%d  %s%s (%s)"):format(
      symbol.row,
      symbol.end_row,
      ("  "):rep(symbol.depth or 0),
      symbol.name,
      symbol.kind
    )
  end

  if #outline.symbols > max_symbols then
    parts[#parts + 1] = ("  ... [%d more symbols suppressed]"):format(#outline.symbols - max_symbols)
  end

  parts[#parts + 1] = "Read a line range with start_row and end_row."

  return table.concat(parts, "\n")
end

return M
