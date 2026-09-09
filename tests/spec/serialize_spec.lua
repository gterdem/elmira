-- tests/spec/serialize_spec.lua — Core/Serialize.lua against the REAL LibSerialize and LibDeflate
-- (docs/02 "Import/export string", PRD F9). The codec that ships is the codec tested: a fake that
-- round-trips by construction would prove nothing about the string a player actually pastes.
local helper = require("tests.helper")

describe("Core.Serialize", function()
  local Serialize, Schema, LS, LD, pack

  -- LibSerialize creates a frame at load (its async path), so the client mock must be present.
  local function loadCodec()
    if not _G.CreateFrame then dofile("tests/wow_mock.lua") end
    _G.LibStub = nil
    for _, path in ipairs({ "Elmira/Libs/LibStub/LibStub.lua", "Elmira/Libs/LibSerialize/LibSerialize.lua",
                            "Elmira/Libs/LibDeflate/LibDeflate.lua" }) do
      local chunk, err = loadfile(path)
      assert(chunk, "the real codec lives in the gitignored Elmira/Libs/: run `make libs` (" .. tostring(err) .. ")")
      chunk()
    end
    return LibStub("LibSerialize"), LibStub("LibDeflate")
  end

  before_each(function()
    helper.reset()
    helper.load("Elmira/Adapters/Interface.lua")
    Schema = helper.load("Elmira/Core/Schema.lua")
    Serialize = helper.load("Elmira/Core/Serialize.lua")
    LS, LD = loadCodec()
    assert.is_true(Serialize.use{ serializer = LS, deflate = LD })
    pack = helper.classPack("Paladin")
  end)

  local function ctx() return { spells = pack.spells, sets = pack.sets, souls = pack.souls, bonuses = pack.bonuses } end

  -- Roadmap M5 acceptance: "Round-trip of every shipped build".
  it("round-trips every shipped build to a deep-equal table", function()
    local n = 0
    for key, build in pairs(pack.builds) do
      local str, err = Serialize.encode(build)
      assert.is_string(str, key .. ": " .. tostring(err))
      local back, derr = Serialize.decode(str, ctx())
      assert.is_table(back, key .. ": " .. tostring(derr))
      assert.same(build, back)
      n = n + 1
    end
    assert.is_true(n >= 4, "expected the shipped paladin builds, found " .. n)
  end)

  it("produces a single printable line with the ELM1: prefix", function()
    local str = Serialize.encode(pack.builds.PALADIN_EXODIN)
    assert.equal("ELM1:", str:sub(1, 5))
    assert.is_nil(str:find("%s"))
    assert.is_true(#str > 100)
  end)

  it("tolerates surrounding whitespace on import", function()
    local str = Serialize.encode(pack.builds.PALADIN_WRATHLIKE)
    local back = Serialize.decode("  \n" .. str .. "\n ", ctx())
    assert.equal("PALADIN_WRATHLIKE", back.key)
  end)

  describe("rejection", function()
    it("refuses a string without the prefix, naming the prefix", function()
      local build, err = Serialize.decode("hello", ctx())
      assert.is_nil(build)
      assert.truthy(err:find("ELM1:", 1, true))
    end)

    it("refuses a corrupted payload without erroring", function()
      local str = Serialize.encode(pack.builds.PALADIN_EXODIN)
      local broken = str:sub(1, 40) .. "!!!!" .. str:sub(45)
      local ok, build, err = pcall(Serialize.decode, broken, ctx())
      assert.is_true(ok)
      assert.is_nil(build)
      assert.truthy(err:find("corrupted", 1, true))
    end)

    it("refuses an unknown string version", function()
      local payload = LS:Serialize({ v = 99, build = { key = "X", entries = {} } })
      local str = "ELM1:" .. LD:EncodeForPrint(LD:CompressDeflate(payload))
      local build, err = Serialize.decode(str, ctx())
      assert.is_nil(build)
      assert.truthy(err:find("version 99", 1, true))
    end)

    it("refuses a string with no build in it", function()
      local payload = LS:Serialize({ v = 1 })
      local build, err = Serialize.decode("ELM1:" .. LD:EncodeForPrint(LD:CompressDeflate(payload)), ctx())
      assert.is_nil(build)
      assert.truthy(err:find("no build", 1, true))
    end)

    it("refuses a build that does not validate against this pack's data", function()
      local str = Serialize.encode({ schema = 1, key = "GHOST", name = "Ghost", class = "PALADIN", flavor = "SoD",
                                     entries = { { spell = "NOT_A_PALADIN_SPELL" } } })
      local build, err = Serialize.decode(str, ctx())
      assert.is_nil(build)
      assert.truthy(err:find("invalid build", 1, true))
    end)

    it("says the codec is unavailable, rather than erroring, when the libraries were not handed in", function()
      assert.is_false(Serialize.use(nil))
      assert.is_false(Serialize.available())
      local str, err = Serialize.encode(pack.builds.PALADIN_EXODIN)
      assert.is_nil(str); assert.truthy(err:find("cannot export", 1, true))
      local build, derr = Serialize.decode("ELM1:x", ctx())
      assert.is_nil(build); assert.truthy(derr:find("cannot import", 1, true))
    end)
  end)

  describe("custom conditions", function()
    local function buildWithCustom()
      return { schema = 1, key = "CUSTOM_ONE", name = "Custom", class = "PALADIN", flavor = "SoD",
               entries = {
                 { spell = "EXORCISM", when = { {"custom", function() return true end} } },
                 { spell = "CRUSADER_STRIKE" },
               } }
    end

    it("strips them, marks the entry disabled, and still exports the rest", function()
      local str, err = Serialize.encode(buildWithCustom())
      assert.is_string(str, tostring(err))
      local back = Serialize.decode(str, ctx())
      assert.is_true(back.entries[1].disabled)
      assert.is_nil(back.entries[1].when)
      assert.equal("CRUSADER_STRIKE", back.entries[2].spell)
      assert.is_nil(back.entries[2].disabled)
    end)

    -- The half that makes "disabled" true: a stripped entry has NO `when`, and an unconditional line
    -- would fire every global. Schema.compile leaves disabled entries out of the compiled list.
    it("compiles to nothing, so the stripped line cannot become unconditional", function()
      local back = Serialize.decode(Serialize.encode(buildWithCustom()), ctx())
      local compiled, errors = Schema.compile(back, ctx())
      assert.is_table(compiled, table.concat(Schema.errorLines(errors or {}), "; "))
      assert.equal(1, #compiled.entries)
      assert.equal("CRUSADER_STRIKE", compiled.entries[1].spell)
      assert.equal(2, compiled.entries[1].index)
    end)
  end)

  it("falls back to the shared namespace when loaded without one, like every Core file", function()
    _G.__ELM_NS = {}
    assert(loadfile("Elmira/Core/Serialize.lua"))("Elmira")
    assert.is_table(_G.__ELM_NS.Serialize)
  end)

  describe("guards", function()
    it("refuses to encode something that is not a build", function()
      local str, err = Serialize.encode(nil)
      assert.is_nil(str); assert.equal("not a build", err)
      assert.is_nil(Serialize.encode("PALADIN_EXODIN"))
    end)

    it("drops function fields anywhere in the build rather than failing to serialize", function()
      local build = { schema = 1, key = "FN", name = "Fn", class = "PALADIN", flavor = "SoD",
                      onLoad = function() end,
                      entries = { { spell = "EXORCISM", hook = function() end } } }
      local str, err = Serialize.encode(build)
      assert.is_string(str, tostring(err))
      local back = Serialize.decode(str, ctx())
      assert.is_nil(back.onLoad)
      assert.is_nil(back.entries[1].hook)
      assert.equal("EXORCISM", back.entries[1].spell)
    end)

    it("reports a serializer failure with its reason", function()
      Serialize.use{ serializer = { Serialize = function() error("boom") end, Deserialize = function() end }, deflate = LD }
      local str, err = Serialize.encode(pack.builds.PALADIN_EXODIN)
      assert.is_nil(str); assert.truthy(err:find("serialize failed", 1, true)); assert.truthy(err:find("boom", 1, true))
    end)

    it("reports a compressor failure", function()
      Serialize.use{ serializer = LS, deflate = { CompressDeflate = function() return nil end, EncodeForPrint = LD.EncodeForPrint,
                                                  DecodeForPrint = LD.DecodeForPrint, DecompressDeflate = LD.DecompressDeflate } }
      local str, err = Serialize.encode(pack.builds.PALADIN_EXODIN)
      assert.is_nil(str); assert.equal("compress failed", err)
    end)

    it("refuses to decode something that is not a string", function()
      local build, err = Serialize.decode(nil, ctx())
      assert.is_nil(build); assert.equal("not a string", err)
    end)

    it("tells apart a payload that decodes but will not decompress", function()
      local build, err = Serialize.decode("ELM1:" .. LD:EncodeForPrint("this was never deflated"), ctx())
      assert.is_nil(build); assert.truthy(err:find("could not decompress", 1, true))
    end)

    it("tells apart a payload that decompresses but is not a serialized table", function()
      local build, err = Serialize.decode("ELM1:" .. LD:EncodeForPrint(LD:CompressDeflate("not a LibSerialize payload")), ctx())
      assert.is_nil(build); assert.truthy(err:find("could not deserialize", 1, true))
    end)
  end)

  it("never carries compiled artefacts: exporting a compiled build yields the plain one", function()
    local compiled = Schema.compile(pack.builds.PALADIN_EXODIN, ctx())
    local back = Serialize.decode(Serialize.encode(compiled), ctx())
    assert.is_nil(back.compiled)
    assert.is_nil(back.entries[1].test)
    assert.is_nil(back.entries[1].data)
    assert.is_nil(back.entries[1].conditions)
    assert.same(pack.builds.PALADIN_EXODIN.entries[1], back.entries[1])
  end)

  -- AB2-D5: one payload shape for everything Elmira shares -- a rotation, a rotation WITH the
  -- settings of the abilities it names, or a bare bag of settings. One format, one decoder.
  describe("bundles (AB2-D5)", function()
    local A

    before_each(function()
      A = helper.load("Elmira/Core/AbilitySettings.lua")
      helper.ns().db = { char = { abilities = {} } }
    end)

    it("round-trips ability settings through the real codec, unchanged", function()
      A.set("EXORCISM", "edge", "enabled", true)
      A.setInherit("EXORCISM", "edge", false)
      A.set("EXORCISM", "edge", "edge", "top")
      A.set("EXORCISM", "edge", "color", { r = 0.9, g = 0.2, b = 0.2 })
      A.set("*", "sound", "used", "Chime")
      local source = A.export(nil)
      local str = assert(Serialize.encodeBundle({ abilities = source,
        spells = { EXORCISM = { id = 415073, name = "Exorcism" } } }))
      assert.equal("ELM1:", str:sub(1, 5))

      -- A fresh character, nothing configured.
      helper.ns().db = { char = { abilities = {} } }
      local back = assert(Serialize.decodeBundle(str))
      assert.same(source, back.abilities)
      assert.equal(2, A.import(back.abilities, back.spells))
      assert.same(source, A.export(nil))
      assert.equal("top", A.effective("EXORCISM", "edge").edge)
      assert.same({ id = 415073, name = "Exorcism" }, A.spellInfo("EXORCISM"))
    end)

    it("carries a rotation and its abilities' settings in one string", function()
      local build = pack.builds.PALADIN_EXODIN
      local str = assert(Serialize.encodeBundle({ build = build,
        abilities = { EXORCISM = { edge = { enabled = true } } } }))
      local back = assert(Serialize.decodeBundle(str, ctx()))
      assert.same(build, back.build)
      assert.is_true(back.abilities.EXORCISM.edge.enabled)
    end)

    -- A settings-only string has no build to check against a pack, which is exactly what makes it
    -- importable on a class with no shipped data at all (the standing rule for this pass).
    it("decodes a settings-only bundle with no pack context", function()
      local str = assert(Serialize.encodeBundle({ abilities = { X = { edge = {} } } }))
      local back = assert(Serialize.decodeBundle(str))
      assert.is_nil(back.build)
      assert.is_table(back.abilities.X)
    end)

    it("still validates a build that IS in the bundle", function()
      local str = assert(Serialize.encodeBundle({ build = { schema = 1, key = "K", name = "N",
        class = "PALADIN", entries = { { spell = "NOT_A_SPELL" } } } }))
      local back, err = Serialize.decodeBundle(str, ctx())
      assert.is_nil(back)
      assert.is_truthy(err:find("NOT_A_SPELL", 1, true))
    end)

    it("refuses to export nothing, and refuses a build that is not a table", function()
      local str, err = Serialize.encodeBundle(nil)
      assert.is_nil(str)
      assert.is_string(err)
      str, err = Serialize.encodeBundle({ build = "PALADIN_EXODIN" })
      assert.is_nil(str)
      assert.is_string(err)
    end)

    -- `Serialize.decode` is the rotation half of the same payload: a settings-only string pasted
    -- into the Rotations box has to be refused with a reason rather than half-imported.
    it("refuses a settings-only string through the build-only decoder", function()
      local str = assert(Serialize.encodeBundle({ abilities = { X = { edge = {} } } }))
      local build, err = Serialize.decode(str, ctx())
      assert.is_nil(build)
      assert.is_truthy(err:find("no build", 1, true))
    end)
  end)

end)
