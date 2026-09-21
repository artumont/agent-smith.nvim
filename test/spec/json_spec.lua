return function(t)
  local Json = require("agent-smith.json")

  t.describe("json.encode: determinism", function()
    t.it("produces identical bytes for the same keys in a different order", function()
      -- The reason this module exists: a prompt cache keys on exact prefix
      -- bytes, so a reordered key is a miss for the whole conversation.
      local first = { name = "read", description = "d", access = "read" }
      local second = { access = "read", description = "d", name = "read" }
      t.eq(Json.encode(first), Json.encode(second))
    end)

    t.it("sorts keys", function()
      t.eq(Json.encode({ zebra = 1, alpha = 2, mike = 3 }), '{"alpha":2,"mike":3,"zebra":1}')
    end)

    t.it("sorts keys in nested objects", function()
      local value = { outer = { zulu = 1, alpha = 2 } }
      t.eq(Json.encode(value), '{"outer":{"alpha":2,"zulu":1}}')
    end)

    t.it("sorts objects inside arrays", function()
      local value = { { z = 1, a = 2 }, { y = 3, b = 4 } }
      t.eq(Json.encode(value), '[{"a":2,"z":1},{"b":4,"y":3}]')
    end)

    t.it("leaves array order alone", function()
      -- Sorting arrays would reorder messages and tool results.
      t.eq(Json.encode({ "c", "a", "b" }), '["c","a","b"]')
    end)

    t.it("repeated calls agree", function()
      local value = { b = { d = 1, c = 2 }, a = 3 }
      t.eq(Json.encode(value), Json.encode(value))
    end)
  end)

  t.describe("json.encode: empty tables", function()
    t.it("keeps Neovim's convention for a bare empty table", function()
      -- Bare {} is a list as far as Neovim is concerned. Callers that mean an
      -- object have to say so.
      t.eq(Json.encode({}), "[]")
    end)

    t.it("honours vim.empty_dict", function()
      t.eq(Json.encode(vim.empty_dict()), "{}")
    end)

    t.it("keeps a marked empty object nested inside a structure", function()
      t.eq(Json.encode({ properties = vim.empty_dict() }), '{"properties":{}}')
    end)
  end)

  t.describe("json.encode_object", function()
    t.it("encodes an empty table as an object", function()
      -- The bug this fixes: tool arguments for a no-argument tool were being
      -- sent as "[]" where a vendor parses an object.
      t.eq(Json.encode_object({}), "{}")
    end)

    t.it("encodes a populated table normally", function()
      t.eq(Json.encode_object({ path = "/a.lua" }), '{"path":"/a.lua"}')
    end)

    t.it("encodes a non-table as an empty object", function()
      t.eq(Json.encode_object(nil), "{}")
      t.eq(Json.encode_object("nonsense"), "{}")
    end)

    t.it("sorts keys within the object", function()
      t.eq(Json.encode_object({ z = 1, a = 2 }), '{"a":2,"z":1}')
    end)
  end)

  t.describe("json.object", function()
    t.it("marks an empty table", function()
      t.eq(Json.encode(Json.object({})), "{}")
    end)

    t.it("leaves a populated table alone", function()
      t.eq(Json.encode(Json.object({ a = 1 })), '{"a":1}')
    end)

    t.it("leaves an array alone", function()
      t.eq(Json.encode(Json.object({ 1, 2 })), "[1,2]")
    end)
  end)

  t.describe("json.encode: round trip", function()
    t.it("decodes back to what went in", function()
      -- Owning the encoder means owning the escaping. This is the guard against
      -- a quoting bug quietly corrupting every request.
      local values = {
        { text = 'he said "hi"' },
        { text = "back\\slash" },
        { text = "line\nbreak\ttab" },
        { text = "control \1 char" },
        { text = "unicode ünïcödé" },
        { number = 42, negative = -7, float = 1.5 },
        { flag = true, other = false },
        { nested = { { a = 1 }, { b = "two" } } },
        { list = { 1, 2, 3 } },
        { role = "tool", content = "path: 1\n" },
      }

      for _, value in ipairs(values) do
        local encoded = Json.encode(value)
        t.eq(vim.json.decode(encoded), value, "round trip failed for " .. encoded)
      end
    end)

    t.it("escapes what JSON requires", function()
      t.eq(Json.encode({ v = '"' }), '{"v":"\\""}')
      t.eq(Json.encode({ v = "\\" }), '{"v":"\\\\"}')
      t.eq(Json.encode({ v = "\n" }), '{"v":"\\n"}')
      t.eq(Json.encode({ v = "\1" }), '{"v":"\\u0001"}')
    end)

    t.it("writes integral numbers without a decimal point", function()
      t.eq(Json.encode({ n = 42 }), '{"n":42}')
      t.eq(Json.encode({ n = 1.5 }), '{"n":1.5}')
      t.eq(Json.encode({ n = -7 }), '{"n":-7}')
    end)

    t.it("refuses a non-finite number rather than emitting invalid JSON", function()
      t.raises(function()
        Json.encode({ n = math.huge })
      end, "cannot encode")
      t.raises(function()
        Json.encode({ n = 0 / 0 })
      end, "cannot encode")
    end)

    t.it("refuses a non-string object key", function()
      t.raises(function()
        Json.encode({ [1] = "x", [2] = "y", name = "z" })
      end, "keys must be strings")
    end)
  end)
end
