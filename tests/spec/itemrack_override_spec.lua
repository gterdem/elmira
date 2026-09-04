local helper = require("tests.helper")

-- Elmira/Adapters/ItemRack.lua — the loadout label that lets a gear swap switch the build.
--
-- Nothing covered `overrideSources` before this: the integration shipped as a stub whose `current()`
-- returned nil and whose `onChange()` did nothing, which is indistinguishable from a working one on
-- a character who never swaps gear.
--
-- The rule this file must not break: **the label, and nothing else**. ItemRack's hook fires roughly
-- half a second BEFORE the new gear is in the equipment slots, so anything read about gear from
-- inside the callback describes what the player is taking OFF. Set counts, bonuses and weapons come
-- from the debounced equipment path instead (docs/01 §3, docs/08).
--
-- Moved into core at ADR-0014. The two tests that used to live here for the separate-addon load
-- guard (`_G.Elmira` absent, "before Elmira core") are gone with the folder: a core file receives
-- `ns` from varargs and cannot load ahead of core. What replaces them is the invariant that only
-- exists BECAUSE it now ships inside core — its presence no longer says anything about whether the
-- user has ItemRack, so registration has to be gated on the client.
describe("Adapters.ItemRack", function()
  local ns, Rack, registered, logged, hooks

  local function load()
    helper.reset()
    ns = _G.__ELM_NS
    registered, logged, hooks = nil, {}, {}
    ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
    ns.API = { RegisterOverrideSource = function(spec) registered = spec; return true end }
    _G.hooksecurefunc = function(tbl, name, fn) hooks[#hooks + 1] = { tbl = tbl, name = name, fn = fn } end
    Rack = helper.load("Elmira/Adapters/ItemRack.lua")
    return Rack
  end

  before_each(function()
    _G.ItemRack, _G.ItemRackUser = nil, nil
  end)

  after_each(function()
    _G.hooksecurefunc, _G.ItemRack, _G.ItemRackUser = nil, nil, nil
  end)

  describe("Register()", function()
    it("registers a real current() and onChange() when ItemRack is installed", function()
      _G.ItemRackUser = { CurrentSet = "Shockadin" }
      assert.is_true(load().Register())
      assert.equal("ItemRack", registered.name)
      assert.equal("function", type(registered.current))
      assert.equal("function", type(registered.onChange))
    end)

    -- The whole reason registration is gated. An override source that can only ever answer nil is
    -- not harmless: everything downstream, the options panel included, reads a registered source as
    -- "ItemRack is set up and you are simply not wearing a loadout".
    it("registers nothing when ItemRack is not installed", function()
      assert.is_false(load().Register())
      assert.is_nil(registered)
    end)

    it("registers when ItemRack is loaded but has not populated its saved variables yet", function()
      _G.ItemRack = { UpdateCurrentSet = function() end }
      assert.is_true(load().Register())
      assert.equal("ItemRack", registered.name)
    end)

    it("registers nothing when the API is not available", function()
      _G.ItemRackUser = { CurrentSet = "Shockadin" }
      load()
      ns.API = nil
      assert.is_false(Rack.Register())
    end)

    it("publishes itself on the namespace", function()
      local rack = load()
      assert.equal(rack, ns.ItemRack)
    end)
  end)

  describe("current()", function()
    it("reports the worn set name", function()
      _G.ItemRackUser = { CurrentSet = "Shockadin" }
      assert.equal("Shockadin", load().current())
    end)

    it("ignores ItemRack's own bookkeeping sets", function()
      -- `~BaseGear`, `~CombatQueue`, `~Unequip` are not loadouts the player chose, and letting one
      -- select a build would switch the rotation every time ItemRack restores gear after combat.
      local spec = load()
      for _, internal in ipairs({ "~BaseGear", "~CombatQueue", "~Unequip" }) do
        _G.ItemRackUser = { CurrentSet = internal }
        assert.is_nil(spec.current(), internal .. " must not select a build")
      end
    end)

    it("answers nil when no set is worn, and when ItemRack has not loaded its saved variables", function()
      local spec = load()
      _G.ItemRackUser = { CurrentSet = "" }
      assert.is_nil(spec.current())
      _G.ItemRackUser = {}
      assert.is_nil(spec.current())
      _G.ItemRackUser = nil
      assert.is_nil(spec.current())
    end)
  end)

  describe("onChange()", function()
    it("hooks UpdateCurrentSet and hands the callback the new label", function()
      _G.ItemRack = { UpdateCurrentSet = function() end }
      _G.ItemRackUser = { CurrentSet = "Shockadin" }
      local spec = load()
      local seen
      assert.is_true(spec.onChange(function(label) seen = label end))
      assert.equal(1, #hooks)
      assert.equal("UpdateCurrentSet", hooks[1].name)

      _G.ItemRackUser.CurrentSet = "Sanctified"
      hooks[1].fn()                       -- ItemRack calls it with NO arguments
      assert.equal("Sanctified", seen)
    end)

    it("passes nil for an internal set, so a combat-queue restore does not switch builds", function()
      _G.ItemRack = { UpdateCurrentSet = function() end }
      _G.ItemRackUser = { CurrentSet = "Shockadin" }
      local spec = load()
      local seen, called = "unset", false
      spec.onChange(function(label) seen, called = label, true end)
      _G.ItemRackUser.CurrentSet = "~CombatQueue"
      hooks[1].fn()
      assert.is_true(called)
      assert.is_nil(seen)
    end)

    it("says so out loud when there is nothing to hook, instead of registering a dead callback", function()
      _G.ItemRack = {}                    -- present, but without the function we hook
      local spec = load()
      assert.is_false(spec.onChange(function() end))
      assert.equal(0, #hooks)
      assert.equal(1, #logged)
      assert.truthy(logged[1]:find("UpdateCurrentSet", 1, true))
    end)

    it("refuses a non-function callback rather than hooking for nobody", function()
      _G.ItemRack = { UpdateCurrentSet = function() end }
      assert.is_false(load().onChange(nil))
      assert.equal(0, #hooks)
    end)
  end)
end)
