local helper = require("tests.helper")

-- Elmira/Display/Overlay.lua — the screen-edge flash (ADR-0009 as amended 2026-09-09, AB2-D1).
--
-- DATA logic only: no frame is ever created here (`Overlay.Create` is the client's job), so every
-- test replaces `Overlay.Flare` with a recorder and asserts on what it was told to draw. Recording
-- a TABLE per call, never the bare edge: an unset edge would make `flared[#flared+1] = nil` append
-- nothing and the list would stay empty however many times the flash actually fired.
describe("Display.Overlay", function()
  local Overlay, A, ns, flared

  -- The pack: `Spells.merged` is what says which abilities exist, and `spells[key].defaults` is
  -- AB2-D3's per-ability default. Both are optional -- a class with no shipped pack is a normal
  -- state (the standing rule for this pass) and every test that does not name one runs without.
  local function stubPack(spells)
    ns.Display = { currentPack = function() return spells and { class = "PALADIN", spells = spells } end,
                   spellName = function(key) return "Name of " .. key end }
  end

  before_each(function()
    ns = helper.reset()
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/Spells.lua")
    A = helper.load("Elmira/Core/AbilitySettings.lua")
    Overlay = helper.load("Elmira/Display/Overlay.lua")
    ns.db = { char = { spells = {}, abilities = {} } }
    stubPack(nil)
    ns.now = function() return 42 end
    flared = {}
    Overlay.Flare = function(edge, color, intensity)
      flared[#flared + 1] = { edge = edge, color = color, intensity = intensity }
      return true
    end
  end)

  describe("EDGES / EVENTS", function()
    it("lists the four screen edges Overlay can actually draw", function()
      assert.same({ "left", "right", "top", "bottom" }, Overlay.EDGES)
    end)

    -- Two of Core/Track's five, deliberately: a full-screen flash on every buff that ticks down is
    -- the strobe ADR-0009 exists to prevent, and the other three are the Texture tab's (AB3).
    it("offers only the two events a screen edge fires on", function()
      assert.same({ "suggested", "ready" }, Overlay.EVENTS)
    end)
  end)

  describe("Fire()", function()
    it("stays silent for an ability whose screen edge is off -- the default install", function()
      assert.is_false(Overlay.Fire("EXORCISM", "suggested"))
      assert.equal(0, #flared)
    end)

    it("flashes on `suggested` once the ability's own switch is on", function()
      A.set("EXORCISM", "edge", "enabled", true)
      assert.is_true(Overlay.Fire("EXORCISM", "suggested"))
      assert.equal(1, #flared)
      assert.equal("left", flared[1].edge)
      assert.equal(0.5, flared[1].intensity)
    end)

    -- AB2-D1: `ready` ships OFF. A cooldown finishing while you are mid-cast on something else is
    -- exactly the flash people learn to ignore.
    it("does not flash on `ready` until that event is ticked", function()
      A.set("EXORCISM", "edge", "enabled", true)
      assert.is_false(Overlay.Fire("EXORCISM", "ready"))
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "ready", true)
      assert.is_true(Overlay.Fire("EXORCISM", "ready"))
      assert.equal(1, #flared)
    end)

    -- AT1-D2: the edge channel is per-ability only now, All abilities included in what it no
    -- longer reaches -- unticking the ability's OWN `suggested` is what goes quiet.
    it("goes quiet when `suggested` is unticked, without switching the channel off", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("EXORCISM", "edge", "suggested", false)
      assert.is_false(Overlay.Fire("EXORCISM", "suggested"))
      assert.equal(0, #flared)
    end)

    -- The edge channel declares no field for the other three events, so an event this tab does not
    -- offer cannot flash by accident -- not even for an ability with everything switched on.
    it("never flashes for used/active/expiring", function()
      A.set("EXORCISM", "edge", "enabled", true)
      for _, event in ipairs({ "used", "active", "expiring" }) do
        assert.is_false(Overlay.Fire("EXORCISM", event), event .. " flashed")
      end
      assert.equal(0, #flared)
    end)

    it("draws each ability's own edge, colour and intensity", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "edge", "right")
      A.set("EXORCISM", "edge", "color", { r = 0.1, g = 0.2, b = 0.3 })
      A.set("EXORCISM", "edge", "intensity", 0.8)
      A.set("JUDGEMENT", "edge", "enabled", true)
      Overlay.Fire("EXORCISM", "suggested")
      Overlay.Fire("JUDGEMENT", "suggested")
      assert.equal("right", flared[1].edge)
      -- Settings store `{r,g,b}`; Flare takes the positional form. One conversion, here.
      assert.same({ 0.1, 0.2, 0.3 }, flared[1].color)
      assert.equal(0.8, flared[1].intensity)
      assert.equal("left", flared[2].edge)
      assert.is_nil(flared[2].color, "an unset colour must reach Flare as nil, not as an empty table")
    end)

    -- An edge Flare cannot draw would make the flash silently never appear. The dropdown cannot
    -- produce one; a class pack's `defaults` and an imported settings string both can.
    it("falls back to a drawable edge when the stored one is not one", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "edge", "middle")
      assert.is_true(Overlay.Fire("EXORCISM", "suggested"))
      assert.equal("left", flared[1].edge)
    end)

    it("does nothing at all without Core/AbilitySettings", function()
      ns.AbilitySettings = nil
      assert.is_false(Overlay.Fire("EXORCISM", "suggested"))
      assert.equal(0, #flared)
    end)

    -- AB2-D3, the amendment: a pack may ship one ability's flash ON, with its own edge and colour.
    describe("class-pack defaults", function()
      local function packWithExorcism()
        stubPack({
          EXORCISM = { id = 415073, defaults = { reason = "Exorcism came off cooldown",
                       edge = { enabled = true, edge = "left",
                                color = { r = 0.9, g = 0.2, b = 0.2 } } } },
          JUDGEMENT = { id = 20271 },
        })
      end

      it("flashes on a fresh character with nothing stored at all", function()
        packWithExorcism()
        assert.is_true(Overlay.Fire("EXORCISM", "suggested"))
        assert.equal("left", flared[1].edge)
        assert.same({ 0.9, 0.2, 0.2 }, flared[1].color)
        -- and only for the ability the pack named
        assert.is_false(Overlay.Fire("JUDGEMENT", "suggested"))
      end)

      it("still loses to the player's own setting", function()
        packWithExorcism()
        A.set("EXORCISM", "edge", "enabled", false)
        assert.is_false(Overlay.Fire("EXORCISM", "suggested"))
        A.set("EXORCISM", "edge", "enabled", true)
        A.setInherit("EXORCISM", "edge", false)
        A.set("EXORCISM", "edge", "edge", "top")
        Overlay.Fire("EXORCISM", "suggested")
        assert.equal("top", flared[1].edge)
      end)

      it("leaves a class with no shipped pack with every ability silent", function()
        stubPack(nil)
        assert.is_false(Overlay.Fire("EXORCISM", "suggested"))
        assert.equal(0, #flared)
      end)
    end)
  end)

  describe("describe()", function()
    it("says nothing at all when no ability has its screen edge on", function()
      stubPack({ EXORCISM = { id = 415073 } })
      assert.same({}, Overlay.describe().abilities)
    end)

    it("reports the resolved edge, colour, intensity and events of every ability that is on", function()
      stubPack({ EXORCISM = { id = 415073 }, JUDGEMENT = { id = 20271 } })
      A.set("EXORCISM", "edge", "enabled", true)
      local rows = Overlay.describe().abilities
      assert.equal(1, #rows)
      assert.equal("EXORCISM", rows[1].key)
      assert.is_true(rows[1].enabled)
      assert.equal("left", rows[1].edge)
      assert.equal(0.5, rows[1].intensity)
      assert.same({ "suggested" }, rows[1].events)
      assert.is_nil(rows[1].firedAt)
    end)

    -- "On, and firing on nothing" is the one state that looks exactly like a broken renderer.
    it("reports an empty event list for an ability switched on with no moment ticked", function()
      stubPack({ EXORCISM = { id = 415073 } })
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("EXORCISM", "edge", "suggested", false)
      assert.same({}, Overlay.describe().abilities[1].events)
    end)

    it("records when an ability last flashed", function()
      stubPack({ EXORCISM = { id = 415073 } })
      A.set("EXORCISM", "edge", "enabled", true)
      Overlay.Fire("EXORCISM", "suggested")
      assert.equal(42, Overlay.describe().abilities[1].firedAt)
    end)

    -- Core/Slash defines ns.now() unconditionally and returns 0 until a state exists, so guarding on
    -- the FUNCTION would never be false -- the same shape of guard that once stamped every recorder
    -- mark with 0. A real reading is never 0, so 0 means "no clock" and must read as never.
    it("a flash with no clock yet reads as never rather than 0s ago", function()
      stubPack({ EXORCISM = { id = 415073 } })
      ns.now = function() return 0 end
      A.set("EXORCISM", "edge", "enabled", true)
      Overlay.Fire("EXORCISM", "suggested")
      assert.is_nil(Overlay.describe().abilities[1].firedAt)
    end)

    -- Sorted: `pairs` has no order, and a diagnostic that reshuffles between two runs cannot be
    -- compared with itself. The two keys are chosen so `pairs` really does return them the other
    -- way round -- with alphabetical-by-luck keys, dropping the sort would pass.
    it("lists the abilities in a stable order, registry and pack alike", function()
      stubPack({ ZZZ_LAST = { id = 1 } })
      ns.Spells.registerPack(ns.db.char.spells, "AAA_FIRST", 2, "Aaa")
      A.set("ZZZ_LAST", "edge", "enabled", true)
      A.set("AAA_FIRST", "edge", "enabled", true)
      local rows = Overlay.describe().abilities
      assert.equal("AAA_FIRST", rows[1].key)
      assert.equal("ZZZ_LAST", rows[2].key)
    end)

    -- The pack's own abilities are in NO settings store on a fresh character -- their screen edge is
    -- on because the pack ships it that way (AB2-D3). Reading only the settings store here would
    -- make `/elm debug cues` silent about exactly the cues nobody configured and everybody sees.
    it("includes a pack ability that is on by default with nothing stored", function()
      stubPack({ EXORCISM = { id = 415073, defaults = { edge = { enabled = true } } } })
      assert.same({}, ns.db.char.abilities)
      local rows = Overlay.describe().abilities
      assert.equal(1, #rows)
      assert.equal("EXORCISM", rows[1].key)
    end)

    it("reads a pack's own spells when the registry merge is not loaded", function()
      stubPack({ EXORCISM = { id = 415073, defaults = { edge = { enabled = true } } } })
      ns.Spells = nil
      assert.equal("EXORCISM", Overlay.describe().abilities[1].key)
    end)

    -- An imported settings row for a spell this client cannot resolve is in no registry and no
    -- pack, and `/elm debug cues` staying silent about it is how "I imported settings and nothing
    -- happens" becomes unanswerable.
    it("includes a settings-only key that belongs to no pack and no registry", function()
      A.import({ MYSTERY = { edge = { enabled = true } } })
      assert.equal("MYSTERY", Overlay.describe().abilities[1].key)
    end)

    it("answers an empty list without Core/AbilitySettings, even with a pack loaded", function()
      stubPack({ EXORCISM = { id = 415073, defaults = { edge = { enabled = true } } } })
      ns.AbilitySettings = nil
      assert.same({}, Overlay.describe().abilities)
    end)
  end)

  describe("TestFire()", function()
    it("flashes an ability whose screen edge is OFF, and says that it is", function()
      stubPack({ EXORCISM = { id = 415073 } })
      local ok, label = Overlay.TestFire("EXORCISM")
      assert.is_true(ok)
      assert.equal(1, #flared)
      assert.truthy(label:find("Name of EXORCISM", 1, true), label)
      assert.truthy(label:find("will not fire in play", 1, true), label)
    end)

    it("names the ability plainly once it is switched on", function()
      stubPack({ EXORCISM = { id = 415073 } })
      A.set("EXORCISM", "edge", "enabled", true)
      local ok, label = Overlay.TestFire("EXORCISM")
      assert.is_true(ok)
      assert.equal("Name of EXORCISM", label)
    end)

    it("flashes with the ability's own colour, edge and intensity", function()
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "edge", "bottom")
      A.set("EXORCISM", "edge", "color", { r = 0.1, g = 0.2, b = 0.3 })
      A.set("EXORCISM", "edge", "intensity", 0.77)
      Overlay.TestFire("EXORCISM")
      assert.equal("bottom", flared[1].edge)
      assert.same({ 0.1, 0.2, 0.3 }, flared[1].color)
      assert.equal(0.77, flared[1].intensity)
    end)

    -- Not "default to the first ability", and not "flash whatever you typed" either.
    it("refuses anything that is not an ability key, and flashes nothing", function()
      for _, bad in ipairs({ "", 7, true }) do
        local ok, why = Overlay.TestFire(bad)
        assert.is_false(ok)
        assert.is_string(why)
      end
      local ok = Overlay.TestFire(nil)
      assert.is_false(ok)
      assert.equal(0, #flared)
    end)

    it("accepts a pack key with the registry merge not loaded", function()
      stubPack({ EXORCISM = { id = 415073 } })
      ns.Spells = nil
      assert.is_true(Overlay.TestFire("EXORCISM"))
      assert.equal(1, #flared)
    end)

    it("accepts a key that has only a settings row, imported for a spell nothing resolves", function()
      A.import({ MYSTERY = { edge = { enabled = true } } })
      assert.is_true(Overlay.TestFire("MYSTERY"))
      assert.equal(1, #flared)
    end)

    it("refuses a key no pack, registry or settings row knows, and flashes nothing", function()
      stubPack({ EXORCISM = { id = 415073 } })
      local ok, why = Overlay.TestFire("NOT_A_SPELL")
      assert.is_false(ok)
      assert.truthy(why:find("NOT_A_SPELL", 1, true))
      assert.equal(0, #flared)
    end)

    -- The Screen-edge tab's own Preview button previews the All abilities row, which is in no
    -- registry by construction -- refusing it would leave a dead button on that page.
    it("previews the All abilities row", function()
      assert.is_true(Overlay.TestFire(A.ALL))
      assert.equal(1, #flared)
    end)
  end)
end)
