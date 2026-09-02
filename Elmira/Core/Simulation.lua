-- Elmira/Core/Simulation.lua — the depth-N queue (docs/01-ARCHITECTURE.md §3, docs/02 "Simulation
-- semantics"). Pure Lua, no WoW globals: dofile-able headlessly.
--
-- Slot 1 is the live state. Slots 2..N come from a VIRTUAL state: an overlay that answers cooldown
-- and power questions as they would read after the earlier picks have been cast, and delegates
-- everything else to the real state.
--
-- The overlay is a shallow proxy, not a deep clone. docs/01 §7 runs this on every dirty frame at up
-- to 10 Hz, so a per-frame deep copy of the whole state would be the single worst allocation in the
-- addon. Two small tables per queue, reused across slots, is the budget.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

-- Same guard as Core/API.lua:17 and Core/Schema.lua — this file is documented as dofile-able, and the
-- dependency warnings below must not themselves be the thing that crashes a headless load.
ns.log = ns.log or function() end

local Simulation = {}

-- Longer than any queue can simulate, so "suppressed for the rest of this queue" needs no special
-- case in the cooldown arithmetic. Finite rather than math.huge: it is subtracted from, and inf-inf
-- is a NaN that would compare false against every bound.
local QUEUE_HORIZON = 86400

-- Pluggable per docs/01 §3, so M3b can drive the step from LibClassicSwingTimerAPI instead of the
-- GCD. Contract: fn(entry, state, t) -> seconds to advance.
local defaultTimeStep = function(entry, state, _t)
  -- gcdDuration, NOT gcd: the latter is the REMAINING global cooldown and is 0 whenever the player is
  -- not mid-global, which made every simulated slot land at t=0 on a live character. Verified in game
  -- 2026-09-02 (docs/07 §9.15). Falls back to gcd() only for a state predating the contract member.
  local gcd = (state.gcdDuration and state:gcdDuration()) or 0
  if gcd <= 0 then gcd = state:gcd() or 0 end
  local cast = entry.spell and state:castTime(entry.spell) or 0
  return math.max(gcd, cast or 0)
end
local timeStep = defaultTimeStep

function Simulation.setTimeStep(fn)
  timeStep = fn or defaultTimeStep
end

function Simulation.resetTimeStep()
  timeStep = defaultTimeStep
end

-- Findings 1 and 3 of the M1 audit: a missing dependency used to produce either a silently empty
-- queue or a confusing "attempt to call method 'baseCooldown'" on the first delegated call. Both are
-- the M0 LoadWith shape — correct code, never loaded, no complaint. Warn once per dependency: this
-- runs inside the display loop at up to 10 Hz, so an unthrottled message would flood the chat frame
-- and bury the very thing it is trying to report.
local warned = {}
local function requireDep(name, value)
  if value then return true end
  if not warned[name] then
    warned[name] = true
    ns.log("Elmira: rotation queue disabled — %s is not loaded (check Elmira_Vanilla.toc load order).", name)
  end
  return false
end

-- Test seam: the warn-once latch is module state, so a spec covering the warning would otherwise
-- pass or fail depending on which spec ran first.
function Simulation.resetWarnings()
  warned = {}
end

-- The virtual state. `cdOverride` holds remaining cooldown for spells cast earlier in the queue;
-- `spent` accumulates resource cost. Every other member falls through to the real state, which is
-- what keeps `not_moving` and friends reading live values (docs/02: future movement is unknowable).
local function newVirtualState(real)
  local v = { _real = real, cdOverride = {}, itemOverride = {}, spent = {}, elapsed = 0 }

  function v:now() return real:now() + self.elapsed end
  function v:gcd() return real:gcd() end
  function v:gcdDuration()
    return (real.gcdDuration and real:gcdDuration()) or real:gcd() or 0
  end

  -- The virtual state models cooldowns and the resource pool, not auras — so a `no_seal` entry used
  -- to pass in every slot and the queue came back as the same seal five times (docs/07 §9.15).
  -- Seals are the one aura the contract exposes directly, so casting one can be reflected honestly
  -- here rather than by special-casing the entry. Everything else stays as documented: an entry that
  -- depends on an aura it just consumed is still not modelled (see M5d twist/stack).
  function v:seal()
    if self.sealOverride ~= nil then return self.sealOverride end
    return real:seal()
  end

  function v:cooldown(key)
    local override = self.cdOverride[key]
    local base = real:cooldown(key)
    -- Time passing shortens a live cooldown; a spell we simulated casting has its own remaining.
    local live = base - self.elapsed
    if live < 0 then live = 0 end
    if override == nil then return live end
    return math.max(override - self.elapsed, live)
  end

  function v:itemCooldown(slot)
    local override = self.itemOverride[slot]
    local live = real:itemCooldown(slot) - self.elapsed
    if live < 0 then live = 0 end
    if override == nil then return live end
    return math.max(override - self.elapsed, live)
  end

  function v:power(kind)
    local cur, cap = real:power(kind)
    local spent = self.spent[kind] or 0
    local left = (cur or 0) - spent
    if left < 0 then left = 0 end
    return left, cap
  end

  -- M3b. Without this the delegation loop below hands back the LIVE seconds-to-next-swing at every
  -- simulated slot, so a `swing` condition three casts into the future is evaluated against the
  -- present — the same class of error as the cooldown that did not tick down, and just as invisible.
  --
  -- Time passing brings the swing closer. Once the simulated clock passes it, this answers nil: the
  -- State contract has no member for the swing PERIOD, so we genuinely do not know when the one
  -- after it lands, and docs/02 makes nil the honest answer rather than a guess. A twist build is
  -- therefore reachable in slot 1 and in any slot before the swing, and never on invented timing.
  function v:swingRemaining()
    local live = real:swingRemaining()
    if live == nil then return nil end
    local left = live - self.elapsed
    if left < 0 then return nil end
    return left
  end

  -- Everything not overridden above delegates. Written as an explicit loop over the contract rather
  -- than __index so the proxy stays a plain table with plain methods — an __index metatable here
  -- would put a metamethod call on the hot path for every condition evaluated in every slot.
  for _, member in ipairs(ns.Interface and ns.Interface.CONTRACT or {}) do
    if v[member] == nil then
      v[member] = function(_, a, b) return real[member](real, a, b) end
    end
  end
  return v
end

-- Records the effect of casting `entry` at the current virtual time.
local function applyCast(v, entry)
  -- Third argument is the offset into the simulated window. The default step ignores it, but M3b's
  -- swing-timer source needs it to answer "how long until the next auto-attack from HERE", so it is
  -- part of the contract and must actually be passed.
  local step = timeStep(entry, v, v.elapsed) or 0

  if entry.item ~= nil then
    -- Items carry no duration anywhere in the data model — the State contract has itemCooldown() but
    -- only as REMAINING. Rather than invent one, suppress the slot for the rest of the queue: real
    -- trinkets run minutes, the queue spans seconds, and re-listing "use trinket 13" two slots after
    -- the first suggestion is noise the user has to read past either way.
    v.itemOverride[entry.item] = v.elapsed + QUEUE_HORIZON
  else
    -- cooldown() is only ever REMAINING, which is 0 for the spell we just picked, so the duration has
    -- to come from somewhere else or the queue degenerates to one ability repeated. Resolution order:
    --   1. state:baseCooldown() -- the adapter's job (M2). It must be modification-aware: SoD runes
    --      change several spells' cooldowns, and GetSpellBaseCooldown returns the UNMODIFIED value,
    --      so the adapter caches the real `duration` observed from GetSpellCooldown and falls back to
    --      the base only until it has seen the spell cast once.
    --   2. entry.cooldownSecs -- optional Data/ fallback, for anything the client can't answer.
    --   3. one time step -- bounds the degenerate case instead of letting one spell take every slot.
    local nominal = v:baseCooldown(entry.spell)
    if not nominal or nominal <= 0 then nominal = entry.cooldownSecs end
    if not nominal or nominal <= 0 then nominal = step end
    v.cdOverride[entry.spell] = v.elapsed + math.max(nominal, step)

    -- Live cost first, for the same reason as cooldown: SoD runes change some spells' mana cost, and
    -- the client's answer already accounts for the rank the character actually has.
    local amount, kind = v:powerCost(entry.spell)
    if amount and amount > 0 and kind then
      -- Upper-cased for the same reason Schema.compile normalises the Data path: the `resource`
      -- condition reads power("MANA"), so an adapter answering "Mana" would debit a key nothing ever
      -- reads and the pool would silently never drain. The client path takes precedence over Data
      -- now, which makes this the more likely of the two to go wrong.
      kind = string.upper(kind)
      v.spent[kind] = (v.spent[kind] or 0) + amount
    elseif entry.cost then
      for costKind, costAmount in pairs(entry.cost) do
        v.spent[costKind] = (v.spent[costKind] or 0) + costAmount
      end
    end
  end

  -- Casting a seal makes it the active seal, which is what stops a `no_seal` entry from matching
  -- again on the next slot. Detected from the compiled entry's own data, so Simulation stays free of
  -- class knowledge — the data pack is what says a spell is a seal.
  if entry.spell and entry.data and entry.data.seal then
    v.sealOverride = entry.spell
  end

  -- docs/02: an entry may declare `hold = true` to be shown but not consume simulated time (off-GCD
  -- items, burst cooldowns). Without this, one trinket line would push every real ability a slot down.
  if not entry.hold then
    v.elapsed = v.elapsed + step
  end
end

-- Simulation.queue(build, state, depth) -> { {spell=|item=, entry=, t=, cdVolatile=, hold=}, ... }
-- Slot 1 uses live state; later slots use the virtual state at the accumulated offset.
function Simulation.queue(build, state, depth)
  if not build or not build.entries then return {} end
  -- Distinguish "nothing castable" (a legitimate empty queue) from "Core is not wired up".
  if not requireDep("Core/Engine.lua", ns.Engine) then return {} end
  if not requireDep("Adapters/Interface.lua", ns.Interface and ns.Interface.CONTRACT) then return {} end
  local Engine = ns.Engine
  depth = depth or 3
  if depth < 1 then return {} end

  local out = {}
  local first = Engine.pick(build, state, 0)
  if not first then return out end
  out[1] = { spell = first.spell, item = first.item, entry = first, t = 0,
             cdVolatile = first.cdVolatile, hold = first.hold, label = first.label }
  if depth == 1 then return out end

  local v = newVirtualState(state)
  applyCast(v, first)

  for slot = 2, depth do
    local entry = Engine.pick(build, v, v.elapsed)
    if not entry then break end
    out[slot] = { spell = entry.spell, item = entry.item, entry = entry, t = v.elapsed,
                  cdVolatile = entry.cdVolatile, hold = entry.hold, label = entry.label }
    applyCast(v, entry)
  end
  return out
end

-- Exposed for specs. The virtual state is where the simulation's subtle bugs live — a cooldown that
-- did not tick down, a seal that never changed, a swing time frozen at "now" — and each of those was
-- found only after it reached the game. Asserting on it directly is worth one line of surface.
Simulation.newVirtualState = newVirtualState

ns.Simulation = Simulation
return Simulation
