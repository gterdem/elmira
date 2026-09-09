local helper = require("tests.helper")

-- Elmira/Core/AbilitySettings.lua — the per-ability, per-character settings store (AB1-D3/D4).
--
-- The rule this file exists to hold in ONE place: inheritance covers appearance and choices, and
-- never whether a channel is ON for Screen-edge, Sound, Texture or Announcement. Glow is the
-- exception. Every assertion below is about an observable VALUE coming back out of `effective`,
-- because "the setter ran" is exactly the shape of defect this project keeps shipping.
describe("Core.AbilitySettings", function()
  local A, ns

  before_each(function()
    ns = helper.reset()
    helper.load("Elmira/Core/DB.lua")
    A = helper.load("Elmira/Core/AbilitySettings.lua")
    ns.db = { char = { abilities = {} } }
  end)

  it("stores under db.char.abilities and nowhere else", function()
    assert.equal(ns.db.char.abilities, A.store())
    A.set("EXORCISM", "glow", "style", "PROC")
    assert.equal("PROC", ns.db.char.abilities.EXORCISM.glow.style)
    -- Per CHARACTER: a second character's fresh store answers with the shipped defaults.
    ns.db.char = { abilities = {} }
    assert.equal("PIXEL", A.effective("EXORCISM", "glow").style)
  end)

  it("answers nothing at all before AceDB has handed a character table over", function()
    ns.db = nil
    assert.is_nil(A.store())
    assert.is_false(A.set("EXORCISM", "glow", "style", "PROC"))
    assert.is_false(A.setInherit("EXORCISM", "glow", false))
    assert.is_false(A.clear("EXORCISM"))
    assert.is_false(A.resetChannel("EXORCISM", "glow"))
    -- and reading still answers the shipped default rather than erroring
    assert.equal("PIXEL", A.effective("EXORCISM", "glow").style)
  end)

  -- `"*"` cannot collide with a registry key: Core/Spells.slug maps every non-alphanumeric to `_`.
  it("names the All abilities row '*'", function()
    assert.equal("*", A.ALL)
  end)

  describe("the shipped defaults", function()
    it("ships glow ON and every other channel OFF (ADR-0009 as amended by AB1-D4)", function()
      assert.is_true(A.effective("X", "glow").enabled)
      assert.is_false(A.effective("X", "texture").enabled)
      assert.is_false(A.effective("X", "edge").enabled)
      assert.is_false(A.effective("X", "sound").enabled)
      assert.is_false(A.effective("X", "announce").enabled)
    end)

    it("leaves every glow number to the library, and colours to the brand", function()
      local g = A.effective("X", "glow")
      assert.equal("PIXEL", g.style)
      assert.is_false(g.color)
      assert.is_false(g.particles)
      assert.is_false(g.frequency)
      assert.is_false(g.thickness)
      assert.is_false(g.speed)
    end)

    it("ships the general and edge shapes AB1-D5 and AB2-D1 read", function()
      assert.is_false(A.effective("X", "general").onlyInCombat)
      assert.equal(3, A.effective("X", "general").expiringSeconds)
      assert.equal("left", A.effective("X", "edge").edge)
      assert.equal(0.5, A.effective("X", "edge").intensity)
      assert.is_false(A.effective("X", "edge").color)
      assert.is_false(A.effective("X", "announce").duration)
    end)

    it("ships every sound event silent", function()
      local s = A.effective("X", "sound")
      for _, event in ipairs(A.EVENTS) do assert.equal("None", s[event], event .. " is not silent") end
      assert.same({ "suggested", "ready", "used", "active", "expiring" }, A.EVENTS)
    end)

    it("declares the six channels and the five with an on/off a player can read", function()
      assert.same({ "general", "glow", "texture", "edge", "sound", "announce" }, A.CHANNELS)
      assert.same({ "glow", "texture", "edge", "sound", "announce" }, A.CUE_CHANNELS)
    end)

    it("answers nil for a channel that does not exist", function()
      assert.is_nil(A.effective("X", "nonsense"))
      assert.is_false(A.set("X", "nonsense", "enabled", true))
      assert.is_false(A.setInherit("X", "nonsense", false))
      assert.is_false(A.resetChannel("X", "nonsense"))
    end)

    it("refuses a field the channel does not declare", function()
      assert.is_false(A.set("X", "glow", "wobble", 1))
      assert.is_nil(A.effective("X", "glow").wobble)
      assert.is_true(A.set("X", "glow", "style", "PROC"))
    end)
  end)

  describe("inheritance (AB1-D4)", function()
    it("links every ability to All abilities by default, and never links All to itself", function()
      assert.is_true(A.inherits("EXORCISM", "glow"))
      assert.is_false(A.inherits(A.ALL, "glow"))
    end)

    it("hands an ability the All abilities appearance while it is linked", function()
      A.set(A.ALL, "glow", "style", "AUTOCAST")
      A.set(A.ALL, "glow", "particles", 12)
      assert.equal("AUTOCAST", A.effective("EXORCISM", "glow").style)
      assert.equal(12, A.effective("EXORCISM", "glow").particles)
    end)

    -- The observable AB1-D3 names: one key's value must not be another key's.
    it("gives an unlinked ability its own values, leaving its neighbours alone", function()
      A.set(A.ALL, "glow", "style", "AUTOCAST")
      A.setInherit("EXORCISM", "glow", false)
      A.set("EXORCISM", "glow", "style", "PROC")
      assert.equal("PROC", A.effective("EXORCISM", "glow").style)
      assert.equal("AUTOCAST", A.effective("JUDGEMENT", "glow").style)
      assert.equal("AUTOCAST", A.effective(A.ALL, "glow").style)
    end)

    it("ignores an ability's own appearance again the moment it is relinked", function()
      A.setInherit("EXORCISM", "glow", false)
      A.set("EXORCISM", "glow", "style", "PROC")
      A.setInherit("EXORCISM", "glow", true)
      assert.equal("PIXEL", A.effective("EXORCISM", "glow").style)
      -- and remembers it for when the link is broken again -- unlinking must not lose the choice
      A.setInherit("EXORCISM", "glow", false)
      assert.equal("PROC", A.effective("EXORCISM", "glow").style)
    end)

    it("inherits per CHANNEL, not per ability", function()
      assert.is_true(A.setInherit("EXORCISM", "glow", false))
      assert.is_false(A.inherits("EXORCISM", "glow"))
      assert.is_true(A.inherits("EXORCISM", "sound"))
    end)

    -- ADR-0009's reason: a cue that fires on everything strobes. This is the assertion the decision
    -- asks for by name -- an ability cannot be switched on by the All abilities entry.
    it("never lets All abilities switch a screen-edge, sound, texture or announcement ON", function()
      for _, channel in ipairs({ "edge", "sound", "texture", "announce" }) do
        A.set(A.ALL, channel, "enabled", true)
        assert.is_false(A.effective("EXORCISM", channel).enabled, channel .. " was inherited ON")
      end
    end)

    it("keeps an ability's own on/off for those four even while it is linked", function()
      A.set("EXORCISM", "edge", "enabled", true)
      assert.is_true(A.inherits("EXORCISM", "edge"))
      assert.is_true(A.effective("EXORCISM", "edge").enabled)
      -- ...while the appearance still comes from All abilities
      A.set(A.ALL, "edge", "edge", "right")
      assert.equal("right", A.effective("EXORCISM", "edge").edge)
    end)

    -- Glow is the exception, and the reason is written into the decision: a bar glow on everything
    -- is what this addon already did.
    it("DOES inherit the glow's on/off", function()
      A.set(A.ALL, "glow", "enabled", false)
      assert.is_false(A.effective("EXORCISM", "glow").enabled)
      A.setInherit("EXORCISM", "glow", false)
      assert.is_true(A.effective("EXORCISM", "glow").enabled)
    end)
  end)

  describe("what is on", function()
    it("counts a channel as on only when its switch is on", function()
      assert.is_true(A.channelOn("EXORCISM", "glow"))
      assert.is_false(A.channelOn("EXORCISM", "edge"))
      A.set("EXORCISM", "edge", "enabled", true)
      assert.is_true(A.channelOn("EXORCISM", "edge"))
      assert.is_false(A.channelOn("EXORCISM", "nonsense"))
    end)

    -- AB1-D8: "the tab is on when any event has a sound". Switched on with everything set to None
    -- is a channel that will never make a noise, and the tree must not claim otherwise.
    it("counts sound as on only when some event actually has one", function()
      A.set("EXORCISM", "sound", "enabled", true)
      assert.is_false(A.channelOn("EXORCISM", "sound"))
      A.set(A.ALL, "sound", "expiring", "Chime")
      assert.is_true(A.channelOn("EXORCISM", "sound"))
      A.set(A.ALL, "sound", "expiring", "None")
      assert.is_false(A.channelOn("EXORCISM", "sound"))
    end)

    it("says an ability is configured when anything at all is on", function()
      assert.is_true(A.anyOn("EXORCISM"), "glow ships on for everything")
      A.setInherit("EXORCISM", "glow", false)
      A.set("EXORCISM", "glow", "enabled", false)
      assert.is_false(A.anyOn("EXORCISM"))
      A.set("EXORCISM", "announce", "enabled", true)
      assert.is_true(A.anyOn("EXORCISM"))
    end)

    -- The tracked set (AB1-D5). Glow is deliberately NOT in it: it follows the now-slot the render
    -- loop already computes, and tracking it would put every ability into a 10 Hz cooldown poll.
    it("tracks only the channels Core/Track has to read the state for", function()
      assert.is_false(A.tracked("EXORCISM"), "glow alone must not put an ability in the poll")
      A.set("EXORCISM", "edge", "enabled", true)
      assert.is_true(A.tracked("EXORCISM"))
      A.set("EXORCISM", "edge", "enabled", false)
      A.set("EXORCISM", "announce", "enabled", true)
      assert.is_true(A.tracked("EXORCISM"))
      A.set("EXORCISM", "announce", "enabled", false)
      A.set("EXORCISM", "texture", "enabled", true)
      assert.is_true(A.tracked("EXORCISM"))
    end)
  end)

  describe("clearing", function()
    it("takes an ability's whole settings row away", function()
      A.set("EXORCISM", "glow", "style", "PROC")
      A.set("EXORCISM", "announce", "enabled", true)
      assert.is_true(A.clear("EXORCISM"))
      assert.is_nil(ns.db.char.abilities.EXORCISM)
      assert.equal("PIXEL", A.effective("EXORCISM", "glow").style)
      assert.is_false(A.clear("EXORCISM"), "nothing left to clear")
    end)

    it("puts one channel back to never-chosen, leaving the rest of the row", function()
      A.set(A.ALL, "glow", "style", "PROC")
      A.set(A.ALL, "announce", "duration", true)
      assert.is_true(A.resetChannel(A.ALL, "glow"))
      assert.is_nil(ns.db.char.abilities[A.ALL].glow)
      assert.equal("PIXEL", A.effective(A.ALL, "glow").style)
      assert.is_true(A.effective(A.ALL, "announce").duration)
    end)

    it("still counts as a change when the channel was never written", function()
      local before = A.version()
      assert.is_true(A.resetChannel("EXORCISM", "glow"))
      assert.is_true(A.version() > before)
    end)
  end)

  -- The version counter is how Display/Driver knows its tracked set is stale, without every setter
  -- in the options panel having to remember to say so.
  describe("the version counter", function()
    it("moves on every write and stands still otherwise", function()
      local start = A.version()
      A.set("EXORCISM", "glow", "style", "PROC")
      local afterSet = A.version()
      assert.is_true(afterSet > start)
      assert.equal(afterSet, A.version())
      A.setInherit("EXORCISM", "glow", false)
      assert.is_true(A.version() > afterSet)
      local afterInherit = A.version()
      A.clear("EXORCISM")
      assert.is_true(A.version() > afterInherit)
    end)

    it("does not move for a refused write", function()
      local start = A.version()
      A.set("EXORCISM", "glow", "wobble", 1)
      A.set("EXORCISM", "nonsense", "enabled", true)
      A.clear("NEVER_STORED")
      assert.equal(start, A.version())
    end)
  end)

  -- The effective table is a COPY. Handing out the defaults table itself would let one ability's
  -- edit rewrite what every future ability starts from.
  it("never hands out the defaults table itself", function()
    local one = A.effective("EXORCISM", "glow")
    one.style = "MANGLED"
    assert.equal("PIXEL", A.effective("JUDGEMENT", "glow").style)
    assert.equal("PIXEL", A.DEFAULTS.glow.style)
  end)
end)
