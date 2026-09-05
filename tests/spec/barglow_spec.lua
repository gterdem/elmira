local helper = require("tests.helper")
local mock = require("tests.wow_mock")

-- Elmira/Display/BarGlow.lua — spell key -> on-screen buttons/keybind. Registered providers first,
-- Blizzard default-bar scan as the fallback (docs/08 `API.RegisterBarProvider`).
--
-- Uses tests/wow_mock.lua for the Blizzard-scan globals (GetActionInfo, GetMacroSpell,
-- RANGE_INDICATOR) and the real Elmira/Core/API.lua for provider registration/priority ordering,
-- rather than reimplementing either. `ns.Display.currentPack()` is stubbed directly: BarGlow only
-- ever reads `pack.spells[key].id`, so nothing is gained by routing through the real Driver/compile
-- chain to get there.

describe("Display.BarGlow", function()
  local BarGlow, API, ns
  local blizzNames

  local function setButton(name, tbl)
    _G[name] = tbl
    blizzNames[#blizzNames + 1] = name
  end

  local function setPack(spells)
    ns.Display = { currentPack = function() return { spells = spells } end }
  end

  before_each(function()
    mock.reset()
    ns = helper.reset()
    API = helper.load("Elmira/Core/API.lua")
    BarGlow = helper.load("Elmira/Display/BarGlow.lua")
    blizzNames = {}
    setPack{ EXORCISM = { id = 415073 } }
  end)

  after_each(function()
    for _, name in ipairs(blizzNames) do _G[name] = nil end
  end)

  describe("symbolic key resolution", function()
    it("a key not in the active pack returns an empty button list, never an error", function()
      local ok, buttons = pcall(BarGlow.buttonsFor, "NOT_A_REAL_SPELL")
      assert.is_true(ok)
      assert.same({}, buttons)
    end)

    it("a key not in the active pack returns nil for keybindFor, never an error", function()
      local ok, bind = pcall(BarGlow.keybindFor, "NOT_A_REAL_SPELL")
      assert.is_true(ok)
      assert.is_nil(bind)
    end)

    it("a non-string key is handled the same way, never an error", function()
      local ok, buttons = pcall(BarGlow.buttonsFor, nil)
      assert.is_true(ok)
      assert.same({}, buttons)
    end)
  end)

  describe("Blizzard scan (no providers registered)", function()
    it("maps a kind==\"spell\" slot directly to its button", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1 })
      local button = _G.ActionButton1
      local buttons = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal(button, buttons[1])
    end)

    it("resolves a kind==\"macro\" slot through GetMacroSpell", function()
      mock.actionInfo[1] = { "macro", 7 }
      mock.macroSpells[7] = 415073
      setButton("ActionButton1", { action = 1 })
      local buttons = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal(_G.ActionButton1, buttons[1])
    end)

    it("a macro that resolves to nothing is simply unmapped, not an error", function()
      mock.actionInfo[1] = { "macro", 9 }
      -- mock.macroSpells[9] deliberately unset
      setButton("ActionButton1", { action = 1 })
      local ok, buttons = pcall(BarGlow.buttonsFor, "EXORCISM")
      assert.is_true(ok)
      assert.same({}, buttons)
    end)

    it("a slot holding an unrelated spell does not contribute a button", function()
      mock.actionInfo[1] = { "spell", 999999 }
      setButton("ActionButton1", { action = 1 })
      assert.same({}, BarGlow.buttonsFor("EXORCISM"))
    end)
  end)

  describe("providers precede the Blizzard scan", function()
    it("a provider returning a non-empty list wins over a Blizzard-mapped button", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1 })
      local providerButton = { fromProvider = true }
      API.RegisterBarProvider{ name = "ElvUI", buttonsForSpell = function(id)
        if id == 415073 then return { providerButton } end
        return {}
      end }
      local buttons = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal(providerButton, buttons[1])
      assert.are_not.equal(_G.ActionButton1, buttons[1])
    end)

    it("a provider returning an empty list falls through to the next provider", function()
      local winner = { fromB = true }
      API.RegisterBarProvider{ name = "Alpha", priority = 10, buttonsForSpell = function() return {} end }
      API.RegisterBarProvider{ name = "Bravo", priority = 5, buttonsForSpell = function(id)
        if id == 415073 then return { winner } end
        return {}
      end }
      local buttons = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal(winner, buttons[1])
    end)

    it("a provider returning an empty list falls through to the Blizzard scan", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1 })
      API.RegisterBarProvider{ name = "Empty", buttonsForSpell = function() return {} end }
      local buttons = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal(_G.ActionButton1, buttons[1])
    end)

    it("a provider whose buttonsForSpell errors does not propagate and falls through", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1 })
      API.RegisterBarProvider{ name = "Broken", buttonsForSpell = function()
        error("this provider reads another addon's internals and just broke")
      end }
      local ok, buttons = pcall(BarGlow.buttonsFor, "EXORCISM")
      assert.is_true(ok)
      assert.equal(1, #buttons)
      assert.equal(_G.ActionButton1, buttons[1])
    end)

    it("a provider whose keybindForSpell errors does not propagate and falls through", function()
      setButton("ActionButton1", { action = 1, HotKey = { GetText = function() return "R" end } })
      mock.actionInfo[1] = { "spell", 415073 }
      API.RegisterBarProvider{ name = "Broken", keybindForSpell = function()
        error("boom")
      end }
      local ok, bind = pcall(BarGlow.keybindFor, "EXORCISM")
      assert.is_true(ok)
      assert.equal("R", bind)
    end)

    it("a provider's keybindForSpell wins over the Blizzard scan", function()
      setButton("ActionButton1", { action = 1, HotKey = { GetText = function() return "R" end } })
      mock.actionInfo[1] = { "spell", 415073 }
      API.RegisterBarProvider{ name = "ElvUI", keybindForSpell = function(id)
        if id == 415073 then return "SHIFT-Q" end
      end }
      assert.equal("SHIFT-Q", BarGlow.keybindFor("EXORCISM"))
    end)
  end)

  describe("keybindFor and the range-indicator sentinel", function()
    it("returns the button's hotkey text when bound", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1, HotKey = { GetText = function() return "Q" end } })
      assert.equal("Q", BarGlow.keybindFor("EXORCISM"))
    end)

    it("returns nil, not the sentinel text, when the button is unbound", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1, HotKey = { GetText = function() return _G.RANGE_INDICATOR end } })
      assert.is_nil(BarGlow.keybindFor("EXORCISM"))
    end)

    it("returns nil when the button has no HotKey at all", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1 })
      assert.is_nil(BarGlow.keybindFor("EXORCISM"))
    end)
  end)

  describe("Invalidate()", function()
    it("a map built before a change is not reused after Invalidate()", function()
      mock.actionInfo[1] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1 })

      local before = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #before)

      -- Rebind the slot to a different spell WITHOUT invalidating: the cached map must still answer
      -- from its stale snapshot.
      mock.actionInfo[1] = { "spell", 999999 }
      local stillCached = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #stillCached)

      BarGlow.Invalidate()
      local after = BarGlow.buttonsFor("EXORCISM")
      assert.same({}, after)
    end)
  end)

  -- ElvUI does not delete Blizzard's bars, it hides them. The buttons still exist, still report the
  -- spell they hold, and still accept a glow that lands on an invisible frame -- which is exactly
  -- what "the bar glow does not work at all" looks like from the player's chair.
  describe("buttons that are not on screen", function()
    local function button(name, visible, action)
      local b = { action = action, IsVisible = function() return visible end,
                  GetName = function() return name end }
      setButton(name, b)
      return b
    end

    it("skips a hidden Blizzard button instead of glowing it invisibly", function()
      mock.actionInfo[1] = { "spell", 415073 }
      button("ActionButton1", false, 1)
      local buttons, source = BarGlow.buttonsFor("EXORCISM")
      assert.equal(0, #buttons)
      assert.is_nil(source)
    end)

    it("keeps a visible one and names where it came from", function()
      mock.actionInfo[1] = { "spell", 415073 }
      button("ActionButton1", true, 1)
      local buttons, source = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal("blizzard", source)
    end)

    it("a provider that returns only hidden buttons falls through to the fallback", function()
      local hidden = { IsVisible = function() return false end }
      API.RegisterBarProvider{ name = "Ghost", priority = 10,
        buttonsForSpell = function() return { hidden } end }
      mock.actionInfo[1] = { "spell", 415073 }
      button("ActionButton1", true, 1)
      local buttons, source = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal("blizzard", source)
    end)

    it("a button with no IsVisible is kept, not silently dropped", function()
      -- Some bar addons hand back plain tables. Filtering those out would break them for a
      -- guess about a method they never had.
      API.RegisterBarProvider{ name = "Plain", priority = 5,
        buttonsForSpell = function() return { { plain = true } } end }
      local buttons, source = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal("Plain", source)
    end)
  end)

  describe("describe()", function()
    it("reports the chain: providers, the fallback size, and one row per spell", function()
      API.RegisterBarProvider{ name = "ElvUI", priority = 10,
        buttonsForSpell = function() return {} end,
        describe = function() return { library = "LibActionButton-1.0-ElvUI", present = true,
                                       buttons = 62, mapped = 14 } end }
      local d = BarGlow.describe({ "EXORCISM" })
      assert.equal(1, #d.providers)
      assert.equal("ElvUI", d.providers[1].name)
      assert.is_true(d.providers[1].buttonsForSpell)
      assert.equal(62, d.providers[1].info.buttons)
      assert.equal(1, #d.rows)
      assert.equal("EXORCISM", d.rows[1].key)
      assert.equal(415073, d.rows[1].id)
      assert.equal(0, d.rows[1].count)
      assert.is_nil(d.rows[1].source)
    end)

    it("a provider whose describe() errors does not take the diagnostic down", function()
      API.RegisterBarProvider{ name = "Rude", priority = 10,
        buttonsForSpell = function() return {} end,
        describe = function() error("no") end }
      local d = BarGlow.describe({ "EXORCISM" })
      assert.equal(1, #d.providers)
      assert.is_nil(d.providers[1].info)
    end)
  end)

  -- Classic has spell RANKS. Each rank is its own spell id; the bar holds whichever rank the player
  -- dragged there; the data pack ships exactly one id per ability. This is the difference between
  -- "the glow works" and "the glow works for Judgement but never for Exorcism", with no error and
  -- nothing in any log.
  describe("spell ranks", function()
    it("finds the button when the bar holds a DIFFERENT rank of the same spell", function()
      -- Pack says Rank 6 (415073); the bar holds Rank 5 (415072). Same name, different id.
      mock.spellNames[415073], mock.spellNames[415072] = "Exorcism", "Exorcism"
      mock.knownSpells[415073] = true
      mock.knownSpells[415072] = true
      mock.actionInfo[1] = { "spell", 415072 }
      setButton("ActionButton1", { action = 1, IsVisible = function() return true end,
                                   GetName = function() return "ActionButton1" end })
      local buttons, source = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal("blizzard", source)
    end)

    it("still prefers an exact id match when both ranks are on the bars", function()
      mock.spellNames[415073], mock.spellNames[415072] = "Exorcism", "Exorcism"
      mock.knownSpells[415073] = true
      mock.knownSpells[415072] = true
      mock.actionInfo[1] = { "spell", 415072 }
      mock.actionInfo[2] = { "spell", 415073 }
      setButton("ActionButton1", { action = 1, IsVisible = function() return true end,
                                   GetName = function() return "ActionButton1" end })
      setButton("ActionButton2", { action = 2, IsVisible = function() return true end,
                                   GetName = function() return "ActionButton2" end })
      local buttons = BarGlow.buttonsFor("EXORCISM")
      assert.equal(1, #buttons)
      assert.equal("ActionButton2", buttons[1]:GetName())
    end)

    it("a keybind is found through the name match too", function()
      mock.spellNames[415072], mock.spellNames[415073] = "Exorcism", "Exorcism"
      mock.knownSpells[415072] = true
      mock.knownSpells[415073] = true
      mock.actionInfo[1] = { "spell", 415072 }
      setButton("ActionButton1", { action = 1, IsVisible = function() return true end,
                                   HotKey = { GetText = function() return "3" end } })
      assert.equal("3", BarGlow.keybindFor("EXORCISM"))
    end)
  end)

  -- The owner's own words: "glowing actionbar buttons is much better than the glowing queue
  -- buttons... you see the icon in the queue but still look after in your actionbars." So a bar glow
  -- that cannot find its button is the MOST important failure in the display, and until now it was
  -- the quietest — it degraded to the queue icon and said nothing, which is how a rank mismatch
  -- survived a whole build.
  -- F37: this is the display's most valuable failure to notice, so it goes through Announce and the
  -- player decides how loudly they hear it -- rather than being printed to whatever chat frame.
  describe("noteMissing() announces rather than prints", function()
    before_each(function()
      ns.db = { profile = { glow = { enabled = true, barGlow = true } } }
      BarGlow.resetAnnouncements()
    end)

    it("sends a warning naming the spell it could not place", function()
      local said = {}
      ns.Announce = { emit = function(cat, text) said[#said + 1] = { cat, text } end }
      assert.is_true(BarGlow.noteMissing("EXORCISM"))
      assert.equal(1, #said)
      assert.equal("warning", said[1][1])
      assert.is_truthy(said[1][2]:find("EXORCISM"))
      assert.is_truthy(said[1][2]:find("/elm debug bars"))
    end)

    it("still says it the old way on a load where Announce is missing", function()
      local printed = {}
      ns.Announce = nil
      ns.log = function(fmt, ...) printed[#printed + 1] = string.format(fmt, ...) end
      assert.is_true(BarGlow.noteMissing("EXORCISM"))
      assert.equal(1, #printed)
      assert.is_truthy(printed[1]:find("EXORCISM"))
    end)
  end)

  describe("noteMissing()", function()
    before_each(function()
      helper.ns().db = { profile = { glow = { enabled = true, barGlow = true } } }
      helper.ns().log = function(...) helper.ns()._logged = { ... } end
      BarGlow.resetAnnouncements()
    end)

    it("says which spell has no button", function()
      assert.is_true(BarGlow.noteMissing("EXORCISM"))
      assert.truthy(table.concat(helper.ns()._logged, " "):find("EXORCISM", 1, true))
    end)

    it("says it once per spell, not once per render", function()
      assert.is_true(BarGlow.noteMissing("EXORCISM"))
      assert.is_false(BarGlow.noteMissing("EXORCISM"))
      assert.is_false(BarGlow.noteMissing("EXORCISM"))
    end)

    it("stays quiet when the user has turned bar glow off", function()
      helper.ns().db.profile.glow.barGlow = false
      assert.is_false(BarGlow.noteMissing("EXORCISM"))
      helper.ns().db.profile.glow.barGlow = true
      helper.ns().db.profile.glow.enabled = false
      BarGlow.resetAnnouncements()
      assert.is_false(BarGlow.noteMissing("JUDGEMENT"))
    end)

    it("will speak again after the bars change, because the spell may have been placed", function()
      assert.is_true(BarGlow.noteMissing("EXORCISM"))
      BarGlow.Invalidate()
      assert.is_true(BarGlow.noteMissing("EXORCISM"))
    end)
  end)
end)

-- The Blizzard fallback scan, corrected 2026-09-04. Two defects lived here: the bar list was missing
-- MultiBar5/6/7 (which DO exist on Classic Era 1.15), and the slot lookup's fallback named
-- `ActionButton_GetPagedID`, a function that does not exist on this client at all -- a safety net
-- made of nothing, guarded so it never errored and never helped.
describe("BarGlow Blizzard scan", function()
  local helper2 = require("tests.helper")
  local mock2 = require("tests.wow_mock")
  local BarGlow2

  local function load2()
    helper2.reset()
    mock2.reset()
    local ns2 = _G.__ELM_NS
    BarGlow2 = helper2.load("Elmira/Display/BarGlow.lua")
    ns2.Display = { currentPack = function() return { spells = { EXORCISM = { id = 415073 } } } end }
    return BarGlow2
  end

  local function frame(fields)
    local f = { IsVisible = function() return true end }
    for k, v in pairs(fields or {}) do f[k] = v end
    return f
  end

  before_each(function()
    load2()
    for _, name in ipairs({ "MultiBar5Button1", "MultiBar6Button1", "MultiBar7Button1",
                            "ActionButton1" }) do
      _G[name] = nil
    end
    _G.ActionButtonUtil = nil
  end)

  after_each(function()
    for _, name in ipairs({ "MultiBar5Button1", "MultiBar6Button1", "MultiBar7Button1",
                            "ActionButton1" }) do
      _G[name] = nil
    end
    _G.ActionButtonUtil = nil
  end)

  it("scans MultiBar5, 6 and 7, which exist on Classic Era", function()
    for i, name in ipairs({ "MultiBar5Button1", "MultiBar6Button1", "MultiBar7Button1" }) do
      mock2.actionInfo[40 + i] = { "spell", 415073 }
      _G[name] = frame({ action = 40 + i })
    end
    BarGlow2.Invalidate()
    local buttons = BarGlow2.buttonsFor("EXORCISM")
    assert.equal(3, #buttons)
  end)

  -- `/elm debug perf` must not change what it measures. `/elm debug bars` and the provider
  -- `describe()` both rebuild on demand -- right for "what WOULD you find" -- but if the
  -- performance report did the same, the two commands could never agree about one session, which
  -- is exactly how an owner ended up holding two contradictory answers.
  describe("stats()", function()
    it("reports the fallback as unbuilt without building it", function()
      local s1 = BarGlow2.stats()
      assert.is_false(s1.built)
      assert.equal(0, s1.mapped)
      -- Still unbuilt after asking: the question did not answer itself.
      assert.is_false(BarGlow2.stats().built)
    end)

    it("reports what the fallback holds once something has built it", function()
      _G.ActionButton1 = frame{ action = 1 }
      mock2.actionInfo = { [1] = { "spell", 415073 } }
      BarGlow2.Rebuild()
      local s = BarGlow2.stats()
      assert.is_true(s.built)
      assert.equal(1, s.mapped)
    end)

    it("counts the registered bar addon providers", function()
      local ns2 = _G.__ELM_NS
      ns2.API = { GetProviders = function() return { { name = "ElvUI" }, { name = "Bartender4" } } end }
      assert.equal(2, BarGlow2.stats().providers)
    end)
  end)

  describe("slot resolution", function()
    it("reads the paged slot off the secure `action` attribute first", function()
      mock2.actionInfo[61] = { "spell", 415073 }
      _G.ActionButton1 = frame({
        action = 1,                                      -- the unpaged field, deliberately wrong
        GetAttribute = function(_, name) return name == "action" and 61 or nil end,
      })
      BarGlow2.Invalidate()
      assert.equal(1, #BarGlow2.buttonsFor("EXORCISM"))
    end)

    it("falls back to the plain field when there is no attribute", function()
      mock2.actionInfo[5] = { "spell", 415073 }
      _G.ActionButton1 = frame({ action = 5 })
      BarGlow2.Invalidate()
      assert.equal(1, #BarGlow2.buttonsFor("EXORCISM"))
    end)

    it("falls back to CalculateAction, which is what the secure template itself uses", function()
      mock2.actionInfo[8] = { "spell", 415073 }
      _G.ActionButton1 = frame({ CalculateAction = function() return 8 end })
      BarGlow2.Invalidate()
      assert.equal(1, #BarGlow2.buttonsFor("EXORCISM"))
    end)

    it("contributes nothing for a global that is not a frame at all", function()
      mock2.actionInfo[5] = { "spell", 415073 }
      _G.ActionButton1 = 5
      BarGlow2.Invalidate()
      assert.same({}, BarGlow2.buttonsFor("EXORCISM"))
    end)

    it("contributes nothing for a button that answers none of the three", function()
      mock2.actionInfo[5] = { "spell", 415073 }
      _G.ActionButton1 = frame({})
      BarGlow2.Invalidate()
      assert.same({}, BarGlow2.buttonsFor("EXORCISM"))
    end)

    it("survives a button whose attribute reads throw", function()
      mock2.actionInfo[5] = { "spell", 415073 }
      _G.ActionButton1 = frame({
        GetAttribute = function() error("secure frame") end,
        CalculateAction = function() error("secure frame") end,
      })
      BarGlow2.Invalidate()
      assert.same({}, BarGlow2.buttonsFor("EXORCISM"))
    end)
  end)
end)

-- BarGlow.check() — the five-stage chain the Action Bars panel renders.
--
-- The whole value of this function is SEPARATING the causes of "nothing is glowing". Four different
-- problems need four different actions from the player: no bar addon, the spell is not placed, the
-- button is on a bar they cannot see right now, and the bar glow is switched off. Collapsing them
-- into one "not found" is what sends someone to reinstall an addon that was never the problem. So
-- every test below asserts WHICH stage failed, never merely that something did.
-- Symbolic keys are how the engine names spells; they are not what the player calls them, and the
-- options panel needs the real name.
describe("BarGlow.spellName", function()
  local helper4 = require("tests.helper")
  local mock4 = require("tests.wow_mock")

  it("resolves an id to the client's name for it", function()
    helper4.reset(); mock4.reset()
    local BG = helper4.load("Elmira/Display/BarGlow.lua")
    mock4.knownSpells[415073] = true
    mock4.spellNames[415073] = "Exorcism"
    assert.equal("Exorcism", BG.spellName(415073))
    assert.is_nil(BG.spellName(nil))
    assert.is_nil(BG.spellName(999999))
  end)
end)

describe("BarGlow.check", function()
  local helper3 = require("tests.helper")
  local mock3 = require("tests.wow_mock")
  local BarGlow3, ns3

  local function load3(opts)
    opts = opts or {}
    helper3.reset()
    mock3.reset()
    ns3 = _G.__ELM_NS
    helper3.load("Elmira/Core/API.lua")
    BarGlow3 = helper3.load("Elmira/Display/BarGlow.lua")
    ns3.Display = { currentPack = function() return { spells = { EXORCISM = { id = 415073 } } } end }
    ns3.db = { profile = { glow = { enabled = opts.enabled ~= false, barGlow = opts.barGlow ~= false } } }
    return BarGlow3
  end

  local function frame3(visible, name, slot)
    return { IsVisible = function() return visible end, GetName = function() return name end,
             action = slot }
  end

  local function stage(rows, label)
    for _, r in ipairs(rows) do if r.label == label then return r end end
  end

  before_each(function() load3() end)
  after_each(function() _G.ActionButton1 = nil end)

  it("reports an unknown spell as a spell problem, not a bar problem", function()
    local rows = BarGlow3.check("NOT_IN_THE_BUILD")
    assert.equal(1, #rows)
    assert.is_false(stage(rows, "spell").ok)
    assert.is_nil(stage(rows, "bars"))
  end)

  it("names the bar addon in use, and says blizzard when there is none", function()
    assert.equal("blizzard", stage(BarGlow3.check("EXORCISM"), "bars").detail)
    ns3.API.RegisterBarProvider{ name = "ElvUI", priority = 10, buttonsForSpell = function() return {} end }
    assert.equal("ElvUI", stage(BarGlow3.check("EXORCISM"), "bars").detail)
  end)

  it("passes every stage for a spell on a visible button with the glow on", function()
    ns3.API.RegisterBarProvider{ name = "ElvUI",
      buttonsForSpell = function() return { frame3(true, "ElvUI_Bar1Button3") } end }
    local rows = BarGlow3.check("EXORCISM")
    assert.is_true(stage(rows, "placed").ok)
    assert.is_true(stage(rows, "visible").ok)
    assert.equal("ElvUI_Bar1Button3", stage(rows, "visible").detail)
    assert.is_true(stage(rows, "glow").ok)
  end)

  it("fails at 'placed', and does not pretend to have answered the later questions", function()
    local rows = BarGlow3.check("EXORCISM")
    assert.equal(4, #rows)                     -- and it STOPS: no stage is answered twice
    assert.is_false(stage(rows, "placed").ok)
    assert.is_nil(stage(rows, "visible").ok)   -- not reached, distinct from failed
    assert.is_nil(stage(rows, "glow").ok)
  end)

  -- The distinction the whole function exists for. Both of these end in no glow; one is a
  -- five-second fix and the other is a stance, and a player told "not found" cannot tell which.
  it("separates 'not on any bar' from 'on a bar you cannot see'", function()
    ns3.API.RegisterBarProvider{ name = "ElvUI",
      buttonsForSpell = function() return { frame3(false, "ElvUI_Bar5Button1") } end }
    local rows = BarGlow3.check("EXORCISM")
    assert.equal(4, #rows)
    assert.is_true(stage(rows, "placed").ok)    -- it IS placed
    assert.is_false(stage(rows, "visible").ok)  -- just not on screen
    assert.is_nil(stage(rows, "glow").ok)
  end)

  -- Everything above can pass while the bar glow is off. A chain of ticks ending in no glow is the
  -- exact report this is meant to pre-empt.
  it("reports the bar glow being switched off as its own stage", function()
    load3{ barGlow = false }
    ns3.API.RegisterBarProvider{ name = "ElvUI",
      buttonsForSpell = function() return { frame3(true, "ElvUI_Bar1Button1") } end }
    local rows = BarGlow3.check("EXORCISM")
    assert.is_true(stage(rows, "visible").ok)
    assert.is_false(stage(rows, "glow").ok)

    load3{ enabled = false }
    ns3.API.RegisterBarProvider{ name = "ElvUI",
      buttonsForSpell = function() return { frame3(true, "ElvUI_Bar1Button1") } end }
    assert.is_false(stage(BarGlow3.check("EXORCISM"), "glow").ok)
  end)

  it("falls back to the Blizzard bars when no provider holds the spell", function()
    mock3.actionInfo[3] = { "spell", 415073 }
    _G.ActionButton1 = frame3(true, "ActionButton1", 3)
    ns3.API.RegisterBarProvider{ name = "ElvUI", buttonsForSpell = function() return {} end }
    BarGlow3.Invalidate()
    local rows = BarGlow3.check("EXORCISM")
    assert.is_true(stage(rows, "placed").ok)
    assert.equal("ActionButton1", stage(rows, "visible").detail)
  end)

  it("quotes the button name back, and copes when the button will not give one", function()
    ns3.API.RegisterBarProvider{ name = "Nameless",
      buttonsForSpell = function() return { { IsVisible = function() return true end } } end }
    assert.is_nil(stage(BarGlow3.check("EXORCISM"), "visible").detail)
  end)

  -- The defect a pre-commit audit found by probing, which no mutation could see because the bug was
  -- in code that was ABSENT: check() walked providers itself and stopped at the first one returning
  -- ANY button, while buttonsFor() skips a provider whose buttons are all hidden and falls through.
  -- With two bar addons installed the panel said "you cannot see that button" while the glow was
  -- working perfectly on the second one.
  describe("agreeing with what actually glows", function()
    it("does not blame the stance when a second bar addon has the visible button", function()
      ns3.API.RegisterBarProvider{ name = "ElvUI", priority = 10,
        buttonsForSpell = function() return { frame3(false, "ElvUI_Bar5Button1") } end }
      ns3.API.RegisterBarProvider{ name = "Bartender4", priority = 9,
        buttonsForSpell = function() return { frame3(true, "BT4Button7") } end }
      local rows = BarGlow3.check("EXORCISM")
      assert.equal(1, #BarGlow3.buttonsFor("EXORCISM"))   -- the glow works
      assert.is_true(stage(rows, "visible").ok)           -- so the panel must not say otherwise
      assert.equal("BT4Button7", stage(rows, "visible").detail)
      assert.equal("Bartender4", stage(rows, "bars").detail)
    end)

    it("counts buttons across every source, not just the first that answered", function()
      ns3.API.RegisterBarProvider{ name = "ElvUI", priority = 10,
        buttonsForSpell = function() return { frame3(false, "ElvUI_Bar5Button1") } end }
      ns3.API.RegisterBarProvider{ name = "Bartender4", priority = 9,
        buttonsForSpell = function() return { frame3(true, "BT4Button7") } end }
      assert.equal(2, stage(BarGlow3.check("EXORCISM"), "placed").detail)
    end)
  end)

  -- A green chain has to mean a glow. These three states passed every bar question while nothing
  -- could possibly light up, which is the exact lie this panel exists to prevent.
  describe("not reporting all-clear when nothing can glow", function()
    local function placedAndVisible()
      ns3.API.RegisterBarProvider{ name = "ElvUI",
        buttonsForSpell = function() return { frame3(true, "ElvUI_Bar1Button1") } end }
    end

    it("names Elmira itself being switched off, not the bar toggle", function()
      load3(); ns3.db.profile.enabled = false
      placedAndVisible()
      local g = stage(BarGlow3.check("EXORCISM"), "glow")
      assert.is_false(g.ok)
      assert.equal("addon", g.detail)
    end)

    it("distinguishes the queue glow being off from the bar glow being off", function()
      load3(); ns3.db.profile.glow.enabled = false
      placedAndVisible()
      assert.equal("queue", stage(BarGlow3.check("EXORCISM"), "glow").detail)

      load3{ barGlow = false }
      placedAndVisible()
      assert.equal("bars", stage(BarGlow3.check("EXORCISM"), "glow").detail)
    end)

    -- Being hidden is not a misconfiguration -- it is the display doing what it was told -- but a
    -- chain of ticks over a dark bar still has to be explained.
    it("says when the display is simply hidden right now", function()
      load3()
      placedAndVisible()
      ns3.Display.shouldShow = function() return false, "out of combat, no target" end
      local rows = BarGlow3.check("EXORCISM")
      assert.is_true(stage(rows, "glow").ok)
      assert.is_false(stage(rows, "showing").ok)
      assert.equal("out of combat, no target", stage(rows, "showing").detail)
    end)

    it("says nothing about visibility when the display is showing", function()
      load3()
      placedAndVisible()
      ns3.Display.shouldShow = function() return true, "in combat" end
      assert.is_nil(stage(BarGlow3.check("EXORCISM"), "showing"))
    end)
  end)

  it("survives a provider that throws instead of answering", function()
    ns3.API.RegisterBarProvider{ name = "Broken", buttonsForSpell = function() error("their bug") end }
    local rows = BarGlow3.check("EXORCISM")
    assert.is_false(stage(rows, "placed").ok)
  end)
end)
