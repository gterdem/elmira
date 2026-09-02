-- Elmira/Core/Advisor.lua — what should this character CHANGE? (PRD F21, docs/01 §5a)
--
-- PURE (hard rule 3): rules in, a recommendation out. No WoW API, no frames, no slot numbers. What
-- the player currently wears arrives as an argument, gathered by Setup/Detect.lua, so this file
-- never needs to know that shoulders are inventory slot 3.
--
-- The distinction that shapes everything here: a recommendation is not a requirement. `requires` is
-- advisory and never changes evaluation (hard rule 8, ADR-0006); so is this. A build must play
-- correctly for someone who ignores every word of it — the advisor's job is to tell a player what
-- would make their gear better, never to gate what the rotation will suggest.
--
-- Rules come from `Data/<flavor>/Advice/<Class>.lua`, gated with the same `when` syntax builds use.
-- They are compiled through Schema.compileWhen rather than a second evaluator: one condition
-- language with two interpreters drifts the first time a condition type is added, and the drift
-- surfaces as advice that is quietly wrong.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Advisor = {}

-- `current` is what the player HAS: { soul = key|nil, weapon = {type=, speed=}|nil }. Absent fields
-- mean "not known", which is different from "not equipped" — an unknown never produces a complaint,
-- because telling someone their soul is wrong when we could not read it is worse than saying nothing.
local function has(current, field)
  return current ~= nil and current[field] ~= nil
end

-- First matching rule wins, exactly as Data/Advice/<Class>.lua's own header states. A rule with no
-- `when` always matches, so an unconditional rule at the end of the list is the default.
local function firstMatch(rules, state, ctx)
  for _, rule in ipairs(rules or {}) do
    if rule.when == nil then
      return rule
    elseif ns.Schema and ns.Schema.compileWhen then
      local compiled = ns.Schema.compileWhen(rule.when, ctx)
      if compiled.test(state, 0) then return rule end
    end
  end
  return nil
end

-- Advisor.recommend(rules, state, ctx, current) -> recommendation
--
--   rules   — the Advice entry for ONE build (advice[CLASS][buildKey])
--   state   — a State, for the `when` conditions (set counts, bonuses, runes)
--   ctx     — { spells=, sets=, souls=, bonuses= } from the data pack, for compiling conditions
--   current — { soul=, weapon= } as detected; every field optional
--
-- Every returned item carries `ok`: true when the character already satisfies it, false when it is
-- something to change, and nil when we could not tell. Three states, because "you have the wrong
-- soul" and "I cannot read your shoulders" must not render identically.
function Advisor.recommend(rules, state, ctx, current)
  local rec = { soul = nil, runes = {}, weapon = nil, notes = {} }
  if type(rules) ~= "table" then return rec end
  ctx = ctx or {}
  current = current or {}

  local soulRule = firstMatch(rules.soul, state, ctx)
  if soulRule and soulRule.pick then
    local ok
    if has(current, "soul") then ok = current.soul == soulRule.pick end
    rec.soul = { pick = soulRule.pick, reason = soulRule.reason, have = current.soul, ok = ok }
  end

  -- Runes are a flat list of what this build wants engraved. `state:rune()` answers per key, and a
  -- character missing one is the normal case, not a problem — most of them are optional upgrades.
  for _, key in ipairs(rules.runes or {}) do
    local have
    if state and state.rune then
      local okCall, got = pcall(function() return state:rune(key) end)
      if okCall then have = got == true end
    end
    rec.runes[#rec.runes + 1] = { key = key, have = have, ok = have }
  end

  -- Ring runes vary by race in the shipped data (`ringRunes = { human = {...}, default = {...} }`).
  -- Race is not on the State contract, so the caller supplies it; with no race we take `default`,
  -- which is the correct answer for everyone except the race that has a better option.
  local ring = rules.ringRunes
  if type(ring) == "table" then
    local list = (current.race and ring[current.race]) or ring.default
    for _, key in ipairs(list or {}) do
      rec.runes[#rec.runes + 1] = { key = key, have = nil, ok = nil, ring = true }
    end
  end

  -- The weapon descriptor is a bare table, not a `when` list — it describes what to hold, and the
  -- speed bounds are the same ones the catalog's `requires` uses.
  local weapon = rules.weapon
  if type(weapon) == "table" then
    local ok
    if has(current, "weapon") then
      local w = current.weapon
      ok = true
      if weapon.type and w.type ~= weapon.type then ok = false end
      -- A missing speed is unknown, not a failure: base weapon speed comes from a tooltip scan that
      -- can legitimately come back empty (docs/07 §9.11).
      if ok and w.speed then
        if weapon.minSpeed and w.speed < weapon.minSpeed then ok = false end
        if weapon.maxSpeed and w.speed > weapon.maxSpeed then ok = false end
      end
    end
    rec.weapon = { type = weapon.type, minSpeed = weapon.minSpeed, maxSpeed = weapon.maxSpeed,
                   reason = weapon.reason, have = current.weapon, ok = ok }
  end

  -- Warnings are conditional prose the data pack wants surfaced — e.g. "this soul was nerfed".
  -- `unlessBuild` lets one warning be silenced for the build it does not apply to.
  for _, warning in ipairs(rules.warnings or {}) do
    local applies = true
    if warning.unlessBuild and warning.unlessBuild == current.build then applies = false end
    if applies and warning.soul and current.soul and warning.soul ~= current.soul then applies = false end
    if applies and warning.when then
      local compiled = ns.Schema and ns.Schema.compileWhen(warning.when, ctx)
      applies = compiled ~= nil and compiled.test(state, 0) == true
    end
    if applies and warning.text then rec.notes[#rec.notes + 1] = warning.text end
  end

  return rec
end

-- Flattens a recommendation into lines for `/elm advise` and the wizard's summary step. Kept here so
-- chat and the wizard cannot drift into describing the same recommendation differently.
function Advisor.lines(rec, L)
  L = L or setmetatable({}, { __index = function(_, k) return k end })
  local out = {}
  if not rec then return out end

  if rec.soul then
    local line = L["Shoulder soul"] .. ": " .. tostring(rec.soul.pick)
    if rec.soul.ok == true then
      line = line .. " " .. L["(equipped)"]
    elseif rec.soul.ok == false then
      line = line .. " " .. string.format(L["(you have %s)"], tostring(rec.soul.have))
    end
    if rec.soul.reason then line = line .. " — " .. rec.soul.reason end
    out[#out + 1] = line
  end

  if rec.weapon then
    local want = rec.weapon.type or "?"
    if rec.weapon.maxSpeed then want = want .. string.format(" \226\137\164%.1fs", rec.weapon.maxSpeed) end
    if rec.weapon.minSpeed then want = want .. string.format(" \226\137\165%.1fs", rec.weapon.minSpeed) end
    local line = L["Weapon"] .. ": " .. want
    if rec.weapon.ok == false then line = line .. " " .. L["(does not match what you are holding)"] end
    if rec.weapon.reason then line = line .. " — " .. rec.weapon.reason end
    out[#out + 1] = line
  end

  -- Only the missing ones. Listing runes the player already has is a wall of green nobody reads.
  local missing = {}
  for _, rune in ipairs(rec.runes or {}) do
    if rune.have == false then missing[#missing + 1] = rune.key end
  end
  if #missing > 0 then
    out[#out + 1] = L["Runes not engraved"] .. ": " .. table.concat(missing, ", ")
  end

  for _, note in ipairs(rec.notes or {}) do out[#out + 1] = note end
  return out
end

ns.Advisor = Advisor
return Advisor
