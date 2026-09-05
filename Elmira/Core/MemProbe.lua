-- Elmira/Core/MemProbe.lua — "is the memory growth ours?", measured instead of argued.
--
-- The client reports one number for Elmira and it only ever goes up. That number cannot tell a leak
-- from churn, and it cannot tell OUR allocations from those of the shared libraries we happen to
-- own (see Adapters/LibOwner.lua). Reading the code cannot either: the headless benchmark says the
-- render loop allocates ~0.016 KB per frame and retains nothing across 75 000 ticks, while the
-- client reports ~70 KB/s -- and the growth tracks wall-clock seconds, not our tick rate.
--
-- So this measures the one thing that separates the two: it samples Elmira's memory for a window
-- with the display RUNNING, then for an equal window with our OnUpdate SUSPENDED. If the two rates
-- match, nothing in the render loop is responsible and optimising it is wasted work. If they
-- diverge, the difference is exactly the budget worth attacking.
--
-- PURE (hard rule 3): no WoW API, no frames, no clock. Time, the memory reading, the scheduler and
-- the suspend/resume pair all arrive as functions, which is what lets the whole A/B run be driven
-- from a spec with a fake scheduler instead of by staring at a memory readout for forty seconds.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local MemProbe = {}
MemProbe.__index = MemProbe

-- Long enough that one garbage collection inside a window does not dominate it, short enough that
-- nobody has to stand still for a minute. Two of these run back to back.
MemProbe.PHASE_SECONDS = 20
-- Sampling is the whole measurement: a single before/after pair is destroyed by one collection,
-- while a step every two seconds recovers from it (see :add).
MemProbe.INTERVAL = 2

function MemProbe.newWindow()
  return setmetatable({ allocated = 0, collections = 0, samples = 0 }, MemProbe)
end

-- One reading. Sums the POSITIVE steps only.
--
-- A negative step is a garbage collection, not negative allocation: the memory that was allocated
-- before it is real and already counted, so the step is dropped rather than subtracted. Subtracting
-- it would make a busy window with one collection in it report less growth than an idle one, which
-- is the exact inverse of the truth. The collections are counted separately because a window full
-- of them is a window whose total is a floor, not a measurement, and the report has to say so.
function MemProbe:add(t, kb)
  if type(t) ~= "number" or type(kb) ~= "number" then return false end
  self.samples = self.samples + 1
  if self.lastKB then
    local step = kb - self.lastKB
    if step >= 0 then
      self.allocated = self.allocated + step
    else
      self.collections = self.collections + 1
    end
  else
    self.startedAt = t
  end
  self.lastKB, self.endedAt = kb, t
  return true
end

function MemProbe:elapsed()
  if not (self.startedAt and self.endedAt) then return 0 end
  local d = self.endedAt - self.startedAt
  return d > 0 and d or 0
end

-- KB per second, or nil when the window is too short to divide by. nil rather than 0: "we did not
-- measure" and "it allocated nothing" are different answers and must not print the same.
function MemProbe:rate()
  local seconds = self:elapsed()
  if seconds <= 0 then return nil end
  return self.allocated / seconds
end

-- How much of the growth the render loop accounts for, as a fraction of the running window. Only
-- meaningful when both windows produced a rate.
local function share(running, suspended)
  local a, b = running:rate(), suspended:rate()
  if not (a and b) or a <= 0 then return nil end
  return (a - b) / a
end
MemProbe.share = share

