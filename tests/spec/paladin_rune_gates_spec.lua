-- tests/spec/paladin_rune_gates_spec.lua — the shipped Paladin rune ids against what a live client
-- actually reports, in the slot the rune actually occupies.
--
-- This exists because of a defect the rest of the suite could not see. `S:rune()` compares the data
-- pack's stored id against `C_Engraving.GetRuneForEquipmentSlot(slot).learnedAbilitySpellIDs`, so a
-- rune gate fails silently — no error, no warning, the line simply never fires — when EITHER the
-- stored id is not the ability id the client reports, OR the slot is missing from the adapter's
-- scan list. Both shipped at once: RUNE_SHOCK_AND_AWE held 440791 (an older passive override spell)
-- and the cloak slot was not scanned at all.
--
-- The ids below are hardcoded from the owner's client sweeps on Arthorion, 2026-09-03, NOT read back
-- out of the pack — reading them from the pack would make every assertion tautological, which is the
-- exact shape of test that let the original defect through. Each is a number a human read off a
-- `/dump` and typed here.
--
-- Any rune can be engraved by any paladin at any time -- a rune is learned once and then known for
-- good, so swapping one in costs nothing -- and "the character does not play that spec" is never a
-- reason an id cannot be verified. RUNE_RIGHTEOUS_VENGEANCE and RUNE_SHEATH_OF_LIGHT
-- were held back from this table on exactly that mistaken reasoning; the owner engraved both on
-- Arthorion and settled them in one pass.
local helper = require("tests.helper")
local mock = require("tests.wow_mock")

describe("Paladin rune gates against a live client sweep (Arthorion, 2026-09-03)", function()
  local Vanilla, pack

  -- slot -> { rune data key, ability id as the client reported it }
  local OBSERVED = {
    { slot = 1,  key = "RUNE_FANATICISM",              id = 429142 },
    { slot = 5,  key = "RUNE_HALLOWED_GROUND",         id = 458287 },
    { slot = 6,  key = "RUNE_INFUSION_OF_LIGHT",       id = 426065 },
    { slot = 6,  key = "RUNE_MALLEABLE_PROTECTION",    id = 458318 },
    { slot = 7,  key = "RUNE_REBUKE",                  id = 425609 },
    { slot = 8,  key = "RUNE_ART_OF_WAR",              id = 426157 },
    { slot = 9,  key = "RUNE_PURIFYING_POWER",         id = 429144 },
    { slot = 9,  key = "RUNE_HAMMER_OF_THE_RIGHTEOUS", id = 407632 },
    { slot = 10, key = "RUNE_CRUSADER_STRIKE",         id = 407676 },
    { slot = 10, key = "RUNE_HAND_OF_RECKONING",       id = 407631 },
    { slot = 15, key = "RUNE_SHIELD_OF_RIGHTEOUSNESS", id = 440658 },
    { slot = 15, key = "RUNE_SHOCK_AND_AWE",           id = 462834 },
    -- Engraved on Arthorion 2026-09-03 specifically to settle these two. 440672 corrected an
    -- actionbar-override id; 426158 chose Wowhead over wowsims' 426159.
    { slot = 15, key = "RUNE_RIGHTEOUS_VENGEANCE",     id = 440672 },
    { slot = 6,  key = "RUNE_SHEATH_OF_LIGHT",         id = 426158 },
  }

  before_each(function()
    mock.reset()
    Vanilla = helper.load("Elmira/Adapters/Vanilla.lua")
    pack = helper.classPack("Paladin")
  end)

  for _, case in ipairs(OBSERVED) do
    it(case.key .. " is detected when the client reports " .. case.id .. " in slot " .. case.slot, function()
      mock.runes[case.slot] = { name = case.key, learnedAbilitySpellIDs = { case.id } }
      local state = Vanilla.newState(pack.spells, pack.sets, pack.souls)
      assert.is_true(state:rune(case.key),
        case.key .. ": the client reports " .. case.id .. " in slot " .. case.slot ..
        " but the gate did not fire — either the shipped id is wrong or the slot is not scanned")
    end)
  end

  it("does not fire a gate for a rune the client is not reporting", function()
    local state = Vanilla.newState(pack.spells, pack.sets, pack.souls)
    assert.is_false(state:rune("RUNE_SHOCK_AND_AWE"))
  end)
end)
