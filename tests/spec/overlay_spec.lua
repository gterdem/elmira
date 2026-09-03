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

  describe("EDGES", function()
    it("lists the four screen edges Overlay can actually draw", function()
      assert.same({ "left", "right", "top", "bottom" }, Overlay.EDGES)
    end)
  end)

  -- SetOption() validates `edge` (covered above), but SetEnabled() has its own inline use of the
  -- same validEdge() guard (`setting.edge = validEdge(edge) and edge or "left"`) — a second call
  -- site that could quietly regress to `setting.edge = edge` while SetOption's test stays green.
  -- A build's cue.edge is data a class-pack author writes and never runs through SetOption at all,
  -- so this is the path a bad edge actually arrives on in play.
  describe("SetEnabled() edge validation", function()
    it("a build naming an undrawable edge on the cue itself is not stored verbatim -- it falls back to 'left'", function()
      local cue = { event = "now_slot", spell = "EXORCISM", color = {1,0,0}, edge = "middle" }
      Overlay.SetEnabled(cue, true)
      local _, setting = Overlay.isEnabled(cue)
      assert.are_not.equal("middle", setting.edge)
      assert.equal("left", setting.edge)
    end)

    it("an undrawable edge passed via opts.edge is not stored verbatim either -- it falls back to 'left'", function()
      local cue = { event = "now_slot", spell = "EXORCISM", color = {1,0,0}, edge = "left" }
      Overlay.SetEnabled(cue, true, { edge = "middle" })
      local _, setting = Overlay.isEnabled(cue)
      assert.are_not.equal("middle", setting.edge)
      assert.equal("left", setting.edge)
    end)

    -- The fallback must not swallow good data: every edge Overlay can actually draw must survive
    -- SetEnabled unchanged, driven off Overlay.EDGES so a future edge cannot leave this stale.
    it("a valid edge named by the build is stored as-is, for every edge Overlay actually knows", function()
      for _, e in ipairs(Overlay.EDGES) do
        local cue = { event = "now_slot", spell = "EXORCISM_" .. e, color = {1,0,0}, edge = e }
        Overlay.SetEnabled(cue, true)
        local _, setting = Overlay.isEnabled(cue)
        assert.equal(e, setting.edge)
      end
    end)

    it("a valid edge passed via opts.edge is stored as-is, for every edge Overlay actually knows", function()
      for _, e in ipairs(Overlay.EDGES) do
        local cue = { event = "now_slot", spell = "EXORCISM_OPT_" .. e, color = {1,0,0}, edge = "left" }
        Overlay.SetEnabled(cue, true, { edge = e })
        local _, setting = Overlay.isEnabled(cue)
        assert.equal(e, setting.edge)
      end
    end)
  end)

  describe("SetOption() / GetOption() — per-cue appearance (colour/edge/intensity)", function()
    local cue

    before_each(function()
      cue = { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left" }
      -- The real module, not a stubbed colour table: a wrong HIGHLIGHT constant here must fail the
      -- fallback test below, not pass it.
      helper.load("Elmira/Core/Colors.lua")
    end)

    describe("SetOption()", function()
      it("refuses to write for a cue that is not enabled, and leaves no record behind", function()
        local ok = Overlay.SetOption(cue, "color", {0,1,0})
        assert.is_false(ok)
        local on, setting = Overlay.isEnabled(cue)
        assert.is_false(on)
        assert.is_nil(setting)
      end)

      it("writes for a cue that is enabled", function()
        Overlay.SetEnabled(cue, true)
        local ok = Overlay.SetOption(cue, "color", {0,1,0})
        assert.is_true(ok)
        local _, setting = Overlay.isEnabled(cue)
        assert.same({0,1,0}, setting.color)
      end)

      it("refuses an unknown key even for an enabled cue", function()
        Overlay.SetEnabled(cue, true)
        local ok = Overlay.SetOption(cue, "bogus", "x")
        assert.is_false(ok)
        local _, setting = Overlay.isEnabled(cue)
        assert.is_nil(setting.bogus)
      end)

      -- An edge Flare cannot draw makes the cue silently never appear -- the exact failure this
      -- module was just fixed for. Driven off Overlay.EDGES itself so a future edge cannot leave
      -- this test asserting a stale set.
      it("refuses an edge value Flare cannot draw, and writes nothing", function()
        Overlay.SetEnabled(cue, true)
        local ok = Overlay.SetOption(cue, "edge", "diagonal")
        assert.is_false(ok)
        local _, setting = Overlay.isEnabled(cue)
        -- unaffected: still whatever SetEnabled seeded it with, never "diagonal"
        assert.are_not.equal("diagonal", setting.edge)
        assert.equal("left", setting.edge)
      end)

      it("accepts every edge Overlay actually knows how to draw", function()
        Overlay.SetEnabled(cue, true)
        for _, e in ipairs(Overlay.EDGES) do
          local ok = Overlay.SetOption(cue, "edge", e)
          assert.is_true(ok)
          local _, setting = Overlay.isEnabled(cue)
          assert.equal(e, setting.edge)
        end
      end)

      -- The validity flag must be re-derived on every call, not remembered from the last one: a
      -- valid edge accepted a moment ago must not leave the NEXT, invalid edge waved through.
      it("rejects an invalid edge even right after a valid one was accepted", function()
        Overlay.SetEnabled(cue, true)
        assert.is_true(Overlay.SetOption(cue, "edge", "right"))
        local ok = Overlay.SetOption(cue, "edge", "diagonal")
        assert.is_false(ok)
        local _, setting = Overlay.isEnabled(cue)
        assert.equal("right", setting.edge) -- unaffected by the rejected write
      end)
    end)

    describe("GetOption()", function()
      it("returns the BUILD's colour/edge before any customising", function()
        assert.same({0.9,0.2,0.2}, Overlay.GetOption(cue, "color"))
        assert.equal("left", Overlay.GetOption(cue, "edge"))
      end)

      it("returns the shipped default intensity (0.5) when nothing is stored", function()
        assert.equal(0.5, Overlay.GetOption(cue, "intensity"))
      end)

      it("falls back to 'left' for edge when the cue itself has none and nothing is stored", function()
        local edgeless = { event = "now_slot", spell = "JUDGEMENT", color = {1,1,1} }
        assert.equal("left", Overlay.GetOption(edgeless, "edge"))
      end)

      it("returns the stored override once the cue has been customised, not the build's default", function()
        Overlay.SetEnabled(cue, true)
        Overlay.SetOption(cue, "color", {0.1,0.2,0.3})
        Overlay.SetOption(cue, "edge", "right")
        Overlay.SetOption(cue, "intensity", 0.9)
        assert.same({0.1,0.2,0.3}, Overlay.GetOption(cue, "color"))
        assert.are_not.same(cue.color, Overlay.GetOption(cue, "color"))
        assert.equal("right", Overlay.GetOption(cue, "edge"))
        assert.equal(0.9, Overlay.GetOption(cue, "intensity"))
        assert.are_not.equal(0.5, Overlay.GetOption(cue, "intensity"))
      end)

      -- Flare falls back to Colors.HIGHLIGHT for a cue whose build names no colour (see Flare()); the
      -- swatch must promise the colour it will actually flare in, not a white default that the picker
      -- would then silently store over the real fallback.
      describe("colour fallback to Colors.HIGHLIGHT", function()
        it("returns HIGHLIGHT's rgb for a cue with no colour of its own -- not nil, not white", function()
          local colorless = { event = "now_slot", spell = "JUDGEMENT", edge = "left" }
          local c = Overlay.GetOption(colorless, "color")
          assert.is_not_nil(c)
          assert.are_not.same({1, 1, 1}, c)
          assert.same({ns.Colors.HIGHLIGHT.r, ns.Colors.HIGHLIGHT.g, ns.Colors.HIGHLIGHT.b}, c)
        end)

        it("still returns the cue's own colour when the build named one", function()
          assert.same({0.9, 0.2, 0.2}, Overlay.GetOption(cue, "color"))
        end)

        it("a stored override still wins over the HIGHLIGHT fallback", function()
          local colorless = { event = "now_slot", spell = "JUDGEMENT", edge = "left" }
          Overlay.SetEnabled(colorless, true)
          Overlay.SetOption(colorless, "color", {0.4, 0.5, 0.6})
          assert.same({0.4, 0.5, 0.6}, Overlay.GetOption(colorless, "color"))
        end)
      end)
    end)
  end)

  describe("Render() while the display is hidden", function()
    it("fires no cue when the driver says hidden, even with a queue", function()
      local flared = {}
      -- Records a table, not the edge: this cue's stored setting has no edge, and
      -- `flared[#flared+1] = nil` would leave the list empty however many times it fired.
      Overlay.Flare = function(edge) flared[#flared + 1] = { edge = edge } end
      stubActiveBuild{
        { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left",
          reason = "Exorcism came off cooldown" },
      }
      ns.db.profile.overlay.cues = { ["now_slot:EXORCISM"] = { enabled = true } }
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", false)
      assert.equal(0, #flared)
      -- and the memory is cleared, so it fires on the way back rather than being swallowed
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)
    end)
  end)

  describe("Render() — cue firing (change-only semantics, ADR-0009)", function()
    local flared, cue

    before_each(function()
      flared = {}
      -- Records a table, not the bare edge: an edge of nil (unset) would leave `flared[#flared+1]`
      -- appending nothing, and the list would stay empty however many times Flare actually ran.
      Overlay.Flare = function(edge, color, intensity)
        flared[#flared + 1] = { edge = edge, color = color, intensity = intensity }
      end
      -- A fixed clock so `firedAt` assertions can distinguish "never fired" (nil) from "fired at 0"
      -- (a falsy-looking but real timestamp) instead of accidentally relying on the latter.
      ns.now = function() return 42 end
      cue = { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left",
              reason = "Exorcism came off cooldown" }
      stubActiveBuild{ cue }
    end)

    it("flares exactly once when the now-slot changes to an opted-in spell", function()
      Overlay.SetEnabled(cue, true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)
    end)

    it("does not strobe: re-rendering the same now-slot repeatedly flares only once", function()
      Overlay.SetEnabled(cue, true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)
    end)

    it("regression: enabling a cue while its spell is ALREADY the top suggestion still flares", function()
      -- The cue starts OFF. The spell is already the now-slot when the player opts in mid-fight --
      -- the normal case, and exactly the scenario that went silent before the fix.
      local queue = { { spell = "EXORCISM" } }
      Overlay.Render(queue, "PALADIN_EXODIN", true)   -- advances lastNow to EXORCISM; cue is off, no flare
      assert.equal(0, #flared)

      Overlay.SetEnabled(cue, true)
      Overlay.Render(queue, "PALADIN_EXODIN", true)   -- same now-slot as before, cue now on
      assert.equal(1, #flared)
    end)

    it("disabling then re-enabling a cue later re-arms it for the same now-slot", function()
      local queue = { { spell = "EXORCISM" } }
      Overlay.SetEnabled(cue, true)
      Overlay.Render(queue, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)

      Overlay.SetEnabled(cue, false)
      Overlay.Render(queue, "PALADIN_EXODIN", true)   -- still off: no flare
      assert.equal(1, #flared)

      Overlay.SetEnabled(cue, true)
      Overlay.Render(queue, "PALADIN_EXODIN", true)   -- re-enabled, same now-slot: must fire again
      assert.equal(2, #flared)
    end)

    it("toggling a DIFFERENT cue does not re-arm this one", function()
      -- The re-arm inside SetEnabled is conditional on the toggled cue's spell being the current
      -- now-slot. Forgetting the now-slot unconditionally would flash this cue's edge again every
      -- time the user ticked any other row in the options.
      local other = { event = "now_slot", spell = "DIVINE_STORM", edge = "right",
                      reason = "Divine Storm at 3 Holy Power" }
      stubActiveBuild{ cue, other }
      Overlay.SetEnabled(cue, true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)

      -- Exorcism is still the now-slot; the user ticks the unrelated Divine Storm row.
      Overlay.SetEnabled(other, true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)
    end)

    it("a build-key change re-arms the cue for the same now-slot", function()
      local queue = { { spell = "EXORCISM" } }
      Overlay.SetEnabled(cue, true)
      Overlay.Render(queue, "PALADIN_EXODIN_A", true)
      assert.equal(1, #flared)

      Overlay.Render(queue, "PALADIN_EXODIN_A", true)  -- same build, same now-slot: no re-fire
      assert.equal(1, #flared)

      Overlay.Render(queue, "PALADIN_EXODIN_B", true)  -- different build: re-arms
      assert.equal(2, #flared)
    end)

    it("a nil key (the hidden path) is not a build change and does not disturb the remembered key", function()
      local queue = { { spell = "EXORCISM" } }
      Overlay.SetEnabled(cue, true)
      Overlay.Render(queue, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)

      -- nil key must not be mistaken for "no build yet" and must not re-arm the cue on its own.
      Overlay.Render(queue, nil, true)
      assert.equal(1, #flared)

      -- the remembered key must still be PALADIN_EXODIN: rendering it again is not a build change.
      Overlay.Render(queue, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)
    end)

    it("a check-event cue never flares even when its id is enabled in the profile", function()
      local checkCue = { event = "check", key = "SEAL_DROPPED", color = {1,1,1}, edge = "bottom",
                          reason = "Seal dropped" }
      stubActiveBuild{ checkCue }
      Overlay.SetEnabled(checkCue, true)
      Overlay.Render({ { spell = "SEAL_DROPPED" } }, "PALADIN_EXODIN", true)
      assert.equal(0, #flared)
    end)

    it("a requiresBonus cue the character lacks never flares even when enabled in the profile", function()
      stubState({ HOLY_POWER_CONSUME = false })
      local bonusCue = { event = "now_slot", spell = "DIVINE_STORM", requiresBonus = "HOLY_POWER_CONSUME",
                          reason = "Divine Storm at 3 Holy Power" }
      stubActiveBuild{ bonusCue }
      Overlay.SetEnabled(bonusCue, true)
      Overlay.Render({ { spell = "DIVINE_STORM" } }, "PALADIN_EXODIN", true)
      assert.equal(0, #flared)
    end)
  end)

  describe("describe()", function()
    local flared, exoCue, dsCue

    before_each(function()
      flared = {}
      Overlay.Flare = function(edge, color, intensity)
        flared[#flared + 1] = { edge = edge, color = color, intensity = intensity }
      end
      ns.now = function() return 42 end
      exoCue = { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left",
                 reason = "Exorcism came off cooldown" }
      dsCue = { event = "now_slot", spell = "DIVINE_STORM", requiresBonus = "HOLY_POWER_CONSUME",
                reason = "Divine Storm at 3 Holy Power" }
      stubState({ HOLY_POWER_CONSUME = false })
      stubActiveBuild{ exoCue, dsCue }
    end)

    it("reports enabled/unavailable/matchesNow/firedAt correctly before anything has fired", function()
      Overlay.SetEnabled(exoCue, true)
      -- dsCue left disabled AND unavailable (missing bonus), on purpose: both facts are independent.
      local d = Overlay.describe()
      assert.is_nil(d.nowSlot)
      assert.is_nil(d.buildKey)

      local exo, ds
      for _, c in ipairs(d.cues) do
        if c.id == "now_slot:EXORCISM" then exo = c end
        if c.id == "now_slot:DIVINE_STORM" then ds = c end
      end
      assert.is_true(exo.enabled)
      assert.is_nil(exo.unavailable)
      assert.is_false(exo.matchesNow)   -- nothing is the now-slot yet
      assert.is_nil(exo.firedAt)

      assert.is_false(ds.enabled)
      assert.is_string(ds.unavailable)
      assert.is_false(ds.matchesNow)
      assert.is_nil(ds.firedAt)
    end)

    it("a flare with no clock yet records nothing, so it reads as never rather than 0s ago", function()
      -- Core/Slash.lua defines ns.now() unconditionally and returns 0 until state exists, so guarding
      -- on the FUNCTION existing would never be false -- the same shape of guard that once stamped
      -- every recorder mark with 0. What matters is the VALUE: a real reading comes from GetTime()
      -- and is never 0, so 0 means "no clock" and must not be recorded as a timestamp.
      ns.now = function() return 0 end
      local cue = { event = "now_slot", spell = "EXORCISM", edge = "left", reason = "Exo" }
      stubActiveBuild{ cue }
      Overlay.Flare = function() end
      Overlay.SetEnabled(cue, true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.is_nil(Overlay.describe().cues[1].firedAt)
    end)

    it("reports firedAt and matchesNow correctly once a cue has flared", function()
      Overlay.SetEnabled(exoCue, true)
      Overlay.Render({ { spell = "EXORCISM" } }, "PALADIN_EXODIN", true)
      assert.equal(1, #flared)

      local d = Overlay.describe()
      assert.equal("EXORCISM", d.nowSlot)
      assert.equal("PALADIN_EXODIN", d.buildKey)

      local exo, ds
      for _, c in ipairs(d.cues) do
        if c.id == "now_slot:EXORCISM" then exo = c end
        if c.id == "now_slot:DIVINE_STORM" then ds = c end
      end
      assert.is_true(exo.matchesNow)
      assert.equal(42, exo.firedAt)
      -- ds never fired (unavailable) and its spell never matched the now-slot either.
      assert.is_nil(ds.firedAt)
      assert.is_false(ds.matchesNow)
    end)

    -- Mutation regression: a user who customises a cue's colour/intensity in the options expects
    -- describe() to report what they CHOSE, not the build's shipped default. Both defaults
    -- (exoCue.color and the 0.5 fallback intensity) are deliberately distinct from the override so
    -- a describe() that silently fell back to the default would be caught.
    it("reports the stored override colour/intensity, not the cue's default, once customised", function()
      Overlay.SetEnabled(exoCue, true, { color = {0.1, 0.2, 0.3}, intensity = 0.77 })
      local d = Overlay.describe()
      local exo
      for _, c in ipairs(d.cues) do
        if c.id == "now_slot:EXORCISM" then exo = c end
      end
      assert.same({0.1, 0.2, 0.3}, exo.color)
      assert.are_not.same(exoCue.color, exo.color)
      assert.equal(0.77, exo.intensity)
      assert.are_not.equal(0.5, exo.intensity)
    end)
  end)

  describe("TestFire()", function()
    local flared, cue

    before_each(function()
      flared = {}
      Overlay.Flare = function(edge, color, intensity)
        flared[#flared + 1] = { edge = edge, color = color, intensity = intensity }
      end
      cue = { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left",
              reason = "Exorcism came off cooldown" }
      stubActiveBuild{ cue }
    end)

    it("fires a disabled cue, because the diagnostic ignores the enabled flag on purpose", function()
      -- Never enabled via SetEnabled.
      local ok, label = Overlay.TestFire(1)
      assert.is_true(ok)
      assert.equal("Exorcism came off cooldown", label)
      assert.equal(1, #flared)
    end)

    it("returns false and a reason for an out-of-range index, without flaring", function()
      local ok, label = Overlay.TestFire(99)
      assert.is_false(ok)
      assert.is_string(label)
      assert.equal(0, #flared)
    end)

    -- Mutation regression: TestFire must flare with the STORED override colour/edge/intensity, not
    -- the cue's shipped default — a user who customised a cue expects the test-fire to show them
    -- what they chose, not the build's canned suggestion.
    it("flares with the stored override colour/edge/intensity, not the cue's default", function()
      Overlay.SetEnabled(cue, true, { color = {0.1, 0.2, 0.3}, edge = "right", intensity = 0.77 })
      local ok = Overlay.TestFire(1)
      assert.is_true(ok)
      assert.equal(1, #flared)
      assert.same({0.1, 0.2, 0.3}, flared[1].color)
      assert.are_not.same(cue.color, flared[1].color)
      assert.equal(0.77, flared[1].intensity)
      assert.equal("right", flared[1].edge)
    end)
  end)
end)
