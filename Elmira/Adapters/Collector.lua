-- Elmira/Adapters/Collector.lua — `/elm debug dump`, per docs/01 §4a.
--
-- Writes one machine-readable snapshot of the character to SavedVariables, because the addon author
-- cannot run the game and every client-only fact otherwise arrives one question per probe round.
--
-- THE RULE THIS FILE EXISTS TO ENFORCE: dump the RAW client value beside our INTERPRETATION of it.
-- A dump that printed only one side would have looked correct through both probe rounds that missed
-- the rune bug (docs/07 §9.12): every RUNE_* entry held a teach id while detection matches ability
-- ids, so rune() reported "not engraved" for runes the player was wearing, with no error anywhere.
-- Printing both sides is what turns a silent no-op into a visible mismatch.
--
-- Structure: the comparison functions are PURE and take readings as arguments, so the NO MATCH path
-- is tested headlessly with no client mock. Only the read* functions name a WoW global.
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {}

local Collector = {}

-- INVSLOT ids that can host a rune, verified in game (docs/07 §9.5). Shoulder (3) returns nothing:
-- shoulders take souls, not runes. Ordered, never pairs(), so a dump diffs cleanly against the last.
Collector.RUNE_SLOTS = { 1, 5, 6, 7, 8, 9, 10 }
Collector.SLOT_NAMES = {
  [1] = "head", [5] = "chest", [6] = "waist", [7] = "legs", [8] = "feet", [9] = "wrist", [10] = "hands",
}

