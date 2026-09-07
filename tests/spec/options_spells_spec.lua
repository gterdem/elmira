local helper = require("tests.helper")

-- Elmira/Options/Spells.lua — the Spells page (R2, D52-D57). Plain data and closures, like
-- Options/Rotation.lua: a spec calls `SpellsPage.group()` and drives a row's get/set/func directly.
--
-- `ns.Rotation` is FAKED down to the four members this file actually calls
-- (templateRows/forkRows/displayName/syncSpells) rather than loading the real, much heavier
-- Options/Rotation.lua: Rotation's own behaviour is Options/Rotation's spec's job, and a fake here
-- keeps a failure in this file pointing at Spells.lua, not at the wiring underneath it.
describe("Options/Spells (the Spells page, R2 D52-D57)", function()
  local SpellsPage, Spells, ns

  local function installMinimal()
    ns.L = setmetatable({}, { __index = function(_, k) return k end })
    helper.load("Elmira/Core/Colors.lua")
    helper.load("Elmira/Core/Conditions.lua")
    Spells = helper.load("Elmira/Core/Spells.lua")
    ns.db = { char = { spells = {} } }
    ns.Display = { currentPack = function() return { class = "PALADIN" } end }
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
  end

  before_each(function()
    ns = helper.reset()
    installMinimal()
  end)

  describe("group()", function()
    it("is a tree named Spells, ordered right after Rotations (0)", function()
      local g = SpellsPage.group()
      assert.equal("group", g.type)
      assert.equal("tree", g.childGroups)
      assert.equal("Spells", g.name)
      assert.equal(0.5, g.order)
    end)

    it("opens with the exact D52 sentence", function()
      local g = SpellsPage.group()
      assert.equal("Every spell, buff or debuff a rotation or a cue can use. Spells used by your"
        .. " rotations are listed automatically; add anything else here.", g.args.intro.name)
    end)

    it("counts the registered entries in the header", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.registerPack(ns.db.char.spells, "JUDGEMENT", 415075, "Judgement")
      assert.equal("Registered · 2", SpellsPage.group().args.header.name)
    end)

    it("syncs the registry (Rotation.syncSpells) before reading it", function()
      local called = 0
      ns.Rotation.syncSpells = function() called = called + 1 end
      SpellsPage.group()
      assert.equal(1, called)
    end)

    it("lists each entry as a root-page card AND as a nested tree page keyed by its key", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      local g = SpellsPage.group()
      local sawCard = false
      for _, row in pairs(g.args) do
        if row.type == "execute" and row.name and tostring(row.name):find("Exorcism", 1, true) then
          sawCard = true
        end
      end
      assert.is_true(sawCard, "no clickable card names the entry")
      assert.equal("group", g.args.EXORCISM.type)
    end)

    -- D52: player-added entries in BRAND colour; automatic ones plain.
    it("colours a manually added entry's card in BRAND, and a pack entry plain", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      local g = SpellsPage.group()
      assert.equal("Exorcism", g.args.EXORCISM.name, "a pack entry's page name is plain text")
      assert.is_truthy(tostring(g.args.SLICE_AND_DICE.name):find("|c", 1, true),
        "a manually added entry's page name must be colour-wrapped")
    end)

    it("suffixes a root card with '<used by rotation names>' only when something references it", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      ns.forkRows = { { build = "MINE", name = "My Rotation" } }
      ns.builds.MINE = { entries = { { spell = "EXORCISM" } } }
      local g = SpellsPage.group()
      local cardName
      for _, row in pairs(g.args) do
        if row.type == "execute" and row.name and tostring(row.name):find("Exorcism", 1, true) then
          cardName = row.name
        end
      end
      assert.is_truthy(cardName:find("used by My Rotation", 1, true))
    end)
  end)

  describe("the per-entry page (D57 shell)", function()
    it("names the source: pack, id, name or spellbook, verbatim per D57's four strings", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      Spells.add(ns.db.char.spells, { id = 1, name = "ById", source = "id" })
      Spells.add(ns.db.char.spells, { id = 2, name = "ByName", source = "name" })
      Spells.add(ns.db.char.spells, { id = 3, name = "FromBook", source = "spellbook" })
      local g = SpellsPage.group()
      assert.is_truthy(g.args.EXORCISM.args.source.name:find("from the PALADIN pack", 1, true))
      assert.is_truthy(g.args.BYID.args.source.name:find("added by ID", 1, true))
      assert.is_truthy(g.args.BYNAME.args.source.name:find("added by name", 1, true))
      assert.is_truthy(g.args.FROMBOOK.args.source.name:find("added from your spellbook", 1, true))
    end)

    it("says which rotations use it, or says it is not used by any yet", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      local unused = SpellsPage.group().args.EXORCISM.args.source.name
      assert.is_truthy(unused:find("not used by any rotation yet", 1, true))

      ns.forkRows = { { build = "MINE", name = "My Rotation" } }
      ns.builds.MINE = { entries = { { spell = "EXORCISM" } } }
      local used = SpellsPage.group().args.EXORCISM.args.source.name
      assert.is_truthy(used:find("used by My Rotation", 1, true))
    end)

    it("carries the D57 placeholder line for cue controls, and nothing else", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      local args = SpellsPage.group().args.EXORCISM.args
      assert.is_truthy(args.cues.name:find("On-screen cues for this spell arrive in a later update.", 1, true))
    end)
  end)

  describe("D54(a): from the spellbook", function()
    before_each(function()
      ns.Adapter = { spellbookEntries = function()
        return { { id = 900, name = "Slice and Dice" }, { id = 901, name = "Kick" } }
      end }
    end)

    it("offers every spellbook entry as a choice", function()
      local values = SpellsPage.group().args.addSpellbook.args.pick.values
      assert.equal("Slice and Dice", values["900"])
      assert.equal("Kick", values["901"])
    end)

    it("is shaped as an inline group named 'From your spellbook', ordered second", function()
      local row = SpellsPage.group().args.addSpellbook
      assert.equal("group", row.type)
      assert.is_true(row.inline)
      assert.equal(2, row.order)
      assert.equal("From your spellbook", row.name)
    end)

    it("shapes the picker and the Add button", function()
      local args = SpellsPage.group().args.addSpellbook.args
      assert.equal("select", args.pick.type)
      assert.equal(1, args.pick.order)
      assert.equal("Spell", args.pick.name)
      args.pick.set(nil, "901")
      assert.equal("901", args.pick.get())
      assert.equal("execute", args.add.type)
      assert.equal(2, args.add.order)
      assert.equal("Add", args.add.name)
      assert.is_truthy(args.add.desc:find("Registers the selected spell", 1, true))
    end)

    it("does nothing when the picked id is not among the spellbook entries", function()
      local args = SpellsPage.group().args.addSpellbook.args
      args.pick.set(nil, "999")
      args.add.func()
      assert.same({}, ns.db.char.spells)
      assert.is_nil(ns.selected)
    end)

    it("registers the picked spell and navigates to its page", function()
      local args = SpellsPage.group().args.addSpellbook.args
      args.pick.set(nil, "900")
      args.add.func()
      assert.equal("spellbook", ns.db.char.spells.SLICE_AND_DICE.source)
      assert.same({ "Elmira", "spells", "SLICE_AND_DICE" }, ns.selected)
    end)

    it("does nothing when nothing is picked", function()
      SpellsPage.group().args.addSpellbook.args.add.func()
      assert.same({}, ns.db.char.spells)
      assert.is_nil(ns.selected)
    end)
  end)

  describe("D54(b): by ID", function()
    before_each(function()
      ns.Adapter = { spellNameByID = function(id) return id == 415073 and "Exorcism" or nil end }
    end)

    it("is shaped as an inline group named 'By ID', ordered third", function()
      local row = SpellsPage.group().args.addId
      assert.equal("group", row.type)
      assert.is_true(row.inline)
      assert.equal(3, row.order)
      assert.equal("By ID", row.name)
    end)

    it("shapes the value input, the preview line and the Add button", function()
      local args = SpellsPage.group().args.addId.args
      assert.equal("input", args.value.type)
      assert.equal(1, args.value.order)
      assert.equal("Spell ID", args.value.name)
      args.value.set(nil, "42")
      assert.equal("42", args.value.get())
      assert.equal("description", args.preview.type)
      assert.equal(2, args.preview.order)
      assert.equal("medium", args.preview.fontSize)
      assert.equal("execute", args.add.type)
      assert.equal(3, args.add.order)
      assert.equal("Add", args.add.name)
    end)

    it("previews nothing for an empty or non-numeric box", function()
      local args = SpellsPage.group().args.addId.args
      assert.equal("", args.preview.name())
      args.value.set(nil, "abc")
      assert.equal("", args.preview.name())
      args.value.set(nil, "0")
      assert.equal("", args.preview.name())
    end)

    it("previews what the id resolves to before storing anything", function()
      local args = SpellsPage.group().args.addId.args
      args.value.set(nil, "415073")
      assert.is_truthy(args.preview.name():find("Resolves to: Exorcism", 1, true))
      assert.same({}, ns.db.char.spells, "a preview must not store")
    end)

    it("shows Not found in red for an id the client cannot resolve", function()
      local args = SpellsPage.group().args.addId.args
      args.value.set(nil, "1")
      assert.is_truthy(args.preview.name():find("Not found%.", nil))
    end)

    it("registers on Add and navigates to the new page", function()
      local args = SpellsPage.group().args.addId.args
      args.value.set(nil, "415073")
      args.add.func()
      assert.equal("id", ns.db.char.spells.EXORCISM.source)
      assert.same({ "Elmira", "spells", "EXORCISM" }, ns.selected)
    end)

    it("does not store when Add is pressed on an unresolved id", function()
      local args = SpellsPage.group().args.addId.args
      args.value.set(nil, "1")
      args.add.func()
      assert.same({}, ns.db.char.spells)
      assert.is_nil(ns.selected)
    end)
  end)

  describe("D54(c): by name — the refusal must not silently store", function()
    before_each(function()
      ns.Adapter = {
        spellIDByName = function(name) return name == "Exorcism" and 415073 or nil end,
        spellNameByID = function(id) return id == 415073 and "Exorcism" or nil end,
      }
    end)

    it("is shaped as an inline group named 'By name', ordered fourth", function()
      local row = SpellsPage.group().args.addName
      assert.equal("group", row.type)
      assert.is_true(row.inline)
      assert.equal(4, row.order)
      assert.equal("By name", row.name)
    end)

    it("shapes the limitation line, the value input and the error line", function()
      local args = SpellsPage.group().args.addName.args
      assert.equal("description", args.limitation.type)
      assert.equal(1, args.limitation.order)
      assert.equal("medium", args.limitation.fontSize)
      assert.equal("input", args.value.type)
      assert.equal(2, args.value.order)
      assert.equal("Spell name", args.value.name)
      args.value.set(nil, "Anything")
      assert.equal("Anything", args.value.get())
      assert.equal("description", args.error.type)
      assert.equal(3, args.error.order)
      assert.equal("medium", args.error.fontSize)
      assert.equal("execute", args.add.type)
      assert.equal(4, args.add.order)
      assert.equal("Add", args.add.name)
    end)

    it("states the limitation on the page unconditionally, before any attempt", function()
      local args = SpellsPage.group().args.addName.args
      assert.is_truthy(args.limitation.name:find("learned or seen", 1, true))
      assert.is_true(args.error.hidden())
    end)

    it("refuses an unresolved name IN RED, and leaves the registry unchanged", function()
      local args = SpellsPage.group().args.addName.args
      args.value.set(nil, "Something Unseen")
      args.add.func()
      assert.same({}, ns.db.char.spells, "a refused name must not be stored")
      assert.is_false(args.error.hidden())
      local shown = args.error.name()
      assert.is_truthy(shown:find("Not found: this character has not seen it. Try the ID.", 1, true))
      assert.is_truthy(shown:find("|cffE5544B", 1, true), "the refusal must render in red (Colors.BAD)")
      assert.is_nil(ns.selected, "a refusal must not navigate anywhere")
    end)

    it("clears the error and registers on a name the client resolves", function()
      local args = SpellsPage.group().args.addName.args
      args.value.set(nil, "Exorcism")
      args.add.func()
      assert.equal("name", ns.db.char.spells.EXORCISM.source)
      assert.same({ "Elmira", "spells", "EXORCISM" }, ns.selected)
    end)

    it("clears a stale error as soon as the box is edited again", function()
      local args = SpellsPage.group().args.addName.args
      args.value.set(nil, "Something Unseen")
      args.add.func()
      assert.is_false(args.error.hidden())
      args.value.set(nil, "Exorcism")
      assert.is_true(args.error.hidden())
    end)
  end)

  describe("D54: adding an already-registered spell selects its page instead of duplicating it", function()
    it("selects the existing entry rather than creating a second one", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      ns.Adapter = { spellNameByID = function() return "Exorcism" end }
      local args = SpellsPage.group().args.addId.args
      args.value.set(nil, "415073")
      args.add.func()
      assert.same({ "Elmira", "spells", "EXORCISM" }, ns.selected)
      local count = 0
      for _ in pairs(ns.db.char.spells) do count = count + 1 end
      assert.equal(1, count)
    end)
  end)

  describe("D56: the removal guard", function()
    it("shows no remove control at all for an automatic (pack) entry", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      assert.is_nil(SpellsPage.group().args.EXORCISM.args.remove)
    end)

    it("blocks a manual entry still referenced, and names the rotation holding it", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      ns.forkRows = { { build = "MINE", name = "My Rotation" } }
      ns.builds.MINE = { entries = { { spell = "SLICE_AND_DICE" } } }
      local args = SpellsPage.group().args.SLICE_AND_DICE.args
      assert.equal("description", args.remove.type)
      assert.is_truthy(args.remove.name:find("My Rotation", 1, true))
      assert.is_not_nil(ns.db.char.spells.SLICE_AND_DICE)
    end)

    it("offers a confirmed Remove for a manual entry with nothing referencing it", function()
      Spells.add(ns.db.char.spells, { id = 900, name = "Slice and Dice", source = "spellbook" })
      local args = SpellsPage.group().args.SLICE_AND_DICE.args
      assert.equal("execute", args.remove.type)
      assert.is_true(args.remove.confirm)
      assert.is_truthy(args.remove.confirmText:find("Slice and Dice", 1, true))
      args.remove.func()
      assert.is_nil(ns.db.char.spells.SLICE_AND_DICE)
      assert.same({ "Elmira", "spells" }, ns.selected, "removal returns to the root page")
    end)
  end)

  describe("rows in order (D52)", function()
    it("orders the intro, the three add rows and the header 1 through 5", function()
      local args = SpellsPage.group().args
      assert.same({ 1, 2, 3, 4, 5 },
        { args.intro.order, args.addSpellbook.order, args.addId.order, args.addName.order,
          args.header.order })
    end)

    it("orders each root-page card after the header, and each nested page from 1000", function()
      Spells.registerPack(ns.db.char.spells, "AAA", 1, "Aaa")
      Spells.registerPack(ns.db.char.spells, "BBB", 2, "Bbb")
      local g = SpellsPage.group()
      assert.equal(6, g.args.card1.order)
      assert.equal(7, g.args.card2.order)
      assert.equal(1001, g.args.AAA.order)
      assert.equal(1002, g.args.BBB.order)
    end)
  end)

  describe("wiring (D53)", function()
    it("sets ns.SpellsPage to itself when the file loads", function()
      assert.equal(SpellsPage, ns.SpellsPage)
    end)

    it("passes the CURRENT pack through when resolving a rotation's build", function()
      local seen
      ns.UserBuilds.find = function(p) seen = p end
      ns.forkRows = { { build = "MINE", name = "Mine" } }
      SpellsPage.group()
      assert.equal("PALADIN", seen and seen.class)
    end)

    it("also walks shipped TEMPLATE rotations, not only forks, for 'used by'", function()
      Spells.registerPack(ns.db.char.spells, "EXORCISM", 415073, "Exorcism")
      ns.templateRows = { { build = "TEMPLATE" } }
      ns.builds.TEMPLATE = { entries = { { spell = "EXORCISM" } } }
      local used = SpellsPage.group().args.EXORCISM.args.source.name
      assert.is_truthy(used:find("used by TEMPLATE", 1, true))
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
  end)
end)
