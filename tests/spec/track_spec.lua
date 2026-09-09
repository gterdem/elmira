local helper = require("tests.helper")
local FakeState = require("tests.fake_state")

-- Elmira/Core/Track.lua — the per-ability event tracker (AB1-D5).
--
-- Every assertion here is about EDGES. A cooldown that has been at zero for a minute is "ready" on
-- every one of the six hundred ticks it sat there, and a cue that fires on all of them is the
-- strobe ADR-0009 exists to prevent -- so the interesting test is not "it reported ready" but
-- "it reported ready exactly once".
describe("Core.Track", function()
  local Track

  before_each(function()
    helper.reset()
    Track = helper.load("Elmira/Core/Track.lua")
  end)

  local function state(t)
    return FakeState.new(t)
  end

  local function names(events)
    local out = {}
    for _, e in ipairs(events) do out[#out + 1] = e.key .. ":" .. e.event end
    return out
  end

  describe("ready", function()
    -- The decision's own scenario: cooldown 6 -> 0 -> 0 is exactly one `ready`.
    it("fires once when the cooldown reaches zero, and not again while it sits there", function()
      local watched = { { key = "EXORCISM" } }
      local events, prev = Track.tick(state{ cooldowns = { EXORCISM = 6 } }, watched)
      assert.same({}, names(events))

      events, prev = Track.tick(state{ cooldowns = { EXORCISM = 0 } }, watched, prev)
      assert.same({ "EXORCISM:ready" }, names(events))

      events, prev = Track.tick(state{ cooldowns = { EXORCISM = 0 } }, watched, prev)
      assert.same({}, names(events), "a cooldown sitting at 0 fired twice")

      -- ...and it re-arms once the spell goes back on cooldown.
      events, prev = Track.tick(state{ cooldowns = { EXORCISM = 6 } }, watched, prev)
      assert.same({}, names(events))
      events = Track.tick(state{ cooldowns = { EXORCISM = 0 } }, watched, prev)
      assert.same({ "EXORCISM:ready" }, names(events))
    end)

    -- BOTH halves. A spell off cooldown that you cannot afford is not something to tell anyone
    -- about, and reading only the cooldown would fire the moment the mana ran out.
    it("needs the spell to be usable as well as off cooldown", function()
      local watched = { { key = "EXORCISM" } }
      local unusable = { cooldowns = { EXORCISM = 0 }, usable = { EXORCISM = false } }
      local events, prev = Track.tick(state(unusable), watched)
      assert.same({}, names(events))
      events = Track.tick(state{ cooldowns = { EXORCISM = 0 } }, watched, prev)
      assert.same({ "EXORCISM:ready" }, names(events))
    end)

    -- The first tick is a first SIGHTING, not a flood of edges for everything that is ready.
    it("reports a spell that was already ready on the very first tick", function()
      local events = Track.tick(state{}, { { key = "EXORCISM" } })
      assert.same({ "EXORCISM:ready" }, names(events),
        "the first reading is the first thing anything can be compared against")
    end)
  end)

  describe("active and expiring", function()
    it("fires active once when the buff appears, and expiring once when it runs low", function()
      local watched = { { key = "AVENGING_WRATH", expiring = 3 } }
      local events, prev = Track.tick(state{ cooldowns = { AVENGING_WRATH = 9 } }, watched)
      assert.same({}, names(events))

      local up = { cooldowns = { AVENGING_WRATH = 9 },
                   buffs = { AVENGING_WRATH = { remaining = 10 } } }
      events, prev = Track.tick(state(up), watched, prev)
      assert.same({ "AVENGING_WRATH:active" }, names(events))

      up.buffs.AVENGING_WRATH = { remaining = 8 }
      events, prev = Track.tick(state(up), watched, prev)
      assert.same({}, names(events), "an aura merely ticking down is not an event")

      up.buffs.AVENGING_WRATH = { remaining = 2 }
      events, prev = Track.tick(state(up), watched, prev)
      assert.same({ "AVENGING_WRATH:expiring" }, names(events))

      up.buffs.AVENGING_WRATH = { remaining = 1 }
      events = Track.tick(state(up), watched, prev)
      assert.same({}, names(events), "expiring fired on every tick of the window")
    end)

    it("takes the threshold from the watched row, per ability", function()
      local watched = { { key = "A", expiring = 8 }, { key = "B", expiring = 2 } }
      local up = { buffs = { A = { remaining = 5 }, B = { remaining = 5 } }, usable = { A = false, B = false } }
      local events = Track.tick(state(up), watched)
      assert.same({ "A:active", "A:expiring", "B:active" }, names(events))
    end)

    it("falls back to three seconds when the row names no threshold", function()
      local up = { buffs = { A = { remaining = 2.5 } }, usable = { A = false } }
      assert.same({ "A:active", "A:expiring" }, names(Track.tick(state(up), { { key = "A" } })))
      up.buffs.A = { remaining = 3.5 }
      assert.same({ "A:active" }, names(Track.tick(state(up), { { key = "A" } })))
    end)

    -- An aura with no expiry reads zero seconds remaining. Treating that as "not up" would silence
    -- every permanent buff -- seals, auras, the things a paladin most wants to be told about.
    it("counts a buff with no expiry as active, and never as expiring", function()
      local up = { buffs = { SEAL = { remaining = 0 } }, usable = { SEAL = false } }
      assert.same({ "SEAL:active" }, names(Track.tick(state(up), { { key = "SEAL" } })))
    end)

    it("re-arms after the buff drops", function()
      local watched = { { key = "A", expiring = 3 } }
      local up = { buffs = { A = { remaining = 2 } }, usable = { A = false } }
      local _, prev = Track.tick(state(up), watched)
      local events, memory = Track.tick(state{ usable = { A = false } }, watched, prev)
      assert.same({}, names(events))
      events = Track.tick(state(up), watched, memory)
      assert.same({ "A:active", "A:expiring" }, names(events))
    end)
  end)

  -- AB4-D1. The progress fill on an indicator texture is drawn from a START and a LENGTH, and every
  -- number behind it was already being read here to decide `ready`, `active` and `expiring`. What
  -- these prove is that the memory row REPORTS them -- a fill computed from a second pass over the
  -- same abilities would be the same 10 Hz scan twice.
  describe("the numbers behind the booleans", function()
    it("reports how much cooldown is left and how long the whole cooldown is", function()
      local st = state{ cooldowns = { EXORCISM = 4 }, baseCooldown = { EXORCISM = 6 } }
      local _, memory = Track.tick(st, { { key = "EXORCISM" } })
      assert.equal(4, memory.EXORCISM.cooldown)
      assert.equal(6, memory.EXORCISM.cooldownFull)
    end)

    -- `baseCooldown` is observe-and-cache (docs/07 SS9.1: GetSpellBaseCooldown lies on this client),
    -- so off cooldown it answers with whatever was last seen -- which is not a fact about now, and
    -- would draw a full swipe over an ability that is ready to press.
    it("reports no cooldown length at all while the ability is off cooldown", function()
      local st = state{ cooldowns = { EXORCISM = 0 }, baseCooldown = { EXORCISM = 6 } }
      local _, memory = Track.tick(st, { { key = "EXORCISM" } })
      assert.equal(0, memory.EXORCISM.cooldown)
      assert.is_nil(memory.EXORCISM.cooldownFull)
    end)

    it("reports how much of the buff is left and how long it lasts", function()
      local st = state{ buffs = { WRATH = { remaining = 7, duration = 20 } }, usable = { WRATH = false } }
      local _, memory = Track.tick(st, { { key = "WRATH" } })
      assert.equal(7, memory.WRATH.remaining)
      assert.equal(20, memory.WRATH.duration)
    end)

    it("reports no buff numbers for an ability whose buff is not up", function()
      local _, memory = Track.tick(state{ usable = { WRATH = false } }, { { key = "WRATH" } })
      assert.is_false(memory.WRATH.active)
      assert.is_nil(memory.WRATH.remaining)
      assert.is_nil(memory.WRATH.duration)
    end)
  end)

  describe("what it does not do", function()
    it("reports nothing at all for an ability nobody asked it to watch", function()
      local events, prev = Track.tick(state{ cooldowns = {} }, {})
      assert.same({}, names(events))
      assert.same({}, prev)
    end)

    it("forgets an ability that leaves the watched set", function()
      local _, prev = Track.tick(state{}, { { key = "A" } })
      assert.is_not_nil(prev.A)
      local events, memory = Track.tick(state{}, {}, prev)
      assert.same({}, names(events))
      assert.is_nil(memory.A, "a dropped ability kept a stale comparison")
      -- and re-adding it starts clean rather than resuming
      assert.same({ "A:ready" }, names(Track.tick(state{}, { { key = "A" } }, memory)))
    end)

    it("answers empty with no state at all", function()
      local events, prev = Track.tick(nil, { { key = "A" } })
      assert.same({}, names(events))
      assert.same({}, prev)
    end)

    it("survives a nil watched list", function()
      assert.same({}, names((Track.tick(state{}, nil))))
    end)

    -- `suggested` and `used` are not facts about the character's state; Display/Driver emits them
    -- from the now-slot and the cast it already watches for. A Track that invented them would be a
    -- second source of truth for the same event.
    it("never produces suggested or used", function()
      local up = { cooldowns = { A = 0 }, buffs = { A = { remaining = 1 } } }
      for _, e in ipairs(Track.tick(state(up), { { key = "A" } })) do
        assert.is_not.equal("suggested", e.event)
        assert.is_not.equal("used", e.event)
      end
    end)
  end)
end)
