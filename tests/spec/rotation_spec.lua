local helper = require("tests.helper")

-- Elmira/Options/Rotation.lua — the Rotation section (ADR-0015 §1-2), the addon's front door.
--
-- Same mechanism as options_spec: the section is plain data and closures, so a spec calls
-- `Rotation.group()` and drives a row directly with no AceConfig, no AceGUI and no frame. The parts
-- that will need a real widget (the Builder) deliberately hold no logic yet.
--
-- The thing this file is really guarding is the pair of `and`-truncation bugs luacheck caught while
-- it was being written: `local _, key = cond and f()` adjusts f() to ONE value, so the second
-- return silently arrives as nil. Both would have rendered as "no rotation is active" — a panel
-- that looks fine and says nothing true, which is this project's characteristic failure.
describe("Options/Rotation (the Rotation section)", function()
  local Rotation, ns, realUserBuilds

  -- `catalogUpdated` is deliberately the REAL one: it is the function Core/UserBuilds uses to stamp
  -- `derivedAt`, so the stale-parent banner has to ask it the same question. Faking it here would
  -- let the two drift into a banner that silently stops appearing, which is the drift the shared
  -- definition exists to prevent. Only `find`/`list` are fakes.
  local function installUserBuilds(t)
    t.catalogUpdated = t.catalogUpdated or realUserBuilds.catalogUpdated
    ns.UserBuilds = t
    return t
  end

  local CATALOG = {
    { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "medium",
      updated = "2026-08-01", recommended = true },
    { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", difficulty = "hard",
      updated = "2026-07-01", experimental = true },
  }

  local function installPack()
    ns.Display.currentPack = function()
      return { class = "PALADIN", catalog = { PALADIN = CATALOG },
               builds = { PALADIN_EXODIN = {}, PALADIN_SHOCKADIN = {} } }
    end
  end

  -- The wizard is the one place that knows an entry is only offerable when the pack ships the build
  -- it names, so the section reuses it rather than re-deriving. Faked here at that seam.
  local function installWizard(rows)
    ns.Wizard = { choices = function() return rows end }
  end

  before_each(function()
    ns = helper.reset()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    -- The real signature is compiled, key, reason -- and the key SURVIVES a compile failure, which
    -- is the defect the "selected but broken" tests below pin.
    ns.Display = { activeBuild = function() return {}, "PALADIN_EXODIN", nil end,
                   currentPack = function() return nil end }
    realUserBuilds = helper.load("Elmira/Core/UserBuilds.lua")
    ns.UserBuilds = nil -- each test opts in through installUserBuilds
    Rotation = helper.load("Elmira/Options/Rotation.lua")
  end)

  describe("group()", function()
    it("is one tabbed section holding Rotations, Builder and Share, in that order", function()
      local g = Rotation.group()
      assert.equal("group", g.type)
      assert.equal("tab", g.childGroups)
      assert.equal("Rotation", g.name)
      -- Order 0: the front door sorts above the display settings, not at the bottom where
      -- Import/Export used to live.
      assert.equal(0, g.order)
      assert.equal(1, g.args.rotations.order)
      assert.equal(2, g.args.builder.order)
      assert.equal(3, g.args.share.order)
    end)

    it("gives the Builder a search box and a list of spells and items", function()
      local args = Rotation.group().args.builder.args
      assert.equal("input", args.search.type)
      assert.equal("group", args.spells.type)
      assert.equal("group", args.items.type)
      assert.is_true(args.spells.inline)
      assert.equal(6, args.spells.order)
      assert.equal(7, args.items.order)
      assert.equal("group", args.list.type)
      assert.equal(2, args.list.order)
      assert.is_truthy(args.intro.name)
    end)
  end)

  -- The Share tab owns the widget; Options.lua still owns the state. The tab must read THROUGH the
  -- accessors, not hold a second copy — `Options.exchangeText` had no caller outside the suite
  -- until this tab, which in this repo is a bug report rather than a spare function.
  describe("Share tab", function()
    local function box() return Rotation.group().args.share.args end

    it("shows what Options put in the box, and its note", function()
      ns.Options = { exchangeText = function() return "ELM1:abc" end,
                     exchangeNote = function() return "Imported as USER_X." end,
                     importText = function() end }
      assert.equal("ELM1:abc", box().text.get())
      assert.equal("Imported as USER_X.", box().note.name())
    end)

    it("routes a pasted string to Options.importText", function()
      local got
      ns.Options = { exchangeText = function() return "" end,
                     exchangeNote = function() return "" end,
                     importText = function(str) got = str end }
      box().text.set(nil, "ELM1:pasted")
      assert.equal("ELM1:pasted", got)
    end)

    it("describes itself: one multiline input naming the string format", function()
      ns.Options = { exchangeText = function() return "" end,
                     exchangeNote = function() return "" end, importText = function() end }
      assert.equal("input", box().text.type)
      assert.equal(8, box().text.multiline)
      assert.equal("Build string", box().text.name)
      assert.is_truthy(box().text.desc:find("ELM1:", 1, true))
      assert.equal("description", box().note.type)
      assert.equal(2, box().note.order)
    end)

    -- Options.lua loads after this file in the TOC, so the accessors are reached lazily. Reading
    -- them at load time would leave the box permanently empty with nothing to show for it.
    it("renders without Options loaded rather than erroring", function()
      ns.Options = nil
      assert.equal("", box().text.get())
      assert.equal("", box().note.name())
      box().text.set(nil, "ELM1:ignored")
    end)
  end)

  -- The Builder's palette (step 2). Core/Palette is pure and tested on its own; this is the wiring
  -- that hands it the client-shaped parts and renders what comes back.
  describe("Builder palette", function()
    local PACK_SPELLS = {
      EXORCISM = { id = 415073 },
      DIVINE_STORM = { id = 407778 },
      RUNE_DIVINE_STORM = { id = 407778, rune = "chest" },
    }

    local function installPalette(known)
      helper.load("Elmira/Core/Palette.lua")
      ns.Display.currentPack = function()
        return { class = "PALADIN", catalog = { PALADIN = CATALOG }, spells = PACK_SPELLS }
      end
      ns.Detect = { readableName = function(key) return key end }
      ns.API = { GetState = function()
        return { known = function(_, key) return known and known(key) end }
      end }
      ns.db = { profile = { paletteAllSlots = false } }
      Rotation.setSearch("")
    end

    it("lists the pack's abilities and not its rune records", function()
      installPalette(function() return true end)
      local args = Rotation.group().args.builder.args.spells.args
      local names = {}
      for _, row in pairs(args) do names[#names + 1] = row.name end
      assert.equal(2, #names, "expected Exorcism and Divine Storm, no rune record")
    end)

    -- The whole point of the owner's "show everything, grey the rest" choice: the row you cannot
    -- use yet has to say what to do about it.
    it("dims an un-known ability and names the rune that grants it", function()
      installPalette(function() return false end)
      local args = Rotation.group().args.builder.args.spells.args
      local text = ""
      for _, row in pairs(args) do
        if row.name:find("DIVINE_STORM", 1, true) then text = row.name end
      end
      assert.is_truthy(text:find("engrave", 1, true), "no reason on the greyed row")
      assert.is_truthy(text:find("|cff9AA0A6", 1, true), "the un-known row is not dimmed")
    end)

    it("does not dim anything when the client cannot tell what is known", function()
      installPalette(function() return nil end)
      for _, row in pairs(Rotation.group().args.builder.args.spells.args) do
        assert.is_nil(row.name:find("engrave", 1, true))
      end
    end)

    it("filters both lists on what you typed, ignoring case", function()
      installPalette(function() return true end)
      Rotation.setSearch("exorc")
      assert.equal(1, #Rotation.paletteSpells())
      Rotation.setSearch("EXORC")
      assert.equal(1, #Rotation.paletteSpells())
      Rotation.setSearch("")
      assert.equal(2, #Rotation.paletteSpells())
    end)

    -- A search box that treats what you typed as a Lua pattern errors on a bracket, which is not a
    -- thing a search box may do.
    it("treats the search as plain text, not a Lua pattern", function()
      installPalette(function() return true end)
      Rotation.setSearch("[")
      assert.same({}, Rotation.paletteSpells())
      assert.same({}, Rotation.paletteItems())
    end)

    it("says so when nothing matches, rather than rendering an empty box", function()
      installPalette(function() return true end)
      Rotation.setSearch("zzzz")
      assert.is_truthy(Rotation.group().args.builder.args.spells.args.none.name
        :find("Nothing matches", 1, true))
    end)

    it("routes the search box through the accessor", function()
      installPalette(function() return true end)
      local row = Rotation.group().args.builder.args.search
      row.set(nil, "judge")
      assert.equal("judge", Rotation.search())
      assert.equal("judge", row.get())
    end)

    it("lists trinkets only until the toggle is on, and remembers the choice", function()
      installPalette(function() return true end)
      assert.equal(2, #Rotation.paletteItems())
      local toggle = Rotation.group().args.builder.args.items.args.all
      assert.is_false(toggle.get())
      toggle.set(nil, true)
      assert.is_true(ns.db.profile.paletteAllSlots)
      assert.is_true(#Rotation.paletteItems() > 2)
    end)

    it("names each slot for a person, and marks the empty ones", function()
      installPalette(function() return true end)
      ns.Display.itemIcon = function(slot) return slot == 13 and "tex" or nil end
      local args = Rotation.group().args.builder.args.items.args
      assert.is_truthy(args.i1.name:find("Trinket 1", 1, true))
      assert.is_truthy(args.i2.name:find("Trinket 2", 1, true))
      assert.is_nil(args.i1.name:find("empty", 1, true))
      assert.is_truthy(args.i2.name:find("empty", 1, true))
    end)

    -- spellLabel walks three sources in order; each needs its own case, or the fallbacks are
    -- untested code that only runs on the clients we cannot reach.
    describe("spellLabel()", function()
      it("prefers the name the client resolves from the spell id", function()
        installPalette(function() return true end)
        ns.BarGlow = { spellName = function(id) return id == 415073 and "Exorcism" or nil end }
        assert.equal("Exorcism", Rotation.spellLabel("EXORCISM"))
      end)

      it("falls back to the readable key when the client cannot resolve the id", function()
        installPalette(function() return true end)
        ns.BarGlow = { spellName = function() return nil end }
        ns.Detect = { readableName = function(key) return "readable:" .. key end }
        assert.equal("readable:EXORCISM", Rotation.spellLabel("EXORCISM"))
      end)

      it("falls back to the raw key when nothing can name it at all", function()
        installPalette(function() return true end)
        ns.BarGlow, ns.Detect = nil, nil
        assert.equal("EXORCISM", Rotation.spellLabel("EXORCISM"))
      end)

      it("answers for a key the pack does not carry", function()
        installPalette(function() return true end)
        ns.BarGlow, ns.Detect = nil, nil
        assert.equal("NOT_IN_PACK", Rotation.spellLabel("NOT_IN_PACK"))
      end)

      it("answers before a pack is loaded", function()
        ns.BarGlow, ns.Detect = nil, nil
        assert.equal("EXORCISM", Rotation.spellLabel("EXORCISM"))
      end)

      -- The palette must be labelled by THIS function, not by the raw key: without it every row
      -- reads as EXORCISM rather than Exorcism, and the search box matches the wrong text.
      it("is what the palette labels its rows with", function()
        installPalette(function() return true end)
        ns.BarGlow = { spellName = function(id) return id == 415073 and "Exorcism" or nil end }
        local rows = Rotation.paletteSpells()
        local seen = {}
        for _, row in ipairs(rows) do seen[row.key] = row.label end
        assert.equal("Exorcism", seen.EXORCISM)
      end)
    end)

    it("names every slot it offers, with no raw numbers left over", function()
      installPalette(function() return true end)
      ns.db.profile.paletteAllSlots = true
      for _, row in ipairs(Rotation.paletteItems()) do
        assert.is_string(row.label)
        assert.is_nil(row.label:find("Slot ", 1, true),
          "slot " .. row.slot .. " has no name of its own")
      end
    end)

    it("names the slots a person actually recognises", function()
      installPalette(function() return true end)
      ns.db.profile.paletteAllSlots = true
      local byName = {}
      for _, row in ipairs(Rotation.paletteItems()) do byName[row.slot] = row.label end
      assert.equal("Head", byName[1])
      assert.equal("Neck", byName[2])
      assert.equal("Hands", byName[10])
      assert.equal("Ring 2", byName[12])
      assert.equal("Trinket 1", byName[13])
      assert.equal("Back", byName[15])
      assert.equal("Main hand", byName[16])
      assert.equal("Off hand", byName[17])
      assert.equal("Ranged", byName[18])
    end)

    it("describes the all-slots toggle it offers", function()
      installPalette(function() return true end)
      local toggle = Rotation.group().args.builder.args.items.args.all
      assert.equal("toggle", toggle.type)
      assert.equal(0, toggle.order)
      assert.equal("Show every equipment slot", toggle.name)
      assert.is_truthy(toggle.desc:find("trinkets", 1, true))
    end)

    it("puts each spell's icon on its row", function()
      installPalette(function() return true end)
      ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
      local args = Rotation.group().args.builder.args.spells.args
      local withIcon = 0
      for _, row in pairs(args) do
        if row.name:find("|Ttex:ex:0|t", 1, true) then withIcon = withIcon + 1 end
      end
      assert.equal(1, withIcon)
    end)

    it("puts each slot's icon on its row", function()
      installPalette(function() return true end)
      ns.Display.itemIcon = function(slot) return slot == 13 and "tex:tr" or nil end
      assert.is_truthy(Rotation.group().args.builder.args.items.args.i1.name
        :find("|Ttex:tr:0|t", 1, true))
    end)

    it("introduces the tab as a list, at reading size", function()
      installPalette(function() return true end)
      local row = Rotation.group().args.builder.args.intro
      assert.equal("description", row.type)
      assert.equal(1, row.order)
      assert.equal("full", row.width)
      assert.equal("medium", row.fontSize)
    end)

    -- An empty search must hand back the SAME table, not a copy: the short-circuit is the only
    -- thing keeping a filter off every row on every repaint at 10 Hz.
    it("returns the list untouched when nothing is typed", function()
      installPalette(function() return true end)
      local rows = { { label = "one" }, { label = "two" } }
      assert.equal(rows, Rotation.filtered(rows, function(r) return r.label end))
      Rotation.setSearch("o")
      assert.is_not.equal(rows, Rotation.filtered(rows, function(r) return r.label end))
    end)

    -- Options.table() is built on open, which can happen before AceDB has a profile -- the panel
    -- must fall back to the shipped defaults rather than erroring on a nil profile.
    -- Discriminating on purpose: the shipped default is `false`, so an empty-table fallback reads
    -- identically and a spec asserting "false" proves nothing. Flip the default and watch it follow.
    it("reads the shipped defaults before a profile exists", function()
      installPalette(function() return true end)
      local DB = helper.load("Elmira/Core/DB.lua")
      ns.db = nil
      DB.defaults.profile.paletteAllSlots = true
      assert.is_true(Rotation.group().args.builder.args.items.args.all.get())
      assert.is_true(#Rotation.paletteItems() > 2, "should follow the default, not an empty table")
      DB.defaults.profile.paletteAllSlots = false
      assert.is_false(Rotation.group().args.builder.args.items.args.all.get())
      assert.equal(2, #Rotation.paletteItems())
    end)

    -- The defaults table is shared: every profile made afterwards is copied from it. A setter that
    -- fell back to it would not lose the click, it would change the default for everyone.
    it("never writes into the shipped defaults when there is no profile", function()
      installPalette(function() return true end)
      local DB = helper.load("Elmira/Core/DB.lua")
      ns.db = nil
      DB.defaults.profile.paletteAllSlots = false
      Rotation.group().args.builder.args.items.args.all.set(nil, true)
      assert.is_false(DB.defaults.profile.paletteAllSlots,
        "the toggle wrote into the shipped defaults")
    end)

    it("renders without Core/Palette loaded rather than erroring", function()
      ns.Palette = nil
      assert.same({}, Rotation.paletteSpells())
      assert.same({}, Rotation.paletteItems())
    end)
  end)

  -- The Builder's rotation list (step 3): the rows being edited, above the palette they come from.
  describe("Builder rotation list", function()
    local BUILD = { key = "PALADIN_EXODIN", entries = {
      { spell = "EXORCISM" },
      { spell = "DIVINE_STORM", label = "3 HP", when = { { "buff", "HOLY_POWER_BUFF", min = 3 } } },
      { item = 13, when = { { "item_ready", 13 } } },
    } }

    local function install(origin)
      helper.load("Elmira/Core/Palette.lua")
      ns.Display.currentPack = function()
        return { class = "PALADIN", catalog = { PALADIN = CATALOG }, spells = {}, builds = {} }
      end
      ns.Display.activeBuild = function() return {}, "THE_KEY", nil end
      ns.Display.refresh = function() end
      ns.Detect = { readableName = function(key) return key end }
      ns.db = { profile = { paletteAllSlots = false } }
      installUserBuilds{
        -- Answers on the KEY, like the real find: a fake that hands back a build for a nil key
        -- makes "nothing is active" untestable and hides the guard that handles it.
        find = function(_, k)
          if not k then return nil end
          return BUILD, origin, { name = "Mine" }
        end,
        list = function() return {} end,
      }
    end

    it("lists the rotation in priority order, naming each line", function()
      install("fork")
      local rows = Rotation.listRows()
      assert.equal(3, #rows)
      assert.equal("EXORCISM", rows[1].label)
      assert.equal(1, rows[1].index)
      -- An item line binds to the SLOT and is named for it, not for whatever is in it today.
      assert.equal("Trinket 1", rows[3].label)
      assert.equal(13, rows[3].item)
    end)

    it("carries each line's spell, and its icon, onto the row", function()
      install("fork")
      ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
      assert.equal("EXORCISM", Rotation.listRows()[1].spell)
      local row = Rotation.group().args.builder.args.list.args.r1.args.what
      assert.equal("description", row.type)
      assert.equal(1, row.order)
      assert.equal(1.6, row.width)
      assert.is_truthy(row.name:find("|Ttex:ex:0|t", 1, true))
    end)

    -- Class-scoped, like every other fork lookup: db.global is shared across characters.
    it("hands the class pack to the lookup", function()
      install("fork")
      local classes = {}
      ns.UserBuilds.find = function(pk, k)
        classes[#classes + 1] = (pk and pk.class) or "<no pack>"
        if not k then return nil end
        return BUILD, "fork", { name = "Mine" }
      end
      Rotation.listRows()
      -- The rendered list looks it up again for the condition summary; both must be class-scoped.
      Rotation.group()
      assert.is_true(#classes > 0)
      for _, c in ipairs(classes) do assert.equal("PALADIN", c) end
    end)

    it("says the rotation is yours to edit when it is", function()
      install("fork")
      assert.is_truthy(Rotation.group().args.builder.args.intro.name
        :find("top to bottom", 1, true))
    end)

    it("marks the ends, so the arrows can be greyed rather than doing nothing", function()
      install("fork")
      local rows = Rotation.listRows()
      assert.is_true(rows[1].first); assert.is_false(rows[1].last)
      assert.is_false(rows[2].first); assert.is_false(rows[2].last)
      assert.is_true(rows[3].last)
    end)

    it("is empty, not an error, when no rotation is active", function()
      install("fork")
      ns.Display.activeBuild = function() return nil, nil, nil end
      local rows, _, editable = Rotation.listRows()
      assert.same({}, rows)
      assert.is_false(editable)
      assert.is_truthy(Rotation.group().args.builder.args.list.args.none.name
        :find("no lines yet", 1, true))
    end)

    -- A template is read-only (ADR-0005, hard rule 7). The controls are ABSENT rather than present
    -- and dead: a control that silently does nothing is worse than one not offered.
    it("offers no arrows or checkbox on a template, and says why", function()
      install("pack")
      local args = Rotation.group().args.builder.args.list.args
      assert.is_truthy(args.r1.args.what)
      assert.is_nil(args.r1.args.on)
      assert.is_nil(args.r1.args.up)
      assert.is_nil(args.r1.args.down)
      assert.is_truthy(Rotation.group().args.builder.args.intro.name
        :find("cannot be edited", 1, true))
    end)

    it("offers all three on a rotation of your own", function()
      install("fork")
      local args = Rotation.group().args.builder.args.list.args
      assert.equal("toggle", args.r1.args.on.type)
      assert.equal("execute", args.r1.args.up.type)
      assert.equal("execute", args.r1.args.down.type)
      assert.is_true(args.r1.args.up.disabled, "the first line cannot move up")
      assert.is_false(args.r1.args.down.disabled)
      assert.is_true(args.r3.args.down.disabled, "the last line cannot move down")
    end)

    it("moves a line through UserBuilds and repaints", function()
      install("fork")
      local moved, repaints = nil, 0
      ns.UserBuilds.moveEntry = function(pk, k, i, d) moved = { pk and pk.class, k, i, d }; return true end
      ns.Display.refresh = function() repaints = repaints + 1 end
      local args = Rotation.group().args.builder.args.list.args
      args.r2.args.up.func()
      assert.same({ "PALADIN", "THE_KEY", 2, -1 }, moved)
      args.r2.args.down.func()
      assert.same({ "PALADIN", "THE_KEY", 2, 1 }, moved)
      -- Without the repaint the strip keeps showing the old order until something else moves it.
      assert.equal(2, repaints)
    end)

    it("turns a line off through UserBuilds and repaints", function()
      install("fork")
      local off, repaints = nil, 0
      ns.UserBuilds.setEntryDisabled = function(pk, k, i, v) off = { pk and pk.class, k, i, v }; return true end
      ns.Display.refresh = function() repaints = repaints + 1 end
      local row = Rotation.group().args.builder.args.list.args.r1.args.on
      assert.is_true(row.get())
      row.set(nil, false)
      assert.same({ "PALADIN", "THE_KEY", 1, true }, off)
      assert.equal(1, repaints)
    end)

    it("dims a line that is switched off", function()
      install("fork")
      BUILD.entries[1].disabled = true
      local args = Rotation.group().args.builder.args.list.args
      assert.is_truthy(args.r1.args.what.name:find("|cff9AA0A6", 1, true))
      assert.is_false(args.r1.args.on.get())
      BUILD.entries[1].disabled = nil
    end)

    -- The author's own note is more use than a count, so it wins when there is one.
    it("summarises what a line waits for, preferring the author's note", function()
      install("fork")
      local args = Rotation.group().args.builder.args.list.args
      assert.is_truthy(args.r2.args.what.name:find("3 HP", 1, true))
      assert.is_truthy(args.r1.args.what.name:find("always", 1, true))
    end)

    -- The summary falls back to the STORED build's `when` list, so the row still says something
    -- when the author left no note.
    it("falls back to counting the stored line's conditions", function()
      install("fork")
      BUILD.entries[2].label = nil
      local args = Rotation.group().args.builder.args.list.args
      assert.is_truthy(args.r2.args.what.name:find("1 condition", 1, true))
      BUILD.entries[2].label = "3 HP"
    end)

    it("counts conditions when a line has no note", function()
      install("fork")
      assert.equal("always", Rotation.conditionSummary({ }))
      assert.equal("always", Rotation.conditionSummary(nil))
      assert.equal("1 condition", Rotation.conditionSummary({ when = { { "buff", "X" } } }))
      assert.equal("2 conditions",
        Rotation.conditionSummary({ when = { { "buff", "X" }, { "buff", "Y" } } }))
    end)
  end)

  -- ADR-0015 §2: Customize forks the template AND activates the fork in the same click. The two
  -- halves must not come apart -- Hekili's copy-then-forget, where the copy must be separately
  -- activated and people carry on playing the original, is the failure this is designed against.
  describe("customize()", function()
    local function install()
      ns.Display.currentPack = function()
        return { class = "PALADIN", catalog = { PALADIN = CATALOG }, builds = {} }
      end
      ns.Display.refresh = function() end
      ns.Adapter = { today = function() return "2026-09-05" end }
    end

    it("forks the template and activates the fork, in one call", function()
      install()
      local forked, applied, repaints = nil, nil, 0
      installUserBuilds{ fork = function(_, k, o) forked = { k, o.today }; return "USER_MINE" end }
      ns.Wizard = { apply = function(k) applied = k; return true end }
      ns.Display.refresh = function() repaints = repaints + 1 end

      local ok, key = Rotation.customize("PALADIN_EXODIN")
      assert.is_true(ok)
      assert.equal("USER_MINE", key)
      assert.same({ "PALADIN_EXODIN", "2026-09-05" }, forked)
      assert.equal("USER_MINE", applied, "the fork was made but never activated")
      assert.equal(1, repaints)
    end)

    it("is what the Customize button on a template row does", function()
      install()
      local forked
      installUserBuilds{ fork = function(_, k) forked = k; return "USER_MINE" end }
      ns.Wizard = { apply = function() return true end }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local button = Rotation.group().args.rotations.args.templates.args.t1.args.customize
      assert.equal("execute", button.type)
      assert.equal("Customize", button.name)
      button.func()
      assert.equal("PALADIN_EXODIN", forked)
    end)

    it("describes what the button will do before it is pressed", function()
      install()
      installUserBuilds{ fork = function() return "USER_MINE" end }
      ns.Wizard = { apply = function() return true end }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local button = Rotation.group().args.rotations.args.templates.args.t1.args.customize
      assert.is_truthy(button.desc:find("editable copy", 1, true))
      assert.is_truthy(button.desc:find("switches to it", 1, true))
    end)

    it("hands the class pack to the fork", function()
      install()
      local gotClass
      installUserBuilds{ fork = function(pk) gotClass = pk and pk.class; return "USER_MINE" end }
      ns.Wizard = { apply = function() return true end }
      Rotation.customize("PALADIN_EXODIN")
      assert.equal("PALADIN", gotClass)
    end)

    it("reports the reason when the fork cannot be made", function()
      install()
      installUserBuilds{ fork = function() return nil, "unknown template" end }
      local ok, err = Rotation.customize("PALADIN_NOPE")
      assert.is_false(ok)
      assert.equal("unknown template", err)
    end)

    -- The fork still exists in that case, and is on the Rotations tab: saying so beats a click that
    -- appears to have done nothing.
    it("reports when the fork was made but could not be activated", function()
      install()
      installUserBuilds{ fork = function() return "USER_MINE" end }
      ns.Wizard = { apply = function() return false, "no profile" end }
      local ok, err = Rotation.customize("PALADIN_EXODIN")
      assert.is_false(ok)
      assert.equal("no profile", err)
    end)

    it("says so rather than erroring when the builds module is absent", function()
      install()
      ns.UserBuilds = nil
      local ok, err = Rotation.customize("PALADIN_EXODIN")
      assert.is_false(ok)
      assert.is_truthy(err:find("not loaded", 1, true))
    end)
  end)

  describe("statusLines()", function()
    it("says so plainly when nothing is active", function()
      ns.Display.activeBuild = function() return nil, nil end
      assert.same({ "No rotation is active yet." }, Rotation.statusLines())
    end)

    -- The truncation bug: `local _, key = cond and Display.activeBuild()` reads the SECOND return,
    -- which an `and` expression discards. It rendered as "No rotation is active yet." forever.
    it("names the running rotation, reading activeBuild's second return", function()
      installPack()
      local lines = Rotation.statusLines()
      assert.equal("Running: Exodin", lines[1])
    end)

    it("names the template a fork came from", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function() return {}, "fork",
                        { name = "My Exodin", derivedFrom = "PALADIN_EXODIN",
                          derivedAt = "2026-08-01" } end }
      local lines = Rotation.statusLines()
      assert.equal("Running: My Exodin", lines[1])
      assert.equal("Yours, forked from Exodin.", lines[2])
      assert.is_nil(lines[3])
    end)

    -- Display.activeBuild returns `nil, key, reason` when the build fails to compile: the key
    -- survives, the rotation does not. Reading the key alone printed "Running: Exodin" while
    -- nothing was queued -- the panel's headline stating a falsehood.
    it("says a selected build could not be loaded, rather than calling it Running", function()
      installPack()
      ns.Display.activeBuild = function()
        return nil, "PALADIN_EXODIN", "build 'PALADIN_EXODIN' failed to compile (2 problem(s))"
      end
      local lines = Rotation.statusLines()
      assert.equal(1, #lines)
      assert.is_nil(lines[1]:find("Running", 1, true))
      assert.is_truthy(lines[1]:find("Exodin", 1, true))
      assert.is_truthy(lines[1]:find("could not be loaded", 1, true))
      assert.is_truthy(lines[1]:find("failed to compile", 1, true))
    end)

    it("still names the build when the failure carries no reason", function()
      installPack()
      ns.Display.activeBuild = function() return nil, "PALADIN_EXODIN", nil end
      assert.is_truthy(Rotation.statusLines()[1]:find("Exodin", 1, true))
    end)

    -- ADR-0010: a template updated by a release since the fork was taken is offered as a diff,
    -- never rebased. Saying it happened is the half that is useful on its own.
    it("reports a parent that has been updated since the fork", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function() return {}, "fork",
                        { name = "My Exodin", derivedFrom = "PALADIN_EXODIN",
                          derivedAt = "2026-07-01" } end }
      local lines = Rotation.statusLines()
      assert.is_truthy(lines[3]:find("has been updated since you forked it", 1, true))
      assert.is_truthy(lines[3]:find("2026-08-01", 1, true))
    end)

    -- Partial-module guard, the same asymmetry as forkRows' `list` check: a UserBuilds that can
    -- answer `find` but not `catalogUpdated` must lose the staleness line, not the whole panel.
    it("drops the staleness line rather than erroring when catalogUpdated is missing", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      ns.UserBuilds = { find = function() return {}, "fork",
                        { name = "Mine", derivedFrom = "PALADIN_EXODIN",
                          derivedAt = "2026-01-01" } end }
      local lines = Rotation.statusLines()
      assert.equal("Yours, forked from Exodin.", lines[2])
      assert.is_nil(lines[3])
    end)

    it("says nothing about a parent when the fork is not derived from one", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function() return {}, "fork", { name = "Scratch" } end }
      local lines = Rotation.statusLines()
      assert.equal("Yours, not derived from a template.", lines[2])
      -- Stops there: the parent lines below it would name a template that does not exist.
      assert.is_nil(lines[3])
    end)

    -- The lookup is class-scoped: db.global is shared across characters, so a fork only belongs to
    -- this one because find() is handed the pack. Dropping the pack silently widens that.
    it("hands the class pack to the fork lookup", function()
      installPack()
      -- Every call, not the last: displayName() does its own lookup with its own pack, so asserting
      -- on a single captured value passes even when statusLines hands over nothing.
      local classes = {}
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ find = function(pk)
        classes[#classes + 1] = (pk and pk.class) or "<no pack>"
        return {}, "fork", {}
      end }
      Rotation.statusLines()
      assert.is_true(#classes > 0, "the fork lookup was never reached")
      for _, class in ipairs(classes) do assert.equal("PALADIN", class) end
    end)

    it("renders the status block as one description row per line", function()
      installPack()
      local args = Rotation.group().args.rotations.args.status.args
      assert.equal("description", args.line1.type)
      assert.equal(1, args.line1.order)
      assert.equal("full", args.line1.width)
      assert.equal("medium", args.line1.fontSize)
      assert.equal("Running: Exodin", args.line1.name)
      assert.is_nil(args.line2)
    end)

    it("renders one row per line when there are several", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{ list = function() return {} end,
                        find = function() return {}, "fork",
                        { name = "Mine", derivedFrom = "PALADIN_EXODIN" } end }
      local args = Rotation.group().args.rotations.args.status.args
      assert.equal(2, args.line2.order)
      assert.equal("Yours, forked from Exodin.", args.line2.name)
    end)
  end)

  describe("templateRows()", function()
    it("is empty, not an error, before a class pack is loaded", function()
      assert.same({}, Rotation.templateRows())
    end)

    it("marks the running template active and leaves the others alone", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local rows = Rotation.templateRows()
      assert.is_true(rows[1].active)
      assert.is_false(rows[2].active)
    end)

    -- The catalog is read-only and shipped-only (ADR-0005, hard rule 7). A template row carrying a
    -- set/get would be an edit surface on it.
    it("renders templates as read-only rows", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "medium",
                       updated = "2026-08-01", fits = true } }
      local row = Rotation.group().args.rotations.args.templates.args.t1
      assert.equal("group", row.type)
      assert.equal("description", row.args.what.type)
      assert.is_nil(row.args.what.set)
      assert.is_truthy(row.args.what.name:find("Exodin", 1, true))
      assert.is_truthy(row.args.what.name:find("2026-08-01", 1, true))
    end)

    -- The row model carries `active`; the marker is what the player actually sees. Testing only the
    -- model leaves the render free to mark every row the same.
    it("marks the running template's row and leaves the others unmarked", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local args = Rotation.group().args.rotations.args.templates.args
      assert.is_truthy(args.t1.args.what.name:find(">>", 1, true))
      assert.is_nil(args.t2.args.what.name:find(">>", 1, true))
      assert.is_truthy(args.t2.args.what.name:find("--", 1, true))
    end)

    it("says on the row when a template needs gear or runes you do not have", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false } }
      local row = Rotation.group().args.rotations.args.templates.args.t1
      assert.is_truthy(row.args.what.name:find("needs gear or runes", 1, true))
    end)

    -- Wizard.choices reaches the catalog and Detect; an error there must not take the whole panel
    -- down with it, or one bad catalog entry means no settings window at all.
    it("renders an empty list rather than propagating a wizard error", function()
      installPack()
      ns.Wizard = { choices = function() error("bad catalog entry") end }
      assert.same({}, Rotation.templateRows())
    end)

    it("tags a row with its difficulty and marks an experimental one", function()
      installPack()
      installWizard{ { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", difficulty = "hard",
                       experimental = true, fits = true } }
      local name = Rotation.group().args.rotations.args.templates.args.t1.args.what.name
      assert.is_truthy(name:find("hard", 1, true))
      assert.is_truthy(name:find("experimental", 1, true))
    end)

    it("says templates cannot be edited, and names the way to get a copy", function()
      installPack()
      installWizard{}
      local note = Rotation.group().args.rotations.args.note
      assert.equal("description", note.type)
      assert.equal(3, note.order)
      assert.equal("full", note.width)
      assert.is_truthy(note.name:find("read-only", 1, true))
      assert.is_truthy(note.name:find("Customize", 1, true))
    end)

    it("says so when the class ships no templates", function()
      installPack()
      installWizard{}
      assert.is_truthy(Rotation.group().args.rotations.args.templates.args.none.name
        :find("No templates ship", 1, true))
    end)
  end)

  describe("forkRows()", function()
    it("says so when you have made none", function()
      installPack()
      assert.is_truthy(Rotation.group().args.rotations.args.mine.args.none.name
        :find("not made a rotation of your own", 1, true))
    end)

    -- The other truncation bug: `local _, _, fork = ns.UserBuilds and find(...)` discarded the fork
    -- record, so every row rendered as "not from a template".
    it("lists each fork with the template it came from", function()
      installPack()
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function() return {}, "fork",
               { name = "My Exodin", derivedFrom = "PALADIN_EXODIN" } end,
      }
      local rows = Rotation.forkRows()
      assert.equal(1, #rows)
      assert.equal("My Exodin", rows[1].name)
      assert.equal("PALADIN_EXODIN", rows[1].derivedFrom)
      assert.is_truthy(Rotation.group().args.rotations.args.mine.args.f1.name
        :find("from Exodin", 1, true))
    end)

    it("carries the key and marks the running fork active", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{
        list = function() return { "USER_MINE", "USER_OTHER" } end,
        find = function(_, key) return {}, "fork", { name = key } end,
      }
      local rows = Rotation.forkRows()
      assert.equal("USER_MINE", rows[1].build)
      assert.is_true(rows[1].active)
      assert.equal("USER_OTHER", rows[2].build)
      assert.is_false(rows[2].active)
    end)

    it("marks the running fork's row and leaves the others unmarked", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{
        list = function() return { "USER_MINE", "USER_OTHER" } end,
        find = function(_, key) return {}, "fork", { name = key } end,
      }
      local args = Rotation.group().args.rotations.args.mine.args
      assert.is_truthy(args.f1.name:find(">>", 1, true))
      assert.is_nil(args.f2.name:find(">>", 1, true))
      assert.is_truthy(args.f2.name:find("--", 1, true))
    end)

    -- Same widening the statusLines test guards: db.global is shared across characters, so the
    -- pack is what keeps a mage out of a paladin's forks.
    it("hands the class pack to every fork lookup", function()
      installPack()
      local classes = {}
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function(pk)
          classes[#classes + 1] = (pk and pk.class) or "<no pack>"
          return {}, "fork", { name = "Mine" }
        end,
      }
      Rotation.forkRows()
      assert.is_true(#classes > 0, "the fork lookup was never reached")
      for _, class in ipairs(classes) do assert.equal("PALADIN", class) end
    end)

    it("renders without erroring when UserBuilds is loaded but has no list yet", function()
      installPack()
      installUserBuilds{ find = function() return nil end }
      assert.same({}, Rotation.forkRows())
    end)

    it("scopes the fork list to this class's pack", function()
      installPack()
      local gotClass
      installUserBuilds{ list = function(pk) gotClass = pk and pk.class; return {} end,
                        find = function() return nil end }
      Rotation.forkRows()
      assert.equal("PALADIN", gotClass)
    end)

    it("labels a fork that came from no template, as a read-only row", function()
      installPack()
      installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                        find = function() return {}, "fork", { name = "Scratch" } end }
      local row = Rotation.group().args.rotations.args.mine.args.f1
      assert.equal("description", row.type)
      assert.equal(1, row.order)
      assert.equal("full", row.width)
      assert.is_nil(row.set)
      assert.is_truthy(row.name:find("not from a template", 1, true))
    end)
  end)

  describe("displayName()", function()
    it("prefers the catalog's playstyle name over the raw key", function()
      installPack()
      assert.equal("Exodin", Rotation.displayName("PALADIN_EXODIN"))
    end)

    it("falls back to the key, because a blank row is worse than an ugly one", function()
      installPack()
      assert.equal("PALADIN_UNKNOWN", Rotation.displayName("PALADIN_UNKNOWN"))
    end)

    it("answers for a non-string rather than erroring", function()
      assert.equal("?", Rotation.displayName(nil))
    end)
  end)
end)
