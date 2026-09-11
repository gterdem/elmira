local helper = require("tests.helper")

-- Elmira/Display/TextureLibrary.lua — the visual texture library's data and lookups (AT4-D2).
--
-- Pure: no frames, no client, no `ns`. What this file guards is that the picker has something to
-- show and that every entry in it is a fact about a file rather than a name somebody invented --
-- an empty category, a name generated off the wrong segment of a path, or a WeakAuras category
-- offered on a character without WeakAuras all look exactly like a working picker until the grid is
-- on screen.
describe("Display.TextureLibrary", function()
  local Library

  -- The counts, spelled out. Not decoration: the whole point of this module is that the picker is
  -- FULL, and a refactor that silently drops a category (or one that quietly lists the ~86 Blizzard
  -- alert textures Classic Era does not have) is invisible in every other test.
  local EXPECTED = {
    elmira = 8, beams = 12, icons = 19, pvp = 105, runes = 17, sparks = 1, markers = 9,
    weakauras = 35, powerauras = 145,
  }

  local function group(key)
    for _, g in ipairs(Library.GROUPS) do
      if g.key == key then return g end
    end
  end

  local function keysOf(list)
    local out = {}
    for _, g in ipairs(list) do out[#out + 1] = g.key end
    return out
  end

  before_each(function()
    helper.reset()
    Library = helper.load("Elmira/Display/TextureLibrary.lua")
  end)

  describe("the categories", function()
    it("offers them in the order the picker's dropdown draws them", function()
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers",
                    "weakauras", "powerauras" }, keysOf(Library.GROUPS))
    end)

    it("fills every one of them", function()
      local total = 0
      for _, g in ipairs(Library.GROUPS) do
        assert.equal(EXPECTED[g.key], #g.textures, g.key .. " has the wrong number of textures")
        total = total + #g.textures
      end
      assert.equal(351, total)
    end)

    it("gives every texture a path and a name of our own", function()
      for _, g in ipairs(Library.GROUPS) do
        for _, entry in ipairs(g.textures) do
          assert.is_string(entry.path, g.key .. " has an entry with no file")
          assert.not_equal("", entry.path)
          assert.is_string(entry.name, entry.path .. " has no name")
          assert.not_equal("", entry.name)
        end
      end
    end)

    -- The licence line, as a test: not one file of WeakAuras' or PowerAuras' is copied into this
    -- repository, so every entry that names one points at the PLAYER's own installation.
    it("points at WeakAuras' own folder for the two categories that need it", function()
      assert.equal("WeakAuras", group("weakauras").requires)
      assert.equal("WeakAuras", group("powerauras").requires)
      for _, entry in ipairs(group("weakauras").textures) do
        local folder = "Interface\\AddOns\\WeakAuras\\Media\\Textures\\"
        assert.equal(folder, entry.path:sub(1, #folder))
      end
      assert.equal("Interface\\Addons\\WeakAuras\\PowerAurasMedia\\Auras\\Aura1",
        group("powerauras").textures[1].path)
      assert.equal("Interface\\Addons\\WeakAuras\\PowerAurasMedia\\Auras\\Aura145",
        group("powerauras").textures[145].path)
    end)

    it("asks nothing of the client for the seven categories every character has", function()
      for _, key in ipairs({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers" }) do
        assert.is_nil(group(key).requires, key .. " must be offered to everyone")
      end
    end)

    -- Blizzard's art is addressable only by numeric file id on this client, and the ids listed are
    -- the ones that resolve on CLASSIC ERA -- the alerts family, and the 17 beams / 9 icons /
    -- 9 runes this flavour lacks, are deliberately absent rather than drawn as empty cells.
    it("lists Blizzard's art as file ids and skips what Classic Era does not have", function()
      for _, key in ipairs({ "beams", "icons", "runes", "sparks" }) do
        for _, entry in ipairs(group(key).textures) do
          assert.is_truthy(tonumber(entry.path), entry.path .. " is not a file id")
        end
      end
      local ids = {}
      for _, entry in ipairs(group("beams").textures) do ids[entry.path] = true end
      assert.is_nil(ids["167096"], "a beam Classic Era does not have")
      assert.is_truthy(ids["186185"], "a beam it does")
    end)

    -- AT6-D2: the category is "Shapes", not "Elmira Shapes" -- this is Elmira's own picker, so
    -- saying so twice in one dropdown says nothing. WeakAuras keeps its name, where it earns it.
    it("names the shipped shapes group after the shapes, not after the addon", function()
      assert.equal("Shapes", group("elmira").name)
      assert.equal("WeakAuras Shapes", group("weakauras").name)
    end)

    it("names the shipped shapes after the shape, not after the file", function()
      local names = {}
      for _, entry in ipairs(group("elmira").textures) do names[#names + 1] = entry.name end
      assert.same({ "Ring", "Disc", "Square", "Diamond", "Arrow", "Star", "Bar", "Chevron" }, names)
      assert.equal("Interface\\AddOns\\Elmira\\media\\shape_ring", group("elmira").textures[1].path)
    end)
  end)

  describe("groups(isLoaded)", function()
    it("drops the WeakAuras categories on a character that is not running it", function()
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers" },
        keysOf(Library.groups(function() return false end)))
      -- nil predicate is the same answer: a caller that cannot ask must not offer files that would
      -- draw nothing.
      assert.equal(7, #Library.groups(nil))
    end)

    it("offers them to one that is", function()
      local asked = {}
      local list = Library.groups(function(name)
        asked[#asked + 1] = name
        return name == "WeakAuras"
      end)
      assert.same({ "elmira", "beams", "icons", "pvp", "runes", "sparks", "markers",
                    "weakauras", "powerauras" }, keysOf(list))
      assert.same({ "WeakAuras", "WeakAuras" }, asked, "the addon is named, not assumed")
    end)

    it("hands back the same texture tables, never copies", function()
      assert.equal(group("elmira").textures, Library.groups(nil)[1].textures)
    end)
  end)

  -- AT4-D3: what makes a stored path say WHY it draws nothing on this character.
  describe("requires(path)", function()
    it("names WeakAuras for anything inside its folder, whichever way it is spelled", function()
      assert.equal("WeakAuras",
        Library.requires("Interface\\AddOns\\WeakAuras\\Media\\Textures\\Ring_10px.tga"))
      assert.equal("WeakAuras",
        Library.requires("Interface\\Addons\\WeakAuras\\PowerAurasMedia\\Auras\\Aura9"))
      -- Case-insensitive and slash-insensitive: the client treats all four spellings as one file.
      assert.equal("WeakAuras",
        Library.requires("interface/addons/weakauras/Media/Textures/triangle.tga"))
    end)

    it("names nothing for a path or a file id every client has", function()
      assert.is_nil(Library.requires("Interface\\AddOns\\Elmira\\media\\shape_ring"))
      assert.is_nil(Library.requires("Interface\\Icons\\Spell_Holy_Excorcism"))
      assert.is_nil(Library.requires("165558"))
      assert.is_nil(Library.requires(nil))
      -- A folder that merely MENTIONS WeakAuras further along is somebody else's addon.
      assert.is_nil(Library.requires("Interface\\AddOns\\MyPack\\WeakAuras\\thing.tga"))
    end)
  end)

  describe("drawable(path)", function()
    -- A file id passed to SetTexture as a string draws nothing at all, which is indistinguishable
    -- from a working setting once the ring fallback has been drawn over it.
    it("turns a stored file id back into a number and leaves a path alone", function()
      assert.equal(165558, Library.drawable("165558"))
      assert.equal("Interface\\Icons\\X", Library.drawable("Interface\\Icons\\X"))
    end)
  end)

  describe("matches(name, needle)", function()
    it("is a plain case-insensitive substring, never a pattern", function()
      assert.is_true(Library.matches("Circle Smooth Border", "smooth"))
      assert.is_true(Library.matches("Circle Smooth Border", "CIRCLE"))
      assert.is_false(Library.matches("Circle Smooth Border", "square"))
      -- Typing a pattern character must filter, not error and not match everything.
      assert.is_false(Library.matches("Circle Smooth", "%d"))
      assert.is_true(Library.matches("Ring 10px", "10px"))
    end)

    it("matches everything while the search box is empty", function()
      assert.is_true(Library.matches("anything", ""))
      assert.is_true(Library.matches("anything", nil))
    end)
  end)

  describe("nameFromPath(path)", function()
    it("reads the last segment, drops the extension and splits the words", function()
      assert.equal("Circle Alpha Gradient In",
        Library.nameFromPath("Interface\\AddOns\\WeakAuras\\Media\\Textures\\Circle_AlphaGradient_In.tga"))
      assert.equal("Triangle 45", Library.nameFromPath("Triangle45"))
      assert.equal("Square Border 1px", Library.nameFromPath("square_border_1px.tga"))
      assert.equal("Ring Glow 3", Library.nameFromPath("ring_glow3.tga"))
      -- Already-shouted words keep their capitals; a forward slash separates as a backslash does.
      assert.equal("PVP Banner Emblem 7",
        Library.nameFromPath("Interface\\PVPFrame\\PVP-Banner-Emblem-7"))
      assert.equal("Thing", Library.nameFromPath("Interface/Icons/thing"))
    end)

    it("answers with something for a path that is barely one", function()
      assert.equal("", Library.nameFromPath(nil))
      assert.equal("", Library.nameFromPath(""))
      assert.equal("165558", Library.nameFromPath("165558"))
    end)
  end)
end)
