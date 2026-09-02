-- Elmira/Core/Recorder.lua — capture many labelled snapshots in one play session.
--
-- WHY THIS EXISTS. An addon cannot write files; SavedVariables is the only persistence WoW offers and
-- it flushes only on /reload or logout. That one reload is unavoidable. Everything else about the old
-- workflow was not: `/elm debug dump` captured a single snapshot, so testing eight gear states meant
-- eight reloads, or reading the chat frame mid-fight — which truncates, and which the player rightly
-- said is unworkable while actually playing.
--
-- So: record many marks into a ring buffer during play, flush once at the end. The player types two
-- commands and swaps gear; combat and equipment changes mark themselves.
--
-- Pure Lua, no WoW API (hard rule 3). Snapshots arrive through an injected function, and the clock
-- comes from the caller, so this is fully testable headlessly.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Recorder = {}

-- docs/12 budgets SavedVariables size. A trimmed mark is roughly 1-2 KB, so 40 keeps a full test
-- session comfortably under ~80 KB while being far more than any checklist needs. Oldest is dropped
-- rather than refusing to record: losing the start of a long session beats silently stopping.
Recorder.MAX_MARKS = 40

local state = { active = false, marks = {}, dropped = 0, deduped = 0, startedAt = nil, lastKey = nil }

function Recorder.reset()
  state = { active = false, marks = {}, dropped = 0, deduped = 0, startedAt = nil, lastKey = nil }
end

function Recorder.isRecording() return state.active end

function Recorder.start(now)
  state.active = true
  state.startedAt = now
  return true
end

function Recorder.stop()
  state.active = false
  return #state.marks
end

-- `capture` is a function returning the trimmed snapshot for this instant. Called ONLY when
-- recording, so a stopped recorder costs nothing — this can be wired to combat events without
-- paying for a snapshot on every fight.
-- `dedupeKey` is optional and only passed by AUTOMATIC marks. Consecutive auto-marks with the same
-- key are skipped: repeatedly pulling a dummy produced 20+ identical combat-start/combat-end pairs in
-- the first real recording, which filled a 40-slot buffer with noise and would have evicted the gear
-- states the test actually compares. A manual `/elm rec mark` passes no key and is never skipped —
-- if the player deliberately marked something, it is wanted.
function Recorder.mark(label, now, capture, dedupeKey)
  if not state.active then return false, "not recording" end
  if type(capture) ~= "function" then return false, "no capture function" end
  if dedupeKey ~= nil and state.lastKey ~= nil and dedupeKey == state.lastKey then
    state.deduped = (state.deduped or 0) + 1
    return false, "unchanged since last mark"
  end

  local snapshot = capture()
  if snapshot == nil then return false, "capture returned nothing" end
  state.lastKey = dedupeKey

  snapshot.label = label or "mark"
  snapshot.at = now
  snapshot.elapsed = (now and state.startedAt) and (now - state.startedAt) or nil

  state.marks[#state.marks + 1] = snapshot
  while #state.marks > Recorder.MAX_MARKS do
    table.remove(state.marks, 1)
    state.dropped = state.dropped + 1
  end
  return true
end

-- Marks are returned in order with their labels, so the reader can tell "4/9 T3" from "3/9 T3"
-- without correlating timestamps by hand.
function Recorder.marks() return state.marks end
function Recorder.count() return #state.marks end
function Recorder.dropped() return state.dropped end
function Recorder.deduped() return state.deduped or 0 end

function Recorder.clear()
  state.marks = {}
  state.dropped = 0
  state.deduped = 0
  state.lastKey = nil
end

-- What goes to SavedVariables. Includes `dropped` so a truncated session says so rather than looking
-- like a short one — a silently shortened record is the same failure shape as a silently empty queue.
function Recorder.payload()
  return {
    startedAt = state.startedAt,
    recording = state.active,
    dropped = state.dropped,
    deduped = state.deduped or 0,
    count = #state.marks,
    marks = state.marks,
  }
end

function Recorder.status()
  if not state.active then
    if #state.marks == 0 then return "not recording, nothing captured" end
    return string.format("stopped, %d mark(s) held%s — /reload to write them out",
      #state.marks, state.dropped > 0 and string.format(" (%d dropped)", state.dropped) or "")
  end
  return string.format("RECORDING, %d mark(s) so far%s", #state.marks,
    state.dropped > 0 and string.format(" (%d dropped, oldest first)", state.dropped) or "")
end

ns.Recorder = Recorder
return Recorder
