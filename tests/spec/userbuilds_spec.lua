-- tests/spec/userbuilds_spec.lua — Core/UserBuilds.lua: forks (ADR-0010) arriving by import string.
local helper = require("tests.helper")

describe("Core.UserBuilds", function()
  local UserBuilds, Serialize, ns, pack, db

  local function loadCodec()
    if not _G.CreateFrame then dofile("tests/wow_mock.lua") end
    _G.LibStub = nil
    for _, path in ipairs({ "Elmira/Libs/LibStub/LibStub.lua", "Elmira/Libs/LibSerialize/LibSerialize.lua",
                            "Elmira/Libs/LibDeflate/LibDeflate.lua" }) do
      local chunk = assert(loadfile(path), path .. " — run `make libs`"); chunk()
    end
    return LibStub("LibSerialize"), LibStub("LibDeflate")
  end

  before_each(function()
    ns = helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    helper.load("Elmira/Core/Schema.lua")
    Serialize = helper.load("Elmira/Core/Serialize.lua")
    UserBuilds = helper.load("Elmira/Core/UserBuilds.lua")
    -- Core/Slash.lua owns `ns.compileBuild` and its cache, which every edit below has to
    -- invalidate. Loaded for real rather than faked: the whole defect these tests pin is that the
    -- two files disagreed about when a compilation stops being valid.
    helper.load("Elmira/Core/Slash.lua")
    -- R2b: `ctxFor` merges this character's registry into the pack's own spells (Spells.merged) --
    -- loaded for real so a spec pins the MERGE, not a fake that already agrees with it.
    helper.load("Elmira/Core/Spells.lua")
    local LS, LD = loadCodec()
    Serialize.use{ serializer = LS, deflate = LD }
    pack = helper.classPack("Paladin")
    db = { global = { userBuilds = {} }, char = { spells = {} } }
    ns.db = db
  end)

  local function exodinString() return Serialize.encode(pack.builds.PALADIN_EXODIN) end

  -- ADR-0015 §2: Customize forks the template AND activates the fork in the same click. These test
  -- the forking half; Options/Rotation.customize wires the two together.
  describe("fork()", function()
    it("copies a shipped template into the user's own rotations", function()
      local key = UserBuilds.fork(pack, "PALADIN_EXODIN", {})
      assert.is_truthy(key)
      assert.is_true(UserBuilds.isForkKey(key))
      local build, origin = UserBuilds.find(pack, key)
      assert.equal("fork", origin)
      assert.equal(#pack.builds.PALADIN_EXODIN.entries, #build.entries)
    end)

    -- ADR-0010: provenance is the whole point of a fork over a copy, and `derivedAt` is what lets a
    -- later release of the parent be noticed instead of silently diverging.
    it("records which template it came from, and which version of it", function()
      local key = UserBuilds.fork(pack, "PALADIN_EXODIN", { today = "2026-09-05" })
      local _, _, fork = UserBuilds.find(pack, key)
      assert.equal("PALADIN_EXODIN", fork.derivedFrom)
      assert.equal(UserBuilds.catalogUpdated(pack, "PALADIN_EXODIN"), fork.derivedAt)
      assert.equal("2026-09-05", fork.importedAt)
      assert.equal(pack.class, fork.class)
    end)

    -- The defect this guards is invisible and account-wide: Classes/<Class>.lua is one shared table
    -- per session, so a fork holding a reference into it would edit the SHIPPED template for every
    -- character, and the edit would vanish on reload with no sign it was ever made.
    it("deep-copies, so editing the fork cannot touch the shipped template", function()
      local key = UserBuilds.fork(pack, "PALADIN_EXODIN", {})
      local build = UserBuilds.find(pack, key)
      local template = pack.builds.PALADIN_EXODIN
      assert.is_not.equal(template, build)
      assert.is_not.equal(template.entries, build.entries)
      assert.is_not.equal(template.entries[1], build.entries[1])
      build.entries[1].spell = "MUTATED"
      build.entries[1].disabled = true
      assert.is_not.equal("MUTATED", template.entries[1].spell)
      assert.is_nil(template.entries[1].disabled)
      -- Nested `when` lists too: a shared condition table is the same defect one level down.
      for i, entry in ipairs(template.entries) do
        if entry.when then assert.is_not.equal(entry.when, build.entries[i].when) end
      end
    end)

    -- A hand-written or imported build could contain a cycle. A stack overflow at login is a worse
    -- bug than anything the copy is guarding against.
    it("copes with a build that refers to itself", function()
      local loop = { key = "PALADIN_LOOP", entries = { { spell = "EXORCISM" } } }
      loop.self = loop
      loop.entries[1].parent = loop.entries
      pack.builds.PALADIN_LOOP = loop
      local key = UserBuilds.fork(pack, "PALADIN_LOOP", {})
      assert.is_truthy(key)
      local build = UserBuilds.find(pack, key)
      -- The cycle is preserved as a cycle, pointing at the COPY, never back at the shipped table.
      assert.equal(build, build.self)
      assert.is_not.equal(loop, build.self)
      assert.equal(build.entries, build.entries[1].parent)
      pack.builds.PALADIN_LOOP = nil
    end)

    it("names the fork after the template, and takes a name when given one", function()
      local key = UserBuilds.fork(pack, "PALADIN_EXODIN", {})
      local _, _, fork = UserBuilds.find(pack, key)
      assert.is_truthy(fork.name:find("(mine)", 1, true))
      local named = UserBuilds.fork(pack, "PALADIN_EXODIN", { name = "Raid night" })
      assert.equal("USER_RAID_NIGHT", named)
      assert.equal("Raid night", select(3, UserBuilds.find(pack, named)).name)
    end)

    it("gives a second fork of the same template its own key", function()
      local a = UserBuilds.fork(pack, "PALADIN_EXODIN", {})
      local b = UserBuilds.fork(pack, "PALADIN_EXODIN", {})
      assert.is_not.equal(a, b)
      assert.equal(2, #UserBuilds.list(pack))
    end)

    it("carries the fork's own key and name into the build itself", function()
      local key = UserBuilds.fork(pack, "PALADIN_EXODIN", {})
      local build = UserBuilds.find(pack, key)
      assert.equal(key, build.key)
      assert.is_truthy(build.name:find("(mine)", 1, true))
    end)

    it("refuses a template the pack does not ship, and says so", function()
      local key, err = UserBuilds.fork(pack, "PALADIN_NOPE", {})
      assert.is_nil(key)
      assert.is_truthy(err:find("PALADIN_NOPE", 1, true))
      assert.equal(0, #UserBuilds.list(pack))
    end)

    -- A fork of a fork would have the wrong provenance: `derivedFrom` must name a TEMPLATE.
    it("refuses to fork one of the user's own rotations", function()
      local key = UserBuilds.fork(pack, "PALADIN_EXODIN", {})
      assert.is_nil(UserBuilds.fork(pack, key, {}))
    end)

    it("answers rather than erroring with no saved variables", function()
      ns.db = nil
      assert.is_nil(UserBuilds.fork(pack, "PALADIN_EXODIN", {}))
      ns.db = db
    end)

    it("works when handed no options", function()
      assert.is_truthy(UserBuilds.fork(pack, "PALADIN_EXODIN"))
    end)
  end)

  -- Priority order IS the rotation (F1: the first passing entry is the suggestion), so these are the
  -- most consequential edits the Builder offers.
  -- The Builder's Save (M5e step 4). It writes the whole line list at once because the panel edits a
  -- DRAFT: a half-applied save would leave a rotation that is neither what was stored nor what is on
  -- screen, and nothing would say so.
  describe("replaceEntries()", function()
    local key
    before_each(function() key = UserBuilds.fork(pack, "PALADIN_EXODIN", {}) end)

    local function entriesOf()
      return UserBuilds.find(pack, key).entries
    end

    it("writes the whole list, in the order it was handed", function()
      local ok = UserBuilds.replaceEntries(pack, key, {
        { spell = "EXORCISM" },
        { spell = "CONSECRATION", when = { { "resource", "MANA", minPct = 40 } } },
      })
      assert.is_true(ok)
      local entries = entriesOf()
      assert.equal(2, #entries)
      assert.equal("EXORCISM", entries[1].spell)
      assert.equal("CONSECRATION", entries[2].spell)
      assert.same({ { "resource", "MANA", minPct = 40 } }, entries[2].when)
    end)

    -- The Builder hangs `src` -- the saved position a draft row came from -- on every row it holds.
    -- `Schema.exportable` copies every field an entry has, so anything left here travels out in the
    -- next ELM1 string to whoever the rotation is shared with.
    it("strips the editor's own bookkeeping instead of storing it", function()
      assert.is_true(UserBuilds.replaceEntries(pack, key, {
        { spell = "EXORCISM", src = 7, selected = true },
      }))
      local entry = entriesOf()[1]
      assert.equal("EXORCISM", entry.spell)
      assert.is_nil(entry.src)
      assert.is_nil(entry.selected)
      local exported = ns.Schema.exportable(UserBuilds.find(pack, key))
      assert.is_nil(exported.entries[1].src)
      assert.is_truthy(UserBuilds.exportKey(pack, key))
    end)

    -- A whitelist can only be right if it names every field the FORMAT has. The shipped pack is the
    -- authority on that, and this is what makes adding a field to docs/03 fail here rather than
    -- silently dropping it on the first save anyone makes.
    it("keeps every field the shipped builds author", function()
      local used = {}
      for _, build in pairs(pack.builds) do
        for _, entry in ipairs(build.entries) do
          for field in pairs(entry) do used[field] = true end
        end
      end
      used.disabled = true -- written by the enable toggle, never by an author
      local kept = {}
      for _, field in ipairs(UserBuilds.ENTRY_FIELDS) do kept[field] = true end
      local dropped = {}
      for field in pairs(used) do
        if not kept[field] then dropped[#dropped + 1] = field end
      end
      table.sort(dropped)
      assert.same({}, dropped)
      -- And it really does carry them, rather than merely listing them.
      assert.is_true(UserBuilds.replaceEntries(pack, key, {
        { spell = "EXORCISM", label = "opener", hold = true, disabled = true },
        { item = 13, when = { { "item_ready", 13 } } },
      }))
      local entries = entriesOf()
      assert.equal("opener", entries[1].label)
      assert.is_true(entries[1].hold)
      assert.is_true(entries[1].disabled)
      assert.equal(13, entries[2].item)
    end)

    -- Copies, not references: a draft that shared its `when` tables with the stored build would
    -- change the saved rotation on every keystroke, and Discard could not put it back.
    it("copies the lines it is handed, all the way down", function()
      local when = { { "resource", "MANA", minPct = 40 } }
      local handed = { { spell = "CONSECRATION", when = when } }
      assert.is_true(UserBuilds.replaceEntries(pack, key, handed))
      when[1].minPct = 90
      handed[1].spell = "EXORCISM"
      local entry = entriesOf()[1]
      assert.equal("CONSECRATION", entry.spell)
      assert.equal(40, entry.when[1].minPct)
    end)

    -- All of it lands or none of it does. A half-applied save leaves a rotation that is neither
    -- what was stored nor what is on screen.
    it("refuses the whole save when one line is bad, and says which", function()
      local before = entriesOf()
      local ok, reasons = UserBuilds.replaceEntries(pack, key, {
        { spell = "EXORCISM" },
        { spell = "NOT_A_REAL_SPELL" },
      })
      assert.is_false(ok)
      assert.equal("table", type(reasons))
      assert.is_true(#reasons > 0)
      assert.is_truthy(table.concat(reasons, " "):find("NOT_A_REAL_SPELL", 1, true))
      assert.is_truthy(table.concat(reasons, " "):find("entry 2", 1, true))
      assert.equal(before, entriesOf(), "the stored rotation must be untouched")
    end)

    it("refuses a line with a condition the compiler cannot read", function()
      local ok, reasons = UserBuilds.replaceEntries(pack, key, {
        { spell = "EXORCISM", when = { { "no_such_condition" } } },
      })
      assert.is_false(ok)
      assert.is_truthy(table.concat(reasons, " "):find("no_such_condition", 1, true))
    end)

    it("refuses an empty rotation rather than storing one nothing can run", function()
      local ok, reasons = UserBuilds.replaceEntries(pack, key, {})
      assert.is_false(ok)
      assert.is_truthy(table.concat(reasons, " "):find("non-empty", 1, true))
    end)

    -- Every refusal answers with a LIST, so a caller can print the reasons without asking which
    -- shape it got back.
    it("refuses a template, a foreign class and a rotation that is not a list", function()
      local function reasonsFor(...)
        local ok, reasons = UserBuilds.replaceEntries(...)
        assert.is_false(ok)
        assert.equal("table", type(reasons))
        return table.concat(reasons, " ")
      end
      assert.equal("not one of your rotations",
                   reasonsFor(pack, "PALADIN_EXODIN", { { spell = "EXORCISM" } }))
      db.global.userBuilds.USER_MAGE_THING =
        { build = { entries = { { spell = "FIREBALL" } } }, class = "MAGE", name = "Mage" }
      assert.equal("not one of your rotations",
                   reasonsFor(pack, "USER_MAGE_THING", { { spell = "EXORCISM" } }))
      assert.is_truthy(reasonsFor(pack, key, "not a list"):find("list of lines", 1, true))
      assert.is_truthy(reasonsFor(pack, key, { "not a line" }):find("line 1", 1, true))
      -- Without the pack's tables Schema cannot check a single symbolic key, so a rotation naming
      -- spells that do not exist would be accepted and fail much later as an empty queue.
      assert.is_truthy(reasonsFor(nil, key, { { spell = "EXORCISM" } }):find("data pack", 1, true))
      assert.equal("PALADIN_EXODIN", pack.builds.PALADIN_EXODIN.key)
    end)

    -- R2b (D75/D76): the gap R2 flagged and deliberately left open. Before this pass `ctxFor` only
    -- ever saw `pack.spells`, so a spell added by id/name/spellbook (Core/Spells.lua) validated
    -- nowhere and Save refused it with "not in the spells data pack" even though the palette
    -- offered it. `ctxFor` now merges this character's registry underneath the pack's own table, so
    -- Save accepts the line -- and the merged table is the SAME one the engine compiles against
    -- (`ns.Spells.merged`), so the resolved id is the registry's, not a guess.
    it("validates and saves a registry-only spell key, and the engine resolves its id", function()
      ns.db.char.spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice",
                                       source = "spellbook" } }
      local ok, reasons = UserBuilds.replaceEntries(pack, key, { { spell = "SLICE" } })
      assert.is_true(ok, reasons and table.concat(reasons, " "))
      local build = UserBuilds.find(pack, key)
      local ctx = { spells = ns.Spells.merged(pack), sets = pack.sets, souls = pack.souls,
                    bonuses = pack.bonuses }
      local compiled = ns.compileBuild(build, ctx)
      assert.equal(900, compiled.entries[1].data.id)
    end)

    -- D75's collision policy: shipped data is the authority, always. A registry entry happening to
    -- share a pack key's NAME (a hand-edited SavedVariables file, or a coincidence of slugging) must
    -- never shadow it -- the engine keeps resolving the pack's own id.
    it("still resolves the pack's own spell when a registry entry collides with its key", function()
      ns.db.char.spells = { EXORCISM = { key = "EXORCISM", id = 1, name = "Mine", source = "id" } }
      assert.is_true(UserBuilds.replaceEntries(pack, key, { { spell = "EXORCISM" } }))
      local build = UserBuilds.find(pack, key)
      local ctx = { spells = ns.Spells.merged(pack), sets = pack.sets, souls = pack.souls,
                    bonuses = pack.bonuses }
      local compiled = ns.compileBuild(build, ctx)
      assert.equal(pack.spells.EXORCISM.id, compiled.entries[1].data.id)
      assert.are_not.equal(1, compiled.entries[1].data.id)
    end)

    -- The pre-existing defect this step exists to end, and this project's characteristic shape
    -- exactly: the panel did the edit, the store held the new rotation, and the DISPLAY went on
    -- running the compilation it had taken before it -- because `ns.compileBuild` caches on the
    -- build table and the write mutates that table in place, so the cached entry never stops
    -- looking valid. Silent until the next /reload. `Display.refresh()` does not help: it drops
    -- the painted queue and then asks `activeBuild()`, which reads straight back out of the cache.
    it("changes what the live queue compiles to", function()
      local build = UserBuilds.find(pack, key)
      local ctx = { spells = pack.spells, sets = pack.sets, souls = pack.souls,
                    bonuses = pack.bonuses }
      assert.is_true(#ns.compileBuild(build, ctx).entries > 1)
      assert.is_true(UserBuilds.replaceEntries(pack, key, { { spell = "EXORCISM" } }))
      local compiled = ns.compileBuild(build, ctx)
      assert.equal(1, #compiled.entries)
      assert.equal("EXORCISM", compiled.entries[1].spell)
    end)

    -- A refused save changed nothing, so it must not throw the compilation away either -- and the
    -- nil build a refusal carries is what `ns.forgetCompiled` has to answer for rather than raise
    -- on (indexing a table with nil is an error in Lua).
    it("leaves the cache alone when the save is refused", function()
      local build = UserBuilds.find(pack, key)
      local ctx = { spells = pack.spells, sets = pack.sets, souls = pack.souls,
                    bonuses = pack.bonuses }
      local compiled = ns.compileBuild(build, ctx)
      assert.is_false(UserBuilds.replaceEntries(pack, key, {}))
      assert.equal(compiled, ns.compileBuild(build, ctx))
      assert.is_false(ns.forgetCompiled(nil))
      assert.is_true(ns.forgetCompiled(build))
      assert.are_not.equal(compiled, ns.compileBuild(build, ctx))
    end)
  end)

  describe("slug()", function()
    it("namespaces, upper-cases, and collapses punctuation", function()
      assert.equal("USER_MY_EXODIN_V2", UserBuilds.slug("My exodin (v2)"))
    end)
    it("never returns an empty name", function()
      assert.equal("USER_BUILD", UserBuilds.slug(""))
      assert.equal("USER_BUILD", UserBuilds.slug(nil))
    end)
    it("bounds the length", function()
      local key = UserBuilds.slug(string.rep("abcdefghij", 5))
      assert.is_true(#key <= #"USER_" + 24)
    end)
    it("recognises its own keys", function()
      assert.is_true(UserBuilds.isForkKey("USER_X"))
      assert.is_false(UserBuilds.isForkKey("PALADIN_EXODIN"))
      assert.is_false(UserBuilds.isForkKey(nil))
    end)
  end)

  describe("importString()", function()
    it("stores a fork under a namespaced key, with provenance from the shipped parent", function()
      local key, err = UserBuilds.importString(exodinString(), pack, { name = "My Exodin", today = "2026-09-03" })
      assert.equal("USER_MY_EXODIN", key, tostring(err))
      local rec = db.global.userBuilds[key]
      assert.equal("PALADIN", rec.class)
      assert.equal("PALADIN_EXODIN", rec.derivedFrom)
      assert.equal("2026-09-03", rec.derivedAt)     -- the catalog's `updated` for Exodin
      assert.equal("2026-09-03", rec.importedAt)
      assert.equal("My Exodin", rec.name)
      -- The fork's own key replaces the parent's, so a Schema error names the fork (ADR-0010).
      assert.equal("USER_MY_EXODIN", rec.build.key)
      assert.equal("My Exodin", rec.build.name)
    end)

    it("defaults the name to the imported build's, and records no parent for an unknown key", function()
      local orphan = {}
      for k, v in pairs(pack.builds.PALADIN_EXODIN) do orphan[k] = v end
      orphan.key, orphan.name = "SOMEONES_EXODIN", "Someone's Exodin"
      local key = UserBuilds.importString(Serialize.encode(orphan), pack, {})
      assert.equal("USER_SOMEONE_S_EXODIN", key)
      assert.is_nil(db.global.userBuilds[key].derivedFrom)
      assert.is_nil(db.global.userBuilds[key].derivedAt)
      assert.is_nil(db.global.userBuilds[key].importedAt)
    end)

    it("never overwrites: a second import with the same name gets a numbered key", function()
      assert.equal("USER_A", UserBuilds.importString(exodinString(), pack, { name = "a" }))
      assert.equal("USER_A_2", UserBuilds.importString(exodinString(), pack, { name = "a" }))
      assert.equal("USER_A_3", UserBuilds.importString(exodinString(), pack, { name = "a" }))
    end)

    it("refuses a build for another class", function()
      local mage = {}
      for k, v in pairs(pack.builds.PALADIN_EXODIN) do mage[k] = v end
      mage.class = "MAGE"
      local key, err = UserBuilds.importString(Serialize.encode(mage), pack, {})
      assert.is_nil(key)
      assert.truthy(err:find("MAGE", 1, true))
    end)

    it("passes the codec's reason through on a bad string", function()
      local key, err = UserBuilds.importString("garbage", pack, {})
      assert.is_nil(key)
      assert.truthy(err:find("ELM1:", 1, true))
    end)

    it("says so when saved variables are not loaded, and when there is no pack", function()
      ns.db = nil
      local key, err = UserBuilds.importString(exodinString(), pack, {})
      assert.is_nil(key); assert.truthy(err:find("saved variables", 1, true))
      ns.db = db
      key, err = UserBuilds.importString(exodinString(), nil, {})
      assert.is_nil(key); assert.truthy(err:find("no data pack", 1, true))
    end)

    -- D75: registry entries are per CHARACTER, so a build exported on one and imported on another
    -- must not silently claim a spell the second one has never registered -- a readable refusal,
    -- not a crash and not a quietly dropped line. `Schema.validate`'s own "not in the spells data
    -- pack" message is the refusal, reached through the SAME merge Save uses (`ctxFor`).
    local function ghostRotation()
      local custom = {}
      for k, v in pairs(pack.builds.PALADIN_EXODIN) do custom[k] = v end
      custom.key, custom.name = "GHOST_ROTATION", "Ghost Rotation"
      custom.entries = { { spell = "SLICE" } }
      return Serialize.encode(custom)
    end

    it("refuses an import naming a registry spell this character has never registered", function()
      -- ns.db.char.spells is empty here -- exactly the state of a character who never saw the
      -- exporting player's "Slice and Dice" registration.
      local key, err = UserBuilds.importString(ghostRotation(), pack, {})
      assert.is_nil(key)
      assert.truthy(err:find("SLICE", 1, true))
      assert.truthy(err:find("spells data pack", 1, true))
      assert.is_nil(db.global.userBuilds.USER_GHOST_ROTATION, "a refused import must store nothing")
    end)

    it("accepts the same import once THIS character has that spell registered too", function()
      ns.db.char.spells = { SLICE = { key = "SLICE", id = 900, name = "Slice and Dice",
                                       source = "spellbook" } }
      local key, err = UserBuilds.importString(ghostRotation(), pack, {})
      assert.is_truthy(key, tostring(err))
      assert.equal("SLICE", db.global.userBuilds[key].build.entries[1].spell)
    end)
  end)

  it("falls back to the shared namespace when loaded without one, like every Core file", function()
    _G.__ELM_NS = {}
    assert(loadfile("Elmira/Core/UserBuilds.lua"))("Elmira")
    assert.is_table(_G.__ELM_NS.UserBuilds)
  end)

  describe("more importString() / exportKey() edges", function()
    it("works with no options at all", function()
      local key = UserBuilds.importString(exodinString(), pack)
      assert.equal("USER_PALADIN_EXODIN_FAST_2H", key)
      assert.is_nil(db.global.userBuilds[key].importedAt)
    end)

    it("says so when the serializer is not loaded, for import and export alike", function()
      local str = exodinString()
      ns.Serialize = nil
      local key, err = UserBuilds.importString(str, pack, {})
      assert.is_nil(key); assert.truthy(err:find("serializer is not loaded", 1, true))
      local out, err2 = UserBuilds.exportKey(pack, "PALADIN_EXODIN")
      assert.is_nil(out); assert.truthy(err2:find("serializer is not loaded", 1, true))
    end)

    -- The decode is validated against THIS pack's data: a string naming a spell the pack lacks
    -- must be refused here, not accepted and left to fail silently in the queue.
    it("refuses a build that names a spell this pack does not have", function()
      local ghost = { schema = 1, key = "GHOST", name = "Ghost", class = "PALADIN", flavor = "SoD",
                      entries = { { spell = "NOT_A_PALADIN_SPELL" } } }
      local key, err = UserBuilds.importString(Serialize.encode(ghost), pack, {})
      assert.is_nil(key); assert.truthy(err:find("invalid build", 1, true))
    end)
  end)

  describe("find() / list()", function()
    it("finds a shipped build first, then a fork of this class, and reports which", function()
      local build, origin = UserBuilds.find(pack, "PALADIN_EXODIN")
      assert.equal("PALADIN_EXODIN", build.key); assert.equal("pack", origin)
      local key = UserBuilds.importString(exodinString(), pack, { name = "mine" })
      local fork, forkOrigin, rec = UserBuilds.find(pack, key)
      assert.equal(key, fork.key); assert.equal("fork", forkOrigin); assert.equal("PALADIN", rec.class)
      assert.is_nil(UserBuilds.find(pack, "USER_NOPE"))
      assert.is_nil(UserBuilds.find(pack, nil))
    end)

    it("hides another class's forks from this pack, and lists only its own, sorted", function()
      UserBuilds.importString(exodinString(), pack, { name = "b" })
      UserBuilds.importString(exodinString(), pack, { name = "a" })
      db.global.userBuilds.USER_MAGE_THING = { build = { key = "USER_MAGE_THING", entries = {} }, class = "MAGE" }
      assert.same({ "USER_A", "USER_B" }, UserBuilds.list(pack))
      assert.is_nil(UserBuilds.find(pack, "USER_MAGE_THING"))
      assert.same({}, UserBuilds.list({ class = "PRIEST" }))
    end)

    it("lists nothing, and finds nothing, without saved variables", function()
      ns.db = nil
      assert.same({}, UserBuilds.list(pack))
      assert.is_nil(UserBuilds.find(pack, "USER_A"))
    end)

    -- F1 (2026-09-07 bug round): a paladin fork copied as "My-Shock" showed up on the owner's mage.
    -- Root cause: `pack == nil` used to skip the class filter entirely, and Paladin is the only
    -- class that ships a pack, so EVERY other class saw every OTHER class's forks. Verified directly
    -- against the reported symptom: the paladin fork must stay invisible with no pack at all, using
    -- the PLAYER's class (`db.keys.class`, F1a), not the pack's.
    describe("F1a: a nil pack no longer disables the class filter", function()
      before_each(function()
        db.global.userBuilds.USER_PALLY = { build = { key = "USER_PALLY", entries = {} },
                                             class = "PALADIN", name = "My-Shock" }
      end)

      it("hides a paladin's fork from a mage with no data pack of its own", function()
        ns.db.keys = { class = "MAGE", char = "Arthorion - Realm" }
        assert.same({}, UserBuilds.list(nil))
        assert.is_nil(UserBuilds.find(nil, "USER_PALLY"))
      end)

      it("still lists and finds a fork of the viewer's OWN class with no data pack", function()
        db.global.userBuilds.USER_MAGE = { build = { key = "USER_MAGE", entries = {} },
                                            class = "MAGE", name = "Mine" }
        ns.db.keys = { class = "MAGE", char = "Arthorion - Realm" }
        assert.same({ "USER_MAGE" }, UserBuilds.list(nil))
        local build = UserBuilds.find(nil, "USER_MAGE")
        assert.equal("USER_MAGE", build.key)
      end)

      it("falls back to the pack's own class when db.keys is not populated (existing callers)", function()
        assert.same({ "USER_PALLY" }, UserBuilds.list(pack))
        assert.is_not_nil(UserBuilds.find(pack, "USER_PALLY"))
      end)
    end)

    -- F1b: the owner's per-fork override, over plain class-wide visibility.
    describe("F1b: a fork marked private is hidden from every other character of the class",
      function()
      it("stays visible to everyone of the class by default", function()
        local key = UserBuilds.create(pack, "Shared")
        ns.db.keys = { class = "PALADIN", char = "OtherToon - Realm" }
        assert.same({ key }, UserBuilds.list(pack))
      end)

      it("hides the fork from a different character of the SAME class once marked private", function()
        local key = UserBuilds.create(pack, "Mine alone")
        ns.db.keys = { class = "PALADIN", char = "Arthorion - Realm" }
        assert.is_true(UserBuilds.setPrivate(key, true))
        assert.same({ key }, UserBuilds.list(pack), "still visible to the character that set it")
        ns.db.keys = { class = "PALADIN", char = "OtherToon - Realm" }
        assert.same({}, UserBuilds.list(pack))
        assert.is_nil(UserBuilds.find(pack, key))
      end)

      it("becomes visible to everyone again once turned back off", function()
        local key = UserBuilds.create(pack, "Mine alone")
        ns.db.keys = { class = "PALADIN", char = "Arthorion - Realm" }
        UserBuilds.setPrivate(key, true)
        UserBuilds.setPrivate(key, false)
        ns.db.keys = { class = "PALADIN", char = "OtherToon - Realm" }
        assert.same({ key }, UserBuilds.list(pack))
      end)

      it("refuses on a key that is not one of your rotations", function()
        local ok, err = UserBuilds.setPrivate("PALADIN_EXODIN", true)
        assert.is_false(ok)
        assert.truthy(err:find("not one of your rotations", 1, true))
      end)
    end)
  end)

  describe("exportKey() / remove()", function()
    it("exports a shipped build and a fork alike, and names a missing key", function()
      local str = UserBuilds.exportKey(pack, "PALADIN_PROT")
      assert.equal("ELM1:", str:sub(1, 5))
      local key = UserBuilds.importString(exodinString(), pack, { name = "mine" })
      assert.equal("ELM1:", UserBuilds.exportKey(pack, key):sub(1, 5))
      local none, err = UserBuilds.exportKey(pack, "GHOST")
      assert.is_nil(none); assert.truthy(err:find("GHOST", 1, true))
    end)

    it("a fork survives a round trip through export and import as a new fork", function()
      local key = UserBuilds.importString(exodinString(), pack, { name = "mine" })
      local again = UserBuilds.importString(UserBuilds.exportKey(pack, key), pack, { name = "copy" })
      assert.equal("USER_COPY", again)
      -- the copy's parent is not the fork (forks are not shipped keys) -- provenance never borrows
      assert.is_nil(db.global.userBuilds[again].derivedFrom)
    end)

    it("removes a fork and reports whether there was one", function()
      local key = UserBuilds.importString(exodinString(), pack, { name = "gone" })
      assert.is_true(UserBuilds.remove(key))
      assert.is_false(UserBuilds.remove(key))
      assert.is_nil(UserBuilds.find(pack, key))
    end)
  end)

  -- D35's "New rotation": an EMPTY fork with no `derivedFrom` at all, unlike `fork()` (above), which
  -- REFUSES a nil/unknown template. This is the second, small writer for that reason.
  describe("create()", function()
    it("writes an empty, findable fork with no derivedFrom", function()
      local key, err = UserBuilds.create(pack, "My rotation")
      assert.is_nil(err)
      assert.is_truthy(key:find("^USER_"))
      local build, origin, fork = UserBuilds.find(pack, key)
      assert.equal("fork", origin)
      assert.same({}, build.entries)
      assert.equal("My rotation", build.name)
      assert.equal("My rotation", fork.name)
      assert.is_nil(fork.derivedFrom)
    end)

    it("refuses without saved variables, or with neither a class pack nor a known class", function()
      ns.db = nil
      local key, err = UserBuilds.create(pack, "My rotation")
      assert.is_nil(key)
      assert.truthy(err:find("saved variables", 1, true))
      ns.db = db
      local key2, err2 = UserBuilds.create(nil, "My rotation")
      assert.is_nil(key2)
      assert.truthy(err2:find("data pack", 1, true))
    end)

    -- F1c: `create` refusing on a nil pack made F1a's fix incoherent -- a mage would correctly see
    -- an empty fork list and then be unable to create anything at all. It takes the class from the
    -- same `db.keys` source `find`/`list` now do, so a class with no shipped pack can still create.
    it("F1c: creates for a class with no data pack, using db.keys.class", function()
      ns.db.keys = { class = "MAGE", char = "Arthorion - Realm" }
      local key, err = UserBuilds.create(nil, "My mage rotation")
      assert.is_nil(err)
      assert.is_truthy(key:find("^USER_"))
      local build, origin = UserBuilds.find(nil, key)
      assert.equal("fork", origin)
      assert.equal("MAGE", db.global.userBuilds[key].class)
      assert.same({}, build.entries)
    end)

    it("names collide safely, the same uniqueKey scheme fork() uses", function()
      local a = UserBuilds.create(pack, "My rotation")
      local b = UserBuilds.create(pack, "My rotation")
      assert.is_not.equal(a, b)
    end)
  end)

  -- The key stays stable (SelectGroup/derivedFrom paths depend on it); only the display name --
  -- both the record's own `name` and the build's own `name` -- changes.
  describe("rename()", function()
    it("renames both the record and the build, keeping the key", function()
      local key = UserBuilds.create(pack, "My rotation")
      assert.is_true(UserBuilds.rename(key, "New name"))
      local build, _, fork = UserBuilds.find(pack, key)
      assert.equal("New name", build.name)
      assert.equal("New name", fork.name)
      assert.equal(key, build.key)
    end)

    it("refuses a key that is not one of your rotations", function()
      local ok, err = UserBuilds.rename("PALADIN_EXODIN", "New name")
      assert.is_false(ok)
      assert.truthy(err:find("not one of your rotations", 1, true))
    end)

    it("refuses a blank or missing name", function()
      local key = UserBuilds.create(pack, "My rotation")
      local ok, err = UserBuilds.rename(key, "")
      assert.is_false(ok)
      assert.truthy(err:find("name", 1, true))
      local build = UserBuilds.find(pack, key)
      assert.equal("My rotation", build.name)
    end)
  end)

  -- D47. The one place a storage key becomes words. It lives here, next to the catalog lookup and
  -- the fork records it reads, because Display/Driver's gear-change announcement is assembled from
  -- the key and Display may not reach into Options for a string (hard rule 3's layering).
  describe("displayName()", function()
    it("gives a shipped build the catalog's playstyle name", function()
      local entry = pack.catalog[pack.class][1]
      assert.equal("PALADIN_EXODIN", entry.build)
      assert.is_not.equal(entry.build, entry.playstyle)
      assert.equal(entry.playstyle, UserBuilds.displayName(pack, "PALADIN_EXODIN"))
    end)

    it("gives a fork the name its owner typed, never the USER_ slug", function()
      local key = UserBuilds.create(pack, "My rotation")
      assert.equal("USER_MY_ROTATION", key)
      assert.equal("My rotation", UserBuilds.displayName(pack, key))
    end)

    it("falls back to the key: an ugly name beats a blank one", function()
      assert.equal("PALADIN_GONE", UserBuilds.displayName(pack, "PALADIN_GONE"))
      assert.equal("USER_GHOST", UserBuilds.displayName(pack, "USER_GHOST"))
      assert.equal("PALADIN_EXODIN", UserBuilds.displayName(nil, "PALADIN_EXODIN"))
    end)

    it("falls back to the key for a catalog entry that names no playstyle", function()
      local thin = { class = "PALADIN", catalog = { PALADIN = { { build = "PALADIN_EXODIN" } } } }
      assert.equal("PALADIN_EXODIN", UserBuilds.displayName(thin, "PALADIN_EXODIN"))
    end)

    it("answers for a non-string rather than erroring", function()
      assert.equal("?", UserBuilds.displayName(pack, nil))
      assert.equal("?", UserBuilds.displayName(pack, 7))
    end)
  end)

  -- AB2-D5: "include ability settings". The rotation and the settings of the abilities it names
  -- travel in ONE string, and the settings are applied at the one place a build string is accepted
  -- -- a second call site is a second place to forget, and settings that silently did not arrive
  -- look exactly like settings the sender never included.
  describe("exporting and importing a rotation WITH its abilities' settings", function()
    local A

    before_each(function()
      A = helper.load("Elmira/Core/AbilitySettings.lua")
      db.char.abilities = {}
    end)

    it("exports the rotation alone when nothing extra is handed over", function()
      local str = assert(UserBuilds.exportKey(pack, "PALADIN_EXODIN"))
      local back = assert(Serialize.decodeBundle(str, { spells = pack.spells }))
      assert.is_table(back.build)
      assert.is_nil(back.abilities)
    end)

    it("carries the settings it was handed, and applies them on import", function()
      local str = assert(UserBuilds.exportKey(pack, "PALADIN_EXODIN", {
        abilities = { EXORCISM = { edge = { enabled = true, intensity = 0.9 }, inherit = nil } },
        spells = { EXORCISM = { id = 415073, name = "Exorcism" } },
      }))
      local key, merged = UserBuilds.importString(str, pack, { name = "Mine" })
      assert.is_string(key)
      assert.equal(1, merged)
      assert.is_true(A.effective("EXORCISM", "edge").enabled)
      assert.same({ id = 415073, name = "Exorcism" }, A.spellInfo("EXORCISM"))
    end)

    it("reports no settings for a plain rotation string, without erroring", function()
      local key, merged = UserBuilds.importString(exodinString(), pack, {})
      assert.is_string(key)
      assert.equal(0, merged)
      assert.same({}, db.char.abilities)
    end)

    it("refuses a settings-only string as a rotation, with a reason", function()
      local str = assert(Serialize.encodeBundle({ abilities = { EXORCISM = { edge = {} } } }))
      local key, err = UserBuilds.importString(str, pack, {})
      assert.is_nil(key)
      assert.is_truthy(err:find("no build", 1, true))
      assert.same({}, db.char.abilities, "nothing was written on the way to refusing it")
    end)
  end)

end)
