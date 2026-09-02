-- Elmira/Setup/Detect.lua — what is this character, right now? (docs/01 §5b, PRD F12/F14)
--
-- Reads the State and the adapter's extras; names no WoW global itself (hard rule 3 is about Core,
-- but keeping the client reads in Adapters/ is what makes this file testable at all). The result is
-- a plain `Detection` record that the wizard renders, `Core/Profiles.lua` matches rules against, and
-- the requirement check compares to a build's `requires`.
--
-- Everything here can legitimately be UNKNOWN. Soul detection is a tooltip scan, base weapon speed
-- is a tooltip scan, talents are a heuristic, and runes need the engraving API. A field that could
-- not be read is `nil`, never a plausible default — the whole point of this record is that the
-- wizard can say "I could not tell" instead of guessing wrong on the user's behalf.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Detect = {}

-- Weapon slots. Named here rather than in Core because Setup is allowed to know about inventory
-- layout; Core never sees these numbers.
local MAINHAND, OFFHAND, SHOULDER = 16, 17, 3

local function safe(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, value = pcall(fn, ...)
  if not ok then return nil end
  return value
end

-- Detect.gather(state, adapter, pack) -> Detection
--
-- `pack` supplies the rune keys worth asking about: `state:rune(key)` answers per key and there is no
-- enumerate-all, so the set of runes we can report is exactly the set the class pack knows. A rune
-- the pack has never heard of is invisible here, which is a real limit and the reason
-- docs/07 §9.5's three observed-but-unstaged runes had to be added to Spells.lua.
function Detect.gather(state, adapter, pack)
  local d = { runes = {}, sets = {} }
  if not state then return d end
  adapter = adapter or {}
  pack = pack or {}

  d.class = safe(adapter.playerClass)
  d.level = safe(function() return state:level() end)

  local talents = safe(adapter.talents)
  if talents then
    d.talents = talents
    d.specIndex = talents.top
    d.talentPoints = talents.total
  end

  d.weapon = safe(function() return state:weapon(MAINHAND) end)
  d.offhand = safe(function() return state:weapon(OFFHAND) end)
  d.soul = safe(function() return state:enchant(SHOULDER) end)

  for key, record in pairs(pack.spells or {}) do
    -- Rune keys are the ones the pack marks; everything else is an ability.
    if type(record) == "table" and record.rune then
      d.runes[key] = safe(function() return state:rune(key) end) == true
    end
  end

  for key in pairs(pack.sets or {}) do
    local count = safe(function() return state:setCount(key) end)
    if count and count > 0 then d.sets[key] = count end
  end

  return d
end

-- Detect.check(detection, requires, pack) -> { {ok=, text=}, ... }
--
-- PRD F14: requirement checks WARN, they never block. `requires` is advisory by hard rule 8 and
-- ADR-0006 — a build must play correctly for a character that satisfies none of it — so this returns
-- prose for the wizard to colour, and nothing else in the addon may branch on it.
--
-- `ok = nil` means "could not tell" and must render differently from `ok = false`. Telling someone
-- their weapon is wrong because a tooltip scan came back empty is worse than saying nothing.
function Detect.check(detection, requires, pack)
  local out = {}
  if type(requires) ~= "table" then return out end
  detection = detection or {}
  pack = pack or {}

  if requires.weapon then
    local w = detection.weapon
    local ok
    if w and w.type then ok = w.type == requires.weapon end
    out[#out + 1] = { key = "weapon", ok = ok,
      text = string.format("Weapon: %s (you have %s)", requires.weapon,
        (w and w.type) or "something I could not read") }
  end

  if requires.minSpeed or requires.maxSpeed then
    local speed = detection.weapon and detection.weapon.speed
    local ok
    if speed then
      ok = true
      if requires.minSpeed and speed < requires.minSpeed then ok = false end
      if requires.maxSpeed and speed > requires.maxSpeed then ok = false end
    end
    local want = requires.minSpeed and ("at least " .. requires.minSpeed .. "s")
              or ("at most " .. requires.maxSpeed .. "s")
    out[#out + 1] = { key = "speed", ok = ok,
      text = string.format("Weapon speed %s (yours is %s)", want,
        speed and (speed .. "s") or "not readable") }
  end

  for _, key in ipairs(requires.runes or {}) do
    local have = detection.runes and detection.runes[key]
    out[#out + 1] = { key = key, ok = have,
      text = (pack.spells and pack.spells[key] and pack.spells[key].name or key) ..
             (have and " engraved" or " not engraved") }
  end

  -- `spells` in `requires` names abilities that are not runes and not granted by levelling. An
  -- unknown spell means every entry needing it is skipped, which is the difference between a build
  -- that plays and one with almost nothing to suggest.
  for _, key in ipairs(requires.spells or {}) do
    local known = detection.spells and detection.spells[key]
    out[#out + 1] = { key = key, ok = known, text = key .. (known and " known" or " not known") }
  end

  for key, min in pairs(requires.sets or {}) do
    local count = (detection.sets and detection.sets[key]) or 0
    out[#out + 1] = { key = key, ok = count >= min,
      text = string.format("%s: %d/%d pieces", key, count, min) }
  end

  return out
end

-- Did anything fail outright? Unknowns do not count — this answers "is there something to fix",
-- not "is there something I could not read".
function Detect.hasFailures(checks)
  for _, check in ipairs(checks or {}) do
    if check.ok == false then return true end
  end
  return false
end

ns.Detect = Detect
return Detect
