local helper = require("tests.helper")
local mock = require("tests.wow_mock")

-- Elmira/Display/BarProviders.lua — one bar provider per LibActionButton-1.0 library on the client.
--
-- Replaces tests/spec/elvui_provider_spec.lua, which died with the Elmira_ElvUI folder at ADR-0014.
-- Two of that file's tests are deliberately NOT carried over: they asserted the separate addon's
-- load guard (`_G.Elmira` absent, `API.version < 1`, the printed "before Elmira core"), behaviour a
-- core file cannot exhibit because it receives `ns` from varargs.
--
-- What this file adds instead is the reason the merge was worth doing: ElvUI and Bartender4 are the
-- SAME code path. Both build buttons with LibActionButton-1.0 — ElvUI under its own major, Bartender4
-- under the stock one — so the discriminator is the library prefix, and the friendly name comes from
-- the buttons themselves. The old provider hardcoded one library name and one addon name, and that
-- was the only thing standing between us and Bartender4 support.
describe("Display.BarProviders", function()
  local ns, API, BarProviders, libs

  -- A LibActionButton-alike: `GetAllButtons()` answers a SET (button -> true), which is the shape
  -- the real library returns and the reason the map build uses `pairs` and not `ipairs`.
  local function library(buttons)
    return { GetAllButtons = function() return buttons end }
  end

  local function button(name, opts)
    opts = opts or {}
    local b = {
      GetName = function() return name end,
      _state_type = opts.stateType or (opts.slot and "action" or nil),
      _state_action = opts.slot,
    }
    if opts.spellId then b.GetSpellId = function() return opts.spellId end end
    if opts.hotkey then b.HotKey = { GetText = function() return opts.hotkey end } end
    return b
  end

  local function set(...)
    local out = {}
    for _, b in ipairs({ ... }) do out[b] = true end
    return out
  end

  local function load()
    helper.reset()
    ns = _G.__ELM_NS
    mock.reset()
    -- The REAL vendored LibStub, not a fake. A hand-written stand-in is what let the blocker
    -- through: `IterateLibraries` returns `pairs(self.libs)` -- an iterator triple -- and a fake that
    -- returned a table proved only that the code agreed with the test's guess about the library.
    -- Registering through the real one means the shape cannot be assumed wrongly twice.
    _G.LibStub = nil
    assert(loadfile("Elmira/Libs/LibStub/LibStub.lua"), "run `make libs`")()
    libs = setmetatable({}, { __newindex = function(t, major, lib)
      rawset(t, major, lib)
      LibStub:NewLibrary(major, 1)
      -- A major may be registered as something that is not a table at all; LibStub does not care,
      -- and neither may we.
      if type(lib) == "table" then
        for k, v in pairs(lib) do LibStub.libs[major][k] = v end
      else
        LibStub.libs[major] = lib
      end
    end })
    API = helper.load("Elmira/Core/API.lua")
    ns.API = API
    helper.load("Elmira/Display/BarGlow.lua")
    BarProviders = helper.load("Elmira/Display/BarProviders.lua")
    return BarProviders
  end

  before_each(load)
  after_each(function() _G.LibStub = nil end)

  it("publishes itself on the namespace", function()
    assert.equal(BarProviders, ns.BarProviders)
  end)

  describe("discovery", function()
    it("finds every LibActionButton-1.0 library, forks included", function()
      libs["LibActionButton-1.0"] = library({})
      libs["LibActionButton-1.0-ElvUI"] = library({})
      libs["LibSharedMedia-3.0"] = library({})     -- must not be picked up
      local found = {}
      for _, entry in ipairs(BarProviders.libraries()) do found[#found + 1] = entry.major end
      assert.same({ "LibActionButton-1.0", "LibActionButton-1.0-ElvUI" }, found)
    end)

    it("finds nothing, without erroring, when no bar addon is loaded", function()
      assert.same({}, BarProviders.libraries())
      assert.same({}, BarProviders.Register())
    end)

    it("finds nothing when the client has no LibStub at all", function()
      _G.LibStub = nil
      assert.same({}, BarProviders.libraries())
    end)

    it("finds nothing when LibStub will not enumerate, rather than erroring into the display loop", function()
      _G.LibStub = { IterateLibraries = function() return "not a table" end }
      assert.same({}, BarProviders.libraries())
      _G.LibStub = { IterateLibraries = function() error("LibStub broke") end }
      assert.same({}, BarProviders.libraries())
    end)

    -- The registry sorts by priority, but the INPUT order has to be deterministic too, or two dumps
    -- from the same client are not diffable against each other.
    -- Five majors, not three: with three, `pairs` happened to yield them already sorted, so the
    -- assertion passed with the sort deleted. A vacuous test is worse than no test, because it
    -- reports the line as covered.
    it("returns libraries in a stable order regardless of table iteration", function()
      for _, major in ipairs({
        "LibActionButton-1.0-Bartender", "LibActionButton-1.0-NDui", "LibActionButton-1.0",
        "LibActionButton-1.0-KkthnxUI", "LibActionButton-1.0-ElvUI",
      }) do
        libs[major] = library({})
      end
      local found = {}
      for _, entry in ipairs(BarProviders.libraries()) do found[#found + 1] = entry.major end
      assert.same({
        "LibActionButton-1.0", "LibActionButton-1.0-Bartender", "LibActionButton-1.0-ElvUI",
        "LibActionButton-1.0-KkthnxUI", "LibActionButton-1.0-NDui",
      }, found)
    end)

    it("registers nothing when the API is not available", function()
      libs["LibActionButton-1.0-ElvUI"] = library({})
      ns.API = nil
      assert.same({}, BarProviders.Register())
    end)

    it("tolerates a library that does not answer GetAllButtons", function()
      libs["LibActionButton-1.0-ElvUI"] = {}
      local spec = BarProviders.Register()[1]
      assert.equal("Action bars", spec.name)
      assert.same({}, spec.buttonsForSpell(415073))
    end)

    -- LibStub hands back whatever was registered under a major. A non-table there is not our bug to
    -- fix, but it must not take the display loop down with it.
    it("tolerates a major registered as something that is not a library", function()
      libs["LibActionButton-1.0-ElvUI"] = false
      local spec = BarProviders.Register()[1]
      assert.same({}, spec.buttonsForSpell(415073))
      assert.equal(0, spec.describe().buttons)
    end)
  end)

  -- The friendly name is read off the BUTTONS, not off the library major and not from a list of
  -- installed addons. That is what lets the options panel print "Bartender4" without the code ever
  -- asking whether Bartender4 is installed — and what keeps an unknown fork honestly generic
  -- instead of confidently mislabelled.
  describe("naming", function()
    local function nameFor(major, buttonName)
      libs[major] = library(set(button(buttonName, { slot = 1 })))
      local specs = BarProviders.Register()
      return specs[1] and specs[1].name
    end

    it("names ElvUI from its button frames", function()
      assert.equal("ElvUI", nameFor("LibActionButton-1.0-ElvUI", "ElvUI_Bar1Button3"))
    end)

    it("names Bartender4 from its button frames", function()
      assert.equal("Bartender4", nameFor("LibActionButton-1.0", "BT4Button12"))
    end)

    it("falls back to a generic name for a fork it does not recognise", function()
      assert.equal("Action bars", nameFor("LibActionButton-1.0-NDui", "NDuiActionBar1Button1"))
    end)

    it("names Dominos from its button frames", function()
      assert.equal("Dominos", nameFor("LibActionButton-1.0", "DominosActionButton13"))
    end)

    it("registers both when ElvUI and Bartender4 are installed side by side", function()
      libs["LibActionButton-1.0-ElvUI"] = library(set(button("ElvUI_Bar1Button1", { slot = 1 })))
      libs["LibActionButton-1.0"] = library(set(button("BT4Button1", { slot = 2 })))
      local specs = BarProviders.Register()
      assert.equal(2, #specs)
      -- ElvUI outranks Bartender4, so exactly one of them is the provider that answers first.
      local registry = API.GetProviders("barProviders")
      assert.equal("ElvUI", registry[1].name)
      assert.equal("Bartender4", registry[2].name)
    end)
  end)

  describe("buttonsForSpell", function()
    local function providerWith(buttons)
      libs["LibActionButton-1.0-ElvUI"] = library(buttons)
      return BarProviders.Register()[1]
    end

    it("finds the button holding a spell placed in an action slot", function()
      mock.actionInfo[7] = { "spell", 415073 }
      local b = button("ElvUI_Bar1Button1", { slot = 7 })
      assert.same({ b }, providerWith(set(b)).buttonsForSpell(415073))
    end)

    -- The defect the hand-rolled `_state_type == "action"` walk carried: LibActionButton also has
    -- `Spell`-type buttons, which have NO action slot at all. Every one of them was invisible, so a
    -- spell placed on one could never glow and nothing anywhere reported it.
    it("finds a LibActionButton Spell-type button, which has no action slot", function()
      local b = button("ElvUI_Bar1Button2", { stateType = "spell", spellId = 415073 })
      assert.same({ b }, providerWith(set(b)).buttonsForSpell(415073))
    end)

    -- A LibActionButton old enough to lack GetSpellId, and whose state fields are not populated:
    -- `GetAction()` returns (type, action) and the `and`-truncated read of it shipped a bug three
    -- times in this codebase.
    it("falls back to GetAction() on a library too old for GetSpellId", function()
      mock.actionInfo[12] = { "spell", 415073 }
      local b = button("ElvUI_Bar3Button1")
      b.GetAction = function() return "action", 12 end
      assert.same({ b }, providerWith(set(b)).buttonsForSpell(415073))
    end)

    -- The slot deliberately HOLDS the spell: if the "action" check were dropped, a macro-kind
    -- button would fall through with 4 as if it were a slot number and match anyway, which is the
    -- shape that shipped three times. An empty slot would make both branches look identical.
    it("ignores a button whose action is not of kind \"action\"", function()
      mock.actionInfo[4] = { "spell", 415073 }
      local b = button("ElvUI_Bar3Button2")
      b.GetAction = function() return "macro", 4 end
      assert.same({}, providerWith(set(b)).buttonsForSpell(415073))
    end)

    it("ignores a non-button sitting in the library's set", function()
      local buttons = { [5] = true }
      libs["LibActionButton-1.0-ElvUI"] = library(buttons)
      assert.same({}, BarProviders.Register()[1].buttonsForSpell(415073))
    end)

    it("resolves a #showtooltip macro to the spell it casts", function()
      mock.actionInfo[9] = { "macro", 3 }
      mock.macroSpells[3] = 415073
      local b = button("ElvUI_Bar2Button1", { slot = 9 })
      assert.same({ b }, providerWith(set(b)).buttonsForSpell(415073))
    end)

    -- Classic has spell RANKS: the bar holds whichever rank the player dragged there, the data pack
    -- ships exactly one id. Matching on id alone silently misses the button for the spell the player
    -- presses most.
    it("matches a different rank of the same spell by name", function()
      mock.knownSpells[24274], mock.knownSpells[24239] = true, true
      mock.spellNames[24274] = "Hammer of Wrath"
      mock.spellNames[24239] = "Hammer of Wrath"
      mock.actionInfo[4] = { "spell", 24274 }
      local b = button("ElvUI_Bar1Button4", { slot = 4 })
      assert.same({ b }, providerWith(set(b)).buttonsForSpell(24239))
    end)

    it("answers an empty list for a spell on no bar", function()
      assert.same({}, providerWith(set(button("ElvUI_Bar1Button1", { slot = 1 }))).buttonsForSpell(999999))
    end)

    it("answers an empty list when asked about no spell at all", function()
      assert.same({}, providerWith(set(button("ElvUI_Bar1Button1", { slot = 1 }))).buttonsForSpell(nil))
    end)
  end)

  describe("keybindForSpell", function()
    local function providerWith(b)
      libs["LibActionButton-1.0-ElvUI"] = library(set(b))
      return BarProviders.Register()[1]
    end

    it("reports the button's hotkey", function()
      mock.actionInfo[1] = { "spell", 415073 }
      assert.equal("3", providerWith(button("ElvUI_Bar1Button1", { slot = 1, hotkey = "3" })).keybindForSpell(415073))
    end)

    -- Blizzard and ElvUI both park an unbound button's hotkey text at this sentinel rather than
    -- clearing it, so a naive read shows the range dot as if it were a keybind.
    -- Reloaded between the two: one name, one provider (see the duplicate guard below), so a second
    -- Register() in the same registry is refused rather than shadowing the first.
    it("rejects the range-indicator sentinel", function()
      mock.actionInfo[1] = { "spell", 415073 }
      local p = providerWith(button("ElvUI_Bar1Button1", { slot = 1, hotkey = _G.RANGE_INDICATOR }))
      assert.is_nil(p.keybindForSpell(415073))
    end)

    it("rejects an empty hotkey string", function()
      mock.actionInfo[1] = { "spell", 415073 }
      local p = providerWith(button("ElvUI_Bar1Button1", { slot = 1, hotkey = "" }))
      assert.is_nil(p.keybindForSpell(415073))
    end)

    it("answers nil for a button with no hotkey region, and for a spell on no bar", function()
      mock.actionInfo[1] = { "spell", 415073 }
      local p = providerWith(button("ElvUI_Bar1Button1", { slot = 1 }))  -- no HotKey
      assert.is_nil(p.keybindForSpell(415073))
      assert.is_nil(p.keybindForSpell(999999))
    end)
  end)

  -- Separates the three ways a provider comes up empty: no library, a library holding no buttons
  -- (asked before the bars were built), and buttons that simply do not hold the spell.
  describe("describe()", function()
    it("counts the library's buttons and what they mapped to", function()
      mock.actionInfo[1] = { "spell", 415073 }
      mock.knownSpells[415073] = true
      mock.spellNames[415073] = "Exorcism"
      libs["LibActionButton-1.0-ElvUI"] = library(set(
        button("ElvUI_Bar1Button1", { slot = 1 }),
        button("ElvUI_Bar1Button2", { slot = 99 })   -- empty slot
      ))
      local info = BarProviders.Register()[1].describe()
      assert.equal("LibActionButton-1.0-ElvUI", info.library)
      assert.is_true(info.present)
      assert.equal(2, info.buttons)
      assert.equal(1, info.mapped)
      assert.equal(1, info.named)
    end)

    it("reports a library present but empty, rather than looking like a missing library", function()
      libs["LibActionButton-1.0-ElvUI"] = library({})
      local info = BarProviders.Register()[1].describe()
      assert.is_true(info.present)
      assert.equal(0, info.buttons)
      assert.equal(0, info.mapped)
    end)

    it("survives a library that errors instead of answering", function()
      libs["LibActionButton-1.0-ElvUI"] = { GetAllButtons = function() error("bar addon broke") end }
      local spec = BarProviders.Register()[1]
      assert.same({}, spec.buttonsForSpell(415073))
      assert.equal(0, spec.describe().buttons)
    end)
  end)

  -- Priorities decide which single provider answers, and therefore which one the options panel will
  -- show as "in use". Left untested, the generic fallback could be given a number that outranks
  -- ElvUI and nothing would notice.
  describe("priority", function()
    it("ranks a recognised bar addon above the generic fallback", function()
      libs["LibActionButton-1.0-ElvUI"] = library(set(button("ElvUI_Bar1Button1", { slot = 1 })))
      libs["LibActionButton-1.0-Unknown"] = library(set(button("SomethingElseButton1", { slot = 2 })))
      BarProviders.Register()
      local registry = API.GetProviders("barProviders")
      assert.equal("ElvUI", registry[1].name)
      assert.equal("Action bars", registry[2].name)
    end)

    it("ranks ElvUI, then Bartender4, then Dominos", function()
      local names = {}
      for _, case in ipairs({
        { major = "LibActionButton-1.0-ElvUI", frame = "ElvUI_Bar1Button1" },
        { major = "LibActionButton-1.0", frame = "BT4Button1" },
        { major = "LibActionButton-1.0-D", frame = "DominosActionButton13" },
      }) do
        libs[case.major] = library(set(button(case.frame, { slot = 1 })))
      end
      BarProviders.Register()
      for _, spec in ipairs(API.GetProviders("barProviders")) do names[#names + 1] = spec.name end
      assert.same({ "ElvUI", "Bartender4", "Dominos" }, names)
    end)
  end)

  describe("Invalidate()", function()
    it("rebuilds the map, so a spell dragged to another button is found there", function()
      mock.actionInfo[1] = { "spell", 415073 }
      local first = button("ElvUI_Bar1Button1", { slot = 1 })
      local second = button("ElvUI_Bar1Button2", { slot = 2 })
      libs["LibActionButton-1.0-ElvUI"] = library(set(first, second))
      local spec = BarProviders.Register()[1]
      assert.same({ first }, spec.buttonsForSpell(415073))

      mock.actionInfo[1] = nil
      mock.actionInfo[2] = { "spell", 415073 }
      BarProviders.Invalidate()
      assert.same({ second }, spec.buttonsForSpell(415073))
    end)
  end)

  -- A third-party provider registered through the public API used to own its own watcher frame.
  -- Moving the bar events into core would have left it with no invalidation from anywhere, its map
  -- frozen at whatever the bars looked like the first time it was asked.
  describe("the public provider contract", function()
    it("invalidates a third-party provider, not just the ones it built itself", function()
      local dropped = 0
      API.RegisterBarProvider{ name = "SomeOtherBars", invalidate = function() dropped = dropped + 1 end }
      BarProviders.Invalidate()
      assert.equal(1, dropped)
    end)

    it("tolerates a provider that keeps no cache, or whose invalidate throws", function()
      API.RegisterBarProvider{ name = "Cacheless" }
      API.RegisterBarProvider{ name = "Broken", invalidate = function() error("their bug") end }
      assert.is_true(pcall(BarProviders.Invalidate))
    end)

    -- docs/08 documents onLayoutChanged as the provider's way of telling core its bars moved.
    it("subscribes to every provider that offers onLayoutChanged", function()
      local fired
      API.RegisterBarProvider{ name = "Pushy", onLayoutChanged = function(cb) fired = cb end }
      API.RegisterBarProvider{ name = "Quiet" }
      assert.equal(1, BarProviders.Subscribe(function() end))
      assert.equal("function", type(fired))
    end)

    -- The provider here ACCEPTS whatever it is handed, so without the type check a nil subscriber
    -- would be wired up and counted -- and would then error the first time the bars moved.
    it("refuses a subscriber that is not a function", function()
      API.RegisterBarProvider{ name = "Accepting", onLayoutChanged = function() end }
      assert.equal(0, BarProviders.Subscribe(nil))
      assert.equal(0, BarProviders.Subscribe("not a function"))
      assert.equal(1, BarProviders.Subscribe(function() end))
    end)

    it("survives a provider whose onLayoutChanged throws", function()
      API.RegisterBarProvider{ name = "Throws", onLayoutChanged = function() error("their bug") end }
      assert.equal(0, BarProviders.Subscribe(function() end))
    end)
  end)

  -- What the options panel lists. Every supported bar addon gets a row whether or not it is
  -- installed: listing only what registered gives no signal at all when the thing you installed did
  -- not show up, which is the failure mode of the dynamic-list pattern this deliberately rejects.
  describe("status()", function()
    local function stateOf(rows, name)
      for _, r in ipairs(rows) do if r.name == name then return r end end
    end

    it("lists every supported bar addon, plus Blizzard, with nothing installed", function()
      local rows = BarProviders.status()
      assert.equal("absent", stateOf(rows, "ElvUI").state)
      assert.equal("absent", stateOf(rows, "Bartender4").state)
      assert.equal("absent", stateOf(rows, "Dominos").state)
      -- With no bar addon the Blizzard bars are not a fallback, they ARE what is in use.
      assert.equal("active", stateOf(rows, "Blizzard").state)
    end)

    it("marks the highest-priority bar addon active and the rest inactive", function()
      libs["LibActionButton-1.0-ElvUI"] = library(set(button("ElvUI_Bar1Button1", { slot = 1 })))
      libs["LibActionButton-1.0"] = library(set(button("BT4Button1", { slot = 2 })))
      BarProviders.Register()
      local rows = BarProviders.status()
      assert.equal("active", stateOf(rows, "ElvUI").state)
      assert.equal("inactive", stateOf(rows, "Bartender4").state)
      -- The inactive row has to be able to name the winner, or "why is only one glowing" has no
      -- answer anywhere in the UI.
      assert.equal("ElvUI", stateOf(rows, "Bartender4").activeName)
      assert.equal("fallback", stateOf(rows, "Blizzard").state)
    end)

    -- Otherwise the panel says "not installed" three times to somebody whose bars are working.
    it("gives an unrecognised bar addon a row of its own", function()
      libs["LibActionButton-1.0-Unknown"] = library(set(button("WhateverButton1", { slot = 1 })))
      BarProviders.Register()
      local rows = BarProviders.status()
      assert.equal("active", stateOf(rows, "Action bars").state)
      assert.equal("Action bars", stateOf(rows, "Action bars").activeName)
      assert.equal("fallback", stateOf(rows, "Blizzard").state)
    end)

    it("names the winner on an unrecognised addon's row too, when a known one outranks it", function()
      libs["LibActionButton-1.0-ElvUI"] = library(set(button("ElvUI_Bar1Button1", { slot = 1 })))
      libs["LibActionButton-1.0-Unknown"] = library(set(button("WhateverButton1", { slot = 2 })))
      BarProviders.Register()
      local row = stateOf(BarProviders.status(), "Action bars")
      assert.equal("inactive", row.state)
      assert.equal("ElvUI", row.activeName)
    end)

    it("does not invent a generic row when no unrecognised addon registered", function()
      libs["LibActionButton-1.0-ElvUI"] = library(set(button("ElvUI_Bar1Button1", { slot = 1 })))
      BarProviders.Register()
      assert.is_nil(stateOf(BarProviders.status(), "Action bars"))
    end)

    it("still lists the bar addons when the API is unavailable", function()
      ns.API = nil
      local rows = BarProviders.status()
      assert.equal("absent", stateOf(rows, "ElvUI").state)
      assert.equal("active", stateOf(rows, "Blizzard").state)
    end)
  end)

  -- The migration hazard, in the one place it can be caught. A retired companion addon left in the
  -- AddOns folder registers a second provider with the same name; the registry sort is stable only
  -- on (priority, name), so which one answers depends on load order. That is how a stale
  -- Elmira_Paladin silently served pre-migration rotations for a whole session.
  describe("duplicate registration", function()
    it("refuses a second provider claiming the same name, and says why", function()
      local logged = {}
      ns.log = function(fmt, ...) logged[#logged + 1] = string.format(fmt, ...) end
      assert.is_true(API.RegisterBarProvider{ name = "ElvUI" })
      local ok, reason = API.RegisterBarProvider{ name = "ElvUI" }
      assert.is_false(ok)
      assert.equal(1, #API.GetProviders("barProviders"))
      assert.truthy(tostring(reason):find("already registered", 1, true))
      assert.truthy(logged[1]:find("already registered", 1, true))
    end)
  end)
end)
