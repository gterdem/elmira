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
