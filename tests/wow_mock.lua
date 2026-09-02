-- tests/wow_mock.lua — WoW client mock for ADAPTER tests only. Core specs must never load this
-- (docs/04): Core is pure Lua and a Core test that needs a client global is a hard-rule-3 violation
-- showing up as a test dependency.
--
-- This file writes into `_G`, so state leaks between specs unless `reset()` is called. Every spec
-- that loads it must call `mock.reset()` in before_each — `tests/spec/wow_mock_spec.lua` exists
-- precisely because until M2 nothing loaded this file at all, making it an untested harness that the
-- adapter specs were about to trust. A mock that lies produces green tests over a broken adapter.
--
-- Return values follow the Classic Era (1.15.x) signatures in the wow-addon-dev API cheat sheet, and
-- where the live client surprised us, THIS MOCK COPIES THE CLIENT, not the documentation. See
-- `GetSpellCooldown` (returns the GCD during the GCD) and `GetTalentTabInfo` (does not return the
-- name first) below — both verified in game, both recorded in docs/07 §9.
local M = {}

-- Defaults live here so reset() is a single assignment and can never drift from the initial state.
local function defaults()
  return {
    time = 0,
    cooldowns = {},          -- [spellID] = { start, duration }
    gcdActive = false,       -- when true, GetSpellCooldown reports the GCD for spells with no real CD
    castTimes = {},          -- [spellID] = milliseconds
    knownSpells = {},        -- [spellID] = true; nil means "not known"
    powerCosts = {},         -- [spellID] = amount (mana)
    auras = { player = {}, target = {} },
    power = { [0] = { 1000, 1000 } },
    inventory = {},          -- [slot] = itemID
    itemLinks = {},          -- [slot] = link string
    tooltipLines = {},       -- [slot] = { "line", ... }  (LEFT column)
    tooltipRight = {},       -- [slot] = { "line", ... }  (RIGHT column, same line numbers)
    itemInfo = {},           -- [itemID] = { name, equipLoc, speed }
    runes = {},              -- [slot] = { name =, learnedAbilitySpellIDs = {...} }
    engravingEnabled = true,
    creatureType = nil,
    attackSpeed = { 2.1, nil },
    level = 60,
    class = "PALADIN",
    talentTabs = { { 382, 31 }, { 383, 0 }, { 381, 20 } }, -- Arthorion's real spread, docs/07 §9.7
    speed = 0,
    health = { 100, 100 },
    inCombat = false,
    targetExists = true,       -- was hardcoded true, so "no target" could never be tested
    itemCooldowns = {},        -- [slot] = { start, duration }; was hardcoded (0,0)
    -- Weapon tooltips live in tooltipLines too; base speed is only readable there.
  }
end

local GCD = 1.5

-- Keys whose default is nil. `pairs()` skips nil values, so a plain copy of defaults() can never
-- clear them and a value set by one spec survives into the next — which is exactly how a stale
-- creatureType made an adapter spec see "Undead" after asking for no target. Nil defaults must be
-- erased explicitly, not assigned.
local NIL_DEFAULTS = { "creatureType" }

function M.reset()
  for _, key in ipairs(NIL_DEFAULTS) do M[key] = nil end
  for key, value in pairs(defaults()) do M[key] = value end
  return M
end

-- Convenience: makes a spell known AND gives it a cooldown/cost in one call, so a spec's intent
-- reads as one line instead of three assignments that can fall out of sync.
function M.spell(id, opts)
  opts = opts or {}
  M.knownSpells[id] = opts.known ~= false
  if opts.cooldown then M.cooldowns[id] = { opts.start or M.time, opts.cooldown } end
  if opts.cost then M.powerCosts[id] = opts.cost end
  if opts.castTime then M.castTimes[id] = opts.castTime end
end

function GetTime() return M.time end

-- Verified in game (docs/07 §9.10): this returns the GLOBAL cooldown for any spell while the GCD is
-- running, not that spell's own cooldown. An adapter that caches the return blindly records 1.5 s as
-- Exorcism's cooldown. The mock reproduces the trap so a spec can prove the filter works.
function GetSpellCooldown(id)
  local c = M.cooldowns[id]
  if c then return c[1], c[2], 1 end
  if M.gcdActive then return M.time, GCD, 1 end
  return 0, 0, 1
end

function IsUsableSpell(id) return M.knownSpells[id] == true, false end
function IsPlayerSpell(id) return M.knownSpells[id] == true end
function IsSpellKnown(id) return M.knownSpells[id] == true end

