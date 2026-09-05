-- Elmira/Core/Palette.lua — what the Builder offers you to put in a rotation (F30, ADR-0015 §2).
--
-- Pure: no WoW API, no frames (hard rule 3). Everything client-shaped arrives through `opts` —
-- `label(key)` resolves a display name, `known(key)` answers whether the character has learned it.
-- That is what lets the whole palette be tested headlessly while the widget that draws it cannot be.
--
-- The palette is PACK-SCOPED, and that is a constraint rather than a choice: `Schema.validate`
-- rejects any entry whose spell key is not in the class data pack, and hard rule 4 forbids raw IDs,
-- so a spell the character knows that `Classes/<Class>.lua` does not carry cannot go in a build at
-- all. Listing it would be offering something that cannot be added.
--
-- Every pack spell is listed, with the un-known ones marked and given a reason (owner decision,
-- 2026-09-05). A rotation you cannot yet run is a rotation you are about to be able to run: runes
-- cost 1c and the engraving is the thing you go and do. Hiding those rows would hide the answer to
-- "why can I not add Divine Storm".
--
-- Two failures are designed out here, both learned by Options.lua's "Test with" dropdown the hard
-- way (see its comment): passive rune records are not castable and must never be offered, and two
-- records can resolve to ONE spell name, which reads as a duplicate however different the keys are.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Palette = {}

-- Inventory slots, as numbers. Naming them is Options' job, the way Core/Visibility's modes are
-- named there: Core decides what a slot IS, Options decides what it is called.
--
-- An entry binds to the SLOT, never to the item in it (`entry.item = 13`, docs/02 `item_ready`),
-- so a rotation keeps working when you replace the trinket.
Palette.TRINKET_SLOTS = { 13, 14 }

-- Everything that can carry an on-use effect. Shirt (4) and tabard (19) never can, so they are not
-- here; the rest are behind the "all equipment slots" toggle because for most characters most of
-- them are empty, and a palette of empty rows teaches you to stop reading it.
Palette.EQUIPMENT_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }

-- Which rune record grants a given castable spell, by spell id.
--
-- There is no `grants` field on a rune to read: the rune record and the ability it teaches carry
-- the SAME id (RUNE_DIVINE_STORM and DIVINE_STORM are both 407778), which is what makes the link
-- derivable at all. Worth stating because it also means the two always resolve to one display name,
-- so the de-duplication below is not optional decoration.
local function runesById(spells)
  local out = {}
  for key, data in pairs(spells or {}) do
    if type(data) == "table" and data.rune and data.id then out[data.id] = key end
  end
  return out
end

-- Is this record something a player can actually press?
--
-- `pack.spells` is not a list of abilities: it is every spell the class data needs to NAME, which
-- includes the auras conditions test (`{"buff","TEMPLAR_BUFF"}`), the debuffs Judgement applies, the
-- passives a rune grants, and the rune records themselves. Offering those was the shipped defect
-- this function exists to stop -- against the real Paladin pack, 14 of 34 rows could never be
-- pressed, and one of them rendered as "The Art of War (engrave The Art of War)".
--
-- The classification lives in the DATA rather than in a heuristic here, because no property of the
-- record distinguishes the two: Rebuke, Righteous Fury, Horn of Lordaeron and every seal are all
-- castable with neither a cost nor a cooldown, so "has a cost or cooldown" would hide real
-- abilities while still showing buffs. A record must therefore SAY what it is.
--
-- Hand of Reckoning is the deliberate exception, and it is not a gap to be closed: it exists only
-- as a rune record, so this filter hides it, and it should stay hidden. It is a taunt -- situational,
-- pressed in answer to what a mob is doing rather than in a priority order, so it does not belong
-- in a rotation at all (owner, 2026-09-05).
function Palette.castable(data)
  if type(data) ~= "table" then return false end
  return not (data.rune or data.aura or data.passive or data.proc or data.triggered)
end

-- Palette.spells(pack, opts) -> rows
--
-- rows are { key, label, known, reason }, sorted by label. `known` is tri-state and carries the
-- adapter's meaning exactly: true, false, or nil for "this client cannot tell" — which must not be
-- rendered as "you do not have it" (Adapters/Interface.lua says the same about `known`).
function Palette.spells(pack, opts)
  opts = opts or {}
  local spells = pack and pack.spells
  if not spells then return {} end
  local label = opts.label or function(key) return key end
  local known = opts.known

  local runeFor = runesById(spells)
  local rows, byLabel = {}, {}

  for key, data in pairs(spells) do
    if Palette.castable(data) then
      local text = label(key)
      local is = known and known(key)
      local row = { key = key, label = text, known = is }

      if is == false then
        -- Structured, not prose: Core says WHY a row is unavailable, Options says it in words and
        -- through AceLocale. `rune` is the actionable case -- "not learned" is true and useless,
        -- "engrave Divine Storm" is the thing you go and do, and for a rune-granted ability it is
        -- the only reason it can be missing.
        local rune = data.id and runeFor[data.id]
        row.reason = rune and "rune" or "unlearned"
        row.reasonKey = rune
      end

      -- Unique on the LABEL, not the key: two records resolving to one spell name are a duplicate
      -- to the reader. A row the character actually has wins, so the palette never explains how to
      -- get something you are already holding.
      --
      -- The index holds a POSITION, not the row it saw. Holding the row means the swap below has to
      -- search `rows` for it and then remember to re-point the index, which is two more lines that
      -- do nothing observable and one stale pointer waiting for the next person to edit this.
      local at = byLabel[text]
      if at == nil then
        rows[#rows + 1] = row
        byLabel[text] = #rows
      elseif rows[at].known ~= true and is == true then
        rows[at] = row
      end
    end
  end

  -- By label, because that is the order the reader sees, and `pairs()` has no order at all -- a
  -- palette that reshuffles between opens is unusable. No tie-break is needed or possible: the
  -- de-duplication above leaves every label unique, so this is already a total order.
  table.sort(rows, function(a, b) return a.label < b.label end)
  return rows
end

-- Palette.items(opts) -> rows of { slot, filled }
--
-- Trinkets alone unless `allSlots`, which is the toggle the Builder offers (owner decision,
-- 2026-09-05): trinkets are what essentially every SoD rotation uses on-use, and the rest are there
-- for engineering gloves and the like without cluttering the common case.
--
-- `filled` says whether something is in the slot right now. It never removes a row: a rotation is
-- allowed to name a slot you have not filled yet, exactly as it may name a rune you have not
-- engraved, and `item_ready` gates it at runtime either way.
function Palette.items(opts)
  opts = opts or {}
  local slots = opts.allSlots and Palette.EQUIPMENT_SLOTS or Palette.TRINKET_SLOTS
  local filled = opts.filled
  local rows = {}
  for _, slot in ipairs(slots) do
    rows[#rows + 1] = { slot = slot, filled = filled and filled(slot) or false }
  end
  return rows
end

ns.Palette = Palette
return Palette
