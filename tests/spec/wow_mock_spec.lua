-- tests/spec/wow_mock_spec.lua — tests the TEST HARNESS.
--
-- Until M2, nothing loaded tests/wow_mock.lua. The adapter specs are its first consumer, which means
-- they were about to trust an untested mock: if the mock lies, every adapter spec goes green over a
-- broken adapter and the failure only appears in game. That is the most expensive shape of this
-- project's characteristic bug, so the harness gets its own tests before anything depends on it.
--
-- Two things are tested here that a normal mock would not bother with, because the live client
-- surprised us on both and the mock is only useful if it reproduces the surprise:
--   * GetSpellCooldown returns the GCD during the GCD (docs/07 §9.10)
--   * GetTalentTabInfo does not return the name first (docs/07 §9.8)
local mock = require("tests.wow_mock")

describe("tests/wow_mock (the harness itself)", function()
  before_each(function() mock.reset() end)

  describe("reset", function()
    -- The mock writes into _G, so without this every spec inherits the previous one's state and the
    -- suite becomes order-dependent — the exact failure helper.reset() exists to prevent for ns.
    it("clears state set by a previous spec", function()
      mock.cooldowns[123] = { 0, 30 }
      mock.level = 12
      mock.auras.player[1] = { name = "Leaked", spellID = 999 }

      mock.reset()

      assert.same({}, mock.cooldowns)
      assert.equal(60, mock.level)
      assert.is_nil(mock.auras.player[1])
      assert.is_nil(UnitAura("player", 1, "HELPFUL"))
    end)

    -- pairs() skips nil values, so a default of nil can never be restored by copying defaults().
    -- Found by an adapter spec seeing a stale "Undead" after asking for no target.
    it("clears a field whose default is nil", function()
      mock.creatureType = "Undead"
      mock.reset()
      assert.is_nil(mock.creatureType)
      assert.is_nil(UnitCreatureType("target"))
    end)

    it("does not share the auras table between resets", function()
      mock.auras.player[1] = { name = "A", spellID = 1 }
      mock.reset()
      mock.auras.player[1] = { name = "B", spellID = 2 }
      assert.equal("B", (UnitAura("player", 1, "HELPFUL")))
    end)
  end)

  describe("GetSpellCooldown", function()
    it("reports a real cooldown", function()
      mock.spell(415073, { cooldown = 6 })
      local _, duration = GetSpellCooldown(415073)
      assert.equal(6, duration)
    end)

    it("reports zero for a spell that is not on cooldown", function()
      local _, duration = GetSpellCooldown(415073)
      assert.equal(0, duration)
    end)

    -- The trap. An adapter that caches this blindly records 1.5 as Exorcism's cooldown forever.
    it("reports the GCD for an unrelated spell while the GCD is running", function()
      mock.gcdActive = true
      local _, duration = GetSpellCooldown(415073)
      assert.equal(1.5, duration)
    end)

    it("still reports the real cooldown during the GCD when the spell has one", function()
      mock.spell(415073, { cooldown = 6 })
      mock.gcdActive = true
      local _, duration = GetSpellCooldown(415073)
      assert.equal(6, duration)
    end)
  end)

  describe("spell knowledge", function()
    it("treats an unregistered spell as not known", function()
      assert.is_false(IsPlayerSpell(415073))
      assert.is_nil(GetSpellInfo(415073))
    end)

    it("registers a spell as known", function()
      mock.spell(415073, { castTime = 0 })
      assert.is_true(IsPlayerSpell(415073))
      assert.equal("Spell415073", (GetSpellInfo(415073)))
    end)

    -- docs/07 §9.6: the client returned no rank string. A mock that invented one would let code
    -- depend on something the client never supplies.
    it("returns no rank string", function()
      mock.spell(20271)
      local _, rank = GetSpellInfo(20271)
      assert.is_nil(rank)
    end)
  end)

  describe("GetSpellPowerCost", function()
    it("returns a list of cost tables, not a bare number", function()
      mock.spell(415073, { cost = 69 })
      local costs = GetSpellPowerCost(415073)
      assert.equal(69, costs[1].cost)
    end)

    it("returns an empty list for a spell with no cost", function()
      assert.same({}, GetSpellPowerCost(415073))
    end)
  end)

  describe("C_Engraving", function()
    it("returns nothing for a slot with no rune", function()
      assert.is_nil(C_Engraving.GetRuneForEquipmentSlot(5))
    end)

    -- The verbatim round-2 chest reading (docs/07 §9.5).
    it("returns learnedAbilitySpellIDs for an engraved slot", function()
      mock.runes[5] = { name = "Hallowed Ground", learnedAbilitySpellIDs = { 458287 } }
      local rune = C_Engraving.GetRuneForEquipmentSlot(5)
      assert.equal("Hallowed Ground", rune.name)
      assert.same({ 458287 }, rune.learnedAbilitySpellIDs)
    end)

    -- IsEngravingEnabled is a real call and NOT equivalent to `C_Engraving ~= nil` (docs/07 §9.5).
    it("can report engraving as disabled while the table still exists", function()
      mock.engravingEnabled = false
      assert.is_false(C_Engraving.IsEngravingEnabled())
      assert.is_not_nil(C_Engraving)
    end)
  end)

  -- The client only refreshes GetAddOnMemoryUsage's figures on request; a mock that always returned
  -- the fresh number would let a spec pass whether or not Vanilla.addonMemoryKB() called
  -- UpdateAddOnMemoryUsage() first, which is the exact bug `/elm debug perf` used to have with the
  -- whole-heap figure being just as stale in spirit. This proves the mock reproduces the trap.
  describe("addon memory", function()
    it("reports a stale reading until UpdateAddOnMemoryUsage() is called", function()
      mock.addons[1] = { name = "Elmira", memory = 0, pendingMemory = 250 }
      assert.equal(0, GetAddOnMemoryUsage(1))
      UpdateAddOnMemoryUsage()
      assert.equal(250, GetAddOnMemoryUsage(1))
    end)

    it("exposes the same list through C_AddOns.GetNumAddOns/GetAddOnInfo", function()
      mock.addons[1] = { name = "Elmira", memory = 10 }
      mock.addons[2] = { name = "Recount", memory = 20 }
      assert.equal(2, C_AddOns.GetNumAddOns())
      assert.equal("Elmira", C_AddOns.GetAddOnInfo(1))
      assert.equal("Recount", C_AddOns.GetAddOnInfo(2))
    end)

    it("reset() clears addons set by a previous spec", function()
      mock.addons[1] = { name = "Leaked", memory = 999 }
      mock.reset()
      assert.same({}, mock.addons)
      assert.equal(0, C_AddOns.GetNumAddOns())
    end)
  end)

  describe("GetTalentTabInfo", function()
    -- docs/07 §9.8: position 1 is a numeric tab id, points are in position 5. Code written against
    -- the documented name-first shape must fail here, not in game.
    it("does not return the name first", function()
      local first, _, _, _, points = GetTalentTabInfo(1)
      assert.equal(382, first)
      assert.equal(31, points)
    end)
  end)

  describe("scanning tooltip", function()
    it("publishes tooltip lines as globals the way Classic does", function()
      mock.tooltipLines[3] = { "Truthbearer Pauldrons", "Exile" }
      local tip = CreateFrame("GameTooltip", "TestScanTooltip", nil, "GameTooltipTemplate")
      tip:ClearLines()
      tip:SetInventoryItem("player", 3)

      assert.equal(2, tip:NumLines())
      assert.equal("Exile", _G["TestScanTooltipTextLeft2"]:GetText())
    end)

    it("reports no lines for a slot with no item", function()
      local tip = CreateFrame("GameTooltip", "TestScanTooltip2", nil, "GameTooltipTemplate")
      tip:SetInventoryItem("player", 3)
      assert.equal(0, tip:NumLines())
    end)
  end)

  describe("AuraUtil.FindAuraByName", function()
    it("finds an aura and returns its spellID in field 10", function()
      mock.auras.player[1] = { name = "Avenging Wrath", spellID = 407788, duration = 20 }
      local name, _, _, _, _, _, _, _, _, spellID =
        AuraUtil.FindAuraByName("Avenging Wrath", "player", "HELPFUL")
      assert.equal("Avenging Wrath", name)
      assert.equal(407788, spellID)
    end)

    it("returns nil when the aura is absent", function()
      assert.is_nil(AuraUtil.FindAuraByName("Avenging Wrath", "player", "HELPFUL"))
    end)
  end)
end)
