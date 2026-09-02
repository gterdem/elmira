-- Data/SoD/Timing.lua — server-side timing constants for the paladin pack.
--
-- These are not spell ids, but hard rule 2's reasoning applies to them exactly: they are numbers the
-- server owns, they change on a tuning pass, and remembering one is not the same as knowing it. Every
-- value here carries its source and the date it was checked, and an unsourced value is simply absent
-- — which leaves the feature that needs it inert rather than mis-timed (docs/02, `seal_linger`).
local ADDON, ns = ...
ns.Data = ns.Data or {}
ns.Data.SoD = ns.Data.SoD or {}

ns.Data.SoD.Timing = {
  -- How long a REPLACED seal can still proc on a swing — the twist window (docs/02 "seal_linger").
  --
  -- PROVENANCE, because this one is weaker than an id from Wowhead and must not be mistaken for it:
  -- Blizzard reintroduced seal twisting as an intentional mechanic in the 2024-04-23 hotfix, but the
  -- note says only that the old seal is "slightly extend[ed] ... for a short time" and gives NO
  -- number. 400 ms is the figure the community and every guide use, and it traces to exactly one
  -- primary artefact: the wowsims/sod simulator's own constant. Two independent readings of that
  -- source agree, and an Icy Veins guide and a published WeakAura both restate 0.4s.
  --
  -- So: sim-derived and community-corroborated, NOT Blizzard-confirmed. It is shipped because the
  -- alternative is leaving twisting permanently inert, and because nothing that ships today reads it
  -- — every build using `seal_linger` is `available = false` until M5d. Re-measure in game before
  -- any twist build goes available; docs/research/seal-twist-window.md carries the measurement
  -- procedure and the open question of whether Seal of Command lingers at all.
  -- src: https://github.com/wowsims/sod/blob/master/sim/paladin/paladin.go  (lingerDuration, read 2026-09-02)
  -- src: https://news.blizzard.com/en-us/world-of-warcraft/24057474/hotfixes-april-23-2024
  sealLingerWindow = 0.4,
}
