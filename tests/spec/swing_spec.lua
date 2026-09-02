local helper = require("tests.helper")

-- Elmira/Adapters/Swing.lua — the swing timer, and specifically the cases where it must answer
-- "I do not know" instead of a number.
--
-- `swing` and `seal_linger` have been compilable conditions since M1 (Core/Schema.lua:246,251) while
-- every adapter returned nil from the accessors behind them: correct code reading a dead member, for
-- two milestones. The risk in fixing that is the opposite failure — a confident wrong number. A
-- swing timer that reports "due now" when it has no data moves the whole rotation, and it does so
-- invisibly, because "due now" is a perfectly plausible answer.
describe("Adapters.Swing", function()
  local Swing, fake

  -- Mirrors the vendored library (v31): a PULL api, `lib:SwingTimerInfo(hand)` returning
  -- speed, expirationTime, lastSwing. Written with named locals so a signature change in the real
  -- library shows up here rather than as a silently nil reading in game.
  local function fakeLib(speed, expires, last)
    return {
      SwingTimerInfo = function(_, hand)
        if hand ~= "mainhand" then return nil end
        return speed, expires, last
      end,
    }
  end

  local function install(lib)
    fake = lib
    _G.LibStub = function(major) return major == "LibClassicSwingTimerAPI" and fake or nil end
  end

  before_each(function()
    helper.reset()
    install(fakeLib(3.0, 100))
    Swing = helper.load("Elmira/Adapters/Swing.lua")
  end)

  after_each(function() _G.LibStub = nil end)

  describe("availability", function()
    it("is available when the library resolves", function()
      assert.is_true(Swing.available())
    end)

    it("is not available when it does not, and answers nil rather than erroring", function()
      install(nil)
      assert.is_false(Swing.available())
      assert.is_nil(Swing.remaining(50))
      assert.is_nil(Swing.speed())
    end)

    it("re-reads LibStub every call, so a late-loading library still works", function()
      install(nil)
      assert.is_false(Swing.available())
      install(fakeLib(3.0, 100))
      assert.is_true(Swing.available())
      assert.equal(50, Swing.remaining(50))
    end)
  end)

  describe("remaining()", function()
    it("is the time to the next swing", function()
      assert.equal(2, Swing.remaining(98))
    end)

    it("subtracts latency in ms, because the player needs to PRESS before the server swings", function()
      assert.equal(1.8, Swing.remaining(98, 200))
    end)

    it("clamps at zero rather than reporting a negative swing", function()
      assert.equal(0, Swing.remaining(100.5))
    end)

    it("is nil when the library has never seen a swing", function()
      install(fakeLib(nil, nil))
      assert.is_nil(Swing.remaining(50))
    end)

    it("is nil for a STALE reading, not zero", function()
      -- The library stops updating out of combat. An expiry a full swing period in the past would
      -- otherwise clamp to 0 and read as "swing is due NOW" — the most damaging wrong answer here.
      assert.is_nil(Swing.remaining(200))
    end)

    it("still answers inside one swing period of the expiry", function()
      assert.equal(0, Swing.remaining(102))
    end)

    it("is nil without a time, and never guesses one", function()
      assert.is_nil(Swing.remaining(nil))
    end)

    it("survives a library that errors or changes its return shape", function()
      install({ SwingTimerInfo = function() error("changed") end })
      assert.is_nil(Swing.remaining(50))
      install({ SwingTimerInfo = function() return "not a number", {} end })
      assert.is_nil(Swing.remaining(50))
    end)
  end)

  describe("describe()", function()
    it("names WHY there is no number, for each of the three ways that happens", function()
      install(nil)
      assert.equal("library not loaded", Swing.describe(50).why)

      install(fakeLib(nil, nil))
      assert.equal("no swing observed yet — attack something", Swing.describe(50).why)

      install(fakeLib(3.0, 100))
      assert.equal("reading is stale (out of combat)", Swing.describe(200).why)
    end)

    it("has no complaint when the reading is good", function()
      local d = Swing.describe(98)
      assert.is_nil(d.why)
      assert.equal(2, d.remaining)
      assert.equal(3.0, d.speed)
      assert.is_true(d.available)
    end)
  end)
end)
