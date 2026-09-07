local helper = require("tests.helper")

-- Elmira/Display/Driver.lua — the tick decision: recompute, repaint, or do nothing.
--
-- Two behaviours here have no other home. VISIBILITY: the display used to run from login to logout
-- with no concept of being off, so it glowed a player's action bar while they stood in a city and
-- burned ticks doing it. HIDDEN is now a first-class tick outcome, and the transition into it must
-- paint once — a queue that merely stops updating leaves the strip on screen and a bar button lit.
-- ERROR REPORTING: a broken renderer errors on every queue change, which in combat is several times
-- a second.
describe("Display.Driver", function()
  local Display, ns, rendered, logged

  local function stubQueue(queue, key)
    Display.computeQueue = function() return queue, key end
  end

  -- One state table per stub, not one per GetState call: the allocation specs below measure the
  -- driver, and a stub that allocated on every read would be charged to it.
  local function stubState(inCombat, hasTarget)
    local state = { inCombat = function() return inCombat end,
                    targetExists = function() return hasTarget end }
    ns.API = { GetState = function() return state end }
  end

  before_each(function()
    ns = helper.reset()
    rendered, logged = {}, {}
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
    helper.load("Elmira/Core/Ticker.lua")
    helper.load("Elmira/Core/Visibility.lua")
    Display = helper.load("Elmira/Display/Driver.lua")
    ns.db = { profile = { enabled = true, depth = 3, visibility = "always" } }
    stubState(false, false)
    stubQueue({ { spell = "EXORCISM" } }, "PALADIN_EXODIN")
    Display.register("test", function(queue, key, visible)
      rendered[#rendered + 1] = { queue = queue, key = key, visible = visible }
    end)
  end)

  -- Ticks are throttled to 10 Hz, so every step advances well past that.
  local t = 0
  local function tick()
    t = t + 1
    return Display.tick(t)
  end

  describe("visibility", function()
    it("renders when the mode says always, whatever the combat state is", function()
      assert.equal("rendered", tick())
      assert.equal(1, #rendered)
      assert.is_true(rendered[1].visible)
    end)

    it("does not compute a queue at all while hidden", function()
      ns.db.profile.visibility = "combat"
      local computed = false
      Display.computeQueue = function() computed = true; return {}, "k" end
      assert.equal("hidden", tick())
      assert.is_false(computed)
    end)

    it("paints the hidden state exactly once, then stops doing anything", function()
      ns.db.profile.visibility = "combat"
      assert.equal("hidden", tick())
      assert.equal(1, #rendered)
      assert.is_nil(rendered[1].queue)      -- renderers must be able to tell "hide" from "empty"
      assert.is_false(rendered[1].visible)
      assert.equal("hidden", tick())
      assert.equal("hidden", tick())
      assert.equal(1, #rendered)            -- still one: a hidden tick is free
    end)

    it("repaints when combat starts, and again when it ends", function()
      ns.db.profile.visibility = "combat"
      assert.equal("hidden", tick())
      stubState(true, false)
      assert.equal("rendered", tick())
      assert.is_true(rendered[#rendered].visible)
      stubState(false, false)
      assert.equal("hidden", tick())
      assert.is_false(rendered[#rendered].visible)
    end)

    it("a target alone shows it under the default mode but not under 'combat'", function()
      ns.db.profile.visibility = "combat_or_target"
      stubState(false, true)
      assert.equal("rendered", tick())
      ns.db.profile.visibility = "combat"
      Display.refresh()
      assert.equal("hidden", tick())
    end)

    it("the master switch hides it regardless of mode", function()
      ns.db.profile.enabled = false
      ns.db.profile.visibility = "always"
      assert.equal("hidden", tick())
      local _, reason = Display.shouldShow()
      assert.equal("display disabled", reason)
    end)

    it("a state that errors shows the display rather than hiding it silently", function()
      ns.API = { GetState = function() return { inCombat = function() error("boom") end } end }
      assert.equal("rendered", tick())
    end)

    it("stats carry the visibility decision and its reason", function()
      ns.db.profile.visibility = "combat"
      tick()
      local s = Display.stats()
      assert.is_false(s.visible)
      assert.equal("out of combat", s.visibleReason)
      assert.equal("combat", s.mode)
    end)
  end)

  -- Display.stats() is what `/elm debug perf` reads. lastBuildKey is only set by a RENDER, so before
  -- M4b it was nil whenever the display was hidden -- most of a session, and exactly when someone
  -- runs this to ask why the screen is empty.
  -- ADR-0010: a pinned fork resolves and compiles exactly like a shipped build. Real Schema,
  -- Profiles and UserBuilds; the pack is the shipped paladin data.
  describe("activeBuild() with a fork pinned", function()
    it("compiles the fork under its own key", function()
      helper.load("Elmira/Adapters/Interface.lua")
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Profiles.lua")
      helper.load("Elmira/Core/UserBuilds.lua")
      ns.compileBuild = ns.compileBuild or function(b, ctx) return ns.Schema.compile(b, ctx) end
      local pack = helper.classPack("Paladin")
      ns.API = { GetProvider = function(kind, class)
        return kind == "dataPacks" and class == "PALADIN" and pack or nil
      end }
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      local fork = {}
      for k, v in pairs(pack.builds.PALADIN_EXODIN) do fork[k] = v end
      fork.key = "USER_MINE"
      ns.db = { profile = { activeBuild = "USER_MINE" },
                global = { userBuilds = { USER_MINE = { class = "PALADIN", build = fork } } } }
      local compiled, key, reason = Display.activeBuild()
      assert.equal("USER_MINE", key)
      assert.equal("pinned", reason)
      assert.is_table(compiled)
      assert.equal("USER_MINE", compiled.key)
      assert.is_true(#compiled.entries > 10)
    end)

    -- R2b (D75/D76): Save validating a registry-key line is not the whole story -- the ACTIVE
    -- build is what the render loop shows, and before this pass `packContext` still handed
    -- `Schema.compile` the pack's OWN spells table alone, so a saved rotation naming a registered
    -- spell would fail to compile here even though `UserBuilds.replaceEntries` had already
    -- accepted it — a rotation that saves but never renders.
    it("compiles a fork naming a registry-only spell, and resolves its id", function()
      helper.load("Elmira/Core/Spells.lua")
      helper.load("Elmira/Adapters/Interface.lua")
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Profiles.lua")
      helper.load("Elmira/Core/UserBuilds.lua")
      ns.compileBuild = ns.compileBuild or function(b, ctx) return ns.Schema.compile(b, ctx) end
      local pack = helper.classPack("Paladin")
      ns.API = { GetProvider = function(kind, class)
        return kind == "dataPacks" and class == "PALADIN" and pack or nil
      end }
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      local fork = {}
      for k, v in pairs(pack.builds.PALADIN_EXODIN) do fork[k] = v end
      fork.key, fork.entries = "USER_MINE", { { spell = "SLICE" } }
      ns.db = { profile = { activeBuild = "USER_MINE" },
                char = { spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" } } },
                global = { userBuilds = { USER_MINE = { class = "PALADIN", build = fork } } } }
      local compiled, key, reason = Display.activeBuild()
      assert.equal("USER_MINE", key)
      assert.is_table(compiled, tostring(reason))
      assert.equal(900, compiled.entries[1].data.id)
    end)
  end)

  describe("stats() build resolution", function()
    it("resolves a build via activeBuild() when nothing has rendered yet, carrying the reason", function()
      -- No tick() has run: lastBuildKey is unset. ns.API is unset by default (before_each only sets
      -- ns.db), so the real activeBuild() takes the "no data pack for this class" path.
      local s = Display.stats()
      assert.is_nil(s.build)
      assert.equal("no data pack for this class", s.buildReason)
    end)

    it("reports the RENDERED build key once a tick has painted, with no buildReason attached", function()
      assert.equal("rendered", tick())
      local s = Display.stats()
      assert.equal("PALADIN_EXODIN", s.build)
      assert.is_nil(s.buildReason)
    end)

    it("does not re-resolve via activeBuild() once a render has already set the key", function()
      assert.equal("rendered", tick())
      -- A decoy: if stats() called activeBuild() again despite already having a real build key, this
      -- would leak through instead of the rendered one.
      Display.activeBuild = function() return {}, "DECOY", "should never be read" end
      local s = Display.stats()
      assert.equal("PALADIN_EXODIN", s.build)
      assert.is_nil(s.buildReason)
    end)
  end)

  -- ADR-0015 amendment. The template is one static list shipped to everybody; what makes it
  -- personal is that its rows carry gates. A player who equips their fourth tier piece has no way
  -- of knowing their rotation grew a line unless something says so.
  describe("telling the player their gear changed the rotation", function()
    local said, entries

    -- The REAL Core/UserBuilds, and a pack with a REAL catalog: the sentence is built from the
    -- storage key, and the name lookup that turns `PALADIN_EXODIN` (or a fork's `USER_...` slug)
    -- into words is the half that was never reachable from here. Stubbing it would put the pin
    -- back where D47 found it.
    local function withGates()
      said = {}
      entries = { { spell = "DIVINE_STORM", when = { { "bonus", "HOLY_POWER_CONSUME" } } } }
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Gates.lua")
      helper.load("Elmira/Core/UserBuilds.lua")
      ns.Announce = { emit = function(cat, text, opts)
        said[#said + 1] = { cat = cat, text = text, icon = opts and opts.icon }
      end }
      ns.Display.activeBuild = function() return { entries = entries }, "PALADIN_EXODIN", "pinned" end
      ns.Display.currentPack = function()
        return { class = "PALADIN",
                 catalog = { PALADIN = { { build = "PALADIN_EXODIN", playstyle = "Exodin" } } },
                 spells = { DIVINE_STORM = { id = 53385 } },
                 bonuses = { HOLY_POWER_CONSUME = { note = "Divine Storm consumes Holy Power" } } }
      end
      _G.GetSpellTexture = function() return "Interface\\Icons\\Ability_Warrior_Cleave" end
    end

    local function setBonus(held)
      ns.API = { GetState = function()
        return { inCombat = function() return false end, targetExists = function() return false end,
                 bonus = function(_, key) return held and key == "HOLY_POWER_CONSUME" end,
                 known = function() return true end }
      end }
    end

    before_each(function() withGates(); setBonus(false) end)
    after_each(function() _G.GetSpellTexture = nil end)

    -- Nothing to announce about a rotation the player has only just been shown.
    it("says nothing on the first look", function()
      assert.is_nil(Display.checkGates())
      assert.equal(0, #said)
    end)

    it("says so when a set bonus makes a row live", function()
      Display.checkGates()
      setBonus(true)
      local text = Display.checkGates()
      assert.is_truthy(text)
      assert.equal(1, #said)
      assert.equal("rotation", said[1].cat)
      assert.is_truthy(said[1].text:find("Divine Storm is now active"))
      assert.is_truthy(said[1].text:find("Divine Storm consumes Holy Power"))
      -- D40/D47: the PLAYSTYLE name, never the storage key. This assertion used to demand the raw
      -- `PALADIN_EXODIN` -- it pinned the very defect the fix removes.
      assert.is_truthy(said[1].text:find("in Exodin", 1, true))
      assert.is_nil(said[1].text:find("PALADIN_EXODIN", 1, true))
    end)

    -- D41's missing assertion. A fork's key is a slug the addon invented (`USER_MY_EXODIN`) and no
    -- player has ever seen; this announcement is the only sentence in the addon assembled from a
    -- storage key, so it is the only place one could reach the screen.
    it("says a fork's own name, never the USER_ key it is stored under", function()
      ns.db.global = { userBuilds = { USER_MY_EXODIN = {
        class = "PALADIN", name = "My Exodin", build = { entries = entries } } } }
      ns.Display.activeBuild = function()
        return { entries = entries }, "USER_MY_EXODIN", "pinned"
      end
      Display.checkGates()
      setBonus(true)
      Display.checkGates()
      assert.equal(1, #said)
      assert.is_truthy(said[1].text:find("in My Exodin", 1, true))
      assert.is_nil(said[1].text:find("USER_", 1, true))
    end)

    -- And when the key answers to nothing at all -- a build removed from the catalog while it was
    -- pinned -- the key is still better than an empty "is now active in .".
    it("falls back to the key when nothing can name it", function()
      ns.Display.activeBuild = function() return { entries = entries }, "PALADIN_GONE", "pinned" end
      Display.checkGates()
      setBonus(true)
      Display.checkGates()
      assert.is_truthy(said[1].text:find("in PALADIN_GONE", 1, true))
    end)

    it("carries the spell's icon, so the toast reads before the sentence does", function()
      Display.checkGates()
      setBonus(true)
      Display.checkGates()
      assert.equal("Interface\\Icons\\Ability_Warrior_Cleave", said[1].icon)
    end)

    it("says the reverse when the bonus goes away", function()
      Display.checkGates()
      setBonus(true)
      Display.checkGates()
      setBonus(false)
      Display.checkGates()
      assert.equal(2, #said)
      assert.is_truthy(said[2].text:find("no longer active"))
    end)

    -- An ordinary gear swap changes nothing about which rows can fire, and must be silent.
    it("says nothing when nothing about the rotation changed", function()
      Display.checkGates()
      Display.checkGates()
      Display.checkGates()
      assert.equal(0, #said)
    end)

    -- Switching profile or fork means every row belonged to another rotation. "Divine Storm is now
    -- active" because the player changed build is a message about nothing.
    it("starts again silently when the build changes", function()
      Display.checkGates()
      ns.Display.activeBuild = function() return { entries = entries }, "PALADIN_PROT", "pinned" end
      setBonus(true)
      assert.is_nil(Display.checkGates())
      assert.equal(0, #said)
    end)

    it("says nothing with no build, no state or no Gates", function()
      ns.Display.activeBuild = function() return nil, nil, "no pack" end
      assert.is_nil(Display.checkGates())
      withGates(); setBonus(false)
      ns.API = { GetState = function() return nil end }
      assert.is_nil(Display.checkGates())
      withGates(); setBonus(false)
      ns.Gates = nil
      assert.is_nil(Display.checkGates())
    end)

    it("has no icon to offer for a spell the pack does not carry", function()
      assert.is_nil(Display.spellIcon("NOT_IN_THE_PACK"))
      assert.equal("Interface\\Icons\\Ability_Warrior_Cleave", Display.spellIcon("DIVINE_STORM"))
      _G.GetSpellTexture = nil
      assert.is_nil(Display.spellIcon("DIVINE_STORM"))
    end)

    -- D81 (review finding on R2b): this used to read `pack.spells` alone, so a spell added by
    -- id/name/spellbook -- resolvable everywhere else after D75/D79/D80 -- still had no icon
    -- anywhere it was drawn, including U1's rows. Same merge as `gateContext`'s own D76 test above.
    it("resolves a registry-only spell's icon too, not just the pack's own keys", function()
      helper.load("Elmira/Core/Spells.lua")
      ns.db = { char = { spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" } } } }
      assert.equal("Interface\\Icons\\Ability_Warrior_Cleave", Display.spellIcon("SLICE"))
      assert.equal("Interface\\Icons\\Ability_Warrior_Cleave", Display.spellIcon("DIVINE_STORM"),
        "the pack's own spells must still resolve")
    end)

    -- Slot-based, not item-based: a build entry binds to the SLOT (`entry.item = 13`), so the
    -- Builder's item palette has to read the icon from the slot too.
    it("reads an item icon out of the inventory slot, and copes when it cannot", function()
      _G.GetInventoryItemTexture = function(unit, slot)
        return (unit == "player" and slot == 13) and "Interface\\Icons\\INV_Trinket" or nil
      end
      assert.equal("Interface\\Icons\\INV_Trinket", Display.itemIcon(13))
      assert.is_nil(Display.itemIcon(14))
      assert.is_nil(Display.itemIcon(nil))
      _G.GetInventoryItemTexture = nil
      assert.is_nil(Display.itemIcon(13))
    end)

    -- "Cooldowns used" shipped with routing, a colour and the ONLY party/raid toggle, and nothing
    -- anywhere emitted it: the owner switched it on, used Avenging Wrath and got silence. Reported
    -- from a client 2026-09-05.
    describe("announcing a cooldown that was used", function()
      local told
      before_each(function()
        told = {}
        ns.Announce = {
          worthAnnouncing = function(cd) return ns.Announce.floor and cd and cd >= ns.Announce.floor end,
          floor = 120,
          emit = function(cat, text, opts) told[#told + 1] = { cat = cat, text = text, opts = opts } end,
        }
        ns.BarGlow = { spellName = function(id) return id == 407788 and "Avenging Wrath" or nil end }
        -- Real cooldown values, so the threshold is tested against the numbers a paladin has:
        -- Avenging Wrath 180s is announced, Crusader Strike 6s is not.
        ns.Display.currentPack = function()
          return { spells = { AVENGING_WRATH = { id = 407788, cooldown = 180 },
                              CRUSADER_STRIKE = { id = 407676, cooldown = 6 } } }
        end
      end)

      it("says a long cooldown went out, in its own category", function()
        assert.is_true(Display.announceCooldown("AVENGING_WRATH"))
        assert.equal(1, #told)
        assert.equal("cooldown", told[1].cat)
        assert.equal("Avenging Wrath used.", told[1].text)
      end)

      -- The bar is deliberately high: this is the one category that may reach party chat, and
      -- Crusader Strike at 6s would be a line every global cooldown.
      it("says nothing about a short one", function()
        assert.is_false(Display.announceCooldown("CRUSADER_STRIKE"))
        assert.equal(0, #told)
      end)

      it("says nothing for a spell the pack does not carry", function()
        assert.is_false(Display.announceCooldown("NOT_IN_THE_PACK"))
        assert.equal(0, #told)
      end)

      it("falls back to a readable name when the client cannot resolve the id", function()
        ns.BarGlow = { spellName = function() return nil end }
        ns.Detect = { readableName = function(key) return "readable:" .. key end }
        Display.announceCooldown("AVENGING_WRATH")
        assert.equal("readable:AVENGING_WRATH used.", told[1].text)
      end)

      -- The key itself is the last resort. A blank line saying " used." is worse than an ugly one.
      it("falls back to the raw key when nothing can name it", function()
        ns.BarGlow, ns.Detect = nil, nil
        Display.announceCooldown("AVENGING_WRATH")
        assert.equal("AVENGING_WRATH used.", told[1].text)
      end)

      it("carries the spell's icon, so the on-screen line shows what went out", function()
        Display.announceCooldown("AVENGING_WRATH")
        assert.is_truthy(told[1].opts.icon)
      end)

      it("does not error before the announcer is loaded", function()
        ns.Announce = nil
        assert.is_false(Display.announceCooldown("AVENGING_WRATH"))
      end)

      -- Both halves, and the announcement must NOT inherit the strip's guards: someone who hides
      -- the queue and watches only the bar glow still wants to be told a cooldown went out.
      it("tells the strip and announces, from one call", function()
        local passed
        ns.Queue = { keyForSpellID = function(id) return id == 407788 and "AVENGING_WRATH" or nil end,
                     noteCast = function(id) passed = id end }
        assert.equal("AVENGING_WRATH", Display.noteCast(407788))
        assert.equal(407788, passed)
        assert.equal(1, #told)
      end)

      it("still tells the strip when the cast is nothing worth announcing", function()
        local passed
        ns.Queue = { keyForSpellID = function() return "CRUSADER_STRIKE" end,
                     noteCast = function(id) passed = id end }
        Display.noteCast(407676)
        assert.equal(407676, passed)
        assert.equal(0, #told)
      end)
    end)

    it("forgets what it knew on request, so the next look starts again", function()
      Display.checkGates()
      setBonus(true)
      Display.resetGates()
      assert.is_nil(Display.checkGates())
      assert.equal(0, #said)
    end)

    -- A build can change WITHOUT its key changing: an import over the same fork, a profile copy,
    -- the M5e editor. Diffing the new rows against the old build's announced a gear change for an
    -- edit the player had just made themselves.
    it("forgets the gates on a repaint, so an edited build is not read as a gear change", function()
      Display.checkGates()
      entries = { { spell = "DIVINE_STORM" } }   -- same key, the row's gate removed by hand
      Display.refresh()
      assert.is_nil(Display.checkGates())
      assert.equal(0, #said)
    end)

    it("still announces a real gear change after a repaint has re-recorded", function()
      Display.checkGates()
      Display.refresh()
      Display.checkGates()
      setBonus(true)
      assert.is_truthy(Display.checkGates())
    end)

    -- A flavour without engraving answers false for every rune, so every rune row would be
    -- reported dead for a reason that is not true and that the player cannot act on.
    it("passes what the client can read down to Gates", function()
      ns.Adapter = { capabilities = function() return { runes = false } end }
      assert.is_false(Display.gateContext().capabilities.runes)
      ns.Display.currentPack = function() return nil end
      assert.is_false(Display.gateContext().capabilities.runes)
    end)

    describe("inactiveRows", function()
      it("lists only the rows that cannot fire, with their reasons", function()
        local rows, key = Display.inactiveRows()
        assert.equal(1, #rows)
        assert.equal("DIVINE_STORM", rows[1].spell)
        assert.same({ "Divine Storm consumes Holy Power" }, rows[1].reasons)
        assert.equal("PALADIN_EXODIN", key)
      end)

      it("lists nothing once every row is live", function()
        setBonus(true)
        assert.equal(0, #Display.inactiveRows())
      end)

      it("lists nothing rather than erroring with no build, no state or no Gates", function()
        ns.Display.activeBuild = function() return nil, nil, "no pack" end
        assert.same({}, Display.inactiveRows())
        withGates(); setBonus(false)
        ns.API = { GetState = function() return nil end }
        assert.same({}, Display.inactiveRows())
        withGates(); setBonus(false)
        ns.Gates = nil
        assert.same({}, Display.inactiveRows())
      end)
    end)

    -- The Builder draws a status marker per row, so it needs the ACTIVE rows too: "cannot fire for
    -- you" and "fine, simply not first right now" are different colours and inactiveRows only
    -- distinguishes one of them.
    describe("gateRows", function()
      it("hands back every row, the compiled build and the key", function()
        entries = { { spell = "DIVINE_STORM", when = { { "bonus", "HOLY_POWER_CONSUME" } } },
                    { spell = "EXORCISM" } }
        local compiled, rows, key = Display.gateRows()
        assert.equal(2, #rows)
        assert.is_false(rows[1].active)
        assert.is_true(rows[2].active)
        assert.equal("PALADIN_EXODIN", key)
        assert.equal(2, #compiled.entries)
      end)

      -- Row i belongs to compiled.entries[i].index, not to saved entry i. Schema.compile drops a
      -- disabled entry and records where it came from, so a caller mapping by ordinal would put
      -- every status one row out the moment a line was switched off.
      it("carries the SAVED position of each row, past a disabled line", function()
        -- Compiled for real here, not stubbed: the skew this pins is created by Schema.compile
        -- dropping a disabled entry, so a stub that hands back the raw build cannot show it.
        local build = { schema = 1, key = "K", name = "K", class = "PALADIN", entries = {
          { spell = "EXORCISM", disabled = true },
          { spell = "DIVINE_STORM", when = { { "bonus", "HOLY_POWER_CONSUME" } } },
        } }
        local built = ns.Schema.compile(build, { spells = { EXORCISM = { id = 1 },
                                                            DIVINE_STORM = { id = 2 } },
                                                 bonuses = { HOLY_POWER_CONSUME = { note = "n" } } })
        ns.Display.activeBuild = function() return built, "PALADIN_EXODIN", "pinned" end
        local compiled, rows = Display.gateRows()
        assert.equal(1, #rows, "the disabled line does not compile, so it has no gate row")
        assert.equal(1, rows[1].index, "the gate row is the first COMPILED row")
        assert.equal(2, compiled.entries[1].index, "and it is the second SAVED row")
        assert.equal("DIVINE_STORM", rows[1].spell)
      end)

      it("answers no rows rather than erroring with no build or no Gates", function()
        ns.Display.activeBuild = function() return nil, nil, "no pack" end
        local compiled, rows, key = Display.gateRows()
        assert.is_nil(compiled)
        assert.same({}, rows)
        assert.is_nil(key)
        withGates(); setBonus(false)
        ns.Gates = nil
        local again, noRows = Display.gateRows()
        assert.is_nil(again)
        assert.same({}, noRows)
      end)
    end)

    it("hands Gates the pack's own words for a set and a bonus", function()
      local gateCtx = Display.gateContext()
      assert.is_not_nil(gateCtx.bonuses.HOLY_POWER_CONSUME)
      assert.is_not_nil(gateCtx.spells.DIVINE_STORM)
      ns.Display.currentPack = function() return nil end
      assert.same({}, Display.gateContext())
    end)

    -- R2b (D76): a gate naming a registry-only spell ("this row needs X you registered") must
    -- resolve it too, not just the pack's own keys -- same merge as `packContext`.
    it("merges this character's registry into the pack's own spells too", function()
      helper.load("Elmira/Core/Spells.lua")
      ns.db = { char = { spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice" } } } }
      local gateCtx = Display.gateContext()
      assert.equal(900, gateCtx.spells.SLICE.id)
      assert.is_not_nil(gateCtx.spells.DIVINE_STORM, "the pack's own spells must still be there")
    end)
  end)

  describe("renderer errors", function()
    it("reports the same error once, not on every queue change", function()
      Display.register("broken", function() error("kaboom") end)
      tick()
      stubQueue({ { spell = "JUDGEMENT" } }, "PALADIN_EXODIN")
      tick()
      stubQueue({ { spell = "CONSECRATION" } }, "PALADIN_EXODIN")
      tick()
      assert.equal(1, #logged)
      assert.truthy(logged[1]:find("kaboom", 1, true))
    end)

    it("reports again once the error changes, and after a renderer recovers", function()
      local message = "first"
      Display.register("broken", function() error(message) end)
      tick()
      message = "second"
      stubQueue({ { spell = "JUDGEMENT" } }, "PALADIN_EXODIN")
      tick()
      assert.equal(2, #logged)
    end)

    -- F37: routed as a warning, so a player who has moved warnings off chat still gets it in the
    -- Log rather than losing it entirely.
    it("routes the report as a warning when Announce is loaded", function()
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      Display.register("broken", function() error("kaboom") end)
      tick()
      assert.equal(1, #said)
      assert.equal("warning", said[1][1])
      assert.is_truthy(said[1][2]:find("kaboom", 1, true))
      assert.is_truthy(said[1][2]:find("broken", 1, true))
      assert.equal(0, #logged)
    end)

    it("one broken renderer does not stop the others", function()
      Display.register("broken", function() error("kaboom") end)
      tick()
      assert.equal(1, #rendered)
    end)
  end)
  -- `/elm debug memory` proved the render loop owns the growth; it could not say WHICH PART of the
  -- loop, and that is the answer that decides what gets rewritten. These are the hooks that say so.
  -- All of them must be free when nothing is measuring: the loop runs at the client's framerate.
  describe("allocation phases (Core/MemProbe)", function()
    local MemProbe

    before_each(function()
      MemProbe = helper.load("Elmira/Core/MemProbe.lua")
    end)

    after_each(function()
      if MemProbe then MemProbe.stopPhases() end
    end)

    local function phaseNames()
      local names = {}
      for _, row in ipairs(MemProbe.stopPhases()) do names[row.name] = row.calls end
      return names
    end

    it("records nothing at all while no measurement is running", function()
      tick()
      assert.is_false(MemProbe.isProfiling())
      assert.same({}, MemProbe.stopPhases())
    end)

    it("names the visibility check and every renderer once a measurement starts", function()
      Display.register("second", function() end)
      MemProbe.startPhases()
      tick()
      local names = phaseNames()
      assert.equal(1, names["visibility"], "the visibility read is its own phase")
      assert.equal(1, names["render:test"])
      assert.equal(1, names["render:second"], "each renderer is attributed by name, not lumped")
    end)

    -- Going hidden paints once, on purpose, so the strip actually disappears -- and that paint is
    -- real work that has to be attributed. What a hidden tick must NEVER show is a queue: the whole
    -- point of the hidden path is that it computes none, and a `simulate` row here would mean the
    -- throttle had stopped working.
    it("attributes the paint that hides the display, and no queue at all", function()
      ns.db.profile.visibility = "combat"
      MemProbe.startPhases()
      assert.equal("hidden", tick())
      assert.equal("hidden", tick())
      local names = phaseNames()
      assert.equal(2, names["visibility"], "every tick reads it; that is what makes it cheap or not")
      assert.equal(1, names["render:test"], "the transition paints once, the second tick is free")
      assert.is_nil(names["simulate"], "a hidden tick must not compute a queue")
    end)

    -- The two halves of computeQueue fail for different reasons: resolving the build should be a
    -- cache hit costing nothing, while simulating is hundreds of client calls. One combined number
    -- cannot tell them apart, which is the whole reason this split exists.
    -- The split is only worth having if each half is measured from its OWN starting point. Reusing
    -- the build's mark for the simulation would still produce two rows, both named correctly and
    -- both with a plausible call count -- and the simulation's number would silently include
    -- everything the build allocated. So the fixture makes the build expensive and the simulation
    -- free, and asserts they do not come back looking alike.
    it("splits the queue into resolving the build and simulating it, from separate marks", function()
      local D = helper.load("Elmira/Display/Driver.lua")   -- fresh, with the real computeQueue
      local sink
      D.activeBuild = function()
        sink = {}
        for i = 1, 2000 do sink[i] = { i } end
        return { entries = {} }, "PALADIN_EXODIN"
      end
      ns.Simulation = { queue = function() return { { spell = "EXORCISM" } } end }
      MemProbe.startPhases()
      -- The collector paused for the span being measured. Allocating 2000 tables under Lua 5.1's
      -- incremental GC provokes collection steps of its own, and a phase that frees more than it
      -- allocates reads as zero -- which is correct behaviour (MemProbe counts positive steps only)
      -- and makes the assertion below a coin toss. WoW never runs with the collector stopped; this
      -- is the fixture holding still, not the code under test behaving differently.
      collectgarbage("stop")
      local queue, key = D.computeQueue(3)
      collectgarbage("restart")
      assert.equal("PALADIN_EXODIN", key)
      assert.equal(1, #queue)
      assert.equal(2000, #sink)

      local rows = {}
      for _, row in ipairs(MemProbe.stopPhases()) do rows[row.name] = row end
      assert.equal(1, rows["build"].calls)
      assert.equal(1, rows["simulate"].calls)
      assert.is_true(rows["build"].kb > 10, "2000 tables have to land somewhere: " .. rows["build"].kb)
      assert.is_true(rows["simulate"].kb < rows["build"].kb / 2,
        "the simulation must not be charged for what the build allocated")
    end)

    -- A build that will not compile returns before the simulation: charging `simulate` for a run
    -- that never happened would invent a phase out of nothing.
    it("does not attribute a simulation that never ran", function()
      local D = helper.load("Elmira/Display/Driver.lua")
      D.activeBuild = function() return nil, "BROKEN" end
      MemProbe.startPhases()
      assert.is_nil(D.computeQueue(3))
      local names = phaseNames()
      assert.equal(1, names["build"])
      assert.is_nil(names["simulate"])
    end)
  end)

  -- Memory round 3. Most recomputes come back "unchanged", and every one of them used to allocate a
  -- fresh queue: five slot tables, four times a second, standing still. The tick now owns two
  -- buffers and computes into whichever is NOT on screen, so the queue being shown survives the
  -- recompute untouched and an unchanged recompute allocates nothing.
  describe("double-buffered queue", function()
    local computed
    local function realComputeQueue()
      -- The real computeQueue with a stand-in Simulation that honours `into`, as the real one does.
      Display.computeQueue = nil
      local D = helper.load("Elmira/Display/Driver.lua")
      D.register("test", function(queue, key, visible)
        rendered[#rendered + 1] = { queue = queue, key = key, visible = visible }
      end)
      local build = { entries = {} }
      D.activeBuild = function() return build, "PALADIN_EXODIN" end
      ns.Simulation = { queue = function(_, _, _, into)
        local out = into or {}
        for i = #computed + 1, #out do out[i] = nil end
        for i, spell in ipairs(computed) do
          out[i] = out[i] or {}
          out[i].spell = spell
        end
        return out
      end }
      return D
    end

    it("leaves the queue on screen untouched while an unchanged recompute runs", function()
      computed = { "EXORCISM", "JUDGEMENT" }
      local D = realComputeQueue()
      assert.equal("rendered", D.tick(1))
      local shown = rendered[#rendered].queue
      assert.equal("EXORCISM", shown[1].spell)
      assert.equal("unchanged", D.tick(2))
      assert.equal("unchanged", D.tick(3))
      assert.equal("EXORCISM", shown[1].spell, "the shown table was not written over")
      assert.equal(2, #shown)
    end)

    it("swaps buffers on a change and alternates between the same two tables", function()
      computed = { "EXORCISM" }
      local D = realComputeQueue()
      D.tick(1)
      local first = rendered[#rendered].queue
      computed = { "JUDGEMENT" }
      assert.equal("rendered", D.tick(2))
      local second = rendered[#rendered].queue
      assert.are_not.equal(first, second, "a changed queue lands in the other buffer")
      assert.equal("EXORCISM", first[1].spell, "the previous buffer still holds what it showed")
      computed = { "CRUSADER_STRIKE" }
      D.tick(3)
      assert.equal(first, rendered[#rendered].queue, "the third queue reuses the first buffer")
      assert.equal("CRUSADER_STRIKE", first[1].spell)
      computed = { "EXORCISM" }
      D.tick(4)
      assert.equal(second, rendered[#rendered].queue)
    end)

    it("hands the tick's buffer to Simulation and no buffer to anyone else", function()
      computed = { "EXORCISM" }
      local D = realComputeQueue()
      local given = {}
      local sim = ns.Simulation.queue
      ns.Simulation.queue = function(b, s, d, into) given[#given + 1] = into; return sim(b, s, d, into) end
      D.tick(1)
      assert.is_table(given[1], "the tick passes a buffer")
      D.computeQueue(3)
      assert.is_nil(given[2], "a direct caller gets fresh tables it may keep")
    end)

    -- What the Builder's queue mirror reads. `nil` while hidden is a real answer -- "no target, out
    -- of combat" -- and must not read as "the addon is broken".
    it("answers the queue that is on screen, and nil while hidden", function()
      computed = { "EXORCISM" }
      ns.db.profile.visibility = "combat_or_target"
      stubState(true, true)
      local D = realComputeQueue()
      assert.is_nil(D.currentQueue(), "nothing has been rendered yet")
      D.tick(1)
      assert.equal(rendered[#rendered].queue, D.currentQueue())
      assert.equal("EXORCISM", D.currentQueue()[1].spell)

      -- It follows the double buffer rather than holding the first table it saw.
      computed = { "JUDGEMENT" }
      D.tick(2)
      assert.equal("JUDGEMENT", D.currentQueue()[1].spell)
      assert.equal(rendered[#rendered].queue, D.currentQueue())

      stubState(false, false)
      assert.equal("hidden", D.tick(3))
      assert.is_nil(D.currentQueue())
    end)

    it("allocates nothing for a tick whose queue did not change", function()
      computed = { "EXORCISM", "JUDGEMENT", "CRUSADER_STRIKE" }
      ns.db.profile.visibility = "combat_or_target"
      stubState(true, true)
      local D = realComputeQueue()
      D.tick(1); D.tick(2); D.tick(3)
      local changed = 0
      local kb = helper.allocatedKB(function()
        for at = 4, 13 do if D.tick(at) ~= "unchanged" then changed = changed + 1 end end
      end)
      assert.equal(0, changed)
      assert.is_true(kb == nil or kb < 0.05, string.format("ten unchanged ticks allocated %.3f KB", kb or 0))
    end)
  end)

  describe("resolving the pack and its compile context without allocating", function()
    local pack
    before_each(function()
      helper.load("Elmira/Adapters/Interface.lua")
      helper.load("Elmira/Core/Schema.lua")
      helper.load("Elmira/Core/Profiles.lua")
      helper.load("Elmira/Core/UserBuilds.lua")
      helper.load("Elmira/Core/Slash.lua")        -- the real compile cache
      pack = helper.classPack("Paladin")
      ns.API = { GetProvider = function(kind, class)
        return kind == "dataPacks" and class == "PALADIN" and pack or nil
      end }
      ns.Adapter = { playerClass = function() return "PALADIN" end }
      ns.db = { profile = { activeBuild = "PALADIN_EXODIN" }, global = { userBuilds = {} } }
    end)

    it("resolves the pinned build through the uncopied provider lookup", function()
      local compiled, key, reason = Display.activeBuild()
      assert.equal("PALADIN_EXODIN", key)
      assert.equal("pinned", reason)
      assert.equal("PALADIN_EXODIN", compiled.key)
    end)

    it("hands the compile cache the same context every tick, so the compile is a hit", function()
      local a = Display.activeBuild()
      local b = Display.activeBuild()
      assert.equal(a, b, "same compiled table: the ctx was reused, so the cache hit")
      local kb = helper.allocatedKB(function() for _ = 1, 10 do Display.activeBuild() end end)
      assert.is_true(kb == nil or kb < 0.05, string.format("ten resolutions allocated %.3f KB", kb or 0))
    end)

    it("rebuilds the context when the pack's tables are swapped underneath it", function()
      local a = Display.activeBuild()
      local spells = {}
      for k, v in pairs(pack.spells) do spells[k] = v end
      pack.spells = spells
      local b = Display.activeBuild()
      assert.are_not.equal(a, b, "new spell table, new ctx, new compile")
    end)

    it("says so when the API cannot look a provider up", function()
      ns.API = { GetProviders = function() return { PALADIN = pack } end }
      assert.is_nil(Display.currentPack())
    end)
  end)

  describe("shouldShow() without a closure", function()
    it("reads combat and target through one reused context", function()
      ns.db.profile.visibility = "combat_or_target"
      stubState(false, false)
      assert.is_false((Display.shouldShow()))
      stubState(false, true)
      assert.is_true((Display.shouldShow()))
      stubState(true, false)
      assert.is_true((Display.shouldShow()))
      local kb = helper.allocatedKB(function() for _ = 1, 10 do Display.shouldShow() end end)
      assert.is_true(kb == nil or kb < 0.05, string.format("ten visibility reads allocated %.3f KB", kb or 0))
    end)
  end)

end)
