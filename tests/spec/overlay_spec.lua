local helper = require("tests.helper")
local FakeState = dofile("tests/fake_state.lua")

-- Elmira/Display/Overlay.lua — cue gating (ADR-0009). DATA logic only: availableCues(), isEnabled(),
-- SetEnabled(). No frame is ever created in this spec (Overlay.Create()/Flare()/Render() are not
-- under test here).

describe("Display.Overlay", function()
  local Overlay, ns

  -- Stubs the one piece of Driver.lua this module depends on, without dragging in the real
  -- Display/compileBuild/Simulation chain: Overlay only ever reads compiled.visuals.cues.
  local function stubActiveBuild(cues)
    ns.Display = { activeBuild = function() return { visuals = { cues = cues } } end }
  end

  local function stubState(bonuses)
    ns.API = { GetState = function() return FakeState.new{ bonuses = bonuses or {} } end }
  end

  before_each(function()
    ns = helper.reset()
    Overlay = helper.load("Elmira/Display/Overlay.lua")
    ns.db = { profile = { overlay = { cues = {} } } }
    stubActiveBuild({})
    stubState({})
  end)

  describe("availableCues()", function()
    it("returns one entry per cue, preserving event/spell/key/color/edge/reason/requiresBonus", function()
      stubActiveBuild{
        { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left",
          reason = "Exorcism came off cooldown" },
      }
      local cues = Overlay.availableCues()
      assert.equal(1, #cues)
      local c = cues[1]
      assert.equal("now_slot", c.event)
      assert.equal("EXORCISM", c.spell)
      assert.is_nil(c.key)
      assert.same({0.9,0.2,0.2}, c.color)
      assert.equal("left", c.edge)
      assert.equal("Exorcism came off cooldown", c.reason)
      assert.is_nil(c.requiresBonus)
    end)

    it("an empty build cue list yields an empty result, not an error", function()
      stubActiveBuild({})
      assert.same({}, Overlay.availableCues())
    end)

    describe("event = \"check\" cues", function()
      it("always carries an unavailable reason mentioning readiness checks / M5b", function()
        stubActiveBuild{
          { event = "check", key = "SEAL_DROPPED", color = {1,1,1}, edge = "bottom",
            reason = "Seal dropped" },
        }
        local c = Overlay.availableCues()[1]
        assert.is_string(c.unavailable)
        assert.truthy(c.unavailable:lower():find("readiness", 1, true) or c.unavailable:lower():find("check", 1, true))
        assert.truthy(c.unavailable:find("M5b", 1, true))
      end)
    end)

    describe("requiresBonus cues", function()
      local function bonusCue()
        return { event = "now_slot", spell = "DIVINE_STORM", requiresBonus = "HOLY_POWER_CONSUME",
                 reason = "Divine Storm at 3 Holy Power" }
      end

      it("carries an unavailable reason naming the missing bonus when the character lacks it", function()
        stubState({ HOLY_POWER_CONSUME = false })
        stubActiveBuild{ bonusCue() }
        local c = Overlay.availableCues()[1]
        assert.is_string(c.unavailable)
        assert.truthy(c.unavailable:find("HOLY_POWER_CONSUME", 1, true))
      end)

      it("has no unavailable reason once the character has the bonus", function()
        stubState({ HOLY_POWER_CONSUME = true })
        stubActiveBuild{ bonusCue() }
        local c = Overlay.availableCues()[1]
        assert.is_nil(c.unavailable)
      end)
    end)

    it("the check-cue reason and the missing-bonus reason are distinguishable ('not yet' vs 'not for you')", function()
      stubState({ NEEDS_GEAR = false })
      stubActiveBuild{
        { event = "check", key = "SEAL_DROPPED", reason = "Seal dropped" },
        { event = "now_slot", spell = "DIVINE_STORM", requiresBonus = "NEEDS_GEAR", reason = "x" },
      }
      local cues = Overlay.availableCues()
      assert.is_string(cues[1].unavailable)
      assert.is_string(cues[2].unavailable)
      assert.are_not.equal(cues[1].unavailable, cues[2].unavailable)
    end)
  end)

  describe("isEnabled()", function()
    it("the default install is silent: an empty profile.overlay.cues enables nothing", function()
      ns.db.profile.overlay.cues = {}
      local cue = { event = "now_slot", spell = "EXORCISM", color = {1,0,0}, edge = "left" }
      local on = Overlay.isEnabled(cue)
      assert.is_false(on)
    end)

    it("is false for a cue id present but never explicitly enabled to true", function()
      local cue = { event = "now_slot", spell = "EXORCISM" }
      -- Not going through SetEnabled: a raw table with no `enabled` key at all should still read false.
      assert.is_false(Overlay.isEnabled(cue))
    end)
  end)

  describe("SetEnabled() / round trip", function()
    local cue

    before_each(function()
      cue = { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left" }
    end)

    it("enable records enabled=true plus colour/edge/intensity defaulted from the cue", function()
      Overlay.SetEnabled(cue, true)
      local on, setting = Overlay.isEnabled(cue)
      assert.is_true(on)
      assert.same({0.9,0.2,0.2}, setting.color)
      assert.equal("left", setting.edge)
      assert.equal(0.5, setting.intensity)
    end)

    it("enable honours explicit overrides over the cue's own defaults", function()
      Overlay.SetEnabled(cue, true, { color = {0,1,0}, edge = "right", intensity = 0.9, sound = "ping.ogg" })
      local on, setting = Overlay.isEnabled(cue)
      assert.is_true(on)
      assert.same({0,1,0}, setting.color)
      assert.equal("right", setting.edge)
      assert.equal(0.9, setting.intensity)
      assert.equal("ping.ogg", setting.sound)
    end)

    it("a cue with no edge of its own defaults the stored edge to 'left'", function()
      local edgeless = { event = "now_slot", spell = "JUDGEMENT", color = {1,1,1} }
      Overlay.SetEnabled(edgeless, true)
      local _, setting = Overlay.isEnabled(edgeless)
      assert.equal("left", setting.edge)
    end)

    it("disable REMOVES the entry entirely rather than storing enabled=false", function()
      Overlay.SetEnabled(cue, true)
      Overlay.SetEnabled(cue, false)
      local on, setting = Overlay.isEnabled(cue)
      assert.is_false(on)
      assert.is_nil(setting)
      -- Absent, not merely falsy: the underlying table must have no entry at all.
      local count = 0
      for _ in pairs(ns.db.profile.overlay.cues) do count = count + 1 end
      assert.equal(0, count)
    end)

    it("full round trip: enable, read back true, disable, read back false", function()
      assert.is_false(Overlay.isEnabled(cue))
      Overlay.SetEnabled(cue, true)
      assert.is_true(Overlay.isEnabled(cue))
      Overlay.SetEnabled(cue, false)
      assert.is_false(Overlay.isEnabled(cue))
    end)
  end)
end)
