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

  -- The fakes are laid OVER the real Core/UserBuilds (freshly loaded per test), never handed over
  -- as a table of their own: a caller names `ns.UserBuilds.list`, but the module's own functions
  -- call each other, and only one table can be both. `Rotation.displayName` is the case that made
  -- this necessary -- it delegates to `UserBuilds.displayName`, which resolves a fork through
  -- `UserBuilds.find`, so a spec faking `find` on a separate table would have been answering a
  -- question nobody asked while the real lookup read an empty store.
  --
  -- Everything not named here stays REAL, which is the point: `catalogUpdated` is what stamps
  -- `derivedAt`, so the stale-parent banner has to ask the same function, and `copy` is the deep
  -- copy the Builder's draft needs (a one-level fake would share every `when` list with the stored
  -- build, and the rotation would change before Save was pressed).
  local function installUserBuilds(t)
    for name, fn in pairs(t) do realUserBuilds[name] = fn end
    ns.UserBuilds = realUserBuilds
    return realUserBuilds
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
  -- The tree reads `Wizard.rows` (every catalog entry, each flagged `available`), not the filtered
  -- `Wizard.choices`. Rows default to available here so a test only says so when unavailability is
  -- what it is about.
  local function installWizard(rows)
    for _, row in ipairs(rows) do
      if row.available == nil then row.available = true end
    end
    ns.Wizard = { rows = function() return rows end }
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
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/Schema.lua")
    helper.load("Elmira/Core/Gates.lua")
    helper.load("Elmira/Core/Palette.lua")
    helper.load("Elmira/Core/Conditions.lua")
    helper.load("Elmira/Core/Spells.lua")
    helper.load("Elmira/Core/Diagnostics.lua")
    realUserBuilds = helper.load("Elmira/Core/UserBuilds.lua")
    ns.UserBuilds = nil -- each test opts in through installUserBuilds
    -- Present BEFORE Rotation.lua loads: D35's popups register themselves at file scope, the same
    -- way any addon's StaticPopupDialogs entry does.
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function(which, arg1, arg2, data)
      _G.__lastStaticPopup = { which = which, arg1 = arg1, arg2 = arg2, data = data }
      return { which = which }
    end
    Rotation = helper.load("Elmira/Options/Rotation.lua")
  end)

  after_each(function()
    _G.StaticPopupDialogs, _G.StaticPopup_Show, _G.__lastStaticPopup = nil, nil, nil
  end)

  describe("group()", function()
    it("is a tree, named Rotations, with Builder and Share as its last two children", function()
      installPack()
      local g = Rotation.group()
      assert.equal("group", g.type)
      assert.equal("tree", g.childGroups)
      assert.equal("Rotations", g.name)
      assert.equal(0, g.order)
      assert.equal("group", g.args.builder.type)
      assert.equal("group", g.args.share.type)
      -- "last two" is an ordering claim, not a naming one: every template/fork page sorts below the
      -- intro rows and above these, whatever the class ships.
      for key, row in pairs(g.args) do
        if key ~= "builder" and key ~= "share" and type(row) == "table" and row.type == "group"
           and not row.inline then
          assert.is_true(row.order < g.args.builder.order, key .. " sorts after Builder")
        end
      end
      assert.is_true(g.args.builder.order < g.args.share.order)
    end)

    it("gives the Builder a search box and a list of spells and items", function()
      installPack()
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
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
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

  -- D30. The tree's own shape: templates in catalog order, their forks nested inside them, a
  -- no-template fork sitting directly under Rotations, and the depth cap that puts a copy of a copy
  -- under the ORIGINAL template rather than under the fork it happened to be copied from.
  describe("the tree (D30)", function()
    before_each(function() installPack() end)

    it("gives every catalog template its own top-level page, in catalog order", function()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local args = Rotation.group().args
      assert.equal("group", args.PALADIN_EXODIN.type)
      assert.is_falsy(args.PALADIN_EXODIN.inline)
      assert.equal("group", args.PALADIN_SHOCKADIN.type)
      assert.is_true(args.PALADIN_EXODIN.order < args.PALADIN_SHOCKADIN.order)
    end)

    it("nests a fork inside the template it was forked from", function()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function(pk, key)
          if key == "USER_MINE" then
            return { entries = {} }, "fork", { name = "My Exodin", derivedFrom = "PALADIN_EXODIN" }
          end
          if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
        end,
      }
      local template = Rotation.group().args.PALADIN_EXODIN
      assert.is_table(template.args.USER_MINE, "the fork is not nested under its template")
      assert.equal("My Exodin", template.args.USER_MINE.name)
    end)

    it("puts a fork with no template directly under Rotations", function()
      installWizard{}
      installUserBuilds{
        list = function() return { "USER_SCRATCH" } end,
        find = function(_, key)
          if key == "USER_SCRATCH" then return { entries = {} }, "fork", { name = "Scratch" } end
        end,
      }
      local root = Rotation.group().args
      assert.is_table(root.USER_SCRATCH)
      assert.equal("Scratch", root.USER_SCRATCH.name)
    end)

    -- Depth cap: a copy of a copy nests under the ORIGINAL template, not under the fork it was
    -- copied from -- otherwise the tree could grow one level deeper every time someone forked a fork.
    it("nests a copy of a copy under the original template, not under the fork it copied", function()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      installUserBuilds{
        list = function() return { "USER_A", "USER_B" } end,
        find = function(pk, key)
          if key == "USER_A" then
            return { entries = {} }, "fork", { name = "Copy A", derivedFrom = "PALADIN_EXODIN" }
          elseif key == "USER_B" then
            return { entries = {} }, "fork", { name = "Copy of Copy A", derivedFrom = "USER_A" }
          end
          if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
        end,
      }
      local template = Rotation.group().args.PALADIN_EXODIN
      assert.is_table(template.args.USER_A)
      assert.is_table(template.args.USER_B, "the copy of a copy is missing from the template's page")
      assert.is_nil(template.args.USER_A.args and template.args.USER_A.args.USER_B,
        "the copy of a copy nested a level too deep, under the fork instead of the template")
    end)

    it("Rotation.rootParent resolves a fork-of-a-fork chain to the original template", function()
      installUserBuilds{
        find = function(pk, key)
          if key == "USER_B" then return {}, "fork", { derivedFrom = "USER_A" } end
          if key == "USER_A" then return {}, "fork", { derivedFrom = "PALADIN_EXODIN" } end
          if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
        end,
      }
      ns.Display.currentPack = function()
        return { class = "PALADIN", builds = { PALADIN_EXODIN = {} } }
      end
      assert.equal("PALADIN_EXODIN", Rotation.rootParent("USER_B"))
    end)

    it("Rotation.rootParent answers nil for a fork derived from nothing", function()
      installUserBuilds{ find = function() return {}, "fork", {} end }
      assert.is_nil(Rotation.rootParent("USER_SCRATCH"))
    end)

    -- A key that resolves to NEITHER a shipped build nor a fork record: `fork` itself is nil here,
    -- not merely one with no `derivedFrom` -- indexing it without the guard would error instead of
    -- answering "no parent".
    it("Rotation.rootParent answers nil for a key that is not a build or a fork at all", function()
      installUserBuilds{ find = function() return nil end }
      assert.is_nil(Rotation.rootParent("GARBAGE"))
    end)

    -- A hand-edited SavedVariables file could in principle name itself as its own ancestor; the
    -- bound in the loop is what stops that from hanging the whole options panel.
    it("Rotation.rootParent does not hang on a cycle", function()
      installUserBuilds{ find = function(_, key)
        if key == "USER_A" then return {}, "fork", { derivedFrom = "USER_B" } end
        return {}, "fork", { derivedFrom = "USER_A" }
      end }
      assert.is_nil(Rotation.rootParent("USER_A"))
    end)

    it("Rotation.rootParent answers nil for a nil key, rather than erroring", function()
      assert.is_nil(Rotation.rootParent(nil))
    end)

    -- Never a real chain (nothing the addon writes grows one), but a hand-edited SavedVariables
    -- file could -- the bound is what stops that from hanging the whole options panel.
    it("Rotation.rootParent gives up after enough hops, on a chain that never repeats or resolves",
      function()
        installUserBuilds{ find = function(_, key) return {}, "fork", { derivedFrom = key .. "X" } end }
        assert.is_nil(Rotation.rootParent("USER_START"))
      end)

    it("says so, without erroring, when the class ships no templates at all", function()
      installWizard{}
      local root = Rotation.group().args
      assert.is_truthy(root.noPack.name:find("No playstyles for", 1, true))
      assert.equal("execute", root.newRotation.type)
    end)

    -- One AceConfig node cannot hold two children at the same `order`: whichever sorts second is
    -- silently invisible in the real dialog. Every branch this pass added -- both templates active
    -- and not, every Detect.check state, notes/no-notes, a fork nested and a fork that is not, the
    -- stale-parent banner -- is exercised here at once so a miscounted `a = a + 1` anywhere in the
    -- tree shows up as a collision rather than as a page nobody happened to open in a test.
    it("gives every sibling in the tree its own order, across every branch this pass added",
      function()
        installPack()
        ns.Detect = { hasFailures = function(checks)
          for _, c in ipairs(checks or {}) do if c.ok == false then return true end end
          return false
        end }
        installWizard{
          { build = "PALADIN_EXODIN", playstyle = "Exodin", recommended = true, phase = "SoD P8",
            updated = "2026-08-01", summary = "Fast 2H.", notes = "Never holds Exorcism.",
            source = "https://www.wowhead.com/classic/guide/paladin", fits = false,
            checks = { { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" },
                       { key = "RUNE_X", ok = true, text = "Rune X engraved" },
                       { key = "RUNE_Y", ok = nil, text = "Rune Y: could not read your runes" } },
            runesToEngrave = { "Art of War (feet)" } },
          { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", experimental = true, fits = true,
            checks = {} },
        }
        -- SHOCKADIN is the one running: exercises the active branch of the card, the header and
        -- the fork nested under it (no Use button, badged name) in the same pass as EXODIN's
        -- inactive one above.
        ns.Display.activeBuild = function() return {}, "USER_ACTIVE", nil end
        installUserBuilds{
          list = function() return { "USER_ACTIVE", "USER_MINE", "USER_SCRATCH" } end,
          find = function(pk, key)
            if key == "USER_ACTIVE" then
              return { entries = {} }, "fork", { name = "My Shockadin", derivedFrom = "PALADIN_SHOCKADIN" }
            elseif key == "USER_MINE" then
              return { entries = {} }, "fork", { name = "My Exodin", derivedFrom = "PALADIN_EXODIN" }
            elseif key == "USER_SCRATCH" then
              return { entries = {} }, "fork", { name = "Scratch" }
            end
            if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
          end,
        }

        local WIDGETS = { execute = true, description = true, group = true, input = true,
                          toggle = true, select = true, header = true, color = true, range = true }
        local function walk(args, path)
          local seen, orders = 0, {}
          for key, node in pairs(args) do
            local at = path .. "." .. tostring(key)
            assert.is_table(node, at .. " is not a table")
            assert.is_truthy(WIDGETS[node.type], at .. " has an unknown type " .. tostring(node.type))
            assert.is_number(node.order, at .. " has no order")
            assert.is_nil(orders[node.order], at .. " shares an order with " .. tostring(orders[node.order]))
            orders[node.order] = at
            seen = seen + 1
            if node.type == "group" then walk(node.args, at) end
          end
          assert.is_true(seen > 0, path .. " is empty")
        end

        walk(Rotation.group().args, "rotation")
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
      helper.load("Elmira/Core/Spells.lua")
      ns.Display.currentPack = function()
        return { class = "PALADIN", catalog = { PALADIN = CATALOG }, spells = PACK_SPELLS }
      end
      ns.Detect = { readableName = function(key) return key end }
      ns.API = { GetState = function()
        return { known = function(_, key) return known and known(key) end }
      end }
      -- `char.spells` is the registry `Rotation.syncSpells()` (D55) seeds from the pack every time
      -- the palette is read -- without it every "Builder palette" test would see an empty list, not
      -- because the pack has nothing castable but because there is nowhere to register it.
      ns.db = { profile = { paletteAllSlots = false }, char = { spells = {} } }
      Rotation.setSearch("")
    end

    it("lists the pack's abilities and not its rune records", function()
      installPalette(function() return true end)
      local args = Rotation.group().args.builder.args.spells.args
      local names = {}
      for key, row in pairs(args) do
        if key ~= "add" then names[#names + 1] = row.name end
      end
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

    -- D55: registers every castable pack spell into the registry, `source = "pack"` -- observed on
    -- the STORE itself, not merely on what the palette shows.
    describe("syncSpells() (D55)", function()
      it("writes every castable pack spell into the registry as source=pack", function()
        installPalette(function() return true end)
        Rotation.syncSpells()
        assert.same({ key = "EXORCISM", id = 415073, name = "EXORCISM", source = "pack" },
                    ns.db.char.spells.EXORCISM)
        assert.equal("pack", ns.db.char.spells.DIVINE_STORM.source)
        assert.is_nil(ns.db.char.spells.RUNE_DIVINE_STORM, "a rune record is not castable")
      end)

      it("never overwrites a manually added entry that shares a pack key", function()
        installPalette(function() return true end)
        ns.db.char.spells.EXORCISM = { key = "EXORCISM", id = 1, name = "Mine", source = "id" }
        Rotation.syncSpells()
        assert.equal("id", ns.db.char.spells.EXORCISM.source)
      end)

      it("does nothing without a store or without a pack, rather than erroring", function()
        installPalette(function() return true end)
        ns.db = nil
        Rotation.syncSpells()
        ns.db = { char = { spells = {} } }
        ns.Display.currentPack = function() return nil end
        Rotation.syncSpells()
        assert.same({}, ns.db.char.spells)
      end)

      it("does nothing without ns.Spells or ns.Palette loaded, rather than erroring", function()
        installPalette(function() return true end)
        ns.Palette = nil
        Rotation.syncSpells()
        assert.same({}, ns.db.char.spells)
        helper.load("Elmira/Core/Palette.lua")
        ns.Spells = nil
        Rotation.syncSpells()
        assert.same({}, ns.db.char.spells)
      end)
    end)

    -- D58: the Builder's "Add a spell" control reads the registry and offers a manually added,
    -- non-pack entry too, undimmed.
    describe("paletteSpells() reads the registry (D58)", function()
      it("offers a manually added entry that has no pack record, with known left nil", function()
        installPalette(function() return true end)
        ns.db.char.spells.SLICE_AND_DICE = { key = "SLICE_AND_DICE", id = 900, name = "Slice and Dice",
                                              source = "spellbook" }
        local rows = Rotation.paletteSpells()
        local found
        for _, row in ipairs(rows) do if row.key == "SLICE_AND_DICE" then found = row end end
        assert.is_not_nil(found, "a registry-only entry must still be offered")
        assert.equal("Slice and Dice", found.label)
        assert.is_nil(found.known)
      end)
    end)

    -- D58's last row: navigation to the Spells page, present whether or not anything matches.
    describe("the palette's \"Add from spellbook...\" row (D58)", function()
      it("is the last row, and always present even when nothing matches", function()
        installPalette(function() return true end)
        Rotation.setSearch("zzzz")
        local args = Rotation.group().args.builder.args.spells.args
        assert.equal("execute", args.add.type)
        assert.is_truthy(args.add.desc:find("Spells page", 1, true))
      end)

      it("navigates the open dialog to the Spells root page, not into the draft", function()
        installPalette(function() return true end)
        local selected
        ns.Options = { dialog = { SelectGroup = function(_, ...) selected = { ... } end } }
        local appended = false
        local realAppend = Rotation.appendSpell
        Rotation.appendSpell = function(...) appended = true; return realAppend(...) end
        local args = Rotation.group().args.builder.args.spells.args
        args.add.func()
        assert.same({ "Elmira", "spells" }, selected)
        assert.is_false(appended, "the navigation row must not append anything")
        Rotation.appendSpell = realAppend
      end)
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
      ns.db = { global = { userBuilds = {} }, profile = { paletteAllSlots = false },
                char = { spells = {} } }
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

      -- D65 STOPGAP (review finding on R2): a spell the Spells registry added by id/name/
      -- spellbook (D54) can be appended here with no matching pack record, and before this fix
      -- `problems()` said nothing about it -- Save looked enabled, and only the click itself
      -- refused, after the fact, with this exact message. Mirrors that Schema.validate check so
      -- Save is greyed out with the reason already on screen.
      it("flags a line whose spell has no pack record, before Save is ever clicked (D65)", function()
        Rotation.appendSpell("NOT_A_PACK_SPELL")
        local problems = Rotation.problems()
        assert.is_true(#problems > 0)
        local text = table.concat(problems, " ")
        assert.is_truthy(text:find("NOT_A_PACK_SPELL", 1, true))
        assert.is_truthy(text:find("is not in the spells data pack", 1, true))
        local args = builder().editing.args
        assert.is_true(args.save.disabled, "Save must be disabled BEFORE the click, not only after it fails")
      end)

      -- D68 (re-review residual): the `ctx.spells and` clause in D65's own check is
      -- load-bearing -- without it, a pack whose `spells` table is nil indexes nil the moment any
      -- entry names a spell, which in AceConfig means the whole Builder page fails to render, not
      -- just this one line. `make mutants` cannot ever catch this: it deletes whole lines, and
      -- deleting the WHOLE `if` line here removes the D65 check entirely, which the D65 test above
      -- already covers as a different failure -- so the clause reads as "covered" while being
      -- exercised by nothing. Pinned directly rather than by restructuring the condition.
      it("does not error when the pack's spells table is nil (D68)", function()
        -- `Rotation.problems()` reads the DRAFT upvalue directly rather than calling
        -- `Rotation.draft()` itself, so the draft must already exist before this runs -- exactly
        -- as it does in the real Builder, which always opens through `Rotation.draft()` first.
        assert.is_not_nil(Rotation.draft(), "the fork under test must produce a draft")
        PACK.spells = nil
        local problems
        assert.has_no.errors(function() problems = Rotation.problems() end)
        assert.is_table(problems)
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

    -- D83: nothing before this test walked the WHOLE path a player actually takes. D79 and D80 each
    -- looked right in isolation -- `wordCtx`/`lineRows` widened, `problems()`/`Rotation.save()`
    -- passing their own specs -- while the fence around this file (R2b's "not in scope") left both
    -- of them building an UN-merged ctx, so a registry spell greyed Save above a `save()` that would
    -- have accepted it, and a saved registry line still rendered `off`. This test fails on either
    -- revert, which no test before it did.
    describe("a registry spell, the whole way through the Builder (D83)", function()
      it("appends, reports no problems, enables Save, saves, and renders live with its icon", function()
        -- The tree only nests a fork under its template when the Wizard names that template as a
        -- row -- otherwise `byParent["TEMPLATE"]` has nowhere to attach, and `args.TEMPLATE` (read
        -- below) would not exist for a reason unrelated to anything D79-D83 touch.
        installWizard({ { build = "TEMPLATE", playstyle = "Template", fits = true } })
        -- Exactly what Options/Spells.lua's "add by id" writes: a registry entry the PACK has never
        -- heard of, keyed by its own slugged name rather than any pack key.
        local key = ns.Spells.add(ns.db.char.spells, { id = 9001, name = "Divine Steed", source = "id" })
        assert.is_truthy(key)
        assert.is_nil(PACK.spells[key], "the pack must not already carry this key or the test proves nothing")

        assert.is_true(Rotation.appendSpell(key))
        assert.same({}, Rotation.problems(),
          "D79: a registry spell must not be flagged as unresolvable")
        assert.is_false(builder().editing.args.save.disabled,
          "D79: Save must be enabled for a line naming a registry spell")

        assert.is_true(Rotation.save())

        local rows = Rotation.lineRows(forkKey)
        local last = rows[#rows]
        assert.equal(key, last.spell)
        assert.not_equal("off", last.mark,
          "D80: a saved registry line must not read as \"cannot happen on this character\"")

        -- The icon: the same seam D72 already wired (`ns.Display.spellIcon`), asked with the SAME
        -- key `lineRows` just carried through -- proving D80 handed the render layer a key it can
        -- actually look up, not a placeholder that happens to satisfy `#rows`.
        ns.Display.spellIcon = function(k) return k == key and "tex:registry" or nil end
        local lineArgs = Rotation.group().args.TEMPLATE.args[forkKey].args.lines.args
        local rendered = lineArgs["l" .. #rows].name
        assert.is_truthy(rendered:find("|Ttex:registry:0|t", 1, true),
          "the rendered row must carry the registry spell's icon")
      end)

      -- `make mutants` guard: deleting D80's merge line entirely leaves `ctx.spells` NIL, not merely
      -- un-merged -- and `Schema.validate`'s spell-key check (`ctx.spells and ctx.spells[key] == nil`)
      -- is itself skipped whenever `ctx.spells` is absent, so a genuinely unknown key would wrongly
      -- validate and every line would compile "off"-free either way. Checking one registry line's
      -- mark alone cannot tell a merged ctx from a missing one; a build that names a spell in NEITHER
      -- the pack NOR the registry can, because only a present (whichever shape) `ctx.spells` refuses it.
      it("still refuses the whole compile when a line names a spell nowhere at all", function()
        local build = realUserBuilds.find(PACK, forkKey)
        build.entries[#build.entries + 1] = { spell = "NOWHERE_AT_ALL" }
        ns.forgetCompiled(build)
        local rows = Rotation.lineRows(forkKey)
        assert.equal(#build.entries, #rows)
        for _, row in ipairs(rows) do
          assert.equal("off", row.mark, "one unresolvable key must refuse the WHOLE build, not just its own line")
        end
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

      -- D43: a texture dot, not the ASCII fallback (>> !! .. -- ++) -- row 1 is "firing" (queueOf(1)),
      -- which maps to the green indicator.
      it("renders the marker as a texture dot, and the reason beside it", function()
        queue = queueOf(1)
        local status = builder().list.args.r1.args.status
        assert.equal("description", status.type)
        assert.equal("full", status.width)
        assert.is_truthy(status.name:find("|TInterface\\COMMON\\Indicator-Green:12|t", 1, true))
        assert.is_nil(status.name:find(">>", 1, true), "the ASCII fallback is still present")
      end)

      -- D43's texture-dot mechanism, D73's colour map (2026-09-07 owner ruling, reversed from R1):
      -- firing green, waiting amber/yellow ("can fire, just not this instant"), blocked/off/unsaved
      -- grey ("cannot happen on this character right now"). Each is a real |T...|t texture escape,
      -- not a glyph the client's font would draw as an empty box.
      it("maps every state to the D73-decided indicator texture", function()
        local expectFile = {
          firing = "Indicator-Green", blocked = "Indicator-Gray",
          waiting = "Indicator-Yellow", off = "Indicator-Gray", unsaved = "Indicator-Gray",
        }
        for markState, file in pairs(expectFile) do
          local look = Rotation.MARKS[markState]
          assert.is_truthy(look.mark:find("|TInterface\\COMMON\\" .. file .. ":", 1, true), markState)
          assert.is_truthy(look.mark:find("|t", 1, true), markState)
        end
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
        assert.is_truthy(lines[3]:find("|TInterface\\COMMON\\Indicator-Green:12|t", 1, true),
          "the legend explains the markers")
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

      -- It hangs off the stale-parent banner on the fork's own page (D36), which is the moment
      -- ADR-0010 asks for a diff.
      it("appears under the banner on the fork's page, and only once the parent has moved on",
        function()
          forkOf(nil)
          realUserBuilds.find(PACK, forkKey).entries[1].when = nil
          installWizard{ { build = "TEMPLATE", playstyle = "Template", checks = {}, fits = true } }
          local stale = Rotation.group().args.TEMPLATE.args[forkKey].args.stale
          assert.is_table(stale, "no stale-parent banner at all")
          local lines = table.concat({ stale.args.banner.name, stale.args.d1.name }, " | ")
          assert.is_truthy(lines:find("has been updated since you forked it", 1, true))
          assert.is_truthy(lines:find("Different conditions on: EXORCISM", 1, true))

          -- Same fork, taken from the CURRENT template: no banner, and so no diff either.
          ns.db.global.userBuilds[forkKey].derivedAt = "2026-08-01"
          assert.is_nil(Rotation.group().args.TEMPLATE.args[forkKey].args.stale)
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
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
    end

    it("forks the template and activates the fork, in one call", function()
      install()
      local forked, repaints = nil, 0
      installUserBuilds{ fork = function(_, k, o) forked = { k, o.today }; return "USER_MINE" end,
                        find = function() return {} end }
      ns.Display.refresh = function() repaints = repaints + 1 end

      local ok, key = Rotation.customize("PALADIN_EXODIN")
      assert.is_true(ok)
      assert.equal("USER_MINE", key)
      assert.same({ "PALADIN_EXODIN", "2026-09-05" }, forked)
      assert.equal("USER_MINE", ns.db.profile.activeBuild, "the fork was made but never activated")
      assert.equal(1, repaints)
    end)

    it("is what the Copy and edit button on a template page does, once named", function()
      install()
      local forked
      installUserBuilds{ fork = function(_, k, o) forked = { k, o.name }; return "USER_MINE" end }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      Rotation.copyAndUse("PALADIN_EXODIN", "My Exodin")
      assert.same({ "PALADIN_EXODIN", "My Exodin" }, forked)
    end)

    it("hands the class pack to the fork", function()
      install()
      local gotClass
      installUserBuilds{ fork = function(pk) gotClass = pk and pk.class; return "USER_MINE" end }
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

    -- The fork still exists in that case, and is on the tree either way: saying so beats a click
    -- that appears to have done nothing.
    it("reports when the fork was made but could not be activated", function()
      install()
      installUserBuilds{ fork = function() return "USER_MINE" end }
      ns.db = nil -- Rotation.use refuses with no profile
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

  -- D34. The one function that writes a selection.
  describe("use()", function()
    local function install()
      ns.Display.currentPack = function()
        return { class = "PALADIN", catalog = { PALADIN = CATALOG },
                 builds = { PALADIN_EXODIN = {} } }
      end
      ns.Display.refresh = function() end
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
    end

    it("pins the build and records the catalog version seen", function()
      install()
      ns.Display.currentPack = function()
        return { class = "PALADIN", catalogVersion = 3, catalog = { PALADIN = CATALOG },
                 builds = { PALADIN_EXODIN = {} } }
      end
      ns.Wizard = { catalogVersion = function(p) return p.catalogVersion end }
      assert.is_true(Rotation.use("PALADIN_EXODIN"))
      assert.equal("PALADIN_EXODIN", ns.db.profile.activeBuild)
      assert.equal(3, ns.db.char.setupDone)
    end)

    it("pins one of the user's own rotations, not just a shipped template", function()
      install()
      installUserBuilds{ find = function(_, key)
        return key == "USER_MINE" and { key = "USER_MINE", entries = {} } or nil
      end }
      assert.is_true(Rotation.use("USER_MINE"))
      assert.equal("USER_MINE", ns.db.profile.activeBuild)
    end)

    it("still refuses a key that is neither a template nor one of your rotations", function()
      install()
      installUserBuilds{ find = function() return nil end }
      local ok, why = Rotation.use("USER_GHOST")
      assert.is_false(ok)
      assert.truthy(why:find("unknown build", 1, true))
      assert.is_false(ns.db.profile.activeBuild)
    end)

    it("refuses everything when the class has no data pack", function()
      install()
      ns.Display.currentPack = function() return nil end
      installUserBuilds{ find = function() return { key = "USER_MINE" } end }
      local ok, why = Rotation.use("USER_MINE")
      assert.is_false(ok)
      assert.truthy(why:find("unknown build", 1, true))
    end)

    it("does nothing but say so with no profile at all", function()
      install()
      ns.db = nil
      local ok, why = Rotation.use("PALADIN_EXODIN")
      assert.is_false(ok)
      assert.equal("no profile", why)
    end)

    -- D34: unlike the old wizard's plain print, using a rotation announces it -- the whole point of
    -- the "Rotation changed" category -- by its DISPLAY name, never the raw storage key.
    it("announces the switch by display name", function()
      install()
      installUserBuilds{}   -- the REAL name lookup: the sentence is built from the storage key
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      Rotation.use("PALADIN_EXODIN")
      assert.equal(1, #said)
      assert.equal("rotation", said[1][1])
      assert.equal("Now using Exodin.", said[1][2])
    end)

    it("does not announce and does not error when Announce is not loaded", function()
      install()
      ns.Announce = nil
      assert.is_true(Rotation.use("PALADIN_EXODIN"))
    end)

    it("refreshes the display", function()
      install()
      local refreshed = 0
      ns.Display.refresh = function() refreshed = refreshed + 1 end
      Rotation.use("PALADIN_EXODIN")
      assert.equal(1, refreshed)
    end)

    it("notifies the options registry so the tree redraws the new 'in use' marker", function()
      install()
      local notified = 0
      _G.LibStub = function() return { NotifyChange = function() notified = notified + 1 end } end
      Rotation.use("PALADIN_EXODIN")
      _G.LibStub = nil
      assert.equal(1, notified)
    end)
  end)

  -- D35. Naming a new rotation: the popups' PURE half (what to write), driven directly rather than
  -- through a fake StaticPopup -- the popup registration itself is covered in options_spec-adjacent
  -- fashion below, against the REAL StaticPopupDialogs table this file loads Rotation.lua against.
  describe("naming a rotation (D35)", function()
    local function install()
      ns.Display.currentPack = function()
        return { class = "PALADIN", catalog = { PALADIN = CATALOG }, builds = {} }
      end
      ns.Display.refresh = function() end
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
    end

    describe("createAndUse()", function()
      it("creates an empty fork with no template and switches to it", function()
        install()
        local created, gotClass
        installUserBuilds{ create = function(pk, name) created, gotClass = name, pk and pk.class; return "USER_NEW" end,
                          find = function() return {} end }
        local ok, key = Rotation.createAndUse("My rotation")
        assert.is_true(ok)
        assert.equal("USER_NEW", key)
        assert.equal("My rotation", created)
        assert.equal("PALADIN", gotClass)
        assert.equal("USER_NEW", ns.db.profile.activeBuild)
      end)

      it("refuses a blank name", function()
        install()
        local ok, err = Rotation.createAndUse("   ")
        assert.is_false(ok)
        assert.truthy(err:find("name", 1, true))
      end)

      it("passes through the reason when the builds module refuses to create", function()
        install()
        installUserBuilds{ create = function() return nil, "no saved variables" end }
        local ok, err = Rotation.createAndUse("My rotation")
        assert.is_false(ok)
        assert.equal("no saved variables", err)
        assert.is_false(ns.db.profile.activeBuild, "a failed create still switched something on")
      end)

      it("says so rather than erroring when the builds module cannot create", function()
        install()
        ns.UserBuilds = {}
        local ok, err = Rotation.createAndUse("My rotation")
        assert.is_false(ok)
        assert.truthy(err:find("not loaded", 1, true))
      end)
    end)

    describe("copyAndUse()", function()
      it("forks the named template under the typed name and switches to it", function()
        install()
        local forked, gotClass
        installUserBuilds{ fork = function(pk, k, o) forked, gotClass = { k, o.name }, pk and pk.class; return "USER_MINE" end,
                          find = function() return {} end }
        local ok, key = Rotation.copyAndUse("PALADIN_EXODIN", "My Exodin")
        assert.is_true(ok)
        assert.equal("USER_MINE", key)
        assert.same({ "PALADIN_EXODIN", "My Exodin" }, forked)
        assert.equal("PALADIN", gotClass)
      end)

      it("refuses a blank name, distinctly from a missing builds module", function()
        install()
        local ok, err = Rotation.copyAndUse("PALADIN_EXODIN", "")
        assert.is_false(ok)
        assert.equal("a rotation needs a name", err)
      end)

      it("refuses a name that is only whitespace", function()
        install()
        local ok, err = Rotation.copyAndUse("PALADIN_EXODIN", "   ")
        assert.is_false(ok)
        assert.equal("a rotation needs a name", err)
      end)

      it("passes through the reason when the builds module refuses to fork", function()
        install()
        installUserBuilds{ fork = function() return nil, "unknown template" end }
        local ok, err = Rotation.copyAndUse("PALADIN_NOPE", "My Exodin")
        assert.is_false(ok)
        assert.equal("unknown template", err)
      end)

      it("says so rather than erroring when the builds module cannot fork", function()
        install()
        ns.UserBuilds = {}
        local ok, err = Rotation.copyAndUse("PALADIN_EXODIN", "My Exodin")
        assert.is_false(ok)
        assert.truthy(err:find("not loaded", 1, true))
      end)
    end)

    describe("prefill names", function()
      it("suggests '<template> (mine)' the first time", function()
        install()
        installUserBuilds{ list = function() return {} end }
        assert.equal("Exodin (mine)", Rotation.copyPrefillName("Exodin"))
      end)

      it("hands the class pack to the fork lookup, not a stray nil", function()
        install()
        local gotClass
        installUserBuilds{ list = function(pk) gotClass = pk and pk.class; return {} end }
        Rotation.copyPrefillName("Exodin")
        assert.equal("PALADIN", gotClass)
      end)

      it("suggests '<template> (mine 2)' once '(mine)' is taken", function()
        install()
        installUserBuilds{ list = function() return { "USER_A" } end,
          find = function(_, key) return {}, "fork", { name = "Exodin (mine)" } end }
        assert.equal("Exodin (mine 2)", Rotation.copyPrefillName("Exodin"))
      end)

      it("suggests 'My rotation' the first time, then 'My rotation 2'", function()
        install()
        installUserBuilds{ list = function() return {} end }
        assert.equal("My rotation", Rotation.newRotationPrefillName())
        installUserBuilds{ list = function() return { "USER_A" } end,
          find = function() return {}, "fork", { name = "My rotation" } end }
        assert.equal("My rotation 2", Rotation.newRotationPrefillName())
      end)

      -- One collision alone cannot tell "counts up" from "always guesses 2"; a second one can.
      it("keeps counting past 2 when '(mine 2)' is ALSO taken", function()
        install()
        installUserBuilds{ list = function() return { "USER_A", "USER_B" } end,
          find = function(_, key)
            if key == "USER_A" then return {}, "fork", { name = "Exodin (mine)" } end
            return {}, "fork", { name = "Exodin (mine 2)" }
          end }
        assert.equal("Exodin (mine 3)", Rotation.copyPrefillName("Exodin"))
      end)

      it("keeps counting past 2 for New rotation too", function()
        install()
        installUserBuilds{ list = function() return { "USER_A", "USER_B" } end,
          find = function(_, key)
            if key == "USER_A" then return {}, "fork", { name = "My rotation" } end
            return {}, "fork", { name = "My rotation 2" }
          end }
        assert.equal("My rotation 3", Rotation.newRotationPrefillName())
      end)
    end)

    -- D35's mechanism itself: one StaticPopup for New/Copy, driven by `data.templateKey`, and a
    -- second for Rename. Never AceGUI (a real frame, per the artifact); registered once, at file
    -- scope, the way every addon's StaticPopupDialogs entry is.
    describe("the popups themselves", function()
      local function box(text)
        local b = { text = text }
        function b:GetText() return self.text end
        function b:SetText(t) self.text = t end
        function b:HighlightText() self.highlighted = true end
        return b
      end

      -- D61d: a harness that reproduces Blizzard's REAL `StaticPopup_Show` sequence -- registration
      -- lookup, Show with data, OnShow, the post-OnShow edit-box clear (exactly where D61b's bug
      -- lived), the accept click (button1 or Enter), and OnHide -- rather than calling OnShow/
      -- OnAccept by hand the way every test above this point still does. Installed only inside this
      -- describe block: it REPLACES the file's outer, dumber `_G.StaticPopup_Show` stub for the
      -- tests below, and `after_each` puts that one back so nothing elsewhere in this file notices.
      local outerShow
      local function harness()
        local shown
        local function newFrame(which)
          -- Blizzard's real StaticPopup frames sit at a low frame level (well under AceGUI's
          -- Frame's 100) inside DIALOG strata -- D62's whole point is that level, not just strata,
          -- decides who draws on top within a strata.
          local frame = { which = which, strata = "DIALOG", level = 5 }
          local editBox = { text = "" }
          function editBox:SetText(t) self.text = t or "" end
          function editBox:GetText() return self.text end
          function editBox:HighlightText() self.highlighted = true end
          function editBox:GetParent() return frame end
          frame.editBox = editBox
          function frame:SetFrameStrata(s) self.strata = s end
          function frame:GetFrameStrata() return self.strata end
          function frame:SetFrameLevel(l) self.level = l end
          function frame:GetFrameLevel() return self.level end
          local hideHooks = {}
          function frame:HookScript(event, fn)
            if event == "OnHide" then hideHooks[#hideHooks + 1] = fn end
          end
          frame.button1 = { Click = function()
            local dialog = _G.StaticPopupDialogs[frame.which]
            if dialog and dialog.OnAccept then dialog.OnAccept(frame, frame.data) end
          end }
          function frame:Hide()
            for _, fn in ipairs(hideHooks) do fn(self) end
          end
          return frame
        end
        _G.StaticPopup_Show = function(which, arg1, arg2, data)
          _G.__lastStaticPopup = { which = which, arg1 = arg1, arg2 = arg2, data = data }
          local dialog = _G.StaticPopupDialogs[which]
          if not dialog then return nil end
          shown = newFrame(which)
          shown.data = data
          if dialog.OnShow then dialog.OnShow(shown, data) end
          -- The exact Blizzard behaviour D61b exists to answer: the edit box is cleared AFTER
          -- OnShow returns, on every real Show, so a prefill written only from inside OnShow never
          -- survives to be seen.
          shown.editBox:SetText("")
          return shown
        end
        return {
          shown = function() return shown end,
          pressEnter = function()
            local dialog = _G.StaticPopupDialogs[shown.which]
            if dialog.EditBoxOnEnterPressed then dialog.EditBoxOnEnterPressed(shown.editBox) end
          end,
          click = function() shown.button1.Click() end,
          hide = function() shown:Hide() end,
        }
      end
      before_each(function() outerShow = _G.StaticPopup_Show end)
      after_each(function() _G.StaticPopup_Show = outerShow end)

      it("openNewRotationPopup shows the shared dialog, prefilled, with no templateKey", function()
        install()
        installUserBuilds{ list = function() return {} end }
        assert.is_true(Rotation.openNewRotationPopup())
        assert.equal("ELMIRA_NAME_ROTATION", _G.__lastStaticPopup.which)
        assert.equal("My rotation", _G.__lastStaticPopup.data.prefill)
        assert.is_nil(_G.__lastStaticPopup.data.templateKey)
      end)

      it("openCopyPopup shows the same dialog, carrying which template to fork", function()
        install()
        installUserBuilds{ list = function() return {} end }
        assert.is_true(Rotation.openCopyPopup("PALADIN_EXODIN", "Exodin"))
        assert.equal("ELMIRA_NAME_ROTATION", _G.__lastStaticPopup.which)
        assert.equal("Exodin (mine)", _G.__lastStaticPopup.data.prefill)
        assert.equal("PALADIN_EXODIN", _G.__lastStaticPopup.data.templateKey)
      end)

      it("openRenamePopup shows the rename dialog, prefilled with the current name", function()
        install()
        assert.is_true(Rotation.openRenamePopup("USER_MINE", "My Exodin"))
        assert.equal("ELMIRA_RENAME_ROTATION", _G.__lastStaticPopup.which)
        assert.equal("My Exodin", _G.__lastStaticPopup.arg1)
        assert.equal("My Exodin", _G.__lastStaticPopup.data.prefill)
        assert.equal("USER_MINE", _G.__lastStaticPopup.data.renameKey)
      end)

      -- D71: the source-link popup, the same shared layer as the three above it.
      it("openSourcePopup shows the show-source dialog with the full url prefilled", function()
        install()
        assert.is_true(Rotation.openSourcePopup("https://www.wowhead.com/classic/guide/paladin"))
        assert.equal("ELMIRA_SHOW_SOURCE", _G.__lastStaticPopup.which)
        assert.equal("https://www.wowhead.com/classic/guide/paladin",
                     _G.__lastStaticPopup.data.prefill)
      end)

      it("openSourcePopup does not error on a non-string source", function()
        install()
        assert.has_no.errors(function() Rotation.openSourcePopup(12345) end)
        assert.equal("12345", _G.__lastStaticPopup.data.prefill)
      end)

      it("every open*Popup reports false without erroring when StaticPopup is unavailable", function()
        install()
        _G.StaticPopupDialogs, _G.StaticPopup_Show = nil, nil
        assert.is_false(Rotation.openNewRotationPopup())
        assert.is_false(Rotation.openCopyPopup("PALADIN_EXODIN", "Exodin"))
        assert.is_false(Rotation.openRenamePopup("USER_MINE", "My Exodin"))
        assert.is_false(Rotation.openSourcePopup("https://example.com"))
      end)

      -- D61, driven through the harness's REAL sequence rather than a hand-built `self`. Every one
      -- of these FAILS against the pre-D61 code: proof this is testing the integration, not just
      -- the handler functions the way the tests above (and, before D61, every popup test) did.
      describe("D61: the real StaticPopup sequence", function()
        it("D61b: the prefill survives the post-OnShow clear", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harness()
          Rotation.openNewRotationPopup()
          assert.equal("My rotation", h.shown().editBox:GetText())
          assert.is_true(h.shown().editBox.highlighted)
        end)

        -- OnShow ALSO highlights (its own fallback prefill), so the assertion above alone cannot
        -- tell "prefillNow highlighted it" from "OnShow already had". Remove OnShow's own chance to
        -- and prove prefillNow does it on its own.
        it("D61b: highlights the text on its own, even without OnShow's help", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harness()
          _G.StaticPopupDialogs.ELMIRA_NAME_ROTATION.OnShow = nil
          Rotation.openNewRotationPopup()
          assert.equal("My rotation", h.shown().editBox:GetText())
          assert.is_true(h.shown().editBox.highlighted)
        end)

        it("D61b: Copy and edit's prefill survives too", function()
          install()
          local h = harness()
          Rotation.openCopyPopup("PALADIN_EXODIN", "Exodin")
          assert.equal("Exodin (mine)", h.shown().editBox:GetText())
        end)

        it("D61b: Rename's prefill survives too", function()
          install()
          local h = harness()
          Rotation.openRenamePopup("USER_MINE", "My Exodin")
          assert.equal("My Exodin", h.shown().editBox:GetText())
        end)

        it("D71: the source popup's full url survives the post-OnShow clear too, and is highlighted",
          function()
            install()
            local h = harness()
            Rotation.openSourcePopup("https://www.wowhead.com/classic/guide/paladin")
            assert.equal("https://www.wowhead.com/classic/guide/paladin", h.shown().editBox:GetText())
            assert.is_true(h.shown().editBox.highlighted)
          end)

        -- D62 (review finding on D61a): strata ALONE is not enough -- AceGUI's options Frame
        -- sits at FULLSCREEN_DIALOG, FRAME LEVEL 100, and SetFrameStrata never touches level, so
        -- two frames sharing one strata still draw by level. This is the assertion strata-only
        -- specs could not make: it fails against a fix that only calls SetFrameStrata.
        it("D62: raises both the strata AND the frame level above 100, restores both on hide", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harness()
          Rotation.openNewRotationPopup()
          assert.equal("FULLSCREEN_DIALOG", h.shown():GetFrameStrata())
          assert.is_true(h.shown():GetFrameLevel() > 100,
            "level must clear AceGUI's Frame (100), or the popup still draws behind it")
          h.hide()
          assert.equal("DIALOG", h.shown():GetFrameStrata())
          assert.equal(5, h.shown():GetFrameLevel(), "level must return to what it was")
        end)

        it("D62: Copy and edit's popup is raised past level 100 too", function()
          install()
          local h = harness()
          Rotation.openCopyPopup("PALADIN_EXODIN", "Exodin")
          assert.equal("FULLSCREEN_DIALOG", h.shown():GetFrameStrata())
          assert.is_true(h.shown():GetFrameLevel() > 100)
        end)

        it("D62: Rename's popup is raised past level 100 too", function()
          install()
          local h = harness()
          Rotation.openRenamePopup("USER_MINE", "My Exodin")
          assert.equal("FULLSCREEN_DIALOG", h.shown():GetFrameStrata())
          assert.is_true(h.shown():GetFrameLevel() > 100)
        end)

        -- D71's own popup MUST use the exact same raise -- the spec that names the trap this pass
        -- was warned about: a strata-only fix would open it behind the options window exactly like
        -- the naming popups before D62/D67 actually fixed them.
        it("D71: the source popup is raised past level 100 too, and restores its own level on hide",
          function()
            install()
            local h = harness()
            Rotation.openSourcePopup("https://www.wowhead.com/classic/guide/paladin")
            assert.equal("FULLSCREEN_DIALOG", h.shown():GetFrameStrata())
            assert.is_true(h.shown():GetFrameLevel() > 100)
            h.hide()
            assert.equal("DIALOG", h.shown():GetFrameStrata())
            assert.equal(5, h.shown():GetFrameLevel())
          end)

        it("D62: does nothing (no error) on a frame with no GetFrameLevel/SetFrameLevel at all", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local frame = { strata = "DIALOG", editBox = { SetText = function() end } }
          function frame:SetFrameStrata(s) self.strata = s end
          _G.StaticPopup_Show = function() return frame end
          assert.has_no.errors(function() Rotation.openNewRotationPopup() end)
          assert.equal("DIALOG", frame.strata, "must not have raised strata without a level to match it")
        end)

        -- D63 (same review): the OnHide restore is on a SHARED frame -- StaticPopup1-4 are reused
        -- by every addon's popups -- so an unconditional restore would force DIALOG/its own level
        -- back down the next time some OTHER addon shows a popup on the same frame, even though
        -- Elmira never touched THAT showing. Gated on `elmiraRaised`, set only by our own raise and
        -- cleared only by our own restore.
        it("D63: does not touch a hide it never raised for, even though the hook still fires", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local hideFns = {}
          local frame = { strata = "DIALOG", level = 5, editBox = { SetText = function() end } }
          function frame:SetFrameStrata(s) self.strata = s end
          function frame:GetFrameStrata() return self.strata end
          function frame:SetFrameLevel(l) self.level = l end
          function frame:GetFrameLevel() return self.level end
          function frame:HookScript(event, fn) if event == "OnHide" then hideFns[#hideFns + 1] = fn end end
          _G.StaticPopup_Show = function() return frame end

          Rotation.openNewRotationPopup() -- our own raise: elmiraRaised = true
          for _, fn in ipairs(hideFns) do fn(frame) end -- our own hide: restores, clears the flag
          assert.equal("DIALOG", frame.strata)
          assert.equal(5, frame.level)

          -- Some OTHER addon now shows its own popup on this SAME shared frame, entirely without
          -- going through Elmira's open*Popup -- our hook is still attached (HookScript chains and
          -- never unregisters) and fires anyway when THEIRS hides.
          frame.strata, frame.level = "FULLSCREEN", 250
          for _, fn in ipairs(hideFns) do fn(frame) end
          assert.equal("FULLSCREEN", frame.strata, "a hide Elmira never raised must not be touched")
          assert.equal(250, frame.level)
        end)

        -- D67 (re-review residual): the old `level < 100` / `level > 100` thresholds
        -- were asymmetric at 0 -- a frame starting there went to 100 and never came back down,
        -- mutating a shared Blizzard frame permanently. The fix stores the pre-raise level and
        -- restores exactly it, at every starting level, with no threshold at all.
        describe("D67: the round trip is exact at every starting level, not just above 100", function()
          local function frameAt(startLevel)
            local hideFns = {}
            local frame = { strata = "DIALOG", level = startLevel,
                             editBox = { SetText = function() end } }
            function frame:SetFrameStrata(s) self.strata = s end
            function frame:GetFrameStrata() return self.strata end
            function frame:SetFrameLevel(l) self.level = l end
            function frame:GetFrameLevel() return self.level end
            function frame:HookScript(event, fn)
              if event == "OnHide" then hideFns[#hideFns + 1] = fn end
            end
            frame.fireHide = function() for _, fn in ipairs(hideFns) do fn(frame) end end
            return frame
          end

          it("returns to level 0 exactly (the reviewer's own probe: 0 -> 100 -> 100 was the bug)", function()
            install()
            installUserBuilds{ list = function() return {} end }
            local frame = frameAt(0)
            _G.StaticPopup_Show = function() return frame end
            Rotation.openNewRotationPopup()
            assert.is_true(frame.level > 100, "must still clear AceGUI's Frame from level 0")
            frame.fireHide()
            assert.equal(0, frame.level, "must return to 0, not stay raised")
          end)

          it("returns to a level already above 100 exactly, not to 100 minus a fixed offset", function()
            install()
            installUserBuilds{ list = function() return {} end }
            local frame = frameAt(150)
            _G.StaticPopup_Show = function() return frame end
            Rotation.openNewRotationPopup()
            assert.is_true(frame.level > 150, "must still raise further above wherever it started")
            frame.fireHide()
            assert.equal(150, frame.level, "must return to its OWN original level, not a guessed one")
          end)

          it("does not re-capture the already-raised level as the original on a second open before hiding", function()
            install()
            installUserBuilds{ list = function() return {} end }
            local frame = frameAt(0)
            _G.StaticPopup_Show = function() return frame end
            Rotation.openNewRotationPopup()
            Rotation.openNewRotationPopup() -- same frame shown again before it ever hid
            frame.fireHide()
            assert.equal(0, frame.level, "the SECOND raise must not have overwritten the stored original")
          end)
        end)

        -- The guard that keeps a reused shared frame (StaticPopup1-4) from picking up a SECOND
        -- hide-hook every time this addon shows one -- observed directly on one persistent frame
        -- object, since the harness above (correctly) hands back a fresh one per Show.
        it("D61a: never stacks a second hide-hook on a frame the client reuses", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local hookCalls = 0
          local frame = { strata = "DIALOG", level = 5, editBox = { SetText = function() end } }
          function frame:SetFrameStrata(s) self.strata = s end
          function frame:GetFrameStrata() return self.strata end
          function frame:SetFrameLevel(l) self.level = l end
          function frame:GetFrameLevel() return self.level end
          function frame:HookScript() hookCalls = hookCalls + 1 end
          _G.StaticPopup_Show = function() return frame end
          Rotation.openNewRotationPopup()
          Rotation.openNewRotationPopup()
          assert.equal(1, hookCalls)
        end)

        -- StaticPopup1-4 are frames Blizzard can hide and re-show without this addon ever seeing a
        -- second OnHide fire in between; the guard against a stacked hook (`elmiraStrataHooked`)
        -- must still leave hiding idempotent -- one restore, not an error, not a second attempt.
        it("D61a: hiding the same popup twice stays at DIALOG, without erroring", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harness()
          Rotation.openNewRotationPopup()
          assert.equal("FULLSCREEN_DIALOG", h.shown():GetFrameStrata())
          h.hide()
          assert.has_no.errors(function() h.hide() end)
          assert.equal("DIALOG", h.shown():GetFrameStrata())
        end)

        it("D61c: pressing Enter in the edit box creates the rotation, exactly like clicking Create", function()
          install()
          local created
          installUserBuilds{ create = function(_, name) created = name; return "USER_NEW" end,
                            find = function() return {} end }
          local h = harness()
          Rotation.openNewRotationPopup()
          h.shown().editBox:SetText("Typed via keyboard")
          h.pressEnter()
          assert.equal("Typed via keyboard", created)
        end)

        it("D61c: clicking Create and switch with the prefilled name actually creates it", function()
          install()
          local created
          installUserBuilds{ create = function(_, name) created = name; return "USER_NEW" end,
                            find = function() return {} end }
          local h = harness()
          Rotation.openNewRotationPopup()
          h.click()
          assert.equal("My rotation", created)
        end)

        -- The exact D61c failure: an empty name (D61b's own bug, before its fix) refused silently.
        -- Now it must say so.
        it("D61c: an empty name reports the failure instead of doing nothing", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local said = {}
          ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
          local h = harness()
          Rotation.openNewRotationPopup()
          h.shown().editBox:SetText("")
          h.click()
          assert.equal(1, #said)
          assert.equal("warning", said[1][1])
          assert.is_truthy(said[1][2]:find("could not create", 1, true))
        end)

        it("D61c: pressing Enter on the rename popup renames too, exactly like clicking Rename", function()
          install()
          local renamed
          ns.UserBuilds = { rename = function(k, n) renamed = { k, n }; return true end }
          local h = harness()
          Rotation.openRenamePopup("USER_MINE", "My Exodin")
          h.shown().editBox:SetText("Renamed via keyboard")
          h.pressEnter()
          assert.same({ "USER_MINE", "Renamed via keyboard" }, renamed)
        end)

        it("D61c: a rename failure reports through announceFailure too", function()
          install()
          local said = {}
          ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
          ns.UserBuilds = { rename = function() return false, "not one of your rotations" end }
          local h = harness()
          Rotation.openRenamePopup("USER_MINE", "My Exodin")
          h.click()
          assert.equal(1, #said)
          assert.is_truthy(said[1][2]:find("could not rename", 1, true))
        end)
      end)

      describe("ELMIRA_NAME_ROTATION", function()
        local dialog
        before_each(function() dialog = _G.StaticPopupDialogs.ELMIRA_NAME_ROTATION end)

        it("prefills the edit box from the data it was shown with, and highlights it", function()
          local shown = box("")
          local self = { editBox = shown, data = { prefill = "My rotation" } }
          dialog.OnShow(self)
          assert.equal("My rotation", shown.text)
          assert.is_true(shown.highlighted)
        end)

        it("creates an empty rotation when shown with no templateKey", function()
          install()
          local created
          installUserBuilds{ create = function(_, name) created = name; return "USER_NEW" end,
                            find = function() return {} end }
          dialog.OnAccept({ editBox = box("My rotation"), data = {} })
          assert.equal("My rotation", created)
        end)

        it("forks the named template when shown WITH a templateKey", function()
          install()
          local forked
          installUserBuilds{ fork = function(_, k, o) forked = { k, o.name }; return "USER_MINE" end,
                            find = function() return {} end }
          dialog.OnAccept({ editBox = box("My Exodin"), data = { templateKey = "PALADIN_EXODIN" } })
          assert.same({ "PALADIN_EXODIN", "My Exodin" }, forked)
        end)

        -- StaticPopup hands `self` alone to OnShow/OnAccept in the real client; `data` only arrives
        -- as a second argument from some callers, so both read it off `self.data` as a fallback.
        it("reads data off self.data when it is not handed separately", function()
          install()
          local created
          installUserBuilds{ create = function(_, name) created = name; return "USER_NEW" end,
                            find = function() return {} end }
          local shown = box("")
          dialog.OnShow({ editBox = shown, data = { prefill = "From self.data" } })
          assert.equal("From self.data", shown.text)
          dialog.OnAccept({ editBox = box("Typed name"), data = {} })
          assert.equal("Typed name", created)
        end)

        it("says what it is for, with Create and switch / Cancel buttons", function()
          assert.equal("Name this rotation:", dialog.text)
          assert.equal("Create and switch", dialog.button1)
          assert.equal("Cancel", dialog.button2)
          assert.is_true(dialog.hasEditBox)
        end)
      end)

      describe("ELMIRA_RENAME_ROTATION", function()
        local dialog
        before_each(function() dialog = _G.StaticPopupDialogs.ELMIRA_RENAME_ROTATION end)

        it("prefills the edit box with the current name, and highlights it", function()
          local shown = box("")
          dialog.OnShow({ editBox = shown, data = { prefill = "My Exodin" } })
          assert.equal("My Exodin", shown.text)
          assert.is_true(shown.highlighted)
        end)

        it("renames through Rotation.rename", function()
          install()
          local renamed
          ns.UserBuilds = { rename = function(k, n) renamed = { k, n }; return true end }
          dialog.OnAccept({ editBox = box("New name"), data = { renameKey = "USER_MINE" } })
          assert.same({ "USER_MINE", "New name" }, renamed)
        end)

        it("does nothing when shown with no renameKey at all, rather than erroring", function()
          local ran
          ns.UserBuilds = { rename = function() ran = true end }
          assert.has_no.errors(function()
            dialog.OnAccept({ editBox = box("New name"), data = {} })
          end)
          assert.is_nil(ran)
        end)

        it("says what it is for, with a Rename button", function()
          assert.equal("Rename \"%s\":", dialog.text)
          assert.equal("Rename", dialog.button1)
          assert.is_true(dialog.hasEditBox)
        end)
      end)

      -- D71: no OnAccept at all -- this popup exists only to be read from and copied out of.
      describe("ELMIRA_SHOW_SOURCE", function()
        local dialog
        before_each(function() dialog = _G.StaticPopupDialogs.ELMIRA_SHOW_SOURCE end)

        it("prefills the edit box with the full url, and highlights it for copying", function()
          local shown = box("")
          dialog.OnShow({ editBox = shown,
                          data = { prefill = "https://www.wowhead.com/classic/guide/paladin" } })
          assert.equal("https://www.wowhead.com/classic/guide/paladin", shown.text)
          assert.is_true(shown.highlighted)
        end)

        it("says what it is for, with only a Close button", function()
          assert.equal("Copy this link:", dialog.text)
          assert.equal("Close", dialog.button1)
          assert.is_nil(dialog.button2)
          assert.is_true(dialog.hasEditBox)
        end)
      end)

      -- Loading the file twice (every spec's before_each) must not stack a second OnAccept behind
      -- the first, or a rename would silently fire twice for one click.
      it("does not re-register the dialogs on a second load", function()
        local first = _G.StaticPopupDialogs.ELMIRA_NAME_ROTATION
        Rotation = helper.load("Elmira/Options/Rotation.lua")
        assert.equal(first, _G.StaticPopupDialogs.ELMIRA_NAME_ROTATION)
      end)

      -- Same guard for the newer dialog: reloading this file (every spec's before_each) must not
      -- stack a second registration on top of the first.
      it("does not re-register ELMIRA_SHOW_SOURCE on a second load either", function()
        local first = _G.StaticPopupDialogs.ELMIRA_SHOW_SOURCE
        Rotation = helper.load("Elmira/Options/Rotation.lua")
        assert.equal(first, _G.StaticPopupDialogs.ELMIRA_SHOW_SOURCE)
      end)
    end)

    describe("rename()", function()
      it("renames through UserBuilds and notifies the tree", function()
        install()
        local renamed, notified = nil, 0
        ns.UserBuilds = { rename = function(k, n) renamed = { k, n }; return true end }
        _G.LibStub = function() return { NotifyChange = function() notified = notified + 1 end } end
        local ok = Rotation.rename("USER_MINE", "New name")
        _G.LibStub = nil
        assert.is_true(ok)
        assert.same({ "USER_MINE", "New name" }, renamed)
        assert.equal(1, notified)
      end)

      it("reports failure without erroring when the module is absent", function()
        install()
        ns.UserBuilds = nil
        local ok, err = Rotation.rename("USER_MINE", "New name")
        assert.is_false(ok)
        assert.truthy(err:find("not loaded", 1, true))
      end)
    end)

    describe("remove()", function()
      it("removes the fork and notifies the tree so the deleted page disappears", function()
        install()
        local removedKey, notified = nil, 0
        ns.UserBuilds = { remove = function(k) removedKey = k; return true end }
        _G.LibStub = function() return { NotifyChange = function() notified = notified + 1 end } end
        assert.is_true(Rotation.remove("USER_MINE"))
        _G.LibStub = nil
        assert.equal("USER_MINE", removedKey)
        assert.equal(1, notified)
      end)

      it("says so rather than erroring when the builds module is absent", function()
        install()
        ns.UserBuilds = nil
        assert.is_false(Rotation.remove("USER_MINE"))
      end)

      -- D35: deleting the rotation you are running leaves none in use.
      it("clears activeBuild and refreshes when the removed rotation was running", function()
        install()
        ns.db.profile.activeBuild = "USER_MINE"
        ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
        local refreshed = 0
        ns.Display.refresh = function() refreshed = refreshed + 1 end
        ns.UserBuilds = { remove = function() return true end }
        Rotation.remove("USER_MINE")
        assert.is_false(ns.db.profile.activeBuild)
        assert.equal(1, refreshed)
      end)

      it("leaves an unrelated active build alone", function()
        install()
        ns.db.profile.activeBuild = "USER_OTHER"
        ns.UserBuilds = { remove = function() return true end }
        Rotation.remove("USER_MINE")
        assert.equal("USER_OTHER", ns.db.profile.activeBuild)
      end)

      it("reports false without erroring when the module cannot remove", function()
        install()
        ns.UserBuilds = { remove = function() return false end }
        assert.is_false(Rotation.remove("USER_MINE"))
      end)
    end)
  end)

  -- D33/D36's "Rotation, top to bottom": the same Core/Gates evaluation the Builder's own status
  -- column runs, generalised to whichever key is being VIEWED.
  describe("lineRows()", function()
    local function installBuild(entries)
      ns.Display.currentPack = function()
        return { class = "PALADIN", spells = { EXORCISM = {} },
                 builds = { PALADIN_EXODIN = { entries = entries } } }
      end
      installUserBuilds{ find = realUserBuilds.find }
    end

    before_each(function()
      ns.compileBuild = function(build) return { entries = build.entries } end
    end)

    it("is empty, not an error, for an unknown key", function()
      installBuild({})
      assert.same({}, Rotation.lineRows("NOPE"))
    end)

    it("marks a disabled line off", function()
      installBuild{ { spell = "EXORCISM", disabled = true } }
      ns.compileBuild = function() return { entries = {} } end -- Schema.compile drops disabled rows
      local rows = Rotation.lineRows("PALADIN_EXODIN")
      assert.equal(1, #rows)
      assert.equal("off", rows[1].mark)
    end)

    it("marks a line blocked when the gate says it cannot fire for this character", function()
      installBuild{ { spell = "EXORCISM" } }
      ns.compileBuild = function(build)
        return { entries = { { index = 1, spell = "EXORCISM" } } }
      end
      ns.API = { GetState = function() return {} end }
      ns.Gates = { evaluate = function() return { { index = 1, active = false, reasons = { "needs a rune" } } } end }
      local rows = Rotation.lineRows("PALADIN_EXODIN")
      assert.equal("blocked", rows[1].mark)
    end)

    it("marks a line firing when nothing gates it", function()
      installBuild{ { spell = "EXORCISM" } }
      ns.compileBuild = function() return { entries = { { index = 1, spell = "EXORCISM" } } } end
      ns.API = { GetState = function() return {} end }
      ns.Gates = { evaluate = function() return { { index = 1, active = true, reasons = {} } } end }
      local rows = Rotation.lineRows("PALADIN_EXODIN")
      assert.equal("firing", rows[1].mark)
    end)

    -- D72: the row carries the spell key so the renderer can resolve its icon through the adapter.
    it("carries the entry's spell key", function()
      installBuild{ { spell = "EXORCISM" } }
      ns.compileBuild = function() return { entries = { { index = 1, spell = "EXORCISM" } } } end
      local rows = Rotation.lineRows("PALADIN_EXODIN")
      assert.equal("EXORCISM", rows[1].spell)
    end)

    it("treats a build that failed to compile as switched off rather than erroring", function()
      installBuild{ { spell = "EXORCISM" } }
      ns.compileBuild = function() return nil end
      local rows = Rotation.lineRows("PALADIN_EXODIN")
      assert.equal("off", rows[1].mark)
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

    -- D32's inline card, on the root page, made to READ as a card (D69): the group's own `name` is
    -- the title now, not an empty string with a name row underneath repeating it.
    it("titles the card with the playstyle name, an Open button, summary, difficulty and a source line",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "medium",
                         updated = "2026-08-01", summary = "Fast 2H.",
                         source = "https://www.wowhead.com/classic/guide/paladin",
                         recommended = true, fits = true } }
        local card = Rotation.group().args.card1
        assert.equal("group", card.type)
        assert.is_true(card.inline)
        -- The title IS the card's own bordered-pane heading (AceGUIContainer-InlineGroup.lua), the
        -- observable D69 exists to fix.
        assert.is_truthy(card.name:find("Exodin", 1, true))
        assert.equal("execute", card.args.open.type)
        assert.is_nil(card.args.open.set)
        assert.equal("Open", card.args.open.name)
        -- D69: the button no longer repeats the name the title already says.
        assert.is_falsy(card.args.open.name:find("Exodin", 1, true))
        assert.equal("Fast 2H.", card.args.summary.name)
        -- D70: difficulty is now on the meta line.
        assert.is_truthy(card.args.meta.name:find("medium", 1, true))
        assert.is_truthy(card.args.meta.name:find("2026%-08%-01"))
        assert.is_truthy(card.args.meta.name:find("recommended", 1, true))
        -- D71: the source is no longer concatenated into that same line...
        assert.is_falsy(card.args.meta.name:find("wowhead", 1, true))
        -- ...it has its own line, phrased so the subject is unambiguous, and a link button.
        assert.is_truthy(card.args.source.name:find("Source:", 1, true))
        assert.is_truthy(card.args.source.name:find("wowhead%.com"))
        assert.equal("execute", card.args.link.type)
        -- This row IS the one running (top before_each's default activeBuild), so there is no Use
        -- button at all -- the sequence is Open, summary, meta, source, link.
        assert.is_nil(card.args.use)
        assert.equal(1, card.args.open.order)
        assert.equal(2, card.args.summary.order)
        assert.equal(3, card.args.meta.order)
        assert.equal(4, card.args.source.order)
        assert.equal(5, card.args.link.order)
      end)

    -- Clicking Open navigates to the template's own page (D32), never a second `Open` of the panel.
    it("navigates to the template's own page when its Open button is clicked", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local selected
      ns.Options = { dialog = { SelectGroup = function(_, ...) selected = { ... } end } }
      Rotation.group().args.card1.args.open.func()
      assert.same({ "Elmira", "rotation", "PALADIN_EXODIN" }, selected)
    end)

    -- D71: the link button opens the SAME StaticPopup layer as D35/D61/D67, never a second one, with
    -- the FULL url (not the shortened host the source line shows).
    it("opens the source URL popup, in full, when the card's link button is clicked", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true,
                       source = "https://www.wowhead.com/classic/guide/paladin" } }
      local link = Rotation.group().args.card1.args.link
      assert.equal("Shows the full web address in a box you can select and copy.", link.desc)
      link.func()
      assert.equal("ELMIRA_SHOW_SOURCE", _G.__lastStaticPopup.which)
      assert.equal("https://www.wowhead.com/classic/guide/paladin", _G.__lastStaticPopup.data.prefill)
    end)

    it("has no source line or link button at all when the catalog entry carries no source", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local card = Rotation.group().args.card1
      assert.is_nil(card.args.source)
      assert.is_nil(card.args.link)
    end)

    -- The Wizard.lua heading, reused word for word so a player never sees it change.
    it("states level, class and weapon in the detection line", function()
      installPack()
      installWizard{}
      ns.Wizard.detection = function()
        return { class = "Paladin", level = 60, weapon = { type = "two-hander" } }
      end
      local line = Rotation.group().args.detection.name
      assert.is_truthy(line:find("Level 60 Paladin, holding a two%-hander", 1))
      assert.is_truthy(line:find("Pick how you want to play", 1, true))
    end)

    it("falls back to '?' and 'unknown' piece by piece when detection cannot answer", function()
      installPack()
      installWizard{}
      ns.Wizard.detection = function() return {} end
      local line = Rotation.group().args.detection.name
      assert.is_truthy(line:find("Level %? %?, holding a"))
      assert.is_truthy(line:find("unknown", 1, true))
    end)

    -- The row model carries `active`; the marker is what the player actually sees.
    it("badges the running template's TITLE, and offers Use on the others", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local args = Rotation.group().args
      assert.is_truthy(args.card1.name:find("in use", 1, true))
      assert.is_nil(args.card1.args.use, "the active row still offers a Use button")
      assert.is_falsy(args.card2.name:find("in use", 1, true))
      assert.equal("execute", args.card2.args.use.type)
      assert.equal("Use", args.card2.args.use.name)
      assert.is_nil(args.card2.args.use.desc, "a fitting row still explains a reason it does not have")
      assert.is_nil(args.card2.args.use.confirm)
      -- With a Use button present, it takes position 2 and everything after it shifts down one.
      assert.equal(1, args.card2.args.open.order)
      assert.equal(2, args.card2.args.use.order)
      assert.equal(3, args.card2.args.summary.order)
      assert.equal(4, args.card2.args.meta.order)
    end)

    -- D44: the Use button actually switches the rotation when clicked -- not just that the button
    -- looks right, but that its own `func` runs `Rotation.use` and the switch takes.
    it("actually switches to the rotation when the Use button is clicked", function()
      installPack()
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      Rotation.group().args.card2.args.use.func()
      assert.equal("PALADIN_SHOCKADIN", ns.db.profile.activeBuild)
      assert.equal(1, #said, "only the success announcement, no failure warning")
      assert.equal("rotation", said[1][1])
    end)

    -- D44: `Rotation.use` returns `false, reason` and this call site used to drop it, so a failed
    -- click looked exactly like a dead button. It must say why instead.
    it("announces the reason instead of doing nothing when the Use button fails to activate",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                       { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
        -- No ns.db in this describe block's default state, so Rotation.use refuses with "no profile".
        local said = {}
        ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
        Rotation.group().args.card2.args.use.func()
        assert.equal(1, #said)
        assert.equal("warning", said[1][1])
        assert.is_truthy(said[1][2]:find("could not set that playstyle", 1, true))
        assert.is_truthy(said[1][2]:find("no profile", 1, true))
      end)

    it("does not error when Announce is not loaded and the Use button fails", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      ns.Announce = nil
      Rotation.group().args.card2.args.use.func()
    end)

    -- Never a literal AceConfig `disabled`: `requires` is advisory (hard rule 8), so a card that
    -- does not fit still offers a button, worded and confirmed rather than refused.
    it("offers 'Use this anyway', confirmed, when a template needs gear or runes you do not have",
      function()
        installPack()
        ns.Display.activeBuild = function() return nil, nil end -- nothing active: the row must not be badged
        ns.Detect = { hasFailures = function(checks)
          for _, c in ipairs(checks or {}) do if c.ok == false then return true end end
          return false
        end }
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false,
                         checks = { { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" } } } }
        local use = Rotation.group().args.card1.args.use
        assert.equal("Use this anyway", use.name)
        assert.is_nil(use.disabled)
        assert.is_true(use.confirm)
        assert.equal("Weapon: 2H (you have 1H)", use.confirmText)
        assert.equal("Weapon: 2H (you have 1H)", use.desc)
      end)

    -- D48. Two catalog entries ship with `available = false` today (seal twisting, seal stacking):
    -- the tree used to drop them, so the owner's answer to "where is seal twisting?" was silence.
    -- Present, muted, and explained -- and still usable, because rule 8 forbids a hard gate.
    describe("a playstyle the pack cannot run yet (D48)", function()
      local function installTwist()
        installPack()
        ns.Display.activeBuild = function() return nil, nil end
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                       { build = "PALADIN_TWIST", playstyle = "Seal twisting", available = false,
                         summary = "Highest ceiling.", fits = true } }
      end

      it("still gives it a page in the tree, with its name muted", function()
        installTwist()
        local page = Rotation.group().args.PALADIN_TWIST
        assert.is_table(page, "an unavailable playstyle is missing from the tree entirely")
        assert.is_nil(page.disabled, "`disabled` hides the page, and the page is the explanation")
        assert.equal(ns.Colors.wrap(ns.Colors.MUTED, "Seal twisting"), page.name)
        -- and the one that IS runnable is not muted
        assert.equal("Exodin", Rotation.group().args.PALADIN_EXODIN.name)
      end)

      it("mutes its card's TITLE on the root page too, so the tree and the list agree", function()
        installTwist()
        local args = Rotation.group().args
        assert.equal(ns.Colors.wrap(ns.Colors.MUTED, "Seal twisting"), args.card2.name)
        assert.equal("Exodin", args.card1.name)
      end)

      it("says why on its own page, in words, above the summary", function()
        installTwist()
        local about = Rotation.group().args.PALADIN_TWIST.args.about.args
        assert.is_table(about.blocked, "the page never explains why the name is muted")
        assert.is_truthy(about.blocked.name:find("no rotation has shipped", 1, true))
        assert.is_true(about.blocked.order < about.summary.order)
        assert.is_nil(Rotation.group().args.PALADIN_EXODIN.args.about.args.blocked)
      end)

      it("keeps a Use button, worded and confirmed with that same reason", function()
        installTwist()
        local use = Rotation.group().args.PALADIN_TWIST.args.header.args.use
        assert.equal("Use this anyway", use.name)
        assert.is_nil(use.disabled)
        assert.is_true(use.confirm)
        assert.is_truthy(use.confirmText:find("no rotation has shipped", 1, true))
        assert.equal(use.confirmText, use.desc)
        assert.equal("Use", Rotation.group().args.PALADIN_EXODIN.args.header.args.use.name)
      end)

      -- The reason it cannot run comes first: "you need a two-hander" is true and beside the point
      -- when there is no rotation behind the name at all.
      it("prefers 'nothing shipped' over a failing requirement as the reason", function()
        installPack()
        ns.Display.activeBuild = function() return nil, nil end
        ns.Detect = { hasFailures = function() return true end }
        installWizard{ { build = "PALADIN_TWIST", playstyle = "Seal twisting", available = false,
                         fits = false,
                         checks = { { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" } } } }
        local use = Rotation.group().args.card1.args.use
        assert.is_truthy(use.confirmText:find("no rotation has shipped", 1, true))
      end)

      it("does not claim the character is ready for a rotation that does not exist", function()
        installTwist()
        local needs = Rotation.group().args.PALADIN_TWIST.args.needs.args
        assert.equal("Nothing extra needed from you.", needs.none.name)
        assert.equal("Nothing extra needed -- this rotation is ready to go.",
                     Rotation.group().args.PALADIN_EXODIN.args.needs.args.none.name)
      end)
    end)

    -- Wizard.rows reaches the catalog and Detect; an error there must not take the whole panel
    -- down with it, or one bad catalog entry means no settings window at all.
    it("renders an empty list rather than propagating a wizard error", function()
      installPack()
      ns.Wizard = { rows = function() error("bad catalog entry") end }
      assert.same({}, Rotation.templateRows())
    end)

    -- D70: the difficulty the catalog carries (Classes/Paladin.lua etc.) reaches the card, which
    -- used to drop it entirely.
    it("tags a card's meta line with its difficulty and marks an experimental one", function()
      installPack()
      installWizard{ { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", difficulty = "hard",
                       experimental = true, fits = true } }
      local meta = Rotation.group().args.card1.args.meta.name
      assert.is_truthy(meta:find("experimental", 1, true))
      assert.is_truthy(meta:find("hard", 1, true))
    end)

    -- A catalog `source` is always a URL string in practice; a malformed one must not error the
    -- whole panel over a punctuation problem in a guide link.
    it("does not error when a catalog source is not a URL-shaped string at all", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true, source = 12345 } }
      assert.has_no.errors(function() return Rotation.group() end)
    end)

    it("says so when the class ships no templates, and still offers New rotation", function()
      installPack()
      installWizard{}
      local root = Rotation.group().args
      assert.is_truthy(root.noPack.name:find("No playstyles for", 1, true))
      assert.equal("execute", root.newRotation.type)
      assert.is_nil(root.header, "a header for an empty catalog names nothing")
    end)

    it("names the class and catalog phase in the root page's header", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true, phase = "SoD P8" } }
      assert.is_truthy(Rotation.group().args.header.name:find("PALADIN", 1, true))
      assert.is_truthy(Rotation.group().args.header.name:find("SoD P8", 1, true))
    end)

    -- Absolute positions, not just "each is unique": a shift here would leave every row still
    -- distinct from the others (the uniqueness test above would not notice), only reordered on
    -- screen from what the artifact specifies -- detection, then New rotation, then the header.
    it("puts detection, New rotation and the header in that exact order", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local args = Rotation.group().args
      assert.equal(1, args.detection.order)
      assert.equal(2, args.newRotation.order)
      assert.equal(3, args.header.order)
      assert.equal(4, args.card1.order)
    end)

    it("puts New rotation right after detection when the class has no catalog", function()
      installPack()
      installWizard{}
      local args = Rotation.group().args
      assert.equal(1, args.detection.order)
      assert.equal(2, args.newRotation.order)
      assert.equal(3, args.noPack.order)
    end)

    -- D33: the template's OWN page, a tree node -- header, explanation and the needs/lines blocks.
    describe("the template's own page", function()
      it("has a header naming it, badged when it is the one running, with a Copy and edit button",
        function()
          installPack()
          installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
          local page = Rotation.group().args.PALADIN_EXODIN
          assert.equal("Exodin", page.name)
          local header = page.args.header.args
          assert.is_truthy(header.name.name:find("Exodin", 1, true))
          assert.is_truthy(header.name.name:find("in use", 1, true))
          assert.is_nil(header.use)
          assert.equal("execute", header.copy.type)
          assert.equal("Copy and edit", header.copy.name)
          assert.equal("Makes your own editable copy of this template, under a name you choose.",
                       header.copy.desc)
          assert.equal(1, header.name.order)
          assert.equal(2, header.copy.order)
          header.copy.func()
          assert.equal("PALADIN_EXODIN", _G.__lastStaticPopup.data.templateKey)
        end)

      it("offers Use before Copy and edit when the template is not the one running", function()
        installPack()
        ns.Display.activeBuild = function() return nil, nil end
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local header = Rotation.group().args.PALADIN_EXODIN.args.header.args
        assert.equal("execute", header.use.type)
        assert.equal(1, header.name.order)
        assert.equal(2, header.use.order)
        assert.equal(3, header.copy.order)
      end)

      it("lists what the rotation needs, one row per check plus the rune shopping list", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false,
          checks = { { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" },
                     { key = "RUNE_X", ok = true, text = "Art of War engraved" },
                     { key = "RUNE_Y", ok = nil, text = "Rune Y: could not read your runes" } },
          runesToEngrave = { "Art of War (feet)" } } }
        local needs = Rotation.group().args.PALADIN_EXODIN.args.needs
        assert.equal("What this rotation needs", needs.name)
        assert.is_truthy(needs.args.n1.name:find("Weapon: 2H", 1, true))
        -- D43: the three marks are the same indicator textures as the rotation lines below, one per
        -- Detect.check verdict (ok=false/true/nil) -- not a second, ASCII marker style on this page.
        assert.is_truthy(needs.args.n1.name:find("|TInterface\\COMMON\\Indicator-Yellow:12|t", 1, true))
        assert.is_truthy(needs.args.n2.name:find("Art of War engraved", 1, true))
        assert.is_truthy(needs.args.n2.name:find("|TInterface\\COMMON\\Indicator-Green:12|t", 1, true))
        assert.is_truthy(needs.args.n3.name:find("could not read your runes", 1, true))
        assert.is_truthy(needs.args.n3.name:find("|TInterface\\COMMON\\Indicator-Gray:12|t", 1, true))
        assert.is_truthy(needs.args.shopping.name:find("Art of War %(feet%)"))
        assert.is_truthy(needs.args.shopping.name:find("Rune Broker", 1, true))
        assert.equal(1, needs.args.n1.order)
        assert.equal(2, needs.args.n2.order)
        assert.equal(3, needs.args.n3.order)
        assert.equal(4, needs.args.shopping.order)
      end)

      it("says nothing extra is needed when every check passes", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true, checks = {} } }
        local needs = Rotation.group().args.PALADIN_EXODIN.args.needs
        assert.is_truthy(needs.args.none.name:find("ready to go", 1, true))
      end)

      -- D71 (2026-09-07, follow-up): the template's own page is where the card's Open
      -- button lands, so it must get the same split the card did -- date/difficulty together, the
      -- source unambiguous and on its own line with a link button, never concatenated.
      it("explains itself with the catalog's summary and notes, a meta line, then a separate source line",
        function()
          installPack()
          installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true,
            summary = "Fast 2H.", notes = "Never holds Exorcism.", difficulty = "medium",
            updated = "2026-08-01", source = "https://www.wowhead.com/classic/guide/paladin" } }
          local about = Rotation.group().args.PALADIN_EXODIN.args.about.args
          assert.equal("Fast 2H.", about.summary.name)
          assert.equal("Never holds Exorcism.", about.notes.name)
          -- D70: difficulty joins the meta line here too.
          assert.is_truthy(about.meta.name:find("medium", 1, true))
          assert.is_truthy(about.meta.name:find("2026%-08%-01"))
          -- The source is no longer concatenated onto that same line...
          assert.is_falsy(about.meta.name:find("wowhead", 1, true))
          -- ...it has its own line, phrased unambiguously, and a Copy link button.
          assert.is_truthy(about.source.name:find("Source:", 1, true))
          assert.is_truthy(about.source.name:find("wowhead%.com"))
          assert.equal("execute", about.link.type)
          assert.equal(1, about.summary.order)
          assert.equal(2, about.notes.order)
          assert.equal(3, about.meta.order)
          assert.equal(4, about.source.order)
          assert.equal(5, about.link.order)
        end)

      it("opens the source popup, in full, from the template page's own link button too", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true,
          source = "https://www.wowhead.com/classic/guide/paladin" } }
        local link = Rotation.group().args.PALADIN_EXODIN.args.about.args.link
        assert.equal("Shows the full web address in a box you can select and copy.", link.desc)
        link.func()
        assert.equal("ELMIRA_SHOW_SOURCE", _G.__lastStaticPopup.which)
        assert.equal("https://www.wowhead.com/classic/guide/paladin", _G.__lastStaticPopup.data.prefill)
      end)

      it("has no source line or link button on the template page when there is no source", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local about = Rotation.group().args.PALADIN_EXODIN.args.about.args
        assert.is_nil(about.source)
        assert.is_nil(about.link)
      end)

      it("skips summary and notes entirely when the catalog entry has neither", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local about = Rotation.group().args.PALADIN_EXODIN.args.about.args
        assert.is_nil(about.summary)
        assert.is_nil(about.notes)
        assert.equal(1, about.meta.order)
      end)

      it("renders the compiled rotation, top to bottom, from lineRows()", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        Rotation.lineRows = function(key)
          assert.equal("PALADIN_EXODIN", key)
          return { { index = 1, mark = "firing", label = "Exorcism", summary = "always" } }
        end
        local lines = Rotation.group().args.PALADIN_EXODIN.args.lines
        assert.equal("Rotation, top to bottom", lines.name)
        assert.is_truthy(lines.args.l1.name:find("Exorcism", 1, true))
        -- D43: the firing mark is the green texture dot, not the ASCII ">>".
        assert.is_truthy(lines.args.l1.name:find("|TInterface\\COMMON\\Indicator-Green:12|t", 1, true))
        assert.is_truthy(lines.args.l1.name:find("always", 1, true))
      end)

      -- D72 (2026-09-07 in-game round): "improvement should be adding the skill icons before their
      -- names" -- resolved through the ADAPTER (Display.spellIcon), the same seam mirrorLines and
      -- the Builder's own listArgs already use, never a direct WoW API call from this module.
      it("shows the spell's icon before its name on each line", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
        Rotation.lineRows = function()
          return { { index = 1, mark = "firing", label = "Exorcism", summary = "always",
                     spell = "EXORCISM" } }
        end
        local lines = Rotation.group().args.PALADIN_EXODIN.args.lines
        assert.is_truthy(lines.args.l1.name:find("|Ttex:ex:0|t", 1, true))
      end)

      -- A spell with no resolvable icon (unknown key, or an item line with no `spell` at all) must
      -- render with no icon and correct spacing -- never a broken texture escape or a shifted column.
      it("renders with no icon, and no broken texture escape, when the spell has none", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        ns.Display.spellIcon = function() return nil end
        Rotation.lineRows = function()
          return { { index = 1, mark = "firing", label = "Mystery", summary = "always",
                     spell = "UNKNOWN" } }
        end
        local lines = Rotation.group().args.PALADIN_EXODIN.args.lines
        -- Exactly one texture escape survives: the status mark itself (always present). A second
        -- one would be a broken/blank icon texture left behind by a bad resolution.
        local _, textureCount = lines.args.l1.name:gsub("|T", "")
        assert.equal(1, textureCount)
        assert.is_truthy(lines.args.l1.name:find("Mystery", 1, true))
      end)
    end)
  end)

  describe("forkRows()", function()
    it("says so when you have made none", function()
      installPack()
      installWizard{}
      assert.is_truthy(Rotation.group().args.newRotation.desc)
    end)

    -- The other truncation bug: `local _, _, fork = ns.UserBuilds and find(...)` discarded the fork
    -- record, so every row rendered as "not from a template".
    it("lists each fork with the template it came from", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function(pk, key)
          if key == "USER_MINE" then
            return {}, "fork", { name = "My Exodin", derivedFrom = "PALADIN_EXODIN" }
          end
          if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
        end,
      }
      local rows = Rotation.forkRows()
      assert.equal(1, #rows)
      assert.equal("My Exodin", rows[1].name)
      assert.equal("PALADIN_EXODIN", rows[1].derivedFrom)
      local fork = Rotation.group().args.PALADIN_EXODIN.args.USER_MINE
      assert.equal("My Exodin", fork.name)
      assert.is_truthy(fork.args.header.args.from.name:find("Exodin", 1, true))
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

    it("badges the running fork's page and offers Use on the others", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{
        list = function() return { "USER_MINE", "USER_OTHER" } end,
        find = function(_, key) return {}, "fork", { name = key } end,
      }
      local root = Rotation.group().args
      local mine = root.USER_MINE.args.header.args
      local other = root.USER_OTHER.args.header.args
      assert.is_truthy(mine.name.name:find("in use", 1, true))
      assert.is_nil(mine.use)
      assert.is_falsy(other.name.name:find("in use", 1, true))
      assert.equal("execute", other.use.type)
      -- Active: name, from, rename, delete (no Use). Not active: Use slots in between.
      assert.equal(1, mine.name.order)
      assert.equal(2, mine.from.order)
      assert.equal(3, mine.rename.order)
      assert.equal(4, mine.delete.order)
      assert.equal(1, other.name.order)
      assert.equal(2, other.from.order)
      assert.equal(3, other.use.order)
      assert.equal(4, other.rename.order)
      assert.equal(5, other.delete.order)
    end)

    -- Same widening the D30 tree tests guard: db.global is shared across characters, so the pack is
    -- what keeps a mage out of a paladin's forks.
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

    it("gives a fork with no template its own page directly under Rotations, with Rename and Delete",
      function()
        installPack()
        installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                          find = function() return {}, "fork", { name = "Scratch" } end }
        local page = Rotation.group().args.USER_SCRATCH
        assert.equal("Scratch", page.name)
        local header = page.args.header.args
        assert.is_truthy(header.from.name:find("yours", 1, true))
        assert.equal("execute", header.rename.type)
        assert.equal("Rename", header.rename.name)
        assert.equal("execute", header.delete.type)
        assert.equal("Delete", header.delete.name)
        assert.is_true(header.delete.confirm)
        assert.equal("execute", header.use.type)
        assert.equal(1, header.name.order)
        assert.equal(2, header.from.order)
        assert.equal(3, header.use.order)
        assert.equal(4, header.rename.order)
        assert.equal(5, header.delete.order)
      end)

    it("gives a fork's page an Edit button that activates it and jumps to the Builder", function()
      installPack()
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
      installUserBuilds{
        list = function() return { "USER_SCRATCH" } end,
        find = function() return { entries = {} }, "fork", { name = "Scratch" } end,
      }
      local selected
      ns.Options = { dialog = { SelectGroup = function(_, ...) selected = { ... } end } }
      local edit = Rotation.group().args.USER_SCRATCH.args.edit
      assert.equal("Opens this rotation in the Builder.", edit.desc)
      edit.func()
      assert.equal("USER_SCRATCH", ns.db.profile.activeBuild)
      assert.same({ "Elmira", "rotation", "builder" }, selected)
    end)

    it("does not re-activate the fork's Edit button when it is already the one running", function()
      installPack()
      ns.db = { profile = { activeBuild = "USER_SCRATCH" }, char = { setupDone = 0 } }
      ns.Display.activeBuild = function() return {}, "USER_SCRATCH", nil end
      installUserBuilds{
        list = function() return { "USER_SCRATCH" } end,
        find = function() return { entries = {} }, "fork", { name = "Scratch" } end,
      }
      local selected, used = nil, 0
      ns.Options = { dialog = { SelectGroup = function(_, ...) selected = { ... } end } }
      local realUse = Rotation.use
      Rotation.use = function(...) used = used + 1; return realUse(...) end
      Rotation.group().args.USER_SCRATCH.args.edit.func()
      Rotation.use = realUse
      assert.equal(0, used, "Use ran again on the rotation already active")
      assert.same({ "Elmira", "rotation", "builder" }, selected)
    end)

    -- D44: this Edit button used to navigate to the Builder REGARDLESS of whether activation
    -- succeeded, so a failed activation silently opened the Builder on a different rotation. It
    -- must say why and stay put instead.
    it("announces the reason and does NOT navigate when Edit fails to activate the fork", function()
      installPack()
      ns.db = nil -- Rotation.use refuses with no profile
      installUserBuilds{
        list = function() return { "USER_SCRATCH" } end,
        find = function() return { entries = {} }, "fork", { name = "Scratch" } end,
      }
      local selected
      ns.Options = { dialog = { SelectGroup = function(_, ...) selected = { ... } end } }
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      Rotation.group().args.USER_SCRATCH.args.edit.func()
      assert.is_nil(selected, "Edit navigated to the Builder despite a failed activation")
      assert.equal(1, #said)
      assert.equal("warning", said[1][1])
      assert.is_truthy(said[1][2]:find("could not set that playstyle", 1, true))
      assert.is_truthy(said[1][2]:find("no profile", 1, true))
    end)
  end)


  -- D47: the answer itself moved to Core/UserBuilds (Display announces a build change and may not
  -- reach into Options for the words). What is left here is the delegation and its one guard, so
  -- these drive the real Core function through the panel rather than a stub of it.
  describe("displayName()", function()
    it("prefers the catalog's playstyle name over the raw key", function()
      installPack()
      installUserBuilds{}
      assert.equal("Exodin", Rotation.displayName("PALADIN_EXODIN"))
    end)

    it("names one of your own rotations by the name you typed", function()
      installPack()
      installUserBuilds{ find = function() return {}, "fork", { name = "My Exodin" } end }
      assert.equal("My Exodin", Rotation.displayName("USER_MINE"))
    end)

    it("falls back to the key, because a blank row is worse than an ugly one", function()
      installPack()
      installUserBuilds{}
      assert.equal("PALADIN_UNKNOWN", Rotation.displayName("PALADIN_UNKNOWN"))
    end)

    -- Every other lookup in this file guards the same way: the panel is data and closures, and a
    -- row asked for its name before Core is up must render an ugly one, not error.
    it("answers with the key, and never errors, when the builds module is not loaded", function()
      installPack()
      ns.UserBuilds = nil
      assert.equal("PALADIN_EXODIN", Rotation.displayName("PALADIN_EXODIN"))
      assert.equal("?", Rotation.displayName(nil))
    end)
  end)
end)
