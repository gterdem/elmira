-- Data/SoD/Catalog.lua — shipped playstyle catalog read by Setup/Wizard.lua. Refresh with the
-- build-catalog-refresh skill each phase. Dates/sources reflect what the entry was derived from.
local ADDON, ns = ...
-- `available` gates what the wizard may offer. Only PALADIN_EXODIN ships a build file at M2; the
-- other five are researched and dated but have no Builds/*.lua yet, and offering them would hand the
-- user a playstyle that resolves to nil. Flip an entry to available when its build lands (M5).
-- Enforced by tests/spec/data_sourcing_spec.lua.
ns.Data.SoD.Catalog = {
  version = 1, flavor = "SoD", phase = "P8",
  PALADIN = {
    { build = "PALADIN_EXODIN", available = true, playstyle = "Exodin — fast 2H, single seal (Ret)", difficulty = "easy", recommended = true,
      updated = "2026-08-31", phase = "SoD P8",
      source = "https://www.wowhead.com/classic/guide/season-of-discovery/classes/paladin/dps-rotation-cooldowns-abilities-pve",
      summary = "Seal of Martyrdom, Exorcism never held, Crusader Strike; DS at 3 Holy Power with T3.5 4-set. ~20-33% ahead in Naxx; viable in SE.",
      requires = { weapon = "2H", maxSpeed = 3.0, runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM" } } },
    { build = "PALADIN_WRATHLIKE", available = false, playstyle = "Wrath-like — slow 2H, mono seal (Ret)", difficulty = "easy",
      updated = "2026-08-31", phase = "SoD P8", source = "https://onlyfarms.gg/guides/season-of-discovery-paladin-dps-bis-gear-pve-guide/",
      summary = "Relaxed Divine Storm / Crusader Strike / Exorcism priority on a slow two-hander.",
      requires = { weapon = "2H", minSpeed = 3.0 } },
    { build = "PALADIN_PROT", available = false, playstyle = "Protection — sword & board tank", difficulty = "easy",
      updated = "2026-08-31", phase = "SoD P8",
      source = "https://www.wowhead.com/classic/guide/season-of-discovery/classes/paladin/tank-talent-builds-runes",
      summary = "Holy Shield uptime, Shield of Righteousness + Hammer of the Righteous on cooldown, Judgement, Exorcism procs.",
      requires = { weapon = "Shield", runes = { "RUNE_HAND_OF_RECKONING" } } },
    { build = "PALADIN_SHOCKADIN", available = false, playstyle = "Shockadin — Holy caster DPS", difficulty = "medium",
      updated = "2026-08-31", phase = "SoD P8", source = "https://www.zockify.com/wowclassic/paladin/dps/",
      summary = "Seal of Righteousness, Judgement of Righteousness and Holy Shock on cooldown; JotC maintenance.",
      requires = { weapon = "1H" } },
    { build = "PALADIN_TWIST", available = false, playstyle = "Seal twisting (Ret)", difficulty = "hard", experimental = true,
      updated = "2026-08-31", phase = "SoD P8", source = "https://onlyfarms.gg/guides/season-of-discovery-paladin-dps-bis-gear-pve-guide/",
      summary = "Highest ceiling (~7-9% in SE). Swing-timer driven; experimental — watch the twist-success readout.", requires = { weapon = "2H", minSpeed = 3.0, runes = { "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM" } } },
    { build = "PALADIN_STACK", available = false, playstyle = "Seal stacking (Ret)", difficulty = "medium", experimental = true,
      updated = "2026-08-31", phase = "SoD P8", source = "https://onlyfarms.gg/guides/season-of-discovery-paladin-dps-bis-gear-pve-guide/",
      summary = "Twist-like damage with fewer casts; needs Soul of the Sealbearer (or Core Forged 6-set). Experimental.",
      requires = { weapon = "2H", minSpeed = 3.0, souls = { "SOUL_OF_THE_SEALBEARER" } } },
  },
  MAGE = {
    -- Filled by build-catalog-refresh in M5.
  },
}
