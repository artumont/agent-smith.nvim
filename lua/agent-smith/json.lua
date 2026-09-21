--- Deterministic JSON encoding for wire bodies.
---
--- `vim.json.encode` cannot be made deterministic here. Object key order follows
--- table iteration order, which follows the hash layout, and writing keys in
--- sorted order does not change it: inserting them in order was measured to
--- produce `{"zebra":1,"alpha":2,"mike":3}` anyway. So the object is emitted
--- directly, with keys sorted.
---
--- Why it matters: a prompt cache keys on the exact bytes of the request prefix.
--- A reordered key is a miss for the entire conversation, not a small loss, and
--- the gateways' own usage estimates assume a large cached prefix.
---
--- A second reason to own this: `vim.json.encode({})` produces `[]`, because an
--- empty table is indistinguishable from an empty list. Tool arguments are
--- parsed as an object, so that is a malformed request.
---
--- Empty tables are still ambiguous, and resolving them is the caller's job:
--- `vim.empty_dict()` marks an object, a bare `{}` stays a list, and
--- `encode_object` is for a value that must be an object either way.

local M = {}

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

--- Escape a string for a JSON document.
---
--- Everything below 0x20 has to be escaped; the named escapes are shorter and
--- more readable than \u forms where they exist. Bytes above 0x7f are emitted
--- raw, which is valid UTF-8 JSON.
local function encode_string(value)
  return '"'
    .. value:gsub('[%z\1-\31\\"]', function(character)
      return ESCAPES[character] or ("\\u%04x"):format(character:byte())
    end)
    .. '"'
end

local function encode_number(value)
  if value ~= value or value == math.huge or value == -math.huge then
    error("cannot encode " .. tostring(value) .. " as JSON", 0)
  end
  if math.floor(value) == value and math.abs(value) < 9007199254740992 then
    return ("%.0f"):format(value)
  end
  return ("%.17g"):format(value)
end

--- Whether a table should be emitted as an object.
local function is_object(value)
  if getmetatable(value) then
    -- vim.empty_dict(), or any explicitly marked table.
    return true
  end
  return not vim.islist(value)
end

local encode_value

local function encode_array(value)
  local parts = {}
  for index, item in ipairs(value) do
    parts[index] = encode_value(item)
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function encode_object(value)
  local keys = vim.tbl_keys(value)

  -- Type-check before sorting: a table with mixed keys blows up in table.sort
  -- with "attempt to compare number with string", which says nothing useful.
  for _, key in ipairs(keys) do
    if type(key) ~= "string" then
      error(("JSON object keys must be strings, got %s"):format(type(key)), 0)
    end
  end

  table.sort(keys)

  local parts = {}
  for index, key in ipairs(keys) do
    parts[index] = encode_string(key) .. ":" .. encode_value(value[key])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(value)
  local kind = type(value)

  if value == nil then
    return "null"
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  if kind == "number" then
    return encode_number(value)
  end
  if kind == "string" then
    return encode_string(value)
  end
  if kind == "table" then
    if next(value) == nil then
      return is_object(value) and "{}" or "[]"
    end
    return is_object(value) and encode_object(value) or encode_array(value)
  end

  error(("cannot encode a %s as JSON"):format(kind), 0)
end

--- Encode with object keys in sorted order, so identical data encodes to
--- identical bytes across builds, restarts and insertion orders.
---@return string
function M.encode(value)
  return encode_value(value)
end

--- Encode a table that must be a JSON object, empty or not.
---
--- For values a vendor parses as an object, where `[]` would be malformed. Tool
--- arguments are the case that matters.
---@return string
function M.encode_object(value)
  if type(value) ~= "table" or next(value) == nil then
    return "{}"
  end
  return encode_object(value)
end

--- Mark an empty table as an object rather than a list.
function M.object(value)
  if type(value) == "table" and next(value) == nil then
    return vim.empty_dict()
  end
  return value
end

return M
