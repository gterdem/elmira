-- Elmira/Core/Engine.lua — priority evaluation (docs/01-ARCHITECTURE.md §3).
-- Pure Lua, no WoW globals: dofile-able headlessly.
--
-- One function, no state of its own. The `dirty` flag in docs/01 §7 belongs to M3's update loop, not
-- here — keeping Engine stateless is what lets Simulation call it repeatedly against a virtual state
-- without any reset dance between slots.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Engine = {}

-- An entry is eligible when its compiled predicate passes AND the ability is actually castable.
-- The usable/cooldown checks are deliberately NOT conditions: every entry needs them, and a build
-- author must not be able to forget them (docs/02 "An entry passes when all `when` conditions pass
-- **and** the spell is known/usable and off cooldown").
--
-- ADR-0006 rule 5 is the important subtlety: an ability the character has not learned (un-engraved
-- rune, wrong level) is skipped SILENTLY here. That is normal, not an error — it is what lets one
-- build file be correct across a whole progression path. A key missing from the DATA PACK is the
-- opposite case and was already rejected by Schema.validate at load.
local function eligible(entry, state, t)
  if entry.item ~= nil then
    if not state:itemUsable(entry.item) then return false end
    if state:itemCooldown(entry.item) > 0 then return false end
  else
    if not state:usable(entry.spell) then return false end
    if state:cooldown(entry.spell) > 0 then return false end
  end
  return entry.test == nil or entry.test(state, t) == true
end

Engine.eligible = eligible

-- Engine.pick(build, state, t) -> entry, index
-- Returns the first eligible entry in priority order, or nil when nothing is castable (silenced
-- abilities, everything on cooldown). `t` is the simulated offset; see Core/Schema.lua on what it
-- does and does not affect.
function Engine.pick(build, state, t)
  if not build or not build.entries then return nil end
  t = t or 0
  for i = 1, #build.entries do
    local entry = build.entries[i]
    if eligible(entry, state, t) then return entry, i end
  end
  return nil
end

ns.Engine = Engine
return Engine
