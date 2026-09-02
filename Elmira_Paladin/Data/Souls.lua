-- Data/SoD/Souls.lua — shoulder "Soul of the …" enchants.
-- Detected from the shoulder TOOLTIP, matching `short` — NOT from the item link. Verified in game
-- 2026-09-01 (docs/07 §9.10, docs/01 §5a): the link's enchant field is empty even when a soul is on
-- the shoulder, so there is no enchant ID to carry and the old `enchantID` key has been dropped
-- rather than left as a permanent placeholder. `short` is the localized name as it appears in the
-- tooltip line, which makes v1 soul detection enUS-only (known limitation).
-- `grants` lists abstract bonus keys resolved by state.bonus(); a build conditions on the bonus, not the source.
local ADDON, ns = ...
ns.Data = ns.Data or {}
ns.Data.SoD = ns.Data.SoD or {}
ns.Data.SoD.Souls = {
  SOUL_OF_THE_EXILE      = { itemID = 236554, grants = { "EXORCISM_DAMAGE_SOUL" },
                             src = "https://www.wowhead.com/classic/item=236554/soul-of-the-exile", short = "Exile", roles = { "RET_EXODIN", "RET_WRATHLIKE" } },
  SOUL_OF_THE_RETRIBUTOR = { itemID = 236551, grants = { "CRUSADER_STRIKE_150" },
                             src = "https://www.wowhead.com/classic/item=236551/soul-of-the-retributor", short = "Retributor", roles = { "RET_WRATHLIKE", "RET_TWIST" } },
  SOUL_OF_THE_JUDICATOR  = { itemID = 236549, grants = { "JUDICATOR_SOUL" },
                             src = "https://www.wowhead.com/classic/item=236549/soul-of-the-judicator", short = "Judicator", roles = { "RET_TWIST" } },
  SOUL_OF_THE_SEALBEARER = { itemID = 236547, grants = { "SEAL_LINGER_6S" },
                             src = "https://www.wowhead.com/classic/item=236547/soul-of-the-sealbearer", short = "Sealbearer", roles = { "RET_STACK" }, note = "Nerfed in P8 (S1)" },
  SOUL_OF_THE_TEMPLAR    = { itemID = 236555, grants = {},
                             src = "https://www.wowhead.com/classic/item=236555/soul-of-the-templar", short = "Templar", note = "No longer works with 2H weapons (S6)" },
  SOUL_OF_THE_VINDICATOR = { itemID = 236544, grants = {}, src = "https://www.wowhead.com/classic/item=236544/soul-of-the-vindicator", short = "Vindicator", roles = { "HOLY_HEALER" } },
}
-- Bonus keys that can come from EITHER set pieces OR a soul. This table is the resolution
-- source: Sets.lua thresholds do NOT carry a `bonus` key, so `from` below is what state.bonus() walks.
ns.Data.SoD.Bonuses = {
  CRUSADER_STRIKE_150 = { note = "150% Crusader Strike damage", from = { { set = "PALADIN_T25_AVENGERS", pieces = 2 }, { soul = "SOUL_OF_THE_RETRIBUTOR" } } },
  -- Core Forged also grants this at 6 pieces, but it is not an enumerable set (see Sets.lua) and its
  -- only consumer is the M5d Stack build, so the set source is deferred with it. Soul-only for now.
  SEAL_LINGER_6S      = { note = "Both seals linger 6s after casting a second seal", from = { { soul = "SOUL_OF_THE_SEALBEARER" } } },
  JUDGEMENT_NO_CONSUME = { note = "+5% damaging Judgements; seals not consumed", from = { { set = "PALADIN_T2_JUDGEMENT", pieces = 2 } } },
  HOLY_POWER_CONSUME  = { note = "Divine Storm consumes Holy Power", from = { { set = "PALADIN_T35_INQUISITION", pieces = 4 } } },
  HOLY_WRATH_INSTANT  = { note = "Holy Wrath instant + shorter CD", from = { { set = "PALADIN_T3_REDEMPTION", pieces = 4 } } },
  EXORCISM_DAMAGE_SOUL = { note = "Exorcism damage (soul only)", from = { { soul = "SOUL_OF_THE_EXILE" } } },
  -- Effect text read from Wowhead 2026-09-01. Rotation-relevant: it moves Judgement's cooldown, so
  -- whether any shipped build should react to it is a build question, not a data one.
  JUDICATOR_SOUL      = { note = "Judgement cooldown -5s, Judgement damage -45%", from = { { soul = "SOUL_OF_THE_JUDICATOR" } } },
}
