local helper = require("tests.helper")

-- Elmira/Core/RotationMode.lua — the manual Single/Cleave/AoE override on top of the nameplate
-- count (M5a-i-D2). Pure Lua: no WoW API, no AceAddon, dofile-able like every other Core module.
describe("Core.RotationMode", function()
  local RotationMode, ns

  before_each(function()
    ns = helper.reset()
    RotationMode = helper.load("Elmira/Core/RotationMode.lua")
  end)

  describe("get()", function()
    it("answers Auto before the database exists", function()
      assert.equal("Auto", RotationMode.get())
    end)

    it("answers Auto when db.char has no stored mode", function()
      ns.db = { char = {} }
      assert.equal("Auto", RotationMode.get())
    end)

    it("reads back whatever was stored", function()
      ns.db = { char = { rotationMode = "AoE" } }
      assert.equal("AoE", RotationMode.get())
    end)

    it("falls back to Auto for a value it does not recognise", function()
      -- A stranger value (an old release's spelling, a corrupted SavedVariables entry) must not
      -- wedge the reading -- Auto is always a safe answer.
      ns.db = { char = { rotationMode = "Aoe" } }
      assert.equal("Auto", RotationMode.get())
    end)
  end)

  describe("set()", function()
    it("refuses before the database exists", function()
      assert.is_false(RotationMode.set("AoE"))
    end)

    it("refuses a value that is not one of MODES, and changes nothing", function()
      ns.db = { char = { rotationMode = "Single" } }
      assert.is_false(RotationMode.set("Nonsense"))
      assert.equal("Single", ns.db.char.rotationMode)
    end)

    it("writes the mode into db.char and reports success", function()
      ns.db = { char = {} }
      assert.is_true(RotationMode.set("Cleave"))
      assert.equal("Cleave", ns.db.char.rotationMode)
    end)

    it("marks the display stale so the very next render sees the change", function()
      ns.db = { char = {} }
      local invalidated = 0
      ns.Display = { invalidate = function() invalidated = invalidated + 1 end }
      RotationMode.set("AoE")
      assert.equal(1, invalidated)
    end)

    it("does not touch Display when there is none loaded", function()
      ns.db = { char = {} }
      ns.Display = nil
      assert.is_true(RotationMode.set("AoE"))
    end)
  end)

  describe("next()", function()
    it("cycles Auto -> Single -> Cleave -> AoE -> Auto", function()
      assert.equal("Single", RotationMode.next("Auto"))
      assert.equal("Cleave", RotationMode.next("Single"))
      assert.equal("AoE", RotationMode.next("Cleave"))
      assert.equal("Auto", RotationMode.next("AoE"))
    end)

    it("wraps an unrecognised current value back to the front of the list", function()
      assert.equal("Auto", RotationMode.next(nil))
      assert.equal("Auto", RotationMode.next("Nonsense"))
    end)
  end)

  describe("isMode()", function()
    it("accepts exactly the four MODES entries", function()
      for _, m in ipairs(RotationMode.MODES) do
        assert.is_true(RotationMode.isMode(m))
      end
      assert.is_false(RotationMode.isMode("aoe"))  -- case-sensitive: MODES is the canonical casing
      assert.is_false(RotationMode.isMode(nil))
    end)
  end)
end)
