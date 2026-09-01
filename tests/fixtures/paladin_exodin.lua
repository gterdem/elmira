-- tests/fixtures/paladin_exodin.lua — a build fixture for Core specs, shaped exactly like a shipped
-- build (docs/02-CONDITION-SCHEMA.md) and structured after the staged Exodin priority.
--
-- This is TEST DATA, not a shipped build: it is not in the catalog, and the real
-- Elmira_Paladin/Data/Builds/Paladin_Exodin.lua arrives at M2 once its IDs are verified. It exists to
-- exercise the engine, so it deliberately covers the awkward shapes — a gated duplicate of an entry
-- that also appears ungated below it (ADR-0006: gated variant above, baseline below), nested any/not,
-- a variadic condition, an item entry, and a `hold` entry.
return {
  schema = 1,
  key = "PALADIN_EXODIN",
  name = "Paladin — Exodin (fixture)",
  class = "PALADIN",
  flavor = "SoD",
  notes = "Fixture build. Baseline is playable with no sets and no runes.",
  requires = { weapon = "2H", maxSpeed = 3.0 }, -- advisory only; never affects evaluation
  entries = {
    { spell = "SEAL_OF_MARTYRDOM", when = { {"no_seal"} }, label = "Seal up" },
    { spell = "EXORCISM", when = { {"buff", "VENGEANCE_BUFF"} }, label = "Proc" },
    { spell = "JUDGEMENT", label = "Seal expiring",
      when = { {"seal", "SEAL_OF_MARTYRDOM"}, {"buff", "SEAL_OF_MARTYRDOM", maxRemaining = 3} } },
    { spell = "JUDGEMENT", when = { {"bonus", "JUDGEMENT_NO_CONSUME"} }, label = "Draconic 2p" },
    { spell = "EXORCISM" },
    { spell = "CRUSADER_STRIKE" },
    { spell = "DIVINE_STORM", label = "3 Holy Power",
      when = { {"buff", "HOLY_POWER_BUFF", min = 3}, {"bonus", "HOLY_POWER_CONSUME"} } },
    { spell = "DIVINE_STORM" },
    { spell = "HOLY_WRATH", when = { {"target_type", "Undead", "Demon"} }, label = "Undead" },
    { spell = "AVENGING_WRATH", hold = true, label = "Burst",
      when = { {"buff", "VENGEANCE_BUFF"},
               {"any", {"buff", "HOLY_POWER_BUFF", min = 3}, {"not", {"set", "PALADIN_T35_INQUISITION", min = 2}}} } },
    { spell = "CONSECRATION", when = { {"resource", "MANA", minPct = 40} } },
    { item = 13, hold = true, when = { {"item_ready", 13} }, label = "Trinket" },
  },
}
