-- Elmira/Core/Conditions.lua — the editor's model of the condition language (F30, ADR-0015 §2).
--
-- PURE (hard rule 3): no WoW API, no frames, no AceConfig. It turns a stored `when` list into typed
-- rows the Builder can draw as category -> field -> operator -> value, turns those rows back into a
-- `when` list, and writes any condition out in words.
--
-- Why a second model at all, when Core/Schema already compiles `when`. Schema answers "does this
-- pass", which is the only question the queue asks; the editor asks three questions Schema has no
-- answer for -- what may go in this slot, what shape is this stored condition in, and what does it
-- say. Keeping those here rather than in Options/Rotation.lua is what lets every one of them be
-- tested headlessly against the SHIPPED pack, which is the only fixture that can catch a field
-- table that has drifted from the builds people actually run.
--
-- Two rules the shapes below exist to enforce:
--   * **One qualifier per row.** `{"buff","X", min = 3}` is a row; `{"buff","X", min = 3,
--     maxRemaining = 2}` is two tests wearing one row's clothes, and a UI that showed one operator
--     would silently drop the other on save. Such a condition is reported COMPLEX and never edited.
--   * **Ids are strings, never numbers.** AceConfig `select` round-trips its value through the
--     widget, and a numeric operator id comes back as a string; the two then compare unequal and
--     the dropdown resets itself every time it is opened.
--
-- Words, not glyphs. Every sentence here is ASCII: the client's font draws U+2265 and friends as
-- empty boxes, which is how a status column once shipped as a row of identical squares
-- (tasks/lessons.md, 2026-09-04).
local ADDON, ns = ...
ns = ns or _G.__ELM_NS or {} -- mutants: equivalent tests/helper.lua always passes ns as a vararg

local Conditions = {}

-- The values that are not in a data pack because they are the language's own vocabulary. Schema
-- validates `mode` and `weapon` against exactly these three-item lists (Core/Schema.lua C.mode,
-- C.weapon), so a fourth entry here would offer the player a value the compiler rejects.
Conditions.MODES = { "Single", "Cleave", "AoE" }
Conditions.WEAPON_KINDS = { "2H", "1H", "Shield" }
-- `state:targetType()` is UnitCreatureType, which answers a LOCALISED string. enUS only in v1
-- (every string via L[...], docs/01-ARCHITECTURE.md), and a build that ships a creature type is
-- shipping an English one.
Conditions.CREATURE_TYPES = {
  "Beast", "Critter", "Demon", "Dragonkin", "Elemental", "Giant", "Humanoid", "Mechanical", "Undead",
}
-- What the adapter can resolve (Adapters/Vanilla.lua S:power). Anything else falls through to Mana
-- there, so offering it would be offering a silent lie. COMBO_POINTS joined the other three at R2
-- (D59), owner-decided 2026-09-07: without it a pack-less rogue -- the case R2 exists to serve --
-- had no way to write "5 combo points" at all, pack or no pack.
Conditions.POWERS = { "MANA", "RAGE", "ENERGY", "COMBO_POINTS" }

