-- tests/fixtures/spells.lua — spells data pack for Core specs. Mirrors Data/<flavor>/Spells.lua in
-- SHAPE only (tests/README.md: "Fixtures under tests/fixtures/ mirror Data/ with plain numeric IDs").
--
-- The IDs below are SYNTHETIC — sequential from 1000, deliberately not real game IDs. Core never
-- reads `id`; it keys off the symbolic name, so the number is irrelevant to every test here. Making
-- them obviously fake means no one can mistake this file for verified data or copy an ID out of it
-- into Data/, where hard rule 2 requires a fetched Wowhead source per ID.
--
-- The fields Core actually consumes: `proc` (suppressed for t>0 in simulation), `cdVolatile` (render
-- marker), `cost` (subtracted from the virtual state), `cooldown` (seconds — Simulation cannot derive
-- this, since the State contract exposes only REMAINING cooldown, which is 0 for a spell just picked),
-- `castTime`, `seal`.
return {
  -- abilities
  JUDGEMENT         = { id = 1001, cost = { mana = 120 }, cooldown = 8 },
  EXORCISM          = { id = 1002, cost = { mana = 180 }, cooldown = 15, cdVolatile = true },
  CRUSADER_STRIKE   = { id = 1003, cost = { mana = 100 }, cooldown = 6 },
  DIVINE_STORM      = { id = 1004, cost = { mana = 160 }, cooldown = 10 },
  HOLY_WRATH        = { id = 1005, cost = { mana = 400 }, cooldown = 60, castTime = 2.0 },
  CONSECRATION      = { id = 1006, cost = { mana = 300 }, cooldown = 8 },
  AVENGING_WRATH    = { id = 1007, cooldown = 180 },
  HAMMER_OF_WRATH   = { id = 1008, cost = { mana = 200 }, cooldown = 6 },

  -- seals
  SEAL_OF_MARTYRDOM = { id = 1020, cost = { mana = 260 }, seal = true },
  SEAL_OF_RIGHTEOUSNESS = { id = 1021, cost = { mana = 240 }, seal = true },

  -- auras. HOLY_POWER_BUFF is a stacking resource aura, not a proc: it must survive simulation.
  VENGEANCE_BUFF    = { id = 1040, proc = true },
  HOLY_POWER_BUFF   = { id = 1041, proc = false },
  DIVINE_FAVOR_BUFF = { id = 1042, proc = false },

  -- runes (teach-abilities; `rune` names the engraving slot, as in the real data pack)
  RUNE_ART_OF_WAR   = { id = 1060, rune = "chest" },
  RUNE_DIVINE_STORM = { id = 1061, rune = "legs" },
}
