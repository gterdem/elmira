local helper = require("tests.helper")

-- Elmira/Core/Ticker.lua — the recompute-throttle decision, per docs/01 §7 (see the file's own
-- header comment for the policy). PURE: fed injected `now`, never GetTime.

describe("Core.Ticker", function()
  local Ticker

  before_each(function()
    helper.reset()
    Ticker = helper.load("Elmira/Core/Ticker.lua")
  end)

  describe("defaults", function()
    it("MAX_RATE is 0.1 (10 Hz)", function()
      assert.equal(0.1, Ticker.MAX_RATE)
    end)

    it("IDLE_REFRESH is 0.25", function()
      assert.equal(0.25, Ticker.IDLE_REFRESH)
    end)

    it("new() with no args uses the module defaults", function()
      local t = Ticker.new()
      assert.is_true(t:shouldRun(0))
      -- rate cap should now be governed by MAX_RATE = 0.1
      t:markDirty()
      assert.is_false(t:shouldRun(0.05))
      assert.is_true(t:shouldRun(0.1))
    end)
  end)

  describe("shouldRun", function()
    it("always runs on the first call, at any `now`", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_true(t:shouldRun(42.7))
    end)

    it("caps at maxRate: dirty but under the cap since the last run is false", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_true(t:shouldRun(0))
      t:markDirty()
      assert.is_false(t:shouldRun(0.05))
    end)

    it("dirty at (or past) the cap runs", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_true(t:shouldRun(0))
      t:markDirty()
      assert.is_true(t:shouldRun(0.1))
    end)

    it("clean coasts under idleRefresh even past the rate cap", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_true(t:shouldRun(0)) -- clears dirty
      -- not dirty, 0.2s elapsed: past maxRate (0.1) but under idleRefresh (0.25)
      assert.is_false(t:shouldRun(0.2))
    end)

    it("clean but past idleRefresh runs anyway (idle backstop)", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_true(t:shouldRun(0)) -- clears dirty
      assert.is_true(t:shouldRun(0.25))
    end)

    it("a true return clears dirty and records lastRun, so back-to-back calls at the same `now` do not both return true", function()
      local t = Ticker.new(0.1, 0.25)
      t:markDirty()
      assert.is_true(t:shouldRun(5))
      assert.is_false(t:shouldRun(5))
    end)

    it("clock going backwards runs immediately rather than wedging", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_true(t:shouldRun(10))
      -- now jumps backwards (reload/timer reset); not dirty, but treated as if no prior run
      assert.is_true(t:shouldRun(1))
    end)

    it("a non-number `now` returns false without erroring", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_false(t:shouldRun(nil))
      assert.is_false(t:shouldRun("later"))
    end)
  end)

  describe("markDirty", function()
    it("is a cheap flag set: calling it alone does not run anything or touch stats", function()
      local t = Ticker.new(0.1, 0.25)
      t:markDirty()
      t:markDirty()
      local s = t:stats()
      assert.equal(0, s.runs)
      assert.equal(0, s.skipped)
      assert.is_true(s.dirty)
    end)
  end)

  describe("stats / resetStats", function()
    it("every false shouldRun increments skipped, every true increments runs", function()
      local t = Ticker.new(0.1, 0.25)
      assert.is_true(t:shouldRun(0))   -- runs = 1
      assert.is_false(t:shouldRun(0.05)) -- skipped = 1 (under cap)
      local s = t:stats()
      assert.equal(1, s.runs)
      assert.equal(1, s.skipped)
    end)

    it("resetStats zeroes runs/skipped but not dirty or lastRun", function()
      local t = Ticker.new(0.1, 0.25)
      t:shouldRun(0)     -- runs=1, lastRun=0
      t:markDirty()      -- dirty=true
      t:resetStats()
      local s = t:stats()
      assert.equal(0, s.runs)
      assert.equal(0, s.skipped)
      assert.is_true(s.dirty)
      assert.equal(0, s.lastRun)
    end)

    it("resetStats does not change subsequent shouldRun behaviour", function()
      local t = Ticker.new(0.1, 0.25)
      t:shouldRun(0)
      t:markDirty()
      t:resetStats()
      -- behaviour must be identical to not having reset: dirty + under cap still skips
      assert.is_false(t:shouldRun(0.05))
    end)
  end)

  describe("queuesDiffer", function()
    it("is a module-level pure function, not a method", function()
      assert.equal("function", type(Ticker.queuesDiffer))
    end)

    it("the identical table reference is not different", function()
      local a = { { spell = 1 }, { spell = 2 } }
      assert.is_false(Ticker.queuesDiffer(a, a))
    end)

    it("both nil is not different", function()
      assert.is_false(Ticker.queuesDiffer(nil, nil))
    end)

    it("one nil, one not is different", function()
      local a = { { spell = 1 } }
      assert.is_true(Ticker.queuesDiffer(a, nil))
      assert.is_true(Ticker.queuesDiffer(nil, a))
    end)

    it("different lengths are different", function()
      local a = { { spell = 1 } }
      local b = { { spell = 1 }, { spell = 2 } }
      assert.is_true(Ticker.queuesDiffer(a, b))
    end)

    it("same length, same spell in every slot is not different", function()
      local a = { { spell = 1 }, { spell = 2 } }
      local b = { { spell = 1 }, { spell = 2 } }
      assert.is_false(Ticker.queuesDiffer(a, b))
    end)

    it("a slot differing only in item is different", function()
      local a = { { spell = 1, item = nil } }
      local b = { { spell = 1, item = 999 } }
      assert.is_true(Ticker.queuesDiffer(a, b))
    end)

    it("a slot differing only in label is different, even with identical spell", function()
      local a = { { spell = 100, label = "Judgement (proc)" } }
      local b = { { spell = 100, label = "Judgement (filler)" } }
      assert.is_true(Ticker.queuesDiffer(a, b))
    end)

    it("does not mutate either argument", function()
      local a = { { spell = 1, label = "x" } }
      local b = { { spell = 2, label = "y" } }
      local aBefore = { spell = a[1].spell, label = a[1].label }
      local bBefore = { spell = b[1].spell, label = b[1].label }
      Ticker.queuesDiffer(a, b)
      assert.equal(aBefore.spell, a[1].spell)
      assert.equal(aBefore.label, a[1].label)
      assert.equal(bBefore.spell, b[1].spell)
      assert.equal(bBefore.label, b[1].label)
      assert.equal(1, #a)
      assert.equal(1, #b)
    end)
  end)
end)
