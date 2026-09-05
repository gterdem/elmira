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
    local LS, LD = loadCodec()
    Serialize.use{ serializer = LS, deflate = LD }
    pack = helper.classPack("Paladin")
    db = { global = { userBuilds = {} } }
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
  describe("moveEntry() and setEntryDisabled()", function()
    local key
    before_each(function() key = UserBuilds.fork(pack, "PALADIN_EXODIN", {}) end)

    -- `e.spell or item:N`, never `e.spell` alone: an entry that binds to an inventory slot has no
    -- spell, and appending nil silently shortens the list -- which made this helper disagree with
    -- the real entry count and the off-the-end assertions pass for the wrong reason.
    local function spellsOf()
      local out = {}
      for _, e in ipairs(UserBuilds.find(pack, key).entries) do
        out[#out + 1] = e.spell or ("item:" .. tostring(e.item))
      end
      return out
    end

    it("swaps a line with the one above it", function()
      local before = spellsOf()
      assert.is_true(UserBuilds.moveEntry(pack, key, 2, -1))
      local after = spellsOf()
      assert.equal(before[2], after[1])
      assert.equal(before[1], after[2])
      assert.equal(#before, #after)
    end)

    it("swaps a line with the one below it", function()
      local before = spellsOf()
      assert.is_true(UserBuilds.moveEntry(pack, key, 1, 1))
      assert.equal(before[1], spellsOf()[2])
    end)

    it("refuses to move off either end rather than dropping the line", function()
      local before = spellsOf()
      assert.is_false(UserBuilds.moveEntry(pack, key, 1, -1))
      assert.is_false(UserBuilds.moveEntry(pack, key, #before, 1))
      assert.is_false(UserBuilds.moveEntry(pack, key, 0, 1))
      assert.is_false(UserBuilds.moveEntry(pack, key, #before + 1, -1))
      assert.same(before, spellsOf())
    end)

    -- A template is read-only (ADR-0005, hard rule 7). The Builder must not be the one place that
    -- can quietly write to one.
    it("refuses to edit a shipped template, and says why", function()
      local ok, why = UserBuilds.moveEntry(pack, "PALADIN_EXODIN", 1, 1)
      assert.is_false(ok)
      assert.equal("not one of your rotations", why)
      ok, why = UserBuilds.setEntryDisabled(pack, "PALADIN_EXODIN", 1, true)
      assert.is_false(ok)
      assert.equal("not one of your rotations", why)
      assert.is_false(UserBuilds.moveEntry(pack, "USER_NOT_A_THING", 1, 1))
      -- The template itself is untouched, which is the point (ADR-0005, hard rule 7).
      assert.is_nil(pack.builds.PALADIN_EXODIN.entries[1].disabled)
    end)

    -- Structural, not incidental: a template key is refused because it is not a USER_ key, rather
    -- than because templates happen not to live in db.global.userBuilds.
    -- db.global is shared across every character on the account, so the class check is what stops
    -- a mage reordering a paladin's rotation. The key prefix alone cannot tell them apart.
    it("refuses a fork belonging to another class", function()
      db.global.userBuilds.USER_MAGE_THING =
        { build = { entries = { { spell = "FIREBALL" } } }, class = "MAGE", name = "Mage" }
      local ok, why = UserBuilds.moveEntry(pack, "USER_MAGE_THING", 1, 1)
      assert.is_false(ok)
      assert.equal("not one of your rotations", why)
      assert.is_false(UserBuilds.setEntryDisabled(pack, "USER_MAGE_THING", 1, true))
    end)

    it("refuses any key that is not one of the user's own", function()
      assert.is_false(UserBuilds.moveEntry(pack, "PALADIN_EXODIN", 1, 1))
      assert.is_false(UserBuilds.moveEntry(pack, nil, 1, 1))
      assert.is_false(UserBuilds.moveEntry(pack, 42, 1, 1))
      assert.is_false(UserBuilds.setEntryDisabled(pack, "NOT_PREFIXED", 1, true))
    end)

    -- A fork whose build survived import with no entries -- possible for a hand-edited or truncated
    -- string. It is still YOURS, so the refusal has to say something different from "not one of
    -- your rotations", or the panel would tell you a rotation you are looking at is not yours.
    it("distinguishes an empty rotation from one that is not yours", function()
      db.global.userBuilds.USER_EMPTY = { build = { key = "USER_EMPTY" }, class = pack.class,
                                          name = "Empty" }
      local ok, why = UserBuilds.moveEntry(pack, "USER_EMPTY", 1, 1)
      assert.is_false(ok)
      assert.equal("that rotation has no lines", why)
      assert.is_false(UserBuilds.setEntryDisabled(pack, "USER_EMPTY", 1, true))
    end)

    it("says why when a line is out of range", function()
      local ok, why = UserBuilds.moveEntry(pack, key, 1, -1)
      assert.is_false(ok)
      assert.equal("out of range", why)
      ok, why = UserBuilds.setEntryDisabled(pack, key, 99, true)
      assert.is_false(ok)
      assert.equal("out of range", why)
    end)

    it("turns a line off and on again", function()
      assert.is_true(UserBuilds.setEntryDisabled(pack, key, 1, true))
      assert.is_true(UserBuilds.find(pack, key).entries[1].disabled)
      assert.is_true(UserBuilds.setEntryDisabled(pack, key, 1, false))
      -- nil, not false: Schema.compile and Schema.exportable both test truthiness, and an exported
      -- build carrying `disabled = false` on every line is noise that travels to whoever imports it.
      assert.is_nil(UserBuilds.find(pack, key).entries[1].disabled)
    end)

    it("refuses a line that is not there", function()
      assert.is_false(UserBuilds.setEntryDisabled(pack, key, 99, true))
    end)

    -- The point of the checkbox: a disabled line must actually leave the rotation.
    it("a disabled line is skipped when the build compiles", function()
      local build = UserBuilds.find(pack, key)
      local before = #ns.Schema.compile(build, { spells = pack.spells, sets = pack.sets,
        souls = pack.souls, bonuses = pack.bonuses }).entries
      UserBuilds.setEntryDisabled(pack, key, 1, true)
      local after = #ns.Schema.compile(build, { spells = pack.spells, sets = pack.sets,
        souls = pack.souls, bonuses = pack.bonuses }).entries
      assert.equal(before - 1, after)
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
end)
