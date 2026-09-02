local helper = require("tests.helper")

-- Elmira/Core/Colors.lua — the shared palette. PURE: no WoW API.

-- Independent hex->float conversion, used only to *check* the module's own r/g/b against its own
-- hex — never copied from the implementation's literals, so this fails if the two spellings drift.
local function hexToFloats(hex)
  local r = tonumber(hex:sub(1, 2), 16) / 255
  local g = tonumber(hex:sub(3, 4), 16) / 255
  local b = tonumber(hex:sub(5, 6), 16) / 255
  return r, g, b
end

local NAMES = { "BRAND", "HIGHLIGHT", "MUTED", "OK", "WARN", "BAD" }

describe("Core.Colors", function()
  local Colors

  before_each(function()
    helper.reset()
    Colors = helper.load("Elmira/Core/Colors.lua")
  end)

  describe("palette shape", function()
    for _, name in ipairs(NAMES) do
      it(name .. " has r/g/b as 0-1 floats and a 6-char uppercase hex string", function()
        local c = Colors[name]
        assert.is_not_nil(c, name .. " must exist on Colors")
        assert.equal("number", type(c.r))
        assert.equal("number", type(c.g))
        assert.equal("number", type(c.b))
        assert.is_true(c.r >= 0 and c.r <= 1)
        assert.is_true(c.g >= 0 and c.g <= 1)
        assert.is_true(c.b >= 0 and c.b <= 1)
        assert.equal("string", type(c.hex))
        assert.equal(6, #c.hex)
        assert.is_not_nil(c.hex:match("^[0-9A-F]+$"), name .. ".hex must be uppercase hex: got " .. c.hex)
      end)
    end

    for _, name in ipairs(NAMES) do
      it(name .. ": hex, converted to floats, reproduces r/g/b", function()
        local c = Colors[name]
        local r, g, b = hexToFloats(c.hex)
        assert.near(r, c.r, 1e-9)
        assert.near(g, c.g, 1e-9)
        assert.near(b, c.b, 1e-9)
      end)
    end
  end)

  describe("wrap", function()
    it("wraps a colour table's hex in a |cff...|r chat escape", function()
      local out = Colors.wrap(Colors.OK, "hi")
      assert.equal("|cff" .. Colors.OK.hex .. "hi|r", out)
    end)

    it("accepts a raw hex string directly", function()
      local out = Colors.wrap("112233", "hi")
      assert.equal("|cff112233hi|r", out)
    end)

    it("falls back to BRAND when given nil, rather than a malformed escape", function()
      local out = Colors.wrap(nil, "hi")
      assert.equal("|cff" .. Colors.BRAND.hex .. "hi|r", out)
    end)
  end)

  describe("prefix", function()
    it("wraps the literal addon name 'Elmira' in BRAND", function()
      assert.equal(Colors.wrap(Colors.BRAND, "Elmira"), Colors.prefix())
    end)
  end)

  describe("brand identity", function()
    it("BRAND does not match the nearest WoW class colour (Warlock 8787ED)", function()
      assert.is_not.equal("8787ED", Colors.BRAND.hex)
    end)

    it("BRAND does not match Ace's default chat green (33FF99)", function()
      assert.is_not.equal("33FF99", Colors.BRAND.hex)
    end)
  end)
end)
