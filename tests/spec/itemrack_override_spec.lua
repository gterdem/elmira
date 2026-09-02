local helper = require("tests.helper")

-- Elmira_ItemRack/Override.lua — the loadout label that lets a gear swap switch the build.
--
-- Nothing covered `overrideSources` before this: the module shipped as a stub whose `current()`
-- returned nil and whose `onChange()` did nothing, which is indistinguishable from a working module
-- on a character who never swaps gear.
--
-- The rule this file must not break: **the label, and nothing else**. ItemRack's hook fires roughly
-- half a second BEFORE the new gear is in the equipment slots, so anything read about gear from
-- inside the callback describes what the player is taking OFF. Set counts, bonuses and weapons come
-- from the debounced equipment path instead (docs/01 §3, docs/08).
describe("Elmira_ItemRack.Override", function()
  local registered, printed, hooks

  local function load()
    registered, printed, hooks = nil, {}, {}
    _G.print = function(msg) printed[#printed + 1] = msg end
    _G.hooksecurefunc = function(tbl, name, fn) hooks[#hooks + 1] = { tbl = tbl, name = name, fn = fn } end
    _G.Elmira = { API = { version = 1, RegisterOverrideSource = function(spec) registered = spec end } }
    local chunk = assert(loadfile("Elmira_ItemRack/Override.lua"))
    chunk("Elmira_ItemRack")
    return registered
  end

  before_each(function()
    helper.reset()
    _G.ItemRack, _G.ItemRackUser = nil, nil
  end)

  after_each(function()
    _G.print, _G.hooksecurefunc, _G.Elmira, _G.ItemRack, _G.ItemRackUser = nil, nil, nil, nil, nil
  end)

  it("registers itself with a real current() and onChange()", function()
    local spec = load()
    assert.equal("ItemRack", spec.name)
    assert.equal("function", type(spec.current))
    assert.equal("function", type(spec.onChange))
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
      assert.equal(1, #printed)
      assert.truthy(printed[1]:find("UpdateCurrentSet", 1, true))
    end)

    it("refuses a non-function callback rather than hooking for nobody", function()
      _G.ItemRack = { UpdateCurrentSet = function() end }
      assert.is_false(load().onChange(nil))
      assert.equal(0, #hooks)
    end)
  end)

  it("complains and registers nothing when it loads before core", function()
    printed, hooks = {}, {}
    _G.print = function(msg) printed[#printed + 1] = msg end
    _G.Elmira = nil
    local sentinel = nil
    local chunk = assert(loadfile("Elmira_ItemRack/Override.lua"))
    chunk("Elmira_ItemRack")
    assert.is_nil(sentinel)
    assert.equal(1, #printed)
    assert.truthy(printed[1]:find("before Elmira core", 1, true))
  end)
end)
