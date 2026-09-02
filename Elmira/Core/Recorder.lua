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

-- MEASURED, not guessed: a mark carrying the real Exodin build (14 entries, 4 tracked buffs)
-- serializes to ~3.6 KB, so 120 marks is ~425 KB and a full cast log adds ~80 KB. That is a large
-- SavedVariables file but a bounded one, and it only fills when the player explicitly runs
-- `/elm rec start`. It will grow as more builds register per pack -- re-measure then rather than
-- trusting this line. (An earlier version of this comment claimed "2-3 KB" from no measurement at
-- all, which is how MAX_MARKS came to be chosen against a number that was never checked.)
--
-- 40 was sized for a gear-swap test of a dozen marks; sampling every few seconds through four fights
-- overran it and dropped 76 of 116, keeping only the tail. Oldest is still dropped rather than
-- refusing to record: losing the start of a long session beats silently stopping.
Recorder.MAX_MARKS = 120

-- A cast row is five short fields, far cheaper than a mark, and one arrives per GCD at most.
Recorder.MAX_CASTS = 600

local function newState()
  return { active = false, marks = {}, dropped = 0, deduped = 0, startedAt = nil, lastKey = nil,
           casts = {}, castsDropped = 0 }
end

local state = newState()

function Recorder.reset() state = newState() end

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

-- WHAT THE PLAYER ACTUALLY PRESSED, next to what Elmira was suggesting at that moment.
--
-- This is the only way to answer "is the rotation right?" before Display/ exists (M3). The question
-- was asked of the player twice and could not be answered either time: there is nothing on screen to
-- judge, and slash commands cannot be typed mid-fight. Both constraints are structural, so the
-- evidence has to be passive. `suggested` is sampled shortly BEFORE the cast, not read at cast time
-- -- see Core/Init.lua -- and `age` says how stale it was, so a correlation made offline can discard
-- rows where the suggestion had gone cold.
function Recorder.cast(row)
  if not state.active then return false, "not recording" end
  if type(row) ~= "table" then return false, "cast row must be a table" end
  state.casts[#state.casts + 1] = row
  while #state.casts > Recorder.MAX_CASTS do
    table.remove(state.casts, 1)
    state.castsDropped = state.castsDropped + 1
  end
  return true
end

function Recorder.casts() return state.casts end
function Recorder.castCount() return #state.casts end
function Recorder.count() return #state.marks end
function Recorder.dropped() return state.dropped end
function Recorder.deduped() return state.deduped or 0 end

function Recorder.clear()
  state.marks = {}
  state.dropped = 0
  state.deduped = 0
  state.lastKey = nil
  state.casts = {}
  state.castsDropped = 0
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
    casts = state.casts,
    castsDropped = state.castsDropped,
  }
end

function Recorder.status()
  if not state.active then
    if #state.marks == 0 then return "not recording, nothing captured" end
    return string.format("stopped, %d mark(s) held%s — /reload to write them out",
      #state.marks, state.dropped > 0 and string.format(" (%d dropped)", state.dropped) or "")
  end
  return string.format("RECORDING, %d mark(s) and %d cast(s) so far%s", #state.marks, #state.casts,
    state.dropped > 0 and string.format(" (%d dropped, oldest first)", state.dropped) or "")
end

-- PURE. The fingerprint that decides whether an automatic mark carries new information. It lived in
-- Core/Init.lua, which no spec loads (it needs AceAddon), so breaking it was provably invisible —
-- removing combat state from it changed no test. Anything worth getting right belongs somewhere a
-- test can reach.
function Recorder.fingerprint(mark)
  if type(mark) ~= "table" then return nil end
  local parts = {
    tostring(mark.inCombat),
    tostring(mark.soul),
    mark.weapon and tostring(mark.weapon.itemID) or "-",
  }
  local keys = {}
  for key in pairs(mark.sets or {}) do keys[#keys + 1] = key end
  table.sort(keys) -- pairs() order is undefined; an unsorted key list would make the fingerprint
                   -- unstable and defeat the dedupe at random.
  for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. tostring(mark.sets[key]) end
  return table.concat(parts, "|")
end

ns.Recorder = Recorder
return Recorder
