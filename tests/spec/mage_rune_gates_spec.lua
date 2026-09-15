-- tests/spec/mage_rune_gates_spec.lua — the shipped Mage rune ids against the adapter's actual
-- detection mechanism (mirror of paladin_rune_gates_spec.lua).
--
-- Unlike that file, these ids are NOT from an owner client sweep: no `/dump` pass against a live P8
-- Mage exists yet (the checklist this pass ships asks the owner to run one). What this file proves
-- instead is the mechanism paladin_rune_gates_spec.lua exists to guard against breaking again:
-- `S:rune()` (Adapters/Vanilla.lua) scans EVERY entry in `RUNE_SLOTS` for the stored ability id,
-- regardless of which slot the record names — so a rune record only needs the client to report its
-- id in ANY of the ten slots to be detected, and `rune = "<slot>"` in Mage.lua is display text for
-- the wizard's shopping list, never an input to detection (see Setup/Detect.lua's `engrave` text and
-- Adapters/Vanilla.lua's own comment on why `equipmentSlot` is never trusted).
--
-- Ids below are read straight back out of Elmira/Classes/Mage.lua (`helper.classPack("Mage")`),
-- which makes this a MECHANISM test (does a rune reported in some slot get detected at all, and does
-- a rune reported nowhere correctly not), not an independent pin on the ids themselves — the ids are
-- policed instead by tests/spec/data_sourcing_spec.lua (every one carries a Wowhead `src`) and by
-- mage-ids-verified-2026-09-14.md's follow-up note. Once the owner's `/dump` sweep lands, this
-- file should switch to hardcoded observed ids exactly the way Paladin's did (see its own header).
local helper = require("tests.helper")
local mock = require("tests.wow_mock")

describe("Mage rune gates against the adapter's slot-scanning mechanism (no live sweep yet)", function()
  local Vanilla, pack

  before_each(function()
    mock.reset()
    Vanilla = helper.load("Elmira/Adapters/Vanilla.lua")
    pack = helper.classPack("Mage")
  end)

  -- Every RUNE_* record the pack ships, gated on ANY one of the ten scanned slots (1 here — the
  -- mechanism does not care which). A rune record whose id the client is not reporting anywhere
  -- must never read as engraved (the second `it` below).
  local RUNE_KEYS = {
    "RUNE_HOT_STREAK", "RUNE_OVERHEAT", "RUNE_ENLIGHTENMENT", "RUNE_FINGERS_OF_FROST",
    "RUNE_BRAIN_FREEZE", "RUNE_SPELL_POWER", "RUNE_FIRE_SPECIALIZATION", "RUNE_FROST_SPECIALIZATION",
    "RUNE_LIVING_BOMB", "RUNE_FROSTFIRE_BOLT", "RUNE_BALEFIRE_BOLT", "RUNE_ICY_VEINS",
    "RUNE_DEEP_FREEZE", "RUNE_FROZEN_ORB", "RUNE_ICE_LANCE", "RUNE_SPELLFROST_BOLT",
    "RUNE_LIVING_FLAME", "RUNE_MOLTEN_ARMOR",
    -- MG2: the Arcane healer's own rune twins.
    "RUNE_ARCANE_BLAST", "RUNE_MISSILE_BARRAGE", "RUNE_MASS_REGENERATION",
    "RUNE_CHRONOSTATIC_PRESERVATION", "RUNE_REWIND_TIME", "RUNE_ARCANE_BARRAGE",
    "RUNE_ADVANCED_WARDING", "RUNE_ARCANE_SPECIALIZATION",
  }

  for _, key in ipairs(RUNE_KEYS) do
    it(key .. " is detected when the client reports its id in any scanned slot", function()
      local id = pack.spells[key] and pack.spells[key].id
      assert.is_number(id, key .. " has no id in the shipped pack")
      mock.runes[1] = { name = key, learnedAbilitySpellIDs = { id } }
      local state = Vanilla.newState(pack.spells, pack.sets, pack.souls)
      assert.is_true(state:rune(key),
        key .. ": the client reports id " .. id .. " in a scanned slot but the gate did not fire")
    end)
  end

  it("does not fire a gate for a rune the client is not reporting anywhere", function()
    local state = Vanilla.newState(pack.spells, pack.sets, pack.souls)
    assert.is_false(state:rune("RUNE_OVERHEAT"))
  end)

  -- Two rune-taught abilities intentionally SHARE their slot with a differently-speced sibling
  -- (dossier: legs = Icy Veins for Fire XOR Living Flame's slot for leveling; hands = Living Bomb for
  -- Fire XOR Ice Lance for Frost) — engraving one must never falsely satisfy the other's gate, since
  -- they are different abilities with different ids.
  it("engraving Ice Lance's rune does not also satisfy Living Bomb's (same slot label, different ids)", function()
    mock.runes[1] = { name = "RUNE_ICE_LANCE", learnedAbilitySpellIDs = { pack.spells.RUNE_ICE_LANCE.id } }
    local state = Vanilla.newState(pack.spells, pack.sets, pack.souls)
    assert.is_true(state:rune("RUNE_ICE_LANCE"))
    assert.is_false(state:rune("RUNE_LIVING_BOMB"))
  end)
end)
