local helper = require("tests.helper")

-- Elmira/Display/Sounds.lua — the one LibSharedMedia fetch and PlaySoundFile call in the addon
-- (AB1-D8). Two callers: the announcement sink and the Abilities page's per-event sounds. Every
-- failure has to be a quiet `false`, because the options panel plays a sound from inside a `set`
-- and an error thrown there takes the panel with it.
describe("Display.Sounds", function()
  local Sounds, ns, played

  local function withMedia(lsm)
    _G.LibStub = function(major) return major == "LibSharedMedia-3.0" and lsm or nil end
  end

  before_each(function()
    ns = helper.reset()
    played = {}
    _G.PlaySoundFile = function(path) played[#played + 1] = path end
    withMedia({
      List = function() return { "Elmira chime", "Whistle" } end,
      Fetch = function(_, kind, name)
        if kind == "sound" and name == "Elmira chime" then return "Interface\\Media\\chime.ogg" end
        return nil
      end,
    })
    Sounds = helper.load("Elmira/Display/Sounds.lua")
    ns.db = { char = { sounds = { enabled = true } } }
  end)

  after_each(function() _G.LibStub, _G.PlaySoundFile = nil, nil end)

  describe("the list", function()
    it("offers None first and every sound the player's packs provide", function()
      local list = Sounds.list()
      assert.equal("None", list.None)
      assert.equal("Elmira chime", list["Elmira chime"])
      assert.equal("Whistle", list.Whistle)
    end)

    -- A dropdown with no way back to silence is a cue you cannot switch off.
    it("still offers None with no media library at all", function()
      withMedia(nil)
      assert.same({ None = "None" }, Sounds.list())
    end)
  end)

  describe("playing", function()
    it("fetches the path and plays it", function()
      assert.is_true(Sounds.play("Elmira chime"))
      assert.same({ "Interface\\Media\\chime.ogg" }, played)
    end)

    -- "None" is the absence of a sound, not a sound to look up.
    it("stays quiet for None or nothing, without even asking the media library", function()
      local asked = 0
      withMedia({ List = function() return {} end,
                  Fetch = function() asked = asked + 1; return "x.ogg" end })
      assert.is_false(Sounds.play("None"))
      assert.is_false(Sounds.play(nil))
      assert.equal(0, asked)
      assert.equal(0, #played)
    end)

    it("stays quiet for a name the player's packs no longer provide", function()
      assert.is_false(Sounds.play("A sound nobody has"))
      assert.equal(0, #played)
    end)

    it("stays quiet with no media library, and on a client with no PlaySoundFile", function()
      withMedia(nil)
      assert.is_false(Sounds.play("Elmira chime"))
      withMedia({ List = function() return {} end, Fetch = function() return "x.ogg" end })
      _G.PlaySoundFile = nil
      assert.is_false(Sounds.play("Elmira chime"))
      assert.equal(0, #played)
    end)
  end)

  -- The master mute is per CHARACTER (db.char), like every other ability setting. It gates ability
  -- sounds only: an announcement's own sound belongs to Core/Announce's routing.
  describe("the ability-sound mute", function()
    it("reads db.char.sounds.enabled", function()
      assert.is_true(Sounds.abilitySoundsOn())
      ns.db.char.sounds.enabled = false
      assert.is_false(Sounds.abilitySoundsOn())
    end)

    it("answers false before there is any character data", function()
      ns.db = nil
      assert.is_false(Sounds.abilitySoundsOn())
      ns.db = { char = {} }
      assert.is_false(Sounds.abilitySoundsOn())
    end)

    -- The mute is a caller's gate, not this module's: Announcers plays through `play` too, and
    -- muting ability sounds must not silence an announcement.
    it("does not gate play() itself", function()
      ns.db.char.sounds.enabled = false
      assert.is_true(Sounds.play("Elmira chime"))
    end)
  end)

  it("sets ns.Sounds when the file loads", function()
    assert.equal(Sounds, ns.Sounds)
  end)
end)
