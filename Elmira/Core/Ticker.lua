-- Elmira/Core/Ticker.lua — when should the queue be recomputed?
--
-- docs/01 §7 specified this loop from the start and nothing ever implemented it: everything up to M2
-- computed a queue on demand, from a slash command or a recorder mark. M3's display needs it running
-- continuously, and "continuously" is the expensive word — a rotation display that recomputes on
-- every frame is the reason people uninstall rotation displays.
--
-- PURE (hard rule 3): no WoW API, no frames, no GetTime. Time arrives as an argument. Display/Driver
-- owns the OnUpdate frame and the events; this file owns only the decision, so the throttle can be
-- tested headlessly instead of by staring at a framerate counter.
--
-- The policy, from docs/01 §7:
--   * an event marks the state dirty (a cooldown finished, an aura changed, the target changed)
--   * a dirty ticker recomputes at the next tick, capped at MAX_RATE
--   * a clean ticker still recomputes after IDLE_REFRESH, because not everything fires an event —
--     a cooldown ticking down to ready has no event of its own, it just becomes true one frame
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Ticker = {}
Ticker.__index = Ticker

-- 10 Hz. The GCD is 1.5 s, so a suggestion that lands within 100 ms is indistinguishable from one
-- that lands instantly, and the difference between 10 Hz and 60 Hz here is six times the cost for
-- nothing a player can perceive.
Ticker.MAX_RATE = 0.1
-- Longest a clean ticker may coast. Deliberately larger than MAX_RATE: this is the backstop for
-- state that changes without an event, not the main path.
Ticker.IDLE_REFRESH = 0.25

function Ticker.new(maxRate, idleRefresh)
  return setmetatable({
    maxRate = maxRate or Ticker.MAX_RATE,
    idleRefresh = idleRefresh or Ticker.IDLE_REFRESH,
    dirty = true,      -- first tick always runs: there is no previous queue to keep showing
    lastRun = nil,
    runs = 0,
    skipped = 0,
  }, Ticker)
end

-- Something changed. Cheap on purpose — this is called from every event handler and must stay a
-- flag set, never a recompute, or the throttle is bypassed by whatever fires most often.
function Ticker:markDirty()
  self.dirty = true
end

-- Should the caller recompute at `now`? Records its own accounting so `/elm debug perf` can report
-- how much work was avoided rather than asserting that some was.
function Ticker:shouldRun(now)
  if type(now) ~= "number" then return false end
  local since = self.lastRun and (now - self.lastRun) or nil

  -- A clock that jumped backwards (a /reload, a timer reset) would otherwise wedge the ticker until
  -- real time caught up. Treat it as "run now" rather than trying to reason about it.
  if since and since < 0 then since = nil end

  if since ~= nil and since < self.maxRate then
    self.skipped = self.skipped + 1
    return false
  end
  if not self.dirty and since ~= nil and since < self.idleRefresh then
    self.skipped = self.skipped + 1
    return false
  end

  self.dirty = false
  self.lastRun = now
  self.runs = self.runs + 1
  return true
end

function Ticker:stats()
  return { runs = self.runs, skipped = self.skipped, dirty = self.dirty, lastRun = self.lastRun }
end

function Ticker:resetStats()
  self.runs, self.skipped = 0, 0
end

-- PURE. Did the queue actually change? docs/01 §7: "No allocations in `render` for unchanged
-- queues (compare spell IDs slot-wise)". Deciding to run is only half the throttle — a rotation
-- holds the same top few suggestions for whole seconds at a time, so most ticks recompute an
-- identical queue, and re-rendering it would rebuild textures and strings ten times a second for no
-- visible change. Compares by value and allocates nothing itself.
function Ticker.queuesDiffer(a, b)
  if a == b then return false end
  if a == nil or b == nil then return true end
  if #a ~= #b then return true end
  for i = 1, #a do
    local x, y = a[i], b[i]
    if x == nil or y == nil then return true end
    -- `label` matters as well as `spell`: three entries can produce JUDGEMENT, and the hover-"why"
    -- and any reason text differ between them even when the icon does not.
    if x.spell ~= y.spell or x.item ~= y.item or x.label ~= y.label then return true end
  end
  return false
end

ns.Ticker = Ticker
return Ticker