local function contains(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then return true end
  end
  return false
end

-- PURE. `readings` is what the client actually returned, one entry per slot that has a rune:
--   { slot = 5, name = "Hallowed Ground", ids = { 458287 } }
-- `spells` is the class pack's Spells table. Returns one row per reading:
--   { slot, slotName, name, ids, matched = "RUNE_HALLOWED_GROUND" | nil, candidates = { {key, id}, ... } }
-- `candidates` lists every data key declaring this slot, WITH its stored id, so a mismatch shows the
-- two numbers side by side instead of just reporting a miss.
function Collector.compareRunes(readings, spells)
  local rows = {}
  for _, reading in ipairs(readings or {}) do
    local slotName = Collector.SLOT_NAMES[reading.slot]
    local row = {
      slot = reading.slot, slotName = slotName, name = reading.name,
      ids = reading.ids or {}, matched = nil, candidates = {},
    }
    -- Sorted so two dumps of the same character produce byte-identical output.
    local keys = {}
    for key in pairs(spells or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local record = spells[key]
      if type(record) == "table" and record.rune then
        if contains(row.ids, record.id) then
          row.matched = key
        elseif record.rune == slotName then
          row.candidates[#row.candidates + 1] = { key = key, id = record.id }
        end
      end
    end
    rows[#rows + 1] = row
  end
  return rows
end

-- PURE. Renders compareRunes rows. A miss prints the stored id next to the client's, which is the
-- single line that would have caught the teach-vs-ability bug on sight.
function Collector.formatRunes(rows)
  local lines = {}
  for _, row in ipairs(rows or {}) do
    local ids = table.concat(row.ids, ", ")
    lines[#lines + 1] = string.format("slot %d (%s): %s  learnedAbilitySpellIDs = { %s }",
      row.slot, tostring(row.slotName), tostring(row.name), ids)
    if row.matched then
      lines[#lines + 1] = string.format("    -> %s  MATCH", row.matched)
    elseif #row.candidates == 0 then
      lines[#lines + 1] = "    -> NO MATCH, and no data key claims this slot (rune absent from pack)"
    else
      for _, c in ipairs(row.candidates) do
        lines[#lines + 1] = string.format("    -> %s = %s  NO MATCH (client says %s)",
          c.key, tostring(c.id), ids)
      end
    end
  end
  return lines
end

-- PURE. `readings[key] = { cooldown = n, cost = n, castTime = n, known = bool }` as read live.
-- Emits the shipped fallback beside each, because docs/07 §9.1 found Wowhead's Exorcism cooldown
-- (15 s) 2.5x the real one (6 s) and that disagreement must be visible, not averaged away.
function Collector.compareSpells(readings, spells)
  local keys = {}
  for key in pairs(readings or {}) do keys[#keys + 1] = key end
  table.sort(keys)

  local rows = {}
  for _, key in ipairs(keys) do
    local live = readings[key] or {}
    local record = (spells or {})[key] or {}
    local shippedCost = type(record.cost) == "table" and record.cost.mana or nil
    rows[#rows + 1] = {
      key = key, id = record.id, known = live.known,
      liveCooldown = live.cooldown, shippedCooldown = record.cooldown,
      liveCost = live.cost, shippedCost = shippedCost,
      castTime = live.castTime,
      cooldownDiffers = live.cooldown ~= nil and record.cooldown ~= nil and live.cooldown ~= record.cooldown,
      costDiffers = live.cost ~= nil and shippedCost ~= nil and live.cost ~= shippedCost,
    }
  end
  return rows
end

function Collector.formatSpells(rows)
  local lines = {}
  for _, r in ipairs(rows or {}) do
    if r.known == false then
      lines[#lines + 1] = string.format("%-26s id=%s  NOT KNOWN", r.key, tostring(r.id))
    else
      lines[#lines + 1] = string.format("%-26s id=%s  cd: live=%s shipped=%s%s  cost: live=%s shipped=%s%s  cast=%s",
        r.key, tostring(r.id),
        tostring(r.liveCooldown), tostring(r.shippedCooldown), r.cooldownDiffers and " <-DIFFERS" or "",
        tostring(r.liveCost), tostring(r.shippedCost), r.costDiffers and " <-DIFFERS" or "",
        tostring(r.castTime))
    end
  end
  return lines
end

-- PURE. Our computed set count vs the count the tooltip itself reports. docs/07 §9.11 found the
-- tooltip knows `(n/N)` for the character's CURRENT spec, so it cannot go stale the way a shipped
-- item list can — which makes it the better witness whenever the two disagree.
function Collector.compareSets(computed, tooltipCounts)
  local keys = {}
  for key in pairs(computed or {}) do keys[#keys + 1] = key end
  table.sort(keys)

  local rows = {}
  for _, key in ipairs(keys) do
    local ours = computed[key]
    local theirs = (tooltipCounts or {})[key]
    rows[#rows + 1] = {
      key = key, computed = ours, tooltip = theirs,
      differs = theirs ~= nil and ours ~= theirs,
    }
  end
  return rows
end

-- ---------------------------------------------------------------------------
-- Below here: the only functions that name a WoW global.
-- ---------------------------------------------------------------------------

-- Returns readings in compareRunes' shape. Empty (not nil) when engraving is unavailable, so the
-- caller never has to nil-check and an absent capability reads as "no runes", not as an error.
function Collector.readRunes()
  local readings = {}
  if not (C_Engraving and C_Engraving.GetRuneForEquipmentSlot) then return readings end
  for _, slot in ipairs(Collector.RUNE_SLOTS) do
    local rune = C_Engraving.GetRuneForEquipmentSlot(slot)
    if rune then
      readings[#readings + 1] = {
        slot = slot,
        name = rune.name,
        ids = rune.learnedAbilitySpellIDs or {},
        itemEnchantmentID = rune.itemEnchantmentID,
        skillLineAbilityID = rune.skillLineAbilityID,
      }
    end
  end
  return readings
end

-- Reads live cooldown/cost/cast time for every spell key in the pack. `GetSpellCooldown` returns the
-- GCD (1.5 s) for any spell while the GCD is running (docs/07 §9.10), so a reading at or below the
-- GCD threshold is recorded as nil rather than as that spell's cooldown — the same filter the
-- adapter's observe-and-cache has to apply.
local GCD_CEILING = 1.6

function Collector.readSpells(spells)
  local readings = {}
  for key, record in pairs(spells or {}) do
    if type(record) == "table" and type(record.id) == "number" and record.id > 0 then
      local id = record.id
      -- NOT `IsPlayerSpell and IsPlayerSpell(id) or nil`: in Lua `false or nil` is nil, so that
      -- collapses "not known" into "unknown" and the NOT KNOWN branch of formatSpells becomes
      -- unreachable — an unlearned spell dumps as though it were known. Explicit branch instead.
      local reading = {}
      if IsPlayerSpell then reading.known = IsPlayerSpell(id) == true end
      if GetSpellCooldown then
        local _, duration = GetSpellCooldown(id)
        if duration and duration > GCD_CEILING then reading.cooldown = duration end
      end
      if GetSpellPowerCost then
        local costs = GetSpellPowerCost(id)
        if type(costs) == "table" and costs[1] then reading.cost = costs[1].cost end
      end
      if GetSpellInfo then
        local _, _, _, castTime = GetSpellInfo(id)
        reading.castTime = castTime
      end
      readings[key] = reading
    end
  end
  return readings
end

-- Souls and set counts live in the shoulder/item TOOLTIP, never in the item link — verified twice in
-- game (docs/07 §9.10). Tooltip scanning is expensive, which is fine here: this runs on demand only.
local scanTooltip

local function getScanTooltip()
  if scanTooltip then return scanTooltip end
  if not CreateFrame then return nil end
  scanTooltip = CreateFrame("GameTooltip", "ElmiraScanTooltip", nil, "GameTooltipTemplate")
  scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
  return scanTooltip
end

-- Returns the raw tooltip lines for an equipped slot, so the dump carries the text I actually have
-- to parse rather than my parse of it.
function Collector.readItemTooltipLines(slot)
  local tip = getScanTooltip()
  if not tip then return {} end
  tip:ClearLines()
  tip:SetInventoryItem("player", slot)
  local lines = {}
  for i = 1, tip:NumLines() do
    local fontString = _G["ElmiraScanTooltipTextLeft" .. i]
    local text = fontString and fontString:GetText()
    if text and text ~= "" then lines[#lines + 1] = text end
  end
  return lines
end

function Collector.readCharacter()
  local character = {}
  if UnitLevel then character.level = UnitLevel("player") end
  if UnitClass then character.class = select(2, UnitClass("player")) end
  if GetTalentTabInfo then
    -- docs/07 §9.8: this does NOT return the name first on this client — position 1 held a numeric
    -- tab id and points were in position 5. Record both raw returns rather than trusting either.
    local tabs = {}
    for i = 1, 3 do
      local first, _, _, _, points = GetTalentTabInfo(i)
      tabs[i] = { first = first, points = points }
    end
    character.talentTabs = tabs
  end
  if C_Engraving then
    character.engravingEnabled = C_Engraving.IsEngravingEnabled and C_Engraving.IsEngravingEnabled()
  end
  return character
end

-- Ties the pieces together. Returns a structured snapshot (for SavedVariables) and the rendered
-- lines (for chat). `pack` is a registered data pack: { spells =, sets =, souls =, ... }.
function Collector.snapshot(pack)
  pack = pack or {}
  local runeReadings = Collector.readRunes()
  local auraSeen, auraScanned = Collector.readAuraPresence(pack.spells)
  return {
    character = Collector.readCharacter(),
    runes = Collector.compareRunes(runeReadings, pack.spells),
    spells = Collector.compareSpells(Collector.readSpells(pack.spells), pack.spells),
    shoulderTooltip = Collector.readItemTooltipLines(3),
    pending = Collector.pendingVerification(pack.spells),
    auraPresence = auraSeen,
    aurasScanned = auraScanned,
  }
end

-- PURE. Renders a snapshot. Kept separate from snapshot() so a fixture can be rendered in a test.
function Collector.format(snapshot)
  snapshot = snapshot or {}
  local lines = { "-- Elmira dump" }
  local c = snapshot.character or {}
  lines[#lines + 1] = string.format("character: level=%s class=%s engraving=%s",
    tostring(c.level), tostring(c.class), tostring(c.engravingEnabled))

  lines[#lines + 1] = ""
  lines[#lines + 1] = "runes (client value vs our data):"
  local runeLines = Collector.formatRunes(snapshot.runes)
  if #runeLines == 0 then
    lines[#lines + 1] = "  (no runes engraved, or engraving unavailable)"
  end
  for _, line in ipairs(runeLines) do lines[#lines + 1] = "  " .. line end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "spells (live vs shipped fallback):"
  for _, line in ipairs(Collector.formatSpells(snapshot.spells)) do lines[#lines + 1] = "  " .. line end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "shoulder tooltip (raw — souls live here, not in the item link):"
  for _, line in ipairs(snapshot.shoulderTooltip or {}) do lines[#lines + 1] = "  " .. line end

  local pending = Collector.formatPending(snapshot.pending, snapshot.auraPresence)
  if #pending > 0 then
    lines[#lines + 1] = ""
    for _, line in ipairs(pending) do lines[#lines + 1] = line end
    lines[#lines + 1] = ""
    for _, line in ipairs(Collector.formatScan(snapshot.aurasScanned)) do lines[#lines + 1] = line end
  end

  return lines
end

-- PURE. Every entry tagged `verify = "in-game"` (docs/03): an id from a real source that nobody has
-- yet watched happen. The dump is how they get resolved, so it lists them with the exact aura name to
-- watch for — otherwise a provisional id sits in the data indefinitely because nothing ever asks.
function Collector.pendingVerification(spells)
  local keys = {}
  for key, record in pairs(spells or {}) do
    if type(record) == "table" and record.verify == "in-game" then keys[#keys + 1] = key end
  end
  table.sort(keys)

  local rows = {}
  for _, key in ipairs(keys) do
    local record = spells[key]
    rows[#rows + 1] = { key = key, id = record.id, src = record.src, note = record.note }
  end
  return rows
end

-- PURE. `seen` is readAuraPresence's output.
function Collector.formatPending(rows, seen)
  if #(rows or {}) == 0 then return {} end
  seen = seen or {}
  local lines = { "awaiting in-game confirmation (docs/03) — provisional ids, not yet observed:" }
  for _, r in ipairs(rows) do
    local hit = seen[r.key]
    local status = hit
      and string.format("VISIBLE to UnitAura (name=%q stacks=%s)", tostring(hit.name), tostring(hit.count))
      or "not on the player right now"
    lines[#lines + 1] = string.format("  %-24s id=%s  %s", r.key, tostring(r.id), status)
    lines[#lines + 1] = string.format("  %-24s   src=%s", "", tostring(r.src))
    if r.note then lines[#lines + 1] = string.format("  %-24s   %s", "", r.note) end
  end
  lines[#lines + 1] = "  (absent proves nothing for a transient buff — only for one that should always be up)"
  return lines
end

-- PURE. Without this line, "0 matched" is unreadable: a working scan that found nothing and a scan
-- that never ran produce identical output. Print what WAS walked so the reader can tell them apart.
function Collector.formatScan(scanned)
  scanned = scanned or {}
  if #scanned == 0 then
    return { "aura scan: walked 0 buffs — NO CONCLUSION can be drawn from any 'not on the player'",
             "  line above. Either you had no buffs up, or the scan is broken. Buff yourself and re-run." }
  end
  local lines = { string.format("aura scan: walked %d player buffs, so an unmatched id above really is"
    .. " absent:", #scanned) }
  for _, a in ipairs(scanned) do
    lines[#lines + 1] = string.format("  %s (%s)", tostring(a.name), tostring(a.spellID))
  end
  return lines
end

-- Scans the player's buffs for each provisional aura id and reports whether the client can see it at
-- all. This is the ONLY thing that can settle whether a "permanent hidden aura" is real to the API:
-- a simulator registering an aura says nothing about whether UnitAura returns it. Absent is only
-- meaningful for auras that should be permanently up (the soul leads); a transient buff being absent
-- means nothing, so the report must not read a conclusion into it.
-- Returns `seen` (matched provisional auras) AND `scanned` (every buff the scan walked). The second
-- return exists because without it a result of "nothing matched" is worthless: it cannot be told apart
-- from "the scan found nothing at all", so a broken scan reads exactly like a disproved hypothesis.
-- The first run hit precisely that — 0 matches, no way to know whether the scan had worked.
function Collector.readAuraPresence(spells)
  local seen, scanned = {}, {}
  if not UnitAura then return seen, scanned end
  local wanted = {}
  for key, record in pairs(spells or {}) do
    if type(record) == "table" and record.verify == "in-game" and type(record.id) == "number" then
      wanted[record.id] = key
    end
  end
  for i = 1, 40 do
    local name, _, count, _, duration, _, _, _, _, spellID = UnitAura("player", i, "HELPFUL")
    if not name then break end
    scanned[#scanned + 1] = { name = name, spellID = spellID }
    local key = wanted[spellID]
    if key then seen[key] = { name = name, count = count, duration = duration, spellID = spellID } end
  end
  return seen, scanned
end

-- PURE. How many rune rows disagree with our data. This is the number worth reading first.
function Collector.mismatchCount(snapshot)
  local n = 0
  for _, row in ipairs((snapshot or {}).runes or {}) do
    if not row.matched then n = n + 1 end
  end
  return n
end

Collector.GCD_CEILING = GCD_CEILING
ns.Collector = Collector
return Collector
