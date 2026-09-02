-- Data/SoD/Sets.lua — item IDs per set + bonus spell IDs per threshold (spec-specific in SoD).
local ADDON, ns = ...

ns.Data = ns.Data or {}
ns.Data.SoD = ns.Data.SoD or {}
ns.Data.SoD.Sets = {
  PALADIN_T2_JUDGEMENT = {
    -- Proper set name is Radiant Judgement; guides call it "Draconic" after the item quality tag and
    -- the vanilla-era name was Judgement Armor, so both are kept as aliases for search/advice text.
    -- NOT the same set as Lawbringer Radiance (the Molten Core "Core Forged" twin), which is a
    -- separate key and the likely source of the seal-linger 6p — deliberately not merged here.
    name = "Radiant Judgement", aliases = { "Judgement Armor", "Draconic" },
    src = "https://www.wowhead.com/classic/item-set=1810",
    items = { 231178, 231176, 231181, 231174,
              231179, 231175, 231177, 231180 },
    bonuses = { -- spec = "RETRIBUTION"; kind = "passive" (no aura) | "aura" (use buff condition instead)
      [2] = { spell = 467518, src = "https://www.wowhead.com/classic/item-set=1810", spec = "RETRIBUTION", kind = "passive",
              note = "+5% damaging Judgements; Judgements no longer consume seals; can trigger multiple seals (S1)" },
      -- Corrected 2026-09-01: this is the SOUL OF THE JUDICATOR effect, not the Retributor. Both the
      -- soul research and the Judicator's own Wowhead text give Judgement CD -5s / damage -45%; the
      -- dossier's "Soul of the Retributor" attribution was wrong (that soul maps to the T2.5 2-set).
      [4] = { spell = 467526, src = "https://www.wowhead.com/classic/item-set=1810", spec = "RETRIBUTION", kind = "passive",
              note = "Judgement cooldown -5s, Judgement damage -45% (same effect as Soul of the Judicator)" },
      -- Stacking, timed buff => an aura, not a passive (hard rule 5: detect effects, not causes).
      -- The APPLIED aura's id is not on Wowhead; 467529 is the bonus spell, the same split as the
      -- T3.5 2-set's 1226460 (bonus) vs 1226461 (HOLY_POWER_BUFF). Needs a /dump in game.
      -- Not Exodin-blocking: no shipped build gates on the T2 6-set yet.
      -- 467529 is a server-side dummy script, so Wowhead cannot show the aura it applies. The aura is
      -- Swift Judgement (see Spells.lua) and that is what a condition watches — ADR-0004, detect the
      -- effect, not the cause. A build must never gate on {"set", ..., min = 6} for this.
      [6] = { spell = 467529, src = "https://www.wowhead.com/classic/item-set=1810", spec = "RETRIBUTION", kind = "aura", aura = "SWIFT_JUDGEMENT_BUFF",
              note = "Judgement grants +1% Holy damage per stack, 5 stacks max, 8s (Swift Judgement)" },
    },
  },
  PALADIN_T25_AVENGERS = {
    name = "Avenger's Radiance (T2.5, SoD)", src = "https://www.wowhead.com/classic/item-set=1845",
    items = { 233398, 233401, 233397, 233400, 233399 },
    bonuses = {
      [2] = { spell = 1213397, src = "https://www.wowhead.com/classic/item-set=1845", spec = "RETRIBUTION", kind = "passive", note = "150% Crusader Strike damage (P8 retune)" },
      -- Resolved 2026-09-01: a buff DOES land on the player — Excommunication (1217927), 20s, 3
      -- stacks, +36% Exorcism damage, applied on melee white hits. Was `passive` on a conservative
      -- reading, which was wrong; ADR-0004 makes this an aura. The rotation guidance is unchanged
      -- and still matters: it boosts the next Exorcism, it is NOT a reason to hold Exorcism.
      [4] = { spell = 1213406, src = "https://www.wowhead.com/classic/item-set=1845", spec = "RETRIBUTION", kind = "aura", aura = "EXCOMMUNICATION_BUFF",
              note = "Excommunication: +36% next Exorcism, 20s, 3 stacks; does NOT change rotation — never hold Exorcism (S1)" },
    },
  },
  PALADIN_T3_REDEMPTION = {
    name = "Redemption Warplate (T3, SoD)", src = "https://www.wowhead.com/classic/item-set=1896",
    -- 9 pieces, NOT 8: the in-game tooltip reads "(n/9)" and the thresholds are 2/9, 4/9, 6/9.
    -- Band of Redemption (236130) IS a member and counts — confirmed in game 2026-09-01 (docs/07
    -- §9.12). A ring in an armour set is unusual, which is why this was worth checking rather than
    -- assuming; excluding it would have withheld the 4-set HOLY_WRATH_INSTANT the Exodin build gates
    -- on from anyone wearing the ring as one of their four.
    -- The Holy and Prot variants have their own rings for M5: Redemption Armor 236116,
    -- Redemption Bulwark 236139.
    items = { 236128, 236126, 236132, 236124,
              236129, 236125, 236127, 236131, 236130 },
    bonuses = {
      [2] = { spell = 1219189, src = "https://www.wowhead.com/classic/item-set=1896", spec = "RETRIBUTION", kind = "passive", note = "Divine Storm damage bonus (S1/S6)" },
      -- Exact in-game text 2026-09-02 (docs/07 §9.14): "Reduces the cast time of your Holy Wrath
      -- ability by 100%, reduces its cooldown by 25%, and reduces its mana cost by 75%." The mana
      -- reduction was not recorded before and shows up live as Holy Wrath costing 201 vs a shipped
      -- fallback of 805 — another reason the shipped cost is a fallback only.
      [4] = { spell = 1219191, src = "https://www.wowhead.com/classic/item-set=1896", spec = "RETRIBUTION", kind = "passive", note = "Holy Wrath: instant cast, -25% cooldown, -75% mana" },
      -- Exact in-game text: the Undead bonus applies only "while Righteous Fury is not active and
      -- Hand of Reckoning is not engraved" — i.e. it is silently off for a tanking paladin. Those
      -- conditions were not in the dossier's summary.
      [6] = { spell = 1219193, src = "https://www.wowhead.com/classic/item-set=1896", spec = "RETRIBUTION", kind = "passive", note = "vs Undead only, and only while Righteous Fury is inactive and Hand of Reckoning is not engraved" },
    },
  },
  PALADIN_T35_INQUISITION = {
    name = "Inquisition Warplate (T3.5, Scarlet Enclave)", src = "https://www.wowhead.com/classic/item-set=1940",
    items = { 240027, 240025, 240030, 240023,
              240028, 240024, 240026, 240029 },
    bonuses = {
      [2] = { spell = 1226460, src = "https://www.wowhead.com/classic/item-set=1940", spec = "RETRIBUTION", kind = "aura", aura = "HOLY_POWER_BUFF",
              note = "CS/Exorcism grant Holy Power (+10% Holy dmg/stack, 3 max, 15s) with a 2H — detect via buff" },
      [4] = { spell = 1226462, src = "https://www.wowhead.com/classic/item-set=1940", spec = "RETRIBUTION", kind = "passive", note = "DS/Holy Shock/Holy Wrath consume Holy Power" },
      [6] = { spell = 1226463, src = "https://www.wowhead.com/classic/item-set=1940", spec = "RETRIBUTION", kind = "aura", aura = "TEMPLAR_BUFF",
              note = "Templar: +15% AP per Holy Power consumed, max 3 stacks, 10s" },
    },
  },
  -- PALADIN_T1_T2_CORE_FORGED is DEFERRED TO M5d, not lost. Core Forged is not a set: it is a P5
  -- stat/bonus trading mechanic (BWL stats + MC bonuses, from the Hydraxian vendors), so it has no
  -- Wowhead item-set page and no enumerable piece list — nothing to verify against, and the entry
  -- could only ever hold a placeholder id. Its one consumer is SEAL_LINGER_6S for the
  -- Stack build, which is M5d; until then that bonus comes from Soul of the Sealbearer alone.
}