-- ---------------------------------------------------------------- fields
--
-- One entry per condition type the editor can draw. `keyAt`/`slotAt` are the POSITIONS the stored
-- condition keeps its arguments at, which is what makes `enchant` (slot at 2, key at 3) and
-- `cooldown_gt` (key at 2, seconds at 3) expressible without a special case in the row conversion.
--
-- `ops[1]` is the default and is always the operator that needs no value, where the field has one.
-- An op with `at` puts its value POSITIONALLY; every other op names a qualifier field, and the op's
-- id IS that qualifier's name -- which is what lets a stored condition be matched back to its
-- operator by looking at which qualifier it carries.
--
-- Labels are English here, and Options passes every one through AceLocale. Core deciding what a
-- field IS while Options decides what it is CALLED is the split Core/Palette and Core/Visibility
-- already use; the alternative is a parallel label table in Options that drifts the first time a
-- field is added, and drifts silently.
local FIELDS = {
  -- Encounter
  enemies = { label = "Enemies nearby", ops = {
    { id = "min", label = "at least", arg = "number" },
    { id = "max", label = "at most", arg = "number" },
  } },
  mode = { label = "Mode", keyAt = 2, keySource = "modes", ops = {
    { id = "present", label = "is" },
  } },
  ttd = { label = "Time to die", ops = {
    { id = "min", label = "at least", arg = "number", unit = "seconds" },
    { id = "max", label = "at most", arg = "number", unit = "seconds" },
  } },

  -- Resources
  resource = { label = "Power", keyAt = 2, keySource = "powers", ops = {
    { id = "minPct", label = "at least (%)", arg = "number" },
    { id = "maxPct", label = "at most (%)", arg = "number" },
    { id = "min", label = "at least (points)", arg = "number" },
    { id = "max", label = "at most (points)", arg = "number" },
  } },

  -- Target
  target_hp = { label = "Target health", ops = {
    { id = "maxPct", label = "at most (%)", arg = "number" },
    { id = "minPct", label = "at least (%)", arg = "number" },
  } },
  target_type = { label = "Target creature type", keyAt = 2, keySource = "creatureTypes", ops = {
    { id = "present", label = "is" },
  } },

  -- Buffs and debuffs. The key source is EVERY pack spell, not the auras: the shipped builds gate
  -- on `no_buff` of Righteous Fury and on `buff` of Seal of Martyrdom, both of which are castable
  -- abilities. Filtering to records flagged `aura` would have made those rows un-editable.
  buff = { label = "Buff on you", keyAt = 2, keySource = "spells", ops = {
    { id = "present", label = "is up" },
    { id = "min", label = "stacks at least", arg = "number" },
    { id = "maxRemaining", label = "seconds left at most", arg = "number", unit = "seconds" },
    { id = "minRemaining", label = "seconds left at least", arg = "number", unit = "seconds" },
  } },
  no_buff = { label = "Buff missing from you", keyAt = 2, keySource = "spells", ops = {
    { id = "present", label = "is not up" },
  } },
  debuff = { label = "Debuff on the target", keyAt = 2, keySource = "spells", ops = {
    { id = "present", label = "is on the target" },
    { id = "minRemaining", label = "seconds left at least", arg = "number", unit = "seconds" },
  } },
  no_debuff = { label = "Debuff missing from the target", keyAt = 2, keySource = "spells", ops = {
    { id = "present", label = "is not on the target" },
  } },
  seal = { label = "Active seal", keyAt = 2, keySource = "seals", ops = {
    { id = "present", label = "is" },
  } },
  no_seal = { label = "No seal at all", ops = { { id = "present", label = "" } } },
  seal_linger = { label = "Seal still lingering", keyAt = 2, keySource = "seals", ops = {
    { id = "present", label = "is" },
  } },

  -- Cooldowns
  cooldown_ready = { label = "Cooldown ready", keyAt = 2, keySource = "castables", ops = {
    { id = "present", label = "is ready" },
  } },
  cooldown_gt = { label = "Cooldown remaining", keyAt = 2, keySource = "castables", ops = {
    { id = "secs", label = "more than", arg = "number", at = 3, unit = "seconds" },
  } },
  item_ready = { label = "Equipment slot ready", slotAt = 2, ops = {
    { id = "present", label = "is usable and off cooldown" },
  } },
  swing = { label = "Next auto-attack", ops = {
    { id = "maxRemaining", label = "at most", arg = "number", unit = "seconds" },
    { id = "minRemaining", label = "at least", arg = "number", unit = "seconds" },
  } },

  -- Gear and runes. These are the STATIC gates (Core/Gates.STATIC) -- the ones that change when the
  -- character changes and then stay changed -- so their wording comes from Gates.describe rather
  -- than from a second phrasing here.
  set = { label = "Tier set pieces", keyAt = 2, keySource = "sets", ops = {
    { id = "present", label = "any piece" },
    { id = "min", label = "at least (pieces)", arg = "number" },
  } },
  bonus = { label = "Set bonus or soul", keyAt = 2, keySource = "bonuses", ops = {
    { id = "present", label = "is active" },
  } },
  rune = { label = "Rune engraved", keyAt = 2, keySource = "runes", ops = {
    { id = "present", label = "is engraved" },
  } },
  no_rune = { label = "Rune not engraved", keyAt = 2, keySource = "runes", ops = {
    { id = "present", label = "is not engraved" },
  } },
  weapon = { label = "Equipped weapon", keyAt = 2, keySource = "weaponKinds", ops = {
    { id = "present", label = "is equipped" },
    { id = "maxSpeed", label = "speed at most", arg = "number", unit = "seconds" },
    { id = "minSpeed", label = "speed at least", arg = "number", unit = "seconds" },
  } },
  enchant = { label = "Enchant on a slot", slotAt = 2, keyAt = 3, keySource = "souls", ops = {
    { id = "present", label = "is applied" },
  } },
  level = { label = "Your level", ops = {
    { id = "min", label = "at least", arg = "number" },
    { id = "max", label = "at most", arg = "number" },
  } },

  -- Combat state
  in_combat = { label = "In combat", ops = { { id = "present", label = "" } } },
  out_of_combat = { label = "Out of combat", ops = { { id = "present", label = "" } } },
  not_moving = { label = "Standing still", ops = { { id = "present", label = "" } } },
}
Conditions.FIELDS = FIELDS

