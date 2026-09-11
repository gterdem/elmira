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
    assert.equal("PROC", A.effective("EXORCISM", "glow").style)
  end)

  it("answers nothing at all before AceDB has handed a character table over", function()
    ns.db = nil
    assert.is_nil(A.store())
    assert.is_false(A.set("EXORCISM", "glow", "style", "PROC"))
    assert.is_false(A.setInherit("EXORCISM", "glow", false))
    assert.is_false(A.clear("EXORCISM"))
    assert.is_false(A.resetChannel("EXORCISM", "glow"))
    -- and reading still answers the shipped default rather than erroring
    assert.equal("PROC", A.effective("EXORCISM", "glow").style)
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

    -- AB3-D1. The size range is the Texture tab's slider; `suggested` and `active` ship ticked so
    -- that switching the tab on does something the first time, and the other three ship off.
    it("ships the texture at 48px, the spell's own icon, and two of the five moments", function()
      local t = A.effective("X", "texture")
      assert.equal("icon", t.source)
      -- AT4-D2: no `shape` field any more -- the shipped shapes are files in the picker like any
      -- other, so there are two sources (the spell's own icon, or a path) and one path field.
      assert.is_nil(t.shape)
      assert.equal("", t.path)
      assert.equal(48, t.size)
      assert.is_false(t.color)
      assert.equal(1, t.alpha)
      -- AB4-D1: no progress swipe until one is asked for. A swipe over a texture that is on screen
      -- for a second and a half is noise, and both fills are meaningless for an ability the tracker
      -- has no cooldown or buff numbers for.
      assert.equal("none", t.fill)
      assert.is_true(t.suggested)
      assert.is_true(t.active)
      assert.is_false(t.ready)
      assert.is_false(t.used)
      assert.is_false(t.expiring)
      -- AT6-D4: the offset from the centre of the screen is the whole of "where". The `place`
      -- field that chose between the indicator row, the centre and a custom spot went with the row.
      assert.is_nil(t.place)
      assert.equal(0, t.x)
      assert.equal(0, t.y)
    end)

    it("leaves every glow number to the library, and colours to the brand", function()
      local g = A.effective("X", "glow")
      assert.equal("PROC", g.style)
      assert.is_false(g.color)
      assert.is_false(g.particles)
      assert.is_false(g.frequency)
      assert.is_false(g.thickness)
      assert.is_false(g.speed)
      -- AT2-D1: ships as the display's own default mode, so nothing about today's screen changes
      -- for a player who never opens the Glow tab's new dropdown.
      assert.equal("combat_or_target", g.show)
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

    -- AB2-D6: GLOW IS NOT A CUE CHANNEL. It ships on for everything, so counting it made every icon
    -- in the tree full colour and every tooltip say "Glow on" -- a mark that is true of every row
    -- marks nothing (owner's first look at AB1).
    it("declares the six channels and the four that count as configured", function()
      assert.same({ "general", "glow", "texture", "edge", "sound", "announce" }, A.CHANNELS)
      assert.same({ "texture", "edge", "sound", "announce" }, A.CUE_CHANNELS)
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
      A.set("EXORCISM", "glow", "style", "PIXEL")
      A.setInherit("EXORCISM", "glow", true)
      assert.equal("PROC", A.effective("EXORCISM", "glow").style)
      -- and remembers it for when the link is broken again -- unlinking must not lose the choice
      A.setInherit("EXORCISM", "glow", false)
      assert.equal("PIXEL", A.effective("EXORCISM", "glow").style)
    end)

    it("inherits per CHANNEL, not per ability", function()
      assert.is_true(A.setInherit("EXORCISM", "glow", false))
      assert.is_false(A.inherits("EXORCISM", "glow"))
      assert.is_true(A.inherits("EXORCISM", "general"))
    end)

    -- AT1-D2: "I don't think anyone will want to set the same texture, screen edge, sound or
    -- announcement for all the abilities" (owner). These four never inherit ANY field any more --
    -- not just the on/off switch AB2-D1/AB1-D4 already refused to inherit.
    it("never inherits anything at all for texture, edge, sound or announce", function()
      for _, channel in ipairs({ "edge", "sound", "texture", "announce" }) do
        assert.is_false(A.inherits("EXORCISM", channel), channel .. " must never inherit")
        assert.is_false(A.inherits(A.ALL, channel))
      end
      -- General and Glow are unaffected: they still fall back to All abilities.
      assert.is_true(A.inherits("EXORCISM", "general"))
      assert.is_true(A.inherits("EXORCISM", "glow"))
    end)

    -- ADR-0009's reason: a cue that fires on everything strobes. This is the assertion the decision
    -- asks for by name -- an ability cannot be switched on by the All abilities entry.
    it("never lets All abilities switch a screen-edge, sound, texture or announcement ON", function()
      for _, channel in ipairs({ "edge", "sound", "texture", "announce" }) do
        A.set(A.ALL, channel, "enabled", true)
        assert.is_false(A.effective("EXORCISM", channel).enabled, channel .. " was inherited ON")
      end
    end)

    -- AB3-D2 as AT1-D2 now makes true of the WHOLE channel: WHERE one texture sits, and everything
    -- else about it, is a fact about that texture alone. An inherited offset would move every other
    -- ability's texture at once, or write to a row nothing reads and move nothing -- and "the
    -- custom Move mode drags that texture alone" is the decision's own wording.
    it("never inherits a texture's placement, offset or appearance", function()
      A.set(A.ALL, "texture", "x", 300)
      A.set(A.ALL, "texture", "y", -200)
      A.set(A.ALL, "texture", "size", 96)
      -- AB4-D1: the fill used to be treated as an appearance CHOICE that inherited; now nothing on
      -- this channel does.
      A.set(A.ALL, "texture", "fill", "cooldown")
      local t = A.effective("EXORCISM", "texture")
      assert.equal(0, t.x)
      assert.equal(0, t.y)
      assert.equal(48, t.size)
      assert.equal("none", t.fill)
      -- ...and an ability's own values hold regardless of what All abilities is set to
      A.set("EXORCISM", "texture", "x", 40)
      A.set("EXORCISM", "texture", "size", 64)
      assert.equal(40, A.effective("EXORCISM", "texture").x)
      assert.equal(64, A.effective("EXORCISM", "texture").size)
    end)

    it("keeps an ability's own on/off for those four, and never its appearance from All abilities", function()
      A.set("EXORCISM", "edge", "enabled", true)
      assert.is_true(A.effective("EXORCISM", "edge").enabled)
      -- All abilities' own edge colour never reaches it any more
      A.set(A.ALL, "edge", "edge", "right")
      assert.equal("left", A.effective("EXORCISM", "edge").edge)
      A.set("EXORCISM", "edge", "edge", "bottom")
      assert.equal("bottom", A.effective("EXORCISM", "edge").edge)
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
      A.set("EXORCISM", "sound", "expiring", "Chime")
      assert.is_true(A.channelOn("EXORCISM", "sound"))
      A.set("EXORCISM", "sound", "expiring", "None")
      assert.is_false(A.channelOn("EXORCISM", "sound"))
    end)

    -- AB2-D6: glow does NOT count, so a fresh character has nothing configured and every icon in
    -- the tree is greyed until they switch something on.
    it("says an ability is configured only once one of the four is on", function()
      assert.is_false(A.anyOn("EXORCISM"), "glow ships on for everything and must not count")
      A.set("EXORCISM", "announce", "enabled", true)
      assert.is_true(A.anyOn("EXORCISM"))
      A.set("EXORCISM", "announce", "enabled", false)
      assert.is_false(A.anyOn("EXORCISM"))
    end)

    -- The tracked set and the mark are now the same question -- every channel worth marking is a
    -- channel Core/Track has to poll for -- and they must not drift apart silently.
    it("tracks exactly what it counts as configured", function()
      assert.equal(A.anyOn("EXORCISM"), A.tracked("EXORCISM"))
      A.set("EXORCISM", "sound", "enabled", true)
      A.set("EXORCISM", "sound", "ready", "Chime")
      assert.is_true(A.tracked("EXORCISM"))
      assert.equal(A.anyOn("EXORCISM"), A.tracked("EXORCISM"))
    end)

    -- The tracked set (AB1-D5). Glow is deliberately NOT in it: it follows the now-slot the render
    -- loop already computes, and tracking it would put every ability into a 10 Hz cooldown poll.
    it("tracks only the channels Core/Track has to read the state for", function()
      assert.is_false(A.tracked("EXORCISM"), "glow alone must not put an ability in the poll")
      A.set("EXORCISM", "glow", "enabled", true)
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
      A.set("EXORCISM", "glow", "style", "PIXEL")
      A.set("EXORCISM", "announce", "enabled", true)
      assert.is_true(A.clear("EXORCISM"))
      assert.is_nil(ns.db.char.abilities.EXORCISM)
      assert.equal("PROC", A.effective("EXORCISM", "glow").style)
      assert.is_false(A.clear("EXORCISM"), "nothing left to clear")
    end)

    it("puts one channel back to never-chosen, leaving the rest of the row", function()
      A.set(A.ALL, "glow", "style", "PIXEL")
      A.set(A.ALL, "announce", "duration", true)
      assert.is_true(A.resetChannel(A.ALL, "glow"))
      assert.is_nil(ns.db.char.abilities[A.ALL].glow)
      assert.equal("PROC", A.effective(A.ALL, "glow").style)
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
    assert.equal("PROC", A.effective("JUDGEMENT", "glow").style)
    assert.equal("PROC", A.DEFAULTS.glow.style)
  end)

  -- AB2-D3: a class pack may say what an ability should do out of the box. The amendment to
  -- ADR-0009 -- still never a global switch, still per ability, but the people who wrote the
  -- rotation may name the two spells worth a flash.
  describe("class-pack defaults", function()
    local function packWith(defaults)
      ns.Display = { currentPack = function()
        return { class = "PALADIN", spells = { EXORCISM = { id = 415073, defaults = defaults } } }
      end }
    end

    it("switches a channel on for a fresh character with nothing stored", function()
      packWith({ edge = { enabled = true, edge = "left", color = { r = 0.9, g = 0.2, b = 0.2 } } })
      local e = A.effective("EXORCISM", "edge")
      assert.is_true(e.enabled)
      assert.equal("left", e.edge)
      assert.same({ r = 0.9, g = 0.2, b = 0.2 }, e.color)
      assert.is_true(A.channelOn("EXORCISM", "edge"))
      assert.is_true(A.anyOn("EXORCISM"))
      -- ...for that ability alone
      assert.is_false(A.effective("JUDGEMENT", "edge").enabled)
    end)

    -- The precedence AB2-D3 names, read from the bottom: shipped, then the pack, then the player.
    -- AT1-D2 removes the All abilities layer from this channel entirely, so an unnamed ability
    -- (JUDGEMENT here) simply gets the shipped default rather than anything set on All abilities.
    it("outranks the shipped default and loses to the ability's own choice", function()
      packWith({ edge = { enabled = true, edge = "left" } })
      A.set(A.ALL, "edge", "edge", "top")
      assert.equal("left", A.effective("EXORCISM", "edge").edge)
      assert.equal("left", A.effective("JUDGEMENT", "edge").edge, "unnamed abilities get the shipped default")
      A.set("EXORCISM", "edge", "edge", "bottom")
      assert.equal("bottom", A.effective("EXORCISM", "edge").edge)
      -- and the player can switch off what the pack switched on
      A.set("EXORCISM", "edge", "enabled", false)
      assert.is_false(A.channelOn("EXORCISM", "edge"))
    end)

    -- Filtered by the channel's own field list, exactly as `set` filters a write from the panel: a
    -- typo in shipped data must be inert, not a field nothing will ever read back.
    it("ignores a field the channel does not declare", function()
      packWith({ edge = { enabled = true, colour = { 1, 1, 1 } } })
      assert.is_nil(A.effective("EXORCISM", "edge").colour)
      assert.is_true(A.effective("EXORCISM", "edge").enabled)
    end)

    it("ignores a defaults block that is not a table of channels", function()
      packWith({ edge = "left" })
      assert.is_false(A.effective("EXORCISM", "edge").enabled)
      packWith(nil)
      assert.is_false(A.effective("EXORCISM", "edge").enabled)
    end)

    -- The standing rule for this pass: nothing may assume a class pack exists.
    it("leaves a class with no shipped pack on the shipped defaults", function()
      ns.Display = nil
      assert.is_false(A.effective("EXORCISM", "edge").enabled)
      ns.Display = { currentPack = function() return nil end }
      assert.is_false(A.effective("EXORCISM", "edge").enabled)
    end)
  end)

  -- AB2-D5. The store is per character, so this is the only way to carry a setup to an alt.
  describe("sharing", function()
    it("exports only what is stored, and copies rather than referencing it", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "color", { r = 1, g = 0, b = 0 })
      A.set(A.ALL, "glow", "style", "PROC")
      local out = A.export(nil)
      assert.is_true(out.EXORCISM.edge.enabled)
      assert.equal("PROC", out["*"].glow.style)
      -- The colour is a TABLE inside the row: a copy that stops at the top level would export a
      -- flash with no colour in it and nobody would notice until it arrived white.
      assert.same({ r = 1, g = 0, b = 0 }, out.EXORCISM.edge.color)
      out.EXORCISM.edge.color.r = 0.5
      assert.equal(1, A.effective("EXORCISM", "edge").color.r, "the store was handed out by reference")
    end)

    it("exports only the keys it was asked for", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("JUDGEMENT", "edge", "enabled", true)
      local out = A.export({ EXORCISM = true })
      assert.is_table(out.EXORCISM)
      assert.is_nil(out.JUDGEMENT)
      assert.is_nil(out["*"], "the All abilities row is not a spell any rotation names")
    end)

    it("round-trips a row through export and import unchanged", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "intensity", 0.8)
      local out = A.export(nil)
      ns.db.char = { abilities = {} }
      assert.equal(1, A.import(out))
      assert.same(out, A.export(nil))
      assert.equal(0.8, A.effective("EXORCISM", "edge").intensity)
      assert.is_false(A.inherits("EXORCISM", "edge"))
    end)

    it("overwrites by key and counts what it wrote", function()
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "intensity", 0.2)
      assert.equal(2, A.import({ EXORCISM = { edge = { intensity = 0.9 } },
                                 JUDGEMENT = { sound = { enabled = true } } }))
      A.setInherit("EXORCISM", "edge", false)
      assert.equal(0.9, A.effective("EXORCISM", "edge").intensity)
      assert.is_true(A.effective("JUDGEMENT", "sound").enabled)
    end)

    -- The one other place values arrive from outside the addon. A string must not be able to write
    -- a channel or a field nothing will ever read back into SavedVariables.
    it("drops channels and fields this addon does not declare", function()
      assert.equal(1, A.import({ EXORCISM = { edge = { enabled = true, wobble = 3 }, nonsense = { x = 1 } } }))
      assert.is_nil(ns.db.char.abilities.EXORCISM.nonsense)
      assert.is_nil(ns.db.char.abilities.EXORCISM.edge.wobble)
      assert.is_true(ns.db.char.abilities.EXORCISM.edge.enabled)
    end)

    -- Display/Driver rebuilds its tracked set when the version moves. An import that wrote rows
    -- without moving it would leave the render loop watching the OLD set until the next click.
    it("moves the version counter for what it wrote, and not for what it did not", function()
      local before = A.version()
      assert.equal(1, A.import({ EXORCISM = { edge = { enabled = true } } }))
      assert.is_true(A.version() > before)
      local after = A.version()
      assert.equal(0, A.import({}))
      assert.equal(after, A.version())
    end)

    it("writes nothing, and counts nothing, for a string with no rows", function()
      local before = A.version()
      assert.equal(0, A.import(nil))
      assert.equal(0, A.import({}))
      assert.equal(before, A.version())
      ns.db = nil
      assert.equal(0, A.import({ EXORCISM = { edge = {} } }))
    end)

    -- What the tree shows for a key this client cannot resolve, and what a re-export puts back.
    it("remembers the spell an imported row came from", function()
      A.import({ MYSTERY = { edge = { enabled = true } } }, { MYSTERY = { id = 999, name = "Mystery" } })
      assert.same({ id = 999, name = "Mystery" }, A.spellInfo("MYSTERY"))
      assert.is_nil(A.spellInfo("EXORCISM"))
      assert.is_nil(A.export(nil).MYSTERY.spell, "the remembered spell is not a channel")
    end)

    -- Sorted, because the tree and `/elm debug cues` both list these and `pairs` has no order at
    -- all. The two keys are chosen so that `pairs` really does return them the other way round --
    -- with alphabetical-by-luck keys, dropping the sort would pass.
    it("lists every key with a row, sorted, without the All abilities one", function()
      A.set("AAA_FIRST", "edge", "enabled", true)
      A.set("ZZZ_LAST", "edge", "enabled", true)
      A.set(A.ALL, "glow", "style", "PROC")
      assert.same({ "AAA_FIRST", "ZZZ_LAST" }, A.keys())
      ns.db = nil
      assert.same({}, A.keys())
    end)
  end)

end)
