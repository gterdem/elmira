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
