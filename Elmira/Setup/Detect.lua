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
-- Same identity shim Core/API.lua installs, so this file stays dofile-able on its own.
ns.L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
local L = ns.L

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

  -- Populated because `Detect.check` reads it. It did not exist until the wizard shipped a line
  -- reading `SEAL_OF_MARTYRDOM not known` for a character that has had the ability since level 10:
  -- the lookup was against a table nobody wrote, so every `requires.spells` entry read nil forever.
  -- Same shape as the hover-tooltip's `slot.index`, in the same milestone.
  d.spells = safe(adapter.knownSpells, pack.spells) or nil

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

-- PE1-D6: the client's own name for a record that carries an id, which is the only source that
-- spells "Shock and Awe" the way the spellbook does (our prettifier below can only ever produce
-- "Shock And Awe", since it has no way to know which words are minor ones). Read through the
-- ADAPTER, never a WoW global -- `Setup/` may reach the adapter, and hard rule 3 forbids only the
-- direct client call -- and gated on the same `spellNameLookup` capability Options/Spells.lua's own
-- id lookup uses, because a client without `GetSpellInfo` answers nil for every id. A `sets` record
-- carries no `id`, so this never fires for one and set names come from their own `name` field.
local function clientSpellName(spell)
  local adapter = ns.Adapter
  if not (spell and spell.id and adapter and adapter.spellNameByID) then return nil end
  local caps = adapter.capabilities and adapter.capabilities()
  if not (caps and caps.spellNameLookup) then return nil end
  return safe(adapter.spellNameByID, spell.id)
end

-- A shipped spell record carries an id and a src, not a display name (the client owns names), so a
-- shopping list built from keys would read "RUNE_HAND_OF_RECKONING". Derive something a person can
-- act on: the CLIENT's own name wins, then an explicit `name`, then strip the RUNE_ prefix and
-- title-case the words. The last two keep this deterministic with no adapter present at all, which
-- is how every headless caller (and every spec) reaches it.
function Detect.readableName(key, spell)
  local fromClient = clientSpellName(spell)
  if fromClient then return fromClient end
  if spell and type(spell.name) == "string" then return spell.name end
  local s = tostring(key):gsub("^RUNE_", ""):lower():gsub("_", " ")
  return (s:gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
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

  -- ADR-0013 §2: a build is WRITTEN for its runes, so a missing one is not a mismatch to warn
  -- about but a thing to go and buy -- the Rune Broker in every starting zone sells them for 1c.
  -- The entry therefore reads as an instruction ("Engrave X (hands)"), carries `kind`/`slot` so the
  -- wizard can collect a shopping list, and keeps ok=false so `fits` still says "not yet".
  -- Three states here too: `nil` means the rune API could not be read, and rendering that as
  -- "not engraved" states a fact we do not have -- the same defect the spellbook check had.
  for _, key in ipairs(requires.runes or {}) do
    local have = detection.runes and detection.runes[key]
    local spell = pack.spells and pack.spells[key]
    local name = Detect.readableName(key, spell)
    local slot = spell and spell.rune
    -- `engrave` is the shopping-list item ("Art of War (feet)") as data, so the wizard never has to
    -- scrape it back out of a localised sentence.
    local engrave = slot and string.format(L["%s (%s)"], name, slot) or name
    local text -- mutants: equivalent deleting the declaration leaves a global write the suite cannot see; luacheck catches it
    if have == true then text = string.format(L["%s engraved"], name)
    elseif have == false then text = string.format(L["Engrave %s"], engrave)
    else text = string.format(L["%s: could not read your runes"], name) end
    out[#out + 1] = { key = key, kind = "rune", slot = slot, ok = have, text = text,
                      engrave = (have == false) and engrave or nil }
  end

  -- `spells` in `requires` names abilities that are not runes and not granted by levelling. An
  -- unknown spell means every entry needing it is skipped, which is the difference between a build
  -- that plays and one with almost nothing to suggest.
  for _, key in ipairs(requires.spells or {}) do
    -- Three states, and the TEXT must agree with the marker. `nil` means we could not read the
    -- spellbook; rendering that as "not known" states a fact we do not have, which is how the wizard
    -- told a level-60 paladin it lacked an ability it has had since level 10.
    local known = detection.spells and detection.spells[key]
    -- PE1-D6: `pack.spells[key].name` alone read the RAW KEY back out for every shipped spell,
    -- because a shipped record has no `name` at all (the client owns names) -- "HOLY_SHOCK known".
    -- The rune loop above has always gone through `readableName`; this one simply never did.
    local name = Detect.readableName(key, pack.spells and pack.spells[key])
    local text -- mutants: equivalent deleting the declaration leaves a global write the suite cannot see; luacheck catches it
    if known == true then text = string.format(L["%s known"], name)
    elseif known == false then text = string.format(L["%s NOT known"], name)
    else text = string.format(L["%s: could not read your spellbook"], name) end
    out[#out + 1] = { key = key, ok = known, text = text }
  end

  for key, min in pairs(requires.sets or {}) do
    local count = (detection.sets and detection.sets[key]) or 0
    -- PE1-D6, same defect: this leaked "T3_5_HOLY: 2/4 pieces". A set record DOES carry a `name`
    -- ("Radiant Judgement"), so `readableName` finds one for every shipped set and prettifies the
    -- key only for a pack that ships none.
    out[#out + 1] = { key = key, ok = count >= min,
      text = string.format(L["%s: %d/%d pieces"],
                           Detect.readableName(key, pack.sets and pack.sets[key]), count, min) }
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
