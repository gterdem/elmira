local helper = require("tests.helper")

-- Elmira/Adapters/LibOwner.lua — whose copy of each shared library LibStub actually served, by
-- diffing a snapshot taken before embeds.xml against one sealed at the end of our TOC, against the
-- live table. `LibOwner.before` is captured at FILE SCOPE the instant the file loads, so most of
-- these specs load the module themselves (rather than relying on a shared before_each) with
-- `_G.LibStub` set up first -- exactly like `embeds.xml` running after this file in the real TOC.
describe("Adapters.LibOwner", function()
  local function load(stub)
    helper.reset()
    _G.LibStub = stub
    return helper.load("Elmira/Adapters/LibOwner.lua")
  end

  after_each(function()
    _G.LibStub = nil
  end)

  describe("snapshot()", function()
    it("returns a COPY of LibStub.minors, not a reference", function()
      local Mod = load(nil)
      local stub = { minors = { Foo = 1 } }
      local snap = Mod.snapshot(stub)
      assert.equal(1, snap.Foo) -- it actually copied the value...
      snap.Foo = 99
      -- ...and mutating the result must not reach back into LibStub
      assert.equal(1, stub.minors.Foo)
    end)

    it("returns {} when there is no LibStub global at all", function()
      local Mod = load(nil)
      _G.LibStub = nil
      assert.same({}, Mod.snapshot())
    end)

    it("returns {} when LibStub.minors is not a table", function()
      local Mod = load(nil)
      assert.same({}, Mod.snapshot({ minors = "not a table" }))
    end)

    it("returns {} when the stub has no minors field at all", function()
      local Mod = load(nil)
      assert.same({}, Mod.snapshot({}))
    end)
  end)

  describe("LibOwner.before (captured at file scope)", function()
    it("is {} when Elmira is first to embed LibStub -- the normal `before` case", function()
      local Mod = load(nil)
      assert.same({}, Mod.before)
    end)

    it("captures whatever another addon already installed ahead of our TOC", function()
      local Mod = load({ minors = { AceEvent = 4 } })
      assert.same({ AceEvent = 4 }, Mod.before)
    end)
  end)

  describe("audit(before, after, live)", function()
    it("reports a major present in `after` at a different minor than `before`, but not one unchanged", function()
      local Mod = load(nil)
      local before = { Foo = 1, Bar = 2 }
      local after = { Foo = 3, Bar = 2 } -- Foo moved, Bar did not
      local rows = Mod.audit(before, after, { Foo = 3, Bar = 2 })
      assert.equal(1, #rows)
      assert.equal("Foo", rows[1].name)
    end)

    it("reports a major absent from `before` entirely (a library we introduced)", function()
      local Mod = load(nil)
      local rows = Mod.audit({}, { NewLib = 5 }, { NewLib = 5 })
      assert.equal(1, #rows)
      assert.equal("NewLib", rows[1].name)
    end)

    -- `/elm debug libs` prints the minor beside every name: an audit that reported which libraries
    -- moved but not to WHAT version leaves the reader unable to compare against the copy any other
    -- addon ships, which is the next question they will ask.
    it("carries the minor we installed and the one the client is serving now", function()
      local Mod = load(nil)
      local ours = Mod.audit({}, { Foo = 2 }, { Foo = 2 })[1]
      assert.equal(2, ours.minor)
      assert.equal(2, ours.current)
      local lost = Mod.audit({}, { Foo = 2 }, { Foo = 5 })[1]
      assert.equal(2, lost.minor, "minor is what WE installed, not what won")
      assert.equal(5, lost.current, "current is what the client is serving now")
    end)

    it("marks ours = true when `live` still holds our minor", function()
      local Mod = load(nil)
      local rows = Mod.audit({}, { Foo = 2 }, { Foo = 2 })
      assert.is_true(rows[1].ours)
      assert.is_nil(rows[1].replacedBy)
    end)

    -- The whole diagnostic rests on this distinction: "this is our bill" vs "this WAS our bill
    -- until ElvUI loaded". A version that only checked `after ~= before` could never tell them apart.
    it("marks ours = false and sets replacedBy when a later addon upgraded it", function()
      local Mod = load(nil)
      local rows = Mod.audit({}, { Foo = 2 }, { Foo = 5 })
      assert.is_false(rows[1].ours)
      assert.equal(5, rows[1].replacedBy)
    end)

    it("returns rows sorted by name, for a deterministic chat report", function()
      local Mod = load(nil)
      local rows = Mod.audit({}, { Zeta = 1, Alpha = 1, Mu = 1 }, {})
      local names = {}
      for i, row in ipairs(rows) do names[i] = row.name end
      assert.same({ "Alpha", "Mu", "Zeta" }, names)
    end)

    it("treats nil before/after/live as empty tables without erroring", function()
      local Mod = load(nil)
      assert.same({}, Mod.audit(nil, nil, nil))
    end)
  end)

  describe("sealAfterEmbeds()", function()
    it("seals a snapshot of the given stub as `after`, and returns true the first time", function()
      local Mod = load(nil)
      assert.is_true(Mod.sealAfterEmbeds({ minors = { Foo = 1 } }))
      assert.same({ Foo = 1 }, Mod.after)
    end)

    -- Pinned hard, per the module's own comment: sealing twice would record other addons' libraries
    -- as ours, the exact inverse of what this module measures.
    it("latches: a second call does NOT overwrite the first snapshot, and returns false", function()
      local Mod = load(nil)
      assert.is_true(Mod.sealAfterEmbeds({ minors = { Foo = 1, Bar = 2 } }))
      local ok = Mod.sealAfterEmbeds({ minors = { Foo = 99, Evil = 1 } })
      assert.is_false(ok)
      assert.same({ Foo = 1, Bar = 2 }, Mod.after)
    end)
  end)

  describe("report()", function()
    it('returns nil plus a reason when sealAfterEmbeds was never called -- "we never looked" must not read as "we own nothing"', function()
      local Mod = load(nil)
      local rows, reason = Mod.report()
      assert.is_nil(rows)
      assert.is_string(reason)
      assert.truthy(reason:find("seal", 1, true))
    end)

    it("audits before/after/live end to end once sealed", function()
      -- before: another addon already had Foo at minor 1
      local Mod = load({ minors = { Foo = 1 } })
      -- our embeds.xml installs Foo at 2 and introduces Bar at 1
      Mod.sealAfterEmbeds({ minors = { Foo = 2, Bar = 1 } })
      -- live client: someone loading after us upgraded Bar, but Foo is still ours
      _G.LibStub = { minors = { Foo = 2, Bar = 5 } }
      local rows = Mod.report()
      local byName = {}
      for _, row in ipairs(rows) do byName[row.name] = row end
      assert.is_true(byName.Foo.ours)
      assert.is_false(byName.Bar.ours)
      assert.equal(5, byName.Bar.replacedBy)
    end)
  end)

  describe("ownedCount()", function()
    it("counts only rows where ours is true", function()
      local Mod = load({ minors = {} })
      Mod.sealAfterEmbeds({ minors = { A = 1, B = 1, C = 1 } })
      _G.LibStub = { minors = { A = 1, B = 99, C = 1 } } -- B got replaced after us
      assert.equal(2, Mod.ownedCount())
    end)

    it("returns nil when report() could not answer (never sealed)", function()
      local Mod = load(nil)
      assert.is_nil(Mod.ownedCount())
    end)
  end)

  it("publishes itself on the namespace", function()
    local Mod = load(nil)
    assert.equal(Mod, helper.ns().LibOwner)
  end)
end)
