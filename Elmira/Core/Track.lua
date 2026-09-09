-- Elmira/Core/Track.lua — the per-ability event tracker (AB1-D5).
--
-- PURE (hard rule 3): reads nothing but the three State members it is handed --
-- `cooldown`, `usable` and `buff` (docs/01 §2) -- so the whole of it is drivable from a fake state.
--
-- EVERY TRANSITION IS AN EDGE. A cooldown that has been at zero for a minute is "ready" on every
-- one of the six hundred ticks it sat there, and a cue that fires on all of them is a strobe -- the
-- same failure ADR-0009 describes for the screen edge. So this compares against what it saw last
-- time and reports only the crossings: a spell coming off cooldown fires `ready` ONCE, and fires it
-- again only after going back on cooldown.
--
-- `suggested` and `used` are not produced here: neither is a fact about the character's state.
-- Display/Driver emits them from the now-slot it has already computed and from the cast it already
-- watches for, which is why this file needs no queue and no combat log.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Track = {}

-- Track.tick(state, watched, prev) -> events, prev
--
-- `watched` is `[{ key = <spell key>, expiring = <seconds> }]` -- the caller decides which abilities
-- are worth polling and how short "about to run out" is for each, because both come from settings
-- this file must not know about.
--
-- `prev` is whatever the last call returned; nil on the first tick, which is what makes the first
-- reading a first sighting rather than a flood of edges for everything that happens to be ready.
-- The returned table REPLACES it -- an ability that has left the watched set leaves no memory
-- behind, so re-adding it later starts clean instead of resuming a stale comparison.
--
-- AB4-D1: each row of the returned memory also carries the NUMBERS behind the three booleans --
-- `cooldown`/`cooldownFull` and `remaining`/`duration`. The progress fill on an indicator texture
-- needs how much is left AND how long the whole thing lasts, and every one of those four readings
-- was already being taken here to decide `ready`, `active` and `expiring`. Reporting them costs
-- one extra state call (`baseCooldown`, and only while the ability is actually on cooldown) and
-- saves Display a second pass over the same abilities at 10 Hz.
function Track.tick(state, watched, prev)
  local events, now = {}, {}
  if not state then return events, now end
  for _, row in ipairs(watched or {}) do
    local key = row.key
    local was = prev and prev[key]
    -- Ready is BOTH halves: off cooldown and castable. A spell whose cooldown has finished while
    -- you cannot afford it is not something to tell anyone about.
    local cooldown = state:cooldown(key) or 0
    local ready = cooldown <= 0 and state:usable(key) == true
    -- How long this cooldown LASTS, asked for only while one is running: `baseCooldown` is an
    -- observe-and-cache reading (docs/07 §9.1 -- GetSpellBaseCooldown lies on this client), so off
    -- cooldown it answers with whatever was last seen, which is not a fact about now.
    local cooldownFull = cooldown > 0 and (state:baseCooldown(key) or 0) or nil
    -- `stacks` rather than the remaining seconds decides "is it up": an aura with no expiry reads
    -- zero seconds remaining, and treating that as "not up" would silence every permanent buff.
    local stacks, remaining, duration = state:buff(key)
    local active = stacks ~= nil
    local expiring = active and (remaining or 0) > 0 and (remaining or 0) <= (row.expiring or 3)
    if ready and not (was and was.ready) then events[#events + 1] = { key = key, event = "ready" } end
    if active and not (was and was.active) then events[#events + 1] = { key = key, event = "active" } end
    if expiring and not (was and was.expiring) then
      events[#events + 1] = { key = key, event = "expiring" }
    end
    now[key] = { ready = ready, active = active, expiring = expiring,
                 cooldown = cooldown, cooldownFull = cooldownFull,
                 remaining = active and remaining or nil, duration = active and duration or nil }
  end
  return events, now
end

ns.Track = Track
return Track
