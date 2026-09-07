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
    -- The REAL deep copy, for the same reason: the Builder's draft has to copy a fork exactly as
    -- deeply as forking one does, and a fake that copied one level would share every `when` list
    -- with the stored build -- so the rotation would change before Save was pressed.
    t.copy = t.copy or realUserBuilds.copy
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
    -- The Builder reads the live display: the queue for its mirror and its green rows, the gate
    -- rows for its orange ones. Both are stubbed to "nothing on screen" here and overridden per
    -- test, so a spec that never mentions the display still exercises the empty case.
    ns.Display = { activeBuild = function() return {}, "PALADIN_EXODIN", nil end,
                   currentPack = function() return nil end,
                   currentQueue = function() return nil end,
                   gateRows = function() return nil, {} end,
                   refresh = function() end }
    helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Gates.lua")
    helper.load("Elmira/Core/Palette.lua")
    helper.load("Elmira/Core/Conditions.lua")
    helper.load("Elmira/Core/Diagnostics.lua")
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
      assert.equal(7, args.spells.order)
      assert.equal(8, args.items.order)
      assert.equal("group", args.list.type)
      assert.equal(4, args.list.order)
      assert.is_truthy(args.intro.name)
      -- The queue strip is mirrored ABOVE everything (ADR-0015 amendment): the status column below
      -- only means anything read against the queue that is actually on screen.
      assert.equal("group", args.mirror.type)
      assert.equal(1, args.mirror.order)
    end)

    -- AceConfig renders a `description` row in GameFontHighlightSmall (10pt) unless `fontSize` says
    -- otherwise (AceConfigDialog-3.0.lua:1404-1410). The Builder is nearly all description rows --
    -- the line list, the palette, the status column, the Checks -- so its CONTENT was two points
    -- smaller than the labels above it, on the busiest page in the addon.
    --
    -- A walk rather than a list: a row added tomorrow has to be caught by this too. The `type`
    -- assertion is part of the guard, because a row that lost its type is not one this would see.
    it("renders every description at the same size as the labels around it", function()
      local function walk(node, path)
        for key, row in pairs(node.args or {}) do
          local where = path .. "." .. tostring(key)
          assert.is_table(row, where .. " is not a table")
          assert.is_string(row.type, where .. " has no type")
          if row.type == "description" then
            assert.equal("medium", row.fontSize, where .. " is drawn smaller than its own label")
          elseif row.type == "group" then
            walk(row, where)
          end
        end
      end
      walk(Rotation.group(), "rotation")
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
      assert.equal(2, row.order)
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
      assert.equal(1.0, row.width)
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

    -- The arrows and the toggle write to the DRAFT and they do NOT repaint: the display is still
    -- running the SAVED rotation, and repainting here would show a queue built from an order the
    -- player has not committed to. Before the draft existed both wrote straight through, so the
    -- strip flickered through half-finished orderings while a rotation was being rearranged.
    it("moves a line in the draft, leaving the store and the display alone", function()
      install("fork")
      local repaints = 0
      ns.Display.refresh = function() repaints = repaints + 1 end
      local args = Rotation.group().args.builder.args.list.args
      args.r2.args.up.func()
      assert.equal(0, repaints)
      assert.equal("DIVINE_STORM", Rotation.listRows()[1].spell)
      assert.equal("EXORCISM", Rotation.listRows()[2].spell)
      assert.equal("EXORCISM", BUILD.entries[1].spell, "the store is untouched until Save")
      Rotation.group().args.builder.args.list.args.r1.args.down.func()
      assert.equal("EXORCISM", Rotation.listRows()[1].spell)
    end)

    it("turns a line off in the draft, leaving the store and the display alone", function()
      install("fork")
      local repaints = 0
      ns.Display.refresh = function() repaints = repaints + 1 end
      local row = Rotation.group().args.builder.args.list.args.r1.args.on
      assert.is_true(row.get())
      row.set(nil, false)
      assert.equal(0, repaints)
      assert.is_true(Rotation.listRows()[1].disabled)
      assert.is_nil(BUILD.entries[1].disabled)
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
    it("falls back to the line's conditions IN WORDS", function()
      install("fork")
      BUILD.entries[2].label = nil
      local args = Rotation.group().args.builder.args.list.args
      assert.is_truthy(args.r2.args.what.name:find("at 3 stacks or more", 1, true))
      BUILD.entries[2].label = "3 HP"
    end)

    -- It used to count them. "2 conditions" said the same thing about every row that had two,
    -- which distinguished nothing -- and the whole point of the line is telling rows apart.
    it("names a line's conditions rather than counting them", function()
      install("fork")
      assert.equal("always", Rotation.conditionSummary({ }))
      assert.equal("always", Rotation.conditionSummary(nil))
      assert.equal("X is up", Rotation.conditionSummary({ when = { { "buff", "X" } } }))
      assert.equal("X is up, Y is up",
        Rotation.conditionSummary({ when = { { "buff", "X" }, { "buff", "Y" } } }))
    end)
  end)

  -- ------------------------------------------------------------------ M5e step 4
  --
  -- The Builder as an editor: a draft, a conditions pane, a live status column and the queue
  -- mirrored above them. Everything below runs against the REAL Core/UserBuilds, Core/Schema,
  -- Core/Conditions and the real compile cache in Core/Slash -- the only fakes are the client-shaped
  -- edges (the pack, the state, the queue). A stubbed save would have proved the panel calls
  -- something; what has to be proved is that the rotation on screen changes.
  describe("the Builder as an editor", function()
    local FakeState = require("tests.fake_state")
    local PACK, forkKey, state, queue

    local function packTables()
      return { spells = PACK.spells, sets = PACK.sets, souls = PACK.souls, bonuses = PACK.bonuses }
    end

    local function compiledFork()
      return ns.compileBuild(realUserBuilds.find(PACK, forkKey), packTables())
    end

    -- One line per status the column can show, so the sweep below cannot pass by producing the
    -- same answer for every row:
    --   1 EXORCISM      -- conditions pass and it is in the queue        -> firing
    --   2 DIVINE_STORM  -- a set bonus this character lacks              -> blocked (static gate)
    --   3 JUDGEMENT     -- nothing stops it; a line above it is going    -> waiting
    --   4 HOLY_WRATH    -- a nested `any`, which the pane will not edit  -> complex
    --   5 item 13       -- an inventory slot, not a spell
    local function newPack()
      return {
        class = "PALADIN",
        catalog = { PALADIN = { { build = "TEMPLATE", playstyle = "Template",
                                  updated = "2026-08-01" } } },
        spells = {
          EXORCISM = { id = 1 }, DIVINE_STORM = { id = 2 }, JUDGEMENT = { id = 3 },
          HOLY_WRATH = { id = 4 }, CONSECRATION = { id = 5 },
          SEAL_OF_TESTING = { id = 6, seal = true },
          VENGEANCE_BUFF = { id = 7, proc = true },
          RUNE_PURIFYING_POWER = { id = 8, rune = "wrist" },
        },
        sets = {}, souls = {},
        bonuses = { HOLY_POWER_CONSUME = { note = "Divine Storm consumes Holy Power" },
                    HOLY_WRATH_INSTANT = { note = "Holy Wrath is instant" } },
        builds = {
          TEMPLATE = {
            schema = 1, key = "TEMPLATE", name = "Template", class = "PALADIN", entries = {
              { spell = "EXORCISM", when = { { "resource", "MANA", minPct = 40 } } },
              { spell = "DIVINE_STORM", when = { { "bonus", "HOLY_POWER_CONSUME" } } },
              { spell = "JUDGEMENT" },
              { spell = "HOLY_WRATH", when = { { "bonus", "HOLY_WRATH_INSTANT" },
                  { "any", { "target_type", "Undead" },
                           { "rune", "RUNE_PURIFYING_POWER" } } } },
              { item = 13, when = { { "item_ready", 13 } } },
            },
          },
        },
      }
    end

    -- The queue as the display would have it: one slot, holding the COMPILED entry, which is what
    -- carries the saved position the status column maps through.
    local function queueOf(...)
      local compiled, out = compiledFork(), {}
      for i, at in ipairs({ ... }) do
        local entry = compiled.entries[at]
        out[i] = { spell = entry.spell, item = entry.item, entry = entry }
      end
      return out
    end

    local function installEditor()
      helper.load("Elmira/Core/Slash.lua")
      PACK = newPack()
      ns.db = { global = { userBuilds = {} }, profile = { paletteAllSlots = false } }
      ns.UserBuilds = realUserBuilds
      ns.Detect = { readableName = function(key) return key end }
      state = FakeState.new{ bonuses = { HOLY_POWER_CONSUME = false, HOLY_WRATH_INSTANT = true },
                             items = { [13] = {} } }
      ns.API = { GetState = function() return state end }
      forkKey = realUserBuilds.fork(PACK, "TEMPLATE", { name = "Mine" })

      ns.Display.currentPack = function() return PACK end
      ns.Display.activeBuild = function() return compiledFork(), forkKey, "pinned" end
      ns.Display.gateRows = function()
        local compiled = compiledFork()
        return compiled, ns.Gates.evaluate(compiled, state, packTables()), forkKey
      end
      queue = nil
      ns.Display.currentQueue = function() return queue end
      ns.Display.spellIcon = function() return nil end
      ns.Display.itemIcon = function() return nil end
      Rotation = helper.load("Elmira/Options/Rotation.lua")
      return forkKey
    end

    local function builder() return Rotation.group().args.builder.args end

    before_each(function() installEditor() end)

    describe("the draft", function()
      it("copies the fork's lines and stamps each with where it came from", function()
        local d = Rotation.draft()
        assert.equal(forkKey, d.key)
        assert.equal(5, #d.entries)
        assert.is_false(d.dirty)
        for i, entry in ipairs(d.entries) do assert.equal(i, entry.src) end
      end)

      -- All the way down. A draft sharing a `when` list with the stored build would change the
      -- saved rotation on the first keystroke, and Discard could not put it back.
      it("copies deeply, so editing a condition does not touch the stored build", function()
        local d = Rotation.draft()
        d.entries[1].when[1].minPct = 90
        assert.equal(40, realUserBuilds.find(PACK, forkKey).entries[1].when[1].minPct)
      end)

      -- A template is read-only (ADR-0005, hard rule 7). No draft at all rather than an unsaveable
      -- one: a Save button that always refuses is worse than no Save button.
      it("does not exist for a template", function()
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        assert.is_nil(Rotation.draft())
        local args = builder()
        assert.is_nil(args.editing)
        assert.is_nil(args.pane)
        assert.is_nil(args.list.args.r1.args.up)
        assert.is_truthy(args.intro.name:find("cannot be edited", 1, true))
      end)

      it("is thrown away when the active rotation changes", function()
        Rotation.moveRow(1, 1)
        assert.is_true(Rotation.draft().dirty)
        local other = realUserBuilds.fork(PACK, "TEMPLATE", { name = "Other" })
        forkKey = other
        local d = Rotation.draft()
        assert.equal(other, d.key)
        assert.is_false(d.dirty, "a fresh rotation opens clean")
        assert.equal("EXORCISM", d.entries[1].spell)
      end)

      it("says whether it has unsaved changes, and offers Save and Discard accordingly", function()
        local args = builder().editing.args
        assert.is_truthy(args.state.name:find("Mine", 1, true))
        assert.is_truthy(args.state.name:find("saved", 1, true))
        assert.is_true(args.save.disabled, "nothing to save yet")
        assert.is_true(args.discard.disabled)

        Rotation.moveRow(1, 1)
        args = builder().editing.args
        assert.is_truthy(args.state.name:find("unsaved changes", 1, true))
        assert.is_false(args.save.disabled)
        assert.is_false(args.discard.disabled)
      end)
    end)

    describe("editing the list", function()
      it("moves a line in the draft and leaves the stored rotation alone until Save", function()
        assert.is_true(Rotation.moveRow(1, 1))
        assert.equal("DIVINE_STORM", Rotation.listRows()[1].spell)
        assert.equal("EXORCISM", realUserBuilds.find(PACK, forkKey).entries[1].spell)
        assert.is_false(Rotation.moveRow(1, -1), "off the top is refused, not wrapped")
        assert.is_false(Rotation.moveRow(99, 1))
      end)

      -- Moving the row you are editing must not silently switch the pane to a different ability.
      it("carries the selection with the line it is on", function()
        Rotation.selectRow(2)
        Rotation.moveRow(2, -1)
        assert.equal(1, Rotation.draft().selected)
        local _, entry = Rotation.paneModel()
        assert.equal("DIVINE_STORM", entry.spell)
        Rotation.selectRow(3)
        Rotation.moveRow(2, 1)  -- swaps 2 and 3, so the selection follows to 2
        assert.equal(2, Rotation.draft().selected)
      end)

      it("switches a line off in the draft, storing nil rather than false", function()
        assert.is_true(Rotation.setRowDisabled(1, true))
        assert.is_true(Rotation.draft().entries[1].disabled)
        assert.is_true(Rotation.setRowDisabled(1, false))
        assert.is_nil(Rotation.draft().entries[1].disabled)
        assert.is_false(Rotation.setRowDisabled(99, true))
      end)

      -- The counterpart to click-to-append. Without it a mis-clicked palette icon could only be
      -- undone by discarding every other edit in the draft.
      it("removes a line, and moves the selection off it", function()
        Rotation.selectRow(2)
        assert.is_true(Rotation.removeRow(2))
        assert.equal(4, #Rotation.draft().entries)
        assert.is_nil(Rotation.draft().selected)
        assert.equal("JUDGEMENT", Rotation.listRows()[2].spell)
        Rotation.selectRow(3)
        Rotation.removeRow(1)
        assert.equal(2, Rotation.draft().selected, "the selection follows its line upwards")
        assert.is_false(Rotation.removeRow(99))
      end)

      it("appends from the palette, at the bottom, selected and unsaved", function()
        assert.is_true(Rotation.appendSpell("CONSECRATION"))
        local d = Rotation.draft()
        assert.equal(6, #d.entries)
        assert.equal("CONSECRATION", d.entries[6].spell)
        assert.is_nil(d.entries[6].src, "an appended line is in no saved rotation yet")
        assert.equal(6, d.selected, "the next thing anyone wants is its conditions")
        assert.is_true(Rotation.appendItem(14))
        assert.equal(14, Rotation.draft().entries[7].item)
        assert.is_false(Rotation.appendSpell(nil))
        assert.is_false(Rotation.appendItem("13"))
      end)

      -- An unconditional line at the TOP would take over the whole rotation the moment it saved.
      it("appends a line with no conditions, which is why it goes to the bottom", function()
        Rotation.appendSpell("CONSECRATION")
        assert.is_nil(Rotation.draft().entries[6].when)
        assert.equal("always", Rotation.listRows()[6].summary)
      end)

      it("makes the palette clickable on a fork and inert on a template", function()
        local row = builder().spells.args.s1
        assert.equal("execute", row.type)
        assert.is_function(row.func)
        row.func()
        assert.equal(6, #Rotation.draft().entries)

        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        assert.equal("description", builder().spells.args.s1.type)
        assert.equal("description", builder().items.args.i1.type)
      end)

      it("drives every list control from the rendered panel", function()
        local args = builder().list.args
        args.r2.args.edit.func()
        assert.equal(2, Rotation.draft().selected)
        args.r1.args.on.set(nil, false)
        assert.is_true(Rotation.draft().entries[1].disabled)
        args.r1.args.down.func()
        assert.equal("DIVINE_STORM", Rotation.listRows()[1].spell)
        builder().list.args.r5.args.remove.func()
        assert.equal(4, #Rotation.draft().entries)
      end)
    end)

    describe("saving", function()
      it("writes the draft, repaints, and re-stamps where each line now lives", function()
        local repaints = 0
        ns.Display.refresh = function() repaints = repaints + 1 end
        Rotation.selectRow(2)
        Rotation.moveRow(1, 1)
        assert.is_true(Rotation.save())
        assert.equal(1, repaints, "without this the strip keeps showing the old order")
        local stored = realUserBuilds.find(PACK, forkKey).entries
        assert.equal("DIVINE_STORM", stored[1].spell)
        assert.equal("EXORCISM", stored[2].spell)
        local d = Rotation.draft()
        assert.is_false(d.dirty)
        assert.equal(1, d.entries[1].src, "src follows the SAVED position, not the old one")
        assert.equal(1, d.selected, "the selection stays on the line it was on")
      end)

      -- The whole reason step 4 touches Core/Slash: the compile cache is keyed on the build TABLE
      -- and the save mutates it in place, so without invalidation the queue would go on running
      -- the order from before the save until the next /reload.
      it("changes what the live queue compiles to, with no reload", function()
        assert.equal("EXORCISM", compiledFork().entries[1].spell)
        Rotation.moveRow(1, 1)
        Rotation.save()
        assert.equal("DIVINE_STORM", compiledFork().entries[1].spell)
      end)

      it("keeps nothing of the editor's own bookkeeping in the stored rotation", function()
        Rotation.appendSpell("CONSECRATION")
        assert.is_true(Rotation.save())
        for _, entry in ipairs(realUserBuilds.find(PACK, forkKey).entries) do
          assert.is_nil(entry.src)
        end
      end)

      it("puts everything back on Discard", function()
        Rotation.moveRow(1, 1)
        Rotation.appendSpell("CONSECRATION")
        assert.is_true(Rotation.discard())
        local d = Rotation.draft()
        assert.is_false(d.dirty)
        assert.equal(5, #d.entries)
        assert.equal("EXORCISM", d.entries[1].spell)
      end)

      it("refuses a draft the compiler cannot read, and says which line", function()
        Rotation.appendSpell("CONSECRATION")
        Rotation.selectRow(6)
        Rotation.addCondition("buff")
        Rotation.setCondition(1, "key", "NOT_A_SPELL_IN_THE_PACK")
        local problems = Rotation.problems()
        assert.is_true(#problems > 0)
        assert.is_truthy(table.concat(problems, " "):find("line 6", 1, true))
        local ok = Rotation.save()
        assert.is_false(ok)
        assert.equal(5, #realUserBuilds.find(PACK, forkKey).entries, "nothing was written")
        local args = builder().editing.args
        assert.is_true(args.save.disabled, "Save is refused while a problem stands")
        assert.is_truthy(args.p1.name:find("line 6", 1, true))
      end)

      it("holds on to the reasons a refused save gave, until the next edit", function()
        -- Schema.validate rejects an empty rotation, which no per-condition compile can catch.
        for _ = 1, 5 do Rotation.removeRow(1) end
        assert.is_false(Rotation.save())
        assert.is_true(#Rotation.problems() > 0)
        Rotation.appendSpell("CONSECRATION")
        assert.same({}, Rotation.problems(), "an edit clears a stale complaint")
      end)

      it("refuses to save when the active rotation is not one of your own", function()
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        local ok, reasons = Rotation.save()
        assert.is_false(ok)
        assert.is_true(#reasons > 0)
        assert.same({}, Rotation.problems())
      end)
    end)

    describe("the conditions pane", function()
      it("is absent until a line is selected, then names the line", function()
        assert.is_nil(builder().pane)
        assert.is_nil(Rotation.paneModel())
        Rotation.selectRow(1)
        local pane = builder().pane
        assert.equal("group", pane.type)
        assert.equal(5, pane.order)
        assert.is_truthy(pane.name:find("EXORCISM", 1, true))
      end)

      it("draws one control group per condition, described in words", function()
        Rotation.selectRow(1)
        local args = builder().pane.args
        assert.equal("all", args.match.get())
        local row = args.conditions.args.c1
        assert.equal("mana at least 40%", row.name)
        assert.equal("resources", row.args.category.get())
        assert.equal("resource", row.args.field.get())
        assert.equal("minPct", row.args.op.get())
        assert.equal("MANA", row.args.key.get())
        assert.equal("40", row.args.amount.get())
        assert.is_false(row.args.negated.get())
      end)

      -- AceConfig round-trips a select value through the widget, so a numeric key comes back as a
      -- string and would never compare equal to the number the row holds.
      it("keys every select by a string, including inventory slots", function()
        Rotation.selectRow(5)
        local row = builder().pane.args.conditions.args.c1
        assert.equal("13", row.args.slot.get())
        row.args.slot.set(nil, "14")
        assert.equal(14, Rotation.draft().entries[5].when[1][2])
        for _, control in pairs(builder().pane.args.conditions.args.c1.args) do
          if control.type == "select" then
            for id in pairs(control.values) do assert.equal("string", type(id)) end
          end
        end
      end)

      it("edits a value, an operator, a field and a category from the rendered panel", function()
        Rotation.selectRow(1)
        builder().pane.args.conditions.args.c1.args.amount.set(nil, "90")
        assert.equal(90, Rotation.draft().entries[1].when[1].minPct)

        builder().pane.args.conditions.args.c1.args.op.set(nil, "maxPct")
        local cond = Rotation.draft().entries[1].when[1]
        assert.equal(90, cond.maxPct)
        assert.is_nil(cond.minPct, "changing the test must move the qualifier, not add one")

        -- A field change REPLACES the row: an operator or key carried over from the old field is a
        -- qualifier the new one does not have, and the panel would look right while the compiler
        -- rejected the result.
        builder().pane.args.conditions.args.c1.args.field.set(nil, "target_hp")
        assert.equal("target_hp", Rotation.draft().entries[1].when[1][1])
        builder().pane.args.conditions.args.c1.args.category.set(nil, "state")
        assert.same({ { "in_combat" } }, Rotation.draft().entries[1].when)
      end)

      it("offers only the fields of the chosen category", function()
        Rotation.selectRow(1)
        local row = builder().pane.args.conditions.args.c1
        assert.is_truthy(row.args.field.values.resource)
        assert.is_nil(row.args.field.values.in_combat)
        assert.is_truthy(row.args.category.values.gear)
      end)

      it("adds, negates and removes a condition", function()
        assert.is_true(Rotation.selectRow(3))
        assert.same({}, Rotation.paneModel().rows)
        builder().pane.args.add.set(nil, "in_combat")
        assert.same({ { "in_combat" } }, Rotation.draft().entries[3].when)
        builder().pane.args.conditions.args.c1.args.negated.set(nil, true)
        assert.same({ { "not", { "in_combat" } } }, Rotation.draft().entries[3].when)
        builder().pane.args.conditions.args.c1.args.remove.func()
        assert.same({}, Rotation.draft().entries[3].when)
        assert.is_nil(builder().pane.args.conditions.args.c1)
      end)

      it("switches the whole line between all and any", function()
        Rotation.selectRow(1)
        assert.is_true(Rotation.addCondition("in_combat"))
        assert.equal(2, #Rotation.draft().entries[1].when)
        builder().pane.args.match.set(nil, "any")
        local when = Rotation.draft().entries[1].when
        assert.equal(1, #when)
        assert.equal("any", when[1][1])
        assert.equal("any", Rotation.paneModel().match)
        builder().pane.args.match.set(nil, "all")
        assert.equal(2, #Rotation.draft().entries[1].when)
      end)

      -- Every pane setter answers whether it wrote, and every write marks the draft dirty --
      -- without which Save stays greyed out and the edit is unreachable however right it looks.
      it("answers whether it wrote, and marks the draft dirty when it did", function()
        Rotation.selectRow(1)
        assert.is_false(Rotation.draft().dirty)
        assert.is_true(Rotation.addCondition("in_combat"))
        assert.is_true(Rotation.draft().dirty)
        Rotation.discard(); Rotation.selectRow(1)

        assert.is_true(Rotation.setMatch("any"))
        assert.is_true(Rotation.draft().dirty)
        Rotation.discard(); Rotation.selectRow(1)

        assert.is_true(Rotation.setCondition(1, "value", 5))
        assert.is_true(Rotation.draft().dirty)
        Rotation.discard(); Rotation.selectRow(1)

        assert.is_true(Rotation.removeCondition(1))
        assert.is_true(Rotation.draft().dirty)
      end)

      it("gives a new condition a legal value rather than a blank that reports an error", function()
        Rotation.selectRow(3)
        Rotation.addCondition("buff")
        local when = Rotation.draft().entries[3].when
        assert.is_truthy(when[1][2], "a new condition arrives with a key already chosen")
        local _, errors = ns.Schema.compileWhen(when, packTables())
        assert.equal(0, #errors)
        assert.same({}, Rotation.problems())
        assert.is_false(Rotation.addCondition("no_such_field"))
      end)

      -- A slot-taking field has no key source to draw a default from, so it needs its own: without
      -- one, `item_ready` arrives with no slot and reports an error before it has been touched.
      it("gives a slot field a real slot to start on", function()
        Rotation.selectRow(3)
        assert.is_true(Rotation.addCondition("item_ready"))
        assert.same({ { "item_ready", 13 } }, Rotation.draft().entries[3].when)
        assert.same({}, Rotation.problems())
      end)

      -- Changing the field REPLACES the row, and the negation is a property of the row rather than
      -- of the field -- so it has to survive the replacement, or a `not` silently disappears.
      it("keeps the negation when the field or the category changes", function()
        Rotation.selectRow(3)
        Rotation.addCondition("in_combat")
        Rotation.setCondition(1, "negated", true)
        assert.same({ { "not", { "in_combat" } } }, Rotation.draft().entries[3].when)
        Rotation.setCondition(1, "kind", "not_moving")
        assert.same({ { "not", { "not_moving" } } }, Rotation.draft().entries[3].when)
        Rotation.setCondition(1, "category", "encounter")
        assert.equal("not", Rotation.draft().entries[3].when[1][1])
        assert.equal("enemies", Rotation.draft().entries[3].when[1][2][1])
        -- And an un-negated row must not gain one.
        Rotation.setCondition(1, "negated", nil)
        Rotation.setCondition(1, "kind", "in_combat")
        assert.same({ { "in_combat" } }, Rotation.draft().entries[3].when)
      end)

      -- Nested conditions are shown, never edited (owner decision, 2026-09-05). Read-only is not
      -- the same as hidden: the "why" of a line IS its conditions.
      it("shows a nested line in words and offers no controls", function()
        Rotation.selectRow(4)
        local model = Rotation.paneModel()
        assert.is_true(model.complex)
        local args = builder().pane.args
        assert.is_nil(args.match)
        assert.is_nil(args.conditions)
        assert.is_nil(args.add)
        assert.is_truthy(args.words.name:find("Holy Wrath is instant", 1, true))
        assert.is_truthy(args.words.name:find("target is Undead or Purifying Power engraved",
                                              1, true))
        assert.is_truthy(args.note.name:find("nested more deeply", 1, true))
      end)

      it("refuses every pane edit on a nested line, rather than rewriting it", function()
        Rotation.selectRow(4)
        local before = Rotation.draft().entries[4].when
        assert.is_false(Rotation.setMatch("any"))
        assert.is_false(Rotation.addCondition("in_combat"))
        assert.is_false(Rotation.removeCondition(1))
        assert.is_false(Rotation.setCondition(1, "op", "min"))
        assert.equal(before, Rotation.draft().entries[4].when)
        assert.is_false(Rotation.draft().dirty)
      end)

      it("refuses a pane edit when nothing is selected, or the field is not one it owns", function()
        assert.is_false(Rotation.setMatch("any"))
        assert.is_false(Rotation.setCondition(1, "op", "min"))
        Rotation.selectRow(1)
        assert.is_false(Rotation.setCondition(9, "op", "min"))
        assert.is_false(Rotation.setCondition(1, "spell", "EXORCISM"))
        assert.is_false(Rotation.setCondition(1, "category", "no_such_category"))
        assert.is_false(Rotation.setCondition(1, "kind", "no_such_field"))
        assert.is_false(Rotation.selectRow(99))
      end)
    end)

    describe("the live status column", function()
      local function statuses()
        local out = {}
        for i, status in ipairs(Rotation.rowStatuses()) do out[i] = status.state end
        return out
      end

      it("tells the four states apart", function()
        queue = queueOf(1)
        assert.same({ "firing", "blocked", "waiting", "waiting", "waiting" }, statuses())
        local rows = Rotation.rowStatuses()
        assert.is_truthy(rows[1].text:find("slot 1", 1, true))
        assert.is_truthy(rows[2].text:find("Divine Storm consumes Holy Power", 1, true))
        -- The requirement is written in the voice of it being MET, so a bare condition here would
        -- tell the player the opposite of what is happening.
        assert.is_truthy(rows[4].text:find("waiting for: ", 1, true))
      end)

      -- The reason names the condition that ACTUALLY failed, not the first one on the line. Written
      -- as `entry.when[1]` this reads perfectly on every single-condition row and lies on every
      -- other -- the same dead-index shape as the M3 hover tooltip (tasks/lessons.md).
      it("names the condition that failed, not the first one on the line", function()
        Rotation.selectRow(3)
        Rotation.addCondition("in_combat")          -- passes: the fake state is in combat
        Rotation.addCondition("resource")
        Rotation.setCondition(2, "op", "minPct")
        Rotation.setCondition(2, "value", 150)      -- cannot pass: mana is capped at 100%
        assert.is_true(Rotation.save())
        queue = queueOf(1)
        assert.equal("waiting for: mana at least 150%", Rotation.rowStatuses()[3].text)
      end)

      -- One line can legitimately appear twice in a five-deep queue, and "firing now, slot 4" for a
      -- line that is also slot 1 is the less useful of the two answers.
      it("reports the FIRST slot a line holds, not the last", function()
        queue = queueOf(1, 3, 1)
        local rows = Rotation.rowStatuses()
        assert.equal("firing", rows[1].state)
        assert.is_truthy(rows[1].text:find("slot 1", 1, true))
        assert.is_nil(rows[1].text:find("slot 3", 1, true))
      end)

      it("says a line is off when the SAVED rotation has it switched off", function()
        realUserBuilds.find(PACK, forkKey).entries[3].disabled = true
        ns.forgetCompiled(realUserBuilds.find(PACK, forkKey))
        assert.equal("off", statuses()[3])
        assert.is_truthy(Rotation.rowStatuses()[3].text:find("switched off", 1, true))
      end)

      -- Schema.compile drops a disabled entry and records the position it came from, so a status
      -- column mapping by ORDINAL would put every row below a switched-off line one out.
      it("stays aligned past a line the saved rotation has switched off", function()
        realUserBuilds.find(PACK, forkKey).entries[1].disabled = true
        ns.forgetCompiled(realUserBuilds.find(PACK, forkKey))
        -- Saved line 1 no longer compiles, so the SECOND compiled entry is saved line 3. Mapped by
        -- ordinal, this slot would have been reported against saved line 2.
        queue = queueOf(2)
        local rows = Rotation.rowStatuses()
        assert.equal("off", rows[1].state)
        assert.equal("blocked", rows[2].state)
        assert.equal("firing", rows[3].state, "the queue slot belongs to saved line 3")
        assert.is_truthy(rows[3].text:find("slot 1", 1, true))
        assert.equal("waiting", rows[4].state)
      end)

      it("says a line has not been saved yet", function()
        Rotation.appendSpell("CONSECRATION")
        local rows = Rotation.rowStatuses()
        assert.equal("unsaved", rows[6].state)
        assert.is_truthy(rows[6].text:find("not saved", 1, true))
      end)

      -- The status text names a spell through the same resolver the rest of the panel uses. Without
      -- the pack context it would print the raw symbolic key, which is not what anyone calls it.
      it("names a spell in the waiting reason the way the client does", function()
        Rotation.selectRow(3)
        Rotation.addCondition("buff")
        Rotation.setCondition(1, "key", "VENGEANCE_BUFF")
        assert.is_true(Rotation.save())
        ns.BarGlow = { spellName = function(id) return id == 7 and "Vengeance" or nil end }
        queue = queueOf(1)
        assert.equal("waiting for: Vengeance is up", Rotation.rowStatuses()[3].text)
      end)

      it("names the cooldown or the usability when every condition passes", function()
        queue = queueOf(1)
        state.cooldowns.JUDGEMENT = 4.2
        assert.is_truthy(Rotation.rowStatuses()[3].text:find("on cooldown (4.2 s)", 1, true))
        state.cooldowns.JUDGEMENT = nil
        state.usableSet = { JUDGEMENT = false }
        assert.is_truthy(Rotation.rowStatuses()[3].text:find("not usable", 1, true))
      end)

      -- With no queue on screen "a line above it is firing" would be a claim about a display that
      -- is not there.
      it("says the queue is hidden rather than inventing a reason", function()
        queue = nil
        assert.is_truthy(Rotation.rowStatuses()[3].text:find("hidden", 1, true))
      end)

      -- The row's own line shows the author's note when it has one, so the summary has nowhere else
      -- to go; on an unlabelled row it is already up there and repeating it says everything twice.
      it("repeats the conditions under a line that shows an author's note, and not otherwise", function()
        queue = queueOf(1)
        realUserBuilds.find(PACK, forkKey).entries[1].label = "opener"
        ns.forgetCompiled(realUserBuilds.find(PACK, forkKey))
        Rotation.discard()
        local args = builder().list.args
        assert.is_truthy(args.r1.args.what.name:find("opener", 1, true))
        assert.is_nil(args.r1.args.what.name:find("mana at least 40%", 1, true))
        assert.is_truthy(args.r1.args.status.name:find("mana at least 40%", 1, true))

        -- The same line without the note: the summary is on its own line now, so the status must
        -- not carry it a second time.
        realUserBuilds.find(PACK, forkKey).entries[1].label = nil
        ns.forgetCompiled(realUserBuilds.find(PACK, forkKey))
        Rotation.discard()
        args = builder().list.args
        assert.is_truthy(args.r1.args.what.name:find("mana at least 40%", 1, true))
        assert.is_nil(args.r1.args.status.name:find("mana at least 40%", 1, true))
      end)

      it("renders the marker and the reason as an ASCII line under each row", function()
        queue = queueOf(1)
        local status = builder().list.args.r1.args.status
        assert.equal("description", status.type)
        assert.equal("full", status.width)
        assert.is_truthy(status.name:find(">>", 1, true))
        -- The client's font has no U+25CF; every marker would draw as the same empty box.
        for _, look in pairs(Rotation.MARKS) do
          assert.is_nil(look.mark:find("[\128-\255]"), look.mark)
        end
        assert.is_nil(status.name:find("[\128-\255]"))
      end)

      it("answers nothing, not an error, when there is no rotation at all", function()
        ns.Display.activeBuild = function() return nil, nil, "no pack" end
        assert.same({}, Rotation.rowStatuses())
      end)
    end)

    describe("the queue mirror", function()
      it("lists the queue with its slot numbers, and the state behind it", function()
        queue = queueOf(1, 3)
        ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
        local lines = Rotation.mirrorLines()
        assert.is_truthy(lines[1]:find("1. EXORCISM", 1, true))
        assert.is_truthy(lines[1]:find("2. JUDGEMENT", 1, true))
        assert.is_truthy(lines[1]:find("|Ttex:ex:0|t", 1, true))
        assert.is_truthy(lines[2]:find("target: yes", 1, true))
        assert.is_truthy(lines[2]:find("mana 100%", 1, true))
        assert.is_truthy(lines[3]:find(">>", 1, true), "the legend explains the markers")
        assert.is_truthy(lines[4]:find("last time the queue changed", 1, true))
      end)

      it("names an item line by its slot", function()
        queue = queueOf(5)
        assert.is_truthy(Rotation.mirrorLines()[1]:find("Trinket 1", 1, true))
      end)

      -- A hidden queue is a real answer, not a missing one: without this the panel would be blank
      -- and read as a broken addon.
      it("says the queue is hidden rather than showing an empty line", function()
        queue = nil
        assert.is_truthy(Rotation.mirrorLines()[1]:find("hidden right now", 1, true))
        queue = {}
        assert.is_truthy(Rotation.mirrorLines()[1]:find("hidden right now", 1, true))
      end)

      it("survives a state that cannot answer any of it", function()
        ns.API = { GetState = function() return nil end }
        assert.is_nil(Rotation.contextLine())
        ns.API = { GetState = function() return { targetExists = function() error("nope") end } end }
        assert.equal("target: no", Rotation.contextLine())
        assert.is_true(#Rotation.mirrorLines() >= 3)
      end)

      it("renders every mirror line into the panel, above everything else", function()
        queue = queueOf(1)
        local mirror = builder().mirror
        assert.equal(1, mirror.order)
        assert.is_truthy(mirror.args.m1.name:find("EXORCISM", 1, true))
        assert.equal("medium", mirror.args.m1.fontSize)
        assert.is_truthy(mirror.args.m4)
      end)
    end)

    -- Every control the Builder draws, checked as a control rather than only as a behaviour.
    --
    -- AceConfig is a data format: a node with no `type` is skipped, a select with no `values` draws
    -- an empty dropdown, an execute with no `func` is a dead button. None of those raise, and none
    -- of them are visible to a test that only calls `args.foo.set(...)` -- which is how this repo
    -- keeps shipping controls that look right and do nothing.
    describe("the panel as AceConfig data", function()
      local WIDGETS = {
        group = function(node) assert.is_table(node.args) end,
        description = function() end,
        execute = function(node) assert.is_function(node.func) end,
        toggle = function(node)
          assert.is_function(node.get); assert.is_function(node.set)
        end,
        input = function(node)
          assert.is_function(node.get); assert.is_function(node.set)
        end,
        select = function(node)
          assert.is_table(node.values)
          assert.is_true(next(node.values) ~= nil, "an empty dropdown offers nothing")
          for id in pairs(node.values) do
            -- AceConfig round-trips a select value through the widget, so a non-string id comes
            -- back as a string and never compares equal to what the code stored.
            assert.equal("string", type(id))
          end
          assert.is_function(node.get); assert.is_function(node.set)
        end,
      }

      local function walk(args, path)
        local seen = 0
        for key, node in pairs(args) do
          local at = path .. "." .. key
          seen = seen + 1
          assert.is_table(node, at)
          local check = WIDGETS[node.type]
          assert.is_truthy(check, at .. " has type " .. tostring(node.type))
          assert.equal("number", type(node.order), at .. " has no order")
          assert.is_truthy(node.name, at .. " has no name")
          check(node)
          if node.type == "group" then walk(node.args, at) end
        end
        assert.is_true(seen > 0, path .. " is empty")
        return seen
      end

      it("draws a complete, well-formed control for every node of the Builder", function()
        queue = queueOf(1)
        Rotation.selectRow(1)
        assert.is_true(walk(builder(), "builder") > 5)
      end)

      it("is well-formed with a nested line selected, and on a template", function()
        Rotation.selectRow(4)
        walk(builder(), "builder:complex")
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        walk(builder(), "builder:template")
      end)

      it("is well-formed across the whole section", function()
        installWizard({ { build = "TEMPLATE", playstyle = "Template", fits = true } })
        Rotation.selectRow(2)
        walk(Rotation.group().args, "rotation")
      end)

      -- A tooltip is the only place several of these controls explain themselves, and an execute
      -- with no `desc` is a button whose consequence is invisible until it has happened.
      it("explains every control whose effect is not obvious from its label", function()
        Rotation.selectRow(1)
        local args = builder()
        assert.is_truthy(args.list.args.r1.args.edit.desc:find("conditions", 1, true))
        assert.is_truthy(args.list.args.r1.args.remove.desc:find("Discard", 1, true))
        assert.is_truthy(args.spells.args.s1.desc:find("bottom of the draft", 1, true))
        assert.is_truthy(args.items.args.i1.desc:find("bottom of the draft", 1, true))
        assert.is_truthy(args.editing.args.save.desc:find("repaints", 1, true))
        assert.is_truthy(args.editing.args.discard.desc:find("saved rotation", 1, true))
        assert.is_truthy(args.pane.args.add.desc:find("change the exact field", 1, true))
        assert.is_truthy(args.pane.args.conditions.args.c1.args.negated.desc:find("NOT", 1, true))
      end)

      it("names each control, and sizes the row so it does not wrap", function()
        Rotation.selectRow(1)
        local row = builder().list.args.r1.args
        assert.equal("Edit", row.edit.name)
        assert.equal("On", row.on.name)
        assert.equal("Up", row.up.name)
        assert.equal("Down", row.down.name)
        assert.equal("Remove", row.remove.name)
        local width = 0
        for _, control in pairs(row) do
          if type(control.width) == "number" then width = width + control.width end
        end
        assert.is_true(width < 3.0, "the row sums to " .. width .. " and would wrap")

        local pane = builder().pane.args.conditions.args.c1.args
        assert.equal("Category", pane.category.name)
        assert.equal("Field", pane.field.name)
        assert.equal("not", pane.negated.name)
        assert.equal("Remove", pane.remove.name)
        assert.equal("Test", pane.op.name)
        assert.equal("Value", pane.key.name)
        assert.equal("seconds", builder().pane.args.conditions.args.c1.args.amount.name ~= nil
                                 and "seconds" or "")
      end)

      it("labels a spell key with its readable name and a plain value with itself", function()
        ns.BarGlow = { spellName = function(id) return id == 7 and "Vengeance" or nil end }
        Rotation.selectRow(3)
        Rotation.addCondition("buff")
        local values = builder().pane.args.conditions.args.c1.args.key.values
        assert.equal("Vengeance", values.VENGEANCE_BUFF)
        assert.equal("EXORCISM", values.EXORCISM, "no client name: the key is its own label")
        Rotation.setCondition(1, "kind", "mode")
        local modes = builder().pane.args.conditions.args.c1.args.key.values
        assert.equal("AoE", modes.AoE, "a mode IS its own label")
      end)

      it("names each inventory slot in the slot dropdown", function()
        Rotation.selectRow(5)
        local slots = builder().pane.args.conditions.args.c1.args.slot.values
        assert.equal("Trinket 1", slots["13"])
        assert.equal("Head", slots["1"])
      end)

      it("offers only the two ways a line can combine its conditions", function()
        Rotation.selectRow(1)
        assert.same({ all = "every condition passes", any = "any condition passes" },
                    builder().pane.args.match.values)
        -- The add dropdown is a menu of CATEGORIES whose values are the first field of each, so
        -- picking one always produces a legal condition.
        local adds = builder().pane.args.add.values
        assert.equal("Encounter", adds.enemies)
        assert.equal("Combat state", adds.in_combat)
        assert.is_nil(builder().pane.args.add.get())
      end)

      it("marks which line the pane is showing", function()
        Rotation.selectRow(2)
        local args = builder().list.args
        assert.is_truthy(args.r2.args.what.name:find("|cffC08CF0>|r", 1, true))
        assert.is_nil(args.r1.args.what.name:find("|cffC08CF0>|r", 1, true))
      end)

      it("saves and discards from the rendered buttons", function()
        Rotation.moveRow(1, 1)
        builder().editing.args.save.func()
        assert.equal("DIVINE_STORM", realUserBuilds.find(PACK, forkKey).entries[1].spell)
        Rotation.moveRow(1, 1)
        builder().editing.args.discard.func()
        assert.is_false(Rotation.draft().dirty)
        assert.equal("DIVINE_STORM", Rotation.listRows()[1].spell)
      end)

      it("appends the right slot from the item palette", function()
        builder().items.args.i1.func()
        assert.equal(13, Rotation.draft().entries[6].item)
        builder().items.args.i2.func()
        assert.equal(14, Rotation.draft().entries[7].item)
      end)
    end)

    -- The states the panel reaches when the display, the state or the rotation is not there. Each
    -- of these is a NORMAL runtime moment, not an error: no pack for this class, a hidden queue,
    -- an adapter that cannot answer.
    describe("degrading rather than erroring", function()
      it("statuses nothing when the Display module cannot answer", function()
        ns.Display.gateRows = nil
        queue = nil
        local rows = Rotation.rowStatuses()
        assert.equal(5, #rows)
        for _, status in ipairs(rows) do assert.equal("waiting", status.state) end
        assert.is_truthy(rows[1].text:find("hidden", 1, true))
        ns.Display = nil
        assert.is_true(#Rotation.rowStatuses() >= 0)
      end)

      it("statuses a line whose compiled entry cannot be read", function()
        ns.API = { GetState = function() return nil end }
        queue = nil
        assert.is_truthy(Rotation.rowStatuses()[3].text:find("hidden", 1, true))
        queue = queueOf(1)
        assert.is_truthy(Rotation.rowStatuses()[3].text:find("waiting its turn", 1, true))
      end)

      it("leaves out a context reading the state cannot give", function()
        ns.API = { GetState = function()
          return { targetExists = function() return false end }
        end }
        local line = Rotation.contextLine()
        assert.equal("target: no", line)
        assert.is_nil(line:find("HP", 1, true), "no target, so no target health")
        assert.is_nil(line:find("enemies", 1, true))
        assert.is_nil(line:find("mana", 1, true))
      end)

      it("reads the mana pair without truncating it to one value", function()
        state.powers = { MANA = { 250, 1000 } }
        assert.is_truthy(Rotation.contextLine():find("mana 25%", 1, true))
        state.powers = { MANA = { 250, 0 } }
        assert.is_nil(Rotation.contextLine():find("mana", 1, true), "a zero cap is not a percentage")
      end)

      -- A capability the adapter does not implement at all -- `enemies` needs nameplates, which
      -- this client does not have. Absent is not the same as an error, and neither is an answer.
      it("leaves out a reading the state has no accessor for", function()
        ns.API = { GetState = function()
          return { targetExists = function() return true end,
                   targetHPPct = function() return 40 end }
        end }
        local line = Rotation.contextLine()
        assert.is_truthy(line:find("target HP 40%", 1, true))
        assert.is_nil(line:find("enemies", 1, true))
        assert.is_nil(line:find("mana", 1, true))
      end)

      it("reports the target's health and the enemy count when it has them", function()
        state._targetHp = 18
        state._enemies = 4
        local line = Rotation.contextLine()
        assert.is_truthy(line:find("target HP 18%", 1, true))
        assert.is_truthy(line:find("enemies 4", 1, true))
      end)

      it("refuses a list edit when the active rotation is a template", function()
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        assert.is_false(Rotation.moveRow(1, 1))
        assert.is_false(Rotation.setRowDisabled(1, true))
        assert.is_false(Rotation.removeRow(1))
        assert.is_false(Rotation.selectRow(1))
        assert.is_false(Rotation.appendSpell("EXORCISM"))
        assert.is_false(Rotation.appendItem(13))
        assert.same({}, Rotation.problems())
      end)

      -- The draft belongs to ONE rotation. Leaving it behind when a template is activated would
      -- offer Save on lines that are no longer the ones on screen.
      it("throws the draft away when a template is activated", function()
        Rotation.moveRow(1, 1)
        assert.is_true(Rotation.draft().dirty)
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        assert.is_nil(Rotation.draft())
        ns.Display.activeBuild = function() return compiledFork(), forkKey, "pinned" end
        assert.is_false(Rotation.draft().dirty, "and it does not come back")
      end)

      -- A template's rows carry their own position as `src`, so the status column works there too:
      -- a template is the thing a new player is looking at, and "why is this line orange" is the
      -- question the Customize button answers.
      it("statuses a template's rows against the template itself", function()
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        ns.Display.gateRows = function()
          local compiled = ns.Schema.compile(PACK.builds.TEMPLATE, packTables())
          return compiled, ns.Gates.evaluate(compiled, state, packTables()), "TEMPLATE"
        end
        local rows = Rotation.listRows()
        for i, row in ipairs(rows) do assert.equal(i, row.src) end
        assert.equal("blocked", Rotation.rowStatuses()[2].state)
      end)
    end)

    -- F36 (ADR-0015 §2: "F36 diagnostics render at the foot of the Builder"). Warnings, never
    -- errors: none of these stops a Save. They answer the two questions an editor cannot answer by
    -- looking -- can this line ever fire, and does it still name something that exists.
    describe("the checks at the foot", function()
      it("says nothing, and draws nothing, about a healthy rotation", function()
        assert.same({}, Rotation.diagnosticLines())
        assert.is_nil(builder().checks)
      end)

      -- The commonest editing mistake: add a line from the palette (which arrives with no
      -- conditions) for a spell that already has a gated line above it.
      it("flags a line an earlier unconditional line for the same spell kills", function()
        Rotation.appendSpell("EXORCISM")                   -- unconditional, at the bottom
        for i = 6, 2, -1 do Rotation.moveRow(i, -1) end    -- walk it up to line 1
        local lines = Rotation.diagnosticLines()
        assert.equal(1, #lines)
        assert.is_truthy(lines[1]:find("Line 2", 1, true))
        assert.is_truthy(lines[1]:find("EXORCISM", 1, true))
        assert.is_truthy(lines[1]:find("line 1 does the same thing and nothing gates it", 1, true))
        assert.is_truthy(builder().checks.args.d1.name:find("Line 2", 1, true))
        assert.equal(9, builder().checks.order, "at the FOOT of the Builder")
      end)

      it("uses the other wording when the line that kills it has gates of its own", function()
        Rotation.appendSpell("EXORCISM")
        Rotation.selectRow(6)
        Rotation.addCondition("in_combat")
        -- Line 1 is `mana >= 40`; give the new line that gate as well, plus one more.
        Rotation.setCondition(1, "kind", "resource")
        Rotation.setCondition(1, "op", "minPct")
        Rotation.setCondition(1, "value", 40)
        Rotation.setCondition(1, "key", "MANA")
        Rotation.addCondition("in_combat")
        for i = 6, 3, -1 do Rotation.moveRow(i, -1) end
        -- The new line now sits at 2, under the original Exorcism at 1, and carries its gate plus one.
        local lines = Rotation.diagnosticLines()
        assert.equal(1, #lines)
        assert.is_truthy(lines[1]:find("whenever this line could", 1, true))
      end)

      -- It reads the DRAFT, so the warning arrives while the edit is being made rather than after
      -- Save -- which is the whole point of a diagnostic in an editor.
      it("appears before Save and goes away on Discard", function()
        Rotation.appendSpell("EXORCISM")
        for i = 6, 2, -1 do Rotation.moveRow(i, -1) end
        assert.equal(1, #Rotation.diagnosticLines())
        assert.equal(5, #realUserBuilds.find(PACK, forkKey).entries, "nothing was written")
        Rotation.discard()
        assert.same({}, Rotation.diagnosticLines())
      end)

      -- What a fork looks like after the class data it was taken from moves on: the fork lives in
      -- SavedVariables and outlives any release. Schema refuses the whole build for it, correctly,
      -- and "failed to compile" does not say WHICH line to fix.
      it("names a line whose key the class data no longer has", function()
        Rotation.draft().entries[3].spell = "SPELL_THAT_WENT_AWAY"
        local lines = Rotation.diagnosticLines()
        assert.equal(1, #lines)
        assert.is_truthy(lines[1]:find("Line 3", 1, true))
        assert.is_truthy(lines[1]:find("SPELL_THAT_WENT_AWAY", 1, true))
        assert.is_truthy(lines[1]:find("no longer has", 1, true))
      end)

      it("diagnoses a template too, which has no draft at all", function()
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        assert.is_nil(Rotation.draft())
        assert.same({}, Rotation.diagnosticLines())
        PACK.builds.TEMPLATE.entries[6] = { spell = "EXORCISM" }
        PACK.builds.TEMPLATE.entries[7] = { spell = "EXORCISM", when = { { "in_combat" } } }
        assert.equal(1, #Rotation.diagnosticLines())
      end)

      it("says nothing when there is no rotation at all", function()
        ns.Display.activeBuild = function() return nil, nil, "no pack" end
        assert.same({}, Rotation.diagnosticLines())
      end)

      -- SavedVariables outlive every release and can be hand-edited, so a stored line that names
      -- neither a spell nor a slot is reachable. It has to render as something rather than take
      -- the panel down.
      it("names a line that binds to nothing at all, rather than erroring", function()
        realUserBuilds.find(PACK, forkKey).entries[3] = { label = "broken" }
        ns.forgetCompiled(realUserBuilds.find(PACK, forkKey))
        assert.equal("?", Rotation.listRows()[3].label)
      end)
    end)

    -- F35 / ADR-0010: a template updated by a release is offered as a DIFF, never rebased -- the
    -- user's edits win, so the addon's job is to let them read what is different and decide.
    describe("the parent diff", function()
      local function forkOf(entries)
        local key = realUserBuilds.fork(PACK, "TEMPLATE", { name = "Diffed" })
        local record = ns.db.global.userBuilds[key]
        record.derivedAt = "2026-07-01"   -- older than the catalog's 2026-08-01
        if entries then record.build.entries = entries end
        forkKey = key
        return key
      end

      it("says nothing while the rotations are the same", function()
        forkOf(nil)
        assert.same({}, Rotation.parentDiffLines())
      end)

      it("names the rows that differ, in both directions", function()
        forkOf{
          { spell = "EXORCISM", when = { { "resource", "MANA", minPct = 90 } } },  -- changed
          { spell = "JUDGEMENT", when = { { "bonus", "HOLY_POWER_CONSUME" } } },   -- only mine
          { spell = "JUDGEMENT" },
          { spell = "HOLY_WRATH", when = { { "bonus", "HOLY_WRATH_INSTANT" },
              { "any", { "target_type", "Undead" }, { "rune", "RUNE_PURIFYING_POWER" } } } },
          { item = 13, when = { { "item_ready", 13 } } },
        }
        local lines = table.concat(Rotation.parentDiffLines(), " | ")
        assert.is_truthy(lines:find("The template has lines yours does not: DIVINE_STORM", 1, true))
        assert.is_truthy(lines:find("Yours has lines the template does not: JUDGEMENT", 1, true))
        assert.is_truthy(lines:find("Different conditions on: EXORCISM", 1, true))
      end)

      -- Position IS the rotation (F1), so a row that only moved is a real difference and can be
      -- the only thing a release changed.
      it("names a row that only moved", function()
        local entries = {}
        for i, entry in ipairs(PACK.builds.TEMPLATE.entries) do entries[i] = entry end
        entries[1], entries[2] = entries[2], entries[1]
        forkOf(entries)
        local lines = table.concat(Rotation.parentDiffLines(), " | ")
        assert.is_truthy(lines:find("In a different order:", 1, true))
        assert.is_nil(lines:find("Different conditions", 1, true))
        assert.is_nil(lines:find("does not", 1, true))
      end)

      it("names an item line by its slot", function()
        forkOf{ { spell = "EXORCISM", when = { { "resource", "MANA", minPct = 40 } } } }
        assert.is_truthy(table.concat(Rotation.parentDiffLines(), " | ")
          :find("Trinket 1", 1, true))
      end)

      it("carries the author's label, so two lines for one spell read apart", function()
        PACK.builds.TEMPLATE.entries[2].label = "3 HP"
        forkOf{ { spell = "EXORCISM", when = { { "resource", "MANA", minPct = 40 } } } }
        assert.is_truthy(table.concat(Rotation.parentDiffLines(), " | ")
          :find("DIVINE_STORM (3 HP)", 1, true))
      end)

      -- It hangs off the stale-parent banner, which is the moment ADR-0010 asks for a diff.
      it("appears under the banner on the Rotations tab, and only once the parent has moved on",
        function()
          forkOf(nil)
          realUserBuilds.find(PACK, forkKey).entries[1].when = nil
          local lines = table.concat(Rotation.statusLines(), " | ")
          assert.is_truthy(lines:find("has been updated since you forked it", 1, true))
          assert.is_truthy(lines:find("Different conditions on: EXORCISM", 1, true))

          -- Same fork, taken from the CURRENT template: no banner, and so no diff either.
          ns.db.global.userBuilds[forkKey].derivedAt = "2026-08-01"
          local current = table.concat(Rotation.statusLines(), " | ")
          assert.is_nil(current:find("has been updated", 1, true))
          assert.is_nil(current:find("Different conditions", 1, true))
        end)

      it("says nothing for a template, or a fork of nothing, or a parent that is gone", function()
        local asFork = ns.Display.activeBuild
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        assert.same({}, Rotation.parentDiffLines())

        -- Back to the fork, or the two cases below would be answered by the template check above
        -- and would prove nothing about the ones they name.
        ns.Display.activeBuild = asFork
        forkOf{ { spell = "EXORCISM" } }   -- deliberately different from the template
        assert.is_true(#Rotation.parentDiffLines() > 0, "the fixture must have something to report")

        ns.db.global.userBuilds[forkKey].derivedFrom = nil
        assert.same({}, Rotation.parentDiffLines())
        ns.db.global.userBuilds[forkKey].derivedFrom = "A_TEMPLATE_THAT_IS_GONE"
        assert.same({}, Rotation.parentDiffLines())
      end)
    end)

    describe("the live refresh", function()
      local notified, clock

      before_each(function()
        notified, clock = 0, 100
        ns.now = function() return clock end
        Rotation.notifyChange = function() notified = notified + 1; return true end
        Rotation.isIdle = function() return true end
      end)

      it("refreshes the panel when the queue changes", function()
        assert.is_true(Rotation.onQueueChanged())
        assert.equal(1, notified)
      end)

      -- NotifyChange rebuilds the ENTIRE options table. In combat the queue changes several times
      -- a second, and rebuilding at that rate is both expensive and unreadable.
      it("refreshes at most once every two seconds", function()
        Rotation.onQueueChanged()
        clock = clock + 1.9
        assert.is_false(Rotation.onQueueChanged())
        clock = clock + 0.2
        assert.is_true(Rotation.onQueueChanged())
        assert.equal(2, notified)
      end)

      -- The panel already rebuilds on every `set`, and an AceGUI EditBox commits only on Enter, so
      -- refreshing on top of someone who is still working discards what they typed.
      it("leaves someone who is still editing alone for three seconds", function()
        Rotation.draft()
        clock = clock + 10
        Rotation.moveRow(1, 1)
        assert.is_false(Rotation.onQueueChanged())
        clock = clock + 2.9
        assert.is_false(Rotation.onQueueChanged())
        clock = clock + 0.2
        assert.is_true(Rotation.onQueueChanged())
      end)

      it("does nothing at all when the Builder is not the thing on screen", function()
        Rotation.isIdle = function() return false end
        assert.is_false(Rotation.onQueueChanged())
        assert.equal(0, notified)
      end)

      it("asks Options whether the Builder is idle, and says no when it cannot", function()
        Rotation = helper.load("Elmira/Options/Rotation.lua")
        ns.Options = nil
        assert.is_false(Rotation.isIdle())
        ns.Options = { builderIdle = function() return true end }
        assert.is_true(Rotation.isIdle())
        ns.Options = { builderIdle = function() return nil end }
        assert.is_false(Rotation.isIdle(), "only an explicit true counts")
      end)

      it("does not notify when AceConfigRegistry is not there to be notified", function()
        Rotation = helper.load("Elmira/Options/Rotation.lua")
        local saved = _G.LibStub
        _G.LibStub = nil
        assert.is_false(Rotation.notifyChange())
        local asked
        _G.LibStub = function(name, silent) asked = { name, silent }; return nil end
        assert.is_false(Rotation.notifyChange())
        assert.same({ "AceConfigRegistry-3.0", true }, asked)
        _G.LibStub = function() return { NotifyChange = function(_, app)
          assert.equal("Elmira", app); notified = notified + 1
        end } end
        assert.is_true(Rotation.notifyChange())
        assert.equal(1, notified)
        _G.LibStub = saved
      end)
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
