local helper = require("tests.helper")
local mock = require("tests.wow_mock")

-- Elmira_ElvUI/Provider.lua — maps a spell to the ElvUI action buttons that hold it, registered
-- with Elmira.API.RegisterBarProvider (docs/08). Loaded with the real Elmira/Core/API.lua underneath
-- it (so the registration itself is real, not a stub of itself), and tests/wow_mock.lua for the
-- Blizzard globals it reads (GetActionInfo, GetMacroSpell, GetSpellInfo, RANGE_INDICATOR) plus the
-- CreateFrame it uses for its own bar-change watcher.
--
-- WHAT IS NOT COVERED HERE, on purpose: this file does NOT filter by button visibility itself (grep
-- confirms no `IsVisible` reference in it at all) — that is Elmira/Display/BarGlow.lua's job,
-- applied generically to whatever ANY provider returns (see barglow_spec.lua's "buttons that are not
-- on screen" section, which already proves it for a synthetic provider). A test asserting THIS file
-- drops hidden buttons would be asserting a design this file does not claim; instead the test below
-- proves the actual contract: buttonsForSpell hands back everything it maps, hidden or not, and
-- leaves the screen-visibility decision to the layer that already owns it.
describe("Elmira_ElvUI.Provider", function()
  local API

  local function button(id, opts)
    opts = opts or {}
    local b = { _state_type = "action", _state_action = id }
    if opts.hotkey then b.HotKey = { GetText = function() return opts.hotkey end } end
    return b
  end

  -- LibActionButton-1.0-ElvUI's real (v31) surface: `lib:GetAllButtons()` -> a SET (button -> true).
  local function installLAB(buttons)
    local lib = { GetAllButtons = function() return buttons or {} end }
    _G.LibStub = function(major, silent)
      if major == "LibActionButton-1.0-ElvUI" then return lib end
      if silent then return nil end
      error("no library " .. tostring(major))
    end
    return lib
  end

  local printed

  before_each(function()
    mock.reset()
    helper.reset()
    printed = {}
    _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
    API = helper.load("Elmira/Core/API.lua")
    _G.Elmira = { API = API }
  end)

  after_each(function()
    _G.LibStub = nil
    _G.print = print
  end)

  local function loadProvider()
    return helper.load("Elmira_ElvUI/Provider.lua")
  end

  describe("load guard", function()
    it("does not register a provider, and says why, when Elmira core has not loaded yet", function()
      _G.Elmira = nil
      loadProvider()
      assert.same({}, API.GetProviders("barProviders"))
      assert.truthy(#printed > 0)
      assert.truthy(printed[1]:find("before Elmira core", 1, true))
    end)

    it("does not register when Elmira.API.version is below what this file needs", function()
      _G.Elmira = { API = { version = 0 } }
      loadProvider()
      assert.same({}, API.GetProviders("barProviders"))
    end)
  end)

  describe("registration", function()
    it("registers itself as the 'ElvUI' bar provider", function()
      installLAB({})
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.equal(1, #providers)
      assert.equal("ElvUI", providers[1].name)
      assert.equal(10, providers[1].priority)
      assert.is_function(providers[1].buttonsForSpell)
      assert.is_function(providers[1].keybindForSpell)
      assert.is_function(providers[1].describe)
      assert.is_function(providers[1].onLayoutChanged)
    end)
  end)

  describe("buttonsForSpell", function()
    it("is empty, not an error, when the library is not present at all", function()
      _G.LibStub = function(_, silent) if silent then return nil end error("boom") end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      local ok, buttons = pcall(providers[1].buttonsForSpell, 415073)
      assert.is_true(ok)
      assert.same({}, buttons)
    end)

    it("is empty when the library has buttons but none holds the requested spell", function()
      mock.actionInfo = mock.actionInfo -- unused, GetActionInfo not read directly by Provider
      local b = button(1)
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 999999 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.same({}, providers[1].buttonsForSpell(415073))
    end)

    it("maps a kind==spell button directly to its id", function()
      local b = button(7)
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 7 then return "spell", 415073 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      local buttons = providers[1].buttonsForSpell(415073)
      assert.equal(1, #buttons)
      assert.equal(b, buttons[1])
    end)

    it("resolves a kind==macro button through GetMacroSpell", function()
      local b = button(3)
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 3 then return "macro", 12 end end
      _G.GetMacroSpell = function(i) if i == 12 then return 415073 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.equal(1, #providers[1].buttonsForSpell(415073))
    end)

    -- The regression this file's own comment documents: `button.GetAction and button:GetAction()`
    -- truncates a (type, action) call to its FIRST return, so a caller that used that form ended up
    -- reading kind ("action") back as if it were the slot/action id, and GetActionInfo("action")
    -- answers nothing. `actionOf` must capture BOTH returns from the GetAction() fallback.
    it("resolves a button through the GetAction() FALLBACK (no _state_type) using BOTH of its return values", function()
      local b = { GetAction = function(self) return "action", 9 end }
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 9 then return "spell", 415073 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.equal(1, #providers[1].buttonsForSpell(415073))
    end)

    it("a button whose GetAction() does not resolve to kind=='action' contributes nothing", function()
      local b = { GetAction = function(self) return "macro", 9 end }
      installLAB({ [b] = true })
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.same({}, providers[1].buttonsForSpell(415073))
    end)

    -- Classic ranks: a bar can hold a different rank (different spell id) of the ability the pack
    -- ships. GetSpellInfo turns an id into a rank-free name, which is what the fallback keys on.
    it("finds a button holding a DIFFERENT rank of the requested spell, by name", function()
      mock.spellNames[415073], mock.spellNames[415072] = "Exorcism", "Exorcism"
      mock.knownSpells[415073], mock.knownSpells[415072] = true, true
      local b = button(1)
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 415072 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.equal(1, #providers[1].buttonsForSpell(415073))
    end)

    it("prefers an exact id match over a name-only match when both ranks are on the bars", function()
      mock.spellNames[415073], mock.spellNames[415072] = "Exorcism", "Exorcism"
      mock.knownSpells[415073], mock.knownSpells[415072] = true, true
      local rank5, rank6 = button(1), button(2)
      installLAB({ [rank5] = true, [rank6] = true })
      _G.GetActionInfo = function(slot)
        if slot == 1 then return "spell", 415072 end
        if slot == 2 then return "spell", 415073 end
      end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      local buttons = providers[1].buttonsForSpell(415073)
      assert.equal(1, #buttons)
      assert.equal(rank6, buttons[1])
    end)

    it("does not filter hidden buttons itself -- returns a mapped button regardless of IsVisible", function()
      local hidden = button(1)
      hidden.IsVisible = function() return false end
      installLAB({ [hidden] = true })
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 415073 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      -- Visibility is BarGlow.lua's decision, applied to whatever this returns; this file always
      -- reports what it mapped.
      assert.equal(1, #providers[1].buttonsForSpell(415073))
    end)

    it("does not error, and reports nothing, when GetAllButtons itself errors", function()
      local lib = { GetAllButtons = function() error("ElvUI internals changed") end }
      _G.LibStub = function(major) if major == "LibActionButton-1.0-ElvUI" then return lib end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      local ok, buttons = pcall(providers[1].buttonsForSpell, 415073)
      assert.is_true(ok)
      assert.same({}, buttons)
    end)
  end)

  describe("keybindForSpell", function()
    it("returns the first mapped button's hotkey text", function()
      local b = button(1, { hotkey = "Q" })
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 415073 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.equal("Q", providers[1].keybindForSpell(415073))
    end)

    it("returns nil, not the range-indicator sentinel, for an unbound button", function()
      local b = button(1, { hotkey = _G.RANGE_INDICATOR })
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 415073 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.is_nil(providers[1].keybindForSpell(415073))
    end)

    it("returns nil when the spell has no mapped button at all", function()
      installLAB({})
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.is_nil(providers[1].keybindForSpell(415073))
    end)
  end)

  describe("describe()", function()
    it("reports the library absent", function()
      _G.LibStub = function(_, silent) if silent then return nil end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      local d = providers[1].describe()
      assert.is_false(d.present)
      assert.equal(0, d.buttons)
    end)

    it("reports button/mapped/named counts when the library is present", function()
      local b = button(1)
      installLAB({ [b] = true })
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 415073 end end
      mock.spellNames[415073] = "Exorcism"
      mock.knownSpells[415073] = true
      loadProvider()
      local providers = API.GetProviders("barProviders")
      providers[1].buttonsForSpell(415073) -- force rebuild()
      local d = providers[1].describe()
      assert.is_true(d.present)
      assert.equal(1, d.buttons)
      assert.equal(1, d.mapped)
      assert.equal(1, d.named)
    end)
  end)

  describe("bar-change watcher", function()
    it("clears the cached map when the watcher frame fires a bar-change event", function()
      local b1 = button(1)
      installLAB({ [b1] = true })
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 415073 end end
      loadProvider()
      local providers = API.GetProviders("barProviders")
      assert.equal(1, #providers[1].buttonsForSpell(415073))

      -- Rebind the same slot to a different spell WITHOUT firing an event: the cached map must
      -- still answer from its stale snapshot (proves there IS a cache to invalidate).
      _G.GetActionInfo = function(slot) if slot == 1 then return "spell", 999999 end end
      assert.equal(1, #providers[1].buttonsForSpell(415073))

      -- The watcher frame is the LAST one created at file scope (ACTIONBAR_SLOT_CHANGED etc.);
      -- tests/wow_mock.lua's CreateFrame now records real SetScript/RegisterEvent calls, so this
      -- is the actual installed handler, not a re-implementation of one.
      assert.is_true(_G.__lastFrame:GetScript("OnEvent") ~= nil)
      _G.__lastFrame:Fire("ACTIONBAR_SLOT_CHANGED")

      assert.same({}, providers[1].buttonsForSpell(415073))
    end)

    it("calls a registered onLayoutChanged listener when the bars change", function()
      installLAB({})
      loadProvider()
      local providers = API.GetProviders("barProviders")
      local called = 0
      providers[1].onLayoutChanged(function() called = called + 1 end)
      _G.__lastFrame:Fire("PLAYER_ENTERING_WORLD")
      assert.equal(1, called)
    end)

    it("a throwing onLayoutChanged listener does not stop invalidate() from completing", function()
      installLAB({})
      loadProvider()
      local providers = API.GetProviders("barProviders")
      providers[1].onLayoutChanged(function() error("boom") end)
      local ok = pcall(function() _G.__lastFrame:Fire("UPDATE_MACROS") end)
      assert.is_true(ok)
    end)
  end)
end)