function GetSpellInfo(id)
  if M.knownSpells[id] == nil then return nil end
  -- Field 2 (rank) is absent on this client — docs/07 §9.6. Returning nil keeps specs honest.
  return "Spell" .. tostring(id), nil, nil, M.castTimes[id] or 0
end

-- Returns a LIST of cost tables, not a bare number. Reflects runes on the live client (345 -> 69
-- measured), which is why the adapter may call it directly instead of shipping a static table.
function GetSpellPowerCost(id)
  local cost = M.powerCosts[id]
  if not cost then return {} end
  return { { cost = cost, type = 0, name = "MANA" } }
end

function UnitAura(unit, i, filter)
  local list = M.auras[unit] or {}
  local a = list[i]
  if not a then return nil end
  return a.name, nil, a.count or 1, nil, a.duration or 10, (a.expires or M.time + 10),
         a.source or "player", nil, nil, a.spellID
end

AuraUtil = {
  FindAuraByName = function(name, unit, filter)
    for i = 1, 40 do
      local auraName = UnitAura(unit, i, filter)
      if not auraName then return nil end
      if auraName == name then return UnitAura(unit, i, filter) end
    end
    return nil
  end,
}

function UnitPower(u, kind) return M.power[kind or 0][1] end
function UnitPowerMax(u, kind) return M.power[kind or 0][2] end
function UnitCreatureType(u) return M.creatureType end
function UnitExists(u)
  if u == "target" then return M.targetExists end
  return true
end
function UnitHealth(u) return M.health[1] end
function UnitHealthMax(u) return M.health[2] end
function UnitLevel(u) return M.level end
function UnitClass(u) return "ClassName", M.class end
function GetUnitSpeed(u) return M.speed end
function GetInventoryItemID(u, slot) return M.inventory[slot] end
function GetInventoryItemLink(u, slot) return M.itemLinks[slot] end
function UnitAttackSpeed(u) return M.attackSpeed[1], M.attackSpeed[2] end
function GetInventoryItemCooldown(u, slot)
  local c = M.itemCooldowns[slot]
  if c then return c[1], c[2] end
  return 0, 0
end
function IsUsableItem(id) return true end
function InCombatLockdown() return M.inCombat end

function GetItemInfo(id)
  local info = M.itemInfo[id]
  if not info then return nil end
  -- Real signature has itemEquipLoc at 9 and speed nowhere; specs read what the adapter reads.
  return info.name, nil, nil, nil, nil, nil, nil, nil, info.equipLoc, nil, nil, nil, nil, nil, nil,
         nil, nil
end

-- Verified in game (docs/07 §9.8): this does NOT return the name first. Position 1 held a numeric tab
-- id (382 Holy / 383 Prot / 381 Ret) and points spent were in position 5. The mock copies the client,
-- so any code written against the documented shape fails here rather than in game.
function GetTalentTabInfo(tab)
  local t = M.talentTabs[tab]
  if not t then return nil end
  return t[1], nil, nil, nil, t[2]
end

C_Engraving = {
  IsEngravingEnabled = function() return M.engravingEnabled end,
  GetRuneForEquipmentSlot = function(slot) return M.runes[slot] end,
  RefreshRunesList = function() end,
}

-- A scanning tooltip: CreateFrame("GameTooltip", name, ...) must also publish the per-line font
-- strings as globals, because that is the only way Classic exposes tooltip text.
function CreateFrame(frameType, name, parent, template)
  local frame = {}
  local lines = {}
  function frame:SetOwner() end
  function frame:ClearLines() lines = {} end
  function frame:NumLines() return #lines end
  -- Models BOTH columns, because the client does: a weapon's "Speed 2.10" is right-column text on
  -- the same line as its damage range. Modelling only the left let a left-only parse pass its test
  -- and then find nothing in game. `tooltipLines[slot]` is the left column; `tooltipRight[slot]` the
  -- right, indexed by the same line number.
  function frame:SetInventoryItem(unit, slot)
    lines = M.tooltipLines[slot] or {}
    local right = M.tooltipRight[slot] or {}
    if name then
      for i = 1, 40 do
        local l, r = lines[i], right[i]
        _G[name .. "TextLeft" .. i] = l and { GetText = function() return l end } or nil
        _G[name .. "TextRight" .. i] = r and { GetText = function() return r end } or nil
      end
    end
  end
  return setmetatable(frame, { __index = function() return function() end end })
end

UIParent = {}
Enum = { PowerType = { Mana = 0, Rage = 1, Energy = 3 } }
WOW_PROJECT_ID, WOW_PROJECT_CLASSIC = 2, 2

M.GCD = GCD
return M.reset()
