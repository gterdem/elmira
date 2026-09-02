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

  -- M4 added two rules between the pin and the catalog fallback. Both are additive: a caller that
  -- passes no ctx must behave exactly as it did at M3, which is what keeps every rule-1..6 case above
  -- meaningful rather than quietly re-specified.
  describe("rule 2: the loadout override source", function()
    local function twoBuildPack()
      return {
        class = "PALADIN",
        builds = { PALADIN_EXODIN = {}, PALADIN_SHOCKADIN = {} },
        catalog = { PALADIN = {
          { build = "PALADIN_EXODIN", available = true, recommended = true },
          { build = "PALADIN_SHOCKADIN", available = true },
        } },
      }
    end

    it("uses the build the USER mapped that set name to", function()
      -- The mapping is per user, never shipped: "Shockadin" is one person's ItemRack set name.
      local profile = { overrides = { Shockadin = "PALADIN_SHOCKADIN" } }
      local key, reason = Profiles.resolve(twoBuildPack(), profile, { override = "Shockadin" })
      assert.equal("PALADIN_SHOCKADIN", key)
      assert.truthy(reason:find("Shockadin", 1, true))
    end)

    it("is outranked by an explicit pin", function()
      local profile = { activeBuild = "PALADIN_EXODIN", overrides = { Shockadin = "PALADIN_SHOCKADIN" } }
      local key, reason = Profiles.resolve(twoBuildPack(), profile, { override = "Shockadin" })
      assert.equal("PALADIN_EXODIN", key)
      assert.equal("pinned", reason)
    end)

    it("ignores a set name with no mapping, and one mapped to a build that is gone", function()
      assert.equal("PALADIN_EXODIN", Profiles.resolve(twoBuildPack(), {}, { override = "Unmapped" }))
      local stale = { overrides = { Shockadin = "PALADIN_REMOVED" } }
      assert.equal("PALADIN_EXODIN", Profiles.resolve(twoBuildPack(), stale, { override = "Shockadin" }))
    end)

    it("ignores ItemRack's internal sets, which are not loadouts", function()
      local profile = { overrides = { ["~BaseGear"] = "PALADIN_SHOCKADIN" } }
      -- Even if one were somehow mapped, an empty label must never resolve.
      assert.equal("PALADIN_EXODIN", Profiles.resolve(twoBuildPack(), profile, { override = "" }))
    end)
  end)

  describe("rule 3: what this character can actually play", function()
    local function gatedPack()
      return {
        class = "PALADIN",
        builds = { PALADIN_EXODIN = {}, PALADIN_SHOCKADIN = {} },
        catalog = { PALADIN = {
          { build = "PALADIN_EXODIN", available = true, recommended = true, requires = { weapon = "2H" } },
          { build = "PALADIN_SHOCKADIN", available = true, requires = { weapon = "1H" } },
        } },
      }
    end

    it("skips a recommended entry the character does not fit", function()
      local fits = function(entry) return entry.requires.weapon == "1H" end
      local key, reason = Profiles.resolve(gatedPack(), {}, { fits = fits })
      assert.equal("PALADIN_SHOCKADIN", key)
      assert.truthy(reason:find("fits", 1, true))
    end)

    it("prefers the recommended entry when the character fits it", function()
      local key, reason = Profiles.resolve(gatedPack(), {}, { fits = function() return true end })
      assert.equal("PALADIN_EXODIN", key)
      assert.truthy(reason:find("recommended", 1, true))
    end)

    -- The important one. `requires` is advisory (hard rule 8): an unreadable tooltip must not cost
    -- someone a build. `fits` answering nil means "could not tell", and nil is not a refusal.
    it("treats 'could not tell' as acceptable, never as a failure", function()
      local key = Profiles.resolve(gatedPack(), {}, { fits = function() return nil end })
      assert.equal("PALADIN_EXODIN", key)
    end)

    it("falls back to the catalog when the character fits nothing at all", function()
      local key, reason = Profiles.resolve(gatedPack(), {}, { fits = function() return false end })
      assert.equal("PALADIN_EXODIN", key)
      assert.equal("catalog recommended", reason)
    end)

    it("changes nothing when no ctx is passed — M3 callers are unaffected", function()
      local withCtx = Profiles.resolve(gatedPack(), {}, {})
      local without = Profiles.resolve(gatedPack(), {})
      assert.equal(without, withCtx)
      assert.equal("PALADIN_EXODIN", without)
    end)
  end)
end)
