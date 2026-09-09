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
    SpellsPage = helper.load("Elmira/Options/Spells.lua")
    -- Every page build starts from an unfiltered tree; the filter is module state.
    SpellsPage.setFilter("", "all")
  end

  before_each(function()
    ns = helper.reset()
    installMinimal()
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

    -- AB2-D5 fills this in; a tab with nothing in it reads as a broken page.
    it("says Share is coming rather than showing an empty tab", function()
      local row = SpellsPage.group().args.share.args.soon
      assert.equal("description", row.type)
      assert.equal("Sharing arrives in the next pass.", row.name)
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

    -- The three inline groups this replaces could not share a row: an AceConfig panel is always the
    -- full width of the page. Controls CAN, through relWidths summing to exactly 1.0 -- which is
    -- the only shape AceGUI's Flow scales (AceGUI-3.0.lua:709-711).
    it("puts all four controls on one row, with relWidths summing to 1", function()
      local args = addArgs()
      local total = 0
      for _, key in ipairs({ "pick", "addPick", "typed", "addTyped" }) do
        assert.equal("relative", args[key].width, key .. " does not share the row")
        total = total + args[key].relWidth
      end
      assert.is_true(math.abs(total - 1.0) < 1e-9, "the row does not add up to 1.0: " .. total)
      assert.equal("From your spellbook", args.pick.name)
      assert.equal("Spell ID or name", args.typed.name)
      assert.equal("Add", args.addPick.name)
      assert.equal("Add", args.addTyped.name)
      assert.same({ 1, 2, 3, 4, 5 }, { args.pick.order, args.addPick.order, args.typed.order,
                                       args.addTyped.order, args.preview.order })
    end)

    it("offers every spellbook entry as a choice, with its icon", function()
      ns.Display.spellIconByID = function(id)
        return id == 900 and "Interface\\Icons\\Ability_Rogue_SliceDice" or nil
      end
      local values = addArgs().pick.values
      assert.equal("|TInterface\\Icons\\Ability_Rogue_SliceDice:14|t Slice and Dice", values["900"])
      assert.equal("Kick", values["901"])
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

    it("previews what the box resolves to, before storing anything", function()
      local args = addArgs()
      assert.equal("", args.preview.name())
      args.typed.set(nil, "415073")
      assert.equal("Resolves to: Exorcism", args.preview.name())
      args.typed.set(nil, "Exorcism")
      assert.equal("Resolves to: Exorcism", args.preview.name())
      args.typed.set(nil, "1")
      assert.equal("", args.preview.name(), "a live 'not found' while typing is noise")
      assert.same({}, ns.db.char.spells, "a preview must not store")
    end)

    it("registers an id on Add, navigates, and clears the box", function()
      local args = addArgs()
      args.typed.set(nil, "415073")
      args.addTyped.func()
      assert.equal("id", ns.db.char.spells.EXORCISM.source)
      assert.same({ "Elmira", "spells", "list", "EXORCISM" }, ns.selected)
      assert.equal("", args.typed.get())
    end)

    it("registers a name on Add, and records that it came from a name", function()
      local args = addArgs()
      args.typed.set(nil, "Exorcism")
      args.addTyped.func()
      assert.equal("name", ns.db.char.spells.EXORCISM.source)
      assert.same({ "Elmira", "spells", "list", "EXORCISM" }, ns.selected)
    end)

    -- D95 (2026-09-07 in-game round): the box clears after EVERY attempt, and the refusal message
    -- is what stays visible -- a "Not found" left sitting in the box read as if nothing happened.
    it("refuses an unresolved id IN RED, clears the box, stores nothing", function()
      local args = addArgs()
      args.typed.set(nil, "1")
      args.addTyped.func()
      assert.same({}, ns.db.char.spells)
      assert.is_nil(ns.selected)
      assert.equal("", args.typed.get())
      local shown = args.preview.name()
      assert.is_truthy(shown:find("Not found.", 1, true))
      assert.is_truthy(shown:find("|cffE5544B", 1, true), "the refusal must render in red (Colors.BAD)")
    end)

    -- A name gets the longer refusal: it is the one that needs to point at the other half of the box.
    it("refuses an unseen NAME with the sentence that names the alternative", function()
      local args = addArgs()
      args.typed.set(nil, "Something Unseen")
      args.addTyped.func()
      assert.same({}, ns.db.char.spells)
      assert.is_truthy(args.preview.name():find(
        "Not found: this character has not seen it. Try the ID.", 1, true))
      assert.is_truthy(addArgs().typed.desc:find("learned or seen", 1, true))
    end)

    it("clears a stale refusal as soon as the box is edited again", function()
      local args = addArgs()
      args.typed.set(nil, "Something Unseen")
      args.addTyped.func()
      assert.is_truthy(args.preview.name():find("Not found", 1, true))
      args.typed.set(nil, "Exorcism")
      assert.equal("Resolves to: Exorcism", args.preview.name())
    end)

    -- ...and a SUCCESSFUL add clears it too. The box is empty afterwards, so a refusal left behind
    -- would sit under an empty field claiming the add had failed.
    it("clears a stale refusal when the next attempt succeeds", function()
      local args = addArgs()
      args.typed.set(nil, "Something Unseen")
      args.addTyped.func()
      args.typed.set(nil, "415073")
      args.addTyped.func()
      assert.equal("", args.preview.name())
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
  end)

  -- ------------------------------------------------------------------ AB1-D4/D9: the tree itself

  describe("D4/D9: the tree rows", function()
    before_each(function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
    end)

    it("opens with an All abilities row carrying the addon's own icon and the same six tabs", function()
      local all = entry("*")
      assert.equal("All abilities", all.name)
      assert.equal("Interface\\AddOns\\Elmira\\media\\icon", all.icon)
      assert.equal("tab", all.childGroups)
      local names = {}
      for key in pairs(all.args) do names[#names + 1] = key end
      table.sort(names)
      assert.same({ "announce", "edge", "general", "glow", "sound", "texture" }, names)
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

    -- AB1-D9(b): the tooltip AceConfigDialog's TreeOnButtonEnter draws for the row.
    it("describes every channel's on/off in the row's tooltip", function()
      assert.equal("Glow on · Texture, Screen-edge, Sound, Announcement off",
                   entry("EXORCISM").desc())
      A.set("EXORCISM", "edge", "enabled", true)
      A.set("EXORCISM", "sound", "enabled", true)
      -- The picks are inherited appearance (AB1-D4), so the All abilities entry is what puts a
      -- real sound behind the switch. Switched on with every event still None is a channel that
      -- will never make a noise, and the tooltip must not claim otherwise.
      assert.equal("Glow, Screen-edge on · Texture, Sound, Announcement off",
                   entry("EXORCISM").desc())
      A.set("*", "sound", "used", "Chime")
      assert.equal("Glow, Screen-edge, Sound on · Texture, Announcement off",
                   entry("EXORCISM").desc())
      A.setInherit("EXORCISM", "glow", false)
      A.set("EXORCISM", "glow", "enabled", false)
      A.set("EXORCISM", "edge", "enabled", false)
      A.set("EXORCISM", "sound", "enabled", false)
      assert.equal("Glow, Texture, Screen-edge, Sound, Announcement off", entry("EXORCISM").desc())
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

    -- "Any configured" is the one that answers "what have I actually set up", which with glow
    -- shipping on for everything is every ability until one is switched off.
    it("matches on any configured channel", function()
      SpellsPage.setFilter("", "any")
      assert.is_true(SpellsPage.matches({ key = "EXORCISM", name = "Exorcism" }))
      A.setInherit("EXORCISM", "glow", false)
      A.set("EXORCISM", "glow", "enabled", false)
      assert.is_false(SpellsPage.matches({ key = "EXORCISM", name = "Exorcism" }))
      A.set("EXORCISM", "announce", "enabled", true)
      assert.is_true(SpellsPage.matches({ key = "EXORCISM", name = "Exorcism" }))
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

    it("guards every channel with Only in combat, and stores it", function()
      local row = tab("EXORCISM", "general").onlyInCombat
      assert.equal("toggle", row.type)
      assert.equal("Only in combat", row.name)
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

    -- AB1-D5: the threshold the `expiring` event fires at.
    it("offers the expiring threshold as a 1-15 second slider defaulting to 3", function()
      local row = tab("*", "general").expiring
      assert.equal("range", row.type)
      assert.equal(1, row.min)
      assert.equal(15, row.max)
      assert.equal(1, row.step)
      assert.equal(3, row.get())
      assert.is_truthy(row.desc:find("about to run out", 1, true))
      row.set(nil, 8)
      assert.equal(8, A.effective("EXORCISM", "general").expiringSeconds)
      -- Greyed with the rest of the tab while the ability is linked, and live once it is not.
      assert.is_true(tab("EXORCISM", "general").expiring.disabled())
      tab("EXORCISM", "general").inherit.set(nil, false)
      assert.is_false(tab("EXORCISM", "general").expiring.disabled())
    end)

    -- AB1-D6: what the SHIPPED class data says about this ability -- which rotations use it, why
    -- its cues fire, and what those need.
    it("summarises the class pack's own rotations, reasons and requirements", function()
      ns.Display.currentPack = function()
        return { class = "PALADIN", builds = {
          EXODIN = { entries = { { spell = "EXORCISM" } },
                     requires = { runes = { "RUNE_ART_OF_WAR" } },
                     visuals = { cues = { { spell = "EXORCISM", reason = "Exorcism came off cooldown",
                                            requiresBonus = "HOLY_POWER_CONSUME" } } } },
          SHOCKADIN = { entries = { { spell = "HOLY_SHOCK" } } },
        } }
      end
      ns.Display.spellName = function(key) return "name:" .. key end
      ns.Display.spellIcon = function(key) return key == "RUNE_ART_OF_WAR" and "Icons\\AoW" or nil end
      local rows = SpellsPage.packNotes("EXORCISM", ns.Display.currentPack())
      assert.equal(1, #rows)
      assert.equal("EXODIN", rows[1].name)
      assert.same({ "Exorcism came off cooldown" }, rows[1].reasons)
      assert.same({ "HOLY_POWER_CONSUME", "RUNE_ART_OF_WAR" }, rows[1].needs)

      local panel = tab("EXORCISM", "general").pack
      assert.equal("What the class pack says", panel.name)
      local text = {}
      for _, row in pairs(panel.args) do text[#text + 1] = row.name end
      table.sort(text)
      local joined = table.concat(text, "\n")
      assert.is_truthy(joined:find("Exorcism came off cooldown", 1, true))
      assert.is_truthy(joined:find("name:HOLY_POWER_CONSUME", 1, true))
      assert.is_truthy(joined:find("|TIcons\\AoW:0|t name:RUNE_ART_OF_WAR", 1, true))
      assert.is_nil(tab("SLICE_AND_DICE", "general").pack, "no pack rotation names it")
      -- One row per thing said: the rotation's name, then its reason, then each requirement. A
      -- shared key would silently swallow whichever line was written first.
      local count = 0
      for _ in pairs(panel.args) do count = count + 1 end
      assert.equal(4, count)
      assert.is_truthy(joined:find("EXODIN", 1, true))
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
      assert.equal(3, args.style.order)
      assert.equal("Style", args.style.name)
      assert.equal("Pixel", args.style.values().PIXEL)
      assert.equal("color", args.color.type)
      assert.equal(4, args.color.order)
      assert.equal("Colour", args.color.name)
      assert.is_falsy(args.color.hasAlpha)
      assert.equal("The colour of the glow on your action bar.", args.color.desc)
      assert.equal("execute", args.preview.type)
      assert.equal(9, args.preview.order)
      assert.equal("Preview Glow", args.preview.name)
      assert.equal("Flashes a button on your bars with these settings.", args.preview.desc)
      assert.equal("Puts every glow setting back the way it shipped, including the colour.",
                   args.reset.desc)
    end)

    it("stores style and colour per ability, and repaints", function()
      local args = tab("*", "glow")
      assert.equal("PIXEL", args.style.get())
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
    end)

    it("plays the sound the moment it is picked, having stored it first", function()
      tab("EXORCISM", "sound").inherit.set(nil, false)
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

    -- AB1-D4: the ON switch is per ability and is never inherited, which is what stops one setting
    -- on All abilities making every spell in the rotation start making noise.
    it("puts the on switch on the ability alone, never on All abilities", function()
      assert.is_nil(tab("*", "sound").enabled, "All abilities must have no sound on/off")
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

    it("inherits the picks from All abilities while linked", function()
      tab("*", "sound").used.set(nil, "Chime")
      assert.equal("Chime", tab("EXORCISM", "sound").used.get())
      assert.is_true(tab("EXORCISM", "sound").used.disabled())
      tab("EXORCISM", "sound").inherit.set(nil, false)
      assert.equal("None", tab("EXORCISM", "sound").used.get())
      assert.is_false(tab("EXORCISM", "sound").used.disabled())
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

    it("gives All abilities the wording but no on switch", function()
      local args = tab("*", "announce")
      assert.is_nil(args.enabled)
      assert.is_nil(args.inherit, "All abilities is what everything else inherits FROM")
      assert.equal("Include how long it lasts", args.duration.name)
      assert.is_false(args.duration.get())
      args.duration.set(nil, true)
      assert.is_true(A.effective("EXORCISM", "announce").duration, "wording inherits")
      assert.is_false(A.effective("EXORCISM", "announce").enabled, "the on switch does not")
    end)

    -- The wording is appearance, so it is greyed while the ability is linked; the on switch is
    -- the ability's own and stays live.
    it("greys the wording, not the on switch, while the ability is linked", function()
      local args = tab("EXORCISM", "announce")
      assert.equal("Same as All abilities", args.inherit.name)
      assert.is_true(args.duration.disabled())
      assert.is_falsy(args.enabled.disabled)
      args.inherit.set(nil, false)
      assert.is_false(tab("EXORCISM", "announce").duration.disabled())
    end)
  end)

  -- ------------------------------------------------------------------ AB1-D12: the shells

  describe("D12: Texture and Screen-edge are one-line shells", function()
    it("says the next pass fills them, and offers no controls", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      for _, name in ipairs({ "texture", "edge" }) do
        local args = tab("EXORCISM", name)
        local keys = {}
        for key in pairs(args) do keys[#keys + 1] = key end
        assert.same({ "soon" }, keys, name .. " has grown a control")
        assert.equal("description", args.soon.type)
        assert.is_truthy(args.soon.name:find("Arrives in the next pass.", 1, true))
      end
    end)
  end)
end)
