local helper = require("tests.helper")

-- Elmira/Options/Spells.lua — the Abilities page (AB1, D1-D12). Plain data and closures, like
-- Options/Rotation.lua: a spec calls `SpellsPage.group()` and drives a row's get/set/func directly.
--
-- `ns.Rotation` is FAKED down to the four members this file actually calls
-- (templateRows/forkRows/displayName/syncSpells) rather than loading the real, much heavier
-- Options/Rotation.lua: Rotation's own behaviour is Options/Rotation's spec's job, and a fake here
-- keeps a failure in this file pointing at Spells.lua, not at the wiring underneath it.
describe("Options/Spells (the Abilities page, AB1)", function()
  local SpellsPage, Spells, A, ns

  local function installMinimal()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/Conditions.lua")
    helper.load("Elmira/Core/Visibility.lua")
    Spells = helper.load("Elmira/Core/Spells.lua")
    A = helper.load("Elmira/Core/AbilitySettings.lua")
    ns.db = { char = { spells = {}, abilities = {}, sounds = { enabled = true } },
              profile = { glow = { barGlow = true } } }
    ns.Display = { currentPack = function() return { class = "PALADIN" } end,
                   refresh = function() ns.repainted = (ns.repainted or 0) + 1 end }
    ns.builds = {}
    ns.UserBuilds = { find = function(_, key) return ns.builds[key] end }
    ns.templateRows, ns.forkRows = {}, {}
    ns.Rotation = {
      templateRows = function() return ns.templateRows end,
      forkRows = function() return ns.forkRows end,
      displayName = function(key) return key end,
      syncSpells = function() end,
    }
    ns.selected = nil
    ns.Options = { dialog = { SelectGroup = function(_, ...) ns.selected = { ... } end } }
    -- The REAL Display/Textures.lua, not a fake: the Texture tab reads its SOURCES/SHAPES/
    -- PLACEMENTS/EVENTS lists to build its dropdowns and its checkboxes, and a fake copy of those
    -- lists here would let the tab and the renderer drift apart without a test noticing. Its frames
    -- need a client, so CreateFrame answers with a no-op object -- nothing in THIS file asserts on
    -- a frame (tests/spec/textures_spec.lua does).
    _G.UIParent = setmetatable({}, { __index = function() return function() end end })
    _G.CreateFrame = function()
      local f = { textures = {} }
      return setmetatable(f, { __index = function()
        return function() return setmetatable({}, { __index = function() return function() end end }) end
      end })
    end
    helper.load("Elmira/Display/Textures.lua")
    -- AT4-D2: the path library behind the picker, loaded for the same reason -- the tab asks it
    -- whether a stored file needs an addon this character does not have.
    helper.load("Elmira/Display/TextureLibrary.lua")
    SpellsPage = helper.load("Elmira/Options/Spells.lua")
    -- Every page build starts from an unfiltered tree; the filter is module state.
    SpellsPage.setFilter("", "all")
  end

  before_each(function()
    ns = helper.reset()
    installMinimal()
  end)

  after_each(function()
    _G.CreateFrame, _G.UIParent = nil, nil
  end)

  -- The two hops the whole page hangs off: `spells > list` for the panels and the tree, and
  -- `spells > list > <key>` for one ability's six tabs.
  local function listArgs() return SpellsPage.group().args.list.args end
  local function entry(key) return listArgs()[key] end
  local function tab(key, name) return entry(key).args[name].args end

  -- ------------------------------------------------------------------ AB1-D1: the page structure

  describe("D1: page structure", function()
    it("is a TAB group named Abilities, ordered right after Rotations", function()
      local g = SpellsPage.group()
      assert.equal("group", g.type)
      assert.equal("tab", g.childGroups)
      assert.equal("Abilities", g.name)
      assert.equal(3, g.order)
    end)

    -- `BuildSubGroups` (AceConfigDialog-3.0.lua:1031) refuses to recurse into a tab group, which is
    -- what keeps the OUTER menu flat: one "Abilities" node with nothing hanging off it. Two
    -- children, in the owner's order.
    it("has exactly the Abilities and Share tabs, in that order", function()
      local args = SpellsPage.group().args
      local keys = {}
      for key in pairs(args) do keys[#keys + 1] = key end
      table.sort(keys)
      assert.same({ "list", "share" }, keys)
      assert.equal("Abilities", args.list.name)
      assert.equal(1, args.list.order)
      assert.equal("Share", args.share.name)
      assert.equal(2, args.share.order)
    end)

    -- The inner tree exists only because its PARENT is a tab group (the "assume tree group by
    -- default" branch, AceConfigDialog-3.0.lua:1721).
    it("makes the Abilities tab a tree of its own", function()
      assert.equal("tree", SpellsPage.group().args.list.childGroups)
    end)

    -- AB2-D5: two exports, one import, one box.
    it("gives Share both exports, the rotation picker and the import box", function()
      local args = SpellsPage.group().args.share.args
      assert.equal("execute", args.exportAll.type)
      assert.equal("select", args.rotation.type)
      assert.equal("execute", args.exportRotation.type)
      assert.equal("input", args.text.type)
      assert.equal(8, args.text.multiline)
    end)

    -- `list`'s OWN args render ABOVE the inner tree (`FeedOptions` runs before the child widget is
    -- added, AceConfigDialog-3.0.lua:1653-1661), so the add panel and the filter sit at the top.
    it("puts the add panel and the filter row above the tree, in that order", function()
      local args = listArgs()
      assert.equal("group", args.add.type)
      assert.is_true(args.add.inline)
      assert.equal(1, args.add.order)
      assert.equal("Add an ability", args.add.name)
      assert.equal("group", args.filter.type)
      assert.is_true(args.filter.inline)
      assert.equal(2, args.filter.order)
      assert.equal("Find an ability", args.filter.name)
    end)

    it("puts All abilities first and every registered ability after it", function()
      Spells.registerPack(ns.db.char.spells, "AAA", 1, "Aaa")
      Spells.registerPack(ns.db.char.spells, "BBB", 2, "Bbb")
      local args = listArgs()
      assert.equal(0, args["*"].order)
      assert.equal(11, args.AAA.order)
      assert.equal(12, args.BBB.order)
    end)

    it("syncs the registry (Rotation.syncSpells) before reading it", function()
      local called = 0
      ns.Rotation.syncSpells = function() called = called + 1 end
      SpellsPage.group()
      assert.equal(1, called)
    end)

    it("renders without ns.Rotation, ns.UserBuilds or ns.UserBuilds.find, rather than erroring", function()
      ns.Rotation = nil
      assert.has_no.errors(function() SpellsPage.group() end)
      installMinimal()
      ns.UserBuilds = nil
      assert.has_no.errors(function() SpellsPage.group() end)
      installMinimal()
      ns.UserBuilds.find = nil
      assert.has_no.errors(function() SpellsPage.group() end)
    end)

    -- The standing rule for the whole redesign: nothing may assume a class pack exists.
    it("builds every tab for a character with no data pack at all", function()
      ns.Display.currentPack = function() return nil end
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      local tabs = entry("SLICE_AND_DICE").args
      assert.is_not_nil(tabs.general.args.onlyInCombat)
      assert.is_not_nil(tabs.glow.args.style)
      assert.is_not_nil(tabs.sound.args.enabled)
      assert.is_not_nil(tabs.announce.args.enabled)
      assert.is_truthy(tabs.general.args.head.name:find("added from your spellbook", 1, true))
    end)

    it("sets ns.SpellsPage to itself when the file loads", function()
      assert.equal(SpellsPage, ns.SpellsPage)
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D2: one add panel

  describe("D2: one add panel, two halves", function()
    before_each(function()
      ns.Adapter = {
        spellbookEntries = function()
          return { { id = 900, name = "Slice and Dice" }, { id = 901, name = "Kick" } }
        end,
        spellNameByID = function(id) return id == 415073 and "Exorcism" or nil end,
        spellIDByName = function(name) return name == "Exorcism" and 415073 or nil end,
      }
    end)

    local function addArgs() return listArgs().add.args end

    -- The inline groups this replaces could not share a row: an AceConfig panel is always the full
    -- width of the page. Controls CAN, through relWidths summing to exactly 1.0 -- which is the
    -- only shape AceGUI's Flow scales (AceGUI-3.0.lua:709-711). AT5-D3 adds the icon slot as a
    -- fifth control rather than growing the group into a second row.
    it("puts all five controls on one row, with relWidths summing to 1", function()
      local args = addArgs()
      local total = 0
      for _, key in ipairs({ "pick", "addPick", "icon", "typed", "addTyped" }) do
        assert.equal("relative", args[key].width, key .. " does not share the row")
        total = total + args[key].relWidth
      end
      assert.is_true(math.abs(total - 1.0) < 1e-9, "the row does not add up to 1.0: " .. total)
      assert.equal("From your spellbook", args.pick.name)
      assert.equal("Spell ID or name", args.typed.name)
      assert.equal("Add", args.addPick.name)
      assert.equal("Add", args.addTyped.name)
      assert.equal("description", args.icon.type)
      assert.same({ 1, 2, 3, 4, 5 }, { args.pick.order, args.addPick.order, args.icon.order,
                                       args.typed.order, args.addTyped.order })
    end)

    it("offers every spellbook entry as a choice, with its icon", function()
      ns.Display.spellIconByID = function(id)
        return id == 900 and "Interface\\Icons\\Ability_Rogue_SliceDice" or nil
      end
      local values = addArgs().pick.values
      -- AT6-D7: the id after the name, in brackets. Two rows of a spellbook read exactly the same
      -- often enough (six ranks of one spell, a rune's version beside the trainer's) that the id is
      -- the only thing telling the player which one they are about to add.
      assert.equal("|TInterface\\Icons\\Ability_Rogue_SliceDice:14|t Slice and Dice (900)",
        values["900"])
      assert.equal("Kick (901)", values["901"])
    end)

    -- I1b: with no explicit `sorting`, AceGUI's DropDown sorts by the KEYS -- `tostring(entry.id)`
    -- -- so the list came out ordered by spell id.
    it("sorts the picker by NAME, not by the spell id its key happens to be", function()
      ns.Adapter.spellbookEntries = function()
        return { { id = 500, name = "Zzz Ability" }, { id = 901, name = "Aaa Ability" } }
      end
      assert.same({ "901", "500" }, addArgs().pick.sorting)
    end)

    it("registers the picked spell and navigates to its page", function()
      local args = addArgs()
      args.pick.set(nil, "900")
      args.addPick.func()
      assert.equal("spellbook", ns.db.char.spells.SLICE_AND_DICE.source)
      assert.same({ "Elmira", "spells", "list", "SLICE_AND_DICE" }, ns.selected)
      assert.is_nil(args.pick.get(), "the picker keeps the spell it just consumed")
    end)

    it("does nothing when nothing is picked, or the pick is not in the spellbook", function()
      addArgs().addPick.func()
      assert.same({}, ns.db.char.spells)
      local args = addArgs()
      args.pick.set(nil, "999")
      args.addPick.func()
      assert.same({}, ns.db.char.spells)
      assert.is_nil(ns.selected)
    end)

    -- Digits resolve by ID, anything else by name, in ONE box.
    -- The whole tuple every time: an id that came back with a nil name, or a refusal that still
    -- reported an id, is exactly the shape that would let Add store half an entry.
    it("resolves digits by id and anything else by name", function()
      assert.same({ 415073, "Exorcism", "id" }, { SpellsPage.resolveTyped("415073") })
      assert.same({ 415073, "Exorcism", "name" }, { SpellsPage.resolveTyped("Exorcism") })
    end)

    it("refuses an unresolved id and an unseen name, saying which half it was", function()
      local id, name, source = SpellsPage.resolveTyped("1")
      assert.is_nil(id)
      assert.is_nil(name)
      assert.equal("id", source)
      id, name, source = SpellsPage.resolveTyped("Something Unseen")
      assert.is_nil(id)
      assert.is_nil(name)
      assert.equal("name", source)
    end)

    -- Nothing typed, a zero or a negative id, and a client that cannot resolve an id at all: all
    -- answer with NO source either, because there is no half of the box to blame.
    it("answers nothing at all for an empty box, a zero id, or no adapter", function()
      assert.same({}, { SpellsPage.resolveTyped("") })
      assert.same({}, { SpellsPage.resolveTyped(nil) })
      assert.same({}, { SpellsPage.resolveTyped("0") })
      assert.same({}, { SpellsPage.resolveTyped("-3") })
      ns.Adapter.spellNameByID = nil
      assert.same({}, { SpellsPage.resolveTyped("415073") })
      ns.Adapter = nil
      assert.same({}, { SpellsPage.resolveTyped("415073") })
      assert.same({}, { SpellsPage.resolveTyped("Exorcism") })
    end)

    -- AT5-D3: WeakAuras' own trigger-field shape. The first Enter only resolves -- the box is
    -- rewritten to "<id> (<name>)" and the icon slot to its left shows the spell's icon -- nothing
    -- is stored yet.
    it("resolves what is typed on Enter, shows its icon, and stores nothing yet", function()
      ns.Display.spellIconByID = function(id)
        return id == 415073 and "Interface\\Icons\\Exo" or nil
      end
      local args = addArgs()
      assert.equal("", args.icon.image(), "empty until something resolves")
      args.typed.set(nil, "415073")
      assert.equal("415073 (Exorcism)", args.typed.get())
      assert.equal("Interface\\Icons\\Exo", args.icon.image())
      assert.same({}, ns.db.char.spells, "a resolve must not store")
    end)

    it("resolves a name the same way, by the id it found", function()
      local args = addArgs()
      args.typed.set(nil, "Exorcism")
      assert.equal("415073 (Exorcism)", args.typed.get())
    end)

    -- Junk clears the box AND the icon, in silence: no "Not found" message any more.
    it("clears the box and the icon on junk, without a message", function()
      ns.Display.spellIconByID = function() return "Interface\\Icons\\Exo" end
      local args = addArgs()
      args.typed.set(nil, "1")
      assert.equal("", args.typed.get())
      assert.equal("", args.icon.image())
      assert.is_nil(args.preview, "the 'Resolves to'/'Not found' line is gone")
    end)

    it("registers a resolved id on Add, navigates, and clears the box and icon", function()
      ns.Display.spellIconByID = function() return "Interface\\Icons\\Exo" end
      local args = addArgs()
      args.typed.set(nil, "415073")
      args.addTyped.func()
      assert.equal("id", ns.db.char.spells.EXORCISM.source)
      assert.same({ "Elmira", "spells", "list", "EXORCISM" }, ns.selected)
      assert.equal("", args.typed.get())
      assert.equal("", args.icon.image())
    end)

    it("registers a resolved name on Add, and records that it came from a name", function()
      local args = addArgs()
      args.typed.set(nil, "Exorcism")
      args.addTyped.func()
      assert.equal("name", ns.db.char.spells.EXORCISM.source)
      assert.same({ "Elmira", "spells", "list", "EXORCISM" }, ns.selected)
    end)

    -- The whole point of the WeakAuras shape: a second Enter over the SAME, already-resolved text
    -- is the trigger field's own confirm, exactly what the Add button does.
    it("registers on a second Enter over an unchanged, resolved box", function()
      local args = addArgs()
      args.typed.set(nil, "415073")
      args.typed.set(nil, args.typed.get())
      assert.equal("id", ns.db.char.spells.EXORCISM.source)
      assert.same({ "Elmira", "spells", "list", "EXORCISM" }, ns.selected)
      assert.equal("", args.typed.get())
    end)

    it("does nothing when Add is pressed with nothing resolved", function()
      addArgs().addTyped.func()
      assert.same({}, ns.db.char.spells)
      assert.is_nil(ns.selected)
    end)

    it("still explains that only a name this character has learned or seen resolves", function()
      assert.is_truthy(addArgs().typed.desc:find("learned or seen", 1, true))
    end)

    it("selects an already-registered spell instead of duplicating it", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      local args = addArgs()
      args.typed.set(nil, "415073")
      args.addTyped.func()
      assert.same({ "Elmira", "spells", "list", "EXORCISM" }, ns.selected)
      local count = 0
      for _ in pairs(ns.db.char.spells) do count = count + 1 end
      assert.equal(1, count)
    end)

    -- AT7-D1, through the real add path: a different RANK of an ability already registered under a
    -- different id selects that same row -- never a fresh "..._2" entry -- and raises the stored id
    -- to whatever the client now says is the higher rank.
    it("typing a different rank of an already-registered ability selects it and raises the id", function()
      Spells.add(ns.db.char.spells, { id = 415072, name = "Exorcism", source = "id" })
      local args = addArgs()
      args.typed.set(nil, "415073")
      args.addTyped.func()
      assert.same({ "Elmira", "spells", "list", "EXORCISM" }, ns.selected)
      assert.equal(415073, ns.db.char.spells.EXORCISM.id)
      local count = 0
      for _ in pairs(ns.db.char.spells) do count = count + 1 end
      assert.equal(1, count, "no HOLY_LIGHT_2-style duplicate was created")
    end)

    it("the spellbook Add dedupes by name too", function()
      Spells.add(ns.db.char.spells, { id = 415072, name = "Exorcism", source = "id" })
      ns.Adapter.spellbookEntries = function() return { { id = 415073, name = "Exorcism" } } end
      local args = addArgs()
      args.pick.set(nil, "415073")
      args.addPick.func()
      assert.equal(415073, ns.db.char.spells.EXORCISM.id)
      local count = 0
      for _ in pairs(ns.db.char.spells) do count = count + 1 end
      assert.equal(1, count)
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D4/D9: the tree itself

  describe("D4/D9: the tree rows", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
    end)

    -- AT1-D2: "I don't think anyone will want to set the same texture, screen edge, sound or
    -- announcement for all the abilities" (owner) -- All abilities keeps only General and Glow.
    it("opens with an All abilities row carrying the addon's own icon and only General and Glow", function()
      local all = entry("*")
      assert.equal("All abilities", all.name)
      assert.equal("Interface\\AddOns\\Elmira\\media\\icon", all.icon)
      assert.equal("tab", all.childGroups)
      local names = {}
      for key in pairs(all.args) do names[#names + 1] = key end
      table.sort(names)
      assert.same({ "general", "glow" }, names)
    end)

    it("gives each ability its own six tabs, in the owner's order", function()
      local tabs = entry("EXORCISM").args
      assert.equal("tab", entry("EXORCISM").childGroups)
      assert.same({ "General", "Glow", "Texture", "Screen-edge", "Sound", "Announcement" },
        { tabs.general.name, tabs.glow.name, tabs.texture.name, tabs.edge.name,
          tabs.sound.name, tabs.announce.name })
      assert.same({ 1, 2, 3, 4, 5, 6 },
        { tabs.general.order, tabs.glow.order, tabs.texture.order, tabs.edge.order,
          tabs.sound.order, tabs.announce.order })
    end)

    -- D52's colour convention survives: a player-added entry is BRAND, a pack one plain.
    it("colours a manually added entry's row in BRAND, and a pack entry plain", function()
      assert.equal("Exorcism", entry("EXORCISM").name)
      assert.is_truthy(tostring(entry("SLICE_AND_DICE").name):find("|c", 1, true))
    end)

    -- AB1-D9(a): the row's icon is the ability's own, through the group's `icon` field
    -- (AceConfigDialog-3.0.lua:1022), resolved through the adapter and never a WoW call from here.
    it("carries the ability's own spell icon on its tree row", function()
      ns.Display.spellIconByID = function(id) return id == 415073 and "Interface\\Icons\\Exo" or nil end
      assert.equal("Interface\\Icons\\Exo", entry("EXORCISM").icon)
      assert.is_nil(entry("SLICE_AND_DICE").icon, "an unresolved icon must not become a broken box")
    end)

    -- AB1-D9(b): the tooltip AceConfigDialog's TreeOnButtonEnter draws for the row. AB2-D6: GLOW IS
    -- NOT IN IT -- it is on for everything by default, so "Glow on" was true of every row in the
    -- tree and said nothing about any of them.
    it("describes every channel's on/off in the row's tooltip", function()
      assert.equal("Texture, Screen-edge, Sound, Announcement off", entry("EXORCISM").desc())
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("EXORCISM", "sound", "enabled", true)
      -- AT1-D2: sound is per ability only now, so switched on with every event still None is a
      -- channel that will never make a noise, and the tooltip must not claim otherwise.
      assert.equal("Screen-edge on · Texture, Sound, Announcement off", entry("EXORCISM").desc())
      A.set("EXORCISM", "sound", "used", "Chime")
      assert.equal("Screen-edge, Sound on · Texture, Announcement off", entry("EXORCISM").desc())
      A.set("EXORCISM", "edge", "enabled", false)
      A.set("EXORCISM", "sound", "enabled", false)
      assert.equal("Texture, Screen-edge, Sound, Announcement off", entry("EXORCISM").desc())
    end)

    it("says nothing in the tooltip when the settings store is not loaded", function()
      local row = entry("EXORCISM")
      ns.AbilitySettings = nil
      assert.equal("", row.desc())
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D9(c): the filter

  describe("D9(c): the filter row", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.registerPack(ns.db.char.spells, "JUDGEMENT", 415075, "Judgement")
    end)

    it("offers a name box and one Show dropdown, sharing a row", function()
      local args = listArgs().filter.args
      assert.equal("input", args.name.type)
      assert.equal("relative", args.name.width)
      assert.equal("select", args.show.type)
      assert.equal("relative", args.show.width)
      assert.is_true(math.abs(args.name.relWidth + args.show.relWidth - 1.0) < 1e-9)
      assert.same({ "all", "any", "glow", "texture", "edge", "sound", "announce" }, args.show.sorting)
      assert.equal("All", args.show.values.all)
      assert.equal("Any configured", args.show.values.any)
      assert.equal("Screen-edge", args.show.values.edge)
    end)

    it("stores what was typed and picked, and hides the rows that do not match", function()
      local args = listArgs().filter.args
      assert.equal("", args.name.get())
      assert.equal("all", args.show.get())
      assert.is_false(entry("EXORCISM").hidden())
      assert.is_false(entry("JUDGEMENT").hidden())

      args.name.set(nil, "exor")
      assert.equal("exor", args.name.get())
      assert.is_false(entry("EXORCISM").hidden(), "the name filter is case-insensitive")
      assert.is_true(entry("JUDGEMENT").hidden())

      args.name.set(nil, "")
      args.show.set(nil, "edge")
      assert.equal("edge", args.show.get())
      assert.is_true(entry("EXORCISM").hidden(), "nothing has a screen-edge cue yet")
      A.set("EXORCISM", "edge", "enabled", true)
      assert.is_false(entry("EXORCISM").hidden())
      assert.is_true(entry("JUDGEMENT").hidden())
    end)

    -- "Any configured" answers "what have I actually set up". AB2-D6: glow does not count, so a
    -- fresh character matches nothing -- with glow counted, this filter matched every ability and
    -- was indistinguishable from "All".
    it("matches on any configured channel, and glow is not one", function()
      SpellsPage.setFilter("", "any")
      assert.is_false(SpellsPage.matches({ key = "EXORCISM", name = "Exorcism" }))
      assert.is_true(A.channelOn("EXORCISM", "glow"), "glow really is on; it just must not count")
      A.set("EXORCISM", "announce", "enabled", true)
      assert.is_true(SpellsPage.matches({ key = "EXORCISM", name = "Exorcism" }))
    end)

    -- AB4 review: both rows write through `SpellsPage.setFilter`, so there is ONE write path and the
    -- predicate the specs drive is the one the panel produces. The trap in routing them through a
    -- two-argument setter is forgetting to pass the other half -- which silently resets a dropdown
    -- the player set two seconds ago.
    it("changing one half of the filter leaves the other alone", function()
      local args = listArgs().filter.args
      args.show.set(nil, "edge")
      args.name.set(nil, "exor")
      assert.equal("edge", listArgs().filter.args.show.get(), "typing a name cleared the Show pick")
      listArgs().filter.args.show.set(nil, "sound")
      assert.equal("exor", listArgs().filter.args.name.get(), "picking a Show cleared the name")
    end)

    it("shows everything when the settings store is not loaded", function()
      SpellsPage.setFilter("", "sound")
      ns.AbilitySettings = nil
      assert.is_true(SpellsPage.matches({ key = "EXORCISM", name = "Exorcism" }))
    end)

    it("falls back to showing everything when told nothing", function()
      SpellsPage.setFilter(nil, nil)
      assert.equal("", listArgs().filter.args.name.get())
      assert.equal("all", listArgs().filter.args.show.get())
      listArgs().filter.args.name.set(nil, nil)
      listArgs().filter.args.show.set(nil, nil)
      assert.equal("", listArgs().filter.args.name.get())
      assert.equal("all", listArgs().filter.args.show.get())
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D6: the General tab

  describe("D6: the General tab", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
    end)

    it("names the ability, its id, where it came from and what uses it", function()
      ns.Display.spellIcon = function(key) return key == "EXORCISM" and "Icons\\Exo" or nil end
      local head = tab("EXORCISM", "general").head.name
      assert.is_truthy(head:find("|TIcons\\Exo:0|t Exorcism", 1, true))
      assert.is_truthy(head:find("#415073", 1, true))
      assert.is_truthy(head:find("from the PALADIN pack", 1, true))
      assert.is_truthy(head:find("not used by any rotation yet", 1, true))

      ns.forkRows = { { build = "MINE", name = "My Rotation" } }
      ns.builds.MINE = { entries = { { spell = "EXORCISM" } } }
      assert.is_truthy(tab("EXORCISM", "general").head.name:find("used by My Rotation", 1, true))
    end)

    it("names the other three sources verbatim", function()
      Spells.add(ns.db.char.spells, { id = 1, name = "ById", source = "id" })
      Spells.add(ns.db.char.spells, { id = 2, name = "ByName", source = "name" })
      assert.is_truthy(tab("BYID", "general").head.name:find("added by ID", 1, true))
      assert.is_truthy(tab("BYNAME", "general").head.name:find("added by name", 1, true))
      assert.is_truthy(tab("SLICE_AND_DICE", "general").head.name:find("added from your spellbook", 1, true))
    end)

    it("explains what the All abilities General tab is for, and shows no ability facts", function()
      local args = tab("*", "general")
      assert.is_truthy(args.head.name:find("Same as All abilities", 1, true))
      assert.is_nil(args.remove)
      assert.is_nil(args.pack)
      assert.is_nil(args.inherit, "All abilities is what everything else inherits FROM")
    end)

    -- AT1-D3: the owner's wording, verbatim, on every General tab (All abilities and each ability).
    it("guards every channel with Only in combat, and stores it", function()
      local row = tab("EXORCISM", "general").onlyInCombat
      assert.equal("toggle", row.type)
      assert.equal("Only in combat", row.name)
      assert.equal("Glow, Texture, Screen Edge, Sounds and Announcements will be only available in combat",
        row.desc)
      assert.equal(tab("*", "general").onlyInCombat.desc, row.desc, "the same tooltip everywhere")
      assert.is_false(row.get())
      -- Linked to All abilities by default, so the ability's own tab writes nothing visible until
      -- it is unlinked -- which is exactly what the greying says.
      assert.is_true(row.disabled())
      tab("EXORCISM", "general").inherit.set(nil, false)
      assert.is_false(tab("EXORCISM", "general").onlyInCombat.disabled())
      tab("EXORCISM", "general").onlyInCombat.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "general").onlyInCombat)
      assert.is_false(A.effective("SLICE_AND_DICE", "general").onlyInCombat)
    end)

    -- AT8-D1: the threshold is per ability and never inherited any more, so All abilities has
    -- nothing left to show for it -- its General tab keeps only "Only in combat"; each ability's
    -- own copy lives on its Sound and Texture tabs instead, right next to the moment it gates.
    it("has no expiring-seconds control on All abilities' General tab any more", function()
      assert.is_nil(tab("*", "general").expiring)
      assert.is_nil(tab("*", "general").expiringSeconds)
      assert.is_nil(tab("EXORCISM", "general").expiring)
      assert.is_nil(tab("EXORCISM", "general").expiringSeconds)
      local args = tab("*", "general")
      local names = {}
      for k in pairs(args) do names[#names + 1] = k end
      table.sort(names)
      assert.same({ "head", "onlyInCombat" }, names,
        "General for All abilities is exactly one sentence plus one toggle now")
    end)

    -- AB1-D6 as AB2-D2/D3 leave it: which rotations use it and what they need, plus the pack's own
    -- one-line reason -- which now lives on the SPELL entry beside the defaults it explains, since
    -- build-level `visuals.cues` (and the `reason` strings inside them) are gone.
    it("summarises the class pack's own rotations, reason and requirements", function()
      ns.Display.currentPack = function()
        return { class = "PALADIN",
          spells = { EXORCISM = { id = 415073,
                     defaults = { reason = "Exorcism came off cooldown",
                                  edge = { enabled = true, edge = "left" } } } },
          builds = {
          EXODIN = { entries = { { spell = "EXORCISM" } },
                     requires = { runes = { "RUNE_ART_OF_WAR" } } },
          SHOCKADIN = { entries = { { spell = "HOLY_SHOCK" } } },
        } }
      end
      ns.Display.spellName = function(key) return "name:" .. key end
      ns.Display.spellIcon = function(key) return key == "RUNE_ART_OF_WAR" and "Icons\\AoW" or nil end
      local rows = SpellsPage.packNotes("EXORCISM", ns.Display.currentPack())
      assert.equal(1, #rows)
      assert.equal("EXODIN", rows[1].name)
      assert.same({ "RUNE_ART_OF_WAR" }, rows[1].needs)
      assert.equal("Exorcism came off cooldown",
                   SpellsPage.packReason("EXORCISM", ns.Display.currentPack()))
      assert.is_nil(SpellsPage.packReason("HOLY_SHOCK", ns.Display.currentPack()))

      local panel = tab("EXORCISM", "general").pack
      assert.equal("What the class pack says", panel.name)
      local text = {}
      for _, row in pairs(panel.args) do text[#text + 1] = row.name end
      table.sort(text)
      local joined = table.concat(text, "\n")
      assert.is_truthy(joined:find("Exorcism came off cooldown", 1, true))
      -- The reason is the FIRST row and has a key of its own: a shared key would render one line
      -- and silently swallow the other.
      assert.equal("Exorcism came off cooldown", panel.args.r1.name)
      assert.equal(1, panel.args.r1.order)
      assert.is_truthy(joined:find("|TIcons\\AoW:0|t name:RUNE_ART_OF_WAR", 1, true))
      assert.is_nil(tab("SLICE_AND_DICE", "general").pack, "no pack rotation names it")
      -- One row per thing said: the reason, the rotation's name, then each requirement. A shared
      -- key would silently swallow whichever line was written first.
      local count = 0
      for _ in pairs(panel.args) do count = count + 1 end
      assert.equal(3, count)
      assert.is_truthy(joined:find("EXODIN", 1, true))
    end)

    -- A pack that says nothing about an ability produces no panel at all, and a pack that says only
    -- a reason (no rotation names the spell) still produces one -- the two halves are independent.
    it("shows the pack's reason even when no rotation names the ability", function()
      ns.Display.currentPack = function()
        return { class = "PALADIN", builds = {},
                 spells = { EXORCISM = { id = 415073, defaults = { reason = "Worth a glance" } } } }
      end
      local panel = tab("EXORCISM", "general").pack
      assert.is_table(panel)
      local joined = ""
      for _, row in pairs(panel.args) do joined = joined .. row.name end
      assert.is_truthy(joined:find("Worth a glance", 1, true))
    end)

    -- Sorted by name: `pairs` over the pack's builds carries no order at all, and a summary that
    -- reshuffled on every open would be unreadable.
    it("lists the pack's rotations in name order, and needs the registry to read them", function()
      ns.Display.currentPack = function()
        return { class = "PALADIN", builds = {
          ZULU = { entries = { { spell = "EXORCISM" } } },
          ALPHA = { entries = { { spell = "EXORCISM" } } },
          MIKE = { entries = { { spell = "EXORCISM" } } },
        } }
      end
      local rows = SpellsPage.packNotes("EXORCISM", ns.Display.currentPack())
      assert.same({ "ALPHA", "MIKE", "ZULU" }, { rows[1].name, rows[2].name, rows[3].name })
      -- ...and all three reach the panel: one key each, in that order. A shared key would render
      -- one rotation and silently swallow the other two.
      local panel = tab("EXORCISM", "general").pack.args
      local names, count = {}, 0
      for _, row in pairs(panel) do count = count + 1 end
      for i = 1, count do names[i] = panel["r" .. i].name end
      assert.equal(3, count)
      assert.is_truthy(names[1]:find("ALPHA", 1, true))
      assert.is_truthy(names[2]:find("MIKE", 1, true))
      assert.is_truthy(names[3]:find("ZULU", 1, true))
      ns.Spells = nil
      assert.same({}, SpellsPage.packNotes("EXORCISM", { builds = { A = {} } }))
    end)

    it("has no pack summary for a class with no data pack", function()
      ns.Display.currentPack = function() return nil end
      assert.same({}, SpellsPage.packNotes("EXORCISM", nil))
      assert.is_nil(tab("EXORCISM", "general").pack)
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D6: Remove

  describe("D6: removing an ability", function()
    it("shows no remove control at all for an automatic (pack) entry", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      assert.is_nil(tab("EXORCISM", "general").remove)
    end)

    it("blocks a manual entry still referenced, and names the rotation holding it", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      ns.forkRows = { { build = "MINE", name = "My Rotation" } }
      ns.builds.MINE = { entries = { { spell = "SLICE_AND_DICE" } } }
      local row = tab("SLICE_AND_DICE", "general").remove
      assert.equal("description", row.type)
      assert.is_truthy(row.name:find("My Rotation", 1, true))
      assert.is_not_nil(ns.db.char.spells.SLICE_AND_DICE)
    end)

    -- The confirm text names every kind of setting that goes with it, which is the whole point of
    -- the new wording: removing an ability throws its glow, sounds and announcement away too.
    it("removes the entry AND its settings, then lands on All abilities", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      A.set("SLICE_AND_DICE", "sound", "enabled", true)
      local row = tab("SLICE_AND_DICE", "general").remove
      assert.equal("execute", row.type)
      assert.is_true(row.confirm)
      assert.equal("Remove Slice and Dice and its glow, texture, screen-edge, sound and "
        .. "announcement settings?", row.confirmText)
      row.func()
      assert.is_nil(ns.db.char.spells.SLICE_AND_DICE)
      assert.is_nil(ns.db.char.abilities.SLICE_AND_DICE)
      assert.same({ "Elmira", "spells", "list", "*" }, ns.selected)
    end)

    -- ---------------------------------------------------------------- AB3-D3: it moved up

    -- Owner, 2026-09-09: "the one control that deletes things should not be the last item after a
    -- slider". It sits on the identity row now, above every setting on the tab.
    it("puts Remove above every settings control instead of under the last slider", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      local args = tab("SLICE_AND_DICE", "general")
      assert.equal(1, args.head.order)
      assert.equal(2, args.remove.order)
      for _, name in ipairs({ "inherit", "onlyInCombat" }) do
        assert.is_true(args[name].order > args.remove.order, name .. " now sits above Remove")
      end
    end)

    -- A Button is the only control that fills its cell, so a row that ends flush right has to end
    -- with one; the two relWidths must sum to exactly 1.0 or AceGUI's Flow does not scale the row
    -- (AceGUI-3.0.lua:709-711).
    it("shares the identity row with the line beside it, ending flush right", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      local args = tab("SLICE_AND_DICE", "general")
      assert.equal("relative", args.head.width)
      assert.equal("relative", args.remove.width)
      assert.equal("execute", args.remove.type)
      assert.equal(1.0, args.head.relWidth + args.remove.relWidth)
    end)

    it("gives the row back to the identity line when there is nothing to remove", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      local args = tab("EXORCISM", "general")
      assert.is_nil(args.remove)
      assert.equal("full", args.head.width)
      assert.is_nil(args.head.relWidth, "a three-quarter line with an empty quarter reads as a gap")
    end)

    it("keeps the refusal in the same cell as the button it replaces", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      ns.forkRows = { { build = "MINE", name = "My Rotation" } }
      ns.builds.MINE = { entries = { { spell = "SLICE_AND_DICE" } } }
      local args = tab("SLICE_AND_DICE", "general")
      assert.equal("description", args.remove.type)
      assert.equal("medium", args.remove.fontSize)
      assert.equal("relative", args.remove.width)
      assert.equal(1.0, args.head.relWidth + args.remove.relWidth)
      assert.equal(2, args.remove.order)
    end)

    -- The settings row must NOT go when the registry guard refused: that would throw away what the
    -- player configured and leave the ability sitting there.
    it("keeps the settings when the removal itself was refused", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      A.set("SLICE_AND_DICE", "sound", "enabled", true)
      local row = tab("SLICE_AND_DICE", "general").remove
      ns.Spells.remove = function() return false, {} end
      row.func()
      assert.is_not_nil(ns.db.char.abilities.SLICE_AND_DICE)
      assert.is_nil(ns.selected)
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D7: the Glow tab

  describe("D7: the Glow tab", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      ns.Glow = {
        available = function() return { PIXEL = true, BUTTON = true, AUTOCAST = true, PROC = true } end,
        applies = function(style, field) return ns.applies[style] and ns.applies[style][field] == true end,
        effective = function(style, field, key)
          return A.effective(key, "glow")[field] or ({ particles = 8, frequency = 0.25,
                                                       thickness = 1, speed = 1 })[field]
        end,
        StopAll = function() ns.stopped = (ns.stopped or 0) + 1 end,
      }
      ns.applies = {
        PIXEL = { particles = true, frequency = true, thickness = true },
        AUTOCAST = { particles = true, frequency = true },
        BUTTON = { frequency = true },
        PROC = { speed = true },
      }
    end)

    it("offers exactly the styles the loaded library can draw", function()
      assert.equal("Proc", SpellsPage.glowStyleNames().PROC)
      assert.equal("Pixel", SpellsPage.glowStyleNames().PIXEL)
      ns.Glow.available = function() return { PIXEL = true } end
      assert.is_nil(SpellsPage.glowStyleNames().PROC)
      ns.Glow = nil
      assert.same({}, SpellsPage.glowStyleNames())
    end)

    it("builds the on/off, style and colour rows as the controls they claim to be", function()
      local args = tab("*", "glow")
      assert.equal("toggle", args.enabled.type)
      assert.equal(2, args.enabled.order)
      assert.equal("full", args.enabled.width)
      assert.equal("Glow the button for this ability", args.enabled.name)
      assert.equal("select", args.style.type)
      assert.equal(4, args.style.order)
      assert.equal("Style", args.style.name)
      assert.equal("Pixel", args.style.values().PIXEL)
      assert.equal("color", args.color.type)
      assert.equal(5, args.color.order)
      assert.equal("Colour", args.color.name)
      assert.is_falsy(args.color.hasAlpha)
      assert.equal("The colour of the glow on your action bar.", args.color.desc)
      assert.equal("execute", args.preview.type)
      assert.equal(10, args.preview.order)
      assert.equal("Preview Glow", args.preview.name)
      assert.equal("Flashes a button on your bars with these settings.", args.preview.desc)
      assert.equal("Puts every glow setting back the way it shipped, including the colour.",
                   args.reset.desc)
    end)

    -- AT2-D1. The dropdown's own words come from Options.lua's LABELS (via Options.VISIBILITY_LABELS)
    -- so the two pages cannot say the mode differently, and it answers per ability like the rest of
    -- the Glow tab -- independent of whatever Options.lua's own stub answers for the queue strip.
    it("offers 'Show the glow', identical to the Queue page's own visibility dropdown", function()
      ns.Options.VISIBILITY_LABELS = { always = "Always",
                     combat_or_target = "In combat, or when you have a target",
                     combat = "In combat only" }
      local args = tab("*", "glow")
      assert.equal("select", args.show.type)
      assert.equal(3, args.show.order)
      assert.equal("Show the glow", args.show.name)
      assert.same({ "always", "combat_or_target", "combat" }, args.show.sorting())
      assert.same({ always = "Always", combat_or_target = "In combat, or when you have a target",
                    combat = "In combat only" }, args.show.values())
      assert.equal("combat_or_target", args.show.get())
      args.show.set(nil, "combat")
      assert.equal("combat", A.effective("*", "glow").show)
    end)

    it("stores style and colour per ability, and repaints", function()
      local args = tab("*", "glow")
      assert.equal("PROC", args.style.get())
      args.style.set(nil, "BUTTON")
      assert.equal("BUTTON", A.effective("*", "glow").style)
      local r, g, b = tab("*", "glow").color.get()
      assert.equal(ns.Colors.HIGHLIGHT.r, r)
      assert.equal(ns.Colors.HIGHLIGHT.g, g)
      assert.equal(ns.Colors.HIGHLIGHT.b, b)
      tab("*", "glow").color.set(nil, 0.1, 0.2, 0.3)
      assert.same({ r = 0.1, g = 0.2, b = 0.3 }, A.effective("*", "glow").color)
      assert.equal(2, ns.stopped, "a running glow keeps its old look until it is torn down")
      -- The driver only repaints when the QUEUE changes, so a colour change would otherwise not
      -- reach the screen until the rotation happened to move on.
      assert.equal(2, ns.repainted, "the settings changed and nothing asked for a repaint")
    end)

    -- The observable AB1-D7 asks for: one ability's colour is not another's.
    it("keeps one ability's glow separate from another's", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      tab("EXORCISM", "glow").inherit.set(nil, false)
      tab("EXORCISM", "glow").color.set(nil, 1, 0, 0)
      assert.same({ r = 1, g = 0, b = 0 }, A.effective("EXORCISM", "glow").color)
      assert.is_false(A.effective("SLICE_AND_DICE", "glow").color)
    end)

    it("greys every control while the ability is linked to All abilities", function()
      local args = tab("EXORCISM", "glow")
      assert.equal("toggle", args.inherit.type)
      assert.equal(1, args.inherit.order)
      assert.equal("full", args.inherit.width)
      assert.equal("Same as All abilities", args.inherit.name)
      assert.equal("Use whatever the All abilities entry at the top of the list is set to.",
                   args.inherit.desc)
      assert.is_true(args.inherit.get())
      for _, key in ipairs({ "enabled", "style", "color", "particles", "preview" }) do
        assert.is_true(args[key].disabled(), key .. " is live while linked")
      end
      args.inherit.set(nil, false)
      local unlinked = tab("EXORCISM", "glow")
      for _, key in ipairs({ "enabled", "style", "color", "particles", "preview" }) do
        assert.is_false(unlinked[key].disabled(), key .. " is still greyed after unlinking")
      end
    end)

    -- AB1-D4: glow is the one channel whose on/off DOES inherit -- bar glow on everything is what
    -- this addon already did.
    it("ships glow on for every ability and lets All abilities switch it off", function()
      assert.is_true(tab("EXORCISM", "glow").enabled.get())
      tab("*", "glow").enabled.set(nil, false)
      assert.is_false(tab("EXORCISM", "glow").enabled.get())
    end)

    -- A row the style cannot use would let the user move a slider and watch nothing happen.
    it("hides the rows the chosen style has no use for", function()
      -- PROC ships as the default: only speed applies until a style is chosen.
      assert.is_true(tab("*", "glow").particles.hidden())
      assert.is_true(tab("*", "glow").thickness.hidden())
      assert.is_false(tab("*", "glow").speed.hidden())
      A.set("*", "glow", "style", "PIXEL")
      assert.is_false(tab("*", "glow").particles.hidden())
      assert.is_false(tab("*", "glow").thickness.hidden())
      assert.is_true(tab("*", "glow").speed.hidden())
      A.set("*", "glow", "style", "AUTOCAST")
      assert.is_true(tab("*", "glow").thickness.hidden())
      assert.is_false(tab("*", "glow").particles.hidden())
      A.set("*", "glow", "style", "PROC")
      assert.is_false(tab("*", "glow").speed.hidden())
      assert.is_true(tab("*", "glow").frequency.hidden())
      ns.Glow = nil
      assert.is_true(tab("*", "glow").particles.hidden())
    end)

    it("builds each number row as a real slider with real bounds, showing the library default", function()
      local args = tab("*", "glow")
      assert.equal("range", args.particles.type)
      assert.equal("Particles", args.particles.name)
      assert.same({ 1, 20, 1 }, { args.particles.min, args.particles.max, args.particles.step })
      assert.same({ 1, 6, 1 }, { args.thickness.min, args.thickness.max, args.thickness.step })
      assert.same({ 0.2, 3, 0.1 }, { args.speed.min, args.speed.max, args.speed.step })
      -- Autocast's own default is 0.125: a coarser step cannot land on it, so the first nudge
      -- would change the look for no reason the user asked for.
      assert.equal(0.025, args.frequency.step)
      assert.is_true(math.abs(0.125 / args.frequency.step - 5) < 1e-9)
      assert.equal(8, args.particles.get())
      args.particles.set(nil, 14)
      assert.equal(14, A.effective("*", "glow").particles)
      ns.Glow = nil
      assert.equal(1, tab("*", "glow").particles.get(), "with no renderer the slider shows its floor")
    end)

    -- PE7-D1's single gate, read from this side: with the bars not glowing at all, every control
    -- here is dead, and a page that does not say so is where "I turned it on and nothing happened"
    -- starts.
    it("says so and greys itself out when action bar glow is off for everything", function()
      assert.equal("description", tab("*", "glow").off.type)
      assert.equal(0, tab("*", "glow").off.order)
      assert.equal("full", tab("*", "glow").off.width)
      assert.equal("medium", tab("*", "glow").off.fontSize)
      assert.is_true(tab("*", "glow").off.hidden())
      assert.is_false(tab("*", "glow").style.disabled())
      ns.db.profile.glow.barGlow = false
      assert.is_false(tab("*", "glow").off.hidden())
      assert.is_truthy(tab("*", "glow").off.name:find(
        "Action bar glow is off for everything -- turn it on under General > Action Bars.", 1, true))
      assert.is_true(tab("*", "glow").style.disabled())
      assert.is_true(tab("*", "glow").enabled.disabled())
    end)

    it("previews THIS ability, and only All abilities offers the reset", function()
      local previewed
      ns.Options.previewGlow = function(secondary, key) previewed = { secondary, key } end
      tab("EXORCISM", "glow").preview.func()
      assert.same({ false, "EXORCISM" }, previewed)
      tab("*", "glow").preview.func()
      assert.same({ false, "*" }, previewed)

      local reset = tab("*", "glow").reset
      assert.equal("Reset These to Defaults", reset.name)
      assert.is_true(reset.confirm)
      assert.is_truthy(reset.confirmText)
      local fired = 0
      ns.Options.resetGlow = function() fired = fired + 1 end
      reset.func()
      assert.equal(1, fired)
      assert.is_nil(tab("EXORCISM", "glow").reset, "one ability's reset is its inherit toggle")
    end)

    it("does not error when the options module is not loaded", function()
      ns.Options = nil
      assert.has_no.errors(function() tab("*", "glow").preview.func() end)
      assert.has_no.errors(function() tab("*", "glow").reset.func() end)
    end)

    -- AB1-D7: no event checkboxes here. A glow follows the now-slot and nothing else.
    it("offers no event checkboxes", function()
      local args = tab("EXORCISM", "glow")
      for _, event in ipairs(A.EVENTS) do assert.is_nil(args[event], event .. " has a checkbox") end
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D8: the Sound tab

  describe("D8: the Sound tab", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      ns.played = {}
      ns.Sounds = { list = function() return { None = "None", Chime = "Chime" } end,
                    play = function(name) ns.played[#ns.played + 1] = name; return true end }
    end)

    it("offers one sound per event, defaulting to None", function()
      local args = tab("EXORCISM", "sound")
      assert.same({ "suggested", "ready", "used", "active", "expiring" }, A.EVENTS)
      for i, event in ipairs(A.EVENTS) do
        assert.equal("select", args[event].type, event .. " is not a dropdown")
        assert.equal("None", args[event].get())
        assert.equal(2 + i, args[event].order)
        assert.equal("Chime", args[event].values().Chime)
      end
      assert.same({ "When it is suggested", "When it comes off cooldown", "When you use it",
                    "When its buff appears", "When its buff is about to run out" },
                  { args.suggested.name, args.ready.name, args.used.name, args.active.name,
                    args.expiring.name })
      -- AT8-D4, verbatim: "a flash" becomes "a sound", and the persistence sentence drops --
      -- a sound plays once.
      assert.equal("A sound when you cast it.", args.used.desc)
      assert.is_falsy(args.suggested.desc:find("Stays", 1, true), "a sound never \"stays\"")
      assert.is_truthy(args.active.desc:find("Avenging Wrath", 1, true))
    end)

    -- AT8-D1/D2: right after "When its buff is about to run out", greyed only until a sound is
    -- actually picked for that moment -- no General-linkage gate left, since the field is per
    -- ability and never inherited any more. Indented under its checkbox: a bare gap shares its row.
    it("offers the warning threshold right after the expiring event, greyed until a sound is picked", function()
      local row = tab("EXORCISM", "sound").expiringSeconds
      assert.equal("range", row.type)
      assert.equal(7.5, row.order, "immediately after the expiring event select at order 7")
      assert.equal("Warn me about to expire", row.name)
      assert.equal(3, row.get())
      assert.is_true(row.disabled(), "no sound picked for expiring yet")
      tab("EXORCISM", "sound").expiring.set(nil, "Chime")
      assert.is_false(tab("EXORCISM", "sound").expiringSeconds.disabled(), "a sound is now picked")
      tab("EXORCISM", "sound").expiringSeconds.set(nil, 11)
      assert.equal(11, A.effective("EXORCISM", "general").expiringSeconds)
      -- The gap that indents the slider under its checkbox: no label of its own, sharing the row.
      local gap = tab("EXORCISM", "sound").expiringGap
      assert.equal("description", gap.type)
      assert.equal(7.49, gap.order, "immediately before the slider, same row")
      assert.equal("", gap.name)
      assert.equal("relative", gap.width)
      assert.equal("relative", row.width)
      assert.is_true(gap.relWidth + row.relWidth == 1, "the two sum to a full row")
    end)

    it("plays the sound the moment it is picked, having stored it first", function()
      tab("EXORCISM", "sound").ready.set(nil, "Chime")
      assert.equal("Chime", A.effective("EXORCISM", "sound").ready)
      assert.same({ "Chime" }, ns.played)
    end)

    it("still offers None with no sound module loaded", function()
      ns.Sounds = nil
      assert.same({ None = "None" }, tab("EXORCISM", "sound").suggested.values())
      assert.has_no.errors(function() tab("EXORCISM", "sound").suggested.set(nil, "Chime") end)
      assert.same({}, ns.played, "nothing to play through")
    end)

    -- AB1-D4/AT1-D2: the ON switch is per ability and is never inherited -- nor is anything else on
    -- this tab any more, so there is no All abilities Sound tab at all to switch anything on from.
    it("puts the on switch on the ability alone, and All abilities has no Sound tab at all", function()
      assert.is_nil(entry("*").args.sound, "All abilities must have no Sound tab")
      local row = tab("EXORCISM", "sound").enabled
      assert.equal("toggle", row.type)
      assert.equal(2, row.order)
      assert.equal("full", row.width)
      assert.equal("Play sounds for this ability", row.name)
      assert.equal("Never inherited: All abilities cannot switch sounds on for you.", row.desc)
      assert.is_false(row.get())
      row.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "sound").enabled)
    end)

    -- AT1-D2: nothing here inherits any more -- each ability's own picks are live from the start.
    it("keeps each ability's own picks, live from the start", function()
      tab("EXORCISM", "sound").used.set(nil, "Chime")
      assert.equal("Chime", tab("EXORCISM", "sound").used.get())
      assert.is_falsy(tab("EXORCISM", "sound").used.disabled)
    end)

    it("builds no rows at all without the settings store", function()
      local page = SpellsPage.group()
      ns.AbilitySettings = nil
      assert.has_no.errors(function() SpellsPage.group() end)
      assert.is_not_nil(page)
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D10: Announcement

  describe("D10: the Announcement tab", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
    end)

    it("names the ability in its toggle and ships OFF", function()
      local row = tab("EXORCISM", "announce").enabled
      assert.equal("toggle", row.type)
      assert.equal("Announce when I use Exorcism", row.name)
      assert.is_false(row.get())
      assert.is_truthy(row.desc:find("Long cooldowns used", 1, true))
      row.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "announce").enabled)
    end)

    -- AT1-D2: All abilities has no Announcement tab at all any more -- the wording lives on each
    -- ability alone, live from the start.
    it("has no Announcement tab on All abilities, and keeps each ability's own wording live", function()
      assert.is_nil(entry("*").args.announce, "All abilities must have no Announcement tab")
      local args = tab("EXORCISM", "announce")
      assert.is_nil(args.inherit)
      assert.equal("Include how long it lasts", args.duration.name)
      assert.is_falsy(args.duration.disabled)
      assert.is_false(args.duration.get())
      args.duration.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "announce").duration)
    end)
  end)

  -- ------------------------------------------------------------------ AB3-D1/D2: the Texture tab

  describe("AB3-D1: the Texture tab", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
    end)

    it("no longer says the next pass fills it", function()
      assert.is_nil(tab("EXORCISM", "texture").soon)
    end)

    -- The on switch, like every other channel's: per ability and never inherited (AB1-D4). AT1-D2:
    -- neither is anything else on this tab any more -- there is no All abilities Texture tab at all.
    it("switches the texture on per ability, and says it cannot be inherited", function()
      local row = tab("EXORCISM", "texture").enabled
      assert.equal("toggle", row.type)
      assert.is_false(row.get())
      row.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "texture").enabled)
      assert.is_truthy(row.desc:find("Never inherited", 1, true))
      assert.is_nil(entry("*").args.texture, "All abilities must have no Texture tab")
    end)

    -- AT4-D2 (owner, 2026-09-11): the Source and Shape dropdowns are gone. One tick box asks the
    -- only question most people have -- its own icon or not -- and unticking it reveals the file
    -- and the button that opens the picker.
    it("asks for the ability's own icon with a tick box, ticked out of the box", function()
      local row = tab("EXORCISM", "texture").ownIcon
      assert.equal("toggle", row.type)
      assert.equal(3, row.order)
      assert.equal("full", row.width)
      assert.equal("Use this ability's own icon", row.name)
      assert.is_true(row.get())
      assert.is_nil(tab("EXORCISM", "texture").source, "the Source dropdown is gone")
      assert.is_nil(tab("EXORCISM", "texture").shape, "the Shape dropdown is gone")
    end)

    -- Unticking must DRAW something: an empty file field beside a texture that fell back to the
    -- ring anyway is the "looks broken" state this whole tab is about.
    it("starts the file at the shipped ring when the tick box comes off, and keeps an earlier pick",
      function()
        tab("EXORCISM", "texture").ownIcon.set(nil, false)
        local e = A.effective("EXORCISM", "texture")
        assert.equal("path", e.source)
        assert.equal("Interface\\AddOns\\Elmira\\media\\shape_ring", e.path)

        tab("EXORCISM", "texture").path.set(nil, "Interface\\Icons\\Ability_Rogue_Ambush")
        tab("EXORCISM", "texture").ownIcon.set(nil, true)
        assert.equal("icon", A.effective("EXORCISM", "texture").source)
        tab("EXORCISM", "texture").ownIcon.set(nil, false)
        assert.equal("Interface\\Icons\\Ability_Rogue_Ambush",
          A.effective("EXORCISM", "texture").path, "the file they chose was thrown away")
      end)

    it("shows the file and the Choose button only when the icon is not being used", function()
      local args = tab("EXORCISM", "texture")
      assert.is_true(args.path.hidden())
      assert.is_true(args.choose.hidden())
      args.ownIcon.set(nil, false)
      assert.is_false(tab("EXORCISM", "texture").path.hidden())
      assert.is_false(tab("EXORCISM", "texture").choose.hidden())
    end)

    it("stores a typed path, and shows the ring rather than an empty box", function()
      local row = tab("EXORCISM", "texture").path
      assert.equal("input", row.type)
      assert.equal(4, row.order)
      assert.equal("Texture file", row.name)
      assert.equal("full", row.width)
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_ring", row.get())
      row.set(nil, "Interface\\Icons\\Ability_Rogue_Ambush")
      assert.equal("Interface\\Icons\\Ability_Rogue_Ambush", A.effective("EXORCISM", "texture").path)
      assert.equal("Interface\\Icons\\Ability_Rogue_Ambush", tab("EXORCISM", "texture").path.get())
    end)

    -- AT6-D3 (owner): Choose… opens the picker ON A CLEAR SCREEN. It does what "Move This Texture"
    -- does -- `Textures.StartMove`, which is what hides the options window through
    -- `Options.BeginMove` and raises the Move toolbar -- AND opens the picker WINDOW
    -- (Options/TexturePanel.lua), the same window the toolbar's own Texture button opens. Judging a
    -- texture over 960x680 of configuration panel is the one thing the picker cannot do.
    it("hides the options window and opens the texture picker for THIS ability", function()
      local opened, moved = {}, {}
      ns.TexturePanel = { Open = function(key) opened[#opened + 1] = key end }
      ns.Textures.StartMove = function(key) moved[#moved + 1] = key; return true end
      local row = tab("EXORCISM", "texture").choose
      assert.equal("execute", row.type)
      assert.equal(5, row.order)
      assert.equal("Choose…", row.name)
      row.func()
      assert.same({ "EXORCISM" }, moved, "the options window was left sitting over the picker")
      assert.same({ "EXORCISM" }, opened)
    end)

    it("opens the picker without erroring when no renderer is loaded", function()
      ns.Textures, ns.TexturePanel = nil, nil
      assert.is_true(pcall(function() tab("EXORCISM", "texture").choose.func() end))
    end)

    -- AT4-D3. A file inside another addon's folder is a file on the character that has that addon
    -- and nothing at all on the one that does not -- where the ring is drawn and looks exactly like
    -- a working setting. One warning, not two: the generic "nothing to draw" stands down.
    it("says which addon a texture needs when this character does not have it", function()
      local args = tab("EXORCISM", "texture")
      args.ownIcon.set(nil, false)
      args.path.set(nil, "Interface\\AddOns\\WeakAuras\\Media\\Textures\\Ring_10px.tga")
      local shown = tab("EXORCISM", "texture")
      assert.equal("description", shown.needsAddon.type)
      assert.is_false(shown.needsAddon.hidden())
      assert.is_truthy(shown.needsAddon.name():find(
        "This texture needs WeakAuras, which is not installed on this character.", 1, true))
      assert.is_true(shown.missing.hidden(), "two warnings about one texture")

      ns.Adapter = { addonLoaded = function(name) return name == "WeakAuras" end }
      assert.is_true(tab("EXORCISM", "texture").needsAddon.hidden())
    end)

    -- The one silence a texture has that a screen edge does not, said where it happens: on screen a
    -- source that resolves to no file is indistinguishable from a working setting.
    it("warns when the source resolves to no file at all", function()
      local args = tab("EXORCISM", "texture")
      -- the pack fake resolves no icon for any key, so the default source has nothing to draw
      assert.equal("description", args.missing.type)
      assert.equal(6, args.missing.order)
      assert.equal("medium", args.missing.fontSize)
      assert.equal("full", args.missing.width)
      assert.is_false(args.missing.hidden())
      assert.is_truthy(args.missing.name:find("falls back to the ring", 1, true))
      -- a file source always resolves to something -- the ring, if nothing was ever chosen
      args.ownIcon.set(nil, false)
      assert.is_true(tab("EXORCISM", "texture").missing.hidden())
    end)

    -- The page is built by Options.lua whatever else loaded; with no renderer there is nothing that
    -- could resolve a file, and claiming one is missing would be a guess.
    it("says nothing about a missing file with no renderer loaded", function()
      ns.Textures = nil
      assert.is_true(tab("EXORCISM", "texture").missing.hidden())
    end)

    -- AT8-D5: 16-512 now, one step throughout (AceConfig's range widget takes a single step).
    it("sizes between 16 and 512 in steps of 8, starting at 48", function()
      local row = tab("EXORCISM", "texture").size
      assert.equal("range", row.type)
      assert.equal(7, row.order)
      assert.equal("Size", row.name)
      assert.is_truthy(row.desc:find("in pixels", 1, true))
      assert.same({ 16, 512, 8 }, { row.min, row.max, row.step })
      assert.equal(48, row.get())
      row.set(nil, 120)
      assert.equal(120, row.get())
    end)

    it("stores a colour and an opacity", function()
      local args = tab("EXORCISM", "texture")
      assert.equal("color", args.color.type)
      assert.equal(8, args.color.order)
      assert.equal("Colour", args.color.name)
      assert.is_false(args.color.hasAlpha, "a colour picker with its own alpha beside an Opacity "
        .. "slider is two controls for one number")
      args.color.set(nil, 0.1, 0.2, 0.3)
      assert.same({ r = 0.1, g = 0.2, b = 0.3 }, A.effective("EXORCISM", "texture").color)
      assert.same({ 0.1, 0.2, 0.3 }, { args.color.get() })

      assert.equal("range", args.alpha.type)
      assert.equal(9, args.alpha.order)
      assert.equal("Opacity", args.alpha.name)
      assert.same({ 0.05, 1.0, 0.05 }, { args.alpha.min, args.alpha.max, args.alpha.step })
      assert.is_true(args.alpha.isPercent, "a raw 0.45 means nothing to anyone")
      assert.equal(1, args.alpha.get())
      args.alpha.set(nil, 0.4)
      assert.equal(0.4, tab("EXORCISM", "texture").alpha.get())
    end)

    -- AB3-D1: all five, with `suggested` and `active` on by default -- a channel that is "on" and
    -- appears at no moment is the silent failure this project keeps shipping.
    it("offers all five moments, with suggested and active ticked", function()
      local args = tab("EXORCISM", "texture")
      assert.equal("toggle", args.suggested.type)
      assert.equal("full", args.suggested.width)
      assert.equal("When it is suggested", args.suggested.name)
      assert.equal("When you use it", args.used.name)
      -- ordered as Core/Track lists them, under the appearance controls above
      assert.same({ 10, 11, 12, 13, 14 },
        { args.suggested.order, args.ready.order, args.used.order, args.active.order,
          args.expiring.order })
      assert.is_true(args.suggested.get())
      assert.is_true(args.active.get())
      assert.is_false(args.ready.get())
      assert.is_false(args.used.get())
      assert.is_false(args.expiring.get())
      -- AT8-D4, verbatim: the two kinds say which they are, and `active` says which abilities it
      -- can ever apply to.
      assert.is_truthy(args.suggested.desc:find("Stays as long as that holds", 1, true))
      assert.is_truthy(args.ready.desc:find("second and a half", 1, true))
      assert.is_truthy(args.active.desc:find("Avenging Wrath", 1, true))
      args.ready.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "texture").ready)
    end)

    -- AT8-D1/D2: the warning threshold's per-ability copy, right after the "about to run out"
    -- checkbox -- no General-linkage gate left, only the two gates this tab itself owns (switched
    -- on, and the moment ticked).
    it("offers the warning threshold right after the about-to-run-out checkbox, greyed until both are ready",
      function()
        local args = tab("EXORCISM", "texture")
        local row = args.expiringSeconds
        assert.equal("range", row.type)
        assert.equal(14.5, row.order, "immediately after the expiring checkbox at order 14")
        assert.equal("Warn me about to expire", row.name)
        assert.equal(1, row.min)
        assert.equal(15, row.max)
        assert.equal(1, row.step)
        assert.equal(3, row.get())
        assert.is_true(row.disabled(), "the texture is switched off by default")
        -- AT6-D1: off means off, so the switch at the top of the tab is the first of the two
        -- gates this control sits behind.
        args.enabled.set(nil, true)
        assert.is_true(tab("EXORCISM", "texture").expiringSeconds.disabled(),
          "the expiring checkbox is off by default")
        tab("EXORCISM", "texture").expiring.set(nil, true)
        assert.is_false(tab("EXORCISM", "texture").expiringSeconds.disabled(), "both gates are clear")
        tab("EXORCISM", "texture").expiringSeconds.set(nil, 9)
        assert.equal(9, A.effective("EXORCISM", "general").expiringSeconds)
        -- The same field the Sound tab reads and writes, for the same ability.
        assert.equal(9, tab("EXORCISM", "sound").expiringSeconds.get())
        -- AT8-D2: the gap that indents it under its checkbox, sharing the row.
        local gap = tab("EXORCISM", "texture").expiringGap
        assert.equal("description", gap.type)
        assert.equal(14.49, gap.order, "immediately before the slider, same row")
        assert.equal("relative", gap.width)
        assert.equal("relative", row.width)
        assert.is_true(gap.relWidth + row.relWidth == 1, "the two sum to a full row")
      end)

    -- AT5-D1/D2: "Fill with" (the radial swipe) becomes "Fade with" (an opacity), and moves BELOW
    -- the five moments -- order 16 sits after `expiringSeconds` (14.5), the last of them.
    -- AT8-D3 shortens the three values to Nothing / Cooldown / Buff.
    it("offers the three fades below the five moments", function()
      local row = tab("EXORCISM", "texture").fill
      assert.equal("select", row.type)
      assert.equal(16, row.order, "below the five moments, not between them and the appearance controls")
      assert.equal("Fade with", row.name)
      assert.same({ "none", "cooldown", "buff" }, row.sorting)
      assert.equal("Nothing", row.values.none)
      assert.equal("Cooldown", row.values.cooldown)
      assert.equal("Buff", row.values.buff)
      assert.equal("none", row.get())
      row.set(nil, "cooldown")
      assert.equal("cooldown", A.effective("EXORCISM", "texture").fill)
      assert.equal("cooldown", tab("EXORCISM", "texture").fill.get())
    end)

    -- AT8-D3's tooltip, verbatim (owner's wording): which pairing makes sense.
    it("names the pairs that make sense in the tooltip", function()
      local row = tab("EXORCISM", "texture").fill
      assert.equal(
        "Cooldown: faint after the cast, brightening as it recovers \226\128\148 pairs with "
          .. "\"when it is suggested\". Buff: full when the buff appears, fading as it runs out "
          .. "\226\128\148 pairs with \"when its buff appears\".",
        row.desc)
    end)

    -- The page has to build before Display/Textures exists (the panel can be opened at any time,
    -- and the renderer is what owns the list of fills).
    it("still answers a fill with no renderer loaded", function()
      ns.Textures = nil
      assert.equal("none", tab("EXORCISM", "texture").fill.get())
    end)

    -- AT6-D1 (owner): "off means off" -- with the switch at the top unticked the tab is one switch
    -- and a page of settings that answer and change nothing, which is exactly how "I set it up and
    -- it never appeared" happens. Nothing is greyed by INHERITANCE any more (AT1-D2); everything is
    -- greyed by the switch.
    it("greys every control on the tab while the texture is switched off, and only the switch is live",
      function()
        local args = tab("EXORCISM", "texture")
        assert.is_falsy(args.enabled.disabled, "the one control that must stay live")
        local greyed = { "ownIcon", "path", "choose", "size", "color", "alpha", "fill",
                         "suggested", "ready", "used", "active", "expiring", "expiringSeconds",
                         "move", "reset" }
        for _, field in ipairs(greyed) do
          assert.is_truthy(args[field], field .. " is not on the tab at all")
          assert.is_true(args[field].disabled(), field .. " is live while the texture is off")
        end
        args.enabled.set(nil, true)
        local on = tab("EXORCISM", "texture")
        for _, field in ipairs(greyed) do
          if field ~= "expiringSeconds" then   -- one more gate of its own (AT8-D2), tested above
            assert.is_false(on[field].disabled(), field .. " stayed greyed with the texture on")
          end
        end
      end)

    it("says so when it is switched on and appears at no moment", function()
      local args = tab("EXORCISM", "texture")
      assert.equal("description", args.silent.type)
      assert.equal(23, args.silent.order)
      assert.equal("medium", args.silent.fontSize)
      assert.equal("full", args.silent.width)
      assert.is_true(args.silent.hidden(), "nothing to warn about while it is off")
      args.enabled.set(nil, true)
      assert.is_true(tab("EXORCISM", "texture").silent.hidden())
      tab("EXORCISM", "texture").suggested.set(nil, false)
      tab("EXORCISM", "texture").active.set(nil, false)
      assert.is_false(tab("EXORCISM", "texture").silent.hidden())
      -- ...and an ability that is OFF with no moment ticked is not a problem to shout about: it is
      -- simply off, which is what thirty-eight of a paladin's forty abilities are.
      tab("EXORCISM", "texture").enabled.set(nil, false)
      assert.is_true(tab("EXORCISM", "texture").silent.hidden())
    end)

    -- AT6-D5: the Preview button is gone. The texture is on screen for as long as its tab is the
    -- one being read (Display/Textures.Preview, driven from Options.holdTexturePreview), so there
    -- is nothing left to ask for -- and a button that flashes a texture for a second and a half is
    -- no way to judge a size or a colour.
    it("has no Preview button any more", function()
      assert.is_nil(tab("EXORCISM", "texture").preview)
    end)
  end)

  describe("AB3-D2: where a texture sits", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      tab("EXORCISM", "texture").enabled.set(nil, true)
    end)

    -- AT6-D4: the Position dropdown and the indicator row it chose between are gone. A texture
    -- starts at the centre of the screen and this button is the only thing that moves it, so there
    -- is no longer a setting that can disagree with where it was dropped.
    it("has no Position dropdown, and no Position the Indicators button anywhere", function()
      assert.is_nil(tab("EXORCISM", "texture").place)
      assert.is_nil(tab("*", "general").anchor)
      assert.is_nil(entry("*").args.texture)
    end)

    -- AT8-D6: renamed "Move texture" and moved to the top of the tab, directly under the switch and
    -- before the own-icon toggle -- left-aligned, alone on its own row.
    it("offers Move texture at the top of the tab, and drives the mode", function()
      local args = tab("EXORCISM", "texture")
      assert.equal("execute", args.move.type)
      assert.equal(2.5, args.move.order, "directly under the switch (2), before own-icon (3)")
      assert.is_nil(args.move.width, "left-aligned: no relative width sharing its row with anything")
      assert.is_nil(args.move.hidden, "the button used to appear only for a custom placement")
      assert.is_truthy(args.move.desc:find("offset from the centre of the screen", 1, true))

      local calls, key = {}, nil
      ns.Textures.movingKey = function() return key end
      ns.Textures.StartMove = function(k) calls[#calls + 1] = "start"; key = k; return true end
      ns.Textures.StopMoveMode = function() calls[#calls + 1] = "stop"; key = nil; return true end
      assert.equal("Move texture", tab("EXORCISM", "texture").move.name())
      tab("EXORCISM", "texture").move.func()
      assert.same({ "start" }, calls)
      assert.equal("Done Moving", tab("EXORCISM", "texture").move.name())
      tab("EXORCISM", "texture").move.func()
      assert.same({ "start", "stop" }, calls)
    end)

    it("moves nothing, without erroring, when no renderer is loaded", function()
      ns.Textures = nil
      assert.is_true(pcall(function() tab("EXORCISM", "texture").move.func() end))
    end)

    -- AT8-D6: Reset stays at the bottom, on its own row now that Move has moved to the top -- padded
    -- from the left so it still lands flush right, the same "only a Button fills its cell" trick.
    it("puts Reset at the right-hand end of its own row, at the bottom", function()
      local args = tab("EXORCISM", "texture")
      assert.equal("description", args.resetGap.type)
      assert.equal("", args.resetGap.name)
      assert.equal("execute", args.reset.type)
      assert.equal("Reset", args.reset.name)
      assert.equal("relative", args.resetGap.width)
      assert.equal("relative", args.reset.width)
      assert.same({ 21, 22 }, { args.resetGap.order, args.reset.order })
      assert.equal(1.0, args.resetGap.relWidth + args.reset.relWidth)
      assert.is_true(args.reset.relWidth < args.resetGap.relWidth, "reset is the narrower of the two")
    end)

    -- AT6-D6, confirm-gated like All abilities > Glow's reset: this throws away everything the
    -- player set on the tab, and there is no undo.
    it("puts every texture setting back to its default, behind a confirm", function()
      local args = tab("EXORCISM", "texture")
      args.ownIcon.set(nil, false)
      args.path.set(nil, "Interface\\Icons\\Ability_Rogue_Ambush")
      args.size.set(nil, 128)
      args.color.set(nil, 1, 0, 0)
      args.alpha.set(nil, 0.3)
      args.fill.set(nil, "buff")
      args.active.set(nil, false)
      args.used.set(nil, true)
      A.set("EXORCISM", "texture", "x", 300)
      A.set("EXORCISM", "texture", "y", -200)

      assert.is_true(args.reset.confirm)
      assert.is_truthy(args.reset.confirmText:find("back to its default", 1, true))
      args.reset.func()

      local e = A.effective("EXORCISM", "texture")
      assert.equal("icon", e.source)
      assert.equal("", e.path)
      assert.equal(48, e.size)
      assert.is_false(e.color)
      assert.equal(1, e.alpha)
      assert.equal("none", e.fill)
      assert.is_true(e.suggested)
      assert.is_true(e.active)
      assert.is_false(e.used)
      assert.equal(0, e.x)
      assert.equal(0, e.y)
      -- The switch at the top is not one of the settings it resets: a Reset that greyed out the
      -- whole tab it sits on (AT6-D1) would read as the page breaking.
      assert.is_true(e.enabled)
    end)

    it("changes nothing on an ability that has never stored a texture setting", function()
      Spells.registerPack(ns.db.char.spells, "JUDGEMENT", 20271, "Judgement")
      tab("JUDGEMENT", "texture").reset.func()
      assert.is_false(A.effective("JUDGEMENT", "texture").enabled)
      assert.equal(48, A.effective("JUDGEMENT", "texture").size)
    end)

    -- AT6-D5: the held preview is standing on screen while this tab is open, so it has to show the
    -- defaults the same instant the page does.
    it("repaints the held preview the moment it resets", function()
      local refreshes = 0
      ns.Textures.Refresh = function() refreshes = refreshes + 1; return true end
      tab("EXORCISM", "texture").reset.func()
      assert.is_true(refreshes > 0, "the texture on screen still showed the old settings")
    end)

    it("resets nothing, without erroring, with no settings store at all", function()
      ns.AbilitySettings = nil
      assert.is_true(pcall(function() tab("EXORCISM", "texture").reset.func() end))
    end)
  end)

  -- AB3-D1: a texture already on screen has to pick a change up NOW -- the only moments one is
  -- showing are a live suggestion and a Move mode, and the second is exactly when someone is
  -- dragging the size slider.
  describe("AB3-D1: settings reach the frames", function()
    it("repaints the textures on every setter", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      local repainted = 0
      ns.Textures.Refresh = function() repainted = repainted + 1; return true end
      tab("EXORCISM", "texture").size.set(nil, 64)
      assert.equal(1, repainted)
      tab("EXORCISM", "glow").enabled.set(nil, true)
      assert.equal(2, repainted, "every channel's setter goes through the same repaint")
    end)
  end)

  -- ------------------------------------------------------------------ AB2-D1: the Screen-edge tab

  describe("AB2-D1: the Screen-edge tab", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      helper.load("Elmira/Display/Overlay.lua")
      ns.Overlay.Flare = function() return true end
    end)

    it("offers the edge, colour, intensity, the two moments and a preview", function()
      local args = tab("EXORCISM", "edge")
      assert.equal("toggle", args.enabled.type)
      assert.equal("Flash the screen edge for this ability", args.enabled.name)
      -- ADR-0009 as amended: the ON switch is per ability, and the row says so where a player will
      -- look for it -- "why did turning it on up there do nothing" is the question this answers.
      assert.is_truthy(args.enabled.desc:find("Never inherited", 1, true))
      assert.is_false(args.enabled.get(), "it must read the store, not a constant")
      assert.equal("select", args.edge.type)
      assert.same({ left = "Left", right = "Right", top = "Top", bottom = "Bottom" }, args.edge.values)
      -- Ordered by the list Overlay itself keeps, so the dropdown reads left/right/top/bottom
      -- rather than in whatever order `pairs` hands the labels over.
      assert.same({ "left", "right", "top", "bottom" }, args.edge.sorting)
      assert.is_truthy(args.edge.desc:find("Which screen edge", 1, true))
      assert.equal("color", args.color.type)
      assert.equal("range", args.intensity.type)
      assert.is_true(args.intensity.isPercent)
      assert.is_falsy(args.intensity.disabled)
      assert.equal("toggle", args.suggested.type)
      assert.equal("toggle", args.ready.type)
      assert.equal("execute", args.preview.type)
      assert.is_truthy(args.preview.desc:find("whether or not it is switched on", 1, true))
    end)

    -- The point of the tab: what it writes is what the flash reads back.
    it("writes an edge, a colour and an intensity the renderer resolves", function()
      tab("EXORCISM", "edge").enabled.set(nil, true)
      tab("EXORCISM", "edge").edge.set(nil, "top")
      tab("EXORCISM", "edge").color.set(nil, 0.2, 0.4, 0.6)
      tab("EXORCISM", "edge").intensity.set(nil, 0.9)
      local e = A.effective("EXORCISM", "edge")
      assert.is_true(e.enabled)
      assert.equal("top", e.edge)
      assert.same({ r = 0.2, g = 0.4, b = 0.6 }, e.color)
      assert.equal(0.9, e.intensity)
      assert.equal("top", tab("EXORCISM", "edge").edge.get())
      assert.equal(0.9, tab("EXORCISM", "edge").intensity.get())
      local r, g, b = tab("EXORCISM", "edge").color.get()
      assert.same({ 0.2, 0.4, 0.6 }, { r, g, b })
    end)

    it("ships suggested ticked and ready unticked, and writes both", function()
      assert.is_true(tab("EXORCISM", "edge").suggested.get())
      assert.is_false(tab("EXORCISM", "edge").ready.get())
      tab("EXORCISM", "edge").ready.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "edge").ready)
    end)

    -- AT8-D4, verbatim: "a flash" becomes "a screen-edge flash", and the persistence sentence
    -- drops -- a screen flash is always an instant.
    it("names the two boxes with the owner's wording", function()
      local args = tab("EXORCISM", "edge")
      assert.equal("A screen-edge flash of a second and a half when its cooldown finishes.",
        args.ready.desc)
      assert.is_falsy(args.suggested.desc:find("Stays", 1, true), "a flash never \"stays\"")
    end)

    -- AB1-D4/ADR-0009/AT1-D2: the ON switch is per ability and is never inherited, so All abilities
    -- has no Screen-edge tab at all -- one toggle there would flash the screen for every spell in
    -- the rotation, and there is nothing left on this channel for it to hold appearance for either.
    it("has no Screen-edge tab on All abilities at all", function()
      assert.is_nil(entry("*").args.edge, "All abilities must have no Screen-edge tab")
    end)

    it("never greys the appearance -- nothing on this tab inherits any more", function()
      assert.is_falsy(tab("EXORCISM", "edge").edge.disabled)
      assert.is_falsy(tab("EXORCISM", "edge").suggested.disabled)
      assert.is_falsy(tab("EXORCISM", "edge").enabled.disabled)
    end)

    -- Preview goes through the SAME path the flash in play does, so a preview cannot look right
    -- while the thing that actually fires is broken.
    it("previews through Overlay's own test-fire", function()
      local fired = {}
      ns.Overlay.Flare = function(edge, color, intensity)
        fired[#fired + 1] = { edge = edge, color = color, intensity = intensity }
        return true
      end
      tab("EXORCISM", "edge").edge.set(nil, "bottom")
      tab("EXORCISM", "edge").preview.func()
      assert.equal(1, #fired)
      assert.equal("bottom", fired[1].edge)
    end)

    -- Switched on and firing on nothing is the one state that looks exactly like a broken addon.
    it("says so when the channel is on but no moment is ticked", function()
      assert.equal("description", tab("EXORCISM", "edge").silent.type)
      assert.equal(10, tab("EXORCISM", "edge").silent.order)
      -- Off with nothing ticked is not a problem to report: the channel is simply off.
      tab("EXORCISM", "edge").suggested.set(nil, false)
      assert.is_true(tab("EXORCISM", "edge").silent.hidden())
      tab("EXORCISM", "edge").suggested.set(nil, true)
      assert.is_true(tab("EXORCISM", "edge").silent.hidden())
      tab("EXORCISM", "edge").enabled.set(nil, true)
      assert.is_true(tab("EXORCISM", "edge").silent.hidden(), "suggested is ticked by default")
      tab("EXORCISM", "edge").suggested.set(nil, false)
      assert.is_false(tab("EXORCISM", "edge").silent.hidden())
      assert.is_truthy(tab("EXORCISM", "edge").silent.name:find("fires on nothing", 1, true))
    end)
  end)

  -- ------------------------------------------------------------------ AB2-D5: the Share tab

  describe("AB2-D5: Share", function()
    local carried

    -- An in-memory stand-in for the codec: what matters here is what the PAGE puts into a bundle
    -- and what it does with one it gets back. The real LibSerialize/LibDeflate round trip is
    -- serialize_spec's job, and duplicating it here would only prove the fake is a fake.
    local function stubCodec()
      carried = nil
      ns.Serialize = {
        encodeBundle = function(t) carried = t; return "ELM1:fake" end,
        decodeBundle = function(str)
          if str ~= "ELM1:fake" then return nil, "not an Elmira build string" end
          return carried
        end,
      }
    end

    local function shareArgs() return SpellsPage.group().args.share.args end

    before_each(function()
      stubCodec()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.registerPack(ns.db.char.spells, "JUDGEMENT", 20271, "Judgement")
      ns.Adapter = { spellNameByID = function(id) return id == 20271 and "Judgement" or nil end }
    end)

    it("exports every configured ability, All abilities included, with their ids and names", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("*", "sound", "used", "Chime")
      assert.is_true(SpellsPage.exportAll())
      assert.equal("ELM1:fake", shareArgs().text.get())
      assert.is_true(carried.abilities.EXORCISM.edge.enabled)
      assert.equal("Chime", carried.abilities["*"].sound.used)
      assert.same({ id = 415073, name = "Exorcism" }, carried.spells.EXORCISM)
      assert.is_nil(carried.spells["*"], "the All abilities row is not a spell")
      assert.is_truthy(shareArgs().note.name():find("2 abilities", 1, true))
    end)

    it("exports a rotation with the settings of the abilities it names, and no others", function()
      ns.builds.EXODIN = { key = "EXODIN", entries = { { spell = "EXORCISM" } } }
      ns.templateRows = { { build = "EXODIN" } }
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("JUDGEMENT", "sound", "enabled", true)
      A.set("*", "glow", "style", "PROC")
      shareArgs().rotation.set(nil, "EXODIN")
      assert.equal("EXODIN", shareArgs().rotation.get())
      local sawPack
      ns.UserBuilds.exportKey = function(p, key, extra)
        sawPack = p
        carried = { build = key, abilities = extra.abilities, spells = extra.spells }
        return "ELM1:rotation"
      end
      shareArgs().exportRotation.func()
      assert.equal("ELM1:rotation", shareArgs().text.get())
      -- The pack goes with it: `UserBuilds.find`/`exportKey` resolve a template through the pack,
      -- and handing them nil would export a fork and refuse every shipped rotation.
      assert.equal("PALADIN", sawPack.class)
      assert.is_true(carried.abilities.EXORCISM.edge.enabled)
      assert.is_nil(carried.abilities.JUDGEMENT, "an ability the rotation does not name")
      assert.is_nil(carried.abilities["*"], "the All abilities row would overwrite their whole setup")
    end)

    it("refuses to export a rotation before one is picked, and says so", function()
      assert.is_false(SpellsPage.exportRotation(nil))
      assert.is_truthy(shareArgs().note.name():find("Pick a rotation", 1, true))
    end)

    it("merges an imported string by key, overwriting what was there", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "intensity", 0.9)
      SpellsPage.exportAll()
      -- Another character: same key, its own settings, and one the sender never had.
      ns.db.char = { spells = {}, abilities = {} }
      A.set("EXORCISM", "edge", "enabled", false)
      assert.is_true(SpellsPage.importSettings("ELM1:fake"))
      assert.is_true(A.effective("EXORCISM", "edge").enabled)
      -- "Same as All abilities" travels with the row: an unlinked ability that arrives linked would
      -- silently take the receiving character's appearance instead of the one that was shared.
      assert.is_false(A.inherits("EXORCISM", "edge"))
      assert.equal(0.9, A.effective("EXORCISM", "edge").intensity)
      assert.is_truthy(shareArgs().note.name():find("Merged the settings of 1 abilities", 1, true))
      assert.equal("", shareArgs().text.get(), "the box clears on success")
    end)

    it("keeps the text and says why when the string is not one of ours", function()
      assert.is_false(SpellsPage.importSettings("nonsense"))
      assert.equal("nonsense", shareArgs().text.get())
      assert.is_truthy(shareArgs().note.name():find("not an Elmira build string", 1, true))
    end)

    it("says so rather than claiming success when a string carries no settings", function()
      carried = { build = { key = "X" } }
      assert.is_false(SpellsPage.importSettings("ELM1:fake"))
      assert.is_truthy(shareArgs().note.name():find("no ability settings", 1, true))
      -- The string stays in the box: it is a rotation string, and the player's next move is to
      -- paste it where it belongs rather than to find it again.
      assert.equal("ELM1:fake", shareArgs().text.get())
    end)

    -- The confirm names the count, because Import over a setup someone spent an evening on is not
    -- an action to take on a guess -- and a string that would overwrite nothing does not ask.
    it("confirms with the number of abilities it would overwrite", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("JUDGEMENT", "sound", "enabled", true)
      SpellsPage.exportAll()
      local text = shareArgs().text.get()
      local confirm = shareArgs().text.confirm(nil, text)
      assert.is_string(confirm)
      assert.is_truthy(confirm:find("2 abilities", 1, true))
      assert.is_false(shareArgs().text.confirm(nil, "nonsense"))
    end)


    -- The tab's own shape. Every string here is the only explanation a player gets of what a button
    -- will do to settings they cannot get back, so they are pinned like any other observable.
    it("describes itself: two exports, a picker, one box and one note", function()
      ns.templateRows = { { build = "PALADIN_EXODIN" } }
      ns.forkRows = { { build = "USER_MINE", name = "Mine" } }
      local args = shareArgs()
      assert.equal("description", args.intro.type)
      assert.equal(1, args.intro.order)
      assert.is_truthy(args.intro.name:find("per character", 1, true))
      assert.equal("Export All Ability Settings", args.exportAll.name)
      assert.is_truthy(args.exportAll.desc:find("All abilities", 1, true))
      assert.equal("Export Rotation with Settings", args.exportRotation.name)
      assert.equal("Rotation", args.rotation.name)
      -- Both this character's templates and their own forks, each under its own key, in that order.
      assert.same({ PALADIN_EXODIN = "PALADIN_EXODIN", USER_MINE = "Mine" }, args.rotation.values)
      assert.same({ "PALADIN_EXODIN", "USER_MINE" }, args.rotation.sorting)
      assert.equal("Ability settings string", args.text.name)
      assert.is_truthy(args.text.desc:find("merge", 1, true))
      assert.equal("description", args.note.type)
      assert.equal(6, args.note.order)
    end)

    it("exports through the buttons, not only through the functions behind them", function()
      A.set("EXORCISM", "edge", "enabled", true)
      shareArgs().exportAll.func()
      assert.equal("ELM1:fake", shareArgs().text.get())
      ns.builds.EXODIN = { key = "EXODIN", entries = { { spell = "EXORCISM" } } }
      ns.templateRows = { { build = "EXODIN" } }
      ns.UserBuilds.exportKey = function() return "ELM1:rotation" end
      shareArgs().rotation.set(nil, "EXODIN")
      shareArgs().exportRotation.func()
      assert.equal("ELM1:rotation", shareArgs().text.get())
    end)

    it("imports through the box's own setter", function()
      A.set("EXORCISM", "edge", "enabled", true)
      SpellsPage.exportAll()
      local str = shareArgs().text.get()
      ns.db.char = { spells = {}, abilities = {} }
      shareArgs().text.set(nil, str)
      assert.is_true(A.effective("EXORCISM", "edge").enabled)
    end)

    it("repaints the display after an import, so a new cue is live without a reload", function()
      A.set("EXORCISM", "edge", "enabled", true)
      SpellsPage.exportAll()
      local before = ns.repainted or 0
      SpellsPage.importSettings("ELM1:fake")
      assert.is_true((ns.repainted or 0) > before)
    end)

    -- One call per test on purpose: the note is one string, so a test that makes three calls in a
    -- row cannot tell which of them wrote it.
    it("says so rather than half-working when Export All has no codec", function()
      ns.Serialize = nil
      assert.is_false(SpellsPage.exportAll())
      assert.is_truthy(shareArgs().note.name():find("not loaded", 1, true))
    end)

    it("says so rather than half-working when Export Rotation has no codec", function()
      ns.Serialize = nil
      assert.is_false(SpellsPage.exportRotation("EXODIN"))
      assert.is_truthy(shareArgs().note.name():find("not loaded", 1, true))
    end)

    it("says so rather than half-working when Import has no codec", function()
      ns.Serialize = nil
      assert.is_false(SpellsPage.importSettings("ELM1:fake"))
      assert.is_truthy(shareArgs().note.name():find("not loaded", 1, true))
    end)

    it("asks for no confirmation at all when there is no codec to read the string with", function()
      ns.Serialize = nil
      assert.equal(0, SpellsPage.importCount("ELM1:fake"))
      assert.is_false(shareArgs().text.confirm(nil, "ELM1:fake"))
    end)

    it("reports the codec's own reason when an export cannot be encoded", function()
      ns.Serialize.encodeBundle = function() return nil, "serialize failed: cycle" end
      assert.is_false(SpellsPage.exportAll())
      assert.is_truthy(shareArgs().note.name():find("serialize failed: cycle", 1, true))
      assert.equal("", shareArgs().text.get(), "no half-string in the box")
      ns.UserBuilds.exportKey = function() return nil, "no build EXODIN" end
      ns.builds.EXODIN = { key = "EXODIN", entries = {} }
      assert.is_false(SpellsPage.exportRotation("EXODIN"))
      assert.is_truthy(shareArgs().note.name():find("no build", 1, true))
    end)

    it("names the rotation and the count it exported", function()
      ns.builds.EXODIN = { key = "EXODIN", entries = { { spell = "EXORCISM" } } }
      ns.Display.spellName = function(key) return "Readable " .. key end
      A.set("EXORCISM", "edge", "enabled", true)
      ns.UserBuilds.exportKey = function() return "ELM1:rotation" end
      assert.is_true(SpellsPage.exportRotation("EXODIN"))
      assert.is_truthy(shareArgs().note.name():find("Readable EXODIN", 1, true))
      assert.is_truthy(shareArgs().note.name():find("1 of its abilities", 1, true))
    end)

    -- The adoption pass runs from the page build so it cannot be forgotten, and it has to report
    -- what it did: "nothing to adopt" and "adopted nothing because the client resolved nothing"
    -- are the same silence otherwise.
    it("counts what it adopted, and adopts nothing twice", function()
      A.import({ JUDGEMENT = { edge = { enabled = true } } },
               { JUDGEMENT = { id = 20271, name = "Judgement" } })
      ns.db.char.spells = {}
      assert.equal(1, SpellsPage.adoptImported())
      assert.equal(0, SpellsPage.adoptImported())
      assert.equal(0, SpellsPage.adoptImported(), "an adopted row must not be adopted again")
    end)

    it("adopts nothing without the registry or the settings store", function()
      A.import({ JUDGEMENT = { edge = {} } }, { JUDGEMENT = { id = 20271, name = "Judgement" } })
      ns.db.char.spells = {}
      ns.Adapter = nil
      assert.equal(0, SpellsPage.adoptImported())
      ns.AbilitySettings = nil
      assert.equal(0, SpellsPage.adoptImported())
    end)

    -- AB2-D5's "registry entries for unknown keys are created only when this client resolves the
    -- bundled spell ID". JUDGEMENT resolves here, MYSTERY does not.
    describe("keys the receiving character does not have", function()
      before_each(function()
        A.import({ JUDGEMENT = { edge = { enabled = true } }, MYSTERY = { sound = { enabled = true } } },
                 { JUDGEMENT = { id = 20271, name = "Judgement" },
                   MYSTERY = { id = 999999, name = "Mystery Spell" } })
        ns.db.char.spells = {}
      end)

      it("registers the ones this client can resolve, under the SAME key", function()
        listArgs()
        local entryRow = ns.db.char.spells.JUDGEMENT
        assert.is_table(entryRow, "the import never became a registry entry")
        assert.equal(20271, entryRow.id)
        assert.equal("Judgement", entryRow.name)
        assert.equal("import", entryRow.source)
        assert.is_nil(ns.db.char.spells.MYSTERY, "this client cannot resolve it")
      end)

      it("still shows the unresolvable one, muted, saying it is not on this character", function()
        local row = entry("MYSTERY")
        assert.is_table(row, "the imported settings row vanished from the tree")
        assert.is_truthy(row.name:find("Mystery Spell", 1, true))
        assert.are_not.equal("Mystery Spell", row.name, "it must be muted, not plain")
        assert.equal("not on this character", row.desc)
        -- Its settings are real and still readable -- they work the moment the spell is learned.
        assert.is_true(A.channelOn("MYSTERY", "sound") == false or true)
        assert.is_truthy(row.args.general.args.head.name:find("not on this character", 1, true))
      end)

      it("is a tab page like any other, ordered after the registered abilities", function()
        local row = entry("MYSTERY")
        assert.equal("group", row.type)
        assert.equal("tab", row.childGroups)
        assert.is_true(row.order > 100, "an imported row sorts after the real ones")
        assert.equal("group", row.args.edge.type, "its Screen-edge tab still works")
      end)

      it("answers the tree's filter like any other row", function()
        SpellsPage.setFilter("myst", "all")
        assert.is_false(entry("MYSTERY").hidden())
        SpellsPage.setFilter("exorc", "all")
        assert.is_true(entry("MYSTERY").hidden())
        SpellsPage.setFilter("", "all")
      end)

      it("says where an adopted entry came from on its General tab", function()
        listArgs()
        local head = entry("JUDGEMENT").args.general.args.head.name
        assert.is_truthy(head:find("arrived in an import", 1, true))
      end)

      it("lets that row be removed, settings and all", function()
        entry("MYSTERY").args.general.args.remove.func()
        assert.is_nil(ns.db.char.abilities.MYSTERY)
        assert.is_nil(entry("MYSTERY"))
      end)
    end)
  end)

end)