-- Ordered, because `pairs()` over FIELDS would reshuffle the dropdown between opens. The grouping is
-- the one a player thinks in -- "what about the fight", "what about me", "what about my gear" --
-- not Schema's implementation order.
Conditions.CATEGORIES = {
  { id = "encounter", label = "Encounter", fields = { "enemies", "mode", "ttd" } },
  { id = "resources", label = "Resources", fields = { "resource" } },
  { id = "target", label = "Target", fields = { "target_hp", "target_type" } },
  { id = "auras", label = "Buffs and debuffs", fields = {
      "buff", "no_buff", "debuff", "no_debuff", "seal", "no_seal", "seal_linger" } },
  { id = "cooldowns", label = "Cooldowns", fields = {
      "cooldown_ready", "cooldown_gt", "item_ready", "swing" } },
  { id = "gear", label = "Gear and runes", fields = {
      "set", "bonus", "rune", "no_rune", "weapon", "enchant", "level" } },
  { id = "state", label = "Combat state", fields = { "in_combat", "out_of_combat", "not_moving" } },
}

function Conditions.field(kind) return FIELDS[kind] end

-- Which category a field sits in, so the pane can open on the right one for a STORED row rather
-- than making the player hunt for where their own condition came from.
function Conditions.categoryOf(kind)
  for _, cat in ipairs(Conditions.CATEGORIES) do
    for _, field in ipairs(cat.fields) do
      if field == kind then return cat.id end
    end
  end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end

local function opById(field, id)
  for _, op in ipairs(field.ops) do
    if op.id == id then return op end
  end
  return nil -- mutants: equivalent Lua returns nil implicitly at the end of a function
end
Conditions.op = opById

-- ---------------------------------------------------------------- key sources

