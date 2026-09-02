-- Paladin Exodin (fast 2H, single seal). Source: Wowhead SoD Paladin DPS Rotation (dossier S1), upd. 2025-06-06.
-- Authored per ADR-0006: BASELINE (no sets, no runes, blues) + GATED UPGRADES the addon switches on when detected.
-- Unknown spells (un-engraved runes) are skipped by the engine automatically.
local ADDON, ns = ...
ns.Data.SoD.Builds = ns.Data.SoD.Builds or {}
ns.Data.SoD.Builds.PALADIN_EXODIN = {
  schema = 1, key = "PALADIN_EXODIN", name = "Paladin — Exodin (fast 2H)", class = "PALADIN", flavor = "SoD",
  notes = "Seal of Martyrdom only. Exorcism is the core button and is never held. Gear-dependent lines switch on when detected.",
  -- Advisory only: the wizard warns about these; evaluation never depends on them.
  requires = { weapon = "2H", maxSpeed = 3.0, runes = { "RUNE_ART_OF_WAR", "RUNE_CRUSADER_STRIKE", "RUNE_DIVINE_STORM", "RUNE_PURIFYING_POWER" } },
  -- Suggested PERIPHERAL cues, not a colour table for every spell. The overlay is off by default and
  -- opted into per cue (docs/01 "Overlay.lua", PRD F16); the wizard offers this list as "recommended
  -- peripheral cues" with one-click enable and never turns any of it on by itself. Deliberately short:
  -- these are the moments worth pulling the eye back from a boss, and a longer list trains the user to
  -- ignore the screen edge. Every other spell in the rotation is served by the queue strip and the
  -- bar glow, which is why Crusader Strike and Judgement are absent here.
  visuals = {
    cues = {
      -- Exorcism is the core button and its cooldown is rune-shortened, so the reset is the single
      -- most valuable thing to notice while looking away.
      { event = "now_slot", spell = "EXORCISM", color = {0.9,0.2,0.2}, edge = "left",
        reason = "Exorcism came off cooldown" },
      -- Readiness event, not a now-slot change: the most expensive miss in the rotation, and it is
      -- invisible until damage has already been lost. Also appears in the readiness row.
      -- INERT UNTIL M5b: Overlay ships at M3, Core/Checks.lua at M5b. The wizard lists this as
      -- unavailable until then rather than offering an opt-in that could never fire (ADR-0009).
      { event = "check", key = "SEAL_DROPPED", color = {1.0,1.0,1.0}, edge = "bottom",
        reason = "Seal dropped", peripheral = true },
      -- Only meaningful with the T3.5 4-set, which is what makes Divine Storm consume Holy Power;
      -- the wizard hides a cue whose gating bonus the character does not have.
      { event = "now_slot", spell = "DIVINE_STORM", color = {0.3,0.6,1.0}, edge = "right",
        requiresBonus = "HOLY_POWER_CONSUME", reason = "Divine Storm at 3 Holy Power" },
    },
  },
  entries = {
    ---------------------------------------------------------------- always
    { spell = "SEAL_OF_MARTYRDOM", when = { {"no_seal"} }, label = "Seal up" },

    ---------------------------------------------------------------- burst cooldowns (gear-aware)
    -- With T3.5 2-set: wait for 3 Holy Power. Without it: use on Vengeance as soon as ready.
    { spell = "AVENGING_WRATH", hold = true, label = "Burst",
      when = { {"buff","VENGEANCE_BUFF"},
               {"any", {"buff","HOLY_POWER_BUFF", min = 3}, {"not", {"set","PALADIN_T35_INQUISITION", min = 2}}} } },
    { spell = "AURA_MASTERY", hold = true, label = "with AW", when = { {"buff","AVENGING_WRATH_BUFF"} } },

    ---------------------------------------------------------------- Judgement (gear-aware)
    -- UPGRADE: T2 Draconic 2-set -> Judgement never consumes the seal -> on cooldown.
    { spell = "JUDGEMENT", label = "Draconic 2p", when = { {"bonus","JUDGEMENT_NO_CONSUME"} } },
    -- BASELINE: judge only when the seal is about to expire, then reseal (next slot shows Seal up).
    { spell = "JUDGEMENT", label = "Seal expiring", when = { {"seal","SEAL_OF_MARTYRDOM"}, {"buff","SEAL_OF_MARTYRDOM", maxRemaining = 3} } },

    ---------------------------------------------------------------- UPGRADE: T3.5 4-set consumes Holy Power
    { spell = "DIVINE_STORM", label = "3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"bonus","HOLY_POWER_CONSUME"} } },

    ---------------------------------------------------------------- BASELINE core (valid with zero sets)
    { spell = "EXORCISM" },          -- baseline ability in P8; never held
    { spell = "CRUSADER_STRIKE" },   -- rune; skipped if not engraved

    ---------------------------------------------------------------- UPGRADE: Naxx — T3 Redemption 4-set makes Holy Wrath instant/short CD
    { spell = "HOLY_WRATH", label = "Naxx", when = { {"bonus","HOLY_WRATH_INSTANT"}, {"any", {"target_type","Undead","Demon"}, {"rune","RUNE_PURIFYING_POWER"}} } },

    { spell = "DIVINE_STORM" },      -- rune; below CS by default (fast weapon)

    ---------------------------------------------------------------- AoE helper only when Holy Power exists
    { spell = "CONSECRATION", label = "AoE, 3 HP", when = { {"buff","HOLY_POWER_BUFF", min = 3}, {"cooldown_gt","DIVINE_STORM", 1} } },

    ---------------------------------------------------------------- BASELINE filler
    { spell = "CONSECRATION", when = { {"resource","MANA", minPct = 40} } },
    { item  = 13, hold = true, label = "Trinket", when = { {"item_ready", 13} } },
    { item  = 14, hold = true, label = "Trinket", when = { {"item_ready", 14} } },
  },
}
