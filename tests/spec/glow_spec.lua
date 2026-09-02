local helper = require("tests.helper")

-- Elmira/Display/Glow.lua — argument POSITIONS, not behaviour.
--
-- This spec exists because of a live crash: LibCustomGlow's three starters take their `key` at three
-- different positions, our call sites passed it by counting nils, and the AutoCast one landed the
-- string "Elmira" in `yOffset`. The library then did `yOffset+0.05` and the whole queue renderer
-- died — on a code path that reads, at a glance, exactly like the two correct ones next to it.
--
-- The fake below is the real library's signature written out by name. That is the point: a spec that
-- only checked "the library was called" would have passed against the bug.
describe("Display.Glow", function()
  local Glow, ns, calls

  -- Named parameters, copied from LibCustomGlow-1.0 v25 (DBM's copy, the one that wins LibStub on
  -- the author's install). If a future version reorders these, this spec is where it shows up.
  local function fakeLib()
    local L = {}
    function L.PixelGlow_Start(r, color, N, frequency, length, th, xOffset, yOffset, border, key, frameLevel)
      calls[#calls + 1] = { fn = "PixelGlow_Start", r = r, color = color, N = N, frequency = frequency,
                            length = length, th = th, xOffset = xOffset, yOffset = yOffset,
                            border = border, key = key, frameLevel = frameLevel }
    end
    function L.AutoCastGlow_Start(r, color, N, frequency, scale, xOffset, yOffset, key, frameLevel)
      calls[#calls + 1] = { fn = "AutoCastGlow_Start", r = r, color = color, N = N, frequency = frequency,
                            scale = scale, xOffset = xOffset, yOffset = yOffset, key = key,
                            frameLevel = frameLevel }
    end
    function L.ButtonGlow_Start(r, color, frequency, frameLevel)
      calls[#calls + 1] = { fn = "ButtonGlow_Start", r = r, color = color, frequency = frequency,
                            frameLevel = frameLevel }
    end
    function L.PixelGlow_Stop(r, key) calls[#calls + 1] = { fn = "PixelGlow_Stop", r = r, key = key } end
    function L.AutoCastGlow_Stop(r, key) calls[#calls + 1] = { fn = "AutoCastGlow_Stop", r = r, key = key } end
    function L.ButtonGlow_Stop(r, key) calls[#calls + 1] = { fn = "ButtonGlow_Stop", r = r, key = key } end
    return L
  end

  before_each(function()
    ns = helper.reset()
    calls = {}
    local lib = fakeLib()
    _G.LibStub = function(major) return major == "LibCustomGlow-1.0" and lib or nil end
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/DB.lua")
    Glow = helper.load("Elmira/Display/Glow.lua")
    ns.db = { profile = { glow = { enabled = true, style = "PIXEL", barGlow = false } } }
  end)

  after_each(function() _G.LibStub = nil end)

  -- The frame is only ever an identity here; nothing in Glow reads it.
  local function frame(name) return { name = name or "f" } end

  describe("the key reaches the library's key parameter", function()
    it("PIXEL: 10th argument, and no numeric parameter is polluted", function()
      local f = frame()
      assert.is_true(Glow.Start(f, "PIXEL"))
      local c = calls[1]
      assert.equal("PixelGlow_Start", c.fn)
      assert.equal("Elmira", c.key)
      assert.equal(f, c.r)
      -- Every geometry parameter must be nil so the library applies its own defaults.
      assert.is_nil(c.N); assert.is_nil(c.frequency); assert.is_nil(c.length)
      assert.is_nil(c.th); assert.is_nil(c.xOffset); assert.is_nil(c.yOffset)
      assert.is_nil(c.border); assert.is_nil(c.frameLevel)
    end)

    it("AUTOCAST: 8th argument — the regression that killed the queue renderer in game", function()
      assert.is_true(Glow.Start(frame(), "AUTOCAST"))
      local c = calls[1]
      assert.equal("AutoCastGlow_Start", c.fn)
      assert.equal("Elmira", c.key)
      -- The bug: "Elmira" arrived here and the library did arithmetic on it.
      assert.is_nil(c.yOffset)
      assert.is_nil(c.xOffset); assert.is_nil(c.scale)
      assert.is_nil(c.N); assert.is_nil(c.frequency); assert.is_nil(c.frameLevel)
    end)

    it("BUTTON: the library takes no key, so nothing extra is passed", function()
      assert.is_true(Glow.Start(frame(), "BUTTON"))
      local c = calls[1]
      assert.equal("ButtonGlow_Start", c.fn)
      assert.is_nil(c.frequency)
      assert.is_nil(c.frameLevel)
    end)

    it("every arithmetic parameter the library will use is a number or nil, never a string", function()
      for _, style in ipairs({ "PIXEL", "AUTOCAST", "BUTTON" }) do
        calls = {}
        Glow.Start(frame(style), style)
        for name, value in pairs(calls[1]) do
          if name ~= "fn" and name ~= "key" and name ~= "r" and name ~= "color" then
            assert.is_not_equal("string", type(value),
              style .. " passed a string into '" .. name .. "'")
          end
        end
      end
    end)
  end)

  describe("stopping", function()
    it("stops with the same key it started with, per style", function()
      for _, case in ipairs({ { "PIXEL", "PixelGlow_Stop", "Elmira" },
                              { "AUTOCAST", "AutoCastGlow_Stop", "Elmira" },
                              { "BUTTON", "ButtonGlow_Stop", nil } }) do
        calls = {}
        local f = frame(case[1])
        Glow.Start(f, case[1])
        assert.is_true(Glow.Stop(f))
        local c = calls[#calls]
        assert.equal(case[2], c.fn)
        assert.equal(f, c.r)
        assert.equal(case[3], c.key)
      end
    end)

    it("an unknown style falls back to PIXEL rather than calling nothing", function()
      assert.is_true(Glow.Start(frame(), "NOPE"))
      assert.equal("PixelGlow_Start", calls[1].fn)
    end)
  end)

  describe("idempotence", function()
    it("does not restart a glow that is already in that style", function()
      local f = frame()
      Glow.Start(f, "PIXEL")
      Glow.Start(f, "PIXEL")
      assert.equal(1, #calls)
    end)

    it("switching style stops the old one before starting the new", function()
      local f = frame()
      Glow.Start(f, "PIXEL")
      Glow.Start(f, "AUTOCAST")
      assert.equal("PixelGlow_Start", calls[1].fn)
      assert.equal("PixelGlow_Stop", calls[2].fn)
      assert.equal("AutoCastGlow_Start", calls[3].fn)
    end)
  end)
end)
