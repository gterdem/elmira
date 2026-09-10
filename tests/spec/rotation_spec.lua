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

  -- PA11 (2026-09-08): the root page's cards moved from `Rotation.group().args.cardN` directly into
  -- an inline group, `args.playstyles.args.cardN`, so the tests reach them the same way the real
  -- page now does.
  local function cards()
    return Rotation.group().args.playstyles.args
  end

  -- PE5-D1/D2: a detail header row right-aligns its buttons by FILLING the row -- every control
  -- relative, the relWidths summing to exactly 1.0. AceGUI's Flow layout starts a new row the moment
  -- they exceed it (AceGUI-3.0.lua:730), which would drop the last button onto a line of its own.
  -- Returns the sum so a caller can also compare the two shapes of the row against each other.
  local function headerRelSum(header)
    local total = 0
    for key, arg in pairs(header) do
      assert.equal("relative", arg.width, key .. " cannot be right-aligned")
      total = total + arg.relWidth
    end
    return total
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
    -- D2: the popup plumbing (raiseAbovePanel, editBox/button1, the prefill fix) now lives in
    -- Display/Popups.lua (ns.Popups), which Rotation.lua calls into rather than defining itself.
    helper.load("Elmira/Display/Popups.lua")
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
      assert.equal(2, g.order) -- M1a: 2 of the owner's 1-8 top-level order
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

    -- PE2-D3.3: the search box lives INSIDE the Abilities group now, as its first element, so it
    -- reads as a filter on that list rather than on the whole page.
    -- PE3-D2: and it owns the WHOLE row -- at half width the first 0.32 palette button flowed up
    -- beside it and sat misaligned, an EditBox carrying a label above its box where a Button has
    -- none. A "full" control ends its row, so the grid always starts on a fresh one.
    -- PE4-D3: and it is not drawn at all for a palette of the size a class pack actually has. ~20-30
    -- abilities, sorted by name and three across, is a list you read rather than search -- while the
    -- box costs a permanent row plus its label. It comes back by itself past 30 entries.
    it("gives the Builder a list of spells and items, and no search box for a small palette", function()
      installPack()
      local args = Rotation.group().args.builder.args
      assert.is_nil(args.search, "the page-level search box is gone")
      assert.is_nil(args.spells.args.search, "a search box for a palette you can already see")
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
    -- AB2-D5, the rotation side. The Share tab could not produce a string at all before this --
    -- only `/elm export` could -- and "include ability settings" is off by default, because a
    -- rotation string is what people paste at each other and quietly sending your glow colours,
    -- sounds and announcements with it is not what "share this rotation" means.
    describe("Export (AB2-D5)", function()
      local wrote, noted

      local function installExchange()
        wrote, noted = nil, nil
        ns.Options = { exchangeText = function() return wrote or "" end,
                       exchangeNote = function() return noted or "" end,
                       importText = function() end,
                       setExchangeText = function(str) wrote = str; noted = "" end,
                       noteExchange = function(text) noted = text end }
      end

      before_each(function()
        installPack()
        installExchange()
        ns.UserBuilds = { find = function(_, key) return { key = key, entries = { { spell = "EXORCISM" } } } end,
                          exportKey = function(_, key, extra)
                            return "ELM1:" .. key .. (extra and ":with-settings" or "")
                          end }
        Rotation.select("PALADIN_EXODIN")
        Rotation.setShareAbilities(false)
      end)

      it("ships the toggle off, and exports the rotation alone while it is", function()
        assert.is_false(box().abilities.get())
        assert.equal("execute", box().export.type)
        assert.equal("Export This Rotation", box().export.name)
        assert.is_truthy(box().export.desc:find("box below", 1, true))
        assert.is_truthy(box().abilities.desc:find("glow, screen-edge, sound and announcement", 1, true))
        assert.is_true(Rotation.exportSelected())
        assert.equal("ELM1:PALADIN_EXODIN", ns.Options.exchangeText())
        assert.is_truthy(ns.Options.exchangeNote():find("PALADIN_EXODIN", 1, true))
        -- Through the button, not only through the function behind it.
        ns.Options.setExchangeText("")
        box().export.func()
        assert.equal("ELM1:PALADIN_EXODIN", ns.Options.exchangeText())
      end)

      it("bundles the settings of the abilities the rotation names once the toggle is on", function()
        local askedFor
        ns.SpellsPage = { bundle = function(keys) askedFor = keys; return { abilities = {}, spells = {} } end }
        box().abilities.set(nil, true)
        assert.is_true(box().abilities.get())
        box().export.func()
        assert.equal("ELM1:PALADIN_EXODIN:with-settings", ns.Options.exchangeText())
        assert.is_true(askedFor.EXORCISM, "it bundled the wrong ability keys")
      end)

      it("says why when the export fails, and leaves no half-string in the box", function()
        ns.UserBuilds.exportKey = function() return nil, "serializer is not loaded" end
        ns.Options.setExchangeText("ELM1:something-older")
        assert.is_false(Rotation.exportSelected())
        assert.equal("", ns.Options.exchangeText())
        assert.is_truthy(ns.Options.exchangeNote():find("serializer is not loaded", 1, true))
      end)

      -- Options.lua and Core/UserBuilds.lua are both reached lazily (TOC load order), so the
      -- button has to answer for itself rather than erroring inside a click handler.
      it("does nothing, without erroring, when the modules it needs are not loaded", function()
        ns.UserBuilds = nil
        assert.is_false(Rotation.exportSelected())
        ns.UserBuilds = { find = function() return nil end, exportKey = function() return "ELM1:x" end }
        ns.Options = nil
        assert.is_false(Rotation.exportSelected())
      end)
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

    -- PE4-D3: the search box only exists once the palette is bigger than 30 entries, so a test that
    -- wants to drive the box has to give it a palette that big. Registry entries, because that is
    -- what the palette is one row per (D58) -- a class pack of this size is exactly the case the
    -- rule keeps the box for.
    local function installBigPalette(n)
      installPalette(function() return true end)
      for i = 1, n do
        ns.db.char.spells["EXTRA_" .. i] = { key = "EXTRA_" .. i, id = 900000 + i,
                                             name = "Extra " .. i, source = "id" }
      end
    end

    it("lists the pack's abilities and not its rune records", function()
      installPalette(function() return true end)
      local args = Rotation.group().args.builder.args.spells.args
      local names = {}
      for key, row in pairs(args) do
        if key ~= "add" and key ~= "search" then names[#names + 1] = row.name end
      end
      assert.equal(2, #names, "expected Exorcism and Divine Storm, no rune record")
    end)

    -- The whole point of the owner's "show everything, grey the rest" choice: the row you cannot
    -- use yet has to say what to do about it.
    -- PE2-D3.2: the row you cannot use yet still has to say what to do about it -- but the sentence
    -- moved out of the label and into the tooltip, so three buttons fit across a row.
    it("dims an un-known ability and names the rune that grants it, in the tooltip", function()
      installPalette(function() return false end)
      local args = Rotation.group().args.builder.args.spells.args
      local row
      for key, candidate in pairs(args) do
        if key ~= "search" and candidate.name:find("DIVINE_STORM", 1, true) then row = candidate end
      end
      assert.is_truthy(row, "no row for the un-known ability")
      -- This palette is the INERT (template) shape, a description: an AceGUI Label has no tooltip
      -- to move the reason into, so there it stays in the text. The clickable shape puts it in
      -- `desc` instead -- see "moves the reason into the tooltip on a clickable palette" below.
      assert.equal("description", row.type)
      assert.is_truthy(row.name:find("Engrave", 1, true), "no reason on the greyed row")
      assert.is_truthy(row.name:find("|cff9AA0A6", 1, true), "the un-known row is not dimmed")
    end)

    -- PE2-D3.2: two different reasons, two different sentences. "Engrave X" is an instruction the
    -- player can act on today; an ability with no rune behind it is simply not learned yet, and
    -- naming a rune for it would send them shopping for something that does not exist.
    it("says which of the two reasons an ability cannot be used", function()
      installPalette(function() return false end)
      local args = Rotation.group().args.builder.args.spells.args
      local byName = {}
      for key, row in pairs(args) do
        if key ~= "search" and key ~= "add" then byName[row.name] = row end
      end
      local rune, plain
      for name, row in pairs(byName) do
        if name:find("DIVINE_STORM", 1, true) then rune = row
        elseif name:find("EXORCISM", 1, true) then plain = row end
      end
      assert.is_truthy(rune and plain, "the palette lost one of its two rows")
      assert.is_truthy(rune.name:find("Engrave", 1, true))
      assert.is_truthy(plain.name:find("You have not learned this ability yet.", 1, true),
        "an ability with no rune behind it does not say why it is greyed")
      assert.is_nil(plain.name:find("Engrave", 1, true),
        "an ability with no rune behind it was told to engrave one")
    end)

    -- PE2-D3.1 (owner ruling): three across, not one full-width button per entry -- seventeen
    -- centred rows was most of the page. Both shapes carry it, or a template's palette and a
    -- fork's lay out differently from one another.
    it("lays the palette three across in both its shapes", function()
      installPalette(function() return true end)
      local inert = Rotation.group().args.builder.args.spells.args
      for key, row in pairs(inert) do
        if key ~= "search" and key ~= "add" then
          assert.equal("description", row.type)
          assert.equal("relative", row.width, key .. " is not a relative-width row")
          assert.equal(0.32, row.relWidth, key .. " does not fit three across")
        end
      end
    end)

    -- PE4-D3: the box only exists once the palette is bigger than 30 entries, and the size it
    -- measures is the REGISTRY -- which the palette seeds from the class pack on every read. Asked
    -- before anything else has read the palette, the count has to seed it for itself or a pack of
    -- forty abilities answers zero and the box never appears.
    it("counts the palette by seeding the registry for itself", function()
      installPalette(function() return true end)
      assert.equal(2, Rotation.paletteSize())
    end)

    it("draws the search box as a full-width input, and says what it filters", function()
      installBigPalette(31)
      local row = Rotation.group().args.builder.args.spells.args.search
      assert.equal("input", row.type)
      assert.equal(0, row.order, "the search box is no longer above the abilities it filters")
      assert.equal("full", row.width)
      assert.equal("Search", row.name)
      assert.equal("Filters the abilities below. Plain text, not a pattern.", row.desc)
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
      installBigPalette(31)
      local row = Rotation.group().args.builder.args.spells.args.search
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
      assert.equal(2.5, row.order)
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

    -- D58's last row: navigation to the Abilities page (M1b wording), present whether or not
    -- anything matches. The `spells` group key it navigates to is unchanged.
    describe("the palette's \"Add from spellbook...\" row (D58)", function()
      it("is the last row, and always present even when nothing matches", function()
        installPalette(function() return true end)
        Rotation.setSearch("zzzz")
        local args = Rotation.group().args.builder.args.spells.args
        assert.equal("execute", args.add.type)
        assert.is_truthy(args.add.desc:find("Abilities page", 1, true))
      end)

      it("navigates the open dialog to the Abilities root page, not into the draft", function()
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
      -- R3 (D84): the header names the ability through an in-place SELECT on a fork, so the icon
      -- travels in the option's own label rather than a separate description.
      local row = Rotation.group().args.builder.args.list.args.r1.args.spell
      assert.equal("select", row.type)
      assert.equal(4, row.order)
      assert.equal(1.0, row.width)
      assert.is_truthy(row.values["spell:EXORCISM"]:find("|Ttex:ex:0|t", 1, true))
      assert.equal("spell:EXORCISM", row.get())
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
      ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
      local args = Rotation.group().args.builder.args.list.args
      assert.equal("description", args.r1.args.spell.type)
      assert.is_truthy(args.r1.args.spell.name:find("|Ttex:ex:0|t", 1, true))
      assert.is_nil(args.r1.args.up)
      assert.is_nil(args.r1.args.down)
      assert.is_nil(args.r1.args.remove)
      assert.is_nil(args.r1.args.body.args.on)
      assert.equal(1, args.r1.args.body.args.words.order)
      assert.is_truthy(Rotation.group().args.builder.args.intro.name
        :find("cannot be edited", 1, true))
    end)

    -- Every draft edit is reachable with no draft open: a template is the page's normal state
    -- (read-only, ADR-0005) and each of these is a public entry point. "No" is the answer; an error
    -- out of a rotation page that is merely being LOOKED at is not.
    it("answers no, rather than erroring, to every draft edit on a template", function()
      install("pack")
      assert.is_nil(Rotation.draft(), "the template opened a draft, so this proves nothing")
      assert.is_false(Rotation.moveRow(1, 1))
      assert.is_false(Rotation.moveRowTo(1, 2))
      assert.is_false(Rotation.setRowDisabled(1, true))
      assert.is_false(Rotation.canReset())
      assert.is_false(Rotation.resetToTemplate())
    end)

    it("offers all three on a rotation of your own", function()
      install("fork")
      local args = Rotation.group().args.builder.args.list.args
      assert.equal("select", args.r1.args.spell.type)
      assert.equal("toggle", args.r1.args.body.args.on.type)
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
      local row = Rotation.group().args.builder.args.list.args.r1.args.body.args.on
      assert.is_true(row.get())
      row.set(nil, false)
      assert.equal(0, repaints)
      assert.is_true(Rotation.listRows()[1].disabled)
      assert.is_nil(BUILD.entries[1].disabled)
    end)

    -- R3 (D85): a switched-off line says so in the SENTENCE rather than through a colour alone --
    -- `entry.disabled` is read straight off the draft, so this is immediate, unlike the dot (D87),
    -- which stays tied to the SAVED, running rotation until Save.
    it("says a line is switched off in its own sentence", function()
      install("fork")
      BUILD.entries[1].disabled = true
      local args = Rotation.group().args.builder.args.list.args
      assert.is_truthy(args.r1.args.sentence.name:find("Switched off", 1, true))
      assert.is_false(args.r1.args.body.args.on.get())
      BUILD.entries[1].disabled = nil
    end)

    -- The author's own note is more use than a count, so it wins when there is one -- now read
    -- through the panel's own sentence-building, `Rotation.headerSentence`.
    it("folds a single condition into the header sentence", function()
      install("fork")
      local args = Rotation.group().args.builder.args.list.args
      assert.is_truthy(args.r2.args.sentence.name:find("stacks or more", 1, true))
      assert.is_nil(args.r2.args.sentence.name:find("is cast", 1, true), "the verb is back")
      -- PE2-D2.3: line 1 has no conditions here, so it gets no sentence control at all rather than
      -- an empty full-width description reserving a blank row.
      assert.is_nil(args.r1.args.sentence)
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
        -- PE3-D3: the readable words the condition editor's Value dropdown reads -- a set's `name`,
        -- a soul's `short`, a bonus's `note` and the `from` list that says which of the two a bonus
        -- comes from. Shaped exactly as Classes/Paladin.lua ships them.
        sets = { PALADIN_T35_INQUISITION = { name = "Inquisition Shockplate (T3.5)" } },
        souls = { SOUL_OF_THE_EXILE = { short = "Exile" } },
        bonuses = { HOLY_POWER_CONSUME = { note = "Divine Storm consumes Holy Power",
                      from = { { set = "PALADIN_T35_INQUISITION", pieces = 4 },
                               { soul = "SOUL_OF_THE_EXILE" } } },
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
      -- `keys` mirrors what AceDB actually populates at load (Elmira/Libs/AceDB-3.0), independent
      -- of whether this class ships a pack -- F1a reads it as the class filter's ground truth, so a
      -- fixture without it would make the pack vanishing (below) look like a class the addon cannot
      -- identify, which is not what a real client session is ever like.
      ns.db = { global = { userBuilds = {} }, profile = { paletteAllSlots = false },
                char = { spells = {} }, keys = { class = "PALADIN", char = "Arthorion - Realm" } }
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
        Rotation.selectRow(2)
        assert.is_true(Rotation.isExpanded(2))
        Rotation.moveRow(1, 1)
        assert.is_true(Rotation.draft().dirty)
        local other = realUserBuilds.fork(PACK, "TEMPLATE", { name = "Other" })
        forkKey = other
        local d = Rotation.draft()
        assert.equal(other, d.key)
        assert.is_false(d.dirty, "a fresh rotation opens clean")
        assert.equal("EXORCISM", d.entries[1].spell)
        -- The expanded body is UI state about the rotation being LOOKED AT, not the draft object --
        -- it must forget itself the moment that changes too, or the new rotation opens with some
        -- unrelated line's body already showing.
        assert.is_false(Rotation.isExpanded(2), "the expanded body must not survive a rotation switch")
      end)

      -- Each of `toggleExpand`/`moveRow`/`removeRow` re-syncs for itself rather than trusting a
      -- PRIOR call to have done it -- a stale index from the rotation just left behind must not
      -- silently follow an edit made in the new one.
      it("does not toggle a stale expanded index back open when a rotation switch left it behind", function()
        Rotation.selectRow(2)
        forkKey = realUserBuilds.fork(PACK, "TEMPLATE", { name = "OtherToggle" })
        Rotation.draft()
        assert.is_true(Rotation.toggleExpand(2))
        assert.is_true(Rotation.isExpanded(2), "a stale 'already open' must not turn this click into a close")
      end)

      it("does not carry a stale expanded index into a swap made in a different rotation", function()
        Rotation.selectRow(2)
        forkKey = realUserBuilds.fork(PACK, "TEMPLATE", { name = "OtherMove" })
        Rotation.draft()
        Rotation.moveRow(2, -1)
        assert.is_false(Rotation.isExpanded(1))
        assert.is_false(Rotation.isExpanded(2))
      end)

      it("does not carry a stale expanded index into a removal made in a different rotation", function()
        Rotation.selectRow(2)
        forkKey = realUserBuilds.fork(PACK, "TEMPLATE", { name = "OtherRemove" })
        Rotation.draft()
        Rotation.removeRow(1)
        assert.is_false(Rotation.isExpanded(1))
      end)

      -- `isExpanded` is the only PUBLIC reader of the expand state, and it re-syncs on every call --
      -- which is what makes the three tests above pass whichever of `toggleExpand`/`moveRow`/
      -- `removeRow` a caller reaches first. This one calls NOTHING else in between, which is what
      -- isolates `isExpanded`'s OWN re-sync: without it, this is the one case nothing else papers
      -- over, because nothing re-validated freshness before answering.
      it("does not itself answer a stale expanded index across a rotation switch, with no other call between", function()
        Rotation.selectRow(2)
        forkKey = realUserBuilds.fork(PACK, "TEMPLATE", { name = "OtherIsExpanded" })
        Rotation.draft()
        assert.is_false(Rotation.isExpanded(2))
      end)

      -- PE4-D1/D4: the row is three buttons now, right-aligned as a group (four relative widths
      -- summing to exactly 1.0), and each label is coloured by what it does -- but ONLY while it is
      -- enabled, because AceGUI greys a disabled button's FONT OBJECT and a `|cff` escape inside
      -- the text would win over that, leaving a green Save that does nothing.
      it("says whether it has unsaved changes, and offers Save, Discard and Reset accordingly", function()
        local args = builder().editing.args
        assert.is_truthy(args.state.name:find("Mine", 1, true))
        assert.is_truthy(args.state.name:find("saved", 1, true))
        assert.is_true(args.save.disabled, "nothing to save yet")
        assert.is_true(args.discard.disabled)
        assert.equal("Save", args.save.name, "a disabled Save is still painted green")
        assert.equal("Discard", args.discard.name)

        assert.equal(0.4, args.state.relWidth)
        for _, key in ipairs({ "state", "save", "discard", "reset" }) do
          assert.equal("relative", args[key].width, key .. " cannot be right-aligned")
        end
        assert.equal(1.0, args.save.relWidth + args.discard.relWidth + args.reset.relWidth
                          + args.state.relWidth)

        Rotation.moveRow(1, 1)
        args = builder().editing.args
        assert.is_truthy(args.state.name:find("unsaved changes", 1, true))
        assert.is_false(args.save.disabled)
        assert.is_false(args.discard.disabled)
        assert.equal(ns.Colors.wrap(ns.Colors.OK, "Save"), args.save.name)
        assert.equal(ns.Colors.wrap(ns.Colors.BAD, "Discard"), args.discard.name)
      end)

      -- PE4-D1. Reset writes the DRAFT, never the saved rotation: that is what makes it undoable
      -- (Discard puts the saved lines back) and why it carries no confirmation popup.
      describe("Reset, which puts the template back", function()
        it("is disabled while the draft already matches the template", function()
          local args = builder().editing.args
          assert.is_true(args.reset.disabled)
          assert.equal("Reset", args.reset.name, "a disabled Reset is still painted red")
          assert.is_truthy(args.reset.desc:find("Nothing is saved until you press Save", 1, true))
        end)

        it("is disabled for a rotation that was started empty and has no original", function()
          forkKey = realUserBuilds.create(PACK, "Scratch")
          Rotation.discard()
          assert.is_false(Rotation.canReset())
          assert.is_true(builder().editing.args.reset.disabled)
          assert.is_false(Rotation.resetToTemplate(), "there is no template to go back to")
        end)

        it("puts the template's lines into the draft, leaving the saved rotation alone", function()
          Rotation.removeRow(1)
          Rotation.removeRow(1)
          assert.is_true(Rotation.save())
          assert.equal(3, #realUserBuilds.find(PACK, forkKey).entries)

          local args = builder().editing.args
          assert.is_false(args.reset.disabled)
          assert.equal(ns.Colors.wrap(ns.Colors.BAD, "Reset"), args.reset.name)

          args.reset.func()
          local rows = Rotation.listRows()
          assert.equal(5, #rows, "the template's lines are not back in the draft")
          assert.equal("EXORCISM", rows[1].spell)
          assert.equal("DIVINE_STORM", rows[2].spell)
          assert.is_nil(rows[1].src, "a reset line claims to be a line the display is running")
          assert.is_false(builder().editing.args.save.disabled, "Reset did not mark the draft dirty")
          assert.equal(3, #realUserBuilds.find(PACK, forkKey).entries,
            "Reset wrote the SAVED rotation, so Discard could not undo it")

          -- Undoable, which is the whole design: Discard throws the reset draft away and the saved
          -- three lines come back.
          Rotation.discard()
          assert.equal(3, #Rotation.listRows())
        end)

        -- The comparison is a DEEP one over the authored fields. A changed condition leaves the
        -- row count and every spell key exactly as the template has them, so anything shallower
        -- greys Reset out against a draft that differs in the only place the player edited.
        it("counts a changed condition as something to go back from", function()
          assert.is_false(Rotation.canReset(), "a fresh fork already reads as different")
          assert.is_true(Rotation.setCondition(1, 1, "value", 55))
          assert.is_true(Rotation.canReset())
        end)

        it("counts a removed condition as something to go back from", function()
          assert.is_true(Rotation.removeCondition(1, 1))
          assert.is_true(Rotation.canReset())
        end)

        -- The open body followed a line that no longer exists at that position; leaving it open
        -- would expand whichever of the template's lines happens to sit there now.
        it("closes the expanded body, which now belongs to a line that is gone", function()
          Rotation.removeRow(1)
          Rotation.selectRow(2)
          assert.is_true(Rotation.isExpanded(2))
          Rotation.resetToTemplate()
          assert.is_false(Rotation.isExpanded(2))
        end)

        -- A deep copy, exactly as a fork is: a draft holding a reference into the shipped template
        -- would edit it for every character on the account, and the edit would vanish on reload
        -- with no sign it had ever been made.
        it("copies the template's conditions rather than sharing them", function()
          Rotation.removeRow(1)
          Rotation.resetToTemplate()
          assert.is_true(Rotation.removeCondition(1, 1), "the reset line lost its conditions")
          assert.equal(1, #PACK.builds.TEMPLATE.entries[1].when,
            "editing the draft edited the shipped template itself")
        end)
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

      -- Moving the row you are editing must not silently switch the expanded body to a different
      -- ability (R3: the expand flag, not `d.selected`, is what now follows the line).
      it("carries the expanded body with the line it is on", function()
        Rotation.selectRow(2)
        Rotation.moveRow(2, -1)
        assert.is_true(Rotation.isExpanded(1))
        local _, entry = Rotation.paneModel(1)
        assert.equal("DIVINE_STORM", entry.spell)
        Rotation.selectRow(3)
        Rotation.moveRow(2, 1)  -- swaps 2 and 3, so the expanded body follows to 2
        assert.is_true(Rotation.isExpanded(2))
      end)

      -- PE2-D2.1's Top and Bottom. A move to an arbitrary position, NOT a loop over `moveRow`:
      -- looping the swap would mark the draft dirty once per hop and drag every row it passed
      -- through one place the wrong way for a frame.
      it("moves a line straight to another position, shifting the block it passes", function()
        local function order()
          local out = {}
          for i, row in ipairs(Rotation.listRows()) do out[i] = row.spell or ("item" .. row.item) end
          return out
        end
        local was = order()
        assert.is_true(Rotation.moveRowTo(4, 1))
        assert.same({ was[4], was[1], was[2], was[3], was[5] }, order())
        assert.is_true(Rotation.moveRowTo(1, 3))
        assert.same({ was[1], was[2], was[4], was[3], was[5] }, order())
      end)

      it("refuses a move that would not be one", function()
        local before = #Rotation.listRows()
        assert.is_false(Rotation.moveRowTo(2, 2), "a line onto itself is not a change")
        assert.is_false(Rotation.moveRowTo(1, 99))
        assert.is_false(Rotation.moveRowTo(99, 1))
        assert.is_false(Rotation.moveRowTo(nil, nil))
        assert.equal(before, #Rotation.listRows())
        -- The indices are numbers however they arrive: `entries["2"]` is not `entries[2]`, and a
        -- public entry point that silently does nothing for a numeric string is the worst of both.
        assert.is_true(Rotation.moveRowTo("2", "1"))
      end)

      -- The expanded body follows the LINE it is on, not the position. Moving a row you are
      -- editing must not silently switch the conditions on screen to a different ability -- and
      -- neither must moving some OTHER row past it.
      it("carries the expanded body through a move to any position", function()
        Rotation.selectRow(4)
        Rotation.moveRowTo(4, 1)
        assert.is_true(Rotation.isExpanded(1), "the body stayed behind on the old position")

        Rotation.discard()
        Rotation.selectRow(1)
        Rotation.moveRowTo(4, 1)          -- a row lands ON TOP of the expanded one
        assert.is_true(Rotation.isExpanded(2))

        Rotation.discard()
        Rotation.selectRow(3)
        Rotation.moveRowTo(1, 4)          -- a row leaves from ABOVE the expanded one
        assert.is_true(Rotation.isExpanded(2))

        Rotation.discard()
        Rotation.selectRow(5)
        Rotation.moveRowTo(1, 4)          -- ...and one entirely below the block does not move
        assert.is_true(Rotation.isExpanded(5))
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
      it("removes a line, and closes the expanded body if it was the one removed", function()
        Rotation.selectRow(2)
        assert.is_true(Rotation.removeRow(2))
        assert.equal(4, #Rotation.draft().entries)
        assert.is_false(Rotation.isExpanded(2))
        assert.equal("JUDGEMENT", Rotation.listRows()[2].spell)
        Rotation.selectRow(3)
        Rotation.removeRow(1)
        assert.is_true(Rotation.isExpanded(2), "the expanded body follows its line upwards")
        assert.is_false(Rotation.removeRow(99))
      end)

      it("appends from the palette, at the bottom, expanded and unsaved", function()
        assert.is_true(Rotation.appendSpell("CONSECRATION"))
        local d = Rotation.draft()
        assert.equal(6, #d.entries)
        assert.equal("CONSECRATION", d.entries[6].spell)
        assert.is_nil(d.entries[6].src, "an appended line is in no saved rotation yet")
        assert.is_true(Rotation.isExpanded(6), "the next thing anyone wants is its conditions")
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
        args.r2.args.expand.func()
        assert.is_true(Rotation.isExpanded(2))
        args.r1.args.body.args.on.set(nil, false)
        assert.is_true(Rotation.draft().entries[1].disabled)
        args.r1.args.down.func()
        assert.equal("DIVINE_STORM", Rotation.listRows()[1].spell)
        builder().list.args.r5.args.remove.func()
        assert.equal(4, #Rotation.draft().entries)
      end)

      -- R3 (D84): the in-place select changes what a line DOES without touching its position or
      -- its conditions -- the counterpart to `appendSpell`/`appendItem`, which only ever ADD a line.
      it("changes a line's ability from the in-place select, keeping its conditions", function()
        assert.is_false(Rotation.draft().dirty)
        local before = Rotation.draft().entries[1].when
        assert.is_true(Rotation.setLineAction(1, "spell:CONSECRATION"))
        assert.is_true(Rotation.draft().dirty)
        assert.equal("CONSECRATION", Rotation.draft().entries[1].spell)
        assert.equal(before, Rotation.draft().entries[1].when)
        Rotation.setLineAction(1, "item:13")
        assert.is_nil(Rotation.draft().entries[1].spell)
        assert.equal(13, Rotation.draft().entries[1].item)
        assert.is_false(Rotation.setLineAction(1, "not a real key"))
        assert.is_false(Rotation.setLineAction(99, "spell:CONSECRATION"))
      end)

      -- The same "say what is actually there" guarantee as the spell fallback above, for an item
      -- slot the (trinket-only, `paletteAllSlots` off) palette does not currently list.
      it("keeps the in-place select showing an item slot that has fallen out of the palette", function()
        Rotation.setLineAction(5, "item:1") -- Head: not offered while only trinkets are shown
        local row = builder().list.args.r5.args.spell
        assert.equal("item:1", row.get())
        assert.is_truthy(row.values["item:1"])
      end)

      -- The in-place select's own icons -- both palettes, through the loop rather than the
      -- entry-only fallback the two tests above cover -- and proof the palette SEARCH box does not
      -- narrow this dropdown, restoring the typed filter unchanged once it has answered.
      it("shows an icon for every palette choice, ignoring and then restoring the search filter", function()
        ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
        ns.Display.itemIcon = function(slot) return slot == 13 and "tex:tr" or nil end
        Rotation.setSearch("zzz-matches-nothing")
        local values = Rotation.actionChoices()
        assert.is_truthy(values["spell:EXORCISM"]:find("|Ttex:ex:0|t", 1, true))
        assert.is_truthy(values["item:13"]:find("|Ttex:tr:0|t", 1, true))
        assert.equal("zzz-matches-nothing", Rotation.search(), "the search box's own text must survive")
      end)

      -- A hand-edited SavedVariables entry can bind to neither -- `encodeAction` must still answer
      -- something the select can hold rather than erroring.
      it("shows a blank action for a line bound to neither a spell nor an item", function()
        Rotation.draft().entries[5].item = nil
        assert.equal("", builder().list.args.r5.args.spell.get())
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
        assert.is_true(Rotation.isExpanded(1), "the expanded body stays on the line it was on")
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
        Rotation.addCondition(6, "buff")
        Rotation.setCondition(6, 1, "key", "NOT_A_SPELL_IN_THE_PACK")
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

    describe("the conditions pane (now each panel's body, R3)", function()
      it("is hidden until its line is expanded, and reads that line's model either way", function()
        assert.is_true(builder().list.args.r1.args.body.hidden())
        assert.is_table(Rotation.paneModel(1), "the model exists even while collapsed")
        Rotation.selectRow(1)
        assert.is_false(builder().list.args.r1.args.body.hidden())
      end)

      it("draws one control group per condition, described in words", function()
        Rotation.selectRow(1)
        local args = builder().list.args.r1.args.body.args
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

      -- D86: the link to that spell's own page in the Abilities tree, sitting beside the key select.
      -- M1b renamed the page's WORDING to "Abilities"; the `spells` navigation key is unchanged.
      it("links a spell-shaped condition to its page in the Abilities tree", function()
        -- Line 1's own condition is `resource` (a power, not a spell key) -- add a `buff` condition,
        -- whose key source IS spell-shaped, to reach the link this test is about.
        Rotation.addCondition(1, "buff")
        local link = builder().list.args.r1.args.body.args.conditions.args.c2.args.openSpell
        assert.equal("execute", link.type)
        assert.is_truthy(link.name():find("CONSECRATION", 1, true))
        assert.is_truthy(link.name():find("in Abilities", 1, true))
        local navigated
        ns.Options = { dialog = { SelectGroup = function(_, app, page, tab, key)
          navigated = { app, page, tab, key }
        end } }
        link.func()
        -- AB1-D11: the entries live in an INNER tree under the Abilities tab, so the path grew a
        -- step. A two-part path lands on the page and leaves the tree wherever it happened to be.
        assert.same({ "Elmira", "spells", "list", "CONSECRATION" }, navigated)
        -- The purely POWER condition alongside it links nowhere.
        assert.is_nil(builder().list.args.r1.args.body.args.conditions.args.c1.args.openSpell)

        -- A key deliberately cleared (never possible through the UI's own default, but reachable by
        -- a hand-edited row) must not offer a live link to nowhere.
        Rotation.setCondition(1, 2, "key", nil)
        link = builder().list.args.r1.args.body.args.conditions.args.c2.args.openSpell
        assert.equal("in Abilities >", link.name())
        assert.is_true(link.disabled())
        assert.is_truthy(link.desc:find("Abilities tree", 1, true))
      end)

      -- D86: the key select's REGISTRY merge (Rotation.lua's private `mergedPack`), covering the
      -- three shapes it can answer -- no pack at all, a pack with no registry to widen it, and the
      -- ordinary case where the registry adds a key the pack alone does not carry.
      describe("the registry merge behind the key select (D86)", function()
        it("registers and offers a spell no pack knows about", function()
          local key = ns.Spells.add(ns.db.char.spells, { id = 9002, name = "Divine Steed", source = "id" })
          Rotation.addCondition(1, "buff")
          local values = builder().list.args.r1.args.body.args.conditions.args.c2.args.key.values
          assert.is_truthy(values[key], "a registry-only spell must be offered as a condition key")
        end)

        it("still offers the pack's own keys when the registry is not loaded at all", function()
          ns.Spells = nil
          Rotation.addCondition(1, "buff")
          local values = builder().list.args.r1.args.body.args.conditions.args.c2.args.key.values
          assert.is_truthy(values.EXORCISM, "the pack's own spells must still be offered")
        end)

        it("does not offer a registry-only key while the registry is not loaded", function()
          local key = ns.Spells.add(ns.db.char.spells, { id = 9003, name = "Divine Steed", source = "id" })
          ns.Spells = nil
          Rotation.addCondition(1, "buff")
          local values = builder().list.args.r1.args.body.args.conditions.args.c2.args.key.values
          assert.is_nil(values[key])
        end)

        -- `UserBuilds.find` tolerates a nil pack for a FORK key -- F1a: it reads the player's class
        -- from AceDB's `db.keys`, which stays put whether or not a pack does, rather than from the
        -- vanished pack itself -- so the draft survives the pack vanishing mid-edit, exactly the
        -- moment `mergedPack` must degrade rather than error.
        it("adds a condition with no key, rather than erroring, when there is no active pack at all", function()
          Rotation.draft() -- established while the pack is still there
          ns.Display.currentPack = function() return nil end
          assert.is_true(Rotation.addCondition(1, "buff"))
          assert.is_nil(Rotation.draft().entries[1].when[2][2], "buff's key sits at position 2")
        end)
      end)

      -- AceConfig round-trips a select value through the widget, so a numeric key comes back as a
      -- string and would never compare equal to the number the row holds.
      it("keys every select by a string, including inventory slots", function()
        Rotation.selectRow(5)
        local row = builder().list.args.r5.args.body.args.conditions.args.c1
        assert.equal("13", row.args.slot.get())
        row.args.slot.set(nil, "14")
        assert.equal(14, Rotation.draft().entries[5].when[1][2])
        for _, control in pairs(row.args) do
          if control.type == "select" then
            for id in pairs(control.values) do assert.equal("string", type(id)) end
          end
        end
      end)

      it("edits a value, an operator, a field and a category from the rendered panel", function()
        Rotation.selectRow(1)
        local body = function() return builder().list.args.r1.args.body.args end
        body().conditions.args.c1.args.amount.set(nil, "90")
        assert.equal(90, Rotation.draft().entries[1].when[1].minPct)

        body().conditions.args.c1.args.op.set(nil, "maxPct")
        local cond = Rotation.draft().entries[1].when[1]
        assert.equal(90, cond.maxPct)
        assert.is_nil(cond.minPct, "changing the test must move the qualifier, not add one")

        -- A field change REPLACES the row: an operator or key carried over from the old field is a
        -- qualifier the new one does not have, and the panel would look right while the compiler
        -- rejected the result.
        body().conditions.args.c1.args.field.set(nil, "target_hp")
        assert.equal("target_hp", Rotation.draft().entries[1].when[1][1])
        body().conditions.args.c1.args.category.set(nil, "state")
        assert.same({ { "in_combat" } }, Rotation.draft().entries[1].when)
      end)

      it("offers only the fields of the chosen category", function()
        Rotation.selectRow(1)
        local row = builder().list.args.r1.args.body.args.conditions.args.c1
        assert.is_truthy(row.args.field.values.resource)
        assert.is_nil(row.args.field.values.in_combat)
        assert.is_truthy(row.args.category.values.gear)
      end)

      it("adds, negates and removes a condition", function()
        assert.is_true(Rotation.selectRow(3))
        assert.same({}, Rotation.paneModel(3).rows)
        local body = function() return builder().list.args.r3.args.body.args end
        body().add.set(nil, "in_combat")
        assert.same({ { "in_combat" } }, Rotation.draft().entries[3].when)
        body().conditions.args.c1.args.negated.set(nil, true)
        assert.same({ { "not", { "in_combat" } } }, Rotation.draft().entries[3].when)
        body().conditions.args.c1.args.remove.func()
        assert.same({}, Rotation.draft().entries[3].when)
        assert.is_nil(body().conditions, "no empty group once the last row is gone")
      end)

      it("switches the whole line between all and any", function()
        Rotation.selectRow(1)
        assert.is_true(Rotation.addCondition(1, "in_combat"))
        assert.equal(2, #Rotation.draft().entries[1].when)
        local body = function() return builder().list.args.r1.args.body.args end
        body().match.set(nil, "any")
        local when = Rotation.draft().entries[1].when
        assert.equal(1, #when)
        assert.equal("any", when[1][1])
        assert.equal("any", Rotation.paneModel(1).match)
        body().match.set(nil, "all")
        assert.equal(2, #Rotation.draft().entries[1].when)
      end)

      -- Every setter answers whether it wrote, and every write marks the draft dirty -- without
      -- which Save stays greyed out and the edit is unreachable however right it looks.
      it("answers whether it wrote, and marks the draft dirty when it did", function()
        assert.is_false(Rotation.draft().dirty)
        assert.is_true(Rotation.addCondition(1, "in_combat"))
        assert.is_true(Rotation.draft().dirty)
        Rotation.discard()

        assert.is_true(Rotation.setMatch(1, "any"))
        assert.is_true(Rotation.draft().dirty)
        Rotation.discard()

        assert.is_true(Rotation.setCondition(1, 1, "value", 5))
        assert.is_true(Rotation.draft().dirty)
        Rotation.discard()

        assert.is_true(Rotation.removeCondition(1, 1))
        assert.is_true(Rotation.draft().dirty)
      end)

      it("gives a new condition a legal value rather than a blank that reports an error", function()
        Rotation.addCondition(3, "buff")
        local when = Rotation.draft().entries[3].when
        assert.is_truthy(when[1][2], "a new condition arrives with a key already chosen")
        local _, errors = ns.Schema.compileWhen(when, packTables())
        assert.equal(0, #errors)
        assert.same({}, Rotation.problems())
        assert.is_false(Rotation.addCondition(3, "no_such_field"))
      end)

      -- A slot-taking field has no key source to draw a default from, so it needs its own: without
      -- one, `item_ready` arrives with no slot and reports an error before it has been touched.
      it("gives a slot field a real slot to start on", function()
        assert.is_true(Rotation.addCondition(3, "item_ready"))
        assert.same({ { "item_ready", 13 } }, Rotation.draft().entries[3].when)
        assert.same({}, Rotation.problems())
      end)

      -- Changing the field REPLACES the row, and the negation is a property of the row rather than
      -- of the field -- so it has to survive the replacement, or a `not` silently disappears.
      it("keeps the negation when the field or the category changes", function()
        Rotation.addCondition(3, "in_combat")
        Rotation.setCondition(3, 1, "negated", true)
        assert.same({ { "not", { "in_combat" } } }, Rotation.draft().entries[3].when)
        Rotation.setCondition(3, 1, "kind", "not_moving")
        assert.same({ { "not", { "not_moving" } } }, Rotation.draft().entries[3].when)
        Rotation.setCondition(3, 1, "category", "encounter")
        assert.equal("not", Rotation.draft().entries[3].when[1][1])
        assert.equal("enemies", Rotation.draft().entries[3].when[1][2][1])
        -- And an un-negated row must not gain one.
        Rotation.setCondition(3, 1, "negated", nil)
        Rotation.setCondition(3, 1, "kind", "in_combat")
        assert.same({ { "in_combat" } }, Rotation.draft().entries[3].when)
      end)

      -- Nested conditions are shown, never edited (owner decision, 2026-09-05). Read-only is not
      -- the same as hidden: the "why" of a line IS its conditions.
      it("shows a nested line in words and offers no controls", function()
        Rotation.selectRow(4)
        local model = Rotation.paneModel(4)
        assert.is_true(model.complex)
        local args = builder().list.args.r4.args.body.args
        assert.is_nil(args.match)
        assert.is_nil(args.conditions)
        assert.is_nil(args.add)
        assert.is_truthy(args.words.name:find("Holy Wrath is instant", 1, true))
        assert.is_truthy(args.words.name:find("target is Undead or Purifying Power engraved",
                                              1, true))
        assert.is_truthy(args.note.name:find("nested more deeply", 1, true))
      end)

      it("refuses every edit on a nested line, rather than rewriting it", function()
        local before = Rotation.draft().entries[4].when
        assert.is_false(Rotation.setMatch(4, "any"))
        assert.is_false(Rotation.addCondition(4, "in_combat"))
        assert.is_false(Rotation.removeCondition(4, 1))
        assert.is_false(Rotation.setCondition(4, 1, "op", "min"))
        assert.equal(before, Rotation.draft().entries[4].when)
        assert.is_false(Rotation.draft().dirty)
      end)

      it("refuses an edit outside the draft, or naming a line/field it does not own", function()
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        assert.is_false(Rotation.setMatch(1, "any"))
        assert.is_false(Rotation.setCondition(1, 1, "op", "min"))
        assert.is_false(Rotation.addCondition(1, "in_combat"))
        assert.is_false(Rotation.removeCondition(1, 1))
        ns.Display.activeBuild = function() return compiledFork(), forkKey, "pinned" end
        assert.is_false(Rotation.setCondition(1, 9, "op", "min"))
        assert.is_false(Rotation.setCondition(1, 1, "spell", "EXORCISM"))
        assert.is_false(Rotation.setCondition(1, 1, "category", "no_such_category"))
        assert.is_false(Rotation.setCondition(1, 1, "kind", "no_such_field"))
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
        Rotation.addCondition(3, "in_combat")          -- passes: the fake state is in combat
        Rotation.addCondition(3, "resource")
        Rotation.setCondition(3, 2, "op", "minPct")
        Rotation.setCondition(3, 2, "value", 150)      -- cannot pass: mana is capped at 100%
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
        Rotation.addCondition(3, "buff")
        Rotation.setCondition(3, 1, "key", "VENGEANCE_BUFF")
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

      -- R3: the author's note (or the condition summary) no longer lives beside the OLD status
      -- text at all -- `Rotation.listRows()[i].note`/`.summary` still carry it, unaffected, for
      -- whatever reads it (the row's own data, `Rotation.conditionSummary`); the panel's header now
      -- carries the sentence (D85) instead.
      it("still prefers the author's note in the row data, falling back to the summary", function()
        realUserBuilds.find(PACK, forkKey).entries[1].label = "opener"
        ns.forgetCompiled(realUserBuilds.find(PACK, forkKey))
        Rotation.discard()
        local rows = Rotation.listRows()
        assert.equal("opener", rows[1].note)
        assert.is_truthy(rows[1].summary:find("mana at least 40%", 1, true))

        realUserBuilds.find(PACK, forkKey).entries[1].label = nil
        ns.forgetCompiled(realUserBuilds.find(PACK, forkKey))
        Rotation.discard()
        rows = Rotation.listRows()
        assert.is_nil(rows[1].note)
        assert.is_truthy(rows[1].summary:find("mana at least 40%", 1, true))
      end)

      -- D43/D87: a texture dot, not the ASCII fallback (>> !! .. -- ++) -- row 1 is "firing"
      -- (queueOf(1)), which maps to `lineState` nil and so the green "everything's fine" mark.
      it("renders the header's dot as a texture, at its own small width", function()
        queue = queueOf(1)
        assert.is_nil(Rotation.lineState(1))
        local status = builder().list.args.r1.args.status
        assert.equal("description", status.type)
        assert.equal(0.2, status.width)
        assert.is_truthy(status.name:find("|TInterface\\AddOns\\Elmira\\media\\mark_firing:12|t", 1, true))
        assert.is_nil(status.name:find(">>", 1, true), "the ASCII fallback is still present")
      end)

      -- D43's texture-dot mechanism; PE2-D1's shapes (2026-09-08 owner ruling) replace the four
      -- Blizzard `Indicator-*` files, which had only four shapes between six states -- `blocked`,
      -- `off` and `unsaved` were byte-identical, so the legend named a distinction the screen did
      -- not draw. Shape AND colour now: five shipped textures, and `blocked`/`wrong` deliberately
      -- share the cross and differ only in the colour they paint the sentence.
      it("gives every state its own shipped texture, and every grey state a different one", function()
        local expectFile = {
          firing = "mark_firing", waiting = "mark_waiting", blocked = "mark_blocked",
          off = "mark_off", unsaved = "mark_unsaved", wrong = "mark_wrong",
        }
        for markState, file in pairs(expectFile) do
          local look = Rotation.MARKS[markState]
          assert.equal("|TInterface\\AddOns\\Elmira\\media\\" .. file .. ":12|t", look.mark, markState)
          assert.is_truthy(look.desc and #look.desc > 0, markState .. " has no tooltip sentence")
        end
        assert.are_not.equal(Rotation.MARKS.blocked.mark, Rotation.MARKS.off.mark)
        assert.are_not.equal(Rotation.MARKS.off.mark, Rotation.MARKS.unsaved.mark)
        assert.are_not.equal(Rotation.MARKS.blocked.colour, Rotation.MARKS.wrong.colour)
      end)

      it("answers nothing, not an error, when there is no rotation at all", function()
        ns.Display.activeBuild = function() return nil, nil, "no pack" end
        assert.same({}, Rotation.rowStatuses())
      end)
    end)

    -- R3 (D87): the panel header's own three-state dot, re-bucketed from the SAME evaluation the
    -- queue already runs (`rowStatuses`), plus the one thing that evaluation cannot know about
    -- itself: whether a dynamic condition can EVER become true given the lines that exist.
    describe("the panel header's three-state dot (D87)", function()
      it("reads nil (the green everything's-fine mark) once a static gate and a dynamic one both pass", function()
        queue = queueOf(1)
        assert.is_nil(Rotation.lineState(1))
      end)

      it("reads nil, not an error, for a line that does not exist", function()
        queue = queueOf(1)
        assert.is_nil(Rotation.lineState(99))
      end)

      it("reads grey for a static gate this character fails, and renders the grey dot", function()
        queue = queueOf(1)
        assert.equal("grey", Rotation.lineState(2)) -- DIVINE_STORM's bonus gate: character lacks it
        assert.is_truthy(builder().list.args.r2.args.status.name
          :find("|TInterface\\AddOns\\Elmira\\media\\mark_blocked:12|t", 1, true))
      end)

      -- Grey covers several states and they are NOT the same news: a line the player switched off
      -- is grey because they said so, and a line their character cannot run is grey because of
      -- their gear. The blocked cross on a line you turned off yourself sends you looking for a
      -- rune you already have.
      it("draws a line you switched off with the off mark, not the blocked cross", function()
        assert.is_true(Rotation.setRowDisabled(1, true))
        assert.is_true(Rotation.save())
        queue = queueOf(2)
        assert.equal("grey", Rotation.lineState(1))
        local status = builder().list.args.r1.args.status
        assert.equal(Rotation.MARKS.off.mark, status.name)
        assert.are_not.equal(Rotation.MARKS.blocked.mark, status.name)
      end)

      it("reads amber for a dynamic condition that is merely not true yet, and renders the amber dot", function()
        Rotation.addCondition(3, "buff")
        Rotation.setCondition(3, 1, "key", "VENGEANCE_BUFF") -- not up on the fake state
        assert.is_true(Rotation.save())
        queue = queueOf(1)
        assert.equal("amber", Rotation.lineState(3))
        assert.is_truthy(builder().list.args.r3.args.status.name
          :find("|TInterface\\AddOns\\Elmira\\media\\mark_waiting:12|t", 1, true))
      end)

      -- The literal D87 example: a `seal` condition naming a seal no line of the build casts any
      -- more. Structural (Core/Diagnostics.deadSeal), not a second live-evaluation path.
      it("reads red for a condition that can never become true as the rotation stands", function()
        Rotation.addCondition(3, "seal")
        Rotation.setCondition(3, 1, "key", "SEAL_OF_TESTING") -- no entry anywhere casts this seal
        assert.is_true(Rotation.save())
        queue = queueOf(1)
        assert.equal("red", Rotation.lineState(3))
        local mark = builder().list.args.r3.args.status
        assert.is_truthy(mark.name:find("|TInterface\\AddOns\\Elmira\\media\\mark_wrong:12|t", 1, true))
        assert.equal("|cff" .. ns.Colors.BAD.hex, Rotation.MARKS.wrong.colour)

        -- The SAME seal, once a line actually casts it, is merely a dynamic wait -- amber, not red.
        Rotation.appendSpell("SEAL_OF_TESTING")
        assert.is_true(Rotation.save())
        queue = queueOf(1)
        assert.equal("amber", Rotation.lineState(3))
      end)

      -- D1 (review of 65896ad, fix first): the same seal, NEGATED, is trivially true
      -- whenever nothing casts it -- an always-firing line, not a broken one -- so it must not read
      -- red even though nothing in the build casts the named seal.
      it("does not read red for a dead seal condition sitting under 'not'", function()
        Rotation.addCondition(3, "seal")
        Rotation.setCondition(3, 1, "key", "SEAL_OF_TESTING") -- still no entry casts this seal
        Rotation.setCondition(3, 1, "negated", true)
        assert.is_true(Rotation.save())
        queue = queueOf(1)
        assert.are_not.equal("red", Rotation.lineState(3))
      end)

      it("counts only red lines as needing attention, in the page's own header", function()
        assert.equal(0, Rotation.attentionCount())
        assert.is_nil(builder().attention)

        Rotation.addCondition(3, "seal")
        Rotation.setCondition(3, 1, "key", "SEAL_OF_TESTING")
        assert.is_true(Rotation.save())
        queue = queueOf(1)
        assert.equal(1, Rotation.attentionCount())
        assert.is_truthy(builder().attention.name:find("1 line needs attention", 1, true))

        -- A second dead condition, on a different line -- the plural wording, not "1 line" twice.
        -- Line 2 already carries a `bonus` condition at row 1; this is the new row 2.
        Rotation.addCondition(2, "seal")
        Rotation.setCondition(2, 2, "key", "SEAL_OF_TESTING")
        assert.is_true(Rotation.save())
        assert.equal(2, Rotation.attentionCount())
        assert.is_truthy(builder().attention.name:find("2 lines need attention", 1, true))
      end)
    end)

    -- R3 (D85): one vocabulary. The header sentence folds a condition through the SAME
    -- `Conditions.describe` the read-only template page's row summary already uses -- proving the
    -- two can never say the same rule in two different words.
    describe("the header sentence (D85)", function()
      it("matches the wording the read-only page already uses for the same condition", function()
        local entry = Rotation.draft().entries[1]
        local sentence = Rotation.headerSentence(entry)
        -- `Rotation.conditionSummary` is exactly what the read-only "Rotation, top to bottom" page
        -- shows under this same line (`lineRowsArgs`/`row.summary`) -- one call, so there is nowhere
        -- for the two pages to say the same rule in different words.
        local wordsAlone = Rotation.conditionSummary(entry)
        assert.is_truthy(sentence:find(wordsAlone, 1, true))
      end)

      -- PE2-D2.3/D2.4 (2026-09-08 owner ruling): the CONDITION and nothing else. The ability name
      -- came from the dropdown immediately above the sentence, and "when the above is not
      -- applicable" restated priority ordering the page already explains once at the top. Dropping
      -- the verb settles D2.4 at the same time -- a trinket line can no longer read "is cast".
      it("is the condition alone, with no ability name, no verb and no priority restatement", function()
        local sentence = Rotation.headerSentence(
          { spell = "EXORCISM", when = Rotation.draft().entries[1].when })
        assert.equal("mana at least 40%", sentence)
        assert.is_nil(sentence:find("EXORCISM", 1, true))
        assert.is_nil(sentence:find("is cast", 1, true))
        assert.is_nil(sentence:find("not applicable", 1, true))
      end)

      -- A line with no conditions renders NOTHING: an empty full-width description still reserves a
      -- blank row, so the panel must leave the whole control out.
      it("says nothing at all for a line with no conditions, wherever it sits", function()
        assert.equal("", Rotation.headerSentence({ spell = "JUDGEMENT" }))
        assert.is_nil(builder().list.args.r3.args.sentence,
          "an empty sentence still reserves a row")
      end)

      -- PE3-D5 (2026-09-08 owner ruling, in-game): the trinket line's sentence said "the item in
      -- slot 13 is ready" while the slot dropdown two controls away said "Trinket 1". This is the
      -- CALL SITE half of that fix -- Core can name a slot only if the panel hands it a namer, and
      -- a namer nothing passes is the shape of defect this repo keeps shipping.
      it("names the trinket slot in an item line's sentence rather than numbering it", function()
        local sentence = Rotation.headerSentence({ item = 13, when = { { "item_ready", 13 } } })
        assert.equal("Trinket 1 is off cooldown", sentence)
        assert.is_nil(sentence:find("slot 13", 1, true), "the raw inventory slot number is back")
      end)

      it("says only that a switched-off line is switched off", function()
        assert.equal("Switched off.",
          Rotation.headerSentence({ spell = "EXORCISM", disabled = true }))
      end)

      -- Where the position USED to change the wording, it now cannot: the same entry reads the same
      -- whether it is line 1 or line 3.
      it("reads identically for the same conditions at any position", function()
        local entry = { spell = "EXORCISM", when = Rotation.draft().entries[1].when }
        assert.equal(Rotation.headerSentence(entry, 1), Rotation.headerSentence(entry, 3))
      end)

      it("names two conditions rather than trailing off into a colon", function()
        Rotation.addCondition(3, "in_combat")
        Rotation.addCondition(3, "not_moving")
        local sentence = Rotation.headerSentence(Rotation.draft().entries[3])
        assert.equal(Rotation.conditionSummary(Rotation.draft().entries[3]), sentence)
        assert.is_nil(sentence:find(":", 1, true))
      end)
    end)

    -- D88 (the owner's decision C, 2026-09-07). Never Display's real queue, never an announcement,
    -- never a bar glow -- only what the DRAFT would suggest, computed and thrown away.
    describe("the draft preview (D88)", function()
      before_each(function()
        helper.load("Elmira/Adapters/Interface.lua")
        helper.load("Elmira/Core/Engine.lua")
        helper.load("Elmira/Core/Simulation.lua")
        Rotation.draft() -- the module the preview reads its "is there a draft" answer from
      end)

      it("reflects an unsaved edit while Display.currentQueue() does not", function()
        queue = queueOf(1) -- the SAVED/live queue: EXORCISM first
        assert.is_truthy(Rotation.previewLines()[1]:find("1. EXORCISM", 1, true))

        -- JUDGEMENT (line 3) has no conditions at all, so moving it to the top of the DRAFT makes
        -- it the draft's own first suggestion -- unlike DIVINE_STORM, whose bonus gate this
        -- character fails, which would have left the preview unchanged and proved nothing.
        Rotation.moveRow(3, -1); Rotation.moveRow(2, -1)
        assert.equal("JUDGEMENT", Rotation.draft().entries[1].spell)
        assert.is_truthy(Rotation.previewLines()[1]:find("1. JUDGEMENT", 1, true))
        -- The live queue -- and the thing Display actually renders -- has not moved at all.
        assert.equal("EXORCISM", queue[1].spell)
        assert.same(queue, ns.Display.currentQueue())
      end)

      -- D79's own defect (an un-merged ctx silently passing every registry-only spell through
      -- unresolved) is exactly what an empty/missing ctx here would reintroduce: `Schema.compile`
      -- stores `entry.data = ctx.spells[entry.spell]` only when ctx actually carries the merged
      -- registry, and the live queue reads `data.id` etc back off it. `wordCtx()`, not `{}`.
      it("compiles the preview against wordCtx's merged spells registry, not an empty context", function()
        Rotation.moveRow(3, -1); Rotation.moveRow(2, -1) -- JUDGEMENT to the front, as above
        local queuePreview = Rotation.previewQueue()
        assert.equal("JUDGEMENT", queuePreview[1].spell)
        assert.equal(PACK.spells.JUDGEMENT.id, queuePreview[1].entry.data.id,
          "the compiled entry must carry the pack's own spell data, not a nil ctx.spells lookup")
      end)

      it("never calls Announce or Display.refresh while only previewing", function()
        local announced, repainted = 0, 0
        ns.Announce = { emit = function() announced = announced + 1 end }
        ns.Display.refresh = function() repainted = repainted + 1 end
        Rotation.moveRow(1, 1)
        Rotation.previewQueue()
        Rotation.previewLines()
        assert.equal(0, announced)
        assert.equal(0, repainted)
      end)

      it("shows the reason, not a blank box, when the draft does not compile", function()
        for _ = 1, 5 do Rotation.removeRow(1) end -- an empty build fails Schema.validate
        local queuePreview, reason = Rotation.previewQueue()
        assert.is_nil(queuePreview)
        -- The SPECIFIC reason `Schema.validate` gives, not merely "some string came back": the
        -- generic fallback text and this one are both non-nil, and only checking presence cannot
        -- tell them apart.
        assert.equal("entries must be a non-empty list", reason)
        assert.is_truthy(Rotation.previewLines()[1]:find(reason, 1, true))
      end)

      -- D94 (2026-09-07 in-game round): a half-built rotation fails to compile constantly while
      -- someone is editing -- that is the normal state -- and `Schema.compile` used to be called on
      -- every draft change, logging "build 'USER_TEST' failed validation" to chat two or three
      -- times per action. The preview must reach `Schema.validate` (which never logs) instead, and
      -- only fall through to `Schema.compile` once validation has already passed.
      it("never logs while showing the reason for a draft that does not validate", function()
        local logged = {}
        ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
        for _ = 1, 5 do Rotation.removeRow(1) end -- an empty build fails Schema.validate
        local queuePreview, reason = Rotation.previewQueue()
        assert.is_nil(queuePreview)
        assert.is_truthy(reason, "the preview must still explain itself")
        assert.same({}, logged, "Schema.compile must not run (and log) on an invalid draft")
      end)

      it("answers the generic reason when there is no draft to compile at all", function()
        Rotation.discard()
        local queuePreview, reason = Rotation.previewQueue()
        assert.is_nil(queuePreview)
        assert.equal("This draft does not compile.", reason)
      end)

      it("shows the reason when the simulation itself fails, rather than erroring", function()
        Rotation.moveRow(1, 1)
        ns.Simulation.queue = function() error("boom") end
        local queuePreview, reason = Rotation.previewQueue()
        assert.is_nil(queuePreview)
        assert.equal("This draft could not be simulated.", reason)
      end)

      it("carries the spell's icon in the preview line, the same way the live mirror does", function()
        ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
        assert.is_truthy(Rotation.previewLines()[1]:find("|Ttex:ex:0|t", 1, true))
      end)

      -- A compiling draft that simply has nothing left ENABLED is a different case from one that
      -- fails to compile at all: still no blank box, but the words are "nothing", not an error.
      it("says nothing would be suggested, rather than an empty box, once every line is off", function()
        for i = 1, #Rotation.draft().entries do Rotation.setRowDisabled(i, true) end
        local queuePreview, reason = Rotation.previewQueue()
        assert.same({}, queuePreview)
        assert.is_nil(reason)
        assert.is_truthy(Rotation.previewLines()[1]:find("nothing would be suggested", 1, true))
      end)

      it("is absent from the panel entirely when there is no draft to preview", function()
        ns.Display.activeBuild = function()
          return ns.Schema.compile(PACK.builds.TEMPLATE, packTables()), "TEMPLATE", "pinned"
        end
        Rotation.draft() -- re-reads the (now different) active rotation, exactly as opening the panel would
        assert.same({}, Rotation.previewLines())
        assert.is_nil(builder().preview)
      end)

      -- PE2-D4.3 (2026-09-08 owner ruling): only while the draft is actually DIRTY. Headed
      -- "(unsaved)" beside a status line reading "saved", restating the five spells "Right now" had
      -- just listed, it was three ways of saying one thing and one of them was untrue.
      it("stays hidden while the draft is clean, however much there is to preview", function()
        queue = queueOf(1)
        assert.is_false(Rotation.draft().dirty)
        assert.is_nil(builder().preview)
      end)

      it("is present, above the intro, once the draft has unsaved changes", function()
        queue = queueOf(1)
        Rotation.appendSpell("CONSECRATION")
        assert.is_true(Rotation.draft().dirty)
        local preview = builder().preview
        assert.equal("group", preview.type)
        assert.equal(2, preview.order)
        assert.equal("Preview (unsaved)", preview.name)
        assert.is_truthy(preview.args.v1)
      end)
    end)

    describe("the queue mirror", function()
      -- PE2-D4.1 (2026-09-08 owner ruling): NO ordinals. `1. 2. 3.` sat directly above a numbered
      -- rotation list whose numbers mean something else entirely, and the owner read "5.
      -- Consecration" against rotation line 11 and concluded the data was broken.
      -- PE3-D1: the separator is the `mark_next` TEXTURE, never U+2192 -- the arrow shipped as an
      -- empty box on the owner's client, the same way the pre-texture status dots did.
      it("joins the queue with the chevron texture and no slot numbers, and says the state behind it", function()
        queue = queueOf(1, 3)
        ns.Display.spellIcon = function(key) return key == "EXORCISM" and "tex:ex" or nil end
        local lines = Rotation.mirrorLines()
        assert.is_truthy(lines[1]:find("EXORCISM", 1, true))
        assert.is_truthy(lines[1]:find("JUDGEMENT", 1, true))
        assert.is_truthy(lines[1]:find("|TInterface\\AddOns\\Elmira\\media\\mark_next:12|t", 1, true),
          "the separator is a font glyph again, which this client draws as an empty box")
        assert.is_nil(lines[1]:find("\226\134\146", 1, true), "U+2192 is back in a user-facing string")
        assert.is_nil(lines[1]:find("1. ", 1, true), "the slot ordinals are back")
        assert.is_nil(lines[1]:find("2. ", 1, true), "the slot ordinals are back")
        assert.is_truthy(lines[1]:find("|Ttex:ex:0|t", 1, true))
        assert.is_truthy(lines[2]:find("target: yes", 1, true))
        assert.is_truthy(lines[2]:find("mana 100%", 1, true))
        -- PE4-D2: a blank line separates the queue and its context from the key to the symbols,
        -- and the "Status is as of the last time the queue changed." caveat is gone entirely --
        -- a permanent line in the most-read panel on the page that hedged about refresh timing and
        -- that the owner had to ask the meaning of.
        assert.equal(" ", lines[3], "the queue and the legend run together as one paragraph again")
        -- PE2-D1: six states, and the legend names every one of them. Asserted whole, because a
        -- legend that lists five of six is exactly the panel telling the player the sixth mark
        -- means something it does not.
        assert.equal(string.format(
          "%s firing now   %s waiting   %s not active for you   %s off   %s unsaved   %s needs fixing",
          Rotation.MARKS.firing.mark, Rotation.MARKS.waiting.mark, Rotation.MARKS.blocked.mark,
          Rotation.MARKS.off.mark, Rotation.MARKS.unsaved.mark,
          Rotation.MARKS.wrong.mark .. Rotation.MARKS.wrong.colour), lines[4],
          "the legend no longer explains the markers")
        assert.equal(4, #lines, "an extra line is back in the queue mirror")
        assert.is_nil(table.concat(lines, " "):find("last time the queue changed", 1, true))
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
        local seen, orders = 0, {}
        for key, node in pairs(args) do
          local at = path .. "." .. key
          seen = seen + 1
          assert.is_table(node, at)
          local check = WIDGETS[node.type]
          assert.is_truthy(check, at .. " has type " .. tostring(node.type))
          assert.equal("number", type(node.order), at .. " has no order")
          -- Every `a = a + 1` in the panel/body builders exists ONLY to keep this true: two
          -- siblings sharing an order is what an AceConfig group draws in an arbitrary, unstable
          -- sequence.
          assert.is_nil(orders[node.order], at .. " shares an order with " .. tostring(orders[node.order]))
          orders[node.order] = at
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
      -- PE2-D2.1: Top and Bottom join Up and Down, the four ItemRack and Rotation Master both
      -- ship together. Each says which way it goes, because "Top" and "Up" one beside the other
      -- are a pair a player has to be told apart.
      it("wires Top and Bottom to the ends of the list, and says which is which", function()
        local function order()
          local out = {}
          for i, row in ipairs(Rotation.listRows()) do out[i] = row.spell or ("item" .. row.item) end
          return out
        end
        local was = order()
        local args = builder().list.args
        assert.equal("Moves this line to the top of the rotation.", args.r3.args.top.desc)
        assert.equal("Moves this line one place up the rotation.", args.r3.args.up.desc)
        assert.equal("Moves this line one place down the rotation.", args.r3.args.down.desc)
        assert.equal("Moves this line to the bottom of the rotation.", args.r3.args.bottom.desc)

        args.r3.args.top.func()
        assert.equal(was[3], order()[1])

        Rotation.discard()
        builder().list.args.r2.args.bottom.func()
        local now = order()
        assert.equal(was[2], now[#now], "Bottom did not reach the end of the list")
        assert.equal(#was, #now)
      end)

      it("explains every control whose effect is not obvious from its label", function()
        local args = builder()
        -- Collapsed: the tooltip says what expanding it does.
        assert.is_truthy(args.list.args.r1.args.expand.desc:find("conditions", 1, true))
        Rotation.selectRow(1)
        args = builder()
        -- Expanded: the SAME button now says what clicking it again does.
        assert.is_truthy(args.list.args.r1.args.expand.desc:find("Collapse", 1, true))
        -- PE2-D1: the state's own sentence rides on the expander, the one control on the row that
        -- can show a tooltip at all -- a `description` becomes an AceGUI Label, which never fires
        -- OnEnter, so the mark beside it has nowhere to explain itself.
        local mark = args.list.args.r1.args.status
        local expand = args.list.args.r1.args.expand.desc
        assert.is_truthy(expand:find(mark.name, 1, true),
          "the row's own mark is not on the one control that can explain it")
        assert.is_truthy(expand:find(mark.desc, 1, true),
          "the mark is shown with no sentence saying what it means")
        assert.is_truthy(args.list.args.r1.args.remove.desc:find("Discard", 1, true))
        assert.is_truthy(args.spells.args.s1.desc:find("bottom of the draft", 1, true))
        assert.is_truthy(args.items.args.i1.desc:find("bottom of the draft", 1, true))
        assert.is_truthy(args.editing.args.save.desc:find("repaints", 1, true))
        assert.is_truthy(args.editing.args.discard.desc:find("saved rotation", 1, true))
        local body = args.list.args.r1.args.body.args
        assert.is_truthy(body.add.desc:find("change the exact field", 1, true))
        assert.is_truthy(body.conditions.args.c1.args.negated.desc:find("NOT", 1, true))
      end)

      -- PE2-D2.1 (2026-09-08 owner ruling): the reorder tools were 0.25/0.25/0.4, which AceGUI drew
      -- as `...`, `...`, `Remo...` -- controls that worked and that nobody could read. `width` is a
      -- multiple of 170px (AceConfigDialog-3.0.lua:49), so a label needs its own share of the row.
      -- Five tools plus the ability dropdown cannot fit one flow row inside the 960px window, so the
      -- budget is asserted per ROW: identity + dropdown first, then the tool block below it.
      it("names every tool in full, and sizes each row so it does not wrap", function()
        Rotation.selectRow(1)
        local row = builder().list.args.r1.args
        assert.equal("Top", row.top.name)
        assert.equal("Up", row.up.name)
        assert.equal("Down", row.down.name)
        assert.equal("Bottom", row.bottom.name)
        assert.equal("Remove", row.remove.name)
        for _, key in ipairs({ "top", "up", "down", "bottom", "remove" }) do
          assert.is_true(row[key].width >= 0.4,
            key .. " is " .. row[key].width .. " wide, which truncates its label")
        end

        local identity = row.expand.width + row.num.width + row.status.width + row.spell.width
        local tools = row.top.width + row.up.width + row.down.width
                    + row.bottom.width + row.remove.width
        assert.is_true(identity < 3.0, "the identity row sums to " .. identity .. " and would wrap")
        assert.is_true(tools < 3.0, "the tool row sums to " .. tools .. " and would wrap")

        local body = row.body.args
        assert.equal("On", body.on.name)
        assert.equal(1, body.on.order)
        assert.is_truthy(body.on.desc:find("Discard", 1, true))
        local pane = body.conditions.args.c1.args
        assert.equal("Category", pane.category.name)
        assert.equal("Field", pane.field.name)
        assert.equal("not", pane.negated.name)
        assert.equal("Remove", pane.remove.name)
        assert.equal("Test", pane.op.name)
        assert.equal("Value", pane.key.name)
        assert.equal("seconds", body.conditions.args.c1.args.amount.name ~= nil
                                 and "seconds" or "")
      end)

      it("labels a spell key with its readable name and a plain value with itself", function()
        ns.BarGlow = { spellName = function(id) return id == 7 and "Vengeance" or nil end }
        Rotation.addCondition(3, "buff")
        local body = function() return builder().list.args.r3.args.body.args end
        local values = body().conditions.args.c1.args.key.values
        assert.equal("Vengeance", values.VENGEANCE_BUFF)
        assert.equal("EXORCISM", values.EXORCISM, "no client name: the key is its own label")
        Rotation.setCondition(3, 1, "kind", "mode")
        local modes = body().conditions.args.c1.args.key.values
        assert.equal("AoE", modes.AoE, "a mode IS its own label")
      end)

      -- PE3-D3 (2026-09-08 owner ruling, in-game): the Value dropdown listed
      -- `CRUSADER_STRIKE_150`, `HOLY_POWER_CONSUME_HOLY`, `JUDICATOR_SOUL` -- the same defect class
      -- as the "HOLY_SHOCK known" requirement rows PE1-D6 fixed one file over. The words already
      -- exist in the class data: a bonus's `note`, a set's `name`, a soul's `short`.
      it("labels a set-bonus key with the bonus's own sentence, never the raw key", function()
        Rotation.selectRow(2)
        local key = builder().list.args.r2.args.body.args.conditions.args.c1.args.key
        assert.equal("Divine Storm consumes Holy Power", key.values.HOLY_POWER_CONSUME)
        assert.equal("Holy Wrath is instant", key.values.HOLY_WRATH_INSTANT)
        for id, label in pairs(key.values) do
          assert.not_equal(id, label, "a raw programmatic key is back in the dropdown")
        end
      end)

      -- The owner's words: it must say which set bonus, or the shoulder soul enchant BY NAME --
      -- a soul is something a player can go and put on their shoulders. Both, when a bonus has both.
      it("names both of a bonus's sources in the dropdown's tooltip, the soul by its enchant name",
         function()
        Rotation.selectRow(2)
        local key = builder().list.args.r2.args.body.args.conditions.args.c1.args.key
        local text = key.desc()
        assert.is_truthy(text:find("Inquisition Shockplate (T3.5)", 1, true),
          "the set the bonus comes from is not named")
        assert.is_truthy(text:find("4 pieces", 1, true))
        assert.is_truthy(text:find("Soul of the Exile", 1, true),
          "the soul is named as a shoulder enchant, never as SOUL_OF_THE_EXILE")
        assert.is_truthy(text:find("shoulder enchant", 1, true))
        assert.is_nil(text:find("SOUL_OF_THE_EXILE", 1, true))
      end)

      -- The other two sources with words of their own in the class data. A set has a `name` and a
      -- soul has the `short` its shoulder enchant is spelled with -- neither is the key, and the
      -- key is what a player would have to go and look up.
      it("labels a set key with the set's own name and a soul key with its enchant name", function()
        Rotation.addCondition(3, "set")
        local key = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.equal("Inquisition Shockplate (T3.5)", key.values.PALADIN_T35_INQUISITION)
        assert.is_nil(key.values.PALADIN_T35_INQUISITION:find("PALADIN_T35", 1, true))

        Rotation.setCondition(3, 1, "kind", "enchant")
        local soul = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.equal("Soul of the Exile", soul.values.SOUL_OF_THE_EXILE)
      end)

      -- A soul the pack records with no `short` still has to be named. The prettifier is the
      -- fallback, never the raw key.
      it("prettifies a soul the pack gives no enchant name for", function()
        PACK.souls.SOUL_OF_THE_NOBODY = {}
        ns.Detect = { readableName = function(k) return "READABLE:" .. k end }
        Rotation.addCondition(3, "enchant")
        local key = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.equal("READABLE:SOUL_OF_THE_NOBODY", key.values.SOUL_OF_THE_NOBODY)
      end)

      -- Only a key that is WRITTEN like one gets prettified: a mode, a weapon kind and a creature
      -- type are already display words, and the prettifier lower-cases before it re-capitalises, so
      -- it would answer "Aoe" for the first of them.
      it("prettifies a programmatic key and leaves a display word alone", function()
        ns.Detect = { readableName = function(k) return "READABLE:" .. k end }
        Rotation.addCondition(3, "resource")
        local power = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.equal("READABLE:MANA", power.values.MANA)

        Rotation.setCondition(3, 1, "kind", "mode")
        local modes = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.equal("AoE", modes.values.AoE, "a mode IS its own label")
      end)

      -- Core/Detect is a different file and may not be loaded at all (the panel is built before it
      -- on a fresh login). The key itself is a worse label and a far better answer than nothing.
      it("falls back to the key itself with no prettifier loaded", function()
        ns.Detect = nil
        Rotation.addCondition(3, "resource")
        local power = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.equal("MANA", power.values.MANA)
      end)

      -- Nothing to say is said as nothing: a spell-shaped key would otherwise grow a tooltip line
      -- that only repeats the label already on the control.
      it("gives a spell key no source tooltip at all", function()
        Rotation.addCondition(3, "buff")
        local key = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.is_nil(key.desc())
      end)

      -- The source tooltip answers for two sources and no others. Everything else keeps an empty
      -- tooltip rather than growing one from whatever happens to sit under the same key elsewhere
      -- in the pack -- set and bonus keys are routinely named after one another.
      it("says nothing about a source it does not speak for", function()
        PACK.bonuses.PALADIN_T35_INQUISITION = { note = "a bonus named after the set",
                                                 from = { { set = "PALADIN_T35_INQUISITION",
                                                            pieces = 4 } } }
        Rotation.addCondition(3, "set")
        Rotation.setCondition(3, 1, "key", "PALADIN_T35_INQUISITION")
        local key = builder().list.args.r3.args.body.args.conditions.args.c1.args.key
        assert.is_nil(key.desc(), "a set row grew the tooltip of the bonus of the same name")
      end)

      it("names a soul source by its enchant, and says nothing before one is chosen", function()
        Rotation.addCondition(3, "enchant")
        local function desc()
          return builder().list.args.r3.args.body.args.conditions.args.c1.args.key.desc()
        end
        Rotation.setCondition(3, 1, "key", "SOUL_OF_THE_EXILE")
        local text = desc()
        assert.is_truthy(text:find("Soul of the Exile", 1, true))
        assert.is_truthy(text:find("a shoulder enchant", 1, true))
        assert.is_nil(text:find("SOUL_OF_THE_EXILE", 1, true))
        -- A saved line naming a soul this pack no longer records -- a pack update, or a build
        -- imported from another one. There is nothing to say about it, so nothing is said.
        PACK.souls.SOUL_OF_THE_EXILE = nil
        assert.is_nil(desc(), "a soul the pack does not record grew a tooltip anyway")
      end)

      -- A bonus with no `from` at all, and one whose `from` names neither a set nor a soul: there
      -- is nothing to say, so nothing is said. A "From:" with an empty list after it would be the
      -- panel promising an answer it does not have.
      it("says nothing for a bonus with no source to name", function()
        Rotation.selectRow(2)
        local function desc(key)
          Rotation.setCondition(2, 1, "key", key)
          return builder().list.args.r2.args.body.args.conditions.args.c1.args.key.desc()
        end
        assert.is_nil(desc("HOLY_WRATH_INSTANT"), "a bonus with no `from` grew a source line")
        PACK.bonuses.MYSTERY = { note = "something", from = { { nothing = true } } }
        assert.is_nil(desc("MYSTERY"))
      end)

      -- PE3-D4: the Value dropdown takes a row of its own. At 1.1 widths it landed at the end of a
      -- row of label-less controls and its own "Value" label drew on top of the Field dropdown of
      -- the row above -- and a bonus's label is now a whole sentence, which needs the width.
      it("gives the Value dropdown its own full-width row", function()
        Rotation.selectRow(2)
        local key = builder().list.args.r2.args.body.args.conditions.args.c1.args.key
        assert.equal("full", key.width, "the Value label can overlap the Field dropdown again")
      end)

      it("names each inventory slot in the slot dropdown", function()
        Rotation.selectRow(5)
        local slots = builder().list.args.r5.args.body.args.conditions.args.c1.args.slot.values
        assert.equal("Trinket 1", slots["13"])
        assert.equal("Head", slots["1"])
      end)

      it("offers only the two ways a line can combine its conditions", function()
        Rotation.selectRow(1)
        local body = builder().list.args.r1.args.body.args
        assert.same({ all = "every condition passes", any = "any condition passes" },
                    body.match.values)
        -- The add dropdown is a menu of CATEGORIES whose values are the first field of each, so
        -- picking one always produces a legal condition.
        local adds = body.add.values
        assert.equal("Encounter", adds.enemies)
        assert.equal("Combat state", adds.in_combat)
        assert.is_nil(body.add.get())
      end)

      it("marks which line's body is expanded, in the header sentence", function()
        Rotation.selectRow(2)
        local args = builder().list.args
        assert.is_truthy(args.r2.args.sentence.name:find("|cffC08CF0>|r", 1, true))
        assert.is_nil(args.r1.args.sentence.name:find("|cffC08CF0>|r", 1, true))
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
        Rotation.addCondition(6, "in_combat")
        -- Line 1 is `mana >= 40`; give the new line that gate as well, plus one more.
        Rotation.setCondition(6, 1, "kind", "resource")
        Rotation.setCondition(6, 1, "op", "minPct")
        Rotation.setCondition(6, 1, "value", 40)
        Rotation.setCondition(6, 1, "key", "MANA")
        Rotation.addCondition(6, "in_combat")
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

    -- F1 (2026-09-07 bug round): a paladin fork copied as "My-Shock" showed up on the owner's mage.
    -- Root cause was `UserBuilds.find`/`list` treating a nil pack as "skip the class filter", not
    -- this function -- but the old stopgap here ("no pack, refuse everything") happened to also
    -- pass this exact scenario for the wrong reason, so it is replaced with the real ones below,
    -- through the REAL `UserBuilds.find` rather than a fake that no longer represents its contract.
    it("refuses a fork of a different class, even with no data pack of its own (F1a)", function()
      install()
      ns.Display.currentPack = function() return nil end
      ns.db.keys = { class = "MAGE", char = "Mage - Realm" }
      ns.db.global = { userBuilds = { USER_MINE = {
        build = { key = "USER_MINE", entries = {} }, class = "PALADIN", name = "Mine" } } }
      installUserBuilds{} -- the real find(), which is exactly what F1a fixed
      local ok, why = Rotation.use("USER_MINE")
      assert.is_false(ok)
      assert.truthy(why:find("unknown build", 1, true))
    end)

    -- F1c: `UserBuilds.create`'s class fix is dead without this -- a class with no shipped pack
    -- must be able to USE the rotation it just created, not merely have `create` accept it.
    it("pins a rotation of the player's own class even with no data pack at all (F1c)", function()
      install()
      ns.Display.currentPack = function() return nil end
      ns.db.keys = { class = "MAGE", char = "Mage - Realm" }
      ns.db.global = { userBuilds = { USER_MINE = {
        build = { key = "USER_MINE", entries = {} }, class = "MAGE", name = "Mine" } } }
      installUserBuilds{}
      assert.is_true(Rotation.use("USER_MINE"))
      assert.equal("USER_MINE", ns.db.profile.activeBuild)
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
      -- D64 (priority fix, 2026-09-07 in-game): the shape `harness()` above actually has --
      -- `frame.editBox`/`frame.button1` as convenience fields on the dialog -- is NOT what a real
      -- StaticPopup exposes. Verified live: `/run print(StaticPopup1EditBox, StaticPopup1Button1,
      -- StaticPopup1.button1)` answered two real widgets and a `nil`. Every D61-D67 spec above this
      -- point passed against a fake that answered our own assumption back to us. This harness has
      -- NO such fields at all -- only NAME-ADDRESSED GLOBALS, exactly like the client -- so a
      -- `.editBox`/`.button1` read in the code under test is `nil` here unless it falls back to
      -- `_G[name .. suffix]`, which is the one thing this harness exists to prove.
      local globalNames
      local function harnessRealShape()
        local shown
        globalNames = {}
        local function newFrame(which)
          local frame = { which = which, strata = "DIALOG", level = 5 }
          function frame:GetName() return which end
          local editBox = { text = "" }
          function editBox:SetText(t) self.text = t or "" end
          function editBox:GetText() return self.text end
          function editBox:HighlightText() self.highlighted = true end
          function editBox:GetParent() return frame end
          local button1 = { Click = function()
            local dialog = _G.StaticPopupDialogs[frame.which]
            if dialog and dialog.OnAccept then dialog.OnAccept(frame, frame.data) end
          end }
          -- The real client's addressing: `StaticPopup1EditBox`, `StaticPopup1Button1` -- globals,
          -- never `frame.editBox`/`frame.button1`. Tracked in `globalNames` so `after_each` can undo
          -- exactly what this test added and nothing else.
          _G[which .. "EditBox"] = editBox
          _G[which .. "Button1"] = button1
          globalNames[#globalNames + 1] = which .. "EditBox"
          globalNames[#globalNames + 1] = which .. "Button1"
          function frame:SetFrameStrata(s) self.strata = s end
          function frame:GetFrameStrata() return self.strata end
          function frame:SetFrameLevel(l) self.level = l end
          function frame:GetFrameLevel() return self.level end
          local hideHooks = {}
          function frame:HookScript(event, fn)
            if event == "OnHide" then hideHooks[#hideHooks + 1] = fn end
          end
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
          _G[which .. "EditBox"]:SetText("") -- the same post-OnShow clear D61b answers
          return shown
        end
        return {
          shown = function() return shown end,
          editBox = function() return _G[shown.which .. "EditBox"] end,
          button1 = function() return _G[shown.which .. "Button1"] end,
          pressEnter = function()
            local dialog = _G.StaticPopupDialogs[shown.which]
            if dialog.EditBoxOnEnterPressed then
              dialog.EditBoxOnEnterPressed(_G[shown.which .. "EditBox"])
            end
          end,
          click = function() _G[shown.which .. "Button1"].Click() end,
          hide = function() shown:Hide() end,
        }
      end

      describe("D64: the real client shape (name-addressed globals, no convenience fields)", function()
        after_each(function()
          for _, name in ipairs(globalNames or {}) do _G[name] = nil end
        end)

        it("prefills and highlights the SAME edit box the client would actually show", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harnessRealShape()
          Rotation.openNewRotationPopup()
          assert.equal("My rotation", h.editBox():GetText())
          assert.is_true(h.editBox().highlighted)
        end)

        it("reads the typed name on Accept, rather than refusing an empty one", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harnessRealShape()
          Rotation.openNewRotationPopup()
          h.editBox():SetText("Real Client Name")
          -- A spy, not a real fork: what matters here is only whether OnAccept resolved the typed
          -- text at all, which is exactly the thing D61b's own field-shaped harness could not tell
          -- apart from "the box was always empty" (both read as an empty-name refusal).
          local seenName = "unset"
          local realCreate = Rotation.createAndUse
          Rotation.createAndUse = function(name) seenName = name; return true, "KEY" end
          h.click()
          Rotation.createAndUse = realCreate
          assert.equal("Real Client Name", seenName)
        end)

        it("accepts on Enter, through the same name-addressed button", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harnessRealShape()
          Rotation.openNewRotationPopup()
          h.editBox():SetText("Enter Name")
          local seenName = "unset"
          local realCreate = Rotation.createAndUse
          Rotation.createAndUse = function(name) seenName = name; return true, "KEY" end
          h.pressEnter()
          Rotation.createAndUse = realCreate
          assert.equal("Enter Name", seenName, "Enter must click the name-addressed button1, not a nil field")
        end)

        it("raises strata and level on the real frame, exactly as the field-shaped harness proved", function()
          install()
          installUserBuilds{ list = function() return {} end }
          local h = harnessRealShape()
          Rotation.openNewRotationPopup()
          assert.equal("FULLSCREEN_DIALOG", h.shown():GetFrameStrata())
          assert.is_true(h.shown():GetFrameLevel() > 100)
        end)
      end)

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

      -- `StaticPopup_Show` CAN answer nil even while it and the dialog table both exist (the real
      -- client does this for a dialog key it does not recognise) -- `raiseAbovePanel`/`prefillNow`
      -- must not error reaching into a dialog that never arrived.
      it("does not error when StaticPopup_Show itself answers nil", function()
        install()
        _G.StaticPopup_Show = function() return nil end
        assert.has_no.errors(function() assert.is_true(Rotation.openNewRotationPopup()) end)
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

      -- W1's `confirmThen`: the one popup every card-widget action with `confirm` set shows before
      -- running its own `func` (see Rotation.lua's own comment on `confirmThen` for why the card
      -- widget cannot lean on AceConfigDialog's internal confirm the way every OTHER page still
      -- does). `%s` because the text is per-action; `data.onAccept` is `confirmThen`'s own closure.
      describe("ELMIRA_CONFIRM", function()
        local dialog
        before_each(function() dialog = _G.StaticPopupDialogs.ELMIRA_CONFIRM end)

        it("says nothing of its own, with Confirm/Cancel buttons", function()
          assert.equal("%s", dialog.text)
          assert.equal("Confirm", dialog.button1)
          assert.equal("Cancel", dialog.button2)
          assert.is_nil(dialog.hasEditBox)
          assert.equal(0, dialog.timeout)
          assert.is_true(dialog.whileDead)
          assert.is_true(dialog.hideOnEscape)
        end)

        -- Single-arg style, matching ELMIRA_RENAME_ROTATION's own OnAccept tests above: `data`
        -- read off `self.data` when the caller passes none directly, the real StaticPopup shape
        -- (StaticPopup_OnClick hands the frame; `frame.data` is where `StaticPopup_Show`'s own
        -- 4th argument lands).
        it("runs the caller's onAccept when accepted", function()
          local ran
          dialog.OnAccept({ data = { onAccept = function() ran = true end } })
          assert.is_true(ran)
        end)

        it("does nothing when shown with no onAccept at all, rather than erroring", function()
          assert.has_no.errors(function() dialog.OnAccept({ data = {} }) end)
        end)

        -- The real StaticPopup sequence: `use.func()` shows the popup and does NOT switch yet;
        -- only the dialog's own accept, driven through the harness, runs the actual action.
        it("switches the rotation only once the popup is accepted, not when the action merely runs",
          function()
            installPack()
            ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
            ns.Display.activeBuild = function() return nil, nil end
            ns.Detect = { hasFailures = function() return true end }
            installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false,
              checks = { { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" } } } }
            local h = harness()
            cards().card1.arg.actions.use.func()
            assert.is_false(ns.db.profile.activeBuild)
            h.click()
            assert.equal("PALADIN_EXODIN", ns.db.profile.activeBuild)
          end)
      end)

      it("does not re-register ELMIRA_CONFIRM on a second load either", function()
        local first = _G.StaticPopupDialogs.ELMIRA_CONFIRM
        Rotation = helper.load("Elmira/Options/Rotation.lua")
        assert.equal(first, _G.StaticPopupDialogs.ELMIRA_CONFIRM)
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

    -- F1b (2026-09-07 bug round): the one plainly worded per-fork privacy toggle.
    describe("setPrivate()", function()
      it("sets through UserBuilds and notifies the tree", function()
        install()
        local set, notified = nil, 0
        ns.UserBuilds = { setPrivate = function(k, v) set = { k, v }; return true end }
        _G.LibStub = function() return { NotifyChange = function() notified = notified + 1 end } end
        local ok = Rotation.setPrivate("USER_MINE", true)
        _G.LibStub = nil
        assert.is_true(ok)
        assert.same({ "USER_MINE", true }, set)
        assert.equal(1, notified)
      end)

      it("reports failure without erroring when the module is absent", function()
        install()
        ns.UserBuilds = nil
        local ok, err = Rotation.setPrivate("USER_MINE", true)
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

    -- W1 (try/card-widget, 2026-09-07): the root card is now ONE control -- a `dialogControl`d
    -- `description`, at a RELATIVE width, its content handed through `arg` -- rather than an
    -- AceGUI inline group of its own (D69's shape, which AceConfigDialog-3.0.lua:1131-1142 forces
    -- full-width no matter what `width` says, and is exactly why three of them could never share a
    -- row). `relWidth`/`dialogControl` are what let the widget draw three across; asserted here as
    -- plain data, same as every other option in this file.
    it("hands the widget a relative width and its own dialogControl, so it can share a row",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local card = cards().card1
        assert.equal("description", card.type)
        assert.equal("ElmiraCard", card.dialogControl)
        assert.equal("relative", card.width)
        assert.equal(0.32, card.relWidth)
      end)

    it("titles the card with the playstyle name, an Open action, summary and pips",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "medium",
                         updated = "2026-08-01", summary = "Fast 2H.",
                         source = "https://www.wowhead.com/classic/guide/paladin",
                         recommended = true, fits = true } }
        local card = cards().card1
        -- The title IS the badge text the tree/D69 already used -- same string, new home (`arg`).
        assert.is_truthy(card.arg.title:find("Exodin", 1, true))
        assert.equal("Open", card.arg.actions.open.name)
        -- D69: the button no longer repeats the name the title already says.
        assert.is_falsy(card.arg.actions.open.name:find("Exodin", 1, true))
        assert.equal("Fast 2H.", card.arg.summary)
        -- PA6: difficulty is its own level/label field now (CardWidget.lua draws the pip TEXTURES;
        -- see PA6's own correction note above `DIFFICULTY_PIPS` -- a glyph string cannot render on
        -- this client). PE1-D2: the recommended/Unproven bits ride on that same line, muted, and
        -- the meta line is left empty.
        assert.equal(2, card.arg.difficultyLevel)
        assert.is_truthy(card.arg.difficultyLabel:find("Medium", 1, true))
        assert.is_truthy(card.arg.difficultyLabel:find("recommended", 1, true))
        assert.equal("", card.arg.meta)
        -- PA8: the exact date is no longer on the card face at all...
        assert.is_falsy(card.arg.difficultyLabel:find("2026%-08%-01"))
        -- ...it moved to the mouseover tooltip.
        assert.is_truthy(card.arg.tooltip:find("2026%-08%-01"))
        -- PA4: no separate source text line. PE1-D2: and no Copy link action either -- the detail
        -- panel's own Copy Source Link button is the only one left on the page.
        assert.is_nil(card.arg.source)
        assert.is_nil(card.arg.actions.link)
        -- This row IS the one running (top before_each's default activeBuild), so there is no Use
        -- action at all, and the card is flagged active.
        assert.is_nil(card.arg.actions.use)
        assert.is_true(card.arg.active)
      end)

    -- PE1-D2, the layout half stated as data: with a difficulty to fold onto, `meta` is EMPTY, and
    -- CardWidget.lua's own spec proves an empty `meta` reserves no row on the card.
    it("folds recommended and Unproven onto the difficulty line, leaving the meta line empty",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "easy",
                         recommended = true, experimental = true, fits = true } }
        local card = cards().card1
        assert.is_truthy(card.arg.difficultyLabel:find("Easy", 1, true))
        assert.is_truthy(card.arg.difficultyLabel:find("recommended", 1, true))
        assert.is_truthy(card.arg.difficultyLabel:find("Unproven", 1, true))
        assert.equal("", card.arg.meta)
      end)

    -- ...and the signal is never DROPPED to fit the layout: a catalog entry with no difficulty
    -- draws no pip line at all, so there is nothing to fold onto and the bits stay on `meta`.
    it("keeps the bits on the meta line when the row has no difficulty to fold them onto", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", recommended = true,
                       fits = true } }
      local card = cards().card1
      assert.is_nil(card.arg.difficultyLevel)
      assert.is_nil(card.arg.difficultyLabel)
      assert.is_truthy(card.arg.meta:find("recommended", 1, true))
    end)

    -- A plain difficulty with nothing to say beside it must not pick up a trailing separator.
    it("leaves the difficulty word alone when there is nothing to append to it", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "hard",
                       fits = true } }
      assert.equal("Hard", cards().card1.arg.difficultyLabel)
      assert.equal("", cards().card1.arg.meta)
    end)

    -- PA5 (2026-09-08, PROVISIONAL split): a playstyle name that IS "Name -- description" prose
    -- shows only the short name on the card, with the full prose in the tooltip.
    it("splits the playstyle at the em-dash for the card title, keeping the rest for the tooltip",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin — fast 2H, single seal (Ret)",
                         fits = true } }
        local card = cards().card1
        assert.equal("Exodin", card.arg.title)
        assert.is_truthy(card.arg.tooltip:find("Exodin — fast 2H, single seal (Ret)", 1, true))
      end)

    -- PA7: "experimental" used to conflate unproven-and-hard; it now carries only provenance.
    -- PB4: the wording itself claimed "no published guide", which the data disproves (every
    -- experimental entry ships a source) -- the neutral `L["Unproven"]` makes no claim either way.
    it("labels an experimental row as unproven, not the bare word 'experimental'",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", experimental = true,
                         fits = true } }
        -- No difficulty on this row, so the bits are still on `meta` (PE1-D2's own no-pips branch).
        local meta = cards().card1.arg.meta
        assert.is_truthy(meta:find("Unproven", 1, true))
        assert.is_falsy(meta:find("experimental", 1, true))
        assert.is_falsy(meta:find("guide", 1, true))
      end)

    -- PE1-D2: the phase came OFF the card -- after D1 the page header states it once, where six
    -- cards used to repeat it. Asserted against every string the card face carries, not just the
    -- meta line it used to live on.
    it("shows the catalog phase nowhere on the card any more", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", phase = "SoD P8",
                       difficulty = "easy", recommended = true, fits = true } }
      local card = cards().card1
      assert.is_falsy(card.arg.meta:find("SoD P8", 1, true))
      assert.is_falsy(card.arg.difficultyLabel:find("SoD P8", 1, true))
      assert.is_falsy(card.arg.title:find("SoD P8", 1, true))
      -- ...and it is on the page header instead.
      assert.is_truthy(Rotation.group().args.detection.name:find("SoD P8", 1, true))
    end)

    -- PA9: the card hands the widget a plain `unavailable` flag; D48's own "still gives it a page,
    -- muted" test above already proves the TITLE side, this proves the state flag CardWidget.lua's
    -- border keys off.
    it("flags an unavailable playstyle's card so the widget can dim it", function()
      installPack()
      ns.Display.activeBuild = function() return nil, nil end
      installWizard{ { build = "PALADIN_TWIST", playstyle = "Seal twisting", available = false,
                       fits = true } }
      local card = cards().card1
      assert.is_true(card.arg.unavailable)
      assert.is_falsy(card.arg.active)
    end)

    -- PD1-D5: `selected` is orthogonal to `active` -- the card widget's own persistent-brightening
    -- state (CardWidget.lua), never the gold "in use" border `active` already carries.
    it("flags the card last clicked as selected, and no other", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      Rotation.select("PALADIN_SHOCKADIN")
      local c = cards()
      assert.is_falsy(c.card1.arg.selected)
      assert.is_true(c.card2.arg.selected)
    end)

    -- The Label CreateControl falls back to when a `dialogControl` never registered
    -- (AceConfigDialog-3.0.lua:1093-1104, W1d) reads the option's own `name` -- so an install
    -- missing Options/CardWidget.lua must still show something readable, not an empty line.
    it("keeps a readable fallback `name`, for the Label AceConfig falls back to without the widget",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true,
                         summary = "Fast 2H." } }
        local card = cards().card1
        assert.is_truthy(card.name:find("Exodin", 1, true))
        assert.is_truthy(card.name:find("Fast 2H.", 1, true))
      end)

    -- PD1-D2 (2026-09-08): clicking Open used to navigate to the template's own page (D32) --
    -- it now SELECTS the rotation for the shared detail area instead, and never navigates at all.
    -- The tree page itself still exists this pass (PD2 deletes it later); the card body just no
    -- longer opens it.
    it("selects the rotation for the shared detail area, and never calls SelectGroup", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local selectGroupCalls = 0
      ns.Options = { dialog = { SelectGroup = function() selectGroupCalls = selectGroupCalls + 1 end,
                                 Open = function() end } }
      cards().card1.arg.actions.open.func()
      assert.equal("PALADIN_EXODIN", Rotation.selected())
      assert.equal(0, selectGroupCalls)
    end)

    -- PB5 (2026-09-08): `SelectGroup` alone only schedules a DEFERRED rebuild, which is why a card
    -- click used to land on the Builder instead of the clicked template -- every native AceConfig
    -- control (an execute button, a slider) gets a SYNCHRONOUS `AceConfigDialog:Open(appName)`
    -- refresh for free right after its own func runs (`ActivateControl`); the card body is a raw
    -- Frame click that never went through that machinery, so it never got one. The fix is that same
    -- bare, path-less `Open("Elmira")` call, made directly.
    it("also forces a synchronous refresh after SelectGroup, the same one native controls get for free",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local opened = {}
        ns.Options = { dialog = { SelectGroup = function() end,
                                   Open = function(_, ...) opened[#opened + 1] = { ... } end } }
        cards().card1.arg.actions.open.func()
        assert.equal(1, #opened, "the refresh must run exactly once per click, not zero and not twice")
        assert.same({ "Elmira" }, opened[1], "a BARE Open with no path -- a path replaces the whole root (D20)")
      end)

    -- PB5's own warned-against regression: `Options.Open()` with no path arguments forces
    -- `SelectGroup("Elmira", "general")` (D61e) -- routing the refresh through that wrapper instead
    -- of calling AceConfigDialog directly would send every card click to General.
    it("calls AceConfigDialog's own Open directly, never the Options.Open wrapper", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local wrapperCalled = false
      ns.Options = { dialog = { SelectGroup = function() end, Open = function() end },
                     Open = function() wrapperCalled = true end }
      cards().card1.arg.actions.open.func()
      assert.is_false(wrapperCalled)
    end)

    -- The refresh must not depend on `SelectGroup` having succeeded first -- exactly the shape
    -- `ActivateControl` uses (it always refreshes after a native control's func, unconditionally).
    it("still refreshes even on a dialog stand-in that offers no SelectGroup at all", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local opened = false
      ns.Options = { dialog = { Open = function() opened = true end } }
      assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
      assert.is_true(opened)
    end)

    -- No options window loaded at all (an install order this addon has to tolerate elsewhere too)
    -- must not error reaching into a `nil` dialog for either the select or the refresh.
    it("does not error when there is no options dialog to navigate at all", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      ns.Options = nil
      assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
    end)

    -- PE1-D3 -------------------------------------------------------------------------------------
    --
    -- At 1200px the shared detail area begins below two rows of cards and "Your rotations" -- off
    -- the bottom of the window -- so clicking a card looked like it did nothing and players never
    -- found the panel at all. Clicking one now scrolls the page the MINIMUM amount that brings the
    -- detail panel's header on screen, and does not move at all when it is already visible.
    describe("scrolling the detail panel's header into view (PE1-D3)", function()
      -- The arithmetic is a pure function, so it is tested with numbers rather than through frames.
      -- Every case below uses a 500px viewport over 1500px of content, which makes the range
      -- exactly 1000px and one scroll unit exactly one pixel -- so an asserted scroll value reads
      -- directly as "this many pixels", and "not one pixel further" is a literal claim.
      local function measure(over)
        local m = { scroll = 0, contentHeight = 1500, viewHeight = 500,
                    viewTop = 700, viewBottom = 200, detailTop = 600, headerHeight = 40 }
        for k, v in pairs(over or {}) do m[k] = v end
        return Rotation.detailScrollValue(m)
      end

      it("does not move when the header is already fully visible", function()
        assert.is_nil(measure{ detailTop = 600 })
      end)

      it("does not move when the header's bottom edge is exactly on the viewport's", function()
        assert.is_nil(measure{ detailTop = 240 }) -- header bottom 200 == viewBottom
      end)

      -- The whole point: enough to sit the header's bottom on the viewport's bottom edge, and no
      -- further. A "scroll the panel into view" or "centre it" implementation answers larger here.
      it("scrolls down exactly far enough to land the header on the bottom edge", function()
        assert.equal(120, measure{ detailTop = 120 }) -- header bottom 80, 120px below viewBottom
      end)

      it("scales the pixel distance by the page's own scrollable range", function()
        -- Half the range (500px over a 500px viewport) means one pixel costs two scroll units.
        assert.equal(240, measure{ detailTop = 120, contentHeight = 1000 })
      end)

      it("adds to the scroll value the page is already at, rather than replacing it", function()
        assert.equal(320, measure{ detailTop = 120, scroll = 200 })
      end)

      -- A page shorter than its own viewport is the branch SetScroll itself special-cases (it
      -- forces offset 0); there is nothing to scroll and asking for a value would divide by <= 0.
      it("does not move on a page that is shorter than its viewport", function()
        assert.is_nil(measure{ detailTop = 120, contentHeight = 400 })
      end)

      it("does not move on a page exactly as tall as its viewport", function()
        assert.is_nil(measure{ detailTop = 120, contentHeight = 500 })
      end)

      it("clamps at the top of the scroll range", function()
        assert.equal(1000, measure{ detailTop = 100, scroll = 950 })
      end)

      -- Scrolled past a tall detail panel: its header is now ABOVE the viewport, and the minimum
      -- move is back up to the top edge.
      it("scrolls back up when the header has gone off the top", function()
        assert.equal(400, measure{ detailTop = 800, scroll = 500 })
      end)

      it("clamps at the bottom of the scroll range", function()
        assert.equal(0, measure{ detailTop = 900, scroll = 30 })
      end)

      -- The frame-walking glue. Stand-ins for the AceGUI widget tree AceConfigDialog builds: a
      -- Frame holding a TreeGroup holding the page's single ScrollFrame (AceConfigDialog-3.0.lua:
      -- 1635-1646), whose last child is `args.detail` and whose own first child is its header row.
      -- `pairs` skips a nil value, so a test that wants a field ABSENT (an unlaid-out frame answers
      -- nil to GetTop) says so with this sentinel rather than with `= nil`, which would silently
      -- leave the default in place and make the test vacuous.
      local UNSET = {}
      local function harness(over)
        local o = { scrollvalue = 0, contentHeight = 1500, viewHeight = 500, viewTop = 700,
                    viewBottom = 200, detailTop = 600, headerBottom = 560 }
        for k, v in pairs(over or {}) do o[k] = (v ~= UNSET) and v or nil end
        local function frame(top, bottom, height)
          return { GetTop = function() return top end, GetBottom = function() return bottom end,
                   GetHeight = function() return height end }
        end
        local header = { frame = frame(o.detailTop, o.headerBottom) }
        local detail = { frame = frame(o.detailTop, nil),
                         children = o.noDetailChildren and {} or { header } }
        local calls = {}
        local scroll = {
          type = "ScrollFrame",
          children = { { frame = frame(900, 800) }, detail },
          scrollframe = frame(o.viewTop, o.viewBottom, o.viewHeight),
          content = frame(nil, nil, o.contentHeight),
          status = o.noStatus and nil or { scrollvalue = o.scrollvalue },
          localstatus = {},
          SetScroll = function(_, v) calls[#calls + 1] = v end,
        }
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        ns.Options = { dialog = { Open = function() end,
          OpenFrames = { Elmira = { children = { { children = o.noScroll and {} or { scroll } } } } } } }
        return calls
      end

      it("issues no SetScroll at all when the detail panel's header is already visible", function()
        local calls = harness()
        cards().card1.arg.actions.open.func()
        assert.equal(0, #calls, "an already-visible header must produce NO call, not SetScroll(current)")
      end)

      it("scrolls the page's own ScrollFrame, found under the dialog, when the detail is below",
        function()
          local calls = harness{ detailTop = 120, headerBottom = 80 }
          cards().card1.arg.actions.open.func()
          assert.same({ 120 }, calls)
        end)

      it("reads the value the page is already scrolled to", function()
        local calls = harness{ detailTop = 120, headerBottom = 80, scrollvalue = 200 }
        cards().card1.arg.actions.open.func()
        assert.same({ 320 }, calls)
      end)

      -- A freshly built status table has no `scrollvalue` yet (AceConfigDialog creates it empty,
      -- :1652-1655), which must read as "at the top", not error.
      it("treats a status table with no scroll value yet as the top of the page", function()
        local calls = harness{ detailTop = 120, headerBottom = 80, scrollvalue = UNSET }
        cards().card1.arg.actions.open.func()
        assert.same({ 120 }, calls)
      end)

      it("falls back to the widget's own local status when it has been given no status table",
        function()
          local calls = harness{ detailTop = 120, headerBottom = 80, noStatus = true }
          cards().card1.arg.actions.open.func()
          assert.same({ 120 }, calls)
        end)

      it("does nothing, and does not error, when the dialog has no ScrollFrame at all", function()
        local calls = harness{ detailTop = 120, headerBottom = 80, noScroll = true }
        assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
        assert.equal(0, #calls)
      end)

      it("does nothing when the detail panel has no header row to reveal", function()
        local calls = harness{ detailTop = 120, headerBottom = 80, noDetailChildren = true }
        assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
        assert.equal(0, #calls)
      end)

      -- A frame the client has not laid out yet answers nil to GetTop/GetBottom/GetHeight. Guessing
      -- a zero there would scroll the page somewhere arbitrary.
      it("does nothing when the page has not been laid out yet", function()
        local calls = harness{ detailTop = 120, headerBottom = 80, viewTop = UNSET }
        assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
        assert.equal(0, #calls)
      end)

      it("does nothing when the detail frame itself has no position yet", function()
        local calls = harness{ detailTop = UNSET, headerBottom = 80 }
        assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
        assert.equal(0, #calls)
      end)

      it("does nothing when the content height is not readable yet", function()
        local calls = harness{ detailTop = 120, headerBottom = 80, contentHeight = UNSET }
        assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
        assert.equal(0, #calls)
      end)

      -- The dialog stand-ins every other card test uses carry no OpenFrames at all.
      it("does not error when the options window is not open", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        ns.Options = { dialog = { Open = function() end } }
        assert.has_no.errors(function() cards().card1.arg.actions.open.func() end)
      end)
    end)

    -- PE1-D2: the card no longer carries a Copy link action, WITH a source or without one -- the
    -- detail panel's own Copy Source Link button is the single place a player copies a guide URL
    -- from, and every card in both grids is now uniformly body-click + Use.
    it("has no Copy link action even when the catalog entry ships a source", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true,
                       source = "https://www.wowhead.com/classic/guide/paladin" } }
      local card = cards().card1
      assert.is_nil(card.arg.actions.link)
      assert.is_nil(card.arg.source)
      -- The only actions left are the body click and (on a row that is not running) Use.
      assert.is_nil(card.arg.actions.open.name:find("link", 1, true))
    end)

    it("has no source line or Copy link action at all when the catalog entry carries no source",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local card = cards().card1
        assert.is_nil(card.arg.source)
        assert.is_nil(card.arg.actions.link)
      end)

    -- PE1-D1: ONE header row -- what this character is, and which phase the catalog below is for --
    -- with the New Rotation button beside it. The old sentence ("...Pick how you want to play:")
    -- named the class a second time and instructed the player to do the thing six clickable cards
    -- underneath already invite; it stays where it belongs, in the wizard (Setup/Wizard.lua:200).
    describe("the merged header row (PE1-D1)", function()
      local function line(detection, rows)
        installPack()
        installWizard(rows or { { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true,
                                   phase = "SoD P8" } })
        ns.Wizard.detection = function() return detection end
        return Rotation.group().args.detection.name
      end

      it("reads level, class, weapon and phase, joined with a middle dot", function()
        assert.equal("Level 60 Paladin · 1H · SoD P8",
          line({ class = "PALADIN", level = 60, weapon = { type = "1H" } }))
      end)

      -- The old version rendered "Level ? ?, holding a unknown" for a character the adapter had not
      -- answered for yet. A segment we cannot read is OMITTED; nothing ever prints as ?/unknown.
      it("omits the weapon segment entirely rather than saying 'unknown'", function()
        local text = line({ class = "PALADIN", level = 60 })
        assert.equal("Level 60 Paladin · SoD P8", text)
        assert.is_falsy(text:find("?", 1, true))
        assert.is_falsy(text:find("unknown", 1, true))
      end)

      it("omits the phase segment when the catalog carries none", function()
        local text = line({ class = "PALADIN", level = 60, weapon = { type = "1H" } },
          { { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } })
        assert.equal("Level 60 Paladin · 1H", text)
        assert.is_falsy(text:find("?", 1, true))
      end)

      -- Level and class share ONE segment, so a readable level with an unreadable class still reads
      -- as a sentence rather than leaving a dangling "?" where the class would have been.
      it("keeps the level on its own when the class cannot be read", function()
        assert.equal("Level 60 · SoD P8", line({ level = 60 }))
      end)

      it("keeps the class on its own when the level cannot be read", function()
        assert.equal("Paladin · SoD P8", line({ class = "PALADIN" }))
      end)

      it("says nothing at all about a character it cannot read anything about", function()
        local text = line({})
        assert.equal("SoD P8", text)
        assert.is_falsy(text:find("?", 1, true))
        assert.is_falsy(text:find("unknown", 1, true))
      end)

      -- PA10: the class TOKEN read as shouting; the merged line normalises it the same way the old
      -- playstyles header did.
      it("normalises the all-caps class token", function()
        assert.is_falsy(line({ class = "PALADIN", level = 60 }):find("PALADIN", 1, true))
      end)

      -- Both are CONTROLS with a relative width, which is the only shape AceConfigDialog will flow
      -- onto one row (:1444-1452) -- an inline group is forced to `width = "fill"` and could not.
      it("puts the detection line and New Rotation on one row, as relative-width controls", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local args = Rotation.group().args
        assert.equal("relative", args.detection.width)
        assert.equal(0.72, args.detection.relWidth)
        assert.equal("relative", args.newRotation.width)
        assert.equal(0.28, args.newRotation.relWidth)
        -- Together they fill the row; the button is right-aligned by being the second of the two.
        assert.equal(1, args.detection.relWidth + args.newRotation.relWidth)
        assert.is_true(args.newRotation.order > args.detection.order)
      end)

      -- The wizard's own opening sentence shares nothing with this line and is not touched by it.
      it("leaves the wizard's own instruction sentence out of the panel entirely", function()
        assert.is_falsy(line({ class = "PALADIN", level = 60 }):find("Pick how you want to play", 1, true))
      end)
    end)

    -- PA9 (2026-09-08): the "· in use" badge is gone from the card's TITLE -- the widget's own
    -- border/fill carry that now (CardWidget.lua's own tests prove the colour side); the row model
    -- hands the card `active` as a plain flag instead, and offers Use on the others exactly as
    -- before.
    it("marks the running template's row active with no title badge, and offers Use on the others",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                       { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
        local args = cards()
        assert.is_true(args.card1.arg.active)
        assert.is_falsy(args.card1.arg.title:find("in use", 1, true))
        assert.is_nil(args.card1.arg.actions.use, "the active row still offers a Use action")
        assert.is_falsy(args.card2.arg.active)
        assert.is_falsy(args.card2.arg.title:find("in use", 1, true))
        -- PE5-D3: the card's own Use button reads its label straight from `useButtonArgs`, so it is
        -- green here too -- a gold Use on the card beside a green one in the detail panel below it
        -- would be the same action wearing two colours on one screen.
        assert.equal("Use", args.card2.arg.actions.use.name)
        assert.is_nil(args.card2.arg.actions.use.desc, "a fitting row still explains a reason it does not have")
      end)

    -- D44: the Use action actually switches the rotation when it runs -- not just that the action
    -- looks right, but that its own `func` runs `Rotation.use` and the switch takes.
    it("actually switches to the rotation when the Use action runs", function()
      installPack()
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      cards().card2.arg.actions.use.func()
      assert.equal("PALADIN_SHOCKADIN", ns.db.profile.activeBuild)
      assert.equal(1, #said, "only the success announcement, no failure warning")
      assert.equal("rotation", said[1][1])
    end)

    -- D44: `Rotation.use` returns `false, reason` and this call site used to drop it, so a failed
    -- click looked exactly like a dead button. It must say why instead.
    it("announces the reason instead of doing nothing when the Use action fails to activate",
      function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                       { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
        -- No ns.db in this describe block's default state, so Rotation.use refuses with "no profile".
        local said = {}
        ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
        cards().card2.arg.actions.use.func()
        assert.equal(1, #said)
        assert.equal("warning", said[1][1])
        assert.is_truthy(said[1][2]:find("could not set that playstyle", 1, true))
        assert.is_truthy(said[1][2]:find("no profile", 1, true))
      end)

    it("does not error when Announce is not loaded and the Use action fails", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      ns.Announce = nil
      cards().card2.arg.actions.use.func()
    end)

    -- Never a literal AceConfig `disabled`: `requires` is advisory (hard rule 8), so a card that
    -- does not fit still offers an action, worded and confirmed rather than refused. The card's own
    -- buttons are plain frames CardWidget.lua draws, never fed through AceConfigDialog's own
    -- ActivateControl -- so `confirmThen` (Rotation.lua) bakes the confirm INTO `func` itself, and
    -- what is observable here is exactly that: a StaticPopup, naming the same reason, whose OWN
    -- accept is what finally runs `Rotation.use` -- clicking the action alone must not switch yet.
    -- PB3: the label stays plain "Use" even when the row fails a check -- the confirm dialog is
    -- where the caveat lives, named below via `_G.__lastStaticPopup.arg1`.
    it("offers 'Use', confirmed, when a template needs gear or runes you do not have",
      function()
        installPack()
        ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
        ns.Display.activeBuild = function() return nil, nil end -- nothing active: the row must not be badged
        ns.Detect = { hasFailures = function(checks)
          for _, c in ipairs(checks or {}) do if c.ok == false then return true end end
          return false
        end }
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false,
                         checks = { { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" } } } }
        local use = cards().card1.arg.actions.use
        assert.equal("Use", use.name)
        assert.equal("Weapon: 2H (you have 1H)", use.desc)
        use.func()
        assert.is_false(ns.db.profile.activeBuild, "must wait for the popup's own accept, not switch immediately")
        assert.equal("ELMIRA_CONFIRM", _G.__lastStaticPopup.which)
        assert.equal("Weapon: 2H (you have 1H)", _G.__lastStaticPopup.arg1)
        _G.__lastStaticPopup.data.onAccept()
        assert.equal("PALADIN_EXODIN", ns.db.profile.activeBuild)
      end)

    -- `confirmThen`'s own degrade: a client with no StaticPopup layer at all (never true in game,
    -- but the same defensive shape `openSourcePopup` etc. already use above) must still let the
    -- action run, rather than leaving the Use button dead.
    it("runs the action directly when no StaticPopup layer is present at all", function()
      installPack()
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
      ns.Display.activeBuild = function() return nil, nil end
      ns.Detect = { hasFailures = function() return true end }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false,
                       checks = { { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" } } } }
      local use = cards().card1.arg.actions.use
      _G.StaticPopup_Show = nil
      use.func()
      assert.equal("PALADIN_EXODIN", ns.db.profile.activeBuild)
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
        local args = cards()
        assert.equal(ns.Colors.wrap(ns.Colors.MUTED, "Seal twisting"), args.card2.arg.title)
        assert.equal("Exodin", args.card1.arg.title)
      end)

      it("says why on its own page, in words, above the summary", function()
        installTwist()
        local about = Rotation.group().args.PALADIN_TWIST.args.about.args
        assert.is_table(about.blocked, "the page never explains why the name is muted")
        assert.is_truthy(about.blocked.name:find("no rotation has shipped", 1, true))
        assert.is_true(about.blocked.order < about.summary.order)
        assert.is_nil(Rotation.group().args.PALADIN_EXODIN.args.about.args.blocked)
      end)

      -- PB3: the label is plain "Use" on both rows -- the confirmed one carries the caveat only in
      -- `confirm`/`confirmText`, which is what distinguishes it from Exodin's un-confirmed button.
      it("keeps a Use button, worded and confirmed with that same reason", function()
        installTwist()
        local use = Rotation.group().args.PALADIN_TWIST.args.header.args.use
        assert.equal("Use", use.name)
        assert.is_nil(use.disabled)
        assert.is_true(use.confirm)
        assert.is_truthy(use.confirmText:find("no rotation has shipped", 1, true))
        assert.equal(use.confirmText, use.desc)
        local exodinUse = Rotation.group().args.PALADIN_EXODIN.args.header.args.use
        assert.equal("Use", exodinUse.name)
        assert.is_nil(exodinUse.confirm)
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
        local use = cards().card1.arg.actions.use
        use.func()
        assert.is_truthy(_G.__lastStaticPopup.arg1:find("no rotation has shipped", 1, true))
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
    -- PA6: easy/medium/hard hand over a plain LEVEL NUMBER and a LABEL string -- CardWidget.lua owns
    -- turning the level into pip textures (this client's font has no ●/○ glyphs, tasks/lessons.md;
    -- a glyph string would have rendered as three identical boxes, which is exactly the bug the
    -- 2026-09-08 correction replaced).
    it("hands the card a difficulty level and label, one tier per level", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", difficulty = "easy",
                       fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", difficulty = "hard",
                       fits = true } }
      local args = cards()
      assert.equal(1, args.card1.arg.difficultyLevel)
      assert.equal("Easy", args.card1.arg.difficultyLabel)
      assert.equal(3, args.card2.arg.difficultyLevel)
      assert.equal("Hard", args.card2.arg.difficultyLabel)
    end)

    it("omits both difficulty fields when the catalog entry has none", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local card = cards().card1
      assert.is_nil(card.arg.difficultyLevel)
      assert.is_nil(card.arg.difficultyLabel)
    end)

    -- A catalog `source` is always a URL string in practice; a malformed one must not error the
    -- whole panel over a punctuation problem in a guide link.
    it("does not error when a catalog source is not a URL-shaped string at all", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true, source = 12345 } }
      assert.has_no.errors(function() return Rotation.group() end)
    end)

    -- PA5's split (`splitPlaystyle`) runs on `row.playstyle` before anything else touches it; a
    -- catalog entry with a non-string playstyle must not take the whole panel down over it.
    it("does not error when a catalog playstyle is not a string at all", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = 12345, fits = true } }
      assert.has_no.errors(function() return Rotation.group() end)
    end)

    -- PA10's `classDisplay` only runs on a genuinely truthy `p.class`/`detection.class`; a pack
    -- whose `class` field is present but not a string (malformed data, never Elmira's own) must
    -- still render rather than erroring trying to `:sub()` a number.
    it("does not error when the pack's class is not a string at all", function()
      ns.Display.currentPack = function()
        return { class = 12345, catalog = { PALADIN = CATALOG },
                 builds = { PALADIN_EXODIN = {}, PALADIN_SHOCKADIN = {} } }
      end
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      assert.has_no.errors(function() return Rotation.group() end)
    end)

    -- PA10: the pack's own `class` is preferred, but a pack that has none must still fall back to
    -- DETECTION's class (also normally-capitalised), not silently say "?" for a class it could
    -- have named. PE1-D1 moved the class off the playstyles title, so the surviving reader of that
    -- fallback chain is the no-catalog sentence.
    it("falls back to detection's class for the no-catalog sentence when the pack has none",
      function()
        installPack()
        installWizard{}
        ns.Display.currentPack = function()
          return { catalog = { PALADIN = {} }, builds = {} }
        end
        ns.Wizard.detection = function() return { class = "MAGE" } end
        assert.is_truthy(Rotation.group().args.noPack.name:find("Mage", 1, true))
      end)

    -- PA5/PA8: a playstyle with no em-dash and no `updated` date has nothing extra to say in a
    -- tooltip -- it must be genuinely ABSENT (nil), not an empty string that would still make
    -- CardWidget.lua draw a tooltip box with nothing in it.
    it("has no tooltip at all when the playstyle has no extra text and no updated date", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      assert.is_nil(cards().card1.arg.tooltip)
    end)

    -- PE1-D7: `type = "execute"` labels are Title Case. Asserted as the literal strings a player
    -- reads, at their own call sites, so a future lowercase label fails the suite rather than
    -- waiting for a screenshot. Section headers and prose are deliberately NOT included -- "What
    -- this rotation needs" and "Rotation, top to bottom" stay sentence case.
    it("labels every button on the Rotations pages in Title Case", function()
      installPack()
      ns.Display.activeBuild = function() return nil, nil end
      installUserBuilds{ list = function() return { "USER_MINE" } end,
        find = function(pk, key)
          if key == "USER_MINE" then return { entries = {} }, "fork", { name = "Mine" } end
          if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
        end }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local args = Rotation.group().args
      assert.equal("New Rotation", args.newRotation.name)
      -- PE2-D3.4: brand-coloured, on its own row -- it navigates away instead of adding, so it must
      -- not look like the eighteenth ability button. The label itself is unchanged.
      assert.equal(ns.Colors.wrap(ns.Colors.BRAND, "Add from Spellbook…"),
        args.builder.args.spells.args.add.name)
      assert.equal("full", args.builder.args.spells.args.add.width)
      -- PE4-D4/PE5-D3: colour by what the button DOES, every choice driven by ONE table
      -- (`BUTTON_COLOURS`, Rotation.lua) so the owner's likely walk-back to destructive-only is one
      -- line. Green does the thing this page exists for (Use), purple navigates elsewhere (Copy and
      -- Edit, Edit), red throws work away once and globally (Delete); Rename neither commits nor
      -- destroys and keeps the default gold. The LABELS are unchanged, which is what these
      -- assertions still check underneath the escape.
      local header = args.PALADIN_EXODIN.args.header.args
      assert.equal(ns.Colors.wrap(ns.Colors.BRAND, "Copy and Edit"), header.copy.name)
      assert.equal("Use", header.use.name)
      local fork = args.USER_MINE.args.header.args
      assert.equal("Rename", fork.rename.name)
      assert.equal(ns.Colors.wrap(ns.Colors.BAD, "Delete"), fork.delete.name)
      assert.equal(ns.Colors.wrap(ns.Colors.BRAND, "Edit"), fork.edit.name)
    end)

    it("says so when the class ships no templates, and still offers New rotation", function()
      installPack()
      installWizard{}
      local root = Rotation.group().args
      assert.is_truthy(root.noPack.name:find("No playstyles for", 1, true))
      assert.equal("execute", root.newRotation.type)
      assert.is_nil(root.playstyles, "an inline group for an empty catalog names nothing")
    end)

    -- PE1-D1: the class and the phase both moved up into the merged header row, so the box title is
    -- the short word alone -- naming the class a third time on the same screen is what made the old
    -- "Playstyles for Paladin · SoD P8" read as noise.
    it("titles the root page's playstyles group with the bare word, naming no class", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true, phase = "SoD P8" } }
      local header = Rotation.group().args.playstyles.name
      assert.equal("Playstyles", header)
      assert.is_falsy(header:find("Paladin", 1, true))
      assert.is_falsy(header:find("PALADIN", 1, true))
      assert.is_falsy(header:find("SoD P8", 1, true))
    end)

    -- Absolute positions, not just "each is unique": a shift here would leave every row still
    -- distinct from the others (the uniqueness test above would not notice), only reordered on
    -- screen from what the artifact specifies -- detection, then New rotation, then the playstyles
    -- group (PA11's inline group replaces the old separate header line + loose cards).
    it("puts detection, New rotation and the playstyles group in that exact order", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      local args = Rotation.group().args
      assert.equal(1, args.detection.order)
      assert.equal(2, args.newRotation.order)
      assert.equal(3, args.playstyles.order)
      assert.equal(1, cards().card1.order)
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
      it("has a header naming it, badged when it is the one running, with a Copy and Edit button",
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
          -- PE4-D4: purple, because it navigates somewhere else.
          assert.equal(ns.Colors.wrap(ns.Colors.BRAND, "Copy and Edit"), header.copy.name)
          assert.equal("Makes your own editable copy of this template, under a name you choose.",
                       header.copy.desc)
          assert.equal(1, header.name.order)
          assert.equal(2, header.copy.order)
          -- PE5-D1: no Use on the template already running, so the name takes the share Use would
          -- have had. A hard-coded name width leaves a hole in exactly this row.
          assert.equal(1.0, headerRelSum(header))
          assert.equal(0.75, header.name.relWidth)
          header.copy.func()
          assert.equal("PALADIN_EXODIN", _G.__lastStaticPopup.data.templateKey)
        end)

      it("offers Use before Copy and Edit when the template is not the one running", function()
        installPack()
        ns.Display.activeBuild = function() return nil, nil end
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
        local header = Rotation.group().args.PALADIN_EXODIN.args.header.args
        assert.equal("execute", header.use.type)
        assert.equal(1, header.name.order)
        assert.equal(2, header.use.order)
        assert.equal(3, header.copy.order)
        -- PE5-D1: still exactly one row, and the name gave up precisely Use's width to make room.
        assert.equal(1.0, headerRelSum(header))
        assert.equal(0.625, header.name.relWidth)
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

      -- PE1-D5: each ability's own icon before its name, the SAME mechanism the rotation lines one
      -- block down already use (D72, `Display.spellIcon` -> the merged registry -> the ADAPTER).
      -- A check whose key is not a spell at all (weapon/speed), or a set, or one that resolves to
      -- nothing, renders with NO icon AND NO GAP -- not a placeholder texture, and not a stray
      -- second space that would leave its text hanging away from the mark.
      it("puts the ability's icon before its name, and nothing at all where there is none",
        function()
          installPack()
          local asked = {}
          ns.Display.spellIcon = function(key)
            asked[#asked + 1] = key
            if key == "HOLY_SHOCK" then return "Interface\\Icons\\Spell_Holy_SearingLight" end
            if key == "RUNE_ART_OF_WAR" then return "Interface\\Icons\\Ability_Warrior_InnerRage" end
            return nil
          end
          installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false, checks = {
            { key = "HOLY_SHOCK", ok = true, text = "Holy Shock known" },
            { key = "RUNE_ART_OF_WAR", ok = true, text = "Art of War engraved" },
            { key = "PALADIN_T2_JUDGEMENT", ok = false, text = "Radiant Judgement: 2/4 pieces" },
            { key = "weapon", ok = false, text = "Weapon: 2H (you have 1H)" },
          } } }
          local needs = Rotation.group().args.PALADIN_EXODIN.args.needs.args
          local green = "|TInterface\\COMMON\\Indicator-Green:12|t "
          local amber = "|TInterface\\COMMON\\Indicator-Yellow:12|t "
          assert.equal(green .. "|TInterface\\Icons\\Spell_Holy_SearingLight:0|t Holy Shock known",
            needs.n1.name)
          assert.equal(amber:gsub("Yellow", "Green") .. -- a rune check gets its rune's own icon
            "|TInterface\\Icons\\Ability_Warrior_InnerRage:0|t Art of War engraved", needs.n2.name)
          -- No icon: the text starts immediately after the mark's single space.
          assert.equal(amber .. "Radiant Judgement: 2/4 pieces", needs.n3.name)
          assert.equal(amber .. "Weapon: 2H (you have 1H)", needs.n4.name)
          -- Resolved through the check's own key, which is what carries the spell/rune identity.
          -- (`Rotation.group()` renders this row set twice -- the template's page and the shared
          -- detail area both call `needsArgs` -- so the keys repeat; the first pass is the claim.)
          assert.equal("HOLY_SHOCK", asked[1])
          assert.equal("RUNE_ART_OF_WAR", asked[2])
          assert.equal("PALADIN_T2_JUDGEMENT", asked[3])
          assert.equal("weapon", asked[4])
        end)

      -- An install where the display module has not wired `spellIcon` (or a class pack with no
      -- registry) must still render every row, plainly.
      it("renders the rows unchanged when no icon lookup is available at all", function()
        installPack()
        installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = false,
          checks = { { key = "HOLY_SHOCK", ok = true, text = "Holy Shock known" } } } }
        assert.equal("|TInterface\\COMMON\\Indicator-Green:12|t Holy Shock known",
          Rotation.group().args.PALADIN_EXODIN.args.needs.args.n1.name)
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
          -- PE1-D7: after D2 removed the cards' own link buttons this is the only copy-link button
          -- on the page, and D3 lands the player here -- so it names what it copies. An AceGUI
          -- button clips its text rather than growing, so the row is rebalanced to fit the label.
          assert.equal("Copy Source Link", about.link.name)
          assert.equal(1.4, about.source.width)
          assert.equal(0.8, about.link.width)
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
        assert.is_truthy(lines.args.l1.name
          :find("|TInterface\\AddOns\\Elmira\\media\\mark_firing:12|t", 1, true))
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
      assert.equal("medium", fork.args.header.args.from.fontSize,
        "the row is drawn two points smaller than the name beside it")
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
      -- PE5-D2: both shapes of the row fill it exactly, and the name -- not a gap -- absorbs the
      -- width of the Use button the active fork does not have.
      assert.equal(1.0, headerRelSum(mine))
      assert.equal(1.0, headerRelSum(other))
      assert.is_true(mine.name.relWidth > other.name.relWidth,
        "the active fork's name must take the width its missing Use button gave up")
      -- PE5-D2: Use, Edit, Rename, Delete -- most-wanted first, destructive last.
      -- Active: name, from, edit, rename, delete (no Use). Not active: Use slots in between.
      assert.equal(1, mine.name.order)
      assert.equal(2, mine.from.order)
      assert.equal(3, mine.edit.order)
      assert.equal(4, mine.rename.order)
      assert.equal(5, mine.delete.order)
      assert.equal(1, other.name.order)
      assert.equal(2, other.from.order)
      assert.equal(3, other.use.order)
      assert.equal(4, other.edit.order)
      assert.equal(5, other.rename.order)
      assert.equal(6, other.delete.order)
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
        -- PE4-D4: red, because it throws a whole rotation away once and globally.
        assert.equal(ns.Colors.wrap(ns.Colors.BAD, "Delete"), header.delete.name)
        assert.is_true(header.delete.confirm)
        assert.equal("execute", header.use.type)
        assert.equal(1, header.name.order)
        assert.equal(2, header.from.order)
        assert.equal(3, header.use.order)
        assert.equal(4, header.edit.order)
        assert.equal(5, header.rename.order)
        assert.equal(6, header.delete.order)
      end)

    -- F1b (2026-09-07 bug round): the owner's per-fork override, over plain class-wide visibility.
    it("gives a fork's page a private toggle, default off", function()
      installPack()
      installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                        find = function() return {}, "fork", { name = "Scratch", private = false } end }
      local toggle = Rotation.group().args.USER_SCRATCH.args.private
      assert.equal("toggle", toggle.type)
      assert.is_false(toggle.get())
      assert.is_truthy(toggle.desc:find("only this one can", 1, true))
    end)

    it("reflects an already-private fork, and its set() calls UserBuilds.setPrivate", function()
      installPack()
      local calls = {}
      installUserBuilds{
        list = function() return { "USER_SCRATCH" } end,
        find = function() return {}, "fork", { name = "Scratch", private = true } end,
        setPrivate = function(key, v) calls[#calls + 1] = { key, v }; return true end,
      }
      local toggle = Rotation.group().args.USER_SCRATCH.args.private
      assert.is_true(toggle.get())
      toggle.set(nil, false)
      assert.same({ { "USER_SCRATCH", false } }, calls)
    end)

    -- PE5-D2: in the HEADER row now, beside Rename and Delete -- it used to be the last thing on the
    -- page, below the whole rotation listing. The behaviour below is unchanged by the move.
    it("gives a fork's page an Edit button that activates it and jumps to the Builder", function()
      installPack()
      ns.db = { profile = { activeBuild = false }, char = { setupDone = 0 } }
      installUserBuilds{
        list = function() return { "USER_SCRATCH" } end,
        find = function() return { entries = {} }, "fork", { name = "Scratch" } end,
      }
      local selected
      ns.Options = { dialog = { SelectGroup = function(_, ...) selected = { ... } end } }
      local edit = Rotation.group().args.USER_SCRATCH.args.header.args.edit
      assert.equal("Opens this rotation in the Builder.", edit.desc)
      assert.is_nil(Rotation.group().args.USER_SCRATCH.args.edit,
        "Edit is still stranded at the bottom of the page")
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
      Rotation.group().args.USER_SCRATCH.args.header.args.edit.func()
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
      Rotation.group().args.USER_SCRATCH.args.header.args.edit.func()
      assert.is_nil(selected, "Edit navigated to the Builder despite a failed activation")
      assert.equal(1, #said)
      assert.equal("warning", said[1][1])
      assert.is_truthy(said[1][2]:find("could not set that playstyle", 1, true))
      assert.is_truthy(said[1][2]:find("no profile", 1, true))
    end)
  end)

  -- PD1-D1: which card's detail is showing -- transient UI state, never `db.profile`.
  describe("Rotation.select()/Rotation.selected() (PD1-D1)", function()
    it("returns the active key before anything has been clicked", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      ns.Display.activeBuild = function() return {}, "PALADIN_EXODIN", nil end
      assert.equal("PALADIN_EXODIN", Rotation.selected())
    end)

    it("returns the clicked key after Rotation.select", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      ns.Display.activeBuild = function() return {}, "PALADIN_EXODIN", nil end
      assert.is_true(Rotation.select("PALADIN_SHOCKADIN"))
      assert.equal("PALADIN_SHOCKADIN", Rotation.selected())
    end)

    -- Distinct from `templates[1]` on purpose: a mutant deleting either the read of `activeKey()`
    -- or the branch that returns it would still pass every OTHER test here, since those all leave
    -- the active rotation as the first (or only) template listed.
    it("returns the active key even when it is not the first template listed", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      ns.Display.activeBuild = function() return {}, "PALADIN_SHOCKADIN", nil end
      assert.equal("PALADIN_SHOCKADIN", Rotation.selected())
    end)

    -- The args table is rebuilt from scratch on every `Rotation.notifyChange()`
    -- (`Rotation.group()` is exactly that rebuild) -- the selection has to live somewhere that
    -- survives it, which is the whole reason it is a module upvalue and not part of the args.
    it("keeps the selection across a rebuild of the whole args table", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      ns.Display.activeBuild = function() return {}, "PALADIN_EXODIN", nil end
      Rotation.select("PALADIN_SHOCKADIN")
      Rotation.group()
      assert.equal("PALADIN_SHOCKADIN", Rotation.selected())
    end)

    it("falls back to the first template when nothing is active and nothing is selected", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true },
                     { build = "PALADIN_SHOCKADIN", playstyle = "Shockadin", fits = true } }
      ns.Display.activeBuild = function() return nil, nil end
      assert.equal("PALADIN_EXODIN", Rotation.selected())
    end)

    it("answers nil for a class with no templates and no forks", function()
      installWizard{}
      ns.Display.activeBuild = function() return nil, nil end
      assert.is_nil(Rotation.selected())
    end)

    -- The removed row can be the SELECTED one without being the ACTIVE one -- the fallback chain
    -- must still land on the rotation actually running, not on nil.
    it("falls back to the active key once the selected fork is removed", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      ns.Display.activeBuild = function() return {}, "PALADIN_EXODIN", nil end
      local removed = false
      installUserBuilds{
        list = function() return removed and {} or { "USER_MINE" } end,
        find = function(pk, key)
          if key == "USER_MINE" and not removed then
            return { entries = {} }, "fork", { name = "Mine" }
          end
          if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
        end,
        remove = function() removed = true; return true end,
      }
      Rotation.select("USER_MINE")
      assert.equal("USER_MINE", Rotation.selected())
      Rotation.remove("USER_MINE")
      assert.equal("PALADIN_EXODIN", Rotation.selected())
    end)
  end)

  -- PD1-D3: one shared detail area, below the card grid(s), reusing the SAME arg builders the tree's
  -- own sub-pages call (`templateBodyArgs`/`forkBodyArgs`), never a second copy of them.
  describe("the shared detail area (PD1-D3)", function()
    it("shows the selected template's own header/about/needs/lines", function()
      installPack()
      -- `Rotation.displayName` (what the group's own name is built from) falls back to the raw
      -- key with no `UserBuilds` loaded at all -- installed here (with no overrides) so it takes
      -- the real catalog-lookup path instead, the same way every other caller of it gets a name.
      installUserBuilds{}
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true,
                       summary = "Fast 2H." } }
      ns.Display.activeBuild = function() return {}, "PALADIN_EXODIN", nil end
      local detail = Rotation.group().args.detail
      assert.equal("group", detail.type)
      assert.is_true(detail.inline)
      -- PE1-D4: the BOX is a stable landmark, not an echo of the name the inner header already
      -- prints one line below it.
      assert.equal("Details", detail.name)
      assert.is_falsy(detail.name:find("Exodin", 1, true))
      assert.is_falsy(detail.name:find("in use", 1, true))
      -- Identity and the badge stay on the inner header, next to the buttons that act on it.
      assert.is_truthy(detail.args.header.args.name.name:find("Exodin", 1, true))
      assert.is_truthy(detail.args.header.args.name.name:find("in use", 1, true))
      assert.equal("Fast 2H.", detail.args.about.args.summary.name)
      assert.equal("What this rotation needs", detail.args.needs.name)
      assert.equal("Rotation, top to bottom", detail.args.lines.name)
    end)

    it("shows the selected fork's own header/private toggle/edit button once a fork is selected",
      function()
        installPack()
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
        Rotation.select("USER_MINE")
        local detail = Rotation.group().args.detail
        -- PE1-D4: same stable box title for the fork branch...
        assert.equal("Details", detail.name)
        assert.is_falsy(detail.name:find("My Exodin", 1, true))
        -- ...with the fork's own name still on its inner header.
        assert.is_truthy(detail.args.header.args.name.name:find("My Exodin", 1, true))
        assert.equal("toggle", detail.args.private.type)
        -- PE5-D2: the Edit button rides in the header row now, not at the foot of the panel.
        assert.equal("execute", detail.args.header.args.edit.type)
        assert.is_nil(detail.args.about, "a fork's detail must not show the template page's own about block")
      end)

    it("is absent entirely when nothing is selectable at all", function()
      installWizard{}
      ns.Display.activeBuild = function() return nil, nil end
      assert.is_nil(Rotation.group().args.detail)
    end)

    it("sorts between the playstyle cards and the Builder", function()
      installPack()
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      ns.Display.activeBuild = function() return {}, "PALADIN_EXODIN", nil end
      local args = Rotation.group().args
      assert.is_true(args.detail.order > args.playstyles.order)
      assert.is_true(args.detail.order < args.builder.order)
    end)

    -- PE1-D3 depends on this being an INVARIANT, not a coincidence: the scroll lookup finds the
    -- detail panel as the LAST child of the page's scroll content, so anything ordered below it
    -- that is not a tree sub-page (a non-inline group, which AceConfigDialog renders as its own
    -- page and never as content here) would silently break that lookup. This fails the suite
    -- instead.
    it("is the last element on the root page, which is what the scroll lookup depends on", function()
      installPack()
      installUserBuilds{ list = function() return { "USER_MINE" } end,
        find = function(pk, key)
          if key == "USER_MINE" then return { entries = {} }, "fork", { name = "Mine" } end
          if pk and pk.builds and pk.builds[key] then return pk.builds[key], "pack" end
        end }
      installWizard{ { build = "PALADIN_EXODIN", playstyle = "Exodin", fits = true } }
      ns.Display.activeBuild = function() return {}, "PALADIN_EXODIN", nil end
      local args = Rotation.group().args
      assert.is_not_nil(args.detail)
      local checked = 0
      for key, row in pairs(args) do
        local isSubPage = row.type == "group" and not row.inline
        if key ~= "detail" and not isSubPage then
          checked = checked + 1
          assert.is_true(row.order < args.detail.order,
            key .. " renders below the detail panel, which breaks the D3 scroll lookup")
        end
      end
      assert.is_true(checked >= 4, "sanity: the page must actually have had rows to compare")
    end)
  end)

  -- PD1-D4: one ElmiraCard per fork, on the same root page as the playstyle cards.
  describe("\"Your rotations\" cards (PD1-D4)", function()
    local function group() return Rotation.group().args.yourRotations end

    it("is omitted entirely when there are no forks", function()
      installPack()
      installUserBuilds{ list = function() return {} end }
      assert.is_nil(group())
    end)

    it("shows one card per fork, the same widget and width as a playstyle card", function()
      installPack()
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function() return {}, "fork", { name = "My Exodin", derivedFrom = "PALADIN_EXODIN" } end,
      }
      local g = group()
      assert.equal("group", g.type)
      assert.is_true(g.inline)
      assert.equal("Your rotations", g.name)
      local card = g.args.card1
      assert.equal("ElmiraCard", card.dialogControl)
      assert.equal("relative", card.width)
      assert.equal(0.32, card.relWidth)
      assert.equal("My Exodin", card.arg.title)
    end)

    it("shows the copied-from line as the summary", function()
      installPack()
      installUserBuilds{
        list = function() return { "USER_MINE" } end,
        find = function() return {}, "fork", { name = "My Exodin", derivedFrom = "PALADIN_EXODIN" } end,
      }
      assert.is_truthy(group().args.card1.arg.summary:find("Exodin", 1, true))
    end)

    it("says \"yours\" for a fork with no template", function()
      installPack()
      installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                          find = function() return {}, "fork", { name = "Scratch" } end }
      assert.equal("yours", group().args.card1.arg.summary)
    end)

    it("marks a private fork on the meta line", function()
      installPack()
      installUserBuilds{
        list = function() return { "USER_SCRATCH" } end,
        find = function() return {}, "fork", { name = "Scratch", private = true } end,
      }
      assert.is_truthy(group().args.card1.arg.meta:find("Private", 1, true))
    end)

    it("carries no meta text for a fork that is not private", function()
      installPack()
      installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                          find = function() return {}, "fork", { name = "Scratch" } end }
      assert.is_falsy(group().args.card1.arg.meta:find("Private", 1, true))
    end)

    it("flags the running fork active, and offers Use on the others", function()
      installPack()
      ns.Display.activeBuild = function() return {}, "USER_MINE", nil end
      installUserBuilds{
        list = function() return { "USER_MINE", "USER_OTHER" } end,
        find = function(_, key) return {}, "fork", { name = key } end,
      }
      local args = group().args
      assert.is_true(args.card1.arg.active)
      assert.is_nil(args.card1.arg.actions.use)
      assert.is_falsy(args.card2.arg.active)
      -- PE5-D3: green, from the same `useButtonArgs` label the detail panel's own button uses.
      assert.equal("Use", args.card2.arg.actions.use.name)
    end)

    it("has no Copy link action -- a fork carries no source of its own", function()
      installPack()
      installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                          find = function() return {}, "fork", { name = "Scratch" } end }
      assert.is_nil(group().args.card1.arg.actions.link)
    end)

    it("selects rather than navigates when the card body is clicked, same as a playstyle card",
      function()
        installPack()
        installUserBuilds{ list = function() return { "USER_SCRATCH" } end,
                            find = function() return {}, "fork", { name = "Scratch" } end }
        local selectGroupCalls = 0
        ns.Options = { dialog = { SelectGroup = function() selectGroupCalls = selectGroupCalls + 1 end,
                                   Open = function() end } }
        group().args.card1.arg.actions.open.func()
        assert.equal("USER_SCRATCH", Rotation.selected())
        assert.equal(0, selectGroupCalls)
      end)

    -- `UserBuilds.list`/`.find` are the REAL Core/UserBuilds functions here, not faked -- proving
    -- the card section actually inherits `visible()`'s own class/private filtering rather than
    -- assuming `forkRows()` already does.
    it("never shows a card for a fork private to another character", function()
      installPack()
      ns.db = { global = { userBuilds = {
        USER_MINE = { build = { entries = {} }, class = "PALADIN" },
        USER_OTHER = { build = { entries = {} }, class = "PALADIN", private = true,
                       owner = "SomeoneElse - Realm" },
      } }, keys = { class = "PALADIN", char = "Arthorion - Realm" }, profile = { activeBuild = false } }
      ns.UserBuilds = realUserBuilds
      local args = group().args
      assert.is_table(args.card1)
      assert.is_nil(args.card2)
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
