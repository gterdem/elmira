local helper = require("tests.helper")

-- Elmira/Core/Profiles.lua — which build is active (PURE, no WoW API). Contract lives in the file's
-- own header comment; asserted here against that contract, not against whatever the code happens to
-- do today.

describe("Core.Profiles", function()
  local Profiles

  before_each(function()
    helper.reset()
    Profiles = helper.load("Elmira/Core/Profiles.lua")
  end)

  local function pack(t)
    t.class = t.class or "PALADIN"
    return t
  end

  describe("rule 1: explicit pin", function()
    it("an activeBuild naming a build that exists wins over everything else, reason 'pinned'", function()
      local p = pack{
        builds = { A = {}, B = {} },
        catalog = { PALADIN = { { build = "B", available = true, recommended = true } } },
      }
      local key, reason = Profiles.resolve(p, { activeBuild = "A" })
      assert.equal("A", key)
      assert.equal("pinned", reason)
    end)
  end)

  describe("rule 2: dangling pin", function()
    it("a pin naming a build absent from pack.builds falls through, never nil, never errors", function()
      local p = pack{
        builds = { B = {} },
        catalog = { PALADIN = { { build = "B", available = true, recommended = true } } },
      }
      local ok, key, reason = pcall(Profiles.resolve, p, { activeBuild = "GHOST" })
      assert.is_true(ok)
      assert.equal("B", key)
      assert.is_string(reason)
      assert.truthy(reason:find("GHOST", 1, true))
    end)

    it("mentions the missing pinned key even with no catalog to fall back to", function()
      local p = pack{ builds = { Solo = {} } }
      local key, reason = Profiles.resolve(p, { activeBuild = "RENAMED" })
      assert.equal("Solo", key)
      assert.truthy(reason:find("RENAMED", 1, true))
    end)
  end)

  describe("the `false` unset sentinel", function()
    it("activeBuild = false is treated as no pin, not as a literal key", function()
      local p = pack{
        builds = { A = {}, B = {} },
        catalog = { PALADIN = { { build = "B", available = true, recommended = true } } },
      }
      local key, reason = Profiles.resolve(p, { activeBuild = false })
      assert.equal("B", key)
      assert.equal("catalog recommended", reason)
    end)
  end)

  describe("rule 3: catalog recommended", function()
    it("picks the available+recommended catalog entry for pack.class over a merely available one", function()
      local p = pack{
        builds = { Fast = {}, Slow = {} },
        catalog = {
          PALADIN = {
            { build = "Slow", available = true, recommended = false },
            { build = "Fast", available = true, recommended = true },
          },
        },
      }
      local key = Profiles.resolve(p, {})
      assert.equal("Fast", key)
    end)

    it("skips a recommended entry that is not available", function()
      local p = pack{
        builds = { Fast = {}, Slow = {} },
        catalog = {
          PALADIN = {
            { build = "Fast", available = false, recommended = true },
            { build = "Slow", available = true, recommended = false },
          },
        },
      }
      local key = Profiles.resolve(p, {})
      assert.equal("Slow", key)
    end)

    it("skips a recommended catalog entry whose build does not exist in pack.builds", function()
      local p = pack{
        builds = { Slow = {} },
        catalog = {
          PALADIN = {
            { build = "Missing", available = true, recommended = true },
            { build = "Slow", available = true, recommended = false },
          },
        },
      }
      local key = Profiles.resolve(p, {})
      assert.equal("Slow", key)
    end)
  end)

  describe("rule 4: first available catalog entry", function()
    it("with no recommended entry at all, takes the first available one that exists", function()
      local p = pack{
        builds = { First = {}, Second = {} },
        catalog = {
          PALADIN = {
            { build = "First", available = true, recommended = false },
            { build = "Second", available = true, recommended = false },
          },
        },
      }
      local key = Profiles.resolve(p, {})
      assert.equal("First", key)
    end)
  end)

  describe("rule 5: no catalog at all, determinism across pairs() order", function()
    it("resolving the same pack repeatedly always returns the same key", function()
      local p = pack{ builds = { Zed = {}, Alpha = {}, Mid = {} } }
      local first = Profiles.resolve(p, {})
      for _ = 1, 10 do
        assert.equal(first, (Profiles.resolve(p, {})))
      end
    end)

    -- The real risk isn't repeat-calls on one table (the same table iterates the same way twice in
    -- one process) -- it's two packs with the SAME keys built in a DIFFERENT insertion order, which
    -- is exactly what happens between two reloads if a class pack rebuilds its builds table. Only a
    -- sort (not raw pairs()) guarantees these agree.
    it("two packs with identical build keys inserted in different order resolve to the same key", function()
      local function buildsInOrder(order)
        local t = {}
        for _, k in ipairs(order) do t[k] = {} end
        return t
      end
      local pA = pack{ builds = buildsInOrder{ "Zed", "Alpha", "Mid", "Beta", "Gamma" } }
      local pB = pack{ builds = buildsInOrder{ "Gamma", "Beta", "Alpha", "Zed", "Mid" } }
      local keyA = Profiles.resolve(pA, {})
      local keyB = Profiles.resolve(pB, {})
      assert.equal(keyA, keyB)
    end)
  end)

  describe("rule 6: no builds at all", function()
    it("empty pack.builds resolves to nil plus a reason, never an error", function()
      local p = pack{ builds = {} }
      local ok, key, reason = pcall(Profiles.resolve, p, {})
      assert.is_true(ok)
      assert.is_nil(key)
      assert.is_string(reason)
    end)

    it("a non-table pack resolves to nil plus a reason, never an error", function()
      local ok, key, reason = pcall(Profiles.resolve, "not a pack", {})
      assert.is_true(ok)
      assert.is_nil(key)
      assert.is_string(reason)
    end)

    it("an absent pack.builds resolves to nil plus a reason, never an error", function()
      local ok, key, reason = pcall(Profiles.resolve, { class = "PALADIN" }, {})
      assert.is_true(ok)
      assert.is_nil(key)
      assert.is_string(reason)
    end)
  end)
end)