-- PURE. The verdict, as chat lines. Kept apart from the run so the wording is testable without a
-- forty-second timer, and so the numbers reach the report by exactly one path.
--
-- `owned` is the count from Adapters/LibOwner.lua, or nil when it could not be established: a
-- measurement that clears the display and still shows the same growth needs the ownership answer
-- beside it, or the reader is left with "not us" and nowhere to go next.
function MemProbe.summarise(running, suspended, owned, phaseRows)
  local lines = {}
  local a, b = running:rate(), suspended:rate()
  lines[#lines + 1] = string.format(
    "display RUNNING:   %s over %.0fs, %d samples, %d collection(s)",
    a and string.format("%.1f KB/s", a) or "not measurable", running:elapsed(),
    running.samples, running.collections)
  lines[#lines + 1] = string.format(
    "display SUSPENDED: %s over %.0fs, %d samples, %d collection(s)",
    b and string.format("%.1f KB/s", b) or "not measurable", suspended:elapsed(),
    suspended.samples, suspended.collections)

  for _, line in ipairs(MemProbe.phaseLines(phaseRows, running:elapsed())) do
    lines[#lines + 1] = line
  end

  local s = share(running, suspended)
  if not s then
    lines[#lines + 1] = "verdict: not enough readings to compare. Stand still, out of combat, and retry."
  elseif s < 0.25 then
    lines[#lines + 1] = string.format(
      "verdict: suspending Elmira's display changed the rate by %.0f%%. The growth is NOT the render loop.",
      s * 100)
  else
    lines[#lines + 1] = string.format(
      "verdict: the render loop accounts for %.0f%% of the growth (%.1f KB/s of it).",
      s * 100, (a or 0) - (b or 0))
  end

  if owned == nil then
    lines[#lines + 1] = "shared libraries: could not tell which copies are ours (/elm debug libs)"
  elseif owned > 0 then
    lines[#lines + 1] = string.format(
      "shared libraries: %d of the libraries Elmira embeds are the copy the WHOLE UI is using, so", owned)
    lines[#lines + 1] = "  every other addon's use of them is billed to this figure. /elm debug libs"
  else
    lines[#lines + 1] = "shared libraries: none of Elmira's copies won LibStub, so this figure is ours alone."
  end
  return lines
end

-- ---------------------------------------------------------------- phase accounting
--
-- Knowing the render loop owns 111 KB/s is not the same as knowing WHICH PART of it does, and the
-- difference decides what gets rewritten. So while a measurement is running, the loop reports what
-- each phase allocated: reading the visibility, compiling/resolving the build, simulating the
-- queue, and each renderer by name.
--
-- OFF unless a run is in flight. `enter()` answers nil in one comparison and allocates nothing, so
-- an idle client pays a nil check per recompute -- about four a second -- and no more. `phases`
-- being nil IS the off switch, so `stop()` clearing it is what keeps a finished (or crashed) run
-- from leaving two heap reads per phase in the loop for the rest of the session.
local phases = nil -- mutants: equivalent deletion only makes it a global

-- The heap in KB, or nil when nothing is profiling. `collectgarbage("count")` is stock Lua, not the
-- WoW API, so this stays inside hard rule 3 -- Core/Slash.lua already reads it the same way.
function MemProbe.enter()
  if not phases then return nil end
  return collectgarbage("count")
end

-- Closes a phase opened by `enter`. Positive steps only, for the same reason `add` sums them: a
-- collection landing inside a phase is not that phase allocating a negative amount.
function MemProbe.leave(name, before)
  if not (phases and before) then return false end
  local step = collectgarbage("count") - before
  local row = phases.byName[name]
  if not row then
    row = { name = name, kb = 0, calls = 0 }
    phases.byName[name] = row
    phases.order[#phases.order + 1] = row
  end
  row.calls = row.calls + 1
  if step > 0 then row.kb = row.kb + step end
  return true
end

function MemProbe.startPhases()
  phases = { byName = {}, order = {} }
  return true -- mutants: equivalent nil is falsy and no caller uses this as anything but a call
end

-- Returns the rows, heaviest first, and switches accounting off. Ties break on name so a report
-- taken twice in one session cannot come back in two different orders.
function MemProbe.stopPhases()
  local held = phases
  phases = nil
  if not held then return {} end
  table.sort(held.order, function(x, y)
    if x.kb ~= y.kb then return x.kb > y.kb end
    return x.name < y.name
  end)
  return held.order
end

function MemProbe.isProfiling()
  return phases ~= nil
end

-- PURE. The per-phase breakdown as chat lines. Only phases that actually ran are listed: a report
-- padded with "render:overlay 0.0 KB" for a renderer nobody has switched on reads as though the
-- measurement covered it, and it did not.
function MemProbe.phaseLines(rows, seconds)
  local lines = {}
  if not (rows and #rows > 0) then return lines end
  lines[#lines + 1] = "where it went, while the display was running:"
  for _, row in ipairs(rows) do
    lines[#lines + 1] = string.format("  %-22s %7.1f KB/s over %d call(s), %.2f KB each",
      row.name,
      (seconds and seconds > 0) and (row.kb / seconds) or 0,
      row.calls,
      row.calls > 0 and (row.kb / row.calls) or 0)
  end
  return lines
end

-- MemProbe.run(opts) -> true | false, reason
--
-- opts.now()          seconds, monotonic
-- opts.readKB()       Elmira's memory in KB, or nil when the client will not say
-- opts.schedule(s,fn) call fn in s seconds
-- opts.suspend()      stop our OnUpdate
-- opts.resume()       start it again
-- opts.report(lines)  called once, with the finished summary
-- opts.owned          library-ownership count for the report, or nil
--
-- One at a time: a second run would suspend the display underneath the first one's second window
-- and both would measure the same thing wrongly.
function MemProbe.run(opts)
  if MemProbe.active then return false, "a measurement is already running" end
  if not (opts and opts.now and opts.readKB and opts.schedule and opts.suspend
          and opts.resume and opts.report) then
    return false, "incomplete probe wiring"
  end
  if opts.readKB() == nil then
    return false, "this client does not report per-addon memory"
  end

  local seconds = opts.seconds or MemProbe.PHASE_SECONDS
  local interval = opts.interval or MemProbe.INTERVAL
  local running, suspended = MemProbe.newWindow(), MemProbe.newWindow()
  MemProbe.active = { running = running, suspended = suspended }

  -- ONE exit, and it always resumes. Every step of this run is a scheduled callback, so an error
  -- inside any of them breaks the chain: the second window never ends, `resume` is never called,
  -- and the player is left looking at a dark display with no idea why until they reload. A command
  -- that deliberately hides the display for twenty seconds must not be able to fail that way, and
  -- "the display silently stopped" is this codebase's characteristic bug.
  local function stop(lines)
    MemProbe.active = nil
    -- Unconditional, on every exit including the failed ones: accounting left switched on costs
    -- two heap reads per phase in the render loop for the rest of the session, and nothing would
    -- ever say so.
    MemProbe.stopPhases()
    pcall(opts.resume)
    opts.report(lines)
  end

  -- Anything that can throw goes through here, and a failure ENDS the run with a sentence saying
  -- so rather than by disappearing -- a swallowed error would leave the command looking like it is
  -- still measuring, forever. Returning false is what stops the walk below from scheduling the next
  -- step, so a dead run schedules nothing and cannot reach `stop` a second time.
  local function guarded(fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return true end
    stop({ string.format("memory: the measurement stopped early (%s). The display is back.",
                         tostring(err)) })
    return false -- mutants: equivalent nil is falsy and both callers use this only as a condition
  end

  local function sample(window)
    return guarded(function()
      local kb = opts.readKB()
      if kb then window:add(opts.now(), kb) end
    end)
  end

  -- Samples now, then every `interval` until the window is spent. Recursive rather than a repeating
  -- timer so the last sample and the phase change happen in that order, on the same tick: a
  -- repeating timer cancelled from outside can fire once more after the phase has moved on, and
  -- that stray sample lands in the wrong window.
  local function walk(window, remaining, done)
    if not sample(window) then return end
    if remaining <= 0 then return done() end
    opts.schedule(interval, function() walk(window, remaining - interval, done) end)
  end

  MemProbe.startPhases()
  walk(running, seconds, function()
    -- Phases close WITH the running window: the suspended one has no ticks in it by construction,
    -- so leaving accounting on would only add its own cost to a window whose whole purpose is to
    -- show what the loop costs when it is not running.
    local rows = MemProbe.stopPhases()
    if not guarded(opts.suspend) then return end
    walk(suspended, seconds, function()
      stop(MemProbe.summarise(running, suspended, opts.owned, rows))
    end)
  end)
  return true
end

-- Is a measurement in flight? `/elm debug memory` reports it rather than silently doing nothing,
-- and the display must not be re-enabled underneath a suspended window.
function MemProbe.isRunning()
  return MemProbe.active ~= nil
end

-- ---------------------------------------------------------------- per-accessor attribution
--
-- The phase breakdown says `simulate` allocated N KB; it cannot say which question the simulation
-- asked cost it. Round 4 of the memory hunt left 9.76 KB per recompute that the headless stack
-- did not reproduce, and reading the code could not place it (the lesson of every earlier round).
-- So this charges one run to the State accessors that ran inside it: every named member of `state`
-- is wrapped, each call's heap step lands under its name, and whatever is left is the simulation's
-- own. Nested reads (bonus() asking setCount()) count under both names; the rows locate, they do
-- not sum.
--
-- PURE: `state` and `run` are whatever the caller hands in, and the members are restored on every
-- exit -- including a throw, or the live state would be left wrapped for the rest of the session.
--
-- `collector` is `collectgarbage` unless a spec injects one: stopping the collector for the span is
-- what makes the numbers mean anything, and the only way a test can prove it was stopped -- and
-- restarted, on the error path too -- is to watch the calls.
function MemProbe.attribute(state, members, run, collector)
  if type(state) ~= "table" or type(members) ~= "table" or type(run) ~= "function" then
    return nil, "incomplete attribution wiring"
  end
  local gc = collector or collectgarbage
  local rows, originals = {}, {}
  for _, member in ipairs(members) do
    local fn = state[member]
    if type(fn) == "function" then
      local row = { name = member, kb = 0, calls = 0 }
      rows[#rows + 1] = row
      originals[member] = fn
      -- Three returns cover the widest member (buff: count, remaining, duration). No varargs: a
      -- vararg wrapper allocates on every call and would charge its own cost to the accessor.
      state[member] = function(self, a, b)
        local before = gc("count")
        local r1, r2, r3 = fn(self, a, b)
        local step = gc("count") - before
        row.calls = row.calls + 1
        if step > 0 then row.kb = row.kb + step end
        return r1, r2, r3
      end
    end
  end
  gc("stop")
  local before = gc("count")
  local ok, err = pcall(run)
  local total = gc("count") - before
  gc("restart")
  for member, fn in pairs(originals) do state[member] = fn end
  if not ok then return nil, tostring(err) end

  local attributed = 0
  for _, row in ipairs(rows) do attributed = attributed + row.kb end
  -- Heaviest first, ties by name, so two readings of the same state print in the same order.
  table.sort(rows, function(x, y)
    if x.kb ~= y.kb then return x.kb > y.kb end
    return x.name < y.name
  end)
  return { rows = rows, total = total, attributed = attributed, unattributed = total - attributed }
end

-- PURE. The attribution as chat lines. Members that never ran are not listed, for the same reason
-- phaseLines omits idle renderers; members that ran and allocated nothing are, because "asked 40
-- times, free" is the answer the reader is looking for as much as the expensive row is.
function MemProbe.attributionLines(result, key, depth)
  local lines = {}
  if not result then return lines end
  lines[#lines + 1] = string.format("one recompute of %s at depth %d allocated %.2f KB:",
    tostring(key), depth or 0, result.total)
  for _, row in ipairs(result.rows) do
    if row.calls > 0 then
      lines[#lines + 1] = string.format("  %-16s %7.2f KB over %3d call(s), %.3f KB each",
        row.name, row.kb, row.calls, row.kb / row.calls)
    end
  end
  lines[#lines + 1] = string.format("  %-16s %7.2f KB  (the simulation's own: virtual state, queue slots, Engine)",
    "unattributed", result.unattributed)
  return lines
end

ns.MemProbe = MemProbe
return MemProbe