local function sortedKeys(t)
  local out = {}
  for key in pairs(t or {}) do out[#out + 1] = key end
  table.sort(out)
  return out
end

local function spellKeysWhere(pack, accept)
  local out = {}
  for key, data in pairs((pack and pack.spells) or {}) do
    if type(data) == "table" and accept(data) then out[#out + 1] = key end
  end
  table.sort(out)
  return out
end

-- Conditions.keys(kind, pack) -> a sorted list of the values this field accepts, or nil when it
-- takes none. A list rather than a set because the order is what the player reads, and `pairs()`
-- has none.
--
-- `castables` delegates to Core/Palette rather than re-deriving: "can you press this" is decided in
-- the DATA (a record says whether it is a rune, an aura, a passive, a proc or a trigger), and a
-- second copy of that rule here would be the one nobody casts from.
function Conditions.keys(kind, pack)
  local field = FIELDS[kind]
  local source = field and field.keySource
  if not source then return nil end
  if source == "modes" then return Conditions.MODES end
  if source == "weaponKinds" then return Conditions.WEAPON_KINDS end
  if source == "creatureTypes" then return Conditions.CREATURE_TYPES end
  if source == "powers" then return Conditions.POWERS end
  if source == "spells" then return sortedKeys(pack and pack.spells) end
  if source == "sets" then return sortedKeys(pack and pack.sets) end
  if source == "bonuses" then return sortedKeys(pack and pack.bonuses) end
  if source == "souls" then return sortedKeys(pack and pack.souls) end
  if source == "seals" then return spellKeysWhere(pack, function(d) return d.seal == true end) end
  if source == "runes" then return spellKeysWhere(pack, function(d) return d.rune ~= nil end) end
  return spellKeysWhere(pack, ns.Palette.castable) -- "castables"
end

-- ---------------------------------------------------------------- rows

-- The highest positional index this field ever fills. A stored condition longer than that is
-- variadic ({"target_type","Undead","Demon"}), which is more than one value in a slot the editor
-- draws as one -- so it is reported complex instead of being silently narrowed to its first
-- argument, which is a DIFFERENT test from the one that shipped.
local function widthOf(field)
  local width = 1
  if field.slotAt and field.slotAt > width then width = field.slotAt end
  if field.keyAt and field.keyAt > width then width = field.keyAt end
  for _, op in ipairs(field.ops) do
    if op.at and op.at > width then width = op.at end
  end
  return width
end

-- One stored condition -> one row, or nil when it is not a shape the pane can draw.
local function rowOf(cond)
  if type(cond) ~= "table" then return nil end
  local field = FIELDS[cond[1]]
  if not field then return nil end -- unknown to the editor: `custom`, `all`, `any`, a typo
  if #cond > widthOf(field) then return nil end

  local quals = {}
  for key in pairs(cond) do
    if type(key) == "string" then quals[#quals + 1] = key end
  end
  if #quals > 1 then return nil end

  local row = { kind = cond[1] }
  if field.slotAt then row.slot = cond[field.slotAt] end
  if field.keyAt then row.key = cond[field.keyAt] end

  if #quals == 1 then
    local op = opById(field, quals[1])
    -- `op.at` means this field keeps its value positionally, so the same name arriving as a
    -- qualifier is a condition written in a shape the compiler does not read either.
    if not op or op.at then return nil end
    row.op, row.value = op.id, cond[quals[1]]
    return row
  end

  for _, op in ipairs(field.ops) do
    if op.at and cond[op.at] ~= nil then
      row.op, row.value = op.id, cond[op.at]
      return row
    end
  end
  local bare = field.ops[1]
  if bare.arg then return nil end -- the field has no valueless form; this condition is incomplete
  row.op = bare.id
  return row
end

local function condOf(row)
  local field = FIELDS[row and row.kind]
  if not field then return nil end
  local cond = { row.kind }
  if field.slotAt then cond[field.slotAt] = tonumber(row.slot) end
  if field.keyAt then cond[field.keyAt] = row.key end
  local op = opById(field, row.op) or field.ops[1]
  if op.arg == "number" then
    local value = tonumber(row.value)
    if op.at then cond[op.at] = value else cond[op.id] = value end
  end
  return cond
end

-- Conditions.blankRow(kind) -> the row a freshly added condition starts as. The caller fills `key`
-- from Conditions.keys, because only it knows which pack is loaded.
function Conditions.blankRow(kind)
  local field = FIELDS[kind]
  if not field then return nil end
  return { kind = kind, op = field.ops[1].id, value = field.ops[1].arg and 0 or nil }
end

-- Conditions.toRows(when) -> { match = "all"|"any", rows = {...}, complex = bool }
--
-- ONE all/any level, which is what the pane draws. A `when` list is an implicit `all`
-- (Core/Schema.compileList); a list whose single member is an `any` is that `any`'s children under
-- match = "any". Anything deeper -- a composite inside the list, a `not` around a composite, a
-- `custom` function, a variadic value, two qualifiers on one condition -- comes back complex.
--
-- A complex answer carries NO rows, deliberately. Handing back the ones that did convert invites a
-- caller to save those and lose the rest, which is the silent-partial-write shape this file's
-- whole existence is meant to avoid.
function Conditions.toRows(when)
  local list, match = when or {}, "all"
  if #list == 1 and type(list[1]) == "table" and list[1][1] == "any" then
    match = "any"
    local inner = {}
    for i = 2, #list[1] do inner[#inner + 1] = list[1][i] end
    list = inner
  end

  local rows = {}
  for _, cond in ipairs(list) do
    local leaf, negated = cond, false
    if type(cond) == "table" and cond[1] == "not" then
      negated, leaf = true, cond[2]
      if #cond > 2 then leaf = nil end -- `not` takes exactly one child; more is a hand-written shape
    end
    local row = rowOf(leaf)
    if not row then return { match = match, rows = {}, complex = true } end
    row.negated = negated
    rows[#rows + 1] = row
  end
  return { match = match, rows = rows, complex = false }
end

-- Conditions.fromRows(match, rows) -> a `when` list. The inverse of toRows for every shape toRows
-- reports as not complex; never call it for one that is.
function Conditions.fromRows(match, rows)
  local out = {}
  for _, row in ipairs(rows or {}) do
    local cond = condOf(row)
    if cond then
      if row.negated then cond = { "not", cond } end
      out[#out + 1] = cond
    end
  end
  if match ~= "any" or #out == 0 then return out end
  local any = { "any" }
  for i = 1, #out do any[i + 1] = out[i] end
  return { any }
end

-- ---------------------------------------------------------------- words

local function identity(_, key) return key end

local function localizer(ctx)
  return (ctx and ctx.L) or setmetatable({}, { __index = identity })
end

-- A number as a person writes it: 3, not 3.0; 1.5, not 1.5000000001.
local function num(value)
  if type(value) ~= "number" then return tostring(value) end
  return string.format("%g", value)
end

-- The display name for a symbolic key. `ctx.name` is Options/Rotation.spellLabel, which asks the
-- client; without one the key is its own best description, because Core may not call GetSpellInfo
-- (hard rule 3) and a blank is worse than an ugly name.
local function named(key, ctx)
  if ctx and ctx.name then
    local text = ctx.name(key)
    if text then return text end
  end
  return tostring(key)
end

-- One writer per dynamic condition type. The static ones are absent on purpose: they go to
-- Core/Gates.describe, which already words a requirement in the voice of it being MET, and a
-- second phrasing here would be the one that reads wrong in the announcement.
local WORDS = {}

WORDS.enemies = function(cond, _, L)
  if cond.max then return string.format(L["at most %s enemies nearby"], num(cond.max)) end
  return string.format(L["at least %s enemies nearby"], num(cond.min or 1))
end
WORDS.mode = function(cond, _, L) return string.format(L["mode is %s"], tostring(cond[2])) end
WORDS.ttd = function(cond, _, L)
  if cond.max then return string.format(L["target dies within %ss"], num(cond.max)) end
  return string.format(L["target lives at least %ss"], num(cond.min or 0))
end

WORDS.resource = function(cond, _, L)
  local what = tostring(cond[2]):lower()
  if cond.maxPct then return string.format(L["%s at most %s%%"], what, num(cond.maxPct)) end
  if cond.minPct then return string.format(L["%s at least %s%%"], what, num(cond.minPct)) end
  if cond.max then return string.format(L["%s at most %s"], what, num(cond.max)) end
  return string.format(L["%s at least %s"], what, num(cond.min or 0))
end

WORDS.target_hp = function(cond, _, L)
  if cond.maxPct then return string.format(L["target HP at most %s%%"], num(cond.maxPct)) end
  return string.format(L["target HP at least %s%%"], num(cond.minPct or 0))
end
WORDS.target_type = function(cond, _, L)
  local parts = {}
  for i = 2, #cond do parts[#parts + 1] = tostring(cond[i]) end
  return string.format(L["target is %s"], table.concat(parts, L[" or "]))
end

WORDS.buff = function(cond, ctx, L)
  local name = named(cond[2], ctx)
  if cond.min and cond.min > 1 then
    return string.format(L["%s at %s stacks or more"], name, num(cond.min))
  end
  if cond.maxRemaining then
    return string.format(L["%s with %ss left or less"], name, num(cond.maxRemaining))
  end
  if cond.minRemaining then
    return string.format(L["%s with %ss left or more"], name, num(cond.minRemaining))
  end
  return string.format(L["%s is up"], name)
end
WORDS.no_buff = function(cond, ctx, L) return string.format(L["%s is not up"], named(cond[2], ctx)) end
WORDS.debuff = function(cond, ctx, L)
  local name = named(cond[2], ctx)
  if cond.minRemaining then
    return string.format(L["%s on the target with %ss left or more"], name, num(cond.minRemaining))
  end
  return string.format(L["%s is on the target"], name)
end
WORDS.no_debuff = function(cond, ctx, L)
  return string.format(L["%s is not on the target"], named(cond[2], ctx))
end
WORDS.seal = function(cond, ctx, L) return string.format(L["%s is the active seal"], named(cond[2], ctx)) end
WORDS.no_seal = function(_, _, L) return L["no seal is up"] end
WORDS.seal_linger = function(cond, ctx, L)
  return string.format(L["%s is still lingering"], named(cond[2], ctx))
end

WORDS.cooldown_ready = function(cond, ctx, L)
  return string.format(L["%s is off cooldown"], named(cond[2], ctx))
end
WORDS.cooldown_gt = function(cond, ctx, L)
  return string.format(L["%s has more than %ss of cooldown left"], named(cond[2], ctx), num(cond[3]))
end
-- PE3-D5 (2026-09-08 owner ruling, in-game): "the item in slot 13 is ready" is an API detail read
-- aloud. Slot 13 is Trinket 1 and that is what the sentence says -- through `ctx.slotName`, because
-- Core decides what a slot IS and Options decides what it is CALLED (the same split Options.lua
-- states for Core/Visibility's modes). The number is only ever reached by a caller that supplied no
-- namer at all; every panel that shows this sentence builds its ctx from `Rotation.wordCtx`.
WORDS.item_ready = function(cond, ctx, L)
  local slot = ctx and ctx.slotName and ctx.slotName(cond[2])
  if slot then return string.format(L["%s is off cooldown"], slot) end
  return string.format(L["the item in slot %s is ready"], num(cond[2]))
end
WORDS.swing = function(cond, _, L)
  if cond.maxRemaining then
    return string.format(L["next swing within %ss"], num(cond.maxRemaining))
  end
  return string.format(L["next swing at least %ss away"], num(cond.minRemaining or 0))
end

WORDS.in_combat = function(_, _, L) return L["in combat"] end
WORDS.out_of_combat = function(_, _, L) return L["out of combat"] end
WORDS.not_moving = function(_, _, L) return L["standing still"] end

-- Conditions.describe(cond, ctx) -> one condition in words.
--
-- ctx.L is an AceLocale table (identity when absent); ctx.name resolves a symbolic key to a display
-- name; ctx.sets/ctx.bonuses are the pack tables Core/Gates.describe words a static gate from.
function Conditions.describe(cond, ctx)
  local L = localizer(ctx)
  if type(cond) ~= "table" then return L["an unreadable condition"] end
  local kind = cond[1]

  -- Composites recurse HERE rather than in Gates.describe, which knows only the static kinds and
  -- would render a dynamic child as the bare word "buff".
  if kind == "all" or kind == "any" then
    local parts = {}
    for i = 2, #cond do parts[#parts + 1] = Conditions.describe(cond[i], ctx) end
    if #parts == 0 then return L["nothing"] end
    local last = table.remove(parts)
    if #parts == 0 then return last end
    return table.concat(parts, L[", "]) .. (kind == "any" and L[" or "] or L[" and "]) .. last
  elseif kind == "not" then
    return string.format(L["not %s"], Conditions.describe(cond[2], ctx))
  end

  if ns.Gates.STATIC[kind] then return ns.Gates.describe(cond, ctx) end
  local writer = WORDS[kind]
  if writer then return writer(cond, ctx, L) end
  return tostring(kind)
end

-- Conditions.summary(when, ctx) -> the one line the rotation list shows under a row's name.
--
-- Two conditions and a count, not all of them: the list is a column 1.6 widths across and a row
-- that wraps to four lines stops being a list. Replaces the count-only summary the Builder shipped
-- with, which said "2 conditions" for every row that had two and so distinguished nothing.
local SUMMARY_SHOWN = 2

function Conditions.summary(when, ctx)
  local L = localizer(ctx)
  local list = when or {}
  if #list == 0 then return L["always"] end
  local parts = {}
  for i = 1, math.min(#list, SUMMARY_SHOWN) do
    parts[#parts + 1] = Conditions.describe(list[i], ctx)
  end
  local text = table.concat(parts, L[", "])
  if #list > SUMMARY_SHOWN then
    text = text .. string.format(L[" +%d more"], #list - SUMMARY_SHOWN)
  end
  return text
end

ns.Conditions = Conditions
return Conditions
