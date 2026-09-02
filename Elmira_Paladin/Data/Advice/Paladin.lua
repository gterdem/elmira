-- Data/SoD/Advice/Paladin.lua — gear-conditional recommendations per build (S1/S6). Evaluated by Core/Advisor.lua
-- against what the player CURRENTLY has. First matching `soul` rule wins. Never assumes BiS.
local ADDON, ns = ...
ns.Data.SoD.Advice = ns.Data.SoD.Advice or {}
ns.Data.SoD.Advice.PALADIN = {
  PALADIN_EXODIN = {
    soul = { { pick = "SOUL_OF_THE_EXILE", reason = "Always for Exodin; boosts Exorcism (Sealbearer was nerfed)" } },
    weapon = { type = "2H", maxSpeed = 3.0, reason = "Fast 2H maximises Art of War/SoM value" },
    runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM", "RUNE_PURIFYING_POWER", "RUNE_WRATH",
              "RUNE_RIGHTEOUS_VENGEANCE", "RUNE_SHEATH_OF_LIGHT", "RUNE_AURA_MASTERY" },
    ringRunes = { human = { "HOLY_SPECIALIZATION" }, default = { "HOLY_SPECIALIZATION", "WEAPON_SPECIALIZATION_MATCHING_WEAPON" } },
  },
  PALADIN_WRATHLIKE = {
    soul = { { when = { {"set","PALADIN_T25_AVENGERS", min = 2} }, pick = "SOUL_OF_THE_EXILE", reason = "Exile with Avenger's 2-set" },
             { pick = "SOUL_OF_THE_RETRIBUTOR", reason = "Retributor when not using T2.5 (also after T3.5 6-set)" } },
    weapon = { type = "2H", minSpeed = 3.0 },
  },
  PALADIN_TWIST = {
    soul = { { when = { {"set","PALADIN_T2_JUDGEMENT", min = 4} }, pick = "SOUL_OF_THE_RETRIBUTOR", reason = "With Draconic 4-set" },
             { pick = "SOUL_OF_THE_JUDICATOR", reason = "Default with Draconic 2-set" } },
    weapon = { type = "2H", minSpeed = 3.0 },
  },
  PALADIN_STACK = {
    soul = { { pick = "SOUL_OF_THE_SEALBEARER", reason = "Required for seal stacking" } },
    weapon = { type = "2H", minSpeed = 3.0 },
  },
  PALADIN_PROT = {
    soul = {},  -- TODO M2: research tank souls
    weapon = { type = "Shield" },
    runes = { "RUNE_HAND_OF_RECKONING", "RUNE_MALLEABLE_PROTECTION", "RUNE_AEGIS", "RUNE_HAMMER_OF_THE_RIGHTEOUS", "RUNE_AVENGERS_SHIELD" },
  },
  -- Cross-build warnings
  warnings = {
    { soul = "SOUL_OF_THE_TEMPLAR", when = { {"weapon","2H"} }, text = "Soul of the Templar no longer works with two-handed weapons." },
    { soul = "SOUL_OF_THE_SEALBEARER", unlessBuild = "PALADIN_STACK", text = "Sealbearer was nerfed; only Seal Stacking wants it." },
  },
}
